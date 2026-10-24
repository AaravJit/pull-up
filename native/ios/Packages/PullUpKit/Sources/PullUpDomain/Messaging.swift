import Foundation

// One-to-one direct messages. The server (supabase/migrations/
// 20261017000200_direct_messages.sql) decides who may message whom, rate
// limits, request limits and what a reader may see; these types only carry
// its answers.

/// Where a conversation sits for the signed-in person.
public enum ConversationState: String, Codable, Sendable, CaseIterable, Identifiable {
    /// In the inbox.
    case active
    /// From someone you don't follow. They can't tell whether you've read it.
    case request
    /// You deleted the request; they can't send more.
    case declined

    public var id: String { rawValue }
}

/// One row of the inbox, as returned by the `inbox` RPC.
public struct InboxEntry: Codable, Hashable, Sendable, Identifiable {
    public var conversationID: UUID
    public var peer: ProfileStub
    public var state: ConversationState
    public var muted: Bool
    public var lastMessageAt: Date?
    public var preview: String
    public var lastMessageFromMe: Bool
    public var unreadCount: Int
    /// When the other person last read the conversation. Nil unless both
    /// people share read receipts and they've accepted the conversation.
    public var peerReadAt: Date?

    public var id: UUID { conversationID }

    public init(
        conversationID: UUID, peer: ProfileStub, state: ConversationState = .active, muted: Bool = false,
        lastMessageAt: Date? = nil, preview: String = "", lastMessageFromMe: Bool = false, unreadCount: Int = 0, peerReadAt: Date? = nil
    ) {
        self.conversationID = conversationID
        self.peer = peer
        self.state = state
        self.muted = muted
        self.lastMessageAt = lastMessageAt
        self.preview = preview
        self.lastMessageFromMe = lastMessageFromMe
        self.unreadCount = unreadCount
        self.peerReadAt = peerReadAt
    }

    enum CodingKeys: String, CodingKey {
        case state, muted
        case conversationID = "conversation_id"
        case peerID = "peer_id"
        case peerUsername = "peer_username"
        case peerDisplayName = "peer_display_name"
        case peerAvatarPath = "peer_avatar_path"
        case lastMessageAt = "last_message_at"
        case preview = "last_message_preview"
        case lastMessageFromMe = "last_message_from_me"
        case unreadCount = "unread_count"
        case peerReadAt = "peer_read_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        peer = ProfileStub(
            id: try c.decode(UUID.self, forKey: .peerID),
            username: try c.decode(String.self, forKey: .peerUsername),
            displayName: try c.decodeIfPresent(String.self, forKey: .peerDisplayName) ?? "",
            avatarPath: try c.decodeIfPresent(String.self, forKey: .peerAvatarPath)
        )
        state = try c.decodeIfPresent(ConversationState.self, forKey: .state) ?? .active
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        lastMessageAt = try c.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        lastMessageFromMe = try c.decodeIfPresent(Bool.self, forKey: .lastMessageFromMe) ?? false
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        peerReadAt = try c.decodeIfPresent(Date.self, forKey: .peerReadAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conversationID, forKey: .conversationID)
        try c.encode(peer.id, forKey: .peerID)
        try c.encode(peer.username, forKey: .peerUsername)
        try c.encode(peer.displayName, forKey: .peerDisplayName)
        try c.encodeIfPresent(peer.avatarPath, forKey: .peerAvatarPath)
        try c.encode(state, forKey: .state)
        try c.encode(muted, forKey: .muted)
        try c.encodeIfPresent(lastMessageAt, forKey: .lastMessageAt)
        try c.encode(preview, forKey: .preview)
        try c.encode(lastMessageFromMe, forKey: .lastMessageFromMe)
        try c.encode(unreadCount, forKey: .unreadCount)
        try c.encodeIfPresent(peerReadAt, forKey: .peerReadAt)
    }
}

/// Something from elsewhere in Pull Up attached to a message.
public enum SharedKind: String, Codable, Sendable, CaseIterable {
    case vehicle, post, meet, drive

    public var label: String {
        switch self {
        case .vehicle: "Vehicle"
        case .post: "Post"
        case .meet: "Meet"
        case .drive: "Drive"
        }
    }
}

public struct SharedRef: Codable, Hashable, Sendable {
    public var kind: SharedKind
    public var id: UUID

