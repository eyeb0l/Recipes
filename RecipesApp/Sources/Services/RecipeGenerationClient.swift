import Foundation
import Observation
import RecipeCore

/// A web page the generator read while writing a recipe.
struct RecipeGenerationSource: Codable, Hashable, Sendable {
    let title: String?
    let url: URL

    var displayName: String {
        if let title, !title.isEmpty { return title }
        return url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }
}

/// One version of a generated recipe, before it is saved to the library.
struct RecipeDraft: Equatable, Sendable {
    var recipe: RecipeV1
    var sources: [RecipeGenerationSource]
    /// The changes asked for to reach this version, oldest first.
    var feedback: [String] = []
}

/// What to send back to the generator to revise a draft.
struct RecipeRevision: Sendable {
    let draft: RecipeDraft
    let feedback: String
}

struct RecipeGenerationResponse: Decodable, Sendable {
    struct Generation: Decodable, Sendable {
        let provider: String
        let model: String
        let schemaVersion: Int
        let webSearch: Bool
    }

    let requestID: String
    let recipe: RecipeV1
    let generation: Generation
    let sources: [RecipeGenerationSource]
}

enum RecipeGenerationRequestBody {
    /// The service rejects requests shorter than this.
    static let minimumRequestLength = 3
    static let maximumTextLength = 2_000
    /// The service accepts this many earlier changes. Each draft already includes them, so older ones
    /// only remind the model what to keep.
    static let maximumEarlierFeedback = 10

    /// Text length as the service counts it, in UTF-16 code units, so the app never offers to send
    /// text the service will reject.
    static func length(of text: String) -> Int { text.utf16.count }

    /// Builds the JSON body. The draft is encoded with the canonical encoder, so it keeps the
    /// explicit nulls the service's schema expects.
    static func data(
        request: String,
        revision: RecipeRevision?,
        locale: String,
        preferredUnits: UnitSystemPreference,
        idempotencyKey: String
    ) throws -> Data {
        var body: [String: Any] = [
            "request": request,
            "locale": locale,
            "preferredUnitSystem": preferredUnits.rawValue,
            "idempotencyKey": idempotencyKey,
            "supportedUnits": UnitID.allCases.map(\.rawValue)
        ]
        if let revision {
            body["revision"] = [
                "recipe": try JSONSerialization.jsonObject(with: RecipeCoding.encoder.encode(revision.draft.recipe)),
                "feedback": revision.feedback,
                "earlierFeedback": Array(revision.draft.feedback.suffix(maximumEarlierFeedback)),
                "sources": revision.draft.sources.map { source -> [String: Any] in
                    ["title": source.title ?? NSNull(), "url": source.url.absoluteString]
                }
            ] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// Asks the service to write a recipe from a request, or to revise a draft it wrote.
@MainActor
@Observable
final class RecipeGenerationClient {
    enum State: Equatable {
        case idle
        case generating
        case revising
        case failed(String)
    }

    typealias Responder = @Sendable (_ request: String, _ revision: RecipeRevision?) async throws -> RecipeGenerationResponse

    private(set) var state: State = .idle
    /// Whether the user must be signed in. UI tests write recipes locally, so they don't need to.
    let requiresSignIn: Bool
    private let responder: Responder?

    init() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            responder = UITestingRecipeGenerator.respond
            requiresSignIn = false
        } else {
            responder = nil
            requiresSignIn = true
        }
    }

    init(responder: @escaping Responder) {
        self.responder = responder
        requiresSignIn = false
    }

    var isWorking: Bool { state == .generating || state == .revising }

    /// Writes a recipe, or revises one when `revision` is given. Pass the same `idempotencyKey`
    /// when retrying the same request so the service can join work that is still in flight.
    func generate(
        request: String,
        revision: RecipeRevision? = nil,
        auth: AuthSession,
        preferredUnits: UnitSystemPreference,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> RecipeDraft {
        state = revision == nil ? .generating : .revising
        do {
            let response: RecipeGenerationResponse
            if let responder {
                response = try await responder(request, revision)
            } else {
                let body = try RecipeGenerationRequestBody.data(
                    request: request,
                    revision: revision,
                    locale: Locale.current.identifier,
                    preferredUnits: preferredUnits,
                    idempotencyKey: idempotencyKey
                )
                do {
                    response = try await send(body, token: auth.validAccessToken())
                } catch let APIClientError.rejected(status, _) where status == 401 {
                    // The access token can expire or be revoked between the local check and the request.
                    response = try await send(body, token: auth.validAccessToken(forceRefresh: true))
                }
            }
            let validation = RecipeValidator.validate(response.recipe)
            guard validation.isValid else {
                throw APIClientError.rejected(
                    status: 422,
                    message: validation.issues.filter { $0.severity == .error }.map(\.message).joined(separator: " ")
                )
            }
            state = .idle
            let feedback = revision.map { $0.draft.feedback + [$0.feedback] } ?? []
            return RecipeDraft(recipe: response.recipe, sources: response.sources, feedback: feedback)
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func send(_ body: Data, token: String) async throws -> RecipeGenerationResponse {
        do {
            var request = URLRequest(url: APIConfiguration.baseURL.appending(path: "/v1/recipe-generations"))
            request.httpMethod = "POST"
            // The service allows the model 150 seconds, since searching the web adds round trips.
            request.timeoutInterval = 170
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            try requireSuccess(data: data, response: response)
            do {
                return try RecipeCoding.decoder.decode(RecipeGenerationResponse.self, from: data)
            } catch {
                throw APIClientError.invalidResponse
            }
        } catch let error as URLError where error.code == .timedOut {
            throw APIClientError.rejected(status: 504, message: "Writing the recipe took too long. Check your connection and try again.")
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw APIClientError.rejected(status: 0, message: "You're offline. Connect to the internet to create a recipe.")
        }
    }
}

/// Writes recipes on the device for UI tests, so they need no network, sign-in or model.
enum UITestingRecipeGenerator {
    static func respond(request: String, revision: RecipeRevision?) async throws -> RecipeGenerationResponse {
        try await Task.sleep(for: .milliseconds(400))
        var recipe: RecipeV1
        if let revision {
            recipe = revision.draft.recipe
            recipe.summary = "Changed: \(revision.feedback)"
        } else {
            recipe = SampleRecipe.espressoBrownies
            recipe.id = "generated-ui-testing"
            recipe.title = "Generated Brownies"
            recipe.summary = "Written for: \(request)"
        }
        recipe.provenance = RecipeProvenance(sourceType: .generated, cleanedText: "Created from your request:\n\(request)")
        return RecipeGenerationResponse(
            requestID: "ui-testing",
            recipe: recipe,
            generation: .init(provider: "ui-testing", model: "ui-testing", schemaVersion: 1, webSearch: true),
            sources: [RecipeGenerationSource(title: "Brownie baking guide", url: URL(string: "https://example.com/brownies")!)]
        )
    }
}
