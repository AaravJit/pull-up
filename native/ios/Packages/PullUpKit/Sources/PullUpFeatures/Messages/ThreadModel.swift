import Foundation
import Observation
import PullUpData
import PullUpDomain

/// Who and what a conversation screen opens on.
struct ConversationTarget: Identifiable, Hashable {
    let conversationID: UUID
    let peer: ProfileStub
    var state: ConversationState = .active
    var muted = false
    /// Something to attach to the first message, e.g. from "Message owner".
    var attach: SharedRef?

    var id: UUID { conversationID }

    init(conversationID: UUID, peer: ProfileStub, state: ConversationState = .active, muted: Bool = false, attach: SharedRef? = nil) {
        self.conversationID = conversationID
        self.peer = peer
        self.state = state
        self.muted = muted
        self.attach = attach
    }

    init(_ entry: InboxEntry) {
        self.init(conversationID: entry.conversationID, peer: entry.peer, state: entry.state, muted: entry.muted)
    }
}

/// State behind one conversation: the loaded page of messages, messages
/// still on their way, and the person's own actions on it. Sending is
/// optimistic: a message shows at once as "Sending", becomes a stored
/// message when the server accepts it, or stays as "Failed" with Retry.
@MainActor
@Observable
final class ThreadModel {
    struct Pending: Identifiable, Equatable {
        let outgoing: OutgoingMessage
        let createdAt: Date
        var failure: String?
        var id: UUID { outgoing.id }
    }

    enum Delivery: Equatable {
        case sending
        case sent
        case read
        case failed(String)

        var label: String {
            switch self {
            case .sending: "Sending"
            case .sent: "Sent"
            case .read: "Read"
            case let .failed(reason): "Not sent. \(reason)"
            }
        }
    }

    static let pageSize = 40

    let backend: any BackendService
    let me: UserID
    let peer: ProfileStub
    let conversationID: UUID
    private(set) var state: ConversationState
    private(set) var muted: Bool
    private(set) var messages: [DirectMessage] = []
    private(set) var pending: [Pending] = []
    private(set) var peerReadAt: Date?
    private(set) var hasEarlier = false
    private(set) var isLoaded = false
    private(set) var loadingEarlier = false
    var error: String?

    init(backend: any BackendService, me: UserID, target: ConversationTarget) {
        self.backend = backend
        self.me = me
        peer = target.peer
        conversationID = target.conversationID
        state = target.state
        muted = target.muted
    }

    // MARK: Loading

    func load() async {
        do {
            let page = try await backend.messages(conversation: conversationID, before: nil, limit: Self.pageSize)
            merge(page)
            if !isLoaded { hasEarlier = page.count == Self.pageSize }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
        peerReadAt = try? await backend.peerReadAt(conversation: conversationID)
        // Opening a request doesn't tell the sender; the server checks that.
        try? await backend.markRead(conversation: conversationID)
    }

    /// Called on a realtime nudge or when the screen comes back.
    func refresh() async {
        await load()
    }

    func loadEarlier() async {
        guard hasEarlier, !loadingEarlier, let first = messages.first else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        do {
            let page = try await backend.messages(conversation: conversationID, before: first.createdAt, limit: Self.pageSize)
            merge(page)
            hasEarlier = page.count == Self.pageSize
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func merge(_ page: [DirectMessage]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in page { byID[message.id] = message }
        messages = byID.values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        pending.removeAll { byID[$0.id] != nil }
    }

    // MARK: Sending

    /// Queues a message and sends it. Returns false when there's nothing to send.
    @discardableResult
    func send(text: String, photo: OutgoingMessage.Photo? = nil, shared: SharedRef? = nil) async -> Bool {
        guard MessageRules.canSend(body: text, hasAttachment: photo != nil || shared != nil) else { return false }
        let outgoing = OutgoingMessage(conversationID: conversationID, body: MessageRules.trimmed(text), photo: photo, shared: shared)
        pending.append(Pending(outgoing: outgoing, createdAt: .now))
        await deliver(outgoing.id)
        return true
    }

    func retry(_ id: UUID) async {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].failure = nil
        await deliver(id)
    }

    func discard(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    private func deliver(_ id: UUID) async {
        guard let item = pending.first(where: { $0.id == id }) else { return }
        do {
            // Same id on every attempt, so a retry after a lost reply can't duplicate.
            let stored = try await backend.send(item.outgoing)
            merge([stored])
            // Replying to a request accepts it on the server.
            if state == .request { state = .active }
        } catch {
            if let i = pending.firstIndex(where: { $0.id == id }) { pending[i].failure = error.localizedDescription }
        }
    }

    /// Status line under the newest thing the person sent.
    var latestDelivery: (id: UUID, delivery: Delivery)? {
        if let last = pending.last {
            return (last.id, last.failure.map(Delivery.failed) ?? .sending)
        }
        guard let last = messages.last, last.senderID == me, !last.isUnsent else { return nil }
        if let peerReadAt, peerReadAt >= last.createdAt { return (last.id, .read) }
        return (last.id, .sent)
    }

    // MARK: Reactions and unsend

    /// Tapping your current reaction removes it.
    func react(_ emoji: String, to message: DirectMessage) async {
        guard let i = messages.firstIndex(where: { $0.id == message.id }), !message.isUnsent else { return }
        let before = messages[i].reactions
        let next = messages[i].reaction(by: me) == emoji ? nil : emoji
        messages[i].reactions.removeAll { $0.userID == me }
        if let next { messages[i].reactions.append(MessageReaction(userID: me, emoji: next)) }
        do {
            try await backend.setReaction(next, message: message.id)
        } catch {
            if let j = messages.firstIndex(where: { $0.id == message.id }) { messages[j].reactions = before }
            self.error = error.localizedDescription
        }
    }

    func unsend(_ message: DirectMessage) async {
        do {
            try await backend.unsend(message: message.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Conversation actions

    func accept() async {
        do {
            try await backend.respondToRequest(conversation: conversationID, accept: true)
            state = .active
        } catch {
            self.error = error.localizedDescription
        }
    }

    func decline() async throws {
        try await backend.respondToRequest(conversation: conversationID, accept: false)
        state = .declined
    }

    func toggleMuted() async {
        let next = !muted
        do {
            try await backend.setMuted(next, conversation: conversationID)
            muted = next
        } catch {
            self.error = error.localizedDescription
        }
    }

    func hide(clearHistory: Bool) async throws {
        try await backend.hideConversation(conversationID, clearHistory: clearHistory)
    }

    func report(_ reason: ReportReason, details: String, message: DirectMessage?) async throws {
        try await backend.report(user: peer.id, reason: reason, details: details, message: message?.id)
    }

    func block() async throws {
        try await backend.block(peer.id)
    }
}
