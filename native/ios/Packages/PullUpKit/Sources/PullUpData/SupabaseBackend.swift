import Foundation
import Supabase
import PullUpDomain

/// Supabase connection details read from the app's Info.plist, which takes
/// them from the git-ignored `Config/Secrets.xcconfig` (see docs). The anon
/// key is a publishable key; row-level security is what protects data.
public struct BackendConfiguration: Sendable, Equatable {
    public var url: URL
    public var anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> BackendConfiguration? {
        guard let host = bundle.object(forInfoDictionaryKey: "PullUpSupabaseHost") as? String,
              let key = bundle.object(forInfoDictionaryKey: "PullUpSupabaseAnonKey") as? String,
              !host.isEmpty, !key.isEmpty, !host.hasPrefix("$("),
              let url = URL(string: host.hasPrefix("http") ? host : "https://\(host)")
        else { return nil }
        return BackendConfiguration(url: url, anonKey: key)
    }
}

public final class SupabaseBackend: BackendService, @unchecked Sendable {
    // `SupabaseClient` is thread-safe; @unchecked covers the stored URL cache.
    public let client: SupabaseClient
    public var mode: BackendMode { .live }
    private let urlCache = SignedURLCache()

    public init(configuration: BackendConfiguration) {
        client = SupabaseClient(supabaseURL: configuration.url, supabaseKey: configuration.anonKey)
    }

    private func uid() async throws -> UserID {
        guard let id = await currentUserID() else { throw BackendError.notSignedIn }
        return id
    }

    // MARK: Auth

    public func currentUserID() async -> UserID? {
        try? await client.auth.session.user.id
    }

