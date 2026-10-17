import Foundation
import Testing
@testable import PullUpFeatures
@testable import PullUpData
import PullUpDomain

/// Client-side messaging behaviour against the demo backend. The rules that
/// matter for security (who may message whom, limits, visibility) are
/// enforced and tested in Postgres: supabase/tests/003_direct_messages.sql.
@MainActor
@Suite("Messaging flow")
struct MessagingFlowTests {
    private let backend = DemoBackend(replyDelay: .zero)

    private func thread(_ id: UUID, peer: UserID, state: ConversationState = .active) -> ThreadModel {
        ThreadModel(
            backend: backend, me: DemoSeed.meID,
            target: ConversationTarget(conversationID: id, peer: ProfileStub(id: peer, username: "peer", displayName: "Peer"), state: state)
        )
    }

    @Test func inboxSeparatesRequestsAndCountsUnread() async throws {
        let inbox = try await backend.inbox(.active, before: nil)
        #expect(inbox.map(\.peer.username) == ["maya.s15", "kenji.dc2"])
        #expect(inbox.first?.unreadCount == 1)
        let requests = try await backend.inbox(.request, before: nil)
        #expect(requests.map(\.peer.username) == ["sam.ek9"])
        let counts = try await backend.unreadMessages()
        #expect(counts == UnreadMessages(conversations: 1, requests: 1))
    }

    @Test func openingAConversationMarksItRead() async throws {
        let model = thread(DemoSeed.mayaConversationID, peer: DemoSeed.mayaID)
        await model.load()
        #expect(model.messages.count == 4)
        let inbox = try await backend.inbox(.active, before: nil)
        #expect(inbox.first { $0.conversationID == DemoSeed.mayaConversationID }?.unreadCount == 0)
    }

    @Test func sendingShowsTheMessageAndReadState() async throws {
        let model = thread(DemoSeed.kenjiConversationID, peer: DemoSeed.kenjiID)
        await model.load()
        #expect(model.latestDelivery?.delivery == .read)
        let sent = await model.send(text: "  See you at 9  ")
        #expect(sent)
        #expect(model.pending.isEmpty)
        #expect(model.messages.last?.body == "See you at 9")
        #expect(model.latestDelivery?.delivery == .sent)
    }

    @Test func emptyMessagesAreNotSent() async {
        let model = thread(DemoSeed.kenjiConversationID, peer: DemoSeed.kenjiID)
        await model.load()
        let before = model.messages.count
        #expect(await model.send(text: "   ") == false)
        #expect(model.messages.count == before)
    }

    @Test func failedSendStaysWithRetry() async throws {
        let model = thread(DemoSeed.kenjiConversationID, peer: DemoSeed.kenjiID)
        await model.load()
        try await backend.block(DemoSeed.kenjiID)
        await model.send(text: "hello?")
        #expect(model.pending.count == 1)
        guard case let .failed(reason)? = model.latestDelivery?.delivery else {
            Issue.record("Expected a failed send")
            return
        }
        #expect(reason == "You can't message this person.")
        model.discard(model.pending[0].id)
        #expect(model.pending.isEmpty)
    }

    @Test func retryingTheSameMessageDoesNotDuplicate() async throws {
        let outgoing = OutgoingMessage(conversationID: DemoSeed.kenjiConversationID, body: "once")
        _ = try await backend.send(outgoing)
        _ = try await backend.send(outgoing)
        let page = try await backend.messages(conversation: DemoSeed.kenjiConversationID, before: nil, limit: 50)
        #expect(page.filter { $0.body == "once" }.count == 1)
    }

    @Test func reactingTwiceRemovesTheReaction() async throws {
        let model = thread(DemoSeed.mayaConversationID, peer: DemoSeed.mayaID)
        await model.load()
        let message = try #require(model.messages.last)
        await model.react("🔥", to: message)
        #expect(model.messages.last?.reaction(by: DemoSeed.meID) == "🔥")
        await model.react("🔥", to: try #require(model.messages.last))
        #expect(model.messages.last?.reaction(by: DemoSeed.meID) == nil)
    }

    @Test func unsendLeavesATombstone() async throws {
        let model = thread(DemoSeed.kenjiConversationID, peer: DemoSeed.kenjiID)
        await model.load()
        let mine = try #require(model.messages.last { $0.senderID == DemoSeed.meID })
        await model.unsend(mine)
        let after = try #require(model.messages.first { $0.id == mine.id })
        #expect(after.isUnsent)
        #expect(after.body.isEmpty)
    }

    @Test func acceptingARequestMovesItToMessages() async throws {
        let model = thread(DemoSeed.samConversationID, peer: DemoSeed.samID, state: .request)
        await model.load()
        await model.accept()
        #expect(model.state == .active)
        #expect(try await backend.inbox(.request, before: nil).isEmpty)
        #expect(try await backend.inbox(.active, before: nil).contains { $0.peer.id == DemoSeed.samID })
    }

    @Test func readReceiptsAreReciprocal() async throws {
        let id = try await backend.startConversation(with: DemoSeed.samID)
        #expect(id == DemoSeed.samConversationID)
        #expect(try await backend.peerReadAt(conversation: DemoSeed.mayaConversationID) != nil)
        var privacy = try await backend.privacySettings()
        privacy.dmReadReceipts = false
        try await backend.updatePrivacySettings(privacy)
        #expect(try await backend.peerReadAt(conversation: DemoSeed.mayaConversationID) == nil)
    }

    @Test func blockingHidesTheConversation() async throws {
        try await backend.block(DemoSeed.mayaID)
        let inbox = try await backend.inbox(.active, before: nil)
        #expect(!inbox.contains { $0.peer.id == DemoSeed.mayaID })
        await #expect(throws: BackendError.self) { try await backend.startConversation(with: DemoSeed.mayaID) }
    }

    @Test func deletingClearsOnlyYourCopy() async throws {
        let model = thread(DemoSeed.kenjiConversationID, peer: DemoSeed.kenjiID)
        try await model.hide(clearHistory: true)
        #expect(try await backend.messages(conversation: DemoSeed.kenjiConversationID, before: nil, limit: 50).isEmpty)
        #expect(!(try await backend.inbox(.active, before: nil)).contains { $0.conversationID == DemoSeed.kenjiConversationID })
    }

    @Test func privateVehiclesDontPreview() async throws {
        let mine = try await backend.sharedPreview(SharedRef(kind: .vehicle, id: DemoSeed.gsxrID))
        #expect(mine.available)
        #expect(mine.title == "2001 Suzuki GSX-R750")
        let missing = try await backend.sharedPreview(SharedRef(kind: .post, id: UUID()))
        #expect(!missing.available)
    }

    @Test func appBadgeCountsMessages() async {
        var options = LaunchOptions()
        options.demo = true
        let app = AppModel(options: options, appleCredentials: FakeAppleCredentials(storedID: nil, state: .authorized))
        await app.start()
        #expect(app.unreadMessages.total == 2)
    }
}