    public init(kind: SharedKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

public struct MessageReaction: Codable, Hashable, Sendable {
    public var userID: UserID
    public var emoji: String

    public init(userID: UserID, emoji: String) {
        self.userID = userID
        self.emoji = emoji
    }

    enum CodingKeys: String, CodingKey {
        case emoji
        case userID = "user_id"
    }
}

public struct ReactionCount: Hashable, Sendable, Identifiable {
    public var emoji: String
    public var count: Int
    public var id: String { emoji }

    public init(emoji: String, count: Int) {
        self.emoji = emoji
        self.count = count
    }
}

public struct DirectMessage: Codable, Hashable, Sendable, Identifiable {
    /// Chosen by the sender's device, so a retried send can't duplicate.
    public var id: UUID
    public var conversationID: UUID
    public var senderID: UserID
    public var body: String
    public var mediaPath: String?
    public var mediaWidth: Int?
    public var mediaHeight: Int?
    public var shared: SharedRef?
    public var createdAt: Date
    public var unsentAt: Date?
    public var reactions: [MessageReaction]

    public init(
        id: UUID = UUID(), conversationID: UUID, senderID: UserID, body: String, mediaPath: String? = nil,
        mediaWidth: Int? = nil, mediaHeight: Int? = nil, shared: SharedRef? = nil, createdAt: Date = .now,
        unsentAt: Date? = nil, reactions: [MessageReaction] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.body = body
        self.mediaPath = mediaPath
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
        self.shared = shared
        self.createdAt = createdAt
        self.unsentAt = unsentAt
        self.reactions = reactions
    }

    public var isUnsent: Bool { unsentAt != nil }

    public var aspectRatio: Double {
        guard let mediaWidth, let mediaHeight, mediaWidth > 0, mediaHeight > 0 else { return 4.0 / 3.0 }
        return Double(mediaWidth) / Double(mediaHeight)
    }

    /// Reactions grouped for display, most used first.
    public var reactionCounts: [ReactionCount] {
        var counts: [String: Int] = [:]
        for reaction in reactions { counts[reaction.emoji, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ReactionCount(emoji: $0.key, count: $0.value) }
    }

    public func reaction(by user: UserID) -> String? {
        reactions.first { $0.userID == user }?.emoji
    }

    enum CodingKeys: String, CodingKey {
        case id, body, reactions
        case conversationID = "conversation_id"
        case senderID = "sender_id"
        case mediaPath = "media_path"
        case mediaWidth = "media_width"
        case mediaHeight = "media_height"
        case sharedKind = "shared_kind"
        case sharedID = "shared_id"
        case createdAt = "created_at"
        case unsentAt = "unsent_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        senderID = try c.decode(UUID.self, forKey: .senderID)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        mediaPath = try c.decodeIfPresent(String.self, forKey: .mediaPath)
        mediaWidth = try c.decodeIfPresent(Int.self, forKey: .mediaWidth)
        mediaHeight = try c.decodeIfPresent(Int.self, forKey: .mediaHeight)
        if let kind = try c.decodeIfPresent(SharedKind.self, forKey: .sharedKind),
           let sharedID = try c.decodeIfPresent(UUID.self, forKey: .sharedID) {
            shared = SharedRef(kind: kind, id: sharedID)
        } else {
            shared = nil
        }
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        unsentAt = try c.decodeIfPresent(Date.self, forKey: .unsentAt)
        reactions = try c.decodeIfPresent([MessageReaction].self, forKey: .reactions) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(conversationID, forKey: .conversationID)
        try c.encode(senderID, forKey: .senderID)
        try c.encode(body, forKey: .body)
        try c.encodeIfPresent(mediaPath, forKey: .mediaPath)
        try c.encodeIfPresent(mediaWidth, forKey: .mediaWidth)
        try c.encodeIfPresent(mediaHeight, forKey: .mediaHeight)
        try c.encodeIfPresent(shared?.kind, forKey: .sharedKind)
        try c.encodeIfPresent(shared?.id, forKey: .sharedID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(unsentAt, forKey: .unsentAt)
        try c.encode(reactions, forKey: .reactions)
    }
}

/// How a shared object looks to the reader right now, from `shared_preview`.
/// `available` is false when the reader can't see it (private, deleted, or
/// the owner blocked them); nothing else is filled in then. Never carries a
/// location or a route.
public struct SharedPreview: Codable, Hashable, Sendable {
    public var kind: SharedKind
    public var id: UUID
    public var available: Bool
    public var title: String?
    public var subtitle: String?
    public var imagePath: String?
    public var ownerID: UserID?
    public var ownerUsername: String?
    public var vehicleKind: VehicleKind?
    public var bodyStyle: BodyStyle?
    public var identityColor: AccentChoice?
    public var startsAt: Date?
    public var cancelled: Bool?
    public var distanceMeters: Double?
    public var movingSeconds: Double?
    public var vehicleTitle: String?

    public init(
        kind: SharedKind, id: UUID, available: Bool, title: String? = nil, subtitle: String? = nil, imagePath: String? = nil,
        ownerID: UserID? = nil, ownerUsername: String? = nil, vehicleKind: VehicleKind? = nil, bodyStyle: BodyStyle? = nil,
        identityColor: AccentChoice? = nil, startsAt: Date? = nil, cancelled: Bool? = nil, distanceMeters: Double? = nil,
        movingSeconds: Double? = nil, vehicleTitle: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.available = available
        self.title = title
        self.subtitle = subtitle
        self.imagePath = imagePath
        self.ownerID = ownerID
        self.ownerUsername = ownerUsername
        self.vehicleKind = vehicleKind
        self.bodyStyle = bodyStyle
        self.identityColor = identityColor
        self.startsAt = startsAt
        self.cancelled = cancelled
        self.distanceMeters = distanceMeters
        self.movingSeconds = movingSeconds
        self.vehicleTitle = vehicleTitle
    }

    enum CodingKeys: String, CodingKey {
        case kind, id, available, title, subtitle, cancelled
        case imagePath = "image_path"
        case ownerID = "owner_id"
        case ownerUsername = "owner_username"
        case vehicleKind = "vehicle_kind"
        case bodyStyle = "body_style"
        case identityColor = "identity_color"
        case startsAt = "starts_at"
        case distanceMeters = "distance_m"
        case movingSeconds = "moving_s"
        case vehicleTitle = "vehicle_title"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SharedKind.self, forKey: .kind)
        id = try c.decode(UUID.self, forKey: .id)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        ownerID = try c.decodeIfPresent(UUID.self, forKey: .ownerID)
        ownerUsername = try c.decodeIfPresent(String.self, forKey: .ownerUsername)
        // Unknown enum values (a newer server) degrade to nil, not a failure.
        vehicleKind = (try? c.decodeIfPresent(String.self, forKey: .vehicleKind)).flatMap(VehicleKind.init(rawValue:))
        bodyStyle = (try? c.decodeIfPresent(String.self, forKey: .bodyStyle)).flatMap(BodyStyle.init(rawValue:))
        identityColor = (try? c.decodeIfPresent(String.self, forKey: .identityColor)).flatMap(AccentChoice.init(rawValue:))
        startsAt = try c.decodeIfPresent(Date.self, forKey: .startsAt)
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled)
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters)
        movingSeconds = try c.decodeIfPresent(Double.self, forKey: .movingSeconds)
        vehicleTitle = try c.decodeIfPresent(String.self, forKey: .vehicleTitle)
    }
}

/// Who may start a conversation with you.
public enum MessagesFrom: String, Codable, Sendable, CaseIterable, Identifiable {
    case everyone, following, nobody

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .everyone: "Everyone"
        case .following: "People I follow"
        case .nobody: "Nobody"
        }
    }

    public var explanation: String {
        switch self {
        case .everyone: "People you don't follow land in Requests. They can send three messages until you accept."
        case .following: "Only people you follow can start a conversation."
        case .nobody: "Nobody can start a new conversation. Existing ones keep working."
        }
    }
}

