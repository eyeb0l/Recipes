import Foundation
import Observation
import RecipeCore

enum RecipeImportSource: Sendable {
    case url(URL)
    case text(String)
    case images([Data], recognizedText: String?)
}

struct RecipeImportMetadata: Encodable {
    let sourceType: String
    let url: String?
    let text: String?
    let recognizedText: String?
    let locale: String
    let preferredUnitSystem: String
    let idempotencyKey: String
}

struct RecipeImportResponse: Decodable {
    struct Extraction: Decodable {
        let provider: String
        let model: String
        let schemaVersion: Int
    }

    let requestID: String
    let recipe: RecipeV1
    let extraction: Extraction
}

@MainActor
@Observable
final class RecipeImportClient {
    enum State: Equatable {
        case idle
        case importing
        case failed(String)
    }

    private(set) var state: State = .idle

    func importRecipe(
        from source: RecipeImportSource,
        auth: AuthSession,
        preferredUnits: UnitSystemPreference
    ) async throws -> RecipeImportResponse {
        state = .importing
        do {
            let token = try await auth.validAccessToken()
            var request = URLRequest(url: APIConfiguration.baseURL.appending(path: "/v1/recipe-imports"))
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")

            switch source {
            case let .url(url):
                let metadata = RecipeImportMetadata(
                    sourceType: "url", url: url.absoluteString, text: nil, recognizedText: nil,
                    locale: Locale.current.identifier, preferredUnitSystem: preferredUnits.rawValue,
                    idempotencyKey: UUID().uuidString
                )
                try request.setJSONBody(metadata)
            case let .text(text):
                let metadata = RecipeImportMetadata(
                    sourceType: "text", url: nil, text: text, recognizedText: nil,
                    locale: Locale.current.identifier, preferredUnitSystem: preferredUnits.rawValue,
                    idempotencyKey: UUID().uuidString
                )
                try request.setJSONBody(metadata)
            case let .images(images, recognizedText):
                guard !images.isEmpty else { throw APIClientError.invalidSource }
                let metadata = RecipeImportMetadata(
                    sourceType: "images", url: nil, text: nil, recognizedText: recognizedText,
                    locale: Locale.current.identifier, preferredUnitSystem: preferredUnits.rawValue,
                    idempotencyKey: UUID().uuidString
                )
                let boundary = "RecipeTimeline-\(UUID().uuidString)"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = try MultipartBody(boundary: boundary)
                    .addingJSON(metadata, name: "metadata")
                    .addingImages(Array(images.prefix(4)))
                    .data
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            try requireSuccess(data: data, response: response)
            let decoded = try RecipeCoding.decoder.decode(RecipeImportResponse.self, from: data)
            let validation = RecipeValidator.validate(decoded.recipe)
            guard validation.isValid else {
                throw APIClientError.rejected(
                    status: 422,
                    message: validation.issues.filter { $0.severity == .error }.map(\.message).joined(separator: " ")
                )
            }
            state = .idle
            return decoded
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }
}

private struct MultipartBody {
    let boundary: String
    var data = Data()

    func addingJSON<T: Encodable>(_ value: T, name: String) throws -> MultipartBody {
        var copy = self
        copy.data.append("--\(boundary)\r\n".data(using: .utf8)!)
        copy.data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n".data(using: .utf8)!)
        copy.data.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        copy.data.append(try JSONEncoder().encode(value))
        copy.data.append("\r\n".data(using: .utf8)!)
        return copy
    }

    func addingImages(_ images: [Data]) -> MultipartBody {
        var copy = self
        for (index, image) in images.enumerated() {
            copy.data.append("--\(boundary)\r\n".data(using: .utf8)!)
            copy.data.append("Content-Disposition: form-data; name=\"images\"; filename=\"page-\(index + 1).jpg\"\r\n".data(using: .utf8)!)
            copy.data.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            copy.data.append(image)
            copy.data.append("\r\n".data(using: .utf8)!)
        }
        copy.data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return copy
    }
}
