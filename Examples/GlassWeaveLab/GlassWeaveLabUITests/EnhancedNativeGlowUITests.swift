import simd
import UIKit
import XCTest

/// GW-14 in the laboratory: `-lab.nativeGlow <preset>` draws a glow's rim
/// and halo around the native reference glass (`EnhancedNativeGlassView`),
/// with Core Animation and no GlassWeave renderer. Over the still pattern
/// nothing else moves, so the screenshots of the running app show what the
/// system composites: the halo's color and falloff outside the glass, the
/// rim's color on the glass's edge, and Apple's glass unchanged in the
/// middle (compared with the Native glow switch off). The pulse runs in
/// Core Animation: the custom surface submits nothing for it, and the
/// native button keeps working while it runs.
final class EnhancedNativeGlowUITests: XCTestCase {
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

    @MainActor
    private func wait(for element: XCUIElement, toContain text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }

    /// A fresh count: tapping the native button requests no frame but
    /// refreshes the diagnostics.
    @MainActor
    private func freshCount(_ app: XCUIApplication, _ diagnostics: XCUIElement) throws -> LabDiagnostics {
        let before = diagnostics.label
        app.buttons["lab.nativeButton"].tap()
        return try waitForDiagnostics(diagnostics) { _ in diagnostics.label != before }
    }

    // MARK: The energy preset's colors

