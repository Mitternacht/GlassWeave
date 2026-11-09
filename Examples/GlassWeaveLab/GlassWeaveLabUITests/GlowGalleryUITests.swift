import UIKit
import XCTest

/// GW-20: the laboratory's glow gallery. Its glass (a theme switch's knob,
/// three element capsules, an energy orb) is drawn by one surface in one
/// pass; its controls are native. These tests drive the controls as a user
/// and VoiceOver would, read the gallery's diagnostics (the surface's frame
/// counts and what it presents), and check accessibility with Xcode's audit.
/// `-lab.gallery YES` opens the gallery at launch; settings come from
/// `-lab.reduceMotion`, `-lab.reduceTransparency`, `-lab.increaseContrast`,
/// `-lab.appearance`, and `-UIPreferredContentSizeCategoryName`.
final class GlowGalleryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            XCUIDevice.shared.appearance = .light
            XCUIDevice.shared.orientation = .portrait
        }
        super.tearDown()
    }

    @MainActor
    private func launch(_ arguments: [String] = [], appearance: String = "light") -> (XCUIApplication, XCUIElement) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-lab.gallery", "YES", "-lab.appearance", appearance] + arguments
        app.launch()
        let diagnostics = app.staticTexts["gallery.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: diagnostics, toContain: "Surface: visible · scene active"), diagnostics.label)
        // A test that rotated the device may leave the rotation back to
        // portrait still running; taps computed meanwhile land elsewhere.
        let window = app.windows.firstMatch
        let deadline = Date.now.addingTimeInterval(5)
        while window.frame.width > window.frame.height, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertLessThan(window.frame.width, window.frame.height, "Still in landscape")
        Thread.sleep(forTimeInterval: 0.5)
        return (app, diagnostics)
    }

    @MainActor
    private func wait(for element: XCUIElement, toContain text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func wait(for element: XCUIElement, value: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// A fresh count. The diagnostics refresh on draws and actions; tapping
    /// the native glass button (Core Animation only) requests no frame but
    /// refreshes them.
    @MainActor
    private func freshCount(_ app: XCUIApplication, _ diagnostics: XCUIElement) throws -> LabDiagnostics {
        let before = diagnostics.label
        app.buttons["gallery.nativeButton"].tap()
        return try waitForDiagnostics(diagnostics) { _ in diagnostics.label != before }
    }

    /// Frames submitted over `seconds` with nothing touched.
    @MainActor
    private func framesOver(_ seconds: TimeInterval, _ app: XCUIApplication, _ diagnostics: XCUIElement) throws -> (frames: Int, last: LabDiagnostics) {
        let start = try freshCount(app, diagnostics)
        Thread.sleep(forTimeInterval: seconds)
        let end = try freshCount(app, diagnostics)
        return (end.submitted - start.submitted, end)
    }

    @MainActor
    private func toggle(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["gallery.themeToggle"]
    }

    @MainActor
    private func card(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons["gallery.element.\(name)"]
    }

    private static let elements = ["ember", "corona", "eddy"]

    private func report(_ lines: [String], name: String) {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Opening

    /// The gallery opens from the laboratory's button and closes again.
    /// While it covers the laboratory, the laboratory's surface (drawing its
    /// moving background until then) is out of the window and submits
    /// nothing, even with a gallery capsule moving.
    @MainActor
    func testTheGalleryOpensFromTheLaboratoryAndCloses() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let labDiagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(labDiagnostics.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: labDiagnostics, toContain: "Clock: running"), labDiagnostics.label)
        let open = app.buttons["lab.openGallery"]
        XCTAssertEqual(open.label, "Glow gallery")
        open.tap()
        let diagnostics = app.staticTexts["gallery.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: diagnostics, toContain: "Glass: 5 panels · 5 halos · 1 interiors · 0 moving · quads apart"), diagnostics.label)
        XCTAssertFalse(labDiagnostics.exists)
        card(app, "ember").tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "effect clock running"), diagnostics.label)
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["gallery.close"].tap()
        XCTAssertTrue(labDiagnostics.waitForExistence(timeout: 10))
        XCTAssertFalse(diagnostics.exists)
        let back = try waitForDiagnostics(labDiagnostics) { $0.surfaceVisible && $0.hiddenPeriodSubmissions != nil }
        XCTAssertEqual(back.hiddenPeriodSubmissions, 0, labDiagnostics.label)
    }

    // MARK: Controls

    @MainActor
    func testTheThemeSwitchChangesTheAppearanceAndItsValue() throws {
        let (app, diagnostics) = launch()
        let control = toggle(app)
        XCTAssertTrue(control.exists)
        XCTAssertEqual(control.label, "Dark appearance")
        XCTAssertEqual(control.value as? String, "0")
        XCTAssertTrue(control.isHittable)
        let lightPage = try pageSample(app)
        XCTAssertGreaterThan(Self.luminance(lightPage), 0.75, "\(lightPage)")

        control.tap()
        XCTAssertTrue(wait(for: control, value: "1"), "\(String(describing: control.value))")
        XCTAssertTrue(wait(for: diagnostics, toContain: "appearance dark"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "transition idle"), diagnostics.label)
        let darkPage = try pageSample(app)
        XCTAssertLessThan(Self.luminance(darkPage), 0.05, "\(darkPage)")

        control.tap()
        XCTAssertTrue(wait(for: control, value: "0"))
        XCTAssertTrue(wait(for: diagnostics, toContain: "appearance light"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "transition idle"), diagnostics.label)
        // Settled: nothing more is submitted.
        let idle = try framesOver(2, app, diagnostics)
        XCTAssertEqual(idle.frames, 0, diagnostics.label)
        report(["light page \(lightPage), dark page \(darkPage)"], name: "theme-switch.txt")
    }

    @MainActor
    func testSelectingEachCapsuleUpdatesSelectionAndAccessibility() throws {
        let (app, diagnostics) = launch()
        for name in Self.elements {
            XCTAssertFalse(card(app, name).isSelected, name)
        }
        for name in Self.elements {
            card(app, name).tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "selected \(name)"), diagnostics.label)
            for other in Self.elements {
                XCTAssertEqual(card(app, other).isSelected, other == name, "\(name) selected; \(other)")
            }
            XCTAssertTrue(wait(for: diagnostics, toContain: "1 moving · quads apart · effect clock running"), diagnostics.label)
        }
        // Selecting the selected capsule again deselects it, and the gallery
        // settles.
        card(app, "eddy").tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "selected none"), diagnostics.label)
        XCTAssertFalse(card(app, "eddy").isSelected)
        XCTAssertTrue(wait(for: diagnostics, toContain: "0 moving · quads apart · effect clock stopped · transition idle"), diagnostics.label)
    }

    @MainActor
    func testTheOrbSurgesWhenChargedAndThenSettles() throws {
        let (app, diagnostics) = launch()
        let orb = app.buttons["gallery.orb"]
        XCTAssertTrue(orb.label.hasPrefix("Charge the orb"), orb.label)
        XCTAssertEqual(orb.value as? String, "Resting")
        orb.tap()
        XCTAssertTrue(wait(for: orb, value: "Surging"))
        XCTAssertTrue(wait(for: diagnostics, toContain: "orb surging · charges 1"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "effect clock running"), diagnostics.label)
        let surging = try framesOver(1.5, app, diagnostics)
        XCTAssertGreaterThanOrEqual(surging.frames, 30, diagnostics.label)
        XCTAssertLessThanOrEqual(surging.last.peakFramesInFlight, surging.last.maximumFramesInFlight)
        // It settles by itself after its surge.
        XCTAssertTrue(wait(for: orb, value: "Resting", timeout: 10))
        XCTAssertTrue(wait(for: diagnostics, toContain: "orb resting", timeout: 5), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "effect clock stopped · transition idle"), diagnostics.label)
        let idle = try framesOver(2, app, diagnostics)
        XCTAssertEqual(idle.frames, 0, diagnostics.label)
        report(["surging: \(surging.frames) frames in about 1.5 s, peak \(surging.last.peakFramesInFlight) of \(surging.last.maximumFramesInFlight)", "settled: \(idle.frames) frames in about 2 s"], name: "orb-submissions.txt")
    }

    // MARK: On demand

    @MainActor
    func testTheGallerySubmitsFramesOnlyWhileSomethingMoves() throws {
        let (app, diagnostics) = launch()
        var lines: [String] = []
        XCTAssertTrue(wait(for: diagnostics, toContain: "0 moving · quads apart · effect clock stopped · transition idle"), diagnostics.label)
        let rest = try framesOver(2, app, diagnostics)
        lines.append("at rest: \(rest.frames) frames in about 2 s")
        XCTAssertEqual(rest.frames, 0, diagnostics.label)

        card(app, "ember").tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "effect clock running"), diagnostics.label)
        let moving = try framesOver(2, app, diagnostics)
        lines.append("ember selected: \(moving.frames) frames in about 2 s, peak \(moving.last.peakFramesInFlight) of \(moving.last.maximumFramesInFlight)")
        XCTAssertGreaterThanOrEqual(moving.frames, 40, diagnostics.label)
        XCTAssertLessThanOrEqual(moving.last.peakFramesInFlight, moving.last.maximumFramesInFlight)

        // In the background nothing is submitted, and the interior moves
        // again on return.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        let back = try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.sceneState == "active" && $0.hiddenPeriodSubmissions != nil }
        lines.append("background with ember selected: \(back.hiddenPeriodSubmissions ?? -1) frames")
        XCTAssertEqual(back.hiddenPeriodSubmissions, 0, diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "effect clock running"), diagnostics.label)

        card(app, "ember").tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "0 moving · quads apart · effect clock stopped · transition idle"), diagnostics.label)
        let settled = try framesOver(2, app, diagnostics)
        lines.append("deselected: \(settled.frames) frames in about 2 s")
        XCTAssertEqual(settled.frames, 0, diagnostics.label)
        report(lines, name: "gallery-submissions.txt")
    }

    @MainActor
    func testReduceMotionStopsEveryAnimation() throws {
        let (app, diagnostics) = launch(["-lab.reduceMotion", "YES"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Reduce Motion on"), diagnostics.label)
        // A selected capsule shows its still frame: nothing moves and no
        // clock runs.
        card(app, "corona").tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "selected corona · orb resting"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "2 interiors · 0 moving · quads apart · effect clock stopped · transition idle"), diagnostics.label)
        let still = try framesOver(2, app, diagnostics)
        XCTAssertEqual(still.frames, 0, diagnostics.label)
        // The surging orb shows a steady, brighter glow and its interior's
        // still frame: one frame when the surge starts, none while it lasts,
        // and one when it settles, two for the whole five seconds.
        let beforeCharge = still.last
        app.buttons["gallery.orb"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "orb surging · charges 1"), diagnostics.label)
        XCTAssertTrue(diagnostics.label.contains("0 moving") && diagnostics.label.contains("effect clock stopped"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "orb resting", timeout: 10), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "2 interiors · 0 moving · quads apart · effect clock stopped · transition idle"), diagnostics.label)
        Thread.sleep(forTimeInterval: 1)
        let surgeEnded = try freshCount(app, diagnostics)
        let surging = surgeEnded.submitted - beforeCharge.submitted
        XCTAssertEqual(surging, 2, "Only the surge's start and its settling should draw: \(diagnostics.label)")
        // The theme switch cross-dissolves and then settles.
        toggle(app).tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "appearance dark"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "transition idle"), diagnostics.label)
        let afterTheme = try framesOver(2, app, diagnostics)
        XCTAssertEqual(afterTheme.frames, 0, diagnostics.label)
        report(["Reduce Motion, corona selected: \(still.frames) frames in about 2 s", "orb surge (5 s), its start and settling: \(surging) frames", "after the theme cross-dissolve: \(afterTheme.frames) frames in about 2 s"], name: "reduce-motion.txt")
    }

    // MARK: Accessibility settings

    @MainActor
    func testReduceTransparencyAndIncreaseContrastFollowTheGlowDesign() throws {
        // Reduce Transparency: opaque bodies with a thin rim, no halo, no
        // interior, no reflection, nothing moving.
        var (app, diagnostics) = launch(["-lab.reduceTransparency", "YES", "-lab.gallerySelect", "ember", "-lab.galleryCharge", "YES"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Reduce Transparency on"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Glass: 5 panels · 0 halos · 0 interiors · 0 moving · quads apart · effect clock stopped"), diagnostics.label)
        app.terminate()

        // Increase Contrast: halos kept and interiors removed, so the
        // selected capsule does not move; a charged orb's pulse is kept
        // (checked well inside its five-second surge).
        (app, diagnostics) = launch(["-lab.increaseContrast", "YES", "-lab.gallerySelect", "ember"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "contrast high"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "selected ember"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Glass: 5 panels · 5 halos · 0 interiors · 0 moving · quads apart · effect clock stopped"), diagnostics.label)
        app.buttons["gallery.orb"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "orb surging"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Glass: 5 panels · 5 halos · 0 interiors · 1 moving · quads apart · effect clock running", timeout: 4), diagnostics.label)
        app.terminate()
    }

    @MainActor
    func testEveryControlIsOneLabeledElementInReadingOrder() throws {
        let (app, _) = launch()
        let controls: [(XCUIElement, String)] = [
            (app.buttons["gallery.close"], "Close"),
            (toggle(app), "Dark appearance"),
            (card(app, "ember"), "Ember"),
            (card(app, "corona"), "Corona"),
            (card(app, "eddy"), "Eddy"),
            (app.buttons["gallery.nativeButton"], "Native glass"),
        ]
        for (element, label) in controls {
            XCTAssertEqual(element.label, label)
            XCTAssertTrue(element.isHittable, label)
            XCTAssertGreaterThanOrEqual(element.frame.width, 44, label)
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, label)
        }
        XCTAssertTrue(app.buttons["gallery.orb"].label.hasPrefix("Charge the orb"))
        for identifier in ["gallery.close", "gallery.themeToggle", "gallery.element.ember", "gallery.orb", "gallery.nativeButton"] {
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: identifier).count, 1, identifier)
        }
        // The surface and the glass placeholders add no element.
        XCTAssertFalse(app.descendants(matching: .any)["gallery.surface"].exists)
        // Top to bottom: title, switch, capsules (left to right), orb, native.
        let order = [
            app.staticTexts["Glow gallery"].frame.midY, toggle(app).frame.midY,
            card(app, "corona").frame.midY, app.buttons["gallery.orb"].frame.midY,
            app.buttons["gallery.nativeButton"].frame.midY,
        ]
        XCTAssertEqual(order, order.sorted(), "\(order)")
        let row = ["ember", "corona", "eddy"].map { card(app, $0).frame.midX }
        XCTAssertEqual(row, row.sorted(), "\(row)")
    }

    /// Xcode's accessibility audit with a capsule selected (its interior
    /// moving), in light and in dark. The audit's contrast check resolves
    /// text colors for the *system* appearance, so each run sets the
    /// simulator's appearance and launches the gallery in the same one
    /// (`-lab.appearance`, which the gallery follows until its switch is
    /// used); auditing after the switch alone, with the system still light,
    /// judges the white text of the dark gallery as black (seen while
    /// writing this test: only the label over the darkest part of the page
    /// failed, at 19:1 measured from the screenshot).
    @MainActor
    func testAccessibilityAuditPassesInLightAndDark() throws {
        var reported: [String] = []
        for (appearance, device) in [("light", XCUIDevice.Appearance.light), ("dark", .dark)] {
            XCUIDevice.shared.appearance = device
            let (app, diagnostics) = launch(["-lab.gallerySelect", "corona"], appearance: appearance)
            XCTAssertTrue(wait(for: diagnostics, toContain: "appearance \(appearance)"), diagnostics.label)
            XCTAssertTrue(wait(for: diagnostics, toContain: "selected corona"), diagnostics.label)
            XCTAssertTrue(wait(for: diagnostics, toContain: "transition idle"), diagnostics.label)
            let before = reported.count
            try app.performAccessibilityAudit { issue in
                reported.append("\(appearance): \(issue.compactDescription): \(issue.detailedDescription) element: \(issue.element?.debugDescription ?? "none")")
                return true
            }
            if reported.count > before {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "audit-\(appearance).png"
                shot.lifetime = .keepAlways
                add(shot)
            }
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
        XCTAssertTrue(reported.isEmpty, "\(reported)")
    }

    @MainActor
    func testLargestTextSizeKeepsContentAndTargets() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let (app, diagnostics) = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(wait(for: diagnostics, toContain: "text AccessibilityXXXL"), diagnostics.label)
            XCTAssertTrue(wait(for: diagnostics, toContain: "quads apart"), diagnostics.label)
            for name in Self.elements {
                let element = card(app, name)
                XCTAssertGreaterThanOrEqual(element.frame.height, 44, name)
                XCTAssertGreaterThanOrEqual(element.frame.width, 44, name)
            }
            // Every control acts; the gallery scrolls them into reach.
            card(app, "eddy").tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "selected eddy"), diagnostics.label)
            XCTAssertTrue(wait(for: diagnostics, toContain: "quads apart"), diagnostics.label)
            app.buttons["gallery.orb"].tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "charges 1"), diagnostics.label)
            app.buttons["gallery.nativeButton"].tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "native taps 1"), diagnostics.label)
            toggle(app).tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "appearance dark"), diagnostics.label)
            let orb = app.buttons["gallery.orb"]
            XCTAssertGreaterThanOrEqual(orb.frame.height, 44)
            try app.performAccessibilityAudit(for: [.dynamicType, .textClipped]) { issue in
                XCTFail("\(orientation.rawValue): \(issue.compactDescription): \(issue.element?.debugDescription ?? "no element")")
                return true
            }
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Pixels

    /// A sample of the page background in the gallery's top-left margin.
    @MainActor
    private func pageSample(_ app: XCUIApplication) throws -> (Int, Int, Int) {
        let pixels = try SRGBPixels(app.screenshot().image)
        let scale = Double(pixels.width) / Double(app.windows.firstMatch.frame.width)
        let title = app.staticTexts["Glow gallery"].frame
        // Left of the stage, below the title, away from the dot grid's dots.
        let point = CGPoint(x: 6, y: title.maxY + 30)
        return pixels.color(x: Int(point.x * scale), y: Int(point.y * scale))
    }

    private static func luminance(_ color: (Int, Int, Int)) -> Double {
        func linear(_ value: Int) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.0) + 0.7152 * linear(color.1) + 0.0722 * linear(color.2)
    }
}
