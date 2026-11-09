import UIKit
import XCTest

/// GW-19 in the laboratory: `-lab.interior <name>` gives the custom panel an
/// animated interior. Over the still pattern nothing else animates, so every
/// frame submitted while the interior moves comes from the surface's own
/// effect clock (a `UIUpdateLink` for the surface's window). The diagnostics
/// count what the surface submitted while moving, after the Interior motion
/// switch stills it, while the stage is hidden, while the app is in the
/// background, and under Reduce Motion; screenshots of the still frame show
/// that the interior draws only inside the panel.
final class InteriorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> (XCUIApplication, XCUIElement) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        return (app, diagnostics)
    }

    /// A fresh count. The diagnostics refresh on draws and actions; tapping
    /// the native button requests no frame but refreshes them.
    @MainActor
    private func freshCount(_ app: XCUIApplication, _ diagnostics: XCUIElement) throws -> LabDiagnostics {
        let before = diagnostics.label
        app.buttons["lab.nativeButton"].tap()
        return try waitForDiagnostics(diagnostics) { _ in diagnostics.label != before }
    }

    @MainActor
    private func wait(for element: XCUIElement, toContain text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }

    @MainActor
    func testTheInteriorDrawsOnlyWhileItMovesAndTheSurfaceIsVisible() throws {
        let (app, diagnostics) = launch(["-lab.interior", "embers", "-lab.source", "pattern"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Interior: embers · 3 colors · intensity 0.90 · speed 1.00 · seed 11 · fade 1.00 · effect clock running"), diagnostics.label)
        var report: [String] = []

        // Moving: frames at the display's pace, never more than two in flight.
        let start = try freshCount(app, diagnostics)
        Thread.sleep(forTimeInterval: 2)
        let moving = try freshCount(app, diagnostics)
        let movingFrames = moving.submitted - start.submitted
        report.append("moving: \(movingFrames) frames in about 2 s, peak in flight \(moving.peakFramesInFlight) of \(moving.maximumFramesInFlight)")
        XCTAssertGreaterThanOrEqual(movingFrames, 40, diagnostics.label)
        XCTAssertLessThanOrEqual(moving.peakFramesInFlight, moving.maximumFramesInFlight)

        // Still: the still frame is drawn once, then nothing.
        let motionSwitch = app.switches["lab.interiorMotion"]
        motionSwitch.tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "speed 0.00 · seed 11 · fade 1.00 · effect clock stopped"), diagnostics.label)
        Thread.sleep(forTimeInterval: 0.5)
        let settled = try freshCount(app, diagnostics)
        Thread.sleep(forTimeInterval: 2)
        let stillSettled = try freshCount(app, diagnostics)
        report.append("still: \(stillSettled.submitted - settled.submitted) frames in about 2 s")
        XCTAssertEqual(stillSettled.submitted, settled.submitted, "A still interior kept submitting: \(diagnostics.label)")

        // Moving again, then the stage hidden: the clock stops and the hidden
        // period submits nothing.
        motionSwitch.tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "effect clock running"), diagnostics.label)
        let stageSwitch = app.switches["lab.stageVisible"]
        stageSwitch.tap()
        try waitForDiagnostics(diagnostics) { !$0.surfaceVisible }
        XCTAssertTrue(wait(for: diagnostics, toContain: "effect clock stopped"), diagnostics.label)
        Thread.sleep(forTimeInterval: 2)
        stageSwitch.tap()
        let shown = try waitForDiagnostics(diagnostics) { $0.surfaceVisible }
        report.append("hidden stage: \(shown.hiddenPeriodSubmissions.map(String.init) ?? "?") frames")
        XCTAssertEqual(shown.hiddenPeriodSubmissions, 0, diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "effect clock running"), diagnostics.label)

        // Backgrounded: nothing is submitted until the scene returns, and the
        // interior moves again.
        let beforeBackground = try freshCount(app, diagnostics)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        let back = try waitForDiagnostics(diagnostics) {
            $0.surfaceVisible && $0.sceneState == "active" && $0.submitted > beforeBackground.submitted
        }
        report.append("background: \(back.hiddenPeriodSubmissions.map(String.init) ?? "?") frames")
        XCTAssertEqual(back.hiddenPeriodSubmissions, 0, diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "effect clock running"), diagnostics.label)
        let final = try freshCount(app, diagnostics)
        XCTAssertLessThanOrEqual(final.peakFramesInFlight, final.maximumFramesInFlight)

        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "interior-submissions.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Under Reduce Motion the interior is its still frame (speed 0) and the
    /// surface submits nothing once it has drawn it.
    @MainActor
    func testReduceMotionShowsTheStillFrameAndSubmitsNothing() throws {
        let (app, diagnostics) = launch(["-lab.interior", "energy", "-lab.source", "pattern", "-lab.reduceMotion", "YES"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Reduce Motion on"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Interior: energy · 3 colors · intensity 0.85 · speed 0.00 · seed 7 · fade 1.00 · effect clock stopped"), diagnostics.label)
        try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.submitted >= 1 }
        Thread.sleep(forTimeInterval: 0.5)
        let settled = try freshCount(app, diagnostics)
        Thread.sleep(forTimeInterval: 2)
        let later = try freshCount(app, diagnostics)
        XCTAssertEqual(later.submitted, settled.submitted, "A still interior kept submitting: \(diagnostics.label)")
    }

    /// Under Reduce Transparency the interior is not drawn and nothing runs.
    @MainActor
    func testReduceTransparencyRemovesTheInterior() throws {
        let (app, diagnostics) = launch(["-lab.interior", "rays", "-lab.source", "pattern", "-lab.reduceTransparency", "YES"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Interior: rays · not drawn · effect clock stopped"), diagnostics.label)
        try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.submitted >= 1 }
        Thread.sleep(forTimeInterval: 0.5)
        let settled = try freshCount(app, diagnostics)
        Thread.sleep(forTimeInterval: 2)
        let later = try freshCount(app, diagnostics)
        XCTAssertEqual(later.submitted, settled.submitted, diagnostics.label)
    }

    /// A screenshot of the still frame (Reduce Motion, over the still
    /// pattern) and the custom panel's frame.
    @MainActor
    private func stillScreenshot(interior: String?) throws -> (pixels: SRGBPixels, panel: CGRect, scale: Double) {
        var arguments = ["-lab.source", "pattern", "-lab.reduceMotion", "YES", "-lab.appearance", "dark"]
        if let interior { arguments += ["-lab.interior", interior] }
        let (app, diagnostics) = launch(arguments)
        XCTAssertTrue(wait(for: diagnostics, toContain: "· dark ·"), diagnostics.label)
        try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.submitted >= 1 }
        if let interior {
            XCTAssertTrue(wait(for: diagnostics, toContain: "Interior: \(interior) · 3 colors"), diagnostics.label)
        }
        Thread.sleep(forTimeInterval: 1)
        let panel = app.otherElements["lab.customPanel"].frame
        let pixels = try SRGBPixels(app.screenshot().image)
        let scale = Double(pixels.width) / Double(app.windows.firstMatch.frame.width)
        app.terminate()
        return (pixels, panel, scale)
    }

    /// Each interior lights the inside of the panel, leaves the band around
    /// it unchanged (no glow here, so no halo for sparks to rise into), and
    /// leaves the middle, deeper than 85 % of half the shorter side, as it
    /// is without an interior (the documented center fade).
    @MainActor
    func testEachInteriorDrawsOnlyInsideThePanelAndKeepsTheMiddleClear() throws {
        let plain = try stillScreenshot(interior: nil)
        var report: [String] = []
        for interior in ["energy", "rays", "embers"] {
            let lit = try stillScreenshot(interior: interior)
            XCTAssertEqual(lit.panel, plain.panel)
            let panel = lit.panel, scale = lit.scale
            let halfShort = Double(min(panel.width, panel.height)) / 2
            var insideChanged = 0, bandWorst = 0, middleWorst = 0, bandPixels = 0, middlePixels = 0
            for py in stride(from: Int((Double(panel.minY) - 16) * scale), to: Int((Double(panel.maxY) + 16) * scale), by: 1) {
                for px in stride(from: Int((Double(panel.minX) - 16) * scale), to: Int((Double(panel.maxX) + 16) * scale), by: 1) {
                    let x = (Double(px) + 0.5) / scale, y = (Double(py) + 0.5) / scale
                    let a = lit.pixels.color(x: px, y: py), b = plain.pixels.color(x: px, y: py)
                    let difference = max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
                    let depth = Self.depth(x: x, y: y, panel: panel, cornerRadius: 30)
                    if depth < -2 {
                        bandPixels += 1
                        bandWorst = max(bandWorst, difference)
                    } else if depth > 0.85 * halfShort {
                        middlePixels += 1
                        middleWorst = max(middleWorst, difference)
                    } else if depth > 1, difference > 8 {
                        insideChanged += 1
                    }
                }
            }
            report.append("\(interior): \(insideChanged) inside pixels changed by more than 8 steps; band \(bandPixels) pixels, worst \(bandWorst); middle \(middlePixels) pixels, worst \(middleWorst)")
            XCTAssertGreaterThan(insideChanged, 2000, report.last!)
            XCTAssertLessThanOrEqual(bandWorst, 2, report.last!)
            XCTAssertLessThanOrEqual(middleWorst, 2, report.last!)
            XCTAssertGreaterThan(middlePixels, 1000, report.last!)
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "interior-bounds.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Depth of a point below a rounded rectangle's outline, in points
    /// (negative outside).
    private static func depth(x: Double, y: Double, panel: CGRect, cornerRadius: Double) -> Double {
        let radius = min(cornerRadius, Double(min(panel.width, panel.height)) / 2)
        let q = SIMD2(abs(x - Double(panel.midX)), abs(y - Double(panel.midY)))
        let d = q - (SIMD2(Double(panel.width) / 2, Double(panel.height) / 2) - radius)
        let outside = SIMD2(max(d.x, 0), max(d.y, 0))
        return -((outside.x * outside.x + outside.y * outside.y).squareRoot() + min(max(d.x, d.y), 0) - radius)
    }
}
