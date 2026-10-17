import Foundation

/// Which pushes someone wants. Stored on the server, which decides whether to
/// push; the in-app activity list and inbox ignore these.
public struct NotificationPreferences: Codable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case messages, messageRequests, likesComments, followers, meets, drives
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .messages: "Messages"
            case .messageRequests: "Message requests"
            case .likesComments: "Likes and comments"
            case .followers: "New followers"
            case .meets: "Meets"
            case .drives: "Drive checks"
            }
        }

        public var detail: String {
            switch self {
            case .messages: "From people in your inbox."
            case .messageRequests: "First messages from people you don't follow."
            case .likesComments: "On your posts."
            case .followers: "Follows and follow requests."
            case .meets: "RSVPs, changes, cancellations and reminders for meets you're in."
            case .drives: "When a drive has been checked for leaderboards."
            }
        }

        public init?(kind: AppNotification.Kind) {
            switch kind {
            case .message: self = .messages
            case .messageRequest: self = .messageRequests
            case .like, .comment: self = .likesComments
            case .follow, .followRequest: self = .followers
            case .meetRSVP, .meetUpdated, .meetCancelled, .meetStartingSoon: self = .meets
            case .driveValidated: self = .drives
            }
        }
    }

    public var messages: Bool
    public var messageRequests: Bool
    public var likesComments: Bool
    public var followers: Bool
    public var meets: Bool
    public var drives: Bool
    /// Show message text in pushes. Off by default; never applies to requests.
    public var messagePreviews: Bool

    public init(
        messages: Bool = true, messageRequests: Bool = true, likesComments: Bool = true, followers: Bool = true,
        meets: Bool = true, drives: Bool = true, messagePreviews: Bool = false
    ) {
        self.messages = messages
        self.messageRequests = messageRequests
        self.likesComments = likesComments
        self.followers = followers
        self.meets = meets
        self.drives = drives
        self.messagePreviews = messagePreviews
    }

    public subscript(category: Category) -> Bool {
        get {
            switch category {
            case .messages: messages
            case .messageRequests: messageRequests
            case .likesComments: likesComments
            case .followers: followers
            case .meets: meets
            case .drives: drives
            }
        }
        set {
            switch category {
            case .messages: messages = newValue
            case .messageRequests: messageRequests = newValue
            case .likesComments: likesComments = newValue
            case .followers: followers = newValue
            case .meets: meets = newValue
            case .drives: drives = newValue
            }
        }
    }

    /// Mirrors public.push_content on the server.
    public func pushes(_ kind: AppNotification.Kind) -> Bool {
        Category(kind: kind).map { self[$0] } ?? true
    }

    enum CodingKeys: String, CodingKey {
        case messages, messageRequests = "message_requests", likesComments = "likes_comments", followers, meets, drives
        case messagePreviews = "message_previews"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NotificationPreferences()
        messages = try c.decodeIfPresent(Bool.self, forKey: .messages) ?? defaults.messages
        messageRequests = try c.decodeIfPresent(Bool.self, forKey: .messageRequests) ?? defaults.messageRequests
        likesComments = try c.decodeIfPresent(Bool.self, forKey: .likesComments) ?? defaults.likesComments
        followers = try c.decodeIfPresent(Bool.self, forKey: .followers) ?? defaults.followers
        meets = try c.decodeIfPresent(Bool.self, forKey: .meets) ?? defaults.meets
        drives = try c.decodeIfPresent(Bool.self, forKey: .drives) ?? defaults.drives
        messagePreviews = try c.decodeIfPresent(Bool.self, forKey: .messagePreviews) ?? defaults.messagePreviews
    }
}

/// Where tapping a push goes, read from the payload send-push builds
/// (`kind`, `conversation_id`). Anything unexpected opens the activity list.
public enum PushRoute: Hashable, Sendable {
    case conversation(UUID, isRequest: Bool)
    case activity

    public init?(kind: String?, conversationID: String?) {
        guard let kind else { return nil }
        let parsed = AppNotification.Kind(rawValue: kind)
        guard parsed == .message || parsed == .messageRequest else {
            self = .activity
            return
        }
        guard let id = conversationID.flatMap(UUID.init(uuidString:)) else {
            self = .activity
            return
        }
        self = .conversation(id, isRequest: parsed == .messageRequest)
    }
}
