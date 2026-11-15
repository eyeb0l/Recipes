import CoreGraphics
import RecipeCore
import SwiftData
import UIKit
import XCTest
@testable import RecipeTimeline

final class RecipeTimelineTests: XCTestCase {
    @MainActor
    func testCookbookFileImporterLoadsImagesAndLimitsPDFPages() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appending(path: "cover.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 320)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
        }
        try XCTUnwrap(image.pngData()).write(to: imageURL)

        let pdfURL = directory.appending(path: "recipe.pdf")
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { renderer in
            for pageNumber in 1...3 {
                renderer.beginPage()
                NSString(string: "Recipe page \(pageNumber)").draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
            }
        }
        try pdfData.write(to: pdfURL)

        let imported = try CookbookFileImporter.images(from: [imageURL, pdfURL], maximumPageCount: 3)

        XCTAssertEqual(imported.count, 3)
        XCTAssertEqual(imported[0].size.width / imported[0].size.height, 0.75, accuracy: 0.001)
        XCTAssertGreaterThan(imported[0].size.width, 0)
        XCTAssertEqual(max(imported[1].size.width, imported[1].size.height), 2_048, accuracy: 1)
        XCTAssertEqual(max(imported[2].size.width, imported[2].size.height), 2_048, accuracy: 1)
    }

    func testSessionTokensRoundTripThroughPersistentStorageCodec() throws {
        let expected = SessionTokens(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            accessExpiresAt: Date(timeIntervalSince1970: 1_787_310_900),
            refreshExpiresAt: Date(timeIntervalSince1970: 1_789_902_900)
        )

        let restored = try SessionTokens.decodeStored(expected.encodedForStorage())

        XCTAssertEqual(restored.accessToken, expected.accessToken)
        XCTAssertEqual(restored.refreshToken, expected.refreshToken)
        XCTAssertEqual(restored.accessExpiresAt, expected.accessExpiresAt)
        XCTAssertEqual(restored.refreshExpiresAt, expected.refreshExpiresAt)
    }

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

    @MainActor
    func testRecipeExporterCreatesValidPDFWorkbookAndPNGFiles() throws {
        let request = RecipeExportRequest(
            recipe: SampleRecipe.espressoBrownies,
            servings: 18,
            units: .imperial
        )
        let artifacts = try RecipeExporter.exportAll(request)
        XCTAssertEqual(artifacts.map(\.format), [.pdf, .xlsx, .png])

        let pdf = try Data(contentsOf: try XCTUnwrap(artifacts.first { $0.format == .pdf }).url)
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(pdf.count, 1_000)
        let pdfProvider = try XCTUnwrap(CGDataProvider(data: pdf as CFData))
        let pdfDocument = try XCTUnwrap(CGPDFDocument(pdfProvider))
        let pdfPage = try XCTUnwrap(pdfDocument.page(at: 1))
        let mediaBox = pdfPage.getBoxRect(.mediaBox)
        XCTAssertGreaterThan(mediaBox.width, mediaBox.height)

        let workbook = try Data(contentsOf: try XCTUnwrap(artifacts.first { $0.format == .xlsx }).url)
        XCTAssertTrue(workbook.starts(with: Data([0x50, 0x4B, 0x03, 0x04])))
        XCTAssertNotNil(workbook.range(of: Data("xl/workbook.xml".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("Timeline".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("Ingredients".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("Imperial".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("3 min".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("30–40 min".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("mergeCells".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("showGridLines=\"0\"".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("FFF4F1EA".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("FF88464A".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("FFC66E71".utf8)))
        XCTAssertNil(workbook.range(of: Data(".formatted(".utf8)))

        let png = try Data(contentsOf: try XCTUnwrap(artifacts.first { $0.format == .png }).url)
        XCTAssertTrue(png.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
        XCTAssertGreaterThan(png.count, 1_000)
        let timelineImage = try XCTUnwrap(UIImage(data: png))
        XCTAssertGreaterThan(timelineImage.size.width, timelineImage.size.height)
        XCTAssertGreaterThan(timelineImage.size.width, 1_400)
    }

    @MainActor
    func testRecipeExporterRepairsMalformedImportedYieldBeforeScaling() throws {
        var recipe = SampleRecipe.espressoBrownies
        recipe.recipeYield = RecipeYield(servings: Decimal(string: "0.004")!, label: "4 servings")

        let baseRequest = RecipeExportRequest(
            recipe: recipe,
            servings: Decimal(string: "0.004")!,
            units: .metric
        )
        XCTAssertEqual(baseRequest.recipe.recipeYield.servings, 4)
        XCTAssertEqual(baseRequest.servings, 4)

        let artifacts = try RecipeExporter.exportAll(baseRequest)
        let workbook = try Data(contentsOf: try XCTUnwrap(artifacts.first { $0.format == .xlsx }).url)
        XCTAssertNotNil(workbook.range(of: Data("SERVES 4".utf8)))
        XCTAssertNil(workbook.range(of: Data("0.004".utf8)))
        XCTAssertNotNil(workbook.range(of: Data("115 g".utf8)))
        XCTAssertNil(workbook.range(of: Data("115 kg".utf8)))
    }

    func testRecipeExportRequestPreservesValidSelectedServingsAgainstRepairedBase() {
        var recipe = SampleRecipe.espressoBrownies
        recipe.recipeYield = RecipeYield(servings: Decimal(string: "0.004")!, label: "4 servings")

        let request = RecipeExportRequest(recipe: recipe, servings: 2, units: .metric)

        XCTAssertEqual(request.recipe.recipeYield.servings, 4)
        XCTAssertEqual(request.servings, 2)
        XCTAssertEqual(
            request.recipe.sortedIngredients.first?.displayQuantity(
                servings: request.servings,
                originalServings: request.recipe.recipeYield.servings,
                units: request.units
            ),
            "57½ g"
        )
    }

    @MainActor
    func testRecipeURLNormalisationAcceptsPastedLinksAndRejectsNonLinks() {
        XCTAssertEqual(
            ImportRecipeView.normalizedRecipeURL(from: "  https://example.com/recipes/stew \n")?.absoluteString,
            "https://example.com/recipes/stew"
        )
        XCTAssertEqual(
            ImportRecipeView.normalizedRecipeURL(from: "example.com/recipes/stew")?.absoluteString,
            "https://example.com/recipes/stew"
        )
        XCTAssertEqual(ImportRecipeView.normalizedRecipeURL(from: "http://example.org/a")?.scheme, "http")
        XCTAssertNil(ImportRecipeView.normalizedRecipeURL(from: ""))
        XCTAssertNil(ImportRecipeView.normalizedRecipeURL(from: "ftp://example.com/recipe"))
        XCTAssertNil(ImportRecipeView.normalizedRecipeURL(from: "chocolate cake"))
        XCTAssertNil(ImportRecipeView.normalizedRecipeURL(from: "localhost"))
    }

    @MainActor
    func testPastedTextThresholdMatchesTheImportService() {
        // services/import-api rejects trimmed text shorter than 40 characters.
        XCTAssertEqual(ImportRecipeView.minimumPastedTextLength, 40)
    }
}
