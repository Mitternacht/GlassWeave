import XCTest

/// The render lifecycle in the running laboratory: a hidden stage, a
/// backgrounded app, and (on iPad) two window scenes with different
/// activation states. The laboratory's diagnostics report what its own
/// surface submitted, so each check reads one scene's counts.
final class LifecycleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHidingTheStageStopsSubmissionsAndReturnsTextures() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        let stageSwitch = app.switches["lab.stageVisible"]
        try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.submitted > 10 }

        for cycle in 1...10 {
            stageSwitch.tap()
            let hidden = try waitForDiagnostics(diagnostics) { !$0.surfaceVisible }
            XCTAssertTrue(diagnostics.label.contains("Clock: paused (hidden)"), diagnostics.label)
            // Frames still in flight finish and give their textures back;
            // only the presented frame's texture stays while hidden.
            try waitForDiagnostics(diagnostics) { $0.textures == 1 }
            Thread.sleep(forTimeInterval: 0.5)

            // Showing again draws the pending frame. The count taken when
            // the surface became visible covers the whole hidden period.
            stageSwitch.tap()
            let shown = try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.submitted > hidden.submitted }
            XCTAssertEqual(shown.hiddenPeriodSubmissions, 0, "cycle \(cycle): \(diagnostics.label)")
        }
        let final = try LabDiagnostics(diagnostics.label)
        XCTAssertLessThanOrEqual(final.peakFramesInFlight, final.maximumFramesInFlight)
        XCTAssertLessThanOrEqual(final.textures ?? .max, 3)
    }

    /// A stationary source with a settled surface submits nothing. The
    /// diagnostics only refresh on draws and actions, so tapping the native
    /// button (which requests no frame) refreshes them for a fresh count.
    @MainActor
    func testAStationarySourceSubmitsNothing() throws {
        XCUIDevice.shared.orientation = .portrait
        for arguments in [[], ["-lab.source", "pattern"]] {
            let app = XCUIApplication()
            app.launchArguments += arguments
            app.launch()
            let diagnostics = app.staticTexts["lab.diagnostics"]
            let nativeButton = app.buttons["lab.nativeButton"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
            try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.submitted >= 1 }
            if arguments.isEmpty {
                // The moving source: stop its clock.
                app.buttons["lab.pause"].tap()
                XCTAssertTrue(diagnostics.label.contains("Clock: paused"), diagnostics.label)
            }
            Thread.sleep(forTimeInterval: 0.5)
            nativeButton.tap()
            let settled = try waitForDiagnostics(diagnostics) { $0.framesInFlight == 0 }
            Thread.sleep(forTimeInterval: 2)
            nativeButton.tap()
            let later = try waitForDiagnostics(diagnostics) { _ in true }
            XCTAssertTrue(diagnostics.label.contains("Native taps: 2"), diagnostics.label)
            XCTAssertEqual(later.submitted, settled.submitted, "A settled surface kept submitting: \(diagnostics.label)")
            app.terminate()
        }
    }

    @MainActor
    func testBackgroundingTheAppStopsSubmissions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        let before = try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.sceneState == "active" && $0.submitted > 10 }

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let after = try waitForDiagnostics(diagnostics) {
            $0.surfaceVisible && $0.sceneState == "active" && $0.hiddenPeriodSubmissions != nil && $0.submitted > before.submitted
        }
        XCTAssertEqual(after.hiddenPeriodSubmissions, 0, "The backgrounded scene submitted frames: \(diagnostics.label)")
        XCTAssertLessThanOrEqual(after.peakFramesInFlight, after.maximumFramesInFlight)
    }

    /// iPad: a second window scene comes forward and the first goes to the
    /// background. Each surface follows its own scene: the background one
    /// submits nothing and keeps one texture while the active one draws.
    /// Closing the second window brings the first back, which then draws
    /// again.
    @MainActor
    func testTwoWindowScenesFollowTheirOwnActivationState() throws {
        let app = XCUIApplication()
        app.launch()
        let newWindow = app.buttons["lab.newWindow"]
        XCTAssertTrue(app.staticTexts["lab.diagnostics"].waitForExistence(timeout: 10))
        guard newWindow.exists else {
            throw XCTSkip("This device does not show several windows of one app (UIApplication.supportsMultipleScenes is false).")
        }
        let first = app.staticTexts["lab.diagnostics"]
        try waitForDiagnostics(first) { $0.surfaceVisible && $0.submitted > 10 }

        newWindow.tap()
        let allDiagnostics = app.staticTexts.matching(identifier: "lab.diagnostics")
        let twoScenes = NSPredicate(format: "count == 2")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: twoScenes, object: allDiagnostics)], timeout: 10), .completed)

        /// The diagnostics of the scene in `state`.
        func scene(_ state: String) throws -> XCUIElement {
            let deadline = Date.now.addingTimeInterval(10)
            repeat {
                for index in 0..<allDiagnostics.count {
                    let element = allDiagnostics.element(boundBy: index)
                    if let parsed = try? LabDiagnostics(element.label), parsed.sceneState == state {
                        return element
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date.now < deadline
            throw LabDiagnostics.ParseFailure(description: "No scene is \(state)")
        }
        let background = try scene("background")
        let active = try scene("active")
        let backgroundSettled = try waitForDiagnostics(background) { !$0.surfaceVisible && $0.textures == 1 }
        let activeStart = try waitForDiagnostics(active) { $0.surfaceVisible && $0.submitted > 10 }
        Thread.sleep(forTimeInterval: 1)
        let backgroundLater = try LabDiagnostics(background.label)
        let activeLater = try LabDiagnostics(active.label)
        XCTAssertEqual(backgroundLater.submitted, backgroundSettled.submitted, "The background scene submitted frames")
        XCTAssertGreaterThan(activeLater.submitted, activeStart.submitted, "The active scene stopped drawing")
        XCTAssertLessThanOrEqual(activeLater.peakFramesInFlight, activeLater.maximumFramesInFlight)

        // Close the new window. The system then shows the Home Screen with
        // the first scene still in the background; activating the app
        // brings that scene back, and it draws again, having submitted
        // nothing while it was in the background.
        let closeButtons = app.buttons.matching(identifier: "lab.closeWindow")
        var closed = false
        for index in 0..<closeButtons.count where closeButtons.element(boundBy: index).isHittable {
            closeButtons.element(boundBy: index).tap()
            closed = true
            break
        }
        XCTAssertTrue(closed, "No hittable Close window button")
        let oneScene = NSPredicate(format: "count == 1")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: oneScene, object: allDiagnostics)], timeout: 10), .completed)
        let stillBackground = try LabDiagnostics(allDiagnostics.element(boundBy: 0).label)
        XCTAssertEqual(stillBackground.submitted, backgroundSettled.submitted, "The background scene submitted frames")
        app.activate()
        let returned = try waitForDiagnostics(allDiagnostics.element(boundBy: 0)) {
            $0.surfaceVisible && $0.sceneState == "active" && $0.submitted > backgroundLater.submitted
        }
        XCTAssertEqual(returned.hiddenPeriodSubmissions, 0, allDiagnostics.element(boundBy: 0).label)
    }
}
