import Foundation
import RecipeCore
import SwiftData

@Model
final class RecipeRecord {
    var id: String = ""
    var title: String = ""
    var summaryText: String = ""
    var canonicalData: Data = Data()
    var sourceType: String = RecipeSourceType.manual.rawValue
    var sourceURL: String = ""
    var sourceTitle: String = ""
    var sourceCleanedText: String = ""
    var unresolvedWarningCount: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(recipe: RecipeV1, date: Date = Date()) throws {
        id = recipe.id
        title = recipe.title
        summaryText = recipe.summary ?? ""
        canonicalData = try RecipeCoding.encoder.encode(recipe)
        sourceType = recipe.provenance.sourceType.rawValue
        sourceURL = recipe.provenance.url ?? ""
        sourceTitle = recipe.provenance.title ?? ""
        sourceCleanedText = recipe.provenance.cleanedText ?? ""
        unresolvedWarningCount = recipe.uncertainties.filter { !$0.isResolved }.count
        createdAt = date
        updatedAt = date
    }

    func recipe() throws -> RecipeV1 {
        try RecipeSchemaMigrator.decodeAndMigrate(canonicalData)
    }

    func update(with recipe: RecipeV1, date: Date = Date()) throws {
        id = recipe.id
        title = recipe.title
        summaryText = recipe.summary ?? ""
        canonicalData = try RecipeCoding.encoder.encode(recipe)
        sourceType = recipe.provenance.sourceType.rawValue
        sourceURL = recipe.provenance.url ?? ""
        sourceTitle = recipe.provenance.title ?? ""
        sourceCleanedText = recipe.provenance.cleanedText ?? ""
        unresolvedWarningCount = recipe.uncertainties.filter { !$0.isResolved }.count
        updatedAt = date
    }
}
