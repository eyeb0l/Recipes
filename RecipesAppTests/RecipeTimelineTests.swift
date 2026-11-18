import CloudKit
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
        XCTAssertNotNil(workbook.range(of: Data("US customary".utf8)))
        XCTAssertNil(workbook.range(of: Data("Imperial".utf8)))
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
            "58 g"
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

    @MainActor
    func testConcurrentTokenRefreshesShareOneRotatingRequest() async throws {
        StubSessionProtocol.reset(status: 200, body: try Self.tokenBody(access: "fresh-access", refresh: "fresh-refresh"), delay: 0.2)
        URLProtocol.registerClass(StubSessionProtocol.self)
        defer { URLProtocol.unregisterClass(StubSessionProtocol.self) }

        let auth = AuthSession(restoring: Self.expiredAccessTokens(), storage: .init(save: { _ in }, delete: {}))
        defer { auth.signOut() }
        async let first = auth.validAccessToken()
        async let second = auth.validAccessToken()
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["fresh-access", "fresh-access"])
        XCTAssertEqual(StubSessionProtocol.refreshRequestCount, 1)
        XCTAssertEqual(auth.state, .signedIn)
    }

    @MainActor
    func testRejectedRefreshSignsOutWithAnExpiredSessionError() async throws {
        StubSessionProtocol.reset(status: 401, body: Data(#"{"error":{"code":"invalid_refresh","message":"no"}}"#.utf8))
        URLProtocol.registerClass(StubSessionProtocol.self)
        defer { URLProtocol.unregisterClass(StubSessionProtocol.self) }

        let auth = AuthSession(restoring: Self.expiredAccessTokens(), storage: .init(save: { _ in }, delete: {}))
        do {
            _ = try await auth.validAccessToken()
            XCTFail("A rejected refresh must not return a token")
        } catch APIClientError.sessionExpired {
            // Expected.
        }
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.state, .signedOut)
    }

    @MainActor
    func testCloudSyncMonitorRecordsTheLastSuccessfulSyncAndKeepsIt() throws {
        let suite = "CloudSyncMonitorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = CloudSyncMonitor(defaults: defaults, notificationCenter: NotificationCenter())
        XCTAssertNil(monitor.lastSyncDate)

        let id = UUID()
        let finished = Date(timeIntervalSince1970: 1_800_000_000)
        monitor.record(Self.syncEvent(id: id, kind: .import, endDate: nil))
        XCTAssertTrue(monitor.isSyncing)
        monitor.record(Self.syncEvent(id: id, kind: .import, endDate: finished))
        XCTAssertFalse(monitor.isSyncing)
        XCTAssertEqual(monitor.lastSyncDate, finished)

        // Setup isn't a sync, and an older event finishing late mustn't move the date backwards.
        monitor.record(Self.syncEvent(kind: .setup, endDate: finished.addingTimeInterval(60)))
        monitor.record(Self.syncEvent(kind: .export, endDate: finished.addingTimeInterval(-60)))
        XCTAssertEqual(monitor.lastSyncDate, finished)

        let relaunched = CloudSyncMonitor(defaults: defaults, notificationCenter: NotificationCenter())
        XCTAssertEqual(relaunched.lastSyncDate, finished)
    }

    @MainActor
    func testCloudSyncMonitorKeepsAnExportFailureUntilAnExportSucceeds() throws {
        let suite = "CloudSyncMonitorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = CloudSyncMonitor(defaults: defaults, notificationCenter: NotificationCenter())

        let start = Date.now
        monitor.record(Self.syncEvent(kind: .export, endDate: start, succeeded: false, error: "Upload rejected"))
        monitor.record(Self.syncEvent(kind: .export, endDate: start.addingTimeInterval(20), succeeded: false, error: "Upload rejected"))
        XCTAssertNil(monitor.errorMessage(at: start.addingTimeInterval(29)))
        // Downloads still working doesn't mean this device's changes are reaching iCloud.
        let deadline = start.addingTimeInterval(30)
        monitor.record(Self.syncEvent(kind: .import, endDate: deadline))
        XCTAssertEqual(monitor.errorMessage(at: deadline), "Upload rejected")
        monitor.record(Self.syncEvent(kind: .export, endDate: deadline))
        XCTAssertNil(monitor.errorMessage(at: deadline))
    }

    @MainActor
    func testQuickImportRecoveryNeverShowsAWarning() throws {
        let suite = "CloudSyncMonitorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = CloudSyncMonitor(defaults: defaults, notificationCenter: NotificationCenter())
        let start = Date.now
        monitor.record(Self.syncEvent(kind: .import, endDate: start, succeeded: false))
        let retry = UUID()
        monitor.record(Self.syncEvent(id: retry, kind: .import, endDate: nil))
        XCTAssertTrue(monitor.isSyncing)
        XCTAssertNil(monitor.errorMessage(at: start.addingTimeInterval(1)))
        let recovered = start.addingTimeInterval(2)
        monitor.record(Self.syncEvent(id: retry, kind: .import, endDate: recovered))
        XCTAssertEqual(monitor.lastSyncDate, recovered)
        XCTAssertNil(monitor.errorMessage(at: start.addingTimeInterval(60)))
    }

    @MainActor
    func testCloudSyncMessagesExplainTheRecordThatFailedAPartialFailure() {
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                CKRecord.ID(recordName: "a"): CKError(.batchRequestFailed),
                CKRecord.ID(recordName: "b"): CKError(.quotaExceeded),
            ],
        ])
        XCTAssertEqual(CloudSyncMonitor.message(for: partial), "Your iCloud storage is full, so recipe changes can't upload.")
        XCTAssertEqual(
            CloudSyncMonitor.message(for: CKError(.notAuthenticated)),
            "Sign in to iCloud in the Settings app to sync your recipes."
        )
        XCTAssertEqual(
            CloudSyncMonitor.message(for: CKError(.quotaExceeded)),
            "Your iCloud storage is full, so recipe changes can't upload."
        )
    }

    func testCloudSyncWarningKeepsZoneDiagnosticsOutOfSettings() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Error fetching changes in zone <CKRecordZoneID>: client knowledge differs from server knowledge",
        ])
        XCTAssertEqual(CloudSyncMonitor.message(for: error), "iCloud couldn't finish syncing your recipes.")
    }

    @MainActor
    func testLastSyncedDescriptionSaysJustNowForTheFirstMinute() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CloudSyncMonitor.lastSyncedDescription(for: now.addingTimeInterval(-20), relativeTo: now), "Just now")
        XCTAssertNotEqual(CloudSyncMonitor.lastSyncedDescription(for: now.addingTimeInterval(-600), relativeTo: now), "Just now")
    }

    func testShoppingListStartsWithGatheredIngredientsUnselected() {
        let request = ShoppingListRequest(
            recipe: SampleRecipe.espressoBrownies,
            servings: 9,
            units: .metric,
            gatheredIngredientIDs: ["butter", "salt"]
        )
        XCTAssertEqual(request.items.count, 9)
        XCTAssertEqual(request.initiallyExcludedIDs, ["butter", "salt"])
    }

    @MainActor
    func testAddingAShoppingListAsksForAccessAndNeverDuplicatesReminders() async throws {
        let groceries = ReminderListSummary(id: "groceries", title: "Groceries")
        let store = InMemoryShoppingReminderStore(lists: [groceries])
        store.insert(.init(id: "existing", listID: "groceries", title: "Large egg", notes: "6 · Pancakes"))
        store.insert(.init(id: "done", listID: "groceries", title: "Caster sugar", notes: nil, isCompleted: true))
        let items = ShoppingList.items(for: SampleRecipe.espressoBrownies, servings: 9, units: .metric)

        do {
            _ = try await store.add(items, recipeTitle: "Espresso Brownies", toList: "groceries")
            XCTFail("Adding without access should fail")
        } catch {
            XCTAssertEqual(error as? ShoppingReminderError, .accessDenied)
        }

        let granted = try await store.requestAccess()
        XCTAssertTrue(granted)
        let first = try await store.add(items, recipeTitle: "Espresso Brownies", toList: "groceries")
        XCTAssertEqual(first, .init(listTitle: "Groceries", addedCount: 8, updatedCount: 1, alreadyListedCount: 0))
        XCTAssertEqual(store.reminders.first { $0.id == "existing" }?.notes, "6 · Pancakes\n2 · Espresso Brownies")
        XCTAssertEqual(store.reminders.filter { $0.title == "Caster sugar" }.count, 2, "A completed reminder is not reused")

        let second = try await store.add(items, recipeTitle: "Espresso Brownies", toList: "groceries")
        XCTAssertEqual(second, .init(listTitle: "Groceries", addedCount: 0, updatedCount: 0, alreadyListedCount: 9))
        XCTAssertEqual(store.reminders.count, 10)

        do {
            _ = try await store.add(items, recipeTitle: "Espresso Brownies", toList: "deleted")
            XCTFail("Adding to a missing list should fail")
        } catch {
            XCTAssertEqual(error as? ShoppingReminderError, .listUnavailable)
        }
    }

    @MainActor
    func testAPlanIsNotAppliedOverChangesMadeSinceItWasWorkedOut() async throws {
        let store = InMemoryShoppingReminderStore(lists: [.init(id: "groceries", title: "Groceries")], access: .granted)
        store.insert(.init(id: "eggs", listID: "groceries", title: "Large eggs", notes: "6 · Pancakes"))
        let items = [ShoppingListItem(id: "eggs", ingredientIDs: ["eggs"], name: "Large eggs", quantity: "2")]
        let plan = ShoppingList.plan(
            adding: items,
            recipeTitle: "Brownies",
            to: try await store.incompleteReminders(inList: "groceries")
        )

        // Edited in Reminders after the fetch, renamed, completed, then deleted.
        for change in [
            { (reminder: inout InMemoryShoppingReminderStore.Reminder) in reminder.title = "Milk" },
            { (reminder: inout InMemoryShoppingReminderStore.Reminder) in reminder.notes = "6 · Pancakes\nfree range" },
            { (reminder: inout InMemoryShoppingReminderStore.Reminder) in reminder.isCompleted = true }
        ] {
            let original = store.reminders
            change(&store.reminders[0])
            let changed = store.reminders
            XCTAssertThrowsError(try store.apply(plan, toList: "groceries")) { error in
                XCTAssertEqual(error as? ShoppingReminderError, .listChanged)
            }
            XCTAssertEqual(store.reminders, changed, "Nothing is written when the list has changed")
            store.reminders = original
        }
        store.reminders = []
        XCTAssertThrowsError(try store.apply(plan, toList: "groceries"))

        store.insert(.init(id: "eggs", listID: "groceries", title: "Large eggs", notes: "6 · Pancakes"))
        XCTAssertNoThrow(try store.apply(plan, toList: "groceries"))
        XCTAssertEqual(store.reminders.first?.notes, "6 · Pancakes\n2 · Brownies")
    }

    @MainActor
    func testDeniedRemindersAccessIsReportedWithoutWriting() async throws {
        let store = InMemoryShoppingReminderStore(lists: [.init(id: "groceries", title: "Groceries")], grantsAccessOnRequest: false)
        let granted = try await store.requestAccess()
        XCTAssertFalse(granted)
        XCTAssertEqual(store.access, .denied)
        XCTAssertTrue(store.writableLists().isEmpty)
        XCTAssertTrue(store.reminders.isEmpty)
    }

    func testSubstitutesRequestScalesFromARepairedYield() throws {
        var recipe = SampleRecipe.espressoBrownies
        recipe.recipeYield = .init(servings: 0.009, label: "9 squares")
        let butter = try XCTUnwrap(recipe.ingredients.first { $0.id == "butter" })
        let request = IngredientSubstitutesRequest(ingredient: butter, recipe: recipe, servings: 18, units: .metric)
        XCTAssertEqual(request.displayQuantity, "230 g")
        XCTAssertEqual(request.substitutes.first?.components.first?.quantity?.displayString(), "230 g")
    }

    private static func syncEvent(
        id: UUID = UUID(),
        kind: CloudSyncEvent.Kind,
        endDate: Date?,
        succeeded: Bool = true,
        error: String? = nil
    ) -> CloudSyncEvent {
        CloudSyncEvent(id: id, kind: kind, endDate: endDate, succeeded: endDate != nil && succeeded, errorMessage: error)
    }

    private static func expiredAccessTokens() -> SessionTokens {
        SessionTokens(
            accessToken: "stale-access",
            refreshToken: "stale-refresh",
            accessExpiresAt: Date().addingTimeInterval(-60),
            refreshExpiresAt: Date().addingTimeInterval(86_400)
        )
    }

    private static func tokenBody(access: String, refresh: String) throws -> Data {
        let formatter = ISO8601DateFormatter()
        return try JSONSerialization.data(withJSONObject: [
            "accessToken": access,
            "refreshToken": refresh,
            "accessExpiresAt": formatter.string(from: Date().addingTimeInterval(900)),
            "refreshExpiresAt": formatter.string(from: Date().addingTimeInterval(86_400))
        ])
    }
}

/// Answers the import service's session refresh endpoint without touching the network.
private final class StubSessionProtocol: URLProtocol {
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var delay: TimeInterval = 0
    nonisolated(unsafe) private(set) static var refreshRequestCount = 0
    private static let lock = NSLock()

    static func reset(status: Int, body: Data, delay: TimeInterval = 0) {
        lock.withLock {
            self.status = status
            self.body = body
            self.delay = delay
            refreshRequestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path().hasSuffix("/v1/session/refresh") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body, delay) = Self.lock.withLock {
            Self.refreshRequestCount += 1
            return (Self.status, Self.body, Self.delay)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        // Loading runs on URLSession's own thread, so a short sleep keeps a second caller waiting.
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
