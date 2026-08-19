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

    func testTimelineGeometryKeepsSharedLineageTopEdgesAlignedAndBelowGlobalBand() throws {
        let layout = try TimelineLayoutEngine.makeLayout(for: SampleRecipe.espressoBrownies)
        let geometry = TimelineGridGeometry(layout: layout, metrics: .init())
        let placements = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.stageID, $0) })
        let preheat = geometry.cardFrame(for: try XCTUnwrap(placements["preheat"]))
        let expectedTop = geometry.cardFrame(for: try XCTUnwrap(placements["melt"])).minY

        for stageID in ["mix-wet", "add-eggs", "fold", "bake"] {
            let frame = geometry.cardFrame(for: try XCTUnwrap(placements[stageID]))
            XCTAssertEqual(frame.minY, expectedTop, accuracy: 0.001, "\(stageID) should share the lineage top edge")
        }
        XCTAssertGreaterThan(expectedTop, preheat.maxY)
        XCTAssertEqual(geometry.contentWidth, 5 * TimelineGridMetrics().laneWidth, accuracy: 0.001)
    }

    func testTimelineGeometryPlacesDirectIngredientMarkersAtTheirRowCenters() throws {
        let recipe = SampleRecipe.espressoBrownies
        let layout = try TimelineLayoutEngine.makeLayout(for: recipe)
        let geometry = TimelineGridGeometry(layout: layout, metrics: .init())
        let placement = try XCTUnwrap(layout.placements.first { $0.stageID == "mix-wet" })
        let rowsByIngredient = Dictionary(uniqueKeysWithValues: recipe.sortedIngredients.enumerated().map { ($0.element.id, $0.offset) })
        let stage = try XCTUnwrap(recipe.stages.first { $0.id == "mix-wet" })
        let directRows = stage.ingredientUses.compactMap { rowsByIngredient[$0.ingredientID] }

        XCTAssertEqual(
            geometry.inputMarkerOffsets(for: placement, directRows: directRows),
            [132, 224, 316]
        )
    }
}
