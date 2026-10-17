import Foundation
import StoreKit
import PullUpDomain
import PullUpFeatures

/// The live App Store through StoreKit 2. Purchases carry the Pull Up user
/// id as appAccountToken; every transaction handed on has passed StoreKit's
/// on-device verification, and the server still confirms it with Apple.
final class StoreKitClient: StoreClient {
    /// What a purchase produced, in StoreKit's own terms (tested directly by
    /// PullUpStoreTests against the local StoreKit configuration).
    enum Outcome: Equatable {
        case purchased(id: UInt64, productID: String, signedTransaction: String)
        case pending
        case cancelled
    }

    var isLive: Bool { true }

    func products() async throws -> [Product] {
        try await Product.products(for: ProPlan.allCases.map(\.productID))
    }

    func offers() async throws -> [ProOffer] {
        try await products().compactMap { product in
            ProPlan(rawValue: product.id).map { ProOffer(plan: $0, displayPrice: product.displayPrice, price: product.price) }
        }
    }

    func purchaseOutcome(productID: String, account: UUID) async throws -> Outcome {
        guard let product = try await Product.products(for: [productID]).first else {
            throw StoreKitError.notAvailableInStorefront
        }
        switch try await product.purchase(options: [.appAccountToken(account)]) {
        case let .success(verification):
            let transaction = try Self.verified(verification)
            return .purchased(id: transaction.id, productID: transaction.productID, signedTransaction: verification.jwsRepresentation)
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func purchase(_ plan: ProPlan, account: UUID) async throws -> PurchaseOutcome {
        switch try await purchaseOutcome(productID: plan.productID, account: account) {
        case let .purchased(id, _, signed): .purchased(StoreTransaction(id: id, plan: plan, signedTransaction: signed))
        case .pending: .pending
        case .cancelled: .cancelled
        }
    }

    func currentTransactions() async -> [StoreTransaction] {
        await Self.collect(Transaction.currentEntitlements)
    }

    func unfinishedTransactions() async -> [StoreTransaction] {
        await Self.collect(Transaction.unfinished)
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    func finish(_ transactionID: UInt64) async {
        for await result in Transaction.unfinished {
            if case let .verified(transaction) = result, transaction.id == transactionID {
                await transaction.finish()
            }
        }
    }

    func updates() -> AsyncStream<StoreTransaction> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    if let transaction = Self.storeTransaction(result) { continuation.yield(transaction) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func collect(_ sequence: Transaction.Transactions) async -> [StoreTransaction] {
        var transactions: [StoreTransaction] = []
        for await result in sequence {
            if let transaction = storeTransaction(result) { transactions.append(transaction) }
        }
        return transactions
    }

    private static func storeTransaction(_ result: VerificationResult<Transaction>) -> StoreTransaction? {
        guard case let .verified(transaction) = result, let plan = ProPlan(rawValue: transaction.productID) else { return nil }
        return StoreTransaction(id: transaction.id, plan: plan, signedTransaction: result.jwsRepresentation)
    }

    private static func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case let .verified(transaction): transaction
        case let .unverified(_, error): throw error
        }
    }
}
