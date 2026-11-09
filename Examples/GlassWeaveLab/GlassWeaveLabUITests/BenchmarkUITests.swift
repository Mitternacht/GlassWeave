import XCTest

/// GW-09's benchmark scenario in the running laboratory: each timing mode's
/// composition and recorded metrics, the idle check, and the lifecycle
/// stress with settled allocations.
///
/// On a simulator these are functional checks of the scenario and the
/// measurement path. Simulator timings are recorded for completeness and
/// are not device evidence.
final class BenchmarkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ mode: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments += ["-lab.benchmark", mode]
        app.launch()
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        return (app, diagnostics)
    }

    /// Modes 1–3: each shows only its composition, starts with the frame-ID
    /// strip off, and records a metrics window that Reset restarts.
    @MainActor
    func testTimingModesShowTheirCompositionAndRecordMetrics() throws {
        XCUIDevice.shared.orientation = .portrait
        let modes: [(name: String, native: Bool, custom: Bool)] = [
            ("baseline", false, false),
            ("native", true, false),
            ("custom", true, true),
        ]
        var record: [String] = []
        for mode in modes {
            let (app, diagnostics) = launch(mode.name)
            XCTAssertEqual(app.buttons["lab.nativeButton"].exists, mode.native, mode.name)
            XCTAssertEqual(app.buttons["lab.customButton"].exists, mode.custom, mode.name)
            let first = try waitForDiagnostics(diagnostics) { ($0.metricsFrames ?? 0) > 0 }
            XCTAssertEqual(first.benchmarkMode, mode.name)
            XCTAssertTrue(diagnostics.label.contains("frame ID overlay off"), diagnostics.label)
            XCTAssertTrue(diagnostics.label.contains("Clock: running"), diagnostics.label)

            // Warm up, restart the window with Reset, and measure 10 s.
            Thread.sleep(forTimeInterval: 2)
            app.buttons["lab.reset"].tap()
            Thread.sleep(forTimeInterval: 10)
            let measured = try waitForDiagnostics(diagnostics) { _ in true }
            let frames = try XCTUnwrap(measured.metricsFrames)
            XCTAssertGreaterThan(frames, 0)
            XCTAssertEqual(measured.metricsFailed, 0)
            XCTAssertGreaterThanOrEqual(measured.metricsCommitted ?? 0, frames)
            XCTAssertLessThanOrEqual(measured.peakFramesInFlight, measured.maximumFramesInFlight)
            XCTAssertLessThanOrEqual(measured.textures ?? .max, 3)
            let allocated = measured.metalBytes.map { "\($0) B allocated" } ?? "allocation sizes not reported"
            record.append("\(mode.name): \(measured.metricsLine ?? "no metrics") · Metal \(allocated)")
            app.terminate()
        }
        let attachment = XCTAttachment(string: record.joined(separator: "\n"))
        attachment.name = "benchmark-timing-modes.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(record.joined(separator: "\n"))
    }

    /// Mode 4: with the source frozen and the panel settled, nothing is
    /// submitted for 30 seconds (the protocol's settle period). The
    /// diagnostics refresh every second without requesting a frame.
    @MainActor
    func testIdleModeSubmitsNothingForThirtySeconds() throws {
        XCUIDevice.shared.orientation = .portrait
        let (app, diagnostics) = launch("idle")
        XCTAssertTrue(app.buttons["lab.customButton"].exists)
        let settled = try waitForDiagnostics(diagnostics) {
            $0.surfaceVisible && $0.submitted >= 1 && $0.framesInFlight == 0
        }
        XCTAssertTrue(diagnostics.label.contains("Clock: paused · t 0.00 s"), diagnostics.label)
        Thread.sleep(forTimeInterval: 30)
        let later = try LabDiagnostics(diagnostics.label)
        XCTAssertEqual(later.submitted, settled.submitted, "The idle stage submitted frames: \(diagnostics.label)")
        XCTAssertEqual(later.metricsFrames, settled.metricsFrames)
        XCTAssertTrue(diagnostics.label.contains("Clock: paused · t 0.00 s"), diagnostics.label)
        let attachment = XCTAttachment(string: "idle: \(settled.submitted) submitted when settled, \(later.submitted) after 30 s")
        attachment.name = "benchmark-idle.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Mode 5: the app runs 100 seeded hide/show and resize cycles between
    /// two settled measurements; then this test rotates the device and
    /// backgrounds the app three times each and measures again. Outside the
    /// bounded texture pool, allocations must not grow.
    @MainActor
    func testLifecycleStressLeavesNoRetainedGrowth() throws {
        XCUIDevice.shared.orientation = .portrait
        let (app, diagnostics) = launch("lifecycle")
        let done = try waitForDiagnostics(diagnostics, timeout: 120) { $0.lifecycle != nil }
        let lifecycle = try XCTUnwrap(done.lifecycle)
        XCTAssertEqual(lifecycle.cycles, 100)
        // The iOS Simulator reports zero for every Metal allocation size, so
        // there the byte comparison cannot be made; it is recorded as not
        // measured, and only the bounded texture count is checked.
        let reportsAllocations = lifecycle.before.deviceBytes > 0
        if reportsAllocations {
            XCTAssertLessThanOrEqual(lifecycle.after.unpooledBytes, lifecycle.before.unpooledBytes, diagnostics.label)
        } else {
            XCTAssertTrue(diagnostics.label.contains("allocation sizes not reported by this device"), diagnostics.label)
            XCTAssertEqual(lifecycle.after.deviceBytes, 0)
        }
        XCTAssertLessThanOrEqual(lifecycle.after.textures, 3)
        XCTAssertLessThanOrEqual(done.peakFramesInFlight, done.maximumFramesInFlight)

        for _ in 0..<3 {
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1)
            XCUIDevice.shared.orientation = .portrait
            Thread.sleep(forTimeInterval: 1)
        }
        for _ in 0..<3 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
            Thread.sleep(forTimeInterval: 1)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            Thread.sleep(forTimeInterval: 1)
        }
        app.buttons["lab.measure"].tap()
        let measured = try waitForDiagnostics(diagnostics) { $0.settled != nil }
        let settled = try XCTUnwrap(measured.settled)
        if reportsAllocations {
            XCTAssertLessThanOrEqual(settled.unpooledBytes, lifecycle.before.unpooledBytes, diagnostics.label)
        }
        XCTAssertLessThanOrEqual(settled.textures, 3)
        XCTAssertLessThanOrEqual(measured.peakFramesInFlight, measured.maximumFramesInFlight)

        let summary = """
        lifecycle: \(lifecycle.cycles) cycles; settled before \(lifecycle.before); after \(lifecycle.after); \
        after 3 rotations and 3 background/foreground cycles \(settled); \
        allocation sizes \(reportsAllocations ? "reported" : "not reported by this device (not measured)")
        """
        let attachment = XCTAttachment(string: summary)
        attachment.name = "benchmark-lifecycle.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(summary)
    }
}
