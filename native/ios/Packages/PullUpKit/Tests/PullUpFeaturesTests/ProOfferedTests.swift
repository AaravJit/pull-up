import Foundation
import Testing
@testable import PullUpFeatures
@testable import PullUpData
import PullUpDomain

/// Pro can be left out of a release with one build setting
/// (`PULLUP_PRO_OFFERED`) without taking it away from anyone who has it.
@MainActor
@Suite("Pull Up Pro offered switch")
struct ProOfferedTests {
    private let backend = DemoBackend()
    private let theme = ThemeStore(defaults: UserDefaults(suiteName: "pro-offered-tests-\(UUID().uuidString)")!)

    @Test func onlyAnExplicitYesOffersPro() {
        #expect(ProStore.offered(from: "YES"))
        #expect(ProStore.offered(from: "1"))
        #expect(ProStore.offered(from: "true"))
        #expect(!ProStore.offered(from: "NO"))
        #expect(!ProStore.offered(from: ""))
        #expect(!ProStore.offered(from: nil))
        #expect(!ProStore.offered(from: "$(PULLUP_PRO_OFFERED)"))
    }

    @Test func unsetBuildSettingHidesProUntilSomeoneHasIt() async {
        let store = FakeStore()
        store.state.withLock { $0.outcome = .purchased(FakeStore.transaction(5)) }
        let pro = ProStore(store: store, backend: backend, theme: theme)
        await pro.start(account: DemoSeed.meID)
        #expect(!pro.isOffered, "the test bundle has no PullUpProOffered")
        #expect(!pro.showsEntryPoints)

        await pro.purchase(.yearly)
        #expect(pro.isPro)
        #expect(pro.showsEntryPoints, "people who already have Pro keep seeing it")
    }

    @Test func demoModeAlwaysOffersPro() async {
        let pro = ProStore(store: DemoStoreClient(delay: .zero), backend: backend, theme: theme)
        await pro.start(account: DemoSeed.meID)
        #expect(pro.isOffered)
        #expect(pro.showsEntryPoints)
    }

    @Test func noSupportRowWithoutTheBuildSetting() {
        #expect(SettingsView.supportURL == nil)
    }
}
