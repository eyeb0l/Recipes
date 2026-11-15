import AuthenticationServices
import Foundation
import Observation

struct SessionTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Date
    let refreshExpiresAt: Date

    static func decodeStored(_ data: Data) throws -> Self {
        try JSONDecoder.iso8601.decode(Self.self, from: data)
    }

    func encodedForStorage() throws -> Data {
        try JSONEncoder.iso8601.encode(self)
    }
}

private struct AppleSessionRequest: Encodable {
    let identityToken: String
    let authorizationCode: String?
}

private struct RefreshSessionRequest: Encodable {
    let refreshToken: String
}

@MainActor
@Observable
final class AuthSession {
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn
        case failed(String)
    }

    private static let keychainAccount = "session-tokens"
    private(set) var state: State = .signedOut
    private var tokens: SessionTokens?
    /// Refresh tokens rotate on use, so concurrent callers must share one refresh request.
    private var refreshTask: Task<SessionTokens, Error>?

    init() {
        if let data = try? KeychainStore.load(account: Self.keychainAccount),
           let decoded = try? SessionTokens.decodeStored(data),
           decoded.refreshExpiresAt > Date() {
            tokens = decoded
            state = .signedIn
        }
    }

    var isAuthenticated: Bool {
        tokens?.refreshExpiresAt ?? .distantPast > Date()
    }

    func handle(result: Result<ASAuthorization, Error>) async {
        state = .signingIn
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                throw APIClientError.missingIdentityToken
            }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            var request = URLRequest(url: APIConfiguration.baseURL.appending(path: "/v1/session/apple"))
            request.httpMethod = "POST"
            try request.setJSONBody(AppleSessionRequest(identityToken: identityToken, authorizationCode: code))
            let (data, response) = try await URLSession.shared.data(for: request)
            try requireSuccess(data: data, response: response)
            let decoded = try JSONDecoder.iso8601.decode(SessionTokens.self, from: data)
            try persist(decoded)
            state = .signedIn
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens else { throw APIClientError.missingSession }
        if !forceRefresh, tokens.accessExpiresAt.timeIntervalSinceNow > 30 { return tokens.accessToken }
        guard tokens.refreshExpiresAt > Date() else {
            signOut()
            throw APIClientError.sessionExpired
        }

        let refreshToken = tokens.refreshToken
        let task: Task<SessionTokens, Error>
        let ownsRefresh: Bool
        if let existing = refreshTask {
            task = existing
            ownsRefresh = false
        } else {
            task = Task { try await Self.refresh(using: refreshToken) }
            refreshTask = task
            ownsRefresh = true
        }
        defer { if ownsRefresh { refreshTask = nil } }

        do {
            let refreshed = try await task.value
            if ownsRefresh {
                try persist(refreshed)
                state = .signedIn
            }
            return refreshed.accessToken
        } catch let APIClientError.rejected(status, _) where status == 400 || status == 401 {
            // The server no longer recognises this session, so retrying can't succeed.
            if ownsRefresh { signOut() }
            throw APIClientError.sessionExpired
        }
    }

    private static func refresh(using refreshToken: String) async throws -> SessionTokens {
        var request = URLRequest(url: APIConfiguration.baseURL.appending(path: "/v1/session/refresh"))
        request.httpMethod = "POST"
        try request.setJSONBody(RefreshSessionRequest(refreshToken: refreshToken))
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(data: data, response: response)
        return try JSONDecoder.iso8601.decode(SessionTokens.self, from: data)
    }

    func signOut() {
        tokens = nil
        KeychainStore.delete(account: Self.keychainAccount)
        state = .signedOut
    }

    private func persist(_ newTokens: SessionTokens) throws {
        let data = try newTokens.encodedForStorage()
        try KeychainStore.save(data, account: Self.keychainAccount)
        tokens = newTokens
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
