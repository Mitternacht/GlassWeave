import XCTest

/// The native reference region: a real UIButton inside genuine Apple glass
/// over a moving backdrop, with tint and enabled controls that Reset restores.
final class NativeReferenceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNativeGlassButtonIsActionableAndResetRestoresTintAndEnabledState() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        let button = app.buttons["lab.nativeButton"]
        let diagnostics = app.staticTexts["lab.diagnostics"]
        let tint = app.segmentedControls["lab.nativeTint"]
        let enabled = app.switches["lab.nativeEnabled"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(diagnostics.label.contains("Native taps: 0 · tint none · enabled"), diagnostics.label)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.isHittable)

        // The control works while the backdrop moves behind the glass.
        button.tap()
        button.tap()
        XCTAssertTrue(diagnostics.label.contains("Native taps: 2 · tint none · enabled"), diagnostics.label)

        // Change the comparison state: tint the glass and disable the control.
        tint.buttons["Blue"].tap()
        XCTAssertTrue(diagnostics.label.contains("tint blue"), diagnostics.label)
        enabled.tap()
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(diagnostics.label.contains("Native taps: 2 · tint blue · disabled"), diagnostics.label)
        button.tap()
        XCTAssertTrue(diagnostics.label.contains("Native taps: 2 ·"), "A disabled control must not act: \(diagnostics.label)")

        // Reset restores untinted, enabled glass and a zero count.
        app.buttons["lab.reset"].tap()
        XCTAssertTrue(diagnostics.label.contains("Native taps: 0 · tint none · enabled"), diagnostics.label)
        XCTAssertTrue(tint.buttons["None"].isSelected)
        XCTAssertEqual(enabled.value as? String, "1")
        XCTAssertTrue(button.isEnabled)
        button.tap()
        XCTAssertTrue(diagnostics.label.contains("Native taps: 1 · tint none · enabled"), diagnostics.label)

        // Repeating the cycle gives the same starting state.
        tint.buttons["Orange"].tap()
        enabled.tap()
        app.buttons["lab.reset"].tap()
        XCTAssertTrue(diagnostics.label.contains("Native taps: 0 · tint none · enabled"), diagnostics.label)
    }
}