public enum ReportReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case spam, harassment, hate, sexual, violence, scam, impersonation, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .spam: "Spam"
        case .harassment: "Harassment or bullying"
        case .hate: "Hate speech"
        case .sexual: "Sexual content"
        case .violence: "Threats or violence"
        case .scam: "Scam or fraud"
        case .impersonation: "Pretending to be someone else"
        case .other: "Something else"
        }
    }
}

/// What a report from outside Messages is about. The server looks it up as
/// the reporter sees it and keeps a copy for staff (`report_content`).
public struct ReportedContent: Hashable, Sendable {
    public enum Kind: String, Sendable { case post, comment, meet, profile }

    public var kind: Kind
    public var id: UUID

    public init(_ kind: Kind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

/// Badge counts for the Messages button.
public struct UnreadMessages: Codable, Hashable, Sendable {
    public var conversations: Int
    public var requests: Int

    public init(conversations: Int = 0, requests: Int = 0) {
        self.conversations = conversations
        self.requests = requests
    }

    public var total: Int { conversations + requests }

    enum CodingKeys: String, CodingKey {
        case conversations = "unread_conversations"
        case requests
    }
}

/// A message the device is about to send.
public struct OutgoingMessage: Sendable, Hashable {
    public struct Photo: Sendable, Hashable {
        /// Already re-encoded on the device, so it carries no EXIF or location.
        public var jpegData: Data
        public var width: Int
        public var height: Int

        public init(jpegData: Data, width: Int, height: Int) {
            self.jpegData = jpegData
            self.width = width
            self.height = height
        }
    }

    public var id: UUID
    public var conversationID: UUID
    public var body: String
    public var photo: Photo?
    public var shared: SharedRef?

    public init(id: UUID = UUID(), conversationID: UUID, body: String, photo: Photo? = nil, shared: SharedRef? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.body = body
        self.photo = photo
        self.shared = shared
    }
}

/// A realtime nudge: something changed in one of your conversations.
public struct MessagingChange: Sendable, Hashable {
    /// Nil when the change can't be tied to a conversation (a reaction).
    public var conversationID: UUID?

    public init(conversationID: UUID?) {
        self.conversationID = conversationID
    }
}

public enum MessageRules {
    public static let maxLength = 2000
    /// The server's limit for messages before a request is accepted.
    public static let requestMessageLimit = 3
    public static let reactions = ["👍", "❤️", "😂", "🔥", "😮", "😢", "🏁"]

    public static func trimmed(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the composer can send: text within the limit, or an attachment.
    public static func canSend(body: String, hasAttachment: Bool) -> Bool {
        let text = trimmed(body)
        guard text.count <= maxLength else { return false }
        return !text.isEmpty || hasAttachment
    }

    /// Characters left, shown once the person gets close to the limit.
    public static func remaining(_ body: String) -> Int? {
        let left = maxLength - body.count
        return left <= 200 ? left : nil
    }
}
