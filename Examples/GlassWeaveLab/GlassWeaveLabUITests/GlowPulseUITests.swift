import XCTest

/// GW-18 in the laboratory: `-lab.glow energy` gives the custom panel a halo
/// and a pulse. Over the still pattern nothing else animates, so every frame
/// submitted while the glow pulses comes from the surface's own effect clock
/// (a `UIUpdateLink` for the surface's window). The diagnostics count what
/// the surface submitted while pulsing, after the Pulse switch settles the
/// glow, while the stage is hidden, while the app is in the background, and
/// under Reduce Motion.
final class GlowPulseUITests: XCTestCase {
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
    func testThePulseDrawsOnlyWhileItRunsAndTheSurfaceIsVisible() throws {
        let (app, diagnostics) = launch(["-lab.glow", "energy", "-lab.source", "pattern"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Halo: 28 pt · 0.90 · pulse 1.8 s × 0.55 · effect clock running"), diagnostics.label)
        var report: [String] = []

        // Pulsing: frames at the display's pace, never more than two in
        // flight.
        let start = try freshCount(app, diagnostics)
        Thread.sleep(forTimeInterval: 2)
        let pulsing = try freshCount(app, diagnostics)
        let pulsingFrames = pulsing.submitted - start.submitted
        report.append("pulsing: \(pulsingFrames) frames in about 2 s, peak in flight \(pulsing.peakFramesInFlight) of \(pulsing.maximumFramesInFlight)")
        XCTAssertGreaterThanOrEqual(pulsingFrames, 40, diagnostics.label)
        XCTAssertLessThanOrEqual(pulsing.peakFramesInFlight, pulsing.maximumFramesInFlight)

        // Settled: without the pulse the steady glow is drawn once, then
        // nothing.
        let pulseSwitch = app.switches["lab.glowPulse"]
        pulseSwitch.tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "no pulse · effect clock stopped"), diagnostics.label)
        Thread.sleep(forTimeInterval: 0.5)
        let settled = try freshCount(app, diagnostics)
        Thread.sleep(forTimeInterval: 2)
        let stillSettled = try freshCount(app, diagnostics)
        report.append("settled: \(stillSettled.submitted - settled.submitted) frames in about 2 s")
        XCTAssertEqual(stillSettled.submitted, settled.submitted, "A settled glow kept submitting: \(diagnostics.label)")

        // Pulsing again, then the stage hidden: the clock stops and the
        // hidden period submits nothing.
        pulseSwitch.tap()
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

        // Backgrounded: the scene leaves the foreground; nothing is
        // submitted until it returns, and the pulse resumes.
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
        attachment.name = "glow-pulse-submissions.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Under Reduce Motion the glow is steady at the pulse's mean level
    /// (halo 0.90 × (1 − 0.55 / 2) = 0.65) and the surface submits nothing
    /// once it has drawn it.
    @MainActor
    func testReduceMotionShowsASteadyGlowAndSubmitsNothing() throws {
        let (app, diagnostics) = launch(["-lab.glow", "energy", "-lab.source", "pattern", "-lab.reduceMotion", "YES"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Reduce Motion on"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Halo: 28 pt · 0.65 · no pulse · effect clock stopped"), diagnostics.label)
        try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.submitted >= 1 }
        Thread.sleep(forTimeInterval: 0.5)
        let settled = try freshCount(app, diagnostics)
        Thread.sleep(forTimeInterval: 2)
        let later = try freshCount(app, diagnostics)
        XCTAssertEqual(later.submitted, settled.submitted, "A steady glow kept submitting: \(diagnostics.label)")
    }

    /// The presets without a pulse show no Pulse switch and run no clock.
    @MainActor
    func testAHaloWithoutAPulseRunsNoClock() throws {
        let (app, diagnostics) = launch(["-lab.glow", "ember", "-lab.source", "pattern"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Halo: 28 pt · 0.90 · no pulse · effect clock stopped"), diagnostics.label)
        XCTAssertFalse(app.switches["lab.glowPulse"].exists)
        Thread.sleep(forTimeInterval: 0.5)
        let settled = try freshCount(app, diagnostics)
        Thread.sleep(forTimeInterval: 2)
        let later = try freshCount(app, diagnostics)
        XCTAssertEqual(later.submitted, settled.submitted, diagnostics.label)
    }
}
