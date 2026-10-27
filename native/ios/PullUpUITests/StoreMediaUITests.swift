import UIKit
import XCTest

/// Drives the real app for App Store screenshots and app previews. The pixels
/// are taken by the host (`simctl io screenshot` / `recordVideo`, one display
/// at a time on iPhone Duo) through native/ios/scripts/store-media/
/// capture_daemon.py: the test writes a numbered request file into
/// STORE_MEDIA_DIR and waits for the daemon's answer.
///
/// Runs only from .github/workflows/store-media.yml, which sets
/// STORE_MEDIA_DIR; everywhere else every test here is skipped. The app runs
/// on the demo backend (fictional people, cars and meets, a replayed track)
/// with -PullUpStoreCapture, which exists in debug builds only.
@MainActor
final class StoreMediaUITests: XCTestCase {
    private static var sequence = 0

    private var mediaDir: String? { ProcessInfo.processInfo.environment["STORE_MEDIA_DIR"].flatMap { $0.isEmpty ? nil : $0 } }

    override func setUp() async throws {
        continueAfterFailure = false
        guard mediaDir != nil else { throw XCTSkip("Store media capture runs only in the Store media workflow") }
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        if mediaDir != nil, (testRun?.totalFailureCount ?? 0) > 0 {
            // What was on screen, for reading a failure from the published output.
            request("shot", "zz-failed-\(name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test")", wait: true)
        }
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    // MARK: Plumbing

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PullUpDemo", "-PullUpResetDefaults", "-PullUpStoreCapture", "-PullUpAppearance", "dark"] + extra
        // Location is granted by the workflow (simctl privacy), so no
        // permission alert can cover a capture.
        app.launch()
        // The first launch on a fresh simulator can be slow.
        let signedIn = [app.buttons["start-drive"], element(app, "map"), element(app, "garage-actions"), element(app, "open-messages")]
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !signedIn.contains(where: { $0.exists }) { settle(0.5) }
        XCTAssertTrue(signedIn.contains(where: { $0.exists }), "The app should open signed in")
        // Store capture hides the demo labels; if this fails the capture
        // switch isn't compiled into this (debug) build.
        XCTAssertFalse(element(app, "demo-strip").exists, "Store capture must run with -PullUpStoreCapture in a debug build")
        // The host checks the window is on the display it captures (Duo).
        XCTAssertTrue(request("note", "launched", app: app), "The app is on the wrong display for this capture")
        return app
    }

