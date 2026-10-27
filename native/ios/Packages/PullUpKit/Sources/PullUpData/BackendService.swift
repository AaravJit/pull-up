import Foundation
import PullUpDomain

/// Everything the app needs from the server, in one seam.
///
/// Two implementations exist:
///   * `SupabaseBackend` talks to the real Supabase project. Authorization
///     is enforced there by row-level security; nothing in this protocol is a
///     security boundary.
///   * `DemoBackend` is an in-memory stand-in used by SwiftUI previews, UI
///     tests and CI screenshots. The app shows a permanent "Demo data" strip
///     whenever it is active, so it can never be mistaken for real data.
public protocol BackendService: AnyObject, Sendable {
    var mode: BackendMode { get }

    // Auth
    func currentUserID() async -> UserID?
    func authChanges() -> AsyncStream<UserID?>
    /// Email sign-in exists only for accounts created by Pull Up support (the
    /// App Review demo account). New accounts use Sign in with Apple.
    func signIn(email: String, password: String) async throws
    func signInWithApple(idToken: String, nonce: String) async throws
    func signOut() async throws
    /// Completes sign-in from an auth link (pullup://auth-callback).
    func handleAuthCallback(_ url: URL) async throws
    /// Deletes the account on the server. For Sign in with Apple accounts the
    /// server also revokes Apple's tokens when given a fresh authorization code.
    func deleteAccount(appleAuthorizationCode: String?) async throws -> AccountDeletion

    // Account and onboarding
    func account() async throws -> AccountState
    func usernameStatus(_ username: String) async throws -> UsernameStatus
    /// Claims a username (and display name). Throws when it's taken or not allowed.
    func claimUsername(_ username: String, displayName: String) async throws
    /// Uploads an already EXIF-stripped JPEG as the profile photo.
    func uploadAvatar(jpegData: Data) async throws
    func completeOnboarding() async throws

    // Profiles and graph
    func profilePage(_ id: UserID) async throws -> ProfilePage
    func updateProfile(_ update: ProfileUpdate) async throws
    func follow(_ id: UserID) async throws
    func unfollow(_ id: UserID) async throws
    /// People waiting for you to approve their follow, when "Approve new
    /// followers" is on.
    func followRequests() async throws -> [ProfileStub]
    /// Accepting turns the request into a follow; declining deletes it.
    func answerFollowRequest(from id: UserID, accept: Bool) async throws
    func searchProfiles(_ query: String) async throws -> [ProfileStub]

    // Privacy
    func privacySettings() async throws -> PrivacySettings
    func updatePrivacySettings(_ settings: PrivacySettings) async throws
    func privacyZones() async throws -> [PrivacyZone]
    func addPrivacyZone(_ zone: PrivacyZone) async throws
    func deletePrivacyZone(_ id: UUID) async throws

    // Garage
    func vehicles(owner: UserID) async throws -> [Vehicle]
    func saveVehicle(_ vehicle: Vehicle) async throws -> Vehicle
    func deleteVehicle(_ id: UUID) async throws
    func modifications(vehicle: UUID) async throws -> [VehicleModification]
    func saveModification(_ mod: VehicleModification) async throws
    func deleteModification(_ id: UUID) async throws
    func photos(vehicle: UUID) async throws -> [VehiclePhoto]
    func addPhoto(vehicle: Vehicle, jpegData: Data) async throws -> VehiclePhoto

    // Drives
    func drives(owner: UserID, limit: Int) async throws -> [Drive]
    func upload(drive: Drive, track: [LocationSample]) async throws -> Drive
    func updateDrive(_ id: UUID, title: String, audience: Audience) async throws
    func deleteDrive(_ id: UUID) async throws
    func ownTrack(drive: UUID) async throws -> [LocationSample]
    func sharedRoute(drive: UUID) async throws -> [[Coordinate]]?
    func shareRoute(drive: UUID) async throws -> [[Coordinate]]
    func unshareRoute(drive: UUID) async throws

