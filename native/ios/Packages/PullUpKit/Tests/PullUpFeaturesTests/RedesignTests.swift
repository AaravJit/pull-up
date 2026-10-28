import Foundation
import Testing
@testable import PullUpFeatures
import PullUpDesign
import PullUpDomain

/// The 1.0 identity: theme migration, the four-tab navigation and the
/// composer's remembered defaults.
@MainActor
struct ThemeMigrationTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "theme-tests-\(UUID().uuidString)")!
    }

    private func store(_ json: String, in defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: "pullup.theme.v1")
    }

    @Test func newInstallIsElectricBlueAndFollowsTheSystem() {
        let theme = ThemeStore(defaults: defaults()).theme
        #expect(theme.accent == .gulf)
        #expect(theme.accent == .defaultAccent)
        #expect(theme.appearance == .system)
    }

    @Test func oldSodiumDefaultBecomesBlueOnce() {
        let d = defaults()
        store(#"{"accent":"sodium","appearance":"dark","speedometer":"tape","unit":"kmh","dashboard":["distance","elapsed"]}"#, in: d)
        let theme = ThemeStore(defaults: d).theme
        #expect(theme.accent == .gulf)
        // Everything else the person chose is kept.
        #expect(theme.appearance == .dark)
        #expect(theme.speedometer == .tape)
        #expect(theme.unit == .kmh)
        #expect(theme.dashboard == [.distance, .elapsed])

        // Choosing Sodium again after the migration sticks.
        let again = ThemeStore(defaults: d)
        again.theme.accent = .sodium
        #expect(ThemeStore(defaults: d).theme.accent == .sodium)
    }

    @Test func otherAccentsAreKept() {
        let d = defaults()
        store(#"{"accent":"redline","appearance":"light","speedometer":"analog","unit":"mph","dashboard":[]}"#, in: d)
        let theme = ThemeStore(defaults: d).theme
        #expect(theme.accent == .redline)
        #expect(theme.appearance == .light)
    }

    @Test func unknownOrMissingValuesFallBackInsteadOfResetting() {
        let d = defaults()
        // A future accent, a missing unit and an unknown dashboard metric.
        store(#"{"accent":"chrome","appearance":"dark","speedometer":"digital","dashboard":["distance","warp"]}"#, in: d)
        let theme = ThemeStore(defaults: d).theme
        #expect(theme.accent == .defaultAccent)
        #expect(theme.appearance == .dark)
        #expect(theme.speedometer == .digital)
        #expect(theme.dashboard == [.distance])
    }

    @Test func corruptDataGivesTheDefaults() {
        let d = defaults()
        d.set(Data("not json".utf8), forKey: "pullup.theme.v1")
        #expect(ThemeStore(defaults: d).theme.accent == .defaultAccent)
    }

    @Test func launchOverrideIsNotSaved() {
        let d = defaults()
        let first = ThemeStore(defaults: d, override: .dark)
        #expect(first.theme.appearance == .dark)
        #expect(ThemeStore(defaults: d).theme.appearance == .system)
    }

    @Test func darkIsLabelledOLEDBlack() {
        #expect(AppearancePreference.allCases.map(\.label) == ["System", "Light", "OLED Black"])
        #expect(AccentChoice.gulf.label == "Electric Blue")
        #expect(AccentChoice.allCases.first == .gulf)
        #expect(!AccentChoice.gulf.isPro && AccentChoice.standard.contains(.gulf))
    }

    @Test func blueButtonsKeepWhiteText() {
        #expect(!ClusterColor.accentPrefersDarkText(.gulf))
    }
}

struct NavigationTests {
    private func options(_ tab: String) -> LaunchOptions {
        var options = LaunchOptions()
        options.applyTab(tab)
        return options
    }

    @Test func fourTabs() {
        #expect(MainTab.allCases == [.feed, .messages, .explore, .you])
        #expect(ExploreMode.allCases.map(\.label) == ["Meets", "Map", "People"])
    }

    @Test func oldTabNamesLandWhereThoseScreensLiveNow() {
        #expect(options("feed").initialTab == .feed)
        #expect(options("messages").initialTab == .messages)
        #expect(options("map").initialTab == .explore)
        #expect(options("map").initialExplore == .map)
        #expect(options("meets").initialExplore == .meets)
        #expect(options("garage").initialTab == .you)
        #expect(options("garage").opensGarage)
        #expect(options("drive").opensDrive)
        #expect(options("drive").initialTab == .you)
        #expect(options("nonsense").initialTab == nil)
    }

    @MainActor
    @Test func appStartsOnTheFeedWithDriveClosed() {
        var launch = LaunchOptions()
        launch.demo = true
        let app = AppModel(options: launch, appleCredentials: FakeAppleCredentials(storedID: nil, state: .authorized))
        #expect(app.selectedTab == .feed)
        #expect(!app.driveIsPresented)
        app.openDrive()
        #expect(app.driveIsPresented)
        app.driveOpen = false
        #expect(!app.driveIsPresented)
    }
}

struct ComposerDefaultsTests {
    private let me = UserID()

    private func vehicle(_ model: String, position: Int = 0) -> Vehicle {
        Vehicle(ownerID: me, kind: .car, make: "Test", model: model, year: 2020, position: position)
    }

    @Test func onlyVehicleIsSuggested() {
        let only = vehicle("Only")
        #expect(ComposerMemory.suggestedVehicle(garage: [only], lastTagged: nil, lastDriven: nil) == only)
    }

    @Test func lastTaggedBeatsLastDriven() {
        let a = vehicle("A"), b = vehicle("B", position: 1)
        #expect(ComposerMemory.suggestedVehicle(garage: [a, b], lastTagged: b.id, lastDriven: a.id) == b)
        #expect(ComposerMemory.suggestedVehicle(garage: [a, b], lastTagged: nil, lastDriven: a.id) == a)
    }

    @Test func noGuessAmongSeveralWithoutHistory() {
        let a = vehicle("A"), b = vehicle("B", position: 1)
        #expect(ComposerMemory.suggestedVehicle(garage: [a, b], lastTagged: nil, lastDriven: nil) == nil)
        // A vehicle that's gone isn't suggested.
        #expect(ComposerMemory.suggestedVehicle(garage: [a, b], lastTagged: UUID(), lastDriven: nil) == nil)
        #expect(ComposerMemory.suggestedVehicle(garage: [], lastTagged: nil, lastDriven: nil) == nil)
    }

    @Test func draftAndAudienceAreRememberedPerAccount() {
        let defaults = UserDefaults(suiteName: "composer-\(UUID().uuidString)")!
        let memory = ComposerMemory(defaults: defaults, owner: me)
        #expect(memory.audience == .public)
        #expect(memory.draft.isEmpty)
        memory.draft = "Half-written"
        memory.audience = .friends
        #expect(ComposerMemory(defaults: defaults, owner: me).draft == "Half-written")
        #expect(ComposerMemory(defaults: defaults, owner: me).audience == .friends)
        // Someone else signing in on this phone doesn't get it.
        #expect(ComposerMemory(defaults: defaults, owner: UserID()).draft.isEmpty)
        memory.draft = "   "
        #expect(memory.draft.isEmpty, "a blank draft isn't kept")
    }
}
