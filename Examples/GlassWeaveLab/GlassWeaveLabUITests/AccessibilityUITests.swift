import UIKit
import XCTest

/// Accessibility of the laboratory's native content over the custom glass:
/// each native control is one labeled element that activates, the decorative
/// surface adds nothing, the largest text size keeps content and targets,
/// panel text keeps its contrast in light and dark over the moving source,
/// Reduce Motion stops the source, and Reduce Transparency draws the
/// documented opaque surface. Settings come from launch arguments
/// (`-lab.reduceMotion`, `-lab.reduceTransparency`,
/// `-UIPreferredContentSizeCategoryName`, `-lab.appearance`) and
/// `XCUIDevice.appearance`.
final class AccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            XCUIDevice.shared.appearance = .light
        }
        super.tearDown()
    }

    @MainActor
    private func launch(_ arguments: [String] = [], appearance: XCUIDevice.Appearance = .light) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        // The system appearance does not reach the app on every simulator
        // (on the iPad simulator it did not), so the window is also told.
        app.launchArguments += arguments + ["-lab.appearance", appearance == .dark ? "dark" : "light"]
        app.launch()
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        // The appearance can reach the app after launch; wait until the app
        // reports it, so every check runs in the requested appearance.
        let style = appearance == .dark ? "· dark ·" : "· light ·"
        XCTAssertTrue(wait(for: diagnostics, toContain: style), diagnostics.label)
        return app
    }

    @MainActor
    func testNativeControlsAreSingleElementsInReadingOrderAndActivate() throws {
        let app = launch()
        let stage = app.scrollViews["lab.stageScroll"]
        XCTAssertTrue(stage.exists)
        // Each control is one accessible button with a readable label.
        for (identifier, label) in [("lab.customButton", "Custom action"), ("lab.nativeButton", "Native action")] {
            let matches = app.buttons.matching(identifier: identifier)
            XCTAssertEqual(matches.count, 1, identifier)
            XCTAssertEqual(matches.firstMatch.label, label)
            XCTAssertTrue(matches.firstMatch.isHittable, identifier)
        }
        // The decorative surface is not in the accessibility tree at all
        // (its elements are hidden), although the stage it fills is.
        XCTAssertTrue(app.otherElements["lab.stage"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["lab.customSurface"].exists)
        // Order: the stage's content is one vertical stack (panel title,
        // panel button, reference caption, reference button), so the
        // container order UIKit offers assistive technologies matches the
        // top-to-bottom order checked here. (XCUITest lists descendants
        // breadth first, so their index is not the reading order.)
        let ordered = [
            app.staticTexts["Custom GlassWeave"], app.buttons["lab.customButton"],
            app.staticTexts["Native reference"], app.buttons["lab.nativeButton"],
        ].map(\.frame.midY)
        XCTAssertEqual(ordered, ordered.sorted(), "\(ordered)")
        // Activating each control acts once.
        app.buttons["lab.customButton"].tap()
        app.buttons["lab.nativeButton"].tap()
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(wait(for: diagnostics, toContain: "Custom taps: 1\n"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 1 ·"), diagnostics.label)
    }

    /// Xcode's accessibility audit, with the source paused so every
    /// screenshot the audit takes shows the same frame.
    @MainActor
    func testAccessibilityAuditInLight() throws {
        try audit(in: .light)
    }

    /// The same audit in the dark system appearance. The audit's contrast
    /// check follows the system appearance, so the window override is not
    /// used here; where the simulator does not pass `XCUIDevice.appearance`
    /// to the app (seen on the iPad simulator), the test is skipped and the
    /// dark audit is run with the simulator itself set to dark.
    @MainActor
    func testAccessibilityAuditInDark() throws {
        try audit(in: .dark)
    }

    @MainActor
    private func audit(in appearance: XCUIDevice.Appearance) throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        app.launch()
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        let style = appearance == .dark ? "· dark ·" : "· light ·"
        guard wait(for: diagnostics, toContain: style) else {
            throw XCTSkip("The system appearance \(style) did not reach the app on this simulator: \(diagnostics.label)")
        }
        app.buttons["lab.pause"].tap()
        var reported: [String] = []
        try app.performAccessibilityAudit { issue in
            // Collected and reported below with the element, so a failure
            // names what failed.
            reported.append("\(issue.compactDescription): \(issue.detailedDescription) element: \(issue.element?.debugDescription ?? "none")")
            return true
        }
        XCTAssertTrue(reported.isEmpty, "\(style): \(reported)")
    }

    @MainActor
    func testLargestTextSizeKeepsContentAndTargets() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
            XCUIDevice.shared.orientation = orientation
            let diagnostics = app.staticTexts["lab.diagnostics"]
            XCTAssertTrue(wait(for: diagnostics, toContain: "text AccessibilityXXXL"), diagnostics.label)
            let panel = app.otherElements["lab.customPanel"]
            let title = app.staticTexts["Custom GlassWeave"]
            let custom = app.buttons["lab.customButton"]
            let native = app.buttons["lab.nativeButton"]
            // Content is present, whole, and inside the glass panel.
            XCTAssertTrue(title.exists)
            XCTAssertEqual(title.label, "Custom GlassWeave")
            XCTAssertTrue(panel.frame.contains(title.frame), "\(panel.frame) \(title.frame)")
            XCTAssertTrue(panel.frame.contains(custom.frame), "\(panel.frame) \(custom.frame)")
            // Targets grow with the text and stay at least 44 points.
            for button in [custom, native] {
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            }
            XCTAssertGreaterThan(custom.frame.height, 60, "The custom button's text did not grow")
            // Both controls act; the stage scrolls them into reach if needed.
            custom.tap()
            native.tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "Custom taps: 1\n"), diagnostics.label)
            XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 1 ·"), diagnostics.label)
            // After scrolling, the glass panel still encloses the button.
            XCTAssertTrue(panel.frame.contains(custom.frame), "\(panel.frame) \(custom.frame)")
            try app.performAccessibilityAudit(for: [.dynamicType, .textClipped]) { issue in
                XCTFail("\(orientation.rawValue): \(issue.compactDescription): \(issue.element?.debugDescription ?? "no element")")
                return true
            }
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testReduceMotionStopsTheMovingSource() throws {
        let app = launch(["-lab.reduceMotion", "YES"])
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(wait(for: diagnostics, toContain: "Clock: paused (Reduce Motion) · t 0.00 s"), diagnostics.label)
        XCTAssertTrue(diagnostics.label.contains("Reduce Motion on"), diagnostics.label)
        // A static frame was drawn, and nothing more is submitted.
        let native = app.buttons["lab.nativeButton"]
        native.tap()
        let first = try LabDiagnostics(diagnostics.label)
        XCTAssertGreaterThanOrEqual(first.submitted, 1)
        Thread.sleep(forTimeInterval: 2)
        native.tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 2 ·"), diagnostics.label)
        XCTAssertEqual(try LabDiagnostics(diagnostics.label).submitted, first.submitted, diagnostics.label)
        XCTAssertTrue(diagnostics.label.contains("t 0.00 s"), diagnostics.label)
        // Pause and resume keep the clock stopped while Reduce Motion is on.
        app.buttons["lab.pause"].tap()
        app.buttons["lab.pause"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Clock: paused (Reduce Motion)"), diagnostics.label)
        app.buttons["lab.customButton"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Custom taps: 1\n"), diagnostics.label)
    }

    /// Under Reduce Transparency the panel is one opaque color, the system's
    /// secondary background, whatever moves behind it; the controls still act.
    @MainActor
    func testReduceTransparencyDrawsTheDocumentedOpaqueSurface() throws {
        // secondarySystemBackground in sRGB.
        let expected: [(XCUIDevice.Appearance, (Int, Int, Int))] = [(.light, (242, 242, 247)), (.dark, (28, 28, 30))]
        for (appearance, color) in expected {
            let app = launch(["-lab.reduceTransparency", "YES"], appearance: appearance)
            let diagnostics = app.staticTexts["lab.diagnostics"]
            XCTAssertTrue(wait(for: diagnostics, toContain: "Panel: opaque (Reduce Transparency) · tint 1.00"), diagnostics.label)
            XCTAssertTrue(wait(for: diagnostics, toContain: "Clock: running"), diagnostics.label)
            for _ in 0..<3 {
                let samples = try panelInteriorSamples(app)
                XCTAssertGreaterThan(samples.count, 20)
                for (x, y, sample) in samples {
                    let difference = max(abs(sample.0 - color.0), abs(sample.1 - color.1), abs(sample.2 - color.2))
                    XCTAssertLessThanOrEqual(difference, 3, "\(appearance.rawValue) (\(x), \(y)): \(sample)")
                }
                Thread.sleep(forTimeInterval: 0.4)
            }
            app.buttons["lab.customButton"].tap()
            app.buttons["lab.nativeButton"].tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "Custom taps: 1\n"), diagnostics.label)
            XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 1 ·"), diagnostics.label)
            app.terminate()
        }
    }

    /// Light and dark glass: over the moving source, every sampled panel
    /// pixel keeps at least 4.5:1 against the label color (black in light,
    /// white in dark).
    @MainActor
    func testPanelTextKeepsContrastOverTheMovingSource() throws {
        for (appearance, textLuminance) in [(XCUIDevice.Appearance.light, 0.0), (.dark, 1.0)] {
            let app = launch(appearance: appearance)
            let diagnostics = app.staticTexts["lab.diagnostics"]
            XCTAssertTrue(wait(for: diagnostics, toContain: "Clock: running"), diagnostics.label)
            var worst = Double.infinity
            var count = 0
            for _ in 0..<5 {
                for (_, _, sample) in try panelInteriorSamples(app) {
                    let luminance = Self.relativeLuminance(sample)
                    worst = min(worst, (max(luminance, textLuminance) + 0.05) / (min(luminance, textLuminance) + 0.05))
                    count += 1
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            XCTAssertGreaterThan(count, 100)
            XCTAssertGreaterThanOrEqual(worst, 4.5, "\(appearance.rawValue): worst sampled contrast \(worst)")
            let summary = XCTAttachment(string: "appearance \(appearance == .dark ? "dark" : "light"): \(count) panel samples over 5 screenshots, worst contrast against the label color \(String(format: "%.2f", worst)):1")
            summary.name = "panel-contrast-\(appearance == .dark ? "dark" : "light").txt"
            summary.lifetime = .keepAlways
            add(summary)
            app.terminate()
        }
    }

    // MARK: Helpers

    /// sRGB pixels sampled across the panel interior: inside the 22-point
    /// rim, away from the title, the button, and the frame-ID strip.
    @MainActor
    private func panelInteriorSamples(_ app: XCUIApplication) throws -> [(Double, Double, (Int, Int, Int))] {
        let panel = app.otherElements["lab.customPanel"].frame
        let avoid = [app.staticTexts["Custom GlassWeave"].frame, app.buttons["lab.customButton"].frame]
            .map { $0.insetBy(dx: -4, dy: -4) }
        let stripY = panel.maxY - 34
        let screenshot = app.screenshot().image
        let pixels = try SRGBPixels(screenshot)
        let scale = Double(pixels.width) / Double(app.windows.firstMatch.frame.width)
        let interior = panel.insetBy(dx: 26, dy: 26)
        var samples: [(Double, Double, (Int, Int, Int))] = []
        for row in 0...10 {
            for column in 0...10 {
                let point = CGPoint(
                    x: interior.minX + interior.width * CGFloat(column) / 10,
                    y: interior.minY + interior.height * CGFloat(row) / 10
                )
                guard !avoid.contains(where: { $0.contains(point) }), abs(point.y - stripY) > 10 else { continue }
                samples.append((point.x, point.y, pixels.color(x: Int(point.x * scale), y: Int(point.y * scale))))
            }
        }
        return samples
    }

    private static func relativeLuminance(_ color: (Int, Int, Int)) -> Double {
        func linear(_ value: Int) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.0) + 0.7152 * linear(color.1) + 0.0722 * linear(color.2)
    }

    @MainActor
    private func wait(for element: XCUIElement, toContain text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }
}

private extension Array where Element: Equatable {
    func removingAdjacentDuplicates() -> [Element] {
        reduce(into: []) { result, element in
            if result.last != element { result.append(element) }
        }
    }
}