    // Feed
    func feed(_ scope: FeedScope, before: Date?) async throws -> [Post]
    /// Uploads the draft's media, then publishes the post with all of it at
    /// once (see `PostPublisher`). Calling it again with the same draft
    /// returns the same post.
    func createPost(_ post: NewPost) async throws -> Post
    /// Abandons an unpublished draft and deletes the files it uploaded.
    func discardPostDraft(_ id: UUID) async
    /// After the app was closed mid-post: deletes the files of drafts that
    /// never published. Run at sign-in.
    func recoverInterruptedPosts() async
    func setLiked(_ liked: Bool, post: UUID) async throws
    func comments(post: UUID) async throws -> [Comment]
    func addComment(_ body: String, post: UUID) async throws -> Comment
    func deletePost(_ id: UUID) async throws

    // Meets
    func meets(from: Date) async throws -> [Meet]
    func createMeet(_ meet: Meet) async throws -> Meet
    func cancelMeet(_ id: UUID) async throws
    func setRSVP(_ rsvp: RSVP?, meet: UUID) async throws
    func attendees(meet: UUID) async throws -> [ProfileStub]

    // Leaderboards
    func leaderboard(_ query: LeaderboardQuery) async throws -> [LeaderboardEntry]

    // Direct messages. Every rule (blocks, requests, rate limits, who can
    // read what) is enforced by the server; see the DM migration.
    /// Returns the conversation with this person, creating it if needed.
    /// Refusals all read "you can't message this person", whatever the reason.
    func startConversation(with user: UserID) async throws -> UUID
    /// One page of the inbox, newest first; pass the last entry's
    /// `lastMessageAt` as `before` for the next page.
    func inbox(_ state: ConversationState, before: Date?) async throws -> [InboxEntry]
    /// One page of a conversation, oldest first, ending just before `before`.
    func messages(conversation: UUID, before: Date?, limit: Int) async throws -> [DirectMessage]
    /// Idempotent: sending the same `OutgoingMessage.id` twice stores one message.
    func send(_ message: OutgoingMessage) async throws -> DirectMessage
    /// Sets or (with nil) removes your reaction.
    func setReaction(_ emoji: String?, message: UUID) async throws
    func unsend(message: UUID) async throws
    func markRead(conversation: UUID) async throws
    func respondToRequest(conversation: UUID, accept: Bool) async throws
    func setMuted(_ muted: Bool, conversation: UUID) async throws
    /// Hides the conversation until a new message; `clearHistory` also
    /// deletes your copy of everything so far.
    func hideConversation(_ id: UUID, clearHistory: Bool) async throws
    func peerReadAt(conversation: UUID) async throws -> Date?
    func unreadMessages() async throws -> UnreadMessages
    func sharedPreview(_ ref: SharedRef) async throws -> SharedPreview
    func report(user: UserID, reason: ReportReason, details: String, message: UUID?) async throws
    /// Reports a post, comment, meet or profile by `author`, with the
    /// reporter's own note. Your own content can't be reported.
    func report(_ content: ReportedContent, author: UserID, reason: ReportReason, note: String) async throws
    func block(_ user: UserID) async throws
    /// Nudges when something changes in your conversations. Ends when the
    /// consuming task is cancelled.
    func messagingChanges() -> AsyncStream<MessagingChange>

    // Pull Up Pro
    /// The caller's entitlement as the server records it.
    func entitlement() async throws -> Entitlement
    /// Hands a StoreKit transaction (its JWS) to the server, which confirms
    /// it with Apple and returns the resulting entitlement. Throws
    /// `SubscriptionError`.
    func verifySubscription(signedTransaction: String) async throws -> Entitlement

    // Notifications
    func notifications() async throws -> [AppNotification]
    func markNotificationsRead() async throws
    /// Registers this phone's APNs token for the signed-in account. The
    /// server moves a token to whoever registered it last.
    func registerPushToken(_ token: String, sandbox: Bool) async throws
    /// Stops pushes to this phone for the signed-in account (sign-out).
    func unregisterPushToken(_ token: String) async throws
    func notificationPreferences() async throws -> NotificationPreferences
    func updateNotificationPreferences(_ preferences: NotificationPreferences) async throws

