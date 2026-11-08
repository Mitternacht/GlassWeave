import XCTest

final class GlassWeaveLabUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsBothRegionsAndResetIsRepeatable() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Native reference"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Custom GlassWeave"].exists)

        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(diagnostics.exists)
        XCTAssertTrue(diagnostics.label.contains("Resets: 1"), diagnostics.label)

        app.buttons["lab.reset"].tap()
        XCTAssertTrue(diagnostics.label.contains("Resets: 2"), diagnostics.label)
        app.buttons["lab.reset"].tap()
        XCTAssertTrue(diagnostics.label.contains("Resets: 3"), diagnostics.label)
    }
}
