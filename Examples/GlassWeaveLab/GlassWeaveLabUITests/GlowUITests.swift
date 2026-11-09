import UIKit
import XCTest

/// GW-17 in the laboratory: `-lab.glow aurora` gives the custom panel a
/// four-stop gradient glow (cyan at the top, indigo at the right, pink at the
/// bottom, yellow at the left, as system colors resolved for the
/// appearance). The colors are read back from screenshots of the running
/// app, so they check what the UIKit host puts on screen. The still pattern
/// source keeps every screenshot the same.
final class GlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["lab.diagnostics"].waitForExistence(timeout: 10))
        return app
    }

    /// The sRGB bytes of a system color in an appearance.
    private func bytes(of color: UIColor, _ style: UIUserInterfaceStyle) -> (Int, Int, Int) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return (byte(red), byte(green), byte(blue))
    }

    @MainActor
    func testGradientGlowShowsEachColorOnTheRimAtItsAngle() throws {
        for (appearance, style) in [("dark", UIUserInterfaceStyle.dark), ("light", .light)] {
            let app = launch(["-lab.glow", "aurora", "-lab.appearance", appearance, "-lab.source", "pattern"])
            let diagnostics = app.staticTexts["lab.diagnostics"]
            XCTAssertTrue(wait(for: diagnostics, toContain: "Glow: aurora · 4 colors · rim 2.0 pt · inner 0.70 · center 0.00"), diagnostics.label)
            XCTAssertTrue(wait(for: diagnostics, toContain: "· \(appearance) ·"), diagnostics.label)
            let panel = app.otherElements["lab.customPanel"].frame
            let pixels = try SRGBPixels(app.screenshot().image)
            let scale = Double(pixels.width) / Double(app.windows.firstMatch.frame.width)
            // One point inside the outline, in the middle of each edge: the
            // stop angles 0°, 90°, 180°, and 270°.
            let probes: [(CGPoint, UIColor, String)] = [
                (CGPoint(x: panel.midX, y: panel.minY + 1), .systemCyan, "top"),
                (CGPoint(x: panel.maxX - 1, y: panel.midY), .systemIndigo, "right"),
                (CGPoint(x: panel.midX, y: panel.maxY - 1), .systemPink, "bottom"),
                (CGPoint(x: panel.minX + 1, y: panel.midY), .systemYellow, "left"),
            ]
            var report: [String] = []
            for (point, color, side) in probes {
                let sample = pixels.color(x: Int(point.x * scale), y: Int(point.y * scale))
                let expected = bytes(of: color, style)
                let difference = max(abs(sample.0 - expected.0), abs(sample.1 - expected.1), abs(sample.2 - expected.2))
                report.append("\(appearance) \(side): \(sample), expected \(expected), difference \(difference)")
                XCTAssertLessThanOrEqual(difference, 6, report.last!)
            }
            let attachment = XCTAttachment(string: report.joined(separator: "\n"))
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    /// Without the launch argument the panel has no glow and the
    /// diagnostics say nothing about one.
    @MainActor
    func testNoGlowWithoutTheLaunchArgument() throws {
        let app = launch(["-lab.source", "pattern"])
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(wait(for: diagnostics, toContain: "Panel: glass"), diagnostics.label)
        XCTAssertFalse(diagnostics.label.contains("Glow:"), diagnostics.label)
    }

    @MainActor
    private func wait(for element: XCUIElement, toContain text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }
}
