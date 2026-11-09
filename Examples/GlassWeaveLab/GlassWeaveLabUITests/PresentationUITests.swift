import XCTest

/// GW-27: a surface whose drawables are all held elsewhere never stalls the
/// main thread, and its pending frame draws once they are released.
///
/// The laboratory's presentation screen (`-lab.presentation YES`) takes every
/// drawable of the surface's Metal layer that the display does not show, then
/// requests a frame at once, while a main-actor heartbeat records how late
/// the main thread wakes. The surface
/// has to be on screen for this, and a unit-test process has no scene, so it
/// is a UI test. Before the change the host acquired its drawable on the main
/// thread, which waited for the layer's one-second timeout.
final class PresentationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Reads `key=value` pairs from a presentation report label.
    private func values(of element: XCUIElement) -> [String: String] {
        var result: [String: String] = [:]
        for token in element.label.split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }

    /// Polls `element`'s report until `condition` holds.
    @discardableResult
    private func wait(_ element: XCUIElement, timeout: TimeInterval = 10, until condition: ([String: String]) -> Bool) throws -> [String: String] {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            let current = values(of: element)
            if condition(current) { return current }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date.now < deadline
        XCTFail("Timed out waiting on '\(element.label)'")
        return values(of: element)
    }

    @MainActor
    func testHeldDrawablesNeverStallTheMainThreadAndTheRequestDrawsOnRelease() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-lab.presentation", "YES"]
        app.launch()

        let frames = app.staticTexts["presentation.frames"]
        let held = app.staticTexts["presentation.held"]
        let heartbeat = app.staticTexts["presentation.heartbeat"]
        XCTAssertTrue(frames.waitForExistence(timeout: 10))
        // The first frame is drawn and finished before the stress starts.
        try wait(frames) { Int($0["submitted"] ?? "") ?? 0 >= 1 && $0["inflight"] == "0" && $0["visible"] == "1" }
        Thread.sleep(forTimeInterval: 0.5)

        // One action on the main thread: a background thread takes every
        // drawable the display does not show, then the surface is asked for a
        // frame at once, so none is free. The heartbeat is reset just before.
        let before = values(of: frames)
        app.buttons["presentation.stress"].tap()
        let afterHold = try wait(held, timeout: 15) { $0["holding"] == "0" && Int($0["held"] ?? "") ?? 0 >= 1 }
        XCTAssertGreaterThanOrEqual(Int(afterHold["held"] ?? "") ?? 0, 1, held.label)
        Thread.sleep(forTimeInterval: 2.5)
        let beat = values(of: heartbeat)
        let worst = Double(beat["worstMs"] ?? "") ?? .infinity
        XCTAssertLessThan(worst, 50, "The main thread stalled waiting for a drawable: \(heartbeat.label)")
        XCTAssertGreaterThan(Int(beat["beats"] ?? "") ?? 0, 50, "The heartbeat barely ran: \(heartbeat.label)")

        // Releasing the drawables lets the pending request draw. (The layer
        // may hand out a further drawable of its own after a timeout, so the
        // frame can already be drawn by now; either way it is drawn.)
        let submitted = Int(before["submitted"] ?? "") ?? 0
        app.buttons["presentation.release"].tap()
        try wait(frames, timeout: 10) { Int($0["submitted"] ?? "") ?? 0 > submitted && $0["inflight"] == "0" }
    }
}