    // Media
    func mediaURL(_ bucket: MediaBucket, path: String) async -> URL?
}

public enum BackendMode: Sendable, Equatable {
    case live
    case demo
    /// No Supabase credentials in the build. Nothing works; the app explains why.
    case unconfigured
}

/// What the server reported after deleting an account.
public struct AccountDeletion: Sendable, Equatable {
    public enum AppleRevocation: Sendable, Equatable {
        /// Not a Sign in with Apple account.
        case notApplicable
        case revoked
        /// The account is gone, but Apple's link wasn't revoked (server not
        /// configured, prompt cancelled, or Apple refused). The person can
        /// remove Pull Up under Settings ▸ Apple Account ▸ Sign in with Apple.
        case notRevoked(reason: String)
    }

    public var apple: AppleRevocation

    public init(apple: AppleRevocation) {
        self.apple = apple
    }
}

public enum FeedScope: String, Sendable, CaseIterable, Identifiable {
    case following
    case discover
    public var id: String { rawValue }
    public var label: String { self == .following ? "Following" : "Discover" }
}

public enum MediaBucket: String, Sendable {
    case avatars
    case vehicleMedia = "vehicle-media"
    case postMedia = "post-media"
    case dmMedia = "dm-media"
}

public struct LeaderboardQuery: Hashable, Sendable {
    public var metric: LeaderboardMetric
    public var scope: LeaderboardScope
    public var period: LeaderboardPeriod
    public var vehicleKind: VehicleKind?

    public init(metric: LeaderboardMetric, scope: LeaderboardScope, period: LeaderboardPeriod, vehicleKind: VehicleKind?) {
        self.metric = metric
        self.scope = scope
        self.period = period
        self.vehicleKind = vehicleKind
    }
}

public struct NewPost: Sendable {
    public struct Media: Sendable {
        /// Names the uploaded file, so a retry recognises what's already up.
        public var id: UUID
        public var data: Data
        public var type: PostMedia.MediaType
        public var width: Int
        public var height: Int
        public var duration: Double?

        public init(id: UUID = UUID(), data: Data, type: PostMedia.MediaType, width: Int, height: Int, duration: Double? = nil) {
            self.id = id
            self.data = data
            self.type = type
            self.width = width
            self.height = height
            self.duration = duration
        }
    }

    /// The post's id, made once per draft. Submitting the same draft again
    /// (a double tap, or a retry after a lost response) can't make a second post.
    public var id: UUID
    public var kind: Post.Kind
    public var caption: String
    public var audience: Audience
    public var vehicleID: UUID?
    public var meetID: UUID?
    public var driveID: UUID?
    public var media: [Media]

    public init(id: UUID = UUID(), kind: Post.Kind, caption: String, audience: Audience, vehicleID: UUID? = nil, meetID: UUID? = nil, driveID: UUID? = nil, media: [Media] = []) {
        self.id = id
        self.kind = kind
        self.caption = caption
        self.audience = audience
        self.vehicleID = vehicleID
        self.meetID = meetID
        self.driveID = driveID
        self.media = media
    }
}

public struct ProfileUpdate: Sendable {
    public var displayName: String
    public var username: String
    public var bio: String
    public var countryCode: String?
    public var regionCode: String?
    public var audience: Audience
    public var presentation: ProfilePresentation

    public init(displayName: String, username: String, bio: String, countryCode: String?, regionCode: String?, audience: Audience, presentation: ProfilePresentation) {
        self.displayName = displayName
        self.username = username
        self.bio = bio
        self.countryCode = countryCode
        self.regionCode = regionCode
        self.audience = audience
        self.presentation = presentation
    }
}

/// Everything a profile screen renders, as returned by `get_profile`.
public struct ProfilePage: Codable, Hashable, Sendable {
    public struct Relationship: Codable, Hashable, Sendable {
        public var iFollow: String?
        public var followsMe: String?

