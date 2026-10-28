import UIKit
import XCTest

/// The controls that start and stop a drive stay on screen in every shape
/// the window can take, and a rotation never interrupts the recording. Runs
/// on the labelled demo backend, whose replayed track ticks in real time.
@MainActor
final class AdaptiveLayoutUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        if (testRun?.totalFailureCount ?? 0) > 0 {
            let test = name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test"
            snap("zz-failed-\(test)")
        }
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Drive opens full screen at launch (it's reached from You or Explore).
        app.launchArguments = ["-PullUpDemo", "-PullUpResetDefaults", "-PullUpTab", "drive"] + extra
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? shot.pngRepresentation.write(to: url)
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func settle(_ seconds: Double = 0.8) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    private func rotate(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        settle(2)
    }

    /// Opens the picker, checks Start recording can be tapped, and starts a
    /// drive with the preselected vehicle.
    private func startDrive(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let start = app.buttons["start-drive"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), file: file, line: line)
        settle(1.5)
        let confirm = app.buttons["picker-confirm"]
        start.tap()
        if !confirm.waitForExistence(timeout: 10), start.isHittable { start.tap() }
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The picker should open", file: file, line: line)
        settle()
        XCTAssertTrue(confirm.isHittable, "Start recording must be on screen", file: file, line: line)
        confirm.tap()
        XCTAssertTrue(element(app, "hold-to-stop").waitForExistence(timeout: 10), "The live dashboard should appear", file: file, line: line)
        settle(2)
    }

    private func assertControlsReachable(_ app: XCUIApplication, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(app, "hold-to-stop").isHittable, "Hold to stop must be on screen \(when)", file: file, line: line)
        XCTAssertTrue(element(app, "discard-drive").isHittable, "Discard must be on screen \(when)", file: file, line: line)
    }

    /// Seconds recorded so far, read from the spoken value of the REC timer
    /// ("1 minute, 5 seconds").
    private func elapsed(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let timer = element(app, "live-elapsed")
        XCTAssertTrue(timer.exists, "The REC timer should be on screen", file: file, line: line)
        let spoken = (timer.value as? String) ?? ""
        var seconds = 0
        var number: Int?
        for word in spoken.split(whereSeparator: { $0 == " " || $0 == "," }) {
            if let value = Int(word) {
                number = value
            } else if let value = number {
                if word.hasPrefix("hour") { seconds += value * 3600 }
                if word.hasPrefix("minute") { seconds += value * 60 }
                if word.hasPrefix("second") { seconds += value }
                number = nil
            }
        }
        return seconds
    }

    // MARK: Tests

    func testStopStaysReachableAndRecordingSurvivesRotation() throws {
        let app = launch()
        startDrive(app)
        assertControlsReachable(app, "in portrait")
        let vehicle = element(app, "live-vehicle-name").label
        let first = elapsed(app)
        snap("70-live-portrait")

        rotate(.landscapeLeft)
        assertControlsReachable(app, "in landscape")
        let second = elapsed(app)
        XCTAssertGreaterThan(second, first, "The drive should keep recording through the rotation")
        XCTAssertEqual(element(app, "live-vehicle-name").label, vehicle, "Still the same drive")
        snap("71-live-landscape")

        rotate(.portrait)
        assertControlsReachable(app, "back in portrait")
        settle(1.5)
        let third = elapsed(app)
        XCTAssertGreaterThan(third, second, "The drive should keep recording after rotating back")
        XCTAssertEqual(element(app, "live-vehicle-name").label, vehicle, "Still the same drive")
        snap("72-live-portrait-again")
    }

    func testStartAndStopReachableInLandscape() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["start-drive"].waitForExistence(timeout: 10))
        rotate(.landscapeLeft)
        startDrive(app)
        assertControlsReachable(app, "in landscape")
        snap("73-live-landscape-from-start")
    }

    func testStopStaysReachableAtTheLargestTextSize() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        startDrive(app)
        assertControlsReachable(app, "at the largest text size")
        let first = elapsed(app)
        snap("74-live-largest-text")

        rotate(.landscapeLeft)
        assertControlsReachable(app, "at the largest text size in landscape")
        snap("75-live-largest-text-landscape")

        rotate(.portrait)
        assertControlsReachable(app, "at the largest text size back in portrait")
        XCTAssertGreaterThan(elapsed(app), first, "The drive should keep recording")
    }
}
