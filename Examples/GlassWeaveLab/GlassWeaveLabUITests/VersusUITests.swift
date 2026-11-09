import UIKit
import XCTest

/// GW-29a: the Apple vs GlassWeave screen. `-lab.versus YES` opens it at
/// launch; `-lab.versusAnimate NO` keeps the interiors still.
final class VersusUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .portrait
        }
        super.tearDown()
    }

    /// The screen opens and shows both halves with the same layout, and its
    /// own hierarchy check (it walks the live view tree) finds
    /// `UIGlassEffect` views and no GlassWeave surface in the native half, one
    /// GlassWeave surface in the other, and both clipped at the divider.
    @MainActor
    func testTheVersusScreenShowsBothHalvesAndTheNativeHalfHoldsNoGlassWeaveSurface() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-lab.versus", "YES", "-lab.appearance", "light", "-lab.versusAnimate", "NO"]
        app.launch()

        let diagnostics = app.staticTexts["versus.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        // Both halves are there: the first row's native control in each, side
        // by side on either side of the divider, at the same height and size.
        let native = app.buttons["versus.native.hues"]
        let weave = app.buttons["versus.weave.hues"]
        XCTAssertTrue(native.waitForExistence(timeout: 10))
        XCTAssertTrue(weave.exists)
        XCTAssertEqual(native.label, "Hues inside the glass, Apple glass")
        XCTAssertEqual(weave.label, "Hues inside the glass, GlassWeave glass")
        let middle = app.windows.firstMatch.frame.midX
        XCTAssertLessThanOrEqual(native.frame.maxX, middle)
        XCTAssertGreaterThanOrEqual(weave.frame.minX, middle)
        XCTAssertEqual(native.frame.minY, weave.frame.minY, accuracy: 1)
        XCTAssertEqual(native.frame.width, weave.frame.width, accuracy: 1)
        XCTAssertEqual(native.frame.height, weave.frame.height, accuracy: 1)

        // The hierarchy check, once the screen has drawn.
        let nativeLine = #"Native half: [1-9]\d* UIGlassEffect views? · 0 GlassWeave surfaces · clipped at the divider yes"#
        let weaveLine = #"GlassWeave half: 1 surface · \d+ of \d+ panels in view · 0 UIGlassEffect views · clipped at the divider yes"#
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline,
              diagnostics.label.range(of: weaveLine, options: .regularExpression) == nil {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertNotNil(diagnostics.label.range(of: nativeLine, options: .regularExpression), diagnostics.label)
        XCTAssertNotNil(diagnostics.label.range(of: weaveLine, options: .regularExpression), diagnostics.label)
        XCTAssertFalse(diagnostics.label.contains("NO"), diagnostics.label)
    }
}
