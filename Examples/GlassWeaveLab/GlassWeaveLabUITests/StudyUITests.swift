import XCTest

/// GW-29: the material studies (pearl, pill, shelf and vessel). `-lab.study <name>`
/// opens a study as the window's root, `-lab.studyTime <s>` pins its script,
/// `-lab.studyDiagnostics YES` shows the screen's own diagnostics line.
final class StudyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private struct Study {
        let name: String
        let appearance: String
        /// The native controls the study shows, by accessibility identifier.
        let controls: [String]
    }

    private let studies = [
        Study(name: "pearl", appearance: "light", controls: ["study.pearl.ring", "study.pearl.pill"]),
        Study(name: "pill", appearance: "dark", controls: ["study.pill.pause", "study.pill.time"]),
        Study(
            name: "shelf", appearance: "dark",
            controls: ["study.shelf.title", "study.shelf.previous", "study.shelf.play", "study.shelf.next"]
        ),
        Study(name: "vessel", appearance: "dark", controls: ["study.vessel.title", "study.vessel.level", "study.vessel.nudge"]),
    ]

    /// Each study launches with its script pinned at two fixed times, shows
    /// its native controls, reports that no two panels' quads overlap (rule
    /// 10) after its first draw, and writes a capture.
    @MainActor
    func testEachStudyLaunchesShowsItsNativeControlsAndWritesACapture() throws {
        for study in studies {
            for time in [0, 6] {
                let app = XCUIApplication()
                app.launchArguments += [
                    "-lab.study", study.name, "-lab.studyTime", "\(time)", "-lab.appearance", study.appearance,
                    "-lab.studyDiagnostics", "YES",
                ]
                app.launch()

                let diagnostics = app.staticTexts["study.diagnostics"]
                XCTAssertTrue(diagnostics.waitForExistence(timeout: 10), "\(study.name): no diagnostics line")
                for identifier in study.controls {
                    let control = app.descendants(matching: .any)[identifier]
                    XCTAssertTrue(control.waitForExistence(timeout: 5), "\(study.name): missing \(identifier)")
                }

                // The first draw, then the rule: no overlapping quads.
                let deadline = Date.now.addingTimeInterval(10)
                while Date.now < deadline, diagnostics.label.range(of: #"draws [1-9]"#, options: .regularExpression) == nil {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                XCTAssertNotNil(diagnostics.label.range(of: #"draws [1-9]"#, options: .regularExpression), diagnostics.label)
                XCTAssertTrue(diagnostics.label.contains("quads apart yes"), diagnostics.label)
                XCTAssertTrue(diagnostics.label.contains("t=\(time).0"), diagnostics.label)

                // The pill's native time follows the pinned script.
                if study.name == "pill" {
                    let expected = time == 0 ? "12:04" : "12:10"
                    XCTAssertEqual(app.descendants(matching: .any)["study.pill.time"].value as? String, expected)
                }

                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "study-\(study.name)-t\(time)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
