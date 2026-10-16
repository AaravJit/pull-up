import Foundation

public struct Post: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case moment       // photo / video / text
        case build        // vehicle build update
        case meet         // meet recap
        case drive        // shared drive summary
    }

    public var id: UUID
    public var authorID: UserID
    public var kind: Kind
    public var caption: String
    public var vehicleID: UUID?
    public var meetID: UUID?
    public var driveID: UUID?
    public var visibility: Visibility
    public var createdAt: Date
    public var likeCount: Int
    public var commentCount: Int
    public var likedByMe: Bool
    public var media: [PostMedia]
    public var author: ProfileStub?

    public init(
        id: UUID = UUID(), authorID: UserID, kind: Kind, caption: String, vehicleID: UUID? = nil,
        meetID: UUID? = nil, driveID: UUID? = nil, visibility: Visibility, createdAt: Date = .now,
        likeCount: Int = 0, commentCount: Int = 0, likedByMe: Bool = false, media: [PostMedia] = [], author: ProfileStub? = nil
    ) {
        self.id = id
        self.authorID = authorID
        self.kind = kind
        self.caption = caption
        self.vehicleID = vehicleID
        self.meetID = meetID
        self.driveID = driveID
        self.visibility = visibility
        self.createdAt = createdAt
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.likedByMe = likedByMe
        self.media = media
        self.author = author
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, caption, visibility, media, author
        case authorID = "author_id"
        case vehicleID = "vehicle_id"
        case meetID = "meet_id"
        case driveID = "drive_id"
        case createdAt = "created_at"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case likedByMe = "liked_by_me"
    }
}

public struct PostMedia: Codable, Hashable, Sendable, Identifiable {
    public enum MediaType: String, Codable, Sendable { case image, video }

    public var id: UUID
    public var storagePath: String
    public var mediaType: MediaType
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?

    public init(id: UUID = UUID(), storagePath: String, mediaType: MediaType, width: Int? = nil, height: Int? = nil, durationSeconds: Double? = nil) {
        self.id = id
        self.storagePath = storagePath
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }

    public var aspectRatio: Double {
        guard let width, let height, width > 0, height > 0 else { return 4.0 / 5.0 }
        return Double(width) / Double(height)
    }

    enum CodingKeys: String, CodingKey {
        case id, width, height
        case storagePath = "storage_path"
        case mediaType = "media_type"
        case durationSeconds = "duration_s"
    }
}

/// The subset of a profile embedded in feed rows and attendee lists.
public struct ProfileStub: Codable, Hashable, Sendable, Identifiable {
    public var id: UserID
    public var username: String
    public var displayName: String
    public var avatarPath: String?

    public init(id: UserID, username: String, displayName: String, avatarPath: String? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarPath = avatarPath
    }

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarPath = "avatar_path"
    }
}

public struct Comment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var postID: UUID
    public var authorID: UserID
    public var body: String
    public var createdAt: Date
    public var author: ProfileStub?

    public init(id: UUID = UUID(), postID: UUID, authorID: UserID, body: String, createdAt: Date = .now, author: ProfileStub? = nil) {
        self.id = id
        self.postID = postID
        self.authorID = authorID
        self.body = body
        self.createdAt = createdAt
        self.author = author
    }

    enum CodingKeys: String, CodingKey {
        case id, body, author
        case postID = "post_id"
        case authorID = "author_id"
        case createdAt = "created_at"
    }
}

public struct AppNotification: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case follow, followRequest = "follow_request", like, comment
        case meetRSVP = "meet_rsvp", meetUpdated = "meet_updated", meetCancelled = "meet_cancelled", meetStartingSoon = "meet_starting_soon"
        case driveValidated = "drive_validated"
    }

    public var id: UUID
    public var kind: Kind
    public var actor: ProfileStub?
    public var postID: UUID?
    public var meetID: UUID?
    public var driveID: UUID?
    public var createdAt: Date
    public var readAt: Date?

    public init(id: UUID, kind: Kind, actor: ProfileStub?, postID: UUID? = nil, meetID: UUID? = nil, driveID: UUID? = nil, createdAt: Date, readAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.actor = actor
        self.postID = postID
        self.meetID = meetID
        self.driveID = driveID
        self.createdAt = createdAt
        self.readAt = readAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, actor
        case postID = "post_id"
        case meetID = "meet_id"
        case driveID = "drive_id"
        case createdAt = "created_at"
        case readAt = "read_at"
    }
}

