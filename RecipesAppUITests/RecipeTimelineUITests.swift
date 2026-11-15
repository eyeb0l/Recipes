import XCTest

@MainActor
final class RecipeTimelineUITests: XCTestCase {
    func testSampleRecipeOpensAndStartsCookMode() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let recipe = app.staticTexts["Espresso Brownies"]
        XCTAssertTrue(recipe.waitForExistence(timeout: 5))
        if app.buttons["start-cooking"].exists == false { recipe.tap() }

        let start = app.buttons["start-cooking"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        start.tap()
        let cookModeAppeared = app.staticTexts["cook-mode-title"].waitForExistence(timeout: 5)
        XCTAssertTrue(cookModeAppeared)
        let completeExists = app.buttons["complete-stage"].exists
        XCTAssertTrue(completeExists)
    }

    func testEditorialTimelineSnapshot() throws {
        // The editorial grid is the regular-width layout; iPhones show focused step cards instead.
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The timeline grid needs a regular-width iPad window.")
        useLandscapeOrientation()
        let app = launchSampleApp()
        openSampleRecipe(in: app)
        attachScreenshot(named: "timeline")

        let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.58))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.58))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)

        let finalStage = app.descendants(matching: .any)["timeline-stage-bake"]
        XCTAssertTrue(finalStage.waitForExistence(timeout: 3))
        XCTAssertTrue(finalStage.isHittable)
        XCTAssertLessThanOrEqual(finalStage.frame.maxX, app.windows.firstMatch.frame.maxX - 8)
        attachScreenshot(named: "timeline-tail")
    }

    func testDarkCookModeSnapshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-dark"]
        app.launch()
        openSampleRecipe(in: app)
        app.buttons["start-cooking"].tap()
        XCTAssertTrue(app.staticTexts["cook-mode-title"].waitForExistence(timeout: 5))

        let screenshot = XCUIScreen.main.screenshot()
        // The page margin shows the paper colour, which is near-black in dark mode and cream in light mode.
        let margin = try XCTUnwrap(luminance(of: screenshot.image, at: CGPoint(x: 0.015, y: 0.5)))
        XCTAssertLessThan(margin, 0.2, "Cook mode should render with the dark palette")
        attachScreenshot(named: "cook-mode-dark")
    }

    func testLargeTextStageCardsSnapshot() {
        useLandscapeOrientation()
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        openSampleRecipe(in: app)
        XCTAssertTrue(app.staticTexts["115 g"].waitForExistence(timeout: 3))
        attachScreenshot(named: "stage-cards-accessibility-text")
    }

    func testEmptyLibrarySnapshot() {
        useLandscapeOrientation()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-empty-library"]
        app.launch()

        let detailEmptyState = app.staticTexts["Choose a recipe"]
        let compactEmptyState = app.staticTexts["Your cookbook is empty"]
        let emptyStateAppeared =
            detailEmptyState.waitForExistence(timeout: 5)
            || compactEmptyState.waitForExistence(timeout: 2)
        XCTAssertTrue(emptyStateAppeared)
        attachScreenshot(named: "library-empty-state")
    }

    func testRecipeDetailSnapshots() {
        let app = launchSampleApp()
        openSampleRecipe(in: app)

        let startCooking = app.buttons["start-cooking"]
        let window = app.windows.firstMatch
        XCTAssertGreaterThanOrEqual(startCooking.frame.height, 44)
        XCTAssertLessThan(startCooking.frame.width, window.frame.width * 0.75)
        attachScreenshot(named: "recipe-detail-top")

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 3))
        scrollView.swipeUp()
        Thread.sleep(forTimeInterval: 0.75)
        attachScreenshot(named: "recipe-detail-stages")
    }

    func testMalformedImportedYieldRecoversBeforeServingAdjustment() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-malformed-yield"]
        app.launch()
        openSampleRecipe(in: app)

        let increment = app.buttons["servings-control-Increment"]
        XCTAssertTrue(increment.waitForExistence(timeout: 3))
        XCTAssertEqual(increment.value as? String, "9")
        XCTAssertTrue(increment.isHittable)
        increment.tap()
        XCTAssertEqual(increment.value as? String, "10")
        XCTAssertTrue(app.staticTexts["127.78 g"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["127.78 kg"].exists)
    }

    func testRecipeExportOffersAllSupportedFormats() {
        let app = launchSampleApp()
        openSampleRecipe(in: app)

        let export = app.buttons["export-recipe"]
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        export.tap()

        XCTAssertTrue(app.navigationBars["Export recipe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["export-pdf"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["export-xlsx"].exists)
        XCTAssertTrue(app.buttons["export-png"].exists)
    }

    func testChoosePhotosOpensPhotoPickerInsteadOfDocumentScanner() {
        let app = launchSampleApp()

        let importRecipe = app.buttons["import-recipe"]
        XCTAssertTrue(importRecipe.waitForExistence(timeout: 5))
        importRecipe.tap()

        XCTAssertTrue(app.navigationBars["Import recipe"].waitForExistence(timeout: 5))
        let scanPagesSource = app.segmentedControls.buttons["Scan pages"]
        XCTAssertTrue(scanPagesSource.waitForExistence(timeout: 3))
        scanPagesSource.tap()

        let scanPages = app.buttons["scan-pages"]
        let choosePhotos = app.buttons["choose-photos"]
        let chooseFiles = app.buttons["choose-files"]
        XCTAssertTrue(scanPages.waitForExistence(timeout: 5))
        XCTAssertTrue(choosePhotos.waitForExistence(timeout: 5))
        XCTAssertTrue(chooseFiles.waitForExistence(timeout: 5))
        XCTAssertEqual(scanPages.frame.width, choosePhotos.frame.width, accuracy: 2)
        XCTAssertEqual(scanPages.frame.midY, choosePhotos.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(scanPages.frame.height, 44)
        XCTAssertGreaterThanOrEqual(choosePhotos.frame.height, 44)
        XCTAssertGreaterThanOrEqual(chooseFiles.frame.height, 44)
        XCTAssertGreaterThan(chooseFiles.frame.width, choosePhotos.frame.width * 1.8)
        XCTAssertGreaterThan(chooseFiles.frame.minY, choosePhotos.frame.maxY)
        choosePhotos.tap()

        XCTAssertFalse(app.staticTexts["Position the document in view."].waitForExistence(timeout: 2))
        XCTAssertFalse(choosePhotos.isHittable)
        let pickerHeading = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Select up to")
        ).firstMatch
        let photoPickerAppeared =
            pickerHeading.waitForExistence(timeout: 5)
            || app.buttons["Select Photos"].waitForExistence(timeout: 2)
            || app.staticTexts["Select Photos"].waitForExistence(timeout: 2)
        XCTAssertTrue(photoPickerAppeared)
    }

    func testResumingKeepsTheServingsChosenWhenCookingStarted() {
        let app = launchSampleApp()
        openSampleRecipe(in: app)

        let increment = app.buttons["servings-control-Increment"]
        XCTAssertTrue(increment.waitForExistence(timeout: 3))
        let startingServings = Int(increment.value as? String ?? "") ?? 9
        increment.tap()
        let chosen = "\(startingServings + 1)"
        XCTAssertEqual(increment.value as? String, chosen)

        app.buttons["start-cooking"].tap()
        XCTAssertTrue(app.staticTexts["cook-mode-title"].waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()

        // Leave and reopen the recipe so the detail view loads from scratch.
        let back = app.navigationBars.buttons["Recipes"]
        if back.waitForExistence(timeout: 2) { back.tap() }
        openSampleRecipe(in: app)
        XCTAssertTrue(increment.waitForExistence(timeout: 3))
        XCTAssertEqual(increment.value as? String, chosen)

        app.buttons["start-cooking"].tap()
        XCTAssertTrue(app.staticTexts["cook-mode-title"].waitForExistence(timeout: 5))
        let scale = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "\(chosen) servings"))
            .firstMatch
        XCTAssertTrue(scale.waitForExistence(timeout: 3))

        // Leave no active session behind for other tests.
        app.buttons["end-cooking"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "End cooking")).element(boundBy: 1)
        if confirm.waitForExistence(timeout: 3) { confirm.tap() } else { app.buttons["End cooking"].firstMatch.tap() }
        XCTAssertFalse(app.staticTexts["cook-mode-title"].waitForExistence(timeout: 2))
    }

    func testLaunchingWithRealStorageDoesNotCrash() {
        // Without `--ui-testing` the app uses its real recipe store, as it does when iOS launches it
        // in the background. Unsigned builds used to trap a few seconds later while setting up CloudKit.
        let app = XCUIApplication()
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let storage = app.staticTexts["Storage"]
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        attachScreenshot(named: "settings-real-storage")

        XCTAssertFalse(app.wait(for: .notRunning, timeout: 10), "The app quit while setting up recipe storage")
    }

    private func launchSampleApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        return app
    }

    private func useLandscapeOrientation() {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    private func openSampleRecipe(in app: XCUIApplication) {
        let startCooking = app.buttons["start-cooking"]
        if !startCooking.exists {
            let recipe = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Espresso Brownies")
            ).firstMatch
            XCTAssertTrue(recipe.waitForExistence(timeout: 5))
            // Tap the title area: on a landscape iPhone with very large text, the floating search
            // field can cover the middle of the row.
            recipe.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }
        XCTAssertTrue(startCooking.waitForExistence(timeout: 5))
    }

    /// Relative luminance (0–1) of the pixel at a normalised point in an image.
    private func luminance(of image: UIImage, at point: CGPoint) -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        let x = Int(Double(cgImage.width - 1) * point.x)
        let y = Int(Double(cgImage.height - 1) * point.y)
        guard let pixel = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &rgba,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(rgba[0]) + 0.7152 * Double(rgba[1]) + 0.0722 * Double(rgba[2])) / 255
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
