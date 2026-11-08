import XCTest

/// The values the laboratory prints in its diagnostics label, parsed for
/// lifecycle checks.
struct LabDiagnostics {
    struct ParseFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// "Surface: visible · scene active"
    let surfaceVisible: Bool
    let sceneState: String
    /// "Frames: N submitted · K in flight (peak P of B) · ..."
    let submitted: Int
    let framesInFlight: Int
    let peakFramesInFlight: Int
    let maximumFramesInFlight: Int
    /// "Source: ... · T textures (A allocated) · ..."
    let textures: Int?
    /// "Last hidden period: N submitted"
    let hiddenPeriodSubmissions: Int?

    init(_ label: String) throws {
        guard let surface = Self.capture(#"Surface: (visible|hidden) · scene (\w+)"#, in: label) else {
            throw ParseFailure(description: "No surface line in: \(label)")
        }
        surfaceVisible = surface[0] == "visible"
        sceneState = surface[1]
        guard let frames = Self.capture(#"Frames: (\d+) submitted · (\d+) in flight \(peak (\d+) of (\d+)\)"#, in: label) else {
            throw ParseFailure(description: "No frames line in: \(label)")
        }
        submitted = Int(frames[0])!
        framesInFlight = Int(frames[1])!
        peakFramesInFlight = Int(frames[2])!
        maximumFramesInFlight = Int(frames[3])!
        textures = Self.capture(#"· (\d+) textures \("#, in: label).map { Int($0[0])! }
        hiddenPeriodSubmissions = Self.capture(#"Last hidden period: (\d+) submitted"#, in: label).map { Int($0[0])! }
    }

    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

extension XCTestCase {
    /// Polls `element`'s diagnostics until `condition` holds, for up to
    /// `timeout` seconds, and returns the last parsed value.
    @MainActor
    @discardableResult
    func waitForDiagnostics(
        _ element: XCUIElement, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line,
        until condition: (LabDiagnostics) -> Bool
    ) throws -> LabDiagnostics {
        let deadline = Date.now.addingTimeInterval(timeout)
        var last = try LabDiagnostics(element.label)
        while !condition(last) {
            guard Date.now < deadline else {
                XCTFail("Diagnostics never matched: \(element.label)", file: file, line: line)
                return last
            }
            Thread.sleep(forTimeInterval: 0.1)
            last = try LabDiagnostics(element.label)
        }
        return last
    }
}