    /// Asks the host to act and waits for it. Actions: shot, recstart,
    /// recstop, fold, unfold, note.
    @discardableResult
    private func request(_ action: String, _ name: String = "", wait: Bool = true, app: XCUIApplication? = nil) -> Bool {
        guard let dir = mediaDir else { return false }
        Self.sequence += 1
        let id = String(format: "%04d", Self.sequence) + "-" + String(UUID().uuidString.prefix(8))
        var payload: [String: Any] = ["id": id, "action": action, "name": name, "test": self.name,
                                      "orientation": XCUIDevice.shared.orientation.rawValue]
        if let app {
            let frame = app.windows.firstMatch.frame
            payload["window"] = [Double(frame.origin.x), Double(frame.origin.y), Double(frame.width), Double(frame.height)]
        }
        let base = URL(fileURLWithPath: dir)
        let tmp = base.appendingPathComponent(".req-\(id).json")
        let final = base.appendingPathComponent("req-\(id).json")
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              (try? data.write(to: tmp)) != nil,
              (try? FileManager.default.moveItem(at: tmp, to: final)) != nil else {
            XCTFail("Couldn't write a capture request to \(dir)")
            return false
        }
        guard wait else { return true }
        let ack = base.appendingPathComponent("ack-\(id).json")
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            if let data = try? Data(contentsOf: ack),
               let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let ok = answer["ok"] as? Bool ?? false
                XCTAssertTrue(ok, "Host couldn't \(action) \(name): \(answer["error"] ?? "")")
                return ok
            }
            settle(0.2)
        }
        XCTFail("Host didn't answer \(action) \(name)")
        return false
    }

    private func shot(_ app: XCUIApplication, _ name: String, settleFor seconds: Double = 1.2) {
        settle(seconds)
        request("shot", name, app: app)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func settle(_ seconds: Double = 0.8) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    /// Tab bars can sit vertically on iPhone Duo's inner display, so fall back
    /// to any button with the tab's name.
    private func tab(_ app: XCUIApplication, _ name: String) {
        let inBar = app.tabBars.buttons[name].firstMatch
        if inBar.waitForExistence(timeout: 5) {
            inBar.tap()
            settle(1)
            return
        }
        // On the iPhone Duo outer display the tabs are a vertical bar along
        // the trailing edge, not a UITabBar, and other buttons share a tab's
        // label (the Map screen's "Meets" segment). Take the match closest
        // to the window's trailing or bottom edge, where the tab bar sits.
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", name))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), "Tab \(name) missing")
        let window = app.windows.firstMatch.frame
        let edge: (XCUIElement) -> CGFloat = { element in
            let f = element.frame
            return max(f.maxX / max(window.width, 1), f.maxY / max(window.height, 1))
        }
        let candidates = matches.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        let button = candidates.max(by: { edge($0) < edge($1) }) ?? matches.firstMatch
        button.tap()
        settle(1)
    }

    /// A slow drag, so scrolling reads well in a preview.
    private func scroll(_ app: XCUIApplication, from: CGFloat = 0.72, to: CGFloat = 0.38) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<5 where !element.isHittable { scroll(app) ; settle(0.5) }
    }

    @discardableResult
    private func openPicker(_ app: XCUIApplication) -> XCUIElement {
        let start = app.buttons["start-drive"]
        let confirm = app.buttons["picker-confirm"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        settle()
        start.tap()
        if !confirm.waitForExistence(timeout: 10), start.isHittable { start.tap() }
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Start Drive should open the picker")
        return confirm
    }

    private func pickDaily(_ app: XCUIApplication) {
        let bmw = app.buttons["vehicle-choice-320i xDrive"]
        XCTAssertTrue(bmw.waitForExistence(timeout: 5))
        bmw.tap()
    }

    private func waitForDashboard(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "live-vehicle-name").waitForExistence(timeout: 15), "Recording should open the live dashboard")
    }

    private func stopDrive(_ app: XCUIApplication) {
        let stop = element(app, "hold-to-stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.press(forDuration: 1.6)
        XCTAssertTrue(element(app, "summary-vehicle-name").waitForExistence(timeout: 15), "Stopping should show the summary")
    }

    private func openMeet(_ app: XCUIApplication) {
        let meet = element(app, "meet-row-Sac Nights")
        XCTAssertTrue(meet.waitForExistence(timeout: 10))
        settle()
        meet.tap()
        // A loaded CI simulator sometimes drops the tap; tap once more.
        if !element(app, "meet-detail").waitForExistence(timeout: 8), meet.exists, meet.isHittable { meet.tap() }
        XCTAssertTrue(element(app, "meet-detail").waitForExistence(timeout: 10))
    }

    // MARK: Screenshots

    /// The ten App Store screenshots, in product-page order.
    func testScreenshots() throws {
        let app = launch()

        let confirm = openPicker(app)
        pickDaily(app)
        shot(app, "02-start-drive")
        confirm.tap()
        waitForDashboard(app)
        let started = Date()
        settle(22)
        shot(app, "01-live-drive", settleFor: 0.2)
        // The demo backend keeps a drive of at least 30 fixes (one a second).
        let remaining = 36 - Date().timeIntervalSince(started)
        if remaining > 0 { settle(remaining) }
        stopDrive(app)
        shot(app, "03-drive-summary", settleFor: 3)
        app.buttons["summary-done"].tap()
        settle()

        tab(app, "Garage")
        shot(app, "04-garage", settleFor: 1.5)
        let daily = element(app, "garage-tile-320i xDrive")
        XCTAssertTrue(daily.waitForExistence(timeout: 5))
        daily.tap()
        shot(app, "05-vehicle", settleFor: 2)

        tab(app, "Map")
        shot(app, "06-map", settleFor: 5)

        tab(app, "Meets")
        shot(app, "07-meets", settleFor: 1.5)
        openMeet(app)
        shot(app, "08-meet-detail", settleFor: 3)

        tab(app, "Feed")
        shot(app, "09-feed", settleFor: 2)
        let messages = element(app, "open-messages")
        XCTAssertTrue(messages.waitForExistence(timeout: 5))
        messages.tap()
        let maya = element(app, "inbox-row-maya.s15")
        XCTAssertTrue(maya.waitForExistence(timeout: 10))
        maya.tap()
        XCTAssertTrue(element(app, "composer-field").waitForExistence(timeout: 10))
        shot(app, "10-messages", settleFor: 2)
    }

    /// Layout checks in the supported landscape orientations (not product
    /// page screenshots unless chosen later): a live drive, then each tab.
    func testLandscape() throws {
        let app = launch()
        let confirm = openPicker(app)
        pickDaily(app)
        confirm.tap()
        waitForDashboard(app)
        settle(8)
        XCUIDevice.shared.orientation = .landscapeLeft
        shot(app, "L01-live-drive-landscape-left", settleFor: 4)
        XCTAssertTrue(element(app, "hold-to-stop").exists, "Rotating mustn't interrupt the drive")
        XCUIDevice.shared.orientation = .landscapeRight
        shot(app, "L02-live-drive-landscape-right", settleFor: 4)
        XCUIDevice.shared.orientation = .portrait
        // Past the demo backend's 30-fix minimum before stopping.
        settle(26)
        stopDrive(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        shot(app, "L03-drive-summary-landscape", settleFor: 3)
        XCUIDevice.shared.orientation = .portrait
        settle(2)
        app.buttons["summary-done"].tap()
        settle()
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(2)
        tab(app, "Garage")
        shot(app, "L04-garage-landscape", settleFor: 2)
        tab(app, "Map")
        shot(app, "L05-map-landscape", settleFor: 5)
        tab(app, "Meets")
        shot(app, "L06-meets-landscape", settleFor: 2)
        tab(app, "Feed")
        shot(app, "L07-feed-landscape", settleFor: 2)
        XCUIDevice.shared.orientation = .portrait
        settle(2)
    }

    // MARK: App previews (each 15–30 s once trimmed)

    /// Preview 1, Drive: pick the car you're driving and start recording.
    func testPreviewDrive() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["start-drive"].waitForExistence(timeout: 10))
        settle(2)
        request("recstart", "P1-drive", app: app)
        settle(2)
        let confirm = openPicker(app)
        settle(1.5)
        pickDaily(app)
        settle(2)
        confirm.tap()
        waitForDashboard(app)
        settle(11)
        request("recstop", "P1-drive", app: app)
    }

    /// Preview 2, Garage: the vehicles, one car's details and a past drive.
    func testPreviewGarage() throws {
        let app = launch(["-PullUpTab", "garage"])
        let daily = element(app, "garage-tile-320i xDrive")
        XCTAssertTrue(daily.waitForExistence(timeout: 10))
        settle(2)
        request("recstart", "P2-garage", app: app)
        settle(2.5)
        reveal(app, daily)
        daily.tap()
        settle(2.5)
        scroll(app)
        settle(1.5)
        let drive = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Commute'")).firstMatch
        reveal(app, drive)
        drive.tap()
        XCTAssertTrue(element(app, "drive-summary").waitForExistence(timeout: 10) || element(app, "summary-vehicle-name").waitForExistence(timeout: 5))
        settle(3)
        scroll(app)
        settle(2)
        request("recstop", "P2-garage", app: app)
    }

    /// Preview 3, Maps, meets and community: meets on the map, a meet's
    /// details and RSVP, then the feed.
    func testPreviewCommunity() throws {
        let app = launch(["-PullUpTab", "map"])
        XCTAssertTrue(element(app, "map").waitForExistence(timeout: 10))
        settle(5)
        request("recstart", "P3-community", app: app)
        settle(2.5)
        tab(app, "Meets")
        settle(1)
        openMeet(app)
        settle(2)
        let going = app.buttons["rsvp-going"]
        reveal(app, going)
        going.tap()
        settle(1.5)
        tab(app, "Feed")
        settle(2.5)
        request("recstop", "P3-community", app: app)
    }
}