    /// sRGB components of a system color in an appearance, resolved like the
    /// laboratory's own (on the simulated iPhone's P3 display), clamped to
    /// 0...1 as the glow's normalization does.
    private func components(of color: UIColor, _ style: UIUserInterfaceStyle) -> SIMD3<Double> {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.displayGamut = .P3
        }
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let unit = { (value: CGFloat) in min(max(Double(value), 0), 1) }
        return SIMD3(unit(red), unit(green), unit(blue))
    }

    private func decode(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func encode(_ value: Double) -> Double {
        let c = min(max(value, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// A glow's color at a point: the stops (system colors at angles in
    /// turns) interpolated in linear light around the circle, at the
    /// point's angle around the glass's center with the glass scaled to a
    /// square (0 at the top, clockwise), sRGB-encoded.
    private func gradientColor(
        at point: CGPoint, glass: CGRect, stops: [(UIColor, Double)], style: UIUserInterfaceStyle
    ) -> SIMD3<Double> {
        let x = Double((point.x - glass.midX) / (glass.width / 2))
        let y = Double((point.y - glass.midY) / (glass.height / 2))
        var turn = atan2(x, -y) / (2 * .pi)
        turn -= turn.rounded(.down)
        let linear = stops.map { stop in
            let c = components(of: stop.0, style)
            return SIMD3(decode(c.x), decode(c.y), decode(c.z))
        }
        let turns = stops.map(\.1)
        let following = turns.lastIndex { $0 <= turn }.map { $0 + 1 } ?? 0
        let previous = (following + stops.count - 1) % stops.count, next = following % stops.count
        let start = following == 0 ? turns[previous] - 1 : turns[previous]
        let end = following == stops.count ? turns[next] + 1 : turns[next]
        let fraction = (turn - start) / (end - start)
        let mixed = linear[previous] + (linear[next] - linear[previous]) * fraction
        return SIMD3(encode(mixed.x), encode(mixed.y), encode(mixed.z))
    }

    /// The `energy` preset's stops: cyan at the top, purple at the bottom.
    private let energyStops: [(UIColor, Double)] = [(.systemCyan, 0), (.systemPurple, 0.5)]
    /// The `aurora` preset's stops: cyan, indigo, pink, and yellow at 0°,
    /// 90°, 180°, and 270°.
    private let auroraStops: [(UIColor, Double)] = [(.systemCyan, 0), (.systemIndigo, 0.25), (.systemPink, 0.5), (.systemYellow, 0.75)]

    /// The documented halo profile: `Φ((outset − s) / σ)` of the halo's
    /// intensity, with the outline grown by 0.355 × radius and a Gaussian
    /// of 0.216 × radius.
    private func haloProfile(atDistance s: Double, radius: Double) -> Double {
        let outset = 0.355 * radius, sigma = 0.216 * radius
        return 0.5 * erfc(-((outset - s) / sigma) / 2.0.squareRoot())
    }

    /// The two screenshots of one launch: with the glow (pulse settled) and
    /// with the Native glow switch off, and the glass's frame.
    @MainActor
    private func screenshots(
        preset: String, appearance: String
    ) throws -> (on: SRGBPixels, off: SRGBPixels, glass: CGRect, scale: Double) {
        let (app, diagnostics) = launch(["-lab.nativeGlow", preset, "-lab.source", "pattern", "-lab.appearance", appearance])
        XCTAssertTrue(wait(for: diagnostics, toContain: "· \(appearance) ·"), diagnostics.label)
        try waitForDiagnostics(diagnostics) { $0.surfaceVisible }
        Thread.sleep(forTimeInterval: 0.5)
        // The pulse starts when the scene is active, after the last draw
        // refreshed the diagnostics; a tap refreshes them.
        _ = try freshCount(app, diagnostics)
        if preset == "energy" {
            XCTAssertTrue(wait(for: diagnostics, toContain: "Native glow: energy · 2 colors · rim 2.0 pt · halo 28 pt · 0.90 · pulse 1.8 s × 0.55 · animation running"), diagnostics.label)
            // Settle the pulse so both screenshots show the same level.
            app.switches["lab.glowPulse"].tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "Native glow: energy · 2 colors · rim 2.0 pt · halo 28 pt · 0.90 · no pulse · animation stopped"), diagnostics.label)
        } else {
            XCTAssertTrue(wait(for: diagnostics, toContain: "Native glow: \(preset) ·"), diagnostics.label)
        }
        Thread.sleep(forTimeInterval: 0.5)
        let glass = app.otherElements["lab.nativeGlass"].frame
        let elementsWithGlow = app.descendants(matching: .any).count
        let on = try SRGBPixels(app.screenshot().image)

        app.switches["lab.nativeGlowEnabled"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native glow: off · 0 colors"), diagnostics.label)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.otherElements["lab.nativeGlass"].frame, glass, "The glow moved the glass")
        let off = try SRGBPixels(app.screenshot().image)
        // The glow adds no accessibility element, and the control works.
        XCTAssertEqual(app.descendants(matching: .any).count, elementsWithGlow)
        app.buttons["lab.nativeButton"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 2 ·"), diagnostics.label)
        let scale = Double(on.width) / Double(app.windows.firstMatch.frame.width)
        app.terminate()
        return (on, off, glass, scale)
    }

    /// The center, in points, of the screenshot pixel that contains `point`.
    private func pixelCenter(_ point: CGPoint, _ scale: Double) -> CGPoint {
        CGPoint(
            x: ((Double(point.x) * scale).rounded(.down) + 0.5) / scale,
            y: ((Double(point.y) * scale).rounded(.down) + 0.5) / scale
        )
    }

    private func pixel(_ image: SRGBPixels, _ point: CGPoint, _ scale: Double) -> SIMD3<Double> {
        let c = image.color(x: Int((Double(point.x) * scale).rounded(.down)), y: Int((Double(point.y) * scale).rounded(.down)))
        return SIMD3(Double(c.0), Double(c.1), Double(c.2)) / 255
    }

    /// The largest difference, in 8-bit steps, between the two screenshots
    /// over the flat part of the capsule at least `depth` points inside its
    /// outline.
    private func middleDifference(_ shots: (on: SRGBPixels, off: SRGBPixels, glass: CGRect, scale: Double), depth: CGFloat) -> Double {
        let inner = shots.glass.insetBy(dx: shots.glass.height / 2, dy: depth)
        var largest = 0.0
        for y in stride(from: Double(inner.minY), to: Double(inner.maxY), by: 1 / shots.scale) {
            for x in stride(from: Double(inner.minX), to: Double(inner.maxX), by: 1 / shots.scale) {
                let point = CGPoint(x: x, y: y)
                largest = max(largest, abs(pixel(shots.on, point, shots.scale) - pixel(shots.off, point, shots.scale)).max() * 255)
            }
        }
        return largest
    }

    /// A rim-only glow (`aurora`: cyan, indigo, pink, and yellow at 0°, 90°,
    /// 180°, and 270°) shows each color one point inside the outline, and
    /// leaves Apple's glass exactly as it is from 6 points in: GlassWeave
    /// draws nothing inside but the rim band.
    @MainActor
    func testARimShowsEachColorAndLeavesTheGlassUnchangedInside() throws {
        var report: [String] = []
        for (appearance, style) in [("dark", UIUserInterfaceStyle.dark), ("light", .light)] {
            let shots = try screenshots(preset: "aurora", appearance: appearance)
            let glass = shots.glass
            // One point inside the outline at each stop's angle; the color
            // is the gradient's at the pixel's own angle (a fraction of a
            // degree from the stop).
            let probes: [(CGPoint, String)] = [
                (CGPoint(x: glass.midX, y: glass.minY + 1), "top"),
                (CGPoint(x: glass.maxX - 1, y: glass.midY), "right"),
                (CGPoint(x: glass.midX, y: glass.maxY - 1), "bottom"),
                (CGPoint(x: glass.minX + 1, y: glass.midY), "left"),
            ]
            for (point, side) in probes {
                let shown = pixel(shots.on, point, shots.scale) * 255
                let center = pixelCenter(point, shots.scale)
                let expected = gradientColor(at: center, glass: glass, stops: auroraStops, style: style) * 255
                report.append("\(appearance) rim \(side): \(shown), expected \(expected)")
                // Core Animation renders a conic gradient within a few steps
                // of the requested color; next to a stop whose neighbour
                // differs steeply in an encoded channel (yellow's blue rising
                // toward cyan) it measured up to 9 steps off.
                XCTAssertLessThanOrEqual(abs(shown - expected).max(), 12, report.last!)
            }
            let middle = middleDifference(shots, depth: 6)
            report.append("\(appearance) middle from 6 pt in: largest difference \(middle) steps")
            XCTAssertLessThanOrEqual(middle, 2, report.last!)
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "native-rim-pixels.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The `energy` glow's halo, above the flat top edge over the pattern's
    /// yellow quarter: its opacity, read from the blue channel
    /// (source-over: shown = color × a + background × (1 − a)), follows the
    /// documented profile, and from its layers' reach on the screen is the
    /// background. The rim is the glow color. The halo lies over Apple's
    /// material outside the outline only (its layers are hosted in the
    /// glass's content), so the glass neither covers nor samples it, and the
    /// glass's middle is unchanged.
    @MainActor
    func testAHaloFollowsItsProfileOutsideAppleGlass() throws {
        var report: [String] = []
        for (appearance, style) in [("dark", UIUserInterfaceStyle.dark), ("light", .light)] {
            let shots = try screenshots(preset: "energy", appearance: appearance)
            let glass = shots.glass
            let x = glass.midX + 30
            for s in [2.0, 7, 14, 21, 28] {
                let point = CGPoint(x: x, y: glass.minY - s)
                let color = gradientColor(at: pixelCenter(point, shots.scale), glass: glass, stops: energyStops, style: style)
                let background = pixel(shots.off, point, shots.scale), shown = pixel(shots.on, point, shots.scale)
                let alpha = (shown.z - background.z) / (color.z - background.z)
                let expected = 0.9 * haloProfile(atDistance: s, radius: 28)
                report.append("\(appearance) halo at \(s) pt: alpha \(String(format: "%.3f", alpha)), expected \(String(format: "%.3f", expected)), shown \(shown * 255), background \(background * 255)")
                XCTAssertEqual(alpha, expected, accuracy: 0.06, report.last!)
            }
            for point in [CGPoint(x: x, y: glass.minY - 40), CGPoint(x: glass.maxX + 40, y: glass.midY), CGPoint(x: glass.minX - 40, y: glass.midY)] {
                let difference = abs(pixel(shots.on, point, shots.scale) - pixel(shots.off, point, shots.scale)).max() * 255
                report.append("\(appearance) beyond the halo at \(point): difference \(difference)")
                XCTAssertLessThanOrEqual(difference, 1, report.last!)
            }
            let rimPoint = CGPoint(x: x, y: glass.minY + 1)
            let rim = pixel(shots.on, rimPoint, shots.scale) * 255
            let expectedRim = gradientColor(at: pixelCenter(rimPoint, shots.scale), glass: glass, stops: energyStops, style: style) * 255
            report.append("\(appearance) rim: \(rim), expected \(expectedRim)")
            XCTAssertLessThanOrEqual(abs(rim - expectedRim).max(), 8, report.last!)
            for depth in [6.0, 12, 18] {
                let middle = middleDifference(shots, depth: depth)
                report.append("\(appearance) middle from \(depth) pt in: largest difference \(middle) steps")
                // Measured 0 steps. (With the halo below the glass, before
                // the glow moved into the glass's content, Apple's glass
                // picked up 10 to 43 steps of it by itself.)
                XCTAssertLessThanOrEqual(middle, 2, report.last!)
            }
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "native-halo-pixels.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Pulse

    /// The pulse is a Core Animation animation: while it runs the native
    /// button takes taps, and the custom surface (over the still pattern,
    /// without a glow of its own) submits nothing.
    @MainActor
    func testTheNativeButtonWorksDuringThePulseAndNothingIsRendered() throws {
        let (app, diagnostics) = launch(["-lab.nativeGlow", "energy", "-lab.source", "pattern"])
        try waitForDiagnostics(diagnostics) { $0.surfaceVisible && $0.submitted >= 1 }
        Thread.sleep(forTimeInterval: 0.5)
        let start = try freshCount(app, diagnostics)
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 1 ·"), diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "pulse 1.8 s × 0.55 · animation running"), diagnostics.label)

        // Taps during the pulse, a second apart, reach the native button.
        let button = app.buttons["lab.nativeButton"]
        for expected in 2...4 {
            Thread.sleep(forTimeInterval: 0.6)
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: \(expected) ·"), diagnostics.label)
        }
        XCTAssertTrue(diagnostics.label.contains("animation running"), diagnostics.label)
        Thread.sleep(forTimeInterval: 1.5)
        let later = try freshCount(app, diagnostics)
        XCTAssertEqual(later.submitted, start.submitted, "The native pulse made the custom surface draw: \(diagnostics.label)")

        // Settled by the Pulse switch: no animation.
        app.switches["lab.glowPulse"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "no pulse · animation stopped"), diagnostics.label)
        app.switches["lab.glowPulse"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "animation running"), diagnostics.label)

        // Hidden with the stage, and in the background: no animation, and it
        // runs again when shown.
        let stageSwitch = app.switches["lab.stageVisible"]
        stageSwitch.tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "animation stopped"), diagnostics.label)
        stageSwitch.tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "animation running"), diagnostics.label)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        try waitForDiagnostics(diagnostics) { $0.surfaceVisible }
        Thread.sleep(forTimeInterval: 0.5)
        let back = try freshCount(app, diagnostics)
        XCTAssertEqual(back.sceneState, "active", diagnostics.label)
        XCTAssertTrue(wait(for: diagnostics, toContain: "animation running"), diagnostics.label)
    }

    /// Reduce Motion holds the rim and halo at the pulse's mean level
    /// (0.90 × (1 − 0.55 / 2) = 0.65) with no animation; Reduce Transparency
    /// keeps a 2-point rim and no halo or pulse.
    @MainActor
    func testReduceMotionAndReduceTransparencySettleTheNativeGlow() throws {
        var (app, diagnostics) = launch(["-lab.nativeGlow", "energy", "-lab.source", "pattern", "-lab.reduceMotion", "YES"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native glow: energy · 2 colors · rim 2.0 pt · halo 28 pt · 0.65 · no pulse · animation stopped"), diagnostics.label)
        app.terminate()
        (app, diagnostics) = launch(["-lab.nativeGlow", "energy", "-lab.source", "pattern", "-lab.reduceTransparency", "YES"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native glow: energy · 2 colors · rim 2.0 pt · halo 0 pt · 0.00 · no pulse · animation stopped"), diagnostics.label)
        app.buttons["lab.nativeButton"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "Native taps: 1 ·"), diagnostics.label)
    }

    // MARK: Layout and accessibility

    /// The rim follows the glass when its frame changes: after rotating to
    /// landscape and back, and at the largest accessibility text size (a
    /// taller capsule), one point inside the top edge is the glow color.
    @MainActor
    func testTheGlowFollowsTheGlassThroughRotationAndTextSize() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        var report: [String] = []
        for textSize in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let (app, diagnostics) = launch([
                "-lab.nativeGlow", "energy", "-lab.source", "pattern", "-lab.appearance", "dark",
                "-UIPreferredContentSizeCategoryName", textSize,
            ])
            try waitForDiagnostics(diagnostics) { $0.surfaceVisible }
            app.switches["lab.glowPulse"].tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "no pulse · animation stopped"), diagnostics.label)
            for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                Thread.sleep(forTimeInterval: 1.5)
                let button = app.buttons["lab.nativeButton"]
                if !button.isHittable {
                    app.scrollViews["lab.stageScroll"].swipeUp()
                    Thread.sleep(forTimeInterval: 1)
                }
                XCTAssertTrue(button.isHittable, "\(textSize) \(orientation.rawValue)")
                // The stage's own screenshot is upright in every orientation;
                // work in its coordinates.
                let stage = app.otherElements["lab.stage"]
                let stageFrame = stage.frame
                let glass = app.otherElements["lab.nativeGlass"].frame.offsetBy(dx: -stageFrame.minX, dy: -stageFrame.minY)
                let shot = try SRGBPixels(stage.screenshot().image)
                let scale = Double(shot.width) / Double(stageFrame.width)
                let point = CGPoint(x: glass.midX + 0.2 * glass.width, y: glass.minY + 1)
                let shown = pixel(shot, point, scale) * 255
                let expected = gradientColor(at: pixelCenter(point, scale), glass: glass, stops: energyStops, style: .dark) * 255
                report.append("\(textSize) orientation \(orientation.rawValue) glass \(glass): rim \(shown), expected \(expected)")
                XCTAssertLessThanOrEqual(abs(shown - expected).max(), 12, report.last!)
            }
            if textSize.hasSuffix("XXXL") {
                XCTAssertGreaterThan(app.otherElements["lab.nativeGlass"].frame.height, 70, "The glass did not grow with the text")
            }
            app.terminate()
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "native-glow-layout.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Xcode's accessibility audit with the native glow on, in light and
    /// dark: the glow adds no element and breaks no check.
    @MainActor
    func testAccessibilityAuditWithTheNativeGlow() throws {
        defer { XCUIDevice.shared.appearance = .light }
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.orientation = .portrait
            XCUIDevice.shared.appearance = appearance
            let app = XCUIApplication()
            app.launchArguments += ["-lab.nativeGlow", "energy"]
            app.launch()
            let diagnostics = app.staticTexts["lab.diagnostics"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
            let style = appearance == .dark ? "· dark ·" : "· light ·"
            guard wait(for: diagnostics, toContain: style) else {
                throw XCTSkip("The system appearance \(style) did not reach the app on this simulator: \(diagnostics.label)")
            }
            // Still screenshots for the audit: the source paused, the pulse
            // settled.
            app.buttons["lab.pause"].tap()
            app.switches["lab.glowPulse"].tap()
            XCTAssertTrue(wait(for: diagnostics, toContain: "no pulse · animation stopped"), diagnostics.label)
            var reported: [String] = []
            try app.performAccessibilityAudit { issue in
                reported.append("\(issue.compactDescription): \(issue.detailedDescription) element: \(issue.element?.debugDescription ?? "none")")
                return true
            }
            XCTAssertTrue(reported.isEmpty, "\(style): \(reported)")
            app.terminate()
        }
    }

    /// Without the launch argument the reference is plain native glass.
    @MainActor
    func testNoNativeGlowWithoutTheLaunchArgument() throws {
        let (app, diagnostics) = launch(["-lab.source", "pattern"])
        XCTAssertTrue(wait(for: diagnostics, toContain: "Panel: glass"), diagnostics.label)
        XCTAssertFalse(diagnostics.label.contains("Native glow:"), diagnostics.label)
        XCTAssertFalse(app.switches["lab.nativeGlowEnabled"].exists)
    }
}


