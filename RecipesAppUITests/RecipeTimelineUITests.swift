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
        let app = launchSampleApp()
        openSampleRecipe(in: app)
        attachScreenshot(named: "timeline")
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
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()
        openSampleRecipe(in: app)
        attachScreenshot(named: "stage-cards-accessibility-text")
    }

    private func launchSampleApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        return app
    }

    private func openSampleRecipe(in app: XCUIApplication) {
        let recipe = app.staticTexts["Espresso Brownies"]
        XCTAssertTrue(recipe.waitForExistence(timeout: 5))
        if !app.buttons["start-cooking"].exists { recipe.tap() }
        XCTAssertTrue(app.buttons["start-cooking"].waitForExistence(timeout: 5))
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
