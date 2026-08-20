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

    func testEditorialTimelineSnapshot() {
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

    func testDarkCookModeSnapshot() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        openSampleRecipe(in: app)
        app.buttons["start-cooking"].tap()
        XCTAssertTrue(app.staticTexts["cook-mode-title"].waitForExistence(timeout: 5))
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
        attachScreenshot(named: "recipe-detail-top")

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 3))
        scrollView.swipeUp()
        Thread.sleep(forTimeInterval: 0.75)
        attachScreenshot(named: "recipe-detail-stages")
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
            recipe.tap()
        }
        XCTAssertTrue(startCooking.waitForExistence(timeout: 5))
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
