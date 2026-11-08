import CoreGraphics
import UIKit
import XCTest

/// The custom region presents the app-owned four-corner pattern through
/// GlassWeave's `MTKView` host. These tests read the rendered pixels back from
/// element screenshots, so they check what reaches the screen rather than
/// what the code intends.
final class CustomSurfaceUITests: XCTestCase {
    private enum Swatch: String {
        case red, green, blue, yellow, gray, other
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPatternStaysUprightThroughRotation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
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
        let app = XCUIApplication()
        app.launch()
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

/// An image redrawn upright into 8-bit sRGB RGBA memory, row 0 on top.
private struct SRGBPixels {
    struct Failure: Error {}

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: UIImage) throws {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure() }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Flip so UIKit drawing (origin top-left) lands with row 0 on top,
            // and let UIImage apply its orientation.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { throw Failure() }
        self.width = width
        self.height = height
        self.bytes = pixels
    }

    func color(x: Int, y: Int) -> (Int, Int, Int) {
        let index = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }
}
