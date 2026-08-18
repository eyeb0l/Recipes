import Foundation

public enum RecipeSchemaMigrationError: Error, LocalizedError, Equatable {
    case invalidDocument
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "The saved recipe document is invalid."
        case let .unsupportedVersion(version): "Recipe schema version \(version) is not supported."
        }
    }
}

public enum RecipeSchemaMigrator {
    public static let currentVersion = 1

    public static func decodeAndMigrate(_ data: Data) throws -> RecipeV1 {
        let json = try JSONSerialization.jsonObject(with: data)
        guard var object = json as? [String: Any] else { throw RecipeSchemaMigrationError.invalidDocument }
        let version = object["schemaVersion"] as? Int ?? 0
        switch version {
        case 0:
            object = migratePreviewV0(object)
        case currentVersion:
            break
        default:
            throw RecipeSchemaMigrationError.unsupportedVersion(version)
        }
        let migrated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try RecipeCoding.decoder.decode(RecipeV1.self, from: migrated)
    }

    private static func migratePreviewV0(_ input: [String: Any]) -> [String: Any] {
        var recipe = input
        recipe["schemaVersion"] = currentVersion
        if recipe["yield"] == nil {
            recipe["yield"] = ["servings": recipe.removeValue(forKey: "servings") ?? 1]
        }
        recipe["prepTasks"] = recipe["prepTasks"] ?? []
        recipe["workstreams"] = recipe["workstreams"] ?? []
        recipe["uncertainties"] = recipe["uncertainties"] ?? []
        recipe["provenance"] = recipe["provenance"] ?? [
            "sourceType": "manual",
            "importedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0))
        ]
        if var stages = recipe["stages"] as? [[String: Any]] {
            for index in stages.indices {
                stages[index]["dependencies"] = stages[index]["dependencies"] ?? []
                stages[index]["ingredientUses"] = stages[index]["ingredientUses"] ?? []
                stages[index]["timers"] = stages[index]["timers"] ?? []
                stages[index]["sortIndex"] = stages[index]["sortIndex"] ?? index
            }
            recipe["stages"] = stages
        }
        return recipe
    }
}