        public init(iFollow: String? = nil, followsMe: String? = nil) {
            self.iFollow = iFollow
            self.followsMe = followsMe
        }

        public var isFriend: Bool { iFollow == "accepted" && followsMe == "accepted" }

        enum CodingKeys: String, CodingKey {
            case iFollow = "i_follow"
            case followsMe = "follows_me"
        }
    }

    public var profile: Profile
    public var isVerifiedOrganizer: Bool
    public var canViewContent: Bool
    public var followerCount: Int
    public var followingCount: Int
    public var relationship: Relationship

    public init(profile: Profile, isVerifiedOrganizer: Bool = false, canViewContent: Bool = true, followerCount: Int = 0, followingCount: Int = 0, relationship: Relationship = .init()) {
        self.profile = profile
        self.isVerifiedOrganizer = isVerifiedOrganizer
        self.canViewContent = canViewContent
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.relationship = relationship
    }

    enum CodingKeys: String, CodingKey {
        case relationship
        case isVerifiedOrganizer = "is_verified_organizer"
        case canViewContent = "can_view_content"
        case followerCount = "follower_count"
        case followingCount = "following_count"
    }

    public init(from decoder: any Decoder) throws {
        profile = try Profile(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isVerifiedOrganizer = try c.decodeIfPresent(Bool.self, forKey: .isVerifiedOrganizer) ?? false
        canViewContent = try c.decodeIfPresent(Bool.self, forKey: .canViewContent) ?? false
        followerCount = try c.decodeIfPresent(Int.self, forKey: .followerCount) ?? 0
        followingCount = try c.decodeIfPresent(Int.self, forKey: .followingCount) ?? 0
        relationship = try c.decodeIfPresent(Relationship.self, forKey: .relationship) ?? .init()
    }

    public func encode(to encoder: any Encoder) throws {
        try profile.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isVerifiedOrganizer, forKey: .isVerifiedOrganizer)
        try c.encode(canViewContent, forKey: .canViewContent)
        try c.encode(followerCount, forKey: .followerCount)
        try c.encode(followingCount, forKey: .followingCount)
        try c.encode(relationship, forKey: .relationship)
    }
}

public enum BackendError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case notSignedIn
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "This build has no Pull Up server configured."
        case .notSignedIn: "Sign in to continue."
        case let .server(message): message
        }
    }
}

/// Converts a track to the compact wire format stored in `drive_tracks`:
/// `[t_offset_s, lat, lon, alt, speed, h_acc, v_acc, speed_acc]`.
public enum TrackEncoding {
    public static func encode(_ samples: [LocationSample], start: Date) -> [[Double]] {
        samples.map {
            [
                ($0.timestamp.timeIntervalSince(start) * 100).rounded() / 100,
                $0.latitude, $0.longitude,
                ($0.altitude * 10).rounded() / 10,
                ($0.speed * 100).rounded() / 100,
                ($0.horizontalAccuracy * 10).rounded() / 10,
                ($0.verticalAccuracy * 10).rounded() / 10,
                ($0.speedAccuracy * 100).rounded() / 100,
            ]
        }
    }

    public static func decode(_ rows: [[Double]], start: Date) -> [LocationSample] {
        rows.compactMap { r in
            guard r.count >= 6 else { return nil }
            return LocationSample(
                timestamp: start.addingTimeInterval(r[0]), latitude: r[1], longitude: r[2], altitude: r[3],
                horizontalAccuracy: r[5], verticalAccuracy: r.count > 6 ? r[6] : -1,
                speed: r[4], speedAccuracy: r.count > 7 ? r[7] : -1
            )
        }
    }
}

public extension BackendService {
    func handleAuthCallback(_ url: URL) async throws {}
    func discardPostDraft(_ id: UUID) async {}
    func recoverInterruptedPosts() async {}
    func followRequests() async throws -> [ProfileStub] { throw BackendError.notConfigured }
    func answerFollowRequest(from id: UserID, accept: Bool) async throws { throw BackendError.notConfigured }
}
