import RecipeCore
import SwiftData
import XCTest
@testable import RecipeTimeline

final class RecipeTimelineTests: XCTestCase {
    func testRecipeRecordStoresSearchMetadataAndCanonicalJSON() throws {
        let source = SampleRecipe.espressoBrownies
        let record = try RecipeRecord(recipe: source, date: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(record.title, source.title)
        XCTAssertEqual(record.unresolvedWarningCount, 0)
        XCTAssertEqual(try record.recipe(), source)

        var changed = source
        changed.title = "Edited Brownies"
        changed.uncertainties.append(.init(kind: .ambiguousTiming, message: "The source gives two baking times.", stageIDs: ["bake"]))
        try record.update(with: changed, date: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(record.title, "Edited Brownies")
        XCTAssertEqual(record.unresolvedWarningCount, 1)
        XCTAssertEqual(record.updatedAt, Date(timeIntervalSince1970: 200))
    }

    @MainActor
    func testRecipeRecordPersistsOfflineInMemory() throws {
        let schema = Schema([RecipeRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let record = try RecipeRecord(recipe: SampleRecipe.espressoBrownies)
        container.mainContext.insert(record)
        try container.mainContext.save()
        let records = try container.mainContext.fetch(FetchDescriptor<RecipeRecord>())
        XCTAssertEqual(records.map(\.id), [SampleRecipe.espressoBrownies.id])
    }
}
