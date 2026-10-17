import StoreKit
import StoreKitTest
import XCTest
@testable import PullUp

/// Runs the app's StoreKit 2 client against the local StoreKit configuration
/// (PullUpPro.storekit, placeholder prices) on the simulator. No App Store
/// account, no network and no money are involved, and nothing here says
/// whether the live products work: that needs App Store Connect.
@MainActor
final class StoreKitClientTests: XCTestCase {
    private func makeSession() throws -> SKTestSession {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PullUpPro", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    private func currentEntitlements() async -> [Transaction] {
        var transactions: [Transaction] = []
        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result { transactions.append(transaction) }
        }
        return transactions
    }

    func testBothPlansLoadWithTheirPeriods() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let products = try await StoreKitClient().products()
        XCTAssertEqual(Set(products.map(\.id)), ["app.pullup.pro.monthly", "app.pullup.pro.yearly"])
        XCTAssertEqual(products.first { $0.id == "app.pullup.pro.monthly" }?.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(products.first { $0.id == "app.pullup.pro.yearly" }?.subscription?.subscriptionPeriod.unit, .year)
        XCTAssertEqual(products.first { $0.id == "app.pullup.pro.yearly" }?.price, Decimal(string: "29.99"))
    }

    func testPurchaseIsVerifiedAndCarriesThePullUpAccount() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let account = UUID()
        let outcome = try await StoreKitClient().purchaseOutcome(productID: "app.pullup.pro.monthly", account: account)
        guard case let .purchased(id, productID, signed) = outcome else {
            return XCTFail("Expected a purchase, got \(outcome)")
        }
        XCTAssertEqual(productID, "app.pullup.pro.monthly")
        XCTAssertEqual(signed.split(separator: ".").count, 3, "a JWS for the server")
        let current = await currentEntitlements()
        XCTAssertEqual(current.map(\.id), [id])
        XCTAssertEqual(current.first?.appAccountToken, account, "the server binds the purchase to this account")
    }

    func testAskToBuyWaitsForApproval() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let outcome = try await StoreKitClient().purchaseOutcome(productID: "app.pullup.pro.yearly", account: UUID())
        XCTAssertEqual(outcome, .pending)
        let current = await currentEntitlements()
        XCTAssertTrue(current.isEmpty, "nothing is unlocked while approval is pending")
    }

    func testExpiredSubscriptionIsNoLongerCurrent() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        _ = try await StoreKitClient().purchaseOutcome(productID: "app.pullup.pro.monthly", account: UUID())
        try session.expireSubscription(productIdentifier: "app.pullup.pro.monthly")
        let current = await currentEntitlements()
        XCTAssertTrue(current.isEmpty)
    }
}
