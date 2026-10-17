import Foundation
import Testing
@testable import PullUpFeatures
@testable import PullUpData
import PullUpDomain

@MainActor
@Suite("Push tokens and taps")
struct PushFlowTests {
    private func app(signedOut: Bool = false) async -> AppModel {
        var options = LaunchOptions()
        options.demo = true
        options.signedOut = signedOut
        let app = AppModel(options: options, appleCredentials: FakeAppleCredentials(storedID: nil, state: .authorized))
        await app.start()
        return app
    }

    private func tokens(_ app: AppModel) -> [String: UserID] {
        (app.backend as? DemoBackend)?.registeredPushTokens() ?? [:]
    }

    @Test func tokenIsRegisteredForTheSignedInAccount() async {
        let app = await app()
        await app.didReceivePushToken("ABCD", sandbox: true)
        #expect(tokens(app) == ["abcd": DemoSeed.meID])
    }

    @Test func tokenIssuedBeforeSignInWaitsForIt() async {
        let app = await app(signedOut: true)
        await app.didReceivePushToken("abcd", sandbox: true)
        #expect(tokens(app).isEmpty)
    }

    @Test func signingOutStopsPushesToThisPhone() async {
        let app = await app()
        await app.didReceivePushToken("abcd", sandbox: true)
        await app.signOut()
        #expect(tokens(app).isEmpty)
    }

    @Test func messagePushOpensMessagesOnTheFeedTab() async {
        let app = await app()
        let id = UUID()
        app.openPush(kind: "message_request", conversationID: id.uuidString)
        #expect(app.selectedTab == .feed)
        #expect(app.pendingPush == .conversation(id, isRequest: true))
    }

    @Test func otherPushesOpenActivity() async {
        let app = await app()
        app.selectedTab = .garage
        app.openPush(kind: "meet_updated", conversationID: nil)
        #expect(app.selectedTab == .drive)
        #expect(app.pendingPush == .activity)
    }

    @Test func preferencesRoundTrip() async throws {
        let app = await app()
        var prefs = try await app.backend.notificationPreferences()
        #expect(prefs == NotificationPreferences())
        prefs.messagePreviews = true
        prefs.meets = false
        try await app.backend.updateNotificationPreferences(prefs)
        #expect(try await app.backend.notificationPreferences() == prefs)
    }
}
