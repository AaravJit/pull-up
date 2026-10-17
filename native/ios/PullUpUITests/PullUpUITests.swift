import XCTest

/// End-to-end journeys on the labelled demo backend. Each step also saves a
/// screenshot: as an xcresult attachment, and as a PNG in SCREENSHOT_DIR when
/// CI sets it (TEST_RUNNER_SCREENSHOT_DIR), which publishes them for review.
@MainActor
final class PullUpUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PullUpDemo", "-PullUpResetDefaults"] + extra
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

    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.tabBars.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Tab \(name) missing")
        button.tap()
        settle()
    }

    // MARK: Journeys

    /// Start Drive → pick a vehicle → record → stop → summary, then check the
    /// drive landed in that vehicle's history.
    func testDriveIsRecordedAgainstThePickedVehicle() throws {
        let app = launch()
        XCTAssertTrue(element(app, "demo-strip").waitForExistence(timeout: 10), "Demo mode must always be labelled")
        let start = app.buttons["start-drive"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        settle(1.5)
        snap("01-drive-home")

        start.tap()
        let confirm = app.buttons["picker-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        settle()
        XCTAssertFalse(element(app, "live-dashboard").exists, "Opening the picker must not start recording")
        snap("02-picker")

        let bmw = app.buttons["vehicle-choice-320i xDrive"]
        XCTAssertTrue(bmw.waitForExistence(timeout: 5))
        bmw.tap()
        settle()
        XCTAssertTrue(bmw.isSelected)
        snap("03-picker-selected")

        confirm.tap()
        let vehicleName = element(app, "live-vehicle-name")
        if !vehicleName.waitForExistence(timeout: 10) { snap("debug-after-confirm") }
        XCTAssertTrue(vehicleName.exists, "Live dashboard should name the picked vehicle")
        XCTAssertTrue(vehicleName.label.contains("Daily"), "Dashboard shows \(vehicleName.label)")
        settle(16)
        snap("04-live-dashboard")
        // Replay is real time; the server-side minimum is 30 clean fixes.
        settle(22)
        snap("05-live-dashboard-later")

        let stop = element(app, "hold-to-stop")
        XCTAssertTrue(stop.exists)
        stop.press(forDuration: 1.6)

        let summaryVehicle = element(app, "summary-vehicle-name")
        XCTAssertTrue(summaryVehicle.waitForExistence(timeout: 10))
        XCTAssertEqual(summaryVehicle.label, "Daily")
        settle(2)
        snap("06-summary")
        app.swipeUp()
        settle()
        snap("07-summary-charts")
        app.buttons["summary-done"].tap()
        settle()

        tab(app, "Garage")
        snap("08-garage")
        let tile = element(app, "garage-tile-320i xDrive")
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        settle(1.5)
        snap("09-vehicle-detail")
        app.swipeUp()
        settle()
        let newDrive = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS 'Morning drive' OR label CONTAINS 'Afternoon drive' OR label CONTAINS 'Evening drive' OR label CONTAINS 'Night drive'"
        )).firstMatch
        XCTAssertTrue(newDrive.waitForExistence(timeout: 5), "The new drive should be listed under the vehicle it was recorded with")
        snap("10-vehicle-drives")
    }

    func testBrowseEveryArea() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["start-drive"].waitForExistence(timeout: 10))

        app.buttons["open-leaderboards"].tap()
        XCTAssertTrue(element(app, "leaderboards").waitForExistence(timeout: 5))
        settle(1.5)
        snap("11-leaderboards")
        app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Closed course")).firstMatch.tap()
        settle()
        snap("12-leaderboards-closed-course")

        tab(app, "Map")
        settle(4)
        snap("13-map")

        tab(app, "Feed")
        settle(1.5)
        snap("14-feed")
        app.buttons["open-profile"].tap()
        XCTAssertTrue(element(app, "profile").waitForExistence(timeout: 5))
        settle(1.5)
        snap("15-profile")
        app.buttons["open-settings"].tap()
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 5))
        settle()
        snap("16-settings")
        app.swipeUp()
        settle()
        snap("17-settings-privacy")

        tab(app, "Meets")
        settle(1.5)
        snap("18-meets")
        let meet = element(app, "meet-row-Sac Nights")
        XCTAssertTrue(meet.waitForExistence(timeout: 5))
        meet.tap()
        XCTAssertTrue(element(app, "meet-detail").waitForExistence(timeout: 5))
        settle(2)
        snap("19-meet-detail")
        app.swipeUp()
        let going = app.buttons["rsvp-going"]
        XCTAssertTrue(going.waitForExistence(timeout: 5))
        going.tap()
        settle()
        XCTAssertTrue(element(app, "rsvp-show-me").waitForExistence(timeout: 5), "Going should offer the opt-in attendee toggle")
        snap("20-meet-rsvp")
    }

    func testPickerCanBeDismissedWithoutRecording() throws {
        let app = launch()
        let start = app.buttons["start-drive"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["picker-close"].waitForExistence(timeout: 5))
        app.buttons["picker-close"].tap()
        settle()
        XCTAssertFalse(element(app, "live-dashboard").exists)
        XCTAssertTrue(start.isHittable)

        start.tap()
        let picker = element(app, "start-drive-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.swipeDown(velocity: .fast)
        settle()
        XCTAssertFalse(app.buttons["picker-confirm"].exists)
        XCTAssertFalse(element(app, "live-dashboard").exists)
    }

    func testEmptyGarageOffersAddOrGuest() throws {
        let app = launch(["-PullUpEmptyGarage"])
        let start = app.buttons["start-drive"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        if !app.buttons["picker-add-vehicle"].waitForExistence(timeout: 5) { snap("debug-empty-picker") }
        XCTAssertTrue(app.buttons["picker-add-vehicle"].exists)
        XCTAssertTrue(app.buttons["picker-start-guest"].exists)
        settle()
        snap("21-picker-empty-garage")

        app.buttons["picker-add-vehicle"].tap()
        settle()
        snap("22-add-vehicle")
    }

    func testDarkAppearance() throws {
        let app = launch(["-PullUpAppearance", "dark"])
        XCTAssertTrue(app.buttons["start-drive"].waitForExistence(timeout: 10))
        settle(1.5)
        snap("23-drive-dark")
        app.buttons["start-drive"].tap()
        XCTAssertTrue(app.buttons["picker-confirm"].waitForExistence(timeout: 5))
        settle()
        snap("24-picker-dark")
        app.buttons["picker-close"].tap()
        tab(app, "Garage")
        settle(1.5)
        snap("25-garage-dark")
        tab(app, "Feed")
        settle(1.5)
        snap("26-feed-dark")
    }

    func testLargeTextPickerUsesList() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let start = app.buttons["start-drive"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["vehicle-choice-guest"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "vehicle-carousel").exists)
        settle()
        snap("27-picker-accessibility-text")
    }

    func testSignedOutShowsAuth() throws {
        let app = launch(["-PullUpSignedOut"])
        XCTAssertTrue(element(app, "auth").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "continue-with-apple").exists, "Sign in with Apple is the primary way in")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists, "Email sign-in stays tucked away")
        settle()
        snap("28-sign-in")
        app.buttons["other-sign-in"].tap()
        settle()
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'create account'")).firstMatch.exists,
                       "There is no email sign-up")
        snap("29-sign-in-other-options")
        app.buttons["demo-sign-in"].tap()
        XCTAssertTrue(app.buttons["start-drive"].waitForExistence(timeout: 10))
    }

    /// A new Sign in with Apple account picks a username (taken names are
    /// refused live), may skip the photo, sets privacy, then lands on Drive.
    func testNewAccountOnboarding() throws {
        let app = launch(["-PullUpOnboarding"])
        XCTAssertTrue(element(app, "onboarding").waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Onboarding comes before the app")
        let field = app.textFields["onboarding-username"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("maya.s15")
        let status = element(app, "username-status")
        expectation(for: NSPredicate(format: "label CONTAINS[c] 'already'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["onboarding-continue"].isEnabled)
        snap("30-onboarding-username-taken")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "rx7_kenji")
        expectation(for: NSPredicate(format: "label CONTAINS[c] 'available'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        snap("31-onboarding-username")
        app.buttons["onboarding-continue"].tap()

        let photoNext = app.buttons["onboarding-photo-next"]
        XCTAssertTrue(photoNext.waitForExistence(timeout: 5))
        settle()
        snap("32-onboarding-photo")
        photoNext.tap()

        let finish = app.buttons["onboarding-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        settle()
        snap("33-onboarding-privacy")
        finish.tap()
        XCTAssertTrue(app.buttons["start-drive"].waitForExistence(timeout: 10), "Finishing onboarding opens the app")
    }
}
