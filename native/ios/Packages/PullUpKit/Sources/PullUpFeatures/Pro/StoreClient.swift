import Foundation
import Synchronization
import PullUpDomain

/// A plan as the App Store offers it to this person, with the localized
/// price StoreKit returned.
public struct ProOffer: Identifiable, Equatable, Sendable {
    public var plan: ProPlan
    public var displayPrice: String
    public var price: Decimal

    public var id: String { plan.id }

    public init(plan: ProPlan, displayPrice: String, price: Decimal) {
        self.plan = plan
        self.displayPrice = displayPrice
        self.price = price
    }
}

/// A Pro transaction StoreKit verified on the device, ready for the server.
public struct StoreTransaction: Equatable, Sendable {
    public var id: UInt64
    public var plan: ProPlan
    /// StoreKit's JWS. The server only uses it to know what to ask Apple.
    public var signedTransaction: String

    public init(id: UInt64, plan: ProPlan, signedTransaction: String) {
        self.id = id
        self.plan = plan
        self.signedTransaction = signedTransaction
    }
}

public enum PurchaseOutcome: Equatable, Sendable {
    case purchased(StoreTransaction)
    /// Waiting for Ask to Buy approval or a payment check. The result
    /// arrives later through `updates()`.
    case pending
    case cancelled
}

/// The App Store as Pull Up uses it. The live StoreKit 2 implementation is in
/// the app target (`StoreKitClient`); demo mode and tests use their own.
public protocol StoreClient: Sendable {
    /// False when no real money can change hands (demo).
    var isLive: Bool { get }
    func offers() async throws -> [ProOffer]
    /// `account` is attached to the purchase as Apple's appAccountToken, which
    /// is how the server knows which Pull Up account it belongs to.
    func purchase(_ plan: ProPlan, account: UUID) async throws -> PurchaseOutcome
    /// Verified Pro transactions this Apple ID is currently entitled to.
    func currentTransactions() async -> [StoreTransaction]
    /// Transactions not yet finished, e.g. paid while the server was unreachable.
    func unfinishedTransactions() async -> [StoreTransaction]
    /// Restore Purchases: re-syncs this Apple ID's purchases with the App Store.
    func sync() async throws
    func finish(_ transactionID: UInt64) async
    /// Renewals, purchases on other devices, Ask to Buy approvals, refunds.
    func updates() -> AsyncStream<StoreTransaction>
}

/// Used when the build has no StoreKit client: offers nothing, so the
/// paywall says Pro isn't available rather than showing invented prices.
public struct UnavailableStoreClient: StoreClient {
    public init() {}
    public var isLive: Bool { false }
    public func offers() async throws -> [ProOffer] { [] }
    public func purchase(_ plan: ProPlan, account: UUID) async throws -> PurchaseOutcome { .cancelled }
    public func currentTransactions() async -> [StoreTransaction] { [] }
    public func unfinishedTransactions() async -> [StoreTransaction] { [] }
    public func sync() async throws {}
    public func finish(_ transactionID: UInt64) async {}
    public func updates() -> AsyncStream<StoreTransaction> { AsyncStream { $0.finish() } }
}

/// Demo mode's store: placeholder prices, no payment, transactions only the
/// demo backend accepts. Always labelled as a demo on screen.
public final class DemoStoreClient: StoreClient {
    private struct State {
        var purchased: [StoreTransaction] = []
        var finished: Set<UInt64> = []
        var next: UInt64 = 1
    }

    private let state = Mutex(State())
    private let delay: Duration

    public init(delay: Duration = .milliseconds(400)) {
        self.delay = delay
    }

    public var isLive: Bool { false }

    public func offers() async throws -> [ProOffer] {
        ProPlan.allCases.map { ProOffer(plan: $0, displayPrice: $0.placeholderPrice.formatted(.currency(code: "USD")), price: $0.placeholderPrice) }
    }

    public func purchase(_ plan: ProPlan, account: UUID) async throws -> PurchaseOutcome {
        try await Task.sleep(for: delay)
        let tx = state.withLock { s in
            let tx = StoreTransaction(
                id: s.next, plan: plan,
                signedTransaction: "demo.\(plan.rawValue.replacingOccurrences(of: ".", with: "_")).\(account.uuidString)"
            )
            s.next += 1
            s.purchased.append(tx)
            return tx
        }
        return .purchased(tx)
    }

    public func currentTransactions() async -> [StoreTransaction] { state.withLock { $0.purchased } }

    public func unfinishedTransactions() async -> [StoreTransaction] {
        state.withLock { s in s.purchased.filter { !s.finished.contains($0.id) } }
    }

    public func sync() async throws {
        try await Task.sleep(for: delay)
    }

    public func finish(_ transactionID: UInt64) async {
        _ = state.withLock { $0.finished.insert(transactionID) }
    }

    public func updates() -> AsyncStream<StoreTransaction> { AsyncStream { $0.finish() } }
}
