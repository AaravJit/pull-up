import Foundation
import Synchronization
import Testing
@testable import PullUpFeatures
@testable import PullUpData
import PullUpDesign
import PullUpDomain

/// A scripted App Store.
final class FakeStore: StoreClient {
    struct State {
        var offers: [ProOffer] = ProPlan.allCases.map { ProOffer(plan: $0, displayPrice: "$\($0.placeholderPrice)", price: $0.placeholderPrice) }
        var outcome: PurchaseOutcome?
        var unfinished: [StoreTransaction] = []
        var finished: [UInt64] = []
    }

    let state = Mutex(State())
    var isLive: Bool { true }

    static func transaction(_ id: UInt64, _ plan: ProPlan = .yearly, valid: Bool = true) -> StoreTransaction {
        StoreTransaction(id: id, plan: plan, signedTransaction: valid ? "demo.\(plan.rawValue.replacingOccurrences(of: ".", with: "_")).x" : "eyJ.eyJ.sig")
    }

    func offers() async throws -> [ProOffer] { state.withLock { $0.offers } }
    func purchase(_ plan: ProPlan, account: UUID) async throws -> PurchaseOutcome {
        state.withLock { s in
            let outcome = s.outcome ?? .cancelled
            if case let .purchased(tx) = outcome { s.unfinished.append(tx) }
            return outcome
        }
    }
    func currentTransactions() async -> [StoreTransaction] { state.withLock { $0.unfinished } }
    func unfinishedTransactions() async -> [StoreTransaction] {
        state.withLock { s in s.unfinished.filter { !s.finished.contains($0.id) } }
    }
    func sync() async throws {}
    func finish(_ transactionID: UInt64) async { state.withLock { $0.finished.append(transactionID) } }
    func updates() -> AsyncStream<StoreTransaction> { AsyncStream { $0.finish() } }
}

@MainActor
@Suite("Pull Up Pro flow")
struct ProFlowTests {
    private let backend = DemoBackend()
    private let store = FakeStore()
    private let theme = ThemeStore(defaults: UserDefaults(suiteName: "pro-tests-\(UUID().uuidString)")!)

    private func pro() async -> ProStore {
        let pro = ProStore(store: store, backend: backend, theme: theme)
        await pro.start(account: DemoSeed.meID)
        return pro
    }

    @Test func offersComeFromTheStore() async {
        let pro = await pro()
        await pro.loadOffers()
        #expect(pro.phase == .idle)
        #expect(pro.offers.map(\.plan) == [.monthly, .yearly])
        #expect(pro.yearlySaving() == 37)
        #expect(!pro.isPro)
    }

    @Test func noProductsMeansUnavailableNotInventedPrices() async {
        store.state.withLock { $0.offers = [] }
        let pro = await pro()
        await pro.loadOffers()
        #expect(pro.phase == .unavailable)
        #expect(pro.offers.isEmpty)
    }

    @Test func purchaseTurnsProOnOnlyAfterTheServerConfirms() async {
        store.state.withLock { $0.outcome = .purchased(FakeStore.transaction(7)) }
        let pro = await pro()
        await pro.purchase(.yearly)
        #expect(pro.phase == .purchased)
        #expect(pro.isPro)
        #expect(pro.entitlement.plan == .yearly)
        #expect(theme.proUnlocked)
        #expect(store.state.withLock { $0.finished } == [7])
    }

    @Test func askToBuyIsPendingAndUnlocksNothing() async {
        store.state.withLock { $0.outcome = .pending }
        let pro = await pro()
        await pro.purchase(.monthly)
        #expect(pro.phase == .pending)
        #expect(!pro.isPro)
        #expect(store.state.withLock { $0.finished }.isEmpty)
    }

    @Test func cancellingChangesNothing() async {
        store.state.withLock { $0.outcome = .cancelled }
        let pro = await pro()
        await pro.purchase(.monthly)
        #expect(pro.phase == .idle)
        #expect(!pro.isPro)
    }

    @Test func serverOutageKeepsTheTransactionForLater() async {
        backend.subscriptionFailure.withLock { $0 = .unavailable("offline") }
        store.state.withLock { $0.outcome = .purchased(FakeStore.transaction(9)) }
        let pro = await pro()
        await pro.purchase(.yearly)
        guard case .activating = pro.phase else {
            Issue.record("Expected activating, got \(pro.phase)")
            return
        }
        #expect(!pro.isPro)
        #expect(store.state.withLock { $0.finished }.isEmpty, "unfinished, so StoreKit delivers it again")

        backend.subscriptionFailure.withLock { $0 = nil }
        await pro.start(account: DemoSeed.meID)
        #expect(pro.isPro, "delivered on the next launch")
        #expect(store.state.withLock { $0.finished } == [9])
    }

    @Test func aRefusedTransactionIsFinishedAndUnlocksNothing() async {
        store.state.withLock { $0.outcome = .purchased(FakeStore.transaction(11, valid: false)) }
        let pro = await pro()
        await pro.purchase(.yearly)
        guard case .failed = pro.phase else {
            Issue.record("Expected failed, got \(pro.phase)")
            return
        }
        #expect(!pro.isPro)
        #expect(store.state.withLock { $0.finished } == [11])
    }

    @Test func restoreWithNothingSaysSo() async {
        let pro = await pro()
        await pro.restore()
        #expect(pro.phase == .nothingToRestore)
    }

    @Test func proLooksFallBackWithoutProAndComeBackWithIt() {
        theme.proUnlocked = true
        theme.theme.accent = .papaya
        theme.theme.speedometer = .ring
        theme.proUnlocked = false
        #expect(theme.theme.accent == ClusterTheme().accent)
        #expect(theme.theme.speedometer == .analog)
        theme.theme.unit = .kmh
        #expect(theme.chosen.accent == .papaya, "changing something else keeps the Pro pick")
        theme.proUnlocked = true
        #expect(theme.theme.accent == .papaya)
        #expect(theme.theme.speedometer == .ring)
        #expect(theme.theme.unit == .kmh)
    }

    @Test func signingOutLocksPro() async {
        store.state.withLock { $0.outcome = .purchased(FakeStore.transaction(3)) }
        let pro = await pro()
        await pro.purchase(.monthly)
        #expect(pro.isPro)
        pro.stop()
        #expect(!pro.isPro)
        #expect(!theme.proUnlocked)
    }
}

@Suite("Pro legal links")
struct ProLinksTests {
    @Test func privacyPolicyComesFromTheBuildSetting() {
        #expect(ProLinks.privacyURL(from: "pullup.app/privacy")?.absoluteString == "https://pullup.app/privacy")
        #expect(ProLinks.privacyURL(from: "https://pullup.app/privacy")?.absoluteString == "https://pullup.app/privacy")
    }

    @Test func unsetOrUnsafeValuesShowNoLink() {
        #expect(ProLinks.privacyURL(from: nil) == nil)
        #expect(ProLinks.privacyURL(from: "") == nil)
        #expect(ProLinks.privacyURL(from: "$(PULLUP_PRIVACY_POLICY)") == nil)
        #expect(ProLinks.privacyURL(from: "http://pullup.app/privacy") == nil)
    }
}
