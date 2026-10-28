import XCTest

/// End-to-end journeys on the labelled demo backend. Each step also saves a
/// screenshot: as an xcresult attachment, and as a PNG in SCREENSHOT_DIR when
/// CI sets it (TEST_RUNNER_SCREENSHOT_DIR), which publishes them for review.
@MainActor
final class PullUpUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Saves what was on screen when a test failed, so CI failures can be
    /// read from the published screenshots without the result bundle.
    override func tearDown() async throws {
        if (testRun?.totalFailureCount ?? 0) > 0 {
            let test = name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test"
            snap("zz-failed-\(test)")
        }
        try await super.tearDown()
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

    /// The simulator sometimes offers "Enable Dictation?" a few seconds
    /// after the keyboard appears; it isn't the app's, so decline it. The
    /// prompt isn't always hosted by SpringBoard, so the keyboard and Siri
    /// processes are checked too. It is also checked (without waiting)
    /// before every tab switch.
    private func dismissSystemPrompts(_ app: XCUIApplication, timeout: TimeInterval = 1) {
        let hosts = [app] + ["com.apple.springboard", "com.apple.InputUI", "com.apple.siri"]
            .map { XCUIApplication(bundleIdentifier: $0) }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for host in hosts {
                let notNow = host.buttons["Not Now"].firstMatch
                if notNow.exists {
                    notNow.tap()
                    settle(0.5)
                    return
                }
            }
            if timeout > 0 { settle(0.25) }
        } while Date() < deadline
    }

    /// The caption is ready to type into: the keyboard is up, or (with a
    /// hardware keyboard attached to the simulator) the field has focus.
    private func readyToType(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) { return true }
        return (field.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        dismissSystemPrompts(app, timeout: 0)
        let button = app.tabBars.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Tab \(name) missing")
        button.tap()
        settle()
    }

    /// Explore's segmented control: Meets, Map or People.
    private func explore(_ app: XCUIApplication, _ mode: String) {
        tab(app, "Explore")
        let segment = element(app, "explore-mode").buttons[mode]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "Explore ▸ \(mode) missing")
        segment.tap()
        settle()
    }

    /// Taps the leading back button and waits for the pop to finish (a tap
    /// during the previous pop's animation is dropped).
    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        settle()
    }

    /// The main tabs are on screen (signed in, onboarding done).
    private func waitForTabs(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.tabBars.buttons["Feed"].firstMatch.waitForExistence(timeout: 15), "The app should open on its tabs", file: file, line: line)
    }

    /// One pixel of a screenshot, as 0–255 RGB.
    private func pixel(_ shot: XCUIScreenshot, x: CGFloat, y: CGFloat) -> (r: Int, g: Int, b: Int) {
        guard let cg = shot.image.cgImage else { return (-1, -1, -1) }
        let px = min(cg.width - 1, max(0, Int(x * CGFloat(cg.width))))
        let py = min(cg.height - 1, max(0, Int(y * CGFloat(cg.height))))
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (-1, -1, -1) }
        context.draw(cg, in: CGRect(x: -CGFloat(px), y: -CGFloat(cg.height - 1 - py), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    /// Taps Start Drive and waits for `shown` in the picker. A loaded CI
    /// simulator sometimes drops the tap or takes seconds to present the
    /// sheet, so this waits longer and taps once more if the button is
    /// still on screen.
    @discardableResult
    private func openPicker(_ app: XCUIApplication, until shown: XCUIElement) -> Bool {
        let start = app.buttons["start-drive"]
        // Let the Drive screen settle after launch first: in CI a tap made
        // straight after launch once opened Leaderboards instead of the picker.
        _ = start.waitForExistence(timeout: 10)
        settle()
        start.tap()
        if shown.waitForExistence(timeout: 10) { return true }
        if start.isHittable { start.tap() }
        return shown.waitForExistence(timeout: 10)
    }

    /// Taps a meet row and waits for `shown` on its detail page. A loaded CI
    /// simulator sometimes drops the tap (the list stays on screen), so this
    /// taps once more if the row is still there and hittable.
    @discardableResult
    private func openMeet(_ app: XCUIApplication, _ row: XCUIElement, until shown: XCUIElement) -> Bool {
        settle()
        row.tap()
        if shown.waitForExistence(timeout: 8) { return true }
        if row.exists && row.isHittable { row.tap() }
        return shown.waitForExistence(timeout: 10)
    }

    /// Closes the picker and waits for the sheet to go. As with Start Drive,
    /// a loaded CI simulator sometimes drops the tap, leaving the sheet over
    /// the tab bar. testPickerCanBeDismissedWithoutRecording checks a single
    /// tap closes it.
    private func closePicker(_ app: XCUIApplication) {
        let close = app.buttons["picker-close"]
        close.tap()
        if close.waitForNonExistence(timeout: 5) { return }
        if close.isHittable { close.tap() }
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Picker didn't close")
    }

    // MARK: Journeys

    /// You ▸ Start a drive → pick a vehicle → record → stop → summary, then
    /// check the drive landed in that vehicle's history.
    func testDriveIsRecordedAgainstThePickedVehicle() throws {
        let app = launch()
        XCTAssertTrue(element(app, "demo-strip").waitForExistence(timeout: 10), "Demo mode must always be labelled")
        waitForTabs(app)
        tab(app, "You")
        let openDrive = element(app, "open-drive")
        XCTAssertTrue(openDrive.waitForExistence(timeout: 5), "You offers Start a drive")
        snap("00-you")
        openDrive.tap()
        let start = app.buttons["start-drive"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "live-dashboard").exists, "Opening Drive must not start recording")
        settle(1.5)
        snap("01-drive-home")

        let confirm = app.buttons["picker-confirm"]
        XCTAssertTrue(openPicker(app, until: confirm))
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
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "Recording takes the whole screen")
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

        let close = app.buttons["close-drive"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "After the summary, Drive can be closed")
        close.tap()
        waitForTabs(app)
        let tile = element(app, "garage-tile-320i xDrive")
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "You shows the garage")
        snap("08-you-garage")
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

    /// Every area is reachable from the four tabs.
    func testBrowseEveryArea() throws {
        let app = launch()
        waitForTabs(app)
        XCTAssertTrue(element(app, "compose-prompt").waitForExistence(timeout: 10), "The feed leads with posting")
        settle(1.5)
        snap("11-feed")

        explore(app, "Meets")
        let meet = element(app, "meet-row-Sac Nights")
        XCTAssertTrue(meet.waitForExistence(timeout: 5))
        settle(1.5)
        snap("12-explore-meets")
        openMeet(app, meet, until: element(app, "meet-detail"))
        XCTAssertTrue(element(app, "meet-detail").exists)
        settle(2)
        snap("13-meet-detail")
        app.swipeUp()
        let going = app.buttons["rsvp-going"]
        XCTAssertTrue(going.waitForExistence(timeout: 5))
        going.tap()
        settle()
        XCTAssertTrue(element(app, "rsvp-show-me").waitForExistence(timeout: 5), "Going should offer the opt-in attendee toggle")
        snap("14-meet-rsvp")
        back(app)

        explore(app, "Map")
        XCTAssertTrue(element(app, "map").waitForExistence(timeout: 10))
        settle(4)
        snap("15-explore-map")

        explore(app, "People")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("maya")
        dismissSystemPrompts(app)
        XCTAssertTrue(element(app, "person-maya.s15").waitForExistence(timeout: 5), "People search finds Maya")
        settle()
        dismissSystemPrompts(app, timeout: 3)
        snap("16-explore-people")

        tab(app, "You")
        let boards = element(app, "open-leaderboards")
        XCTAssertTrue(boards.waitForExistence(timeout: 5))
        boards.tap()
        XCTAssertTrue(element(app, "leaderboards").waitForExistence(timeout: 5))
        settle(1.5)
        snap("17-leaderboards")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Closed course")).firstMatch.exists, "No speed boards")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Top speed")).firstMatch.exists, "No speed boards")
        back(app)

        app.buttons["open-profile"].tap()
        XCTAssertTrue(element(app, "profile").waitForExistence(timeout: 5))
        settle(1.5)
        snap("18-profile")
        back(app)
        app.buttons["open-settings"].tap()
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 5))
        settle()
        snap("19-settings")
        app.swipeUp()
        settle()
        snap("20-settings-privacy")
        for _ in 0..<4 where !element(app, "privacy-policy").isHittable { app.swipeUp() }
        // The public pages from Base.xcconfig reach the app (LegalLinks).
        for id in ["privacy-policy", "support", "terms", "community"] {
            XCTAssertTrue(element(app, id).exists, "Settings ▸ About should link \(id)")
        }
    }

    /// The composer starts with just text, media and Post; the vehicle is a
    /// suggestion, the post type is tucked away, and a text post publishes
    /// in a few steps.
    func testBasicPostIsQuick() throws {
        let app = launch()
        waitForTabs(app)
        let prompt = element(app, "compose-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        let caption = element(app, "composer-caption")
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        let post = app.buttons["composer-post"]
        XCTAssertFalse(post.isEnabled, "Nothing to post yet")
        dismissSystemPrompts(app)
        XCTAssertTrue(readyToType(caption, in: app), "The keyboard is up, ready to type")
        XCTAssertTrue(element(app, "composer-media").exists, "Photos are one tap away")
        XCTAssertFalse(element(app, "composer-vehicle-tagged").exists, "No vehicle is tagged without a tap")
        XCTAssertFalse(app.buttons["Build update"].exists, "The post type stays under More options")
        settle()
        snap("21-composer")

        caption.typeText("Fresh alignment, first drive out")
        XCTAssertTrue(post.isEnabled)
        let suggestion = element(app, "composer-vehicle-suggestion")
        if suggestion.exists {
            suggestion.tap()
            XCTAssertTrue(element(app, "composer-vehicle-tagged").waitForExistence(timeout: 3), "One tap tags the suggested vehicle")
        }
        settle()
        snap("22-composer-filled")
        post.tap()
        XCTAssertTrue(app.staticTexts["Fresh alignment, first drive out"].waitForExistence(timeout: 10), "The post shows in the feed")
        settle()
        snap("23-feed-after-post")

        // A basic post with no pauses for inspection or screenshots: three
        // interactions (open, type, Post). The simulator types far slower
        // than a person on a loaded CI runner, so 30 s is a generous bound.
        settle(1.5)
        let began = Date()
        prompt.tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        caption.typeText("Quick one")
        post.tap()
        XCTAssertTrue(app.staticTexts["Quick one"].waitForExistence(timeout: 10), "The second post shows in the feed")
        XCTAssertLessThan(Date().timeIntervalSince(began), 30, "A basic post takes under 30 seconds")
        snap("23b-feed-after-quick-post")
    }

    /// From a post's author to a conversation in two taps.
    func testMessageFromProfileInThreeTapsOrFewer() throws {
        let app = launch()
        waitForTabs(app)
        let author = element(app, "post-author-maya.s15")
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        author.tap()                                             // 1
        let message = element(app, "message-profile")
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.tap()                                            // 2
        XCTAssertTrue(element(app, "composer-field").waitForExistence(timeout: 10), "The conversation opens ready to write")
        settle()
        snap("24-dm-from-profile")
    }

    /// Settings ▸ Appearance switches between OLED Black and Light at once,
    /// and OLED Black is true black.
    func testAppearanceSwitchesToOLEDBlackAndLight() throws {
        let app = launch(["-PullUpTab", "you"])
        waitForTabs(app)
        let settingsButton = app.buttons["open-settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        let dark = element(app, "appearance-dark")
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.tap()
        settle(1.5)
        XCTAssertTrue(dark.isSelected)
        let black = XCUIScreen.main.screenshot()
        snap("25-settings-oled-black")
        // The page margin, below the navigation bar.
        let b = pixel(black, x: 0.01, y: 0.6)
        XCTAssertEqual([b.r, b.g, b.b], [0, 0, 0], "OLED Black is #000000")

        let light = element(app, "appearance-light")
        light.tap()
        settle(1.5)
        XCTAssertTrue(light.isSelected)
        let white = XCUIScreen.main.screenshot()
        snap("26-settings-light")
        let w = pixel(white, x: 0.01, y: 0.6)
        XCTAssertEqual([w.r, w.g, w.b], [255, 255, 255], "Light is white")

        // Remembered after a relaunch.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-PullUpDemo", "-PullUpTab", "you"]
        again.launch()
        XCTAssertTrue(again.tabBars.buttons["Feed"].firstMatch.waitForExistence(timeout: 15))
        again.buttons["open-settings"].tap()
        XCTAssertTrue(again.descendants(matching: .any)["appearance-light"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(again.descendants(matching: .any)["appearance-light"].firstMatch.isSelected, "The choice is kept")
    }

    /// Posts by others can be reported and their author blocked (their posts
    /// leave the feed at once); your own posts can be deleted. Profiles and
    /// meets by others offer Report and Block too.
    func testFeedModeration() throws {
        let app = launch(["-PullUpTab", "feed"])
        let gone = NSPredicate(format: "exists == false")

        let mayaOptions = app.buttons["post-options-maya.s15"]
        XCTAssertTrue(mayaOptions.waitForExistence(timeout: 10))
        mayaOptions.tap()
        let report = app.buttons["Report post"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        settle()
        snap("58-post-options")
        report.tap()
        let send = app.buttons["send-report"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled, "A reason comes first")
        app.buttons["Spam"].tap()
        settle()
        snap("59-report-post")
        send.tap()
        XCTAssertTrue(app.staticTexts["Thanks for reporting"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        settle()

        mayaOptions.tap()
        let blockItem = app.buttons["Block @maya.s15"]
        XCTAssertTrue(blockItem.waitForExistence(timeout: 5))
        blockItem.tap()
        let confirmBlock = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Block")).firstMatch
        XCTAssertTrue(confirmBlock.waitForExistence(timeout: 5))
        confirmBlock.tap()
        expectation(for: gone, evaluatedWith: element(app, "post-author-maya.s15"))
        waitForExpectations(timeout: 5)

        let mine = app.buttons["post-options-you"]
        for _ in 0..<4 where !mine.isHittable { app.swipeUp() }
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.tap()
        XCTAssertFalse(app.buttons["Report post"].exists, "Your own post offers Delete, not Report")
        let deleteItem = app.buttons["Delete post"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.tap()
        let confirmDelete = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Delete")).firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()
        expectation(for: gone, evaluatedWith: element(app, "post-author-you"))
        waitForExpectations(timeout: 5)
        settle()
        snap("60-feed-after-moderation")

        let kenji = element(app, "post-author-kenji.dc2")
        for _ in 0..<4 where !kenji.isHittable { app.swipeUp() }
        kenji.tap()
        XCTAssertTrue(app.buttons["profile-options"].waitForExistence(timeout: 5), "Someone else's profile offers Report and Block")
        settle()
        snap("61-profile-options")

        explore(app, "Meets")
        let meet = element(app, "meet-row-Sac Nights")
        XCTAssertTrue(meet.waitForExistence(timeout: 5))
        openMeet(app, meet, until: app.buttons["meet-options"])
        XCTAssertTrue(app.buttons["meet-options"].exists, "A meet by someone else can be reported")
    }

    func testPickerCanBeDismissedWithoutRecording() throws {
        let app = launch(["-PullUpTab", "drive"])
        let start = app.buttons["start-drive"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(openPicker(app, until: app.buttons["picker-close"]))
        app.buttons["picker-close"].tap()
        settle()
        XCTAssertFalse(element(app, "live-dashboard").exists)
        XCTAssertTrue(start.isHittable)

        let picker = element(app, "start-drive-picker")
        XCTAssertTrue(openPicker(app, until: picker))
        picker.swipeDown(velocity: .fast)
        settle()
        XCTAssertFalse(app.buttons["picker-confirm"].exists)
        XCTAssertFalse(element(app, "live-dashboard").exists)

        // Closing Drive returns to the tabs without recording anything.
        app.buttons["close-drive"].tap()
        waitForTabs(app)
        XCTAssertFalse(element(app, "live-dashboard").exists)
    }

    func testEmptyGarageOffersAddOrGuest() throws {
        let app = launch(["-PullUpEmptyGarage", "-PullUpTab", "drive"])
        let start = app.buttons["start-drive"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        if !openPicker(app, until: app.buttons["picker-add-vehicle"]) { snap("debug-empty-picker") }
        XCTAssertTrue(app.buttons["picker-add-vehicle"].exists)
        XCTAssertTrue(app.buttons["picker-start-guest"].exists)
        settle()
        snap("27-picker-empty-garage")

        app.buttons["picker-add-vehicle"].tap()
        settle()
        snap("28-add-vehicle")
    }

    /// The app is usable without a vehicle: You offers to add one, and
    /// nothing asks for one before posting.
    func testNoVehicleNeeded() throws {
        let app = launch(["-PullUpEmptyGarage", "-PullUpTab", "you"])
        waitForTabs(app)
        XCTAssertTrue(element(app, "you-add-vehicle").waitForExistence(timeout: 5))
        settle()
        snap("29-you-empty-garage")
        tab(app, "Feed")
        element(app, "compose-prompt").tap()
        XCTAssertTrue(element(app, "composer-caption").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "composer-vehicle-suggestion").exists)
        XCTAssertFalse(element(app, "composer-vehicle-menu").exists)
    }

    func testDarkAppearance() throws {
        let app = launch(["-PullUpAppearance", "dark", "-PullUpTab", "drive"])
        XCTAssertTrue(app.buttons["start-drive"].waitForExistence(timeout: 10))
        settle(1.5)
        snap("30-drive-dark")
        XCTAssertTrue(openPicker(app, until: app.buttons["picker-confirm"]))
        settle()
        snap("31-picker-dark")
        closePicker(app)
        app.buttons["close-drive"].tap()
        waitForTabs(app)
        tab(app, "Feed")
        settle(1.5)
        snap("32-feed-dark")
        tab(app, "Messages")
        settle(1.5)
        snap("33-messages-dark")
        tab(app, "You")
        settle(1.5)
        snap("34-you-dark")
    }

    func testLargeTextPickerUsesList() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL", "-PullUpTab", "drive"])
        let start = app.buttons["start-drive"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(openPicker(app, until: app.buttons["vehicle-choice-guest"]))
        XCTAssertFalse(element(app, "vehicle-carousel").exists)
        settle()
        snap("35-picker-accessibility-text")
    }

    func testSignedOutShowsAuth() throws {
        let app = launch(["-PullUpSignedOut"])
        XCTAssertTrue(element(app, "auth").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "continue-with-apple").exists, "Sign in with Apple is the primary way in")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists, "Email sign-in stays tucked away")
        settle()
        snap("36-sign-in")
        app.buttons["other-sign-in"].tap()
        settle()
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'create account'")).firstMatch.exists,
                       "There is no email sign-up")
        snap("37-sign-in-other-options")
        app.buttons["demo-sign-in"].tap()
        waitForTabs(app)
    }

    /// A new Sign in with Apple account picks a username (taken names are
    /// refused live), may skip the photo, sets privacy, then lands on Feed.
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
        snap("38-onboarding-username-taken")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "rx7_kenji")
        expectation(for: NSPredicate(format: "label CONTAINS[c] 'available'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        snap("39-onboarding-username")
        app.buttons["onboarding-continue"].tap()

        let photoNext = app.buttons["onboarding-photo-next"]
        XCTAssertTrue(photoNext.waitForExistence(timeout: 5))
        settle()
        snap("40-onboarding-photo")
        photoNext.tap()

        let finish = app.buttons["onboarding-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        settle()
        snap("41-onboarding-privacy")
        app.swipeUp()
        finish.tap()
        waitForTabs(app)
        XCTAssertTrue(element(app, "compose-prompt").waitForExistence(timeout: 10), "Finishing onboarding opens the feed")
    }

    /// Inbox → conversation → send; message requests; New message; "Message
    /// owner" from someone else's vehicle, which attaches the vehicle.
    func testDirectMessages() throws {
        let app = launch(["-PullUpTab", "messages"])
        waitForTabs(app)
        XCTAssertTrue(element(app, "inbox-row-maya.s15").waitForExistence(timeout: 10))
        settle()
        snap("42-messages-inbox")

        element(app, "inbox-row-kenji.dc2").tap()
        let field = element(app, "composer-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Read"].waitForExistence(timeout: 5), "Read receipts show when both people share them")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "A conversation gives the composer the bottom of the screen")
        settle()
        snap("43-messages-thread")
        field.tap()
        field.typeText("Levee loop on Sunday if you're around")
        app.buttons["composer-send"].tap()
        XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: 5))
        settle()
        snap("44-messages-sent")

        back(app)
        XCTAssertTrue(element(app, "inbox-row-maya.s15").waitForExistence(timeout: 10), "Back returns to the inbox")
        let requests = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Requests'")).firstMatch
        XCTAssertTrue(requests.waitForExistence(timeout: 10), "The inbox offers Requests")
        requests.tap()
        let request = element(app, "inbox-row-sam.ek9")
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        settle()
        snap("45-messages-requests")
        request.tap()
        XCTAssertTrue(app.buttons["accept-request"].waitForExistence(timeout: 5), "A request offers Accept before any reply")
        XCTAssertFalse(element(app, "composer-field").exists, "No composer until the request is accepted")
        settle()
        snap("46-messages-request")
        back(app)
        XCTAssertTrue(element(app, "inbox-row-sam.ek9").waitForExistence(timeout: 10), "Back returns to Requests")

        // New message: search someone, open the conversation; nothing is sent.
        app.buttons["new-message"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("dre")
        let dre = element(app, "person-dre.mt")
        XCTAssertTrue(dre.waitForExistence(timeout: 5))
        settle()
        snap("47-new-message")
        dre.tap()
        XCTAssertTrue(element(app, "composer-field").waitForExistence(timeout: 10), "New message opens the conversation")
        back(app)

        tab(app, "Feed")
        let author = element(app, "post-author-maya.s15")
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        author.tap()
        XCTAssertTrue(element(app, "message-profile").waitForExistence(timeout: 5))
        let vehicle = element(app, "glance-Silvia")
        XCTAssertTrue(vehicle.waitForExistence(timeout: 5))
        vehicle.tap()
        let owner = element(app, "message-owner")
        XCTAssertTrue(owner.waitForExistence(timeout: 5))
        settle()
        snap("48-vehicle-message-owner")
        owner.tap()
        XCTAssertTrue(element(app, "composer-field").waitForExistence(timeout: 5))
        settle(1.5)
        snap("49-message-owner-thread")
    }

    func testNotificationPreferences() throws {
        let app = launch(["-PullUpTab", "you"])
        waitForTabs(app)
        app.buttons["open-settings"].tap()
        let link = element(app, "open-notifications")
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        for _ in 0..<6 where !link.isHittable { app.swipeUp() }
        link.tap()
        let previews = app.switches["push-previews"]
        XCTAssertTrue(previews.waitForExistence(timeout: 5))
        XCTAssertEqual(previews.value as? String, "0", "Message text stays off lock screens by default")
        XCTAssertEqual(app.switches["push-messages"].value as? String, "1")
        settle()
        snap("50-notification-preferences")
    }

    func testMessagePushOpensTheConversation() throws {
        // Sam's message request in the demo data.
        let app = launch(["-PullUpOpenPush", "message_request:00000000-0000-4000-8000-0000000000c3"])
        XCTAssertTrue(app.buttons["accept-request"].waitForExistence(timeout: 10), "A request push opens that request")
        XCTAssertFalse(element(app, "composer-field").exists)
        settle()
        snap("51-push-opens-request")
    }

    /// Settings → a locked Pro face opens Pull Up Pro (demo store, labelled,
    /// no payment) → subscribe → the Ring face and Pro accents unlock.
    func testProSubscription() throws {
        let app = launch(["-PullUpTab", "you"])
        waitForTabs(app)
        app.buttons["open-settings"].tap()
        XCTAssertTrue(element(app, "open-pro").waitForExistence(timeout: 5))
        // Speedometer faces are under Driving, below the fold.
        let ring = element(app, "speedometer-ring")
        for _ in 0..<8 where !(ring.exists && ring.isHittable) { app.swipeUp(); settle(0.4) }
        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        settle()
        snap("52-settings-pro-locked")
        ring.tap()

        let subscribe = element(app, "pro-subscribe")
        XCTAssertTrue(subscribe.waitForExistence(timeout: 5), "A locked face opens Pull Up Pro")
        XCTAssertTrue(app.staticTexts["Demo: prices are placeholders and no payment is taken."].exists)
        settle()
        snap("53-pro-paywall")
        element(app, "pro-plan-yearly").tap()
        subscribe.tap()
        XCTAssertTrue(element(app, "pro-purchased").waitForExistence(timeout: 5))
        settle()
        snap("54-pro-active")
        element(app, "pro-close").tap()

        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        ring.tap()
        settle()
        XCTAssertTrue(ring.isSelected, "Pro unlocks the Ring face")
        let accents = element(app, "accent-disclosure")
        for _ in 0..<4 where !accents.isHittable { app.swipeDown() }
        accents.tap()
        settle()
        let papaya = element(app, "accent-papaya")
        XCTAssertTrue(papaya.waitForExistence(timeout: 5))
        for _ in 0..<4 where !papaya.isHittable { app.swipeUp(velocity: .slow) }
        papaya.tap()
        settle()
        snap("55-settings-pro-unlocked")
    }

    /// Garage → vehicle → Find parts: the eBay search is built from the
    /// vehicle, shown before anything is sent, and opens Safari (not tapped
    /// here, so the test stays in the app).
    func testPartsFinderBuildsAVehicleSearch() throws {
        let app = launch(["-PullUpTab", "garage"])
        let tile = element(app, "garage-tile-GSX-R750")
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        for _ in 0..<4 where !tile.isHittable { app.swipeUp() }
        tile.tap()
        let find = element(app, "find-parts")
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        if !find.isHittable { app.swipeUp() }
        find.tap()
        let search = app.buttons["parts-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertFalse(search.isEnabled, "Nothing to search until a part is named")
        XCTAssertEqual(element(app, "parts-model").value as? String, "GSX-R750", "the garage vehicle is filled in")
        let pads = app.buttons["Brake pads"]
        if !pads.isHittable { app.swipeUp() }
        pads.tap()
        let preview = element(app, "parts-preview")
        XCTAssertTrue(preview.label.contains("2001 Suzuki GSX-R750 K1 Brake pads"), "Preview shows \(preview.label)")
        XCTAssertTrue(element(app, "parts-fitment").exists, "the fitment caveat is shown with every search")
        XCTAssertTrue(search.isEnabled)
        settle()
        snap("56-parts-finder")

        // A part number is searched on its own, without the vehicle.
        app.swipeDown()
        let numberMode = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Part number")).firstMatch
        XCTAssertTrue(numberMode.waitForExistence(timeout: 5))
        numberMode.tap()
        XCTAssertFalse(search.isEnabled, "no number yet")
        let number = element(app, "parts-number")
        XCTAssertTrue(number.waitForExistence(timeout: 5))
        number.tap()
        number.typeText("59100-33E00")
        XCTAssertTrue(preview.label.contains("59100-33E00"), "Preview shows \(preview.label)")
        XCTAssertFalse(preview.label.contains("Suzuki"), "Preview shows \(preview.label)")
        XCTAssertTrue(search.isEnabled)
        settle()
        snap("57-parts-finder-part-number")
    }

    // MARK: Screens in dark mode and at an accessibility text size

    func testPhase2ScreensDark() throws {
        phase2Tour(["-PullUpAppearance", "dark"], first: 62, suffix: "dark")
    }

    func testPhase2ScreensLargeText() throws {
        phase2Tour(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], first: 70, suffix: "large-text")
    }

    /// Feed, inbox, conversation, You, paywall, notification settings and
    /// parts finder.
    private func phase2Tour(_ args: [String], first: Int, suffix: String) {
        var app = launch(args + ["-PullUpTab", "feed"])
        func shot(_ offset: Int, _ name: String) {
            settle()
            snap("\(first + offset)-\(name)-\(suffix)")
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        }

        waitForTabs(app)
        XCTAssertTrue(element(app, "compose-prompt").waitForExistence(timeout: 10))
        shot(0, "feed")
        tab(app, "Messages")
        let kenji = element(app, "inbox-row-kenji.dc2")
        XCTAssertTrue(kenji.waitForExistence(timeout: 5))
        shot(1, "messages-inbox")
        reveal(kenji)
        kenji.tap()
        XCTAssertTrue(element(app, "composer-field").waitForExistence(timeout: 5))
        shot(2, "messages-thread")
        back(app)

        tab(app, "You")
        XCTAssertTrue(element(app, "open-drive").waitForExistence(timeout: 5))
        shot(3, "you")
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let pro = element(app, "open-pro")
        XCTAssertTrue(pro.waitForExistence(timeout: 5))
        pro.tap()
        XCTAssertTrue(element(app, "pro-subscribe").waitForExistence(timeout: 5))
        shot(4, "pro-paywall")
        element(app, "pro-close").tap()

        let notifications = element(app, "open-notifications")
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        reveal(notifications)
        notifications.tap()
        XCTAssertTrue(app.switches["push-messages"].waitForExistence(timeout: 5))
        shot(5, "notification-preferences")

        app.terminate()
        app = launch(args + ["-PullUpTab", "garage"])
        let tile = element(app, "garage-tile-GSX-R750")
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        shot(6, "garage")
        reveal(tile)
        tile.tap()
        let find = element(app, "find-parts")
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        reveal(find)
        find.tap()
        XCTAssertTrue(app.buttons["parts-search"].waitForExistence(timeout: 5))
        shot(7, "parts-finder")
    }
}
