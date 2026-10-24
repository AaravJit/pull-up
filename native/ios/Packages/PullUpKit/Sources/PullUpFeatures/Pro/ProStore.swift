import Foundation
import Observation
import PullUpData
import PullUpDomain

/// Pull Up Pro state for the signed-in person. The server's entitlement is
/// the only thing that turns Pro on; StoreKit purchases are handed to the
/// server, which confirms them with Apple.
@MainActor
@Observable
public final class ProStore {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        /// The App Store returned no products (not set up in App Store
        /// Connect yet, or this build has no StoreKit client).
        case unavailable
        case purchasing(ProPlan)
        /// Ask to Buy or a payment check. Resolves through StoreKit updates.
        case pending
        /// Paid, but the server hasn't confirmed it yet. Retried at every
        /// launch and StoreKit update until it does.
        case activating(String)
        case purchased
        case restored
        /// Restore found nothing on this Apple ID.
        case nothingToRestore
        case failed(String)
    }

    public private(set) var offers: [ProOffer] = []
    public private(set) var entitlement: Entitlement = .none
    public private(set) var phase: Phase = .idle

    public var isPro: Bool { entitlement.isPro }
    /// Real App Store purchases (false in demo mode).
    public var isLive: Bool { store.isLive }
    /// Pro is on sale in this build (`PULLUP_PRO_OFFERED`), or this is demo
    /// mode, so UI tests keep running.
    public var isOffered: Bool {
        if store is DemoStoreClient { return true }
        return Self.offered(from: Bundle.main.object(forInfoDictionaryKey: "PullUpProOffered") as? String)
    }
    /// Show Pro UI: on sale, or this person already has Pro (keep honouring
    /// it). The cached flag covers a launch without a connection, when the
    /// entitlement can't be fetched yet; sign-out clears it.
    public var showsEntryPoints: Bool { isOffered || isPro || theme.proUnlocked }

    /// "YES", "1" or "true"; anything else, including an unset build
    /// setting, means Pro isn't offered.
    static func offered(from value: String?) -> Bool {
        ["YES", "1", "true"].contains(value?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    private(set) var store: any StoreClient
    private var backend: any BackendService
    private let theme: ThemeStore
    private var account: UserID?
    private var updatesTask: Task<Void, Never>?

    init(store: any StoreClient, backend: any BackendService, theme: ThemeStore) {
        self.store = store
        self.backend = backend
        self.theme = theme
    }

    func configure(store: any StoreClient, backend: any BackendService) {
        stop()
        self.store = store
        self.backend = backend
    }

    /// On sign-in: read the server's entitlement, hand over anything StoreKit
    /// is still holding, and follow StoreKit updates.
    func start(account: UserID) async {
        self.account = account
        await refresh()
        for transaction in await store.unfinishedTransactions() {
            await deliver(transaction)
        }
        updatesTask?.cancel()
        let updates = store.updates()
        updatesTask = Task { [weak self] in
            for await transaction in updates {
                guard let self else { return }
                await self.deliver(transaction)
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        account = nil
        entitlement = .none
        theme.proUnlocked = false
        phase = .idle
    }

    public func refresh() async {
        guard account != nil else { return }
        if let fresh = try? await backend.entitlement() {
            entitlement = fresh
            theme.proUnlocked = fresh.isPro
        }
    }

    public func loadOffers() async {
        phase = .loading
        do {
            let loaded = try await store.offers()
            offers = ProPlan.allCases.compactMap { plan in loaded.first { $0.plan == plan } }
            phase = offers.isEmpty ? .unavailable : .idle
        } catch {
            offers = []
            phase = .unavailable
        }
    }

    public func purchase(_ plan: ProPlan) async {
        guard let account else {
            phase = .failed("Sign in to subscribe.")
            return
        }
        phase = .purchasing(plan)
        do {
            switch try await store.purchase(plan, account: account) {
            case let .purchased(transaction):
                if await deliver(transaction) { phase = isPro ? .purchased : .failed("The purchase went through, but Pro isn't active yet.") }
            case .pending:
                phase = .pending
            case .cancelled:
                phase = .idle
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func restore() async {
        guard account != nil else { return }
        phase = .loading
        do {
            try await store.sync()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let transactions = await store.currentTransactions()
        var delivered = transactions.isEmpty
        for transaction in transactions {
            if await deliver(transaction) { delivered = true }
        }
        await refresh()
        guard delivered else { return }
        phase = isPro ? .restored : .nothingToRestore
    }

    /// Discounts the yearly plan against twelve months, for the plan card.
    public func yearlySaving() -> Int? {
        guard let monthly = offers.first(where: { $0.plan == .monthly })?.price,
              let yearly = offers.first(where: { $0.plan == .yearly })?.price, monthly > 0 else { return nil }
        let full = NSDecimalNumber(decimal: monthly * 12).doubleValue
        let saving = (1 - NSDecimalNumber(decimal: yearly).doubleValue / full) * 100
        return saving >= 1 ? Int(saving.rounded(.down)) : nil
    }

    /// Hands one transaction to the server. It is finished (acknowledged to
    /// StoreKit) once the server has recorded it, or when retrying can't
    /// help; otherwise StoreKit delivers it again later.
    @discardableResult
    func deliver(_ transaction: StoreTransaction) async -> Bool {
        do {
            let fresh = try await backend.verifySubscription(signedTransaction: transaction.signedTransaction)
            entitlement = fresh
            theme.proUnlocked = fresh.isPro
            await store.finish(transaction.id)
            return true
        } catch let error as SubscriptionError {
            if !error.isRetryable { await store.finish(transaction.id) }
            phase = error.isRetryable ? .activating(error.localizedDescription) : .failed(error.localizedDescription)
            return false
        } catch {
            phase = .activating(error.localizedDescription)
            return false
        }
    }
}
