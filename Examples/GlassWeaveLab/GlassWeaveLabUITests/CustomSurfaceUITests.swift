import CoreGraphics
import UIKit
import XCTest

/// The custom surface presents the app-owned four-corner pattern through
/// GlassWeave's `MTKView` host. These tests read the rendered pixels back from
/// element screenshots, so they check what reaches the screen rather than
/// what the code intends. The laboratory shows the still pattern instead of
/// its moving background when launched with `-lab.source pattern`.
final class CustomSurfaceUITests: XCTestCase {
    /// The laboratory with the still orientation pattern as its source.
    @MainActor
    private func launchWithPattern() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-lab.source", "pattern"]
        app.launch()
        return app
    }

    private enum Swatch: String {
        case red, green, blue, yellow, gray, other
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPatternStaysUprightThroughRotation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchWithPattern()
        let surface = app.otherElements["lab.customSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let corners = try waitForUprightCorners(of: surface)
            XCTAssertEqual(corners, [.red, .green, .blue, .yellow], "orientation \(orientation.rawValue)")
            XCTAssertTrue(diagnostics.label.contains("submitted frame 1"), diagnostics.label)
        }
    }

    @MainActor
    func testResetPresentsANewFrameAndReleasesThePreviousOne() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchWithPattern()
        let diagnostics = app.staticTexts["lab.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: diagnostics, toContain: "submitted frame 1"), diagnostics.label)

        app.buttons["lab.reset"].tap()
        XCTAssertTrue(wait(for: diagnostics, toContain: "submitted frame 2"), diagnostics.label)
        // Frame 1 is released only after the surface let go of it and its
        // submitted draws completed; no draw of it was skipped.
        XCTAssertTrue(wait(for: diagnostics, toContain: "Released frame 1:"), diagnostics.label)
        XCTAssertTrue(diagnostics.label.contains("0 skipped"), diagnostics.label)

        let corners = try waitForUprightCorners(of: app.otherElements["lab.customSurface"])
        XCTAssertEqual(corners, [.red, .green, .blue, .yellow])
    }

    // MARK: Helpers

    /// Waits until the surface shows an upright pattern (rotation settles
    /// asynchronously), then returns the swatches seen at its corners in the
    /// order top-left, top-right, bottom-left, bottom-right.
    @MainActor
    private func waitForUprightCorners(of surface: XCUIElement) throws -> [Swatch] {
        let expected: [Swatch] = [.red, .green, .blue, .yellow]
        var corners: [Swatch] = []
        let deadline = Date.now.addingTimeInterval(10)
        repeat {
            corners = try cornerSwatches(of: surface.screenshot().image)
            if corners == expected { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date.now < deadline
        return corners
    }

    /// Classifies the pixels 10% in from each corner of `image`.
    @MainActor
    private func cornerSwatches(of image: UIImage) throws -> [Swatch] {
        let pixels = try SRGBPixels(image)
        let points: [(Double, Double)] = [(0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)]
        return points.map { u, v in
            let (r, g, b) = pixels.color(x: Int(u * Double(pixels.width)), y: Int(v * Double(pixels.height)))
            return Self.classify(red: r, green: g, blue: b)
        }
    }

    /// The nearest reference color within a tolerance that allows for the
    /// screenshot's color management, or `.other`.
    private static func classify(red: Int, green: Int, blue: Int) -> Swatch {
        let references: [(Swatch, (Int, Int, Int))] = [
            (.red, (255, 0, 0)), (.green, (0, 255, 0)), (.blue, (0, 0, 255)),
            (.yellow, (255, 255, 0)), (.gray, (128, 128, 128)),
        ]
        let nearest = references.min { a, b in
            distance(a.1, (red, green, blue)) < distance(b.1, (red, green, blue))
        }!
        return distance(nearest.1, (red, green, blue)) <= 60 ? nearest.0 : .other
    }

    private static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    private func wait(for element: XCUIElement, toContain text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }
}
