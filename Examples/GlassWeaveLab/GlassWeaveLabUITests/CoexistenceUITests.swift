import UIKit
import XCTest

/// Moving coexistence: one deterministic clock drives the app-owned
/// background and the custom panel's refraction; native text and a button
/// sit above the custom panel, and the native-glass reference control sits
/// beside it. Both controls must keep acting while everything moves, and the
/// background and the panel must show the same produced frame, including
/// after a resize while paused and after resuming.
final class CoexistenceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBothControlsActWhileTheBackgroundMoves() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let diagnostics = app.staticTexts["lab.diagnostics"]
        let customButton = app.buttons["lab.customButton"]
        let nativeButton = app.buttons["lab.nativeButton"]
        XCTAssertTrue(customButton.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: diagnostics, toContain: "Clock: running"), diagnostics.label)
        XCTAssertTrue(app.staticTexts["Custom GlassWeave"].exists)

        // Order: the custom button is native content on the custom panel;
        // the native glass sits beside the panel, not on it.
        let panel = app.otherElements["lab.customPanel"]
        let nativeGlass = app.otherElements["lab.nativeGlass"]
        XCTAssertTrue(panel.frame.contains(customButton.frame), "\(panel.frame) \(customButton.frame)")
        XCTAssertFalse(panel.frame.intersects(nativeGlass.frame), "\(panel.frame) \(nativeGlass.frame)")
        XCTAssertTrue(customButton.isHittable)
        XCTAssertTrue(nativeButton.isHittable)

        // Tap both controls three times each while frames keep advancing.
        var lastFrame = try waitForFrame(after: 0, diagnostics)
        for round in 1...3 {
            customButton.tap()
            nativeButton.tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "Custom taps: \(round)\n"), diagnostics.label)
            XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: \(round) ·"), diagnostics.label)
            let frame = try waitForFrame(after: lastFrame, diagnostics)
            XCTAssertGreaterThan(frame, lastFrame)
            lastFrame = frame
            try assertPresentedFrameIsTheProducedFrame(diagnostics)
        }

        // Pause: frames stop, the controls still act.
        app.buttons["lab.pause"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Clock: paused"), diagnostics.label)
        let pausedFrame = try presentedFrame(diagnostics)
        let pausedTime = try contentTime(diagnostics)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try presentedFrame(diagnostics), pausedFrame, "No frames while paused")
        customButton.tap()
        nativeButton.tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Custom taps: 4\n"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 4 ·"), diagnostics.label)
        try assertFrameIDStripMatches(app: app, panel: panel, frameID: pausedFrame)

        // Resize while paused: a new frame is produced for the new size at
        // the same content time, and it is the one presented.
        XCUIDevice.shared.orientation = .landscapeLeft
        let resizedFrame = try waitForFrame(after: pausedFrame, diagnostics)
        XCTAssertEqual(try contentTime(diagnostics), pausedTime)
        try assertPresentedFrameIsTheProducedFrame(diagnostics)
        XCTAssertTrue(customButton.isHittable)
        XCTAssertTrue(nativeButton.isHittable)
        customButton.tap()
        nativeButton.tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Custom taps: 5\n"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 5 ·"), diagnostics.label)
        XCUIDevice.shared.orientation = .portrait
        _ = try waitForFrame(after: resizedFrame, diagnostics)
        // A frame can arrive while the rotation animation still turns the
        // window; read the strip once the rotation has settled. Each draw
        // while paused refreshes the diagnostics, so the frame read then is
        // the one on screen.
        Thread.sleep(forTimeInterval: 1)
        let portraitFrame = try presentedFrame(diagnostics)
        try assertPresentedFrameIsTheProducedFrame(diagnostics)
        try assertFrameIDStripMatches(app: app, panel: panel, frameID: portraitFrame)

        // Resume: frames and content time advance again.
        app.buttons["lab.pause"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Clock: running"), diagnostics.label)
        let resumedFrame = try waitForFrame(after: portraitFrame, diagnostics)
        XCTAssertGreaterThan(resumedFrame, portraitFrame)
        XCTAssertGreaterThan(try contentTime(diagnostics), pausedTime)
        try assertPresentedFrameIsTheProducedFrame(diagnostics)

        // The frame-ID overlay can be turned off for timing runs.
        app.switches["lab.frameIDOverlay"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "frame ID overlay off"), diagnostics.label)

        // Reset clears both counts and restarts the clock.
        app.buttons["lab.reset"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Custom taps: 0\n"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 0 ·"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "frame ID overlay on"), diagnostics.label)
    }

    // MARK: Diagnostics

    private struct ParseFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// The frame the surface currently presents ("Custom: frame N").
    @MainActor
    private func presentedFrame(_ diagnostics: XCUIElement) throws -> Int {
        try number(after: "Custom: frame ", in: diagnostics.label)
    }

    /// The deterministic clock's content time ("t 1.23 s").
    @MainActor
    private func contentTime(_ diagnostics: XCUIElement) throws -> Double {
        let label = diagnostics.label
        guard let range = label.range(of: #"t (\d+\.\d+) s"#, options: .regularExpression) else {
            throw ParseFailure(description: "No content time in: \(label)")
        }
        let match = label[range].dropFirst(2).dropLast(2)
        guard let value = Double(match) else { throw ParseFailure(description: "Bad time \(match)") }
        return value
    }

    /// The presented frame is the frame most recently produced, and the last
    /// draw submitted that same frame.
    @MainActor
    private func assertPresentedFrameIsTheProducedFrame(_ diagnostics: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        let label = diagnostics.label
        let presented = try number(after: "Custom: frame ", in: label)
        let submitted = try number(after: "submitted frame ", in: label)
        let produced = try number(after: "produced frame ", in: label)
        XCTAssertEqual(presented, produced, label, file: file, line: line)
        XCTAssertEqual(presented, submitted, label, file: file, line: line)
    }

    @MainActor
    private func waitForFrame(after frame: Int, _ diagnostics: XCUIElement) throws -> Int {
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            let current = try presentedFrame(diagnostics)
            if current > frame { return current }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ParseFailure(description: "No frame after \(frame): \(diagnostics.label)")
    }

    private func number(after prefix: String, in text: String) throws -> Int {
        guard let start = text.range(of: prefix)?.upperBound else {
            throw ParseFailure(description: "No \"\(prefix)\" in: \(text)")
        }
        let digits = text[start...].prefix { $0.isNumber }
        guard let value = Int(digits) else { throw ParseFailure(description: "No number after \"\(prefix)\" in: \(text)") }
        return value
    }

    @MainActor
    private func wait(for element: XCUIElement, toContain text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }

    // MARK: Frame-ID strip

    /// Reads the frame-ID strip the producer draws into each frame, once
    /// beside the panel (the background pass) and once inside the panel
    /// (the glass pass), and checks both show `frameID`.
    ///
    /// The strip runs 34 points above the panel's bottom edge, in 12-point
    /// cells from the surface's left edge; cell i shows bit (i mod 16), white
    /// for 1. Portrait only: the stage starts at the screen's left edge.
    @MainActor
    private func assertFrameIDStripMatches(app: XCUIApplication, panel: XCUIElement, frameID: Int) throws {
        let capture = app.screenshot()
        let attachment = XCTAttachment(screenshot: capture)
        attachment.name = "frame-id-strip-\(frameID)"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
        let screenshot = capture.image
        let pixels = try SRGBPixels(screenshot)
        let scale = Double(pixels.width) / Double(app.windows.firstMatch.frame.width)
        let stripY = Double(panel.frame.maxY) - 34
        let panelMin = Double(panel.frame.minX), panelMax = Double(panel.frame.maxX)
        let rim = 24.0
        var outside: [(bit: Int, value: Int)] = []
        var inside: [(bit: Int, value: Int)] = []
        for cell in 0..<64 {
            let left = Double(cell) * 12, right = left + 12
            let center = left + 6
            guard right <= Double(app.windows.firstMatch.frame.width) else { break }
            let (_, green, _) = pixels.color(x: Int(center * scale), y: Int(stripY * scale))
            if right < panelMin - 1 || left > panelMax + 1 {
                outside.append((cell % 16, green))
            } else if left >= panelMin + rim, right <= panelMax - rim {
                inside.append((cell % 16, green))
            }
        }
        XCTAssertFalse(outside.isEmpty)
        XCTAssertEqual(Set(inside.map(\.bit)).count, 16, "The panel interior shows all 16 bits")
        // Outside the panel the cells are near-black or white.
        let label = app.staticTexts["lab.diagnostics"].label
        for (bit, value) in outside {
            XCTAssertTrue(value < 60 || value > 200, "Outside cell for bit \(bit) is \(value); outside \(outside), inside \(inside), strip y \(stripY), panel \(panel.frame): \(label)")
            XCTAssertEqual(value > 128, (frameID >> bit) & 1 == 1, "Outside bit \(bit) of frame \(frameID); outside \(outside): \(label)")
        }
        // Inside, the tint lifts both levels; split them at the midpoint.
        let values = inside.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 0
        XCTAssertGreaterThan(high - low, 40, "Inside cells \(values)")
        for (bit, value) in inside {
            XCTAssertEqual(value > (low + high) / 2, (frameID >> bit) & 1 == 1, "Inside bit \(bit) of frame \(frameID)")
        }
    }
}