public struct Meet: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case meet, cruise, ride, show
        /// Closed-course event (track day, autocross). The only kind whose
        /// drives can feed performance leaderboards.
        case trackDay = "track_day"

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .meet: "Meet"
            case .cruise: "Cruise"
            case .ride: "Ride"
            case .show: "Show"
            case .trackDay: "Track day"
            }
        }
    }

    public enum Focus: String, Codable, CaseIterable, Sendable, Identifiable {
        case all, cars, motorcycles
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    public var id: UUID
    public var hostID: UserID
    public var title: String
    public var details: String
    public var kind: Kind
    public var focus: Focus
    public var startsAt: Date
    public var endsAt: Date
    public var venueName: String
    public var address: String
    public var latitude: Double
    public var longitude: Double
    public var visibility: Visibility
    public var capacity: Int?
    public var cancelledAt: Date?
    public var goingCount: Int
    public var interestedCount: Int
    public var host: ProfileStub?
    public var myRSVP: RSVP?

    public init(
        id: UUID = UUID(), hostID: UserID, title: String, details: String = "", kind: Kind, focus: Focus = .all,
        startsAt: Date, endsAt: Date, venueName: String, address: String = "", latitude: Double, longitude: Double,
        visibility: Visibility = .public, capacity: Int? = nil, cancelledAt: Date? = nil,
        goingCount: Int = 0, interestedCount: Int = 0, host: ProfileStub? = nil, myRSVP: RSVP? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.details = details
        self.kind = kind
        self.focus = focus
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.venueName = venueName
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.visibility = visibility
        self.capacity = capacity
        self.cancelledAt = cancelledAt
        self.goingCount = goingCount
        self.interestedCount = interestedCount
        self.host = host
        self.myRSVP = myRSVP
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    public var isCancelled: Bool { cancelledAt != nil }

    public func isLive(at date: Date = .now) -> Bool {
        !isCancelled && date >= startsAt && date <= endsAt
    }

    public var isFull: Bool {
        guard let capacity else { return false }
        return goingCount >= capacity
    }

    enum CodingKeys: String, CodingKey {
        case id, title, details, kind, focus, address, visibility, capacity, host
        case hostID = "host_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case venueName = "venue_name"
        case latitude = "lat"
        case longitude = "lon"
        case cancelledAt = "cancelled_at"
        case goingCount = "going_count"
        case interestedCount = "interested_count"
        case myRSVP = "my_rsvp"
    }
}

public struct RSVP: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case going, interested }

    public var status: Status
    /// Whether other attendees may see that this user is going. Off by default.
    public var showMe: Bool

    public init(status: Status, showMe: Bool = false) {
        self.status = status
        self.showMe = showMe
    }

    enum CodingKeys: String, CodingKey {
        case status
        case showMe = "show_me"
    }
}

/// Every privacy switch the user controls. Defaults are the most private
/// reasonable choice; the backend applies the same defaults.
public struct PrivacySettings: Codable, Hashable, Sendable {
    public var profileVisibility: Visibility
    public var defaultVehicleVisibility: Visibility
    public var driveHistoryVisibility: Visibility
    public var allowRouteSharing: Bool
    /// Extra distance cut from the start and end of every shared route.
    public var routeEndpointTrimMeters: Double
    public var showEventAttendance: Bool
    public var leaderboardOptIn: Bool
    public var performanceLeaderboardOptIn: Bool
    public var requireFollowApproval: Bool

    public init(
        profileVisibility: Visibility = .public, defaultVehicleVisibility: Visibility = .friends,
        driveHistoryVisibility: Visibility = .private, allowRouteSharing: Bool = false,
        routeEndpointTrimMeters: Double = 400, showEventAttendance: Bool = false,
        leaderboardOptIn: Bool = false, performanceLeaderboardOptIn: Bool = false, requireFollowApproval: Bool = false
    ) {
        self.profileVisibility = profileVisibility
        self.defaultVehicleVisibility = defaultVehicleVisibility
        self.driveHistoryVisibility = driveHistoryVisibility
        self.allowRouteSharing = allowRouteSharing
        self.routeEndpointTrimMeters = routeEndpointTrimMeters
        self.showEventAttendance = showEventAttendance
        self.leaderboardOptIn = leaderboardOptIn
        self.performanceLeaderboardOptIn = performanceLeaderboardOptIn
        self.requireFollowApproval = requireFollowApproval
    }

    enum CodingKeys: String, CodingKey {
        case profileVisibility = "profile_visibility"
        case defaultVehicleVisibility = "default_vehicle_visibility"
        case driveHistoryVisibility = "drive_history_visibility"
        case allowRouteSharing = "allow_route_sharing"
        case routeEndpointTrimMeters = "route_endpoint_trim_m"
        case showEventAttendance = "show_event_attendance"
        case leaderboardOptIn = "leaderboard_opt_in"
        case performanceLeaderboardOptIn = "performance_leaderboard_opt_in"
        case requireFollowApproval = "require_follow_approval"
    }
}

public enum LeaderboardMetric: String, Codable, CaseIterable, Sendable, Identifiable {
    case distance
    case drives
    case exploration
    case community
    case zeroToSixty = "zero_to_sixty"
    case topSpeed = "top_speed"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .distance: "Distance"
        case .drives: "Drives"
        case .exploration: "Explorer"
        case .community: "Community"
        case .zeroToSixty: "0–60"
        case .topSpeed: "Top speed"
        }
    }

    /// Performance boards only accept verified closed-course runs.
    public var isPerformance: Bool { self == .zeroToSixty || self == .topSpeed }
    /// Lower value ranks higher.
    public var ascending: Bool { self == .zeroToSixty }
}

public enum LeaderboardScope: String, Codable, CaseIterable, Sendable, Identifiable {
    case global, country, region, friends
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public enum LeaderboardPeriod: String, Codable, CaseIterable, Sendable, Identifiable {
    case week, month, allTime = "all_time"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .allTime: "All time"
        }
    }
}

public struct LeaderboardEntry: Codable, Hashable, Sendable, Identifiable {
    public var rank: Int
    public var user: ProfileStub
    public var value: Double
    public var vehicleTitle: String?
    public var isMe: Bool

    public var id: UserID { user.id }

    public init(rank: Int, user: ProfileStub, value: Double, vehicleTitle: String? = nil, isMe: Bool = false) {
        self.rank = rank
        self.user = user
        self.value = value
        self.vehicleTitle = vehicleTitle
        self.isMe = isMe
    }

    enum CodingKeys: String, CodingKey {
        case rank, value
        case user = "profile"
        case vehicleTitle = "vehicle_title"
        case isMe = "is_me"
    }
}
