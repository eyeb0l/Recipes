import Foundation

enum APIConfiguration {
    static var baseURL: URL {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "ImportAPIBaseURL") as? String,
            let url = URL(string: raw),
            url.scheme == "https",
            url.host != nil
        else {
            fatalError("ImportAPIBaseURL must be configured as a valid HTTPS URL.")
        }
        return url
    }
}

struct APIErrorPayload: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String
    }

    let error: Detail
    let requestID: String?
}

enum APIClientError: LocalizedError {
    case invalidResponse
    case rejected(status: Int, message: String)
    case missingIdentityToken
    case missingSession
    case invalidSource

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The import service sent a response the app couldn't read."
        case let .rejected(_, message): message
        case .missingIdentityToken: "Sign in with Apple didn't return a valid sign-in token. Try again."
        case .missingSession: "Sign in with Apple before importing a recipe."
        case .invalidSource: "Add a recipe URL, text, or at least one cookbook image."
        }
    }
}

extension URLRequest {
    mutating func setJSONBody<T: Encodable>(_ body: T) throws {
        setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpBody = try JSONEncoder().encode(body)
    }
}

func requireSuccess(data: Data, response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
        throw APIClientError.rejected(status: http.statusCode, message: payload?.error.message ?? "Request failed (\(http.statusCode)).")
    }
}