    public func authChanges() -> AsyncStream<UserID?> {
        let auth = client.auth
        return AsyncStream { continuation in
            let task = Task {
                for await (_, session) in auth.authStateChanges {
                    continuation.yield(session?.user.id)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    public func signUp(email: String, password: String, username: String) async throws -> SignUpOutcome {
        let response = try await client.auth.signUp(
            email: email, password: password,
            data: ["username": .string(username.lowercased())],
            redirectTo: URL(string: "pullup://auth-callback")
        )
        return response.session == nil ? .confirmEmail : .signedIn
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        try await client.auth.signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
    }

    public func signOut() async throws {
        try await client.auth.signOut()
    }

    public func deleteAccount() async throws {
        try await client.functions.invoke("delete-account", options: FunctionInvokeOptions(method: .post))
        try? await client.auth.signOut()
    }

    // MARK: Profiles

    public func profilePage(_ id: UserID) async throws -> ProfilePage {
        let page: ProfilePage? = try await client.rpc("get_profile", params: ["p_user": id.uuidString]).execute().value
        guard let page else { throw BackendError.server("This profile isn't available.") }
        return page
    }

    public func updateProfile(_ update: ProfileUpdate) async throws {
        let id = try await uid()
        struct ProfileRow: Encodable {
            let username: String
            let display_name: String
            let visibility: Audience
            let presentation: ProfilePresentation
        }
        struct DetailsRow: Encodable {
            let bio: String
            let country_code: String?
            let region_code: String?
        }
        try await client.from("profiles")
            .update(ProfileRow(username: update.username.lowercased(), display_name: update.displayName, visibility: update.audience, presentation: update.presentation))
            .eq("id", value: id).execute()
        try await client.from("profile_details")
            .update(DetailsRow(bio: update.bio, country_code: update.countryCode, region_code: update.regionCode))
            .eq("user_id", value: id).execute()
    }

    public func follow(_ id: UserID) async throws {
        let me = try await uid()
        try await client.from("follows").insert(["follower_id": me.uuidString, "followee_id": id.uuidString]).execute()
    }

    public func unfollow(_ id: UserID) async throws {
        let me = try await uid()
        try await client.from("follows").delete().eq("follower_id", value: me).eq("followee_id", value: id).execute()
    }

    public func searchProfiles(_ query: String) async throws -> [ProfileStub] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        return try await client.from("profiles")
            .select("id, username, display_name, avatar_path")
            .ilike("username", pattern: "\(q)%")
            .limit(20).execute().value
    }

    // MARK: Privacy

    public func privacySettings() async throws -> PrivacySettings {
        let id = try await uid()
        let rows: [PrivacySettingsRow] = try await client.from("privacy_settings").select().eq("user_id", value: id).execute().value
        guard let row = rows.first else { return PrivacySettings() }
        let profile: [AudienceRow] = try await client.from("profiles").select("visibility").eq("id", value: id).execute().value
        var settings = row.settings
        settings.profileVisibility = profile.first?.visibility ?? .public
        return settings
    }

    public func updatePrivacySettings(_ settings: PrivacySettings) async throws {
        let id = try await uid()
        try await client.from("privacy_settings").update(PrivacySettingsRow(settings)).eq("user_id", value: id).execute()
        try await client.from("profiles").update(AudienceRow(visibility: settings.profileVisibility)).eq("id", value: id).execute()
    }

    public func privacyZones() async throws -> [PrivacyZone] {
        try await client.from("privacy_zones").select().order("created_at").execute().value
    }

    public func addPrivacyZone(_ zone: PrivacyZone) async throws {
        let id = try await uid()
        struct Row: Encodable { let id: UUID; let user_id: UUID; let label: String; let lat: Double; let lon: Double; let radius_m: Double }
        try await client.from("privacy_zones")
            .insert(Row(id: zone.id, user_id: id, label: zone.label, lat: zone.center.latitude, lon: zone.center.longitude, radius_m: zone.radiusMeters))
            .execute()
    }

    public func deletePrivacyZone(_ id: UUID) async throws {
        try await client.from("privacy_zones").delete().eq("id", value: id).execute()
    }

    // MARK: Garage

    public func vehicles(owner: UserID) async throws -> [Vehicle] {
        try await client.from("vehicles").select().eq("owner_id", value: owner).order("position").order("created_at").execute().value
    }

    public func saveVehicle(_ vehicle: Vehicle) async throws -> Vehicle {
        try await client.from("vehicles").upsert(vehicle).select().single().execute().value
    }

    public func deleteVehicle(_ id: UUID) async throws {
        try await client.from("vehicles").delete().eq("id", value: id).execute()
    }

    public func modifications(vehicle: UUID) async throws -> [VehicleModification] {
        try await client.from("vehicle_mods").select().eq("vehicle_id", value: vehicle).order("installed_on", ascending: false).execute().value
    }

    public func saveModification(_ mod: VehicleModification) async throws {
        try await client.from("vehicle_mods").upsert(mod).execute()
    }

    public func deleteModification(_ id: UUID) async throws {
        try await client.from("vehicle_mods").delete().eq("id", value: id).execute()
    }

    public func photos(vehicle: UUID) async throws -> [VehiclePhoto] {
        try await client.from("vehicle_photos").select().eq("vehicle_id", value: vehicle).order("position").execute().value
    }

    public func addPhoto(vehicle: Vehicle, jpegData: Data) async throws -> VehiclePhoto {
        let path = "\(vehicle.ownerID.uuidString.lowercased())/\(vehicle.id.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage.from(MediaBucket.vehicleMedia.rawValue)
            .upload(path, data: jpegData, options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg"))
        let existing = try await photos(vehicle: vehicle.id)
        let photo = VehiclePhoto(vehicleID: vehicle.id, storagePath: path, position: existing.count)
        try await client.from("vehicle_photos").insert(photo).execute()
        if vehicle.coverPhotoPath == nil {
            try await client.from("vehicles").update(["cover_photo_path": path]).eq("id", value: vehicle.id).execute()
        }
        return photo
    }

    // MARK: Drives

    public func drives(owner: UserID, limit: Int) async throws -> [Drive] {
        try await client.from("drives").select(Self.driveColumns).eq("owner_id", value: owner)
            .order("started_at", ascending: false).limit(limit).execute().value
    }

    static let driveColumns = "id, owner_id, vehicle_id, title, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps, avg_moving_speed_mps, elevation_gain_m, elevation_loss_m, zero_to_sixty_s, zero_to_sixty_quality, visibility, validation_status, has_shared_route"

    public func upload(drive: Drive, track: [LocationSample]) async throws -> Drive {
        // Idempotent: a retry after a dropped connection must not duplicate.
        try await client.from("drives").upsert(drive, onConflict: "id", ignoreDuplicates: true).execute()
        struct TrackRow: Encodable { let drive_id: UUID; let owner_id: UUID; let points: [[Double]] }
        let existing: [IDRow] = try await client.from("drive_tracks").select("drive_id").eq("drive_id", value: drive.id).execute().value
        if existing.isEmpty {
            try await client.from("drive_tracks")
                .insert(TrackRow(drive_id: drive.id, owner_id: drive.ownerID, points: TrackEncoding.encode(track, start: drive.startedAt)))
                .execute()
        }
        return try await client.from("drives").select(Self.driveColumns).eq("id", value: drive.id).single().execute().value
    }

    public func updateDrive(_ id: UUID, title: String, audience: Audience) async throws {
        struct Row: Encodable { let title: String; let visibility: Audience }
        try await client.from("drives").update(Row(title: title, visibility: audience)).eq("id", value: id).execute()
    }

    public func deleteDrive(_ id: UUID) async throws {
        try await client.from("drives").delete().eq("id", value: id).execute()
    }

    public func ownTrack(drive: UUID) async throws -> [LocationSample] {
        struct Row: Decodable { let points: [[Double]] }
        let rows: [Row] = try await client.from("drive_tracks").select("points").eq("drive_id", value: drive).execute().value
        let started: [StartRow] = try await client.from("drives").select("started_at").eq("id", value: drive).execute().value
        guard let points = rows.first?.points, let start = started.first?.started_at else { return [] }
        return TrackEncoding.decode(points, start: start)
    }

    public func sharedRoute(drive: UUID) async throws -> [[Coordinate]]? {
        struct Row: Decodable { let segments: [[[Double]]] }
        let rows: [Row] = try await client.from("drive_shared_routes").select("segments").eq("drive_id", value: drive).execute().value
        return rows.first.map { Self.coordinates($0.segments) }
    }

    public func shareRoute(drive: UUID) async throws -> [[Coordinate]] {
        let segments: [[[Double]]] = try await client.rpc("share_drive_route", params: ["p_drive": drive.uuidString]).execute().value
        return Self.coordinates(segments)
    }

    public func unshareRoute(drive: UUID) async throws {
        try await client.rpc("unshare_drive_route", params: ["p_drive": drive.uuidString]).execute()
    }

    static func coordinates(_ segments: [[[Double]]]) -> [[Coordinate]] {
        segments.map { $0.compactMap { $0.count >= 2 ? Coordinate(latitude: $0[0], longitude: $0[1]) : nil } }
    }

    // MARK: Feed

    static let postColumns = "*, like_count, comment_count, liked_by_me, media:post_media(id, storage_path, media_type, width, height, duration_s), author:profiles!posts_author_id_fkey(id, username, display_name, avatar_path)"

    public func feed(_ scope: FeedScope, before: Date?) async throws -> [Post] {
        let me = try await uid()
        var query = client.from("posts").select(Self.postColumns)
        if scope == .following {
            let follows: [FolloweeRow] = try await client.from("follows").select("followee_id")
                .eq("follower_id", value: me).eq("status", value: "accepted").execute().value
            let authors = follows.map(\.followee_id.uuidString) + [me.uuidString]
            query = query.in("author_id", values: authors)
        }
        if let before {
            query = query.lt("created_at", value: before.ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true)))
        }
        return try await query.order("created_at", ascending: false).limit(20).execute().value
    }

    public func createPost(_ post: NewPost) async throws -> Post {
        let me = try await uid()
        let id = UUID()
        struct Row: Encodable {
            let id: UUID; let author_id: UUID; let kind: Post.Kind; let caption: String
            let vehicle_id: UUID?; let meet_id: UUID?; let drive_id: UUID?; let visibility: Audience
        }
        try await client.from("posts").insert(Row(
            id: id, author_id: me, kind: post.kind, caption: post.caption, vehicle_id: post.vehicleID,
            meet_id: post.meetID, drive_id: post.driveID, visibility: post.audience
        )).execute()
        struct MediaRow: Encodable {
            let post_id: UUID; let storage_path: String; let media_type: PostMedia.MediaType
            let width: Int; let height: Int; let duration_s: Double?; let position: Int
        }
        for (index, media) in post.media.enumerated() {
            let ext = media.type == .video ? "mp4" : "jpg"
            let path = "\(me.uuidString.lowercased())/\(id.uuidString.lowercased())/\(index).\(ext)"
            try await client.storage.from(MediaBucket.postMedia.rawValue).upload(
                path, data: media.data,
                options: FileOptions(cacheControl: "31536000", contentType: media.type == .video ? "video/mp4" : "image/jpeg")
            )
            try await client.from("post_media").insert(MediaRow(
                post_id: id, storage_path: path, media_type: media.type, width: media.width, height: media.height,
                duration_s: media.duration, position: index
            )).execute()
        }
        return try await client.from("posts").select(Self.postColumns).eq("id", value: id).single().execute().value
    }

    public func setLiked(_ liked: Bool, post: UUID) async throws {
        let me = try await uid()
        if liked {
            try await client.from("likes").upsert(["post_id": post.uuidString, "user_id": me.uuidString], ignoreDuplicates: true).execute()
        } else {
            try await client.from("likes").delete().eq("post_id", value: post).eq("user_id", value: me).execute()
        }
    }

    public func comments(post: UUID) async throws -> [Comment] {
        try await client.from("comments")
            .select("*, author:profiles!comments_author_id_fkey(id, username, display_name, avatar_path)")
            .eq("post_id", value: post).order("created_at").execute().value
    }

    public func addComment(_ body: String, post: UUID) async throws -> Comment {
        let me = try await uid()
        return try await client.from("comments")
            .insert(["post_id": post.uuidString, "author_id": me.uuidString, "body": body])
            .select("*, author:profiles!comments_author_id_fkey(id, username, display_name, avatar_path)")
            .single().execute().value
    }

    public func deletePost(_ id: UUID) async throws {
        try await client.from("posts").delete().eq("id", value: id).execute()
    }

    // MARK: Meets

    static let meetColumns = "*, going_count, interested_count, my_rsvp, host:profiles!meets_host_id_fkey(id, username, display_name, avatar_path)"

    public func meets(from: Date) async throws -> [Meet] {
        try await client.from("meets").select(Self.meetColumns)
            .gte("ends_at", value: from.ISO8601Format())
            .order("starts_at").limit(100).execute().value
    }

    public func createMeet(_ meet: Meet) async throws -> Meet {
        struct Row: Encodable {
            let id: UUID; let host_id: UUID; let title: String; let details: String; let kind: Meet.Kind; let focus: Meet.Focus
            let starts_at: Date; let ends_at: Date; let venue_name: String; let address: String
            let lat: Double; let lon: Double; let visibility: Audience; let capacity: Int?
        }
        let me = try await uid()
        try await client.from("meets").insert(Row(
            id: meet.id, host_id: me, title: meet.title, details: meet.details, kind: meet.kind, focus: meet.focus,
            starts_at: meet.startsAt, ends_at: meet.endsAt, venue_name: meet.venueName, address: meet.address,
            lat: meet.latitude, lon: meet.longitude, visibility: meet.visibility, capacity: meet.capacity
        )).execute()
        return try await client.from("meets").select(Self.meetColumns).eq("id", value: meet.id).single().execute().value
    }

    public func cancelMeet(_ id: UUID) async throws {
        try await client.from("meets").update(["cancelled_at": Date().ISO8601Format()]).eq("id", value: id).execute()
    }

    public func setRSVP(_ rsvp: RSVP?, meet: UUID) async throws {
        let me = try await uid()
        if let rsvp {
            struct Row: Encodable { let meet_id: UUID; let user_id: UUID; let status: RSVP.Status; let show_me: Bool }
            try await client.from("meet_rsvps").upsert(Row(meet_id: meet, user_id: me, status: rsvp.status, show_me: rsvp.showMe)).execute()
        } else {
            try await client.from("meet_rsvps").delete().eq("meet_id", value: meet).eq("user_id", value: me).execute()
        }
    }

    public func attendees(meet: UUID) async throws -> [ProfileStub] {
        try await client.rpc("meet_attendees", params: ["p_meet": meet.uuidString]).execute().value
    }

    // MARK: Leaderboards

    public func leaderboard(_ query: LeaderboardQuery) async throws -> [LeaderboardEntry] {
        struct Params: Encodable {
            let p_metric: String; let p_scope: String; let p_period: String; let p_vehicle_kind: String?; let p_limit: Int
        }
        return try await client.rpc("leaderboard", params: Params(
            p_metric: query.metric.rawValue, p_scope: query.scope.rawValue, p_period: query.period.rawValue,
            p_vehicle_kind: query.vehicleKind?.rawValue, p_limit: 100
        )).execute().value
    }

    // MARK: Notifications

    public func notifications() async throws -> [AppNotification] {
        try await client.from("notifications")
            .select("id, kind, post_id, meet_id, drive_id, created_at, read_at, actor:profiles!notifications_actor_id_fkey(id, username, display_name, avatar_path)")
            .order("created_at", ascending: false).limit(100).execute().value
    }

    public func markNotificationsRead() async throws {
        let me = try await uid()
        try await client.from("notifications").update(["read_at": Date().ISO8601Format()])
            .eq("recipient_id", value: me).is("read_at", value: nil).execute()
    }

    public func registerPushToken(_ token: String, sandbox: Bool) async throws {
        let me = try await uid()
        try await client.from("device_tokens").upsert([
            "token": token, "user_id": me.uuidString, "platform": "ios", "environment": sandbox ? "sandbox" : "production",
        ]).execute()
    }

    // MARK: Media

    public func mediaURL(_ bucket: MediaBucket, path: String) async -> URL? {
        let key = "\(bucket.rawValue)/\(path)"
        if let cached = await urlCache.url(for: key) { return cached }
        guard let url = try? await client.storage.from(bucket.rawValue).createSignedURL(path: path, expiresIn: 3_600) else { return nil }
        await urlCache.store(url, for: key, ttl: 3_000)
        return url
    }
}

// MARK: - Rows

private struct IDRow: Decodable { let drive_id: UUID }
private struct StartRow: Decodable { let started_at: Date }
private struct FolloweeRow: Decodable { let followee_id: UUID }
private struct AudienceRow: Codable { let visibility: Audience }

private struct PrivacySettingsRow: Codable {
    let default_vehicle_visibility: Audience
    let drive_history_visibility: Audience
    let allow_route_sharing: Bool
    let route_endpoint_trim_m: Int
    let show_event_attendance: Bool
    let leaderboard_opt_in: Bool
    let performance_leaderboard_opt_in: Bool
    let require_follow_approval: Bool

    init(_ s: PrivacySettings) {
        default_vehicle_visibility = s.defaultVehicleVisibility
        drive_history_visibility = s.driveHistoryVisibility
        allow_route_sharing = s.allowRouteSharing
        route_endpoint_trim_m = Int(s.routeEndpointTrimMeters)
        show_event_attendance = s.showEventAttendance
        leaderboard_opt_in = s.leaderboardOptIn
        performance_leaderboard_opt_in = s.performanceLeaderboardOptIn
        require_follow_approval = s.requireFollowApproval
    }

    var settings: PrivacySettings {
        PrivacySettings(
            defaultVehicleVisibility: default_vehicle_visibility, driveHistoryVisibility: drive_history_visibility,
            allowRouteSharing: allow_route_sharing, routeEndpointTrimMeters: Double(route_endpoint_trim_m),
            showEventAttendance: show_event_attendance, leaderboardOptIn: leaderboard_opt_in,
            performanceLeaderboardOptIn: performance_leaderboard_opt_in, requireFollowApproval: require_follow_approval
        )
    }
}

actor SignedURLCache {
    private var entries: [String: (URL, Date)] = [:]

    func url(for key: String) -> URL? {
        guard let entry = entries[key], entry.1 > .now else { return nil }
        return entry.0
    }

    func store(_ url: URL, for key: String, ttl: TimeInterval) {
        entries[key] = (url, Date().addingTimeInterval(ttl))
    }
}
