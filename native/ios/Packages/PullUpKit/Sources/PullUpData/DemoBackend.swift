import Foundation
import Synchronization
import PullUpDomain
import PullUpTelemetry

/// In-memory backend for previews, UI tests and CI screenshots.
///
/// It is a prototype, not a fallback: the app never switches to it on its own
/// when the real server fails. It is selected explicitly with the
/// `-PullUpDemo` launch argument or by previews, and the UI marks every
/// screen with a "Demo data" strip while it is active. Privacy rules are
/// mimicked loosely here; the real enforcement lives in Postgres RLS and is
/// covered by supabase/tests.
public final class DemoBackend: BackendService, Sendable {
    public var mode: BackendMode { .demo }

    struct State: Sendable {
        var me: UserID?
        var profiles: [UserID: ProfilePage] = [:]
        var vehicles: [Vehicle] = []
        var mods: [VehicleModification] = []
        var photos: [VehiclePhoto] = []
        var drives: [Drive] = []
        var tracks: [UUID: [LocationSample]] = [:]
        var sharedRoutes: [UUID: [[Coordinate]]] = [:]
        var posts: [Post] = []
        var comments: [Comment] = []
        var meets: [Meet] = []
        var notifications: [AppNotification] = []
        var privacy = PrivacySettings()
        var zones: [PrivacyZone] = []
        var follows: Set<[UserID]> = []
        var onboarded = true
    }

    private let state: Mutex<State>
    private let authContinuations = Mutex<[UUID: AsyncStream<UserID?>.Continuation]>([:])

    /// `onboarded: false` starts as a brand-new Sign in with Apple account:
    /// placeholder username, no display name, onboarding not finished.
    public init(signedIn: Bool = true, emptyGarage: Bool = false, onboarded: Bool = true, now: Date = .now) {
        var seed = DemoSeed.make(signedIn: signedIn, emptyGarage: emptyGarage, now: now)
        if !onboarded {
            seed.onboarded = false
            seed.profiles[DemoSeed.meID]?.profile.username = "driver_3f9a1c22e0"
            seed.profiles[DemoSeed.meID]?.profile.displayName = ""
        }
        state = Mutex(seed)
    }

    private func me() throws -> UserID {
        guard let id = state.withLock({ $0.me }) else { throw BackendError.notSignedIn }
        return id
    }

    private func stub(_ id: UserID, in s: State) -> ProfileStub? {
        s.profiles[id].map { ProfileStub(id: $0.profile.id, username: $0.profile.username, displayName: $0.profile.displayName) }
    }

    private func broadcast(_ id: UserID?) {
        for c in authContinuations.withLock({ Array($0.values) }) { c.yield(id) }
    }

    // MARK: Auth

    public func currentUserID() async -> UserID? { state.withLock { $0.me } }

    public func authChanges() -> AsyncStream<UserID?> {
        let key = UUID()
        return AsyncStream { continuation in
            authContinuations.withLock { $0[key] = continuation }
            continuation.yield(state.withLock { $0.me })
            continuation.onTermination = { [weak self] _ in
                _ = self?.authContinuations.withLock { $0.removeValue(forKey: key) }
            }
        }
    }

    public func signIn(email: String, password: String) async throws {
        guard password.count >= 8 else { throw BackendError.server("Invalid login credentials") }
        state.withLock { $0.me = DemoSeed.meID }
        broadcast(DemoSeed.meID)
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        state.withLock { $0.me = DemoSeed.meID }
        broadcast(DemoSeed.meID)
    }

    public func signOut() async throws {
        state.withLock { $0.me = nil }
        broadcast(nil)
    }

    public func deleteAccount(appleAuthorizationCode: String?) async throws -> AccountDeletion {
        try await signOut()
        return AccountDeletion(apple: .notApplicable)
    }

    // MARK: Account

    public func account() async throws -> AccountState {
        let me = try me()
        return try state.withLock { s in
            guard let profile = s.profiles[me]?.profile else { throw BackendError.notSignedIn }
            return AccountState(
                id: me, username: profile.username, displayName: profile.displayName, avatarPath: profile.avatarPath,
                isOnboarded: s.onboarded, signInMethods: [.apple], usesPrivateRelayEmail: true
            )
        }
    }

    public func usernameStatus(_ username: String) async throws -> UsernameStatus {
        let me = try me()
        let name = UsernameRules.normalize(username)
        if let problem = UsernameRules.localProblem(name) { return problem }
        return state.withLock { s in
            s.profiles.values.contains { $0.profile.username == name && $0.profile.id != me } ? .taken : .available
        }
    }

    public func claimUsername(_ username: String, displayName: String) async throws {
        let me = try me()
        let status = try await usernameStatus(username)
        guard status == .available else { throw BackendError.server(status.message) }
        state.withLock { s in
            s.profiles[me]?.profile.username = UsernameRules.normalize(username)
            s.profiles[me]?.profile.displayName = String(displayName.trimmingCharacters(in: .whitespaces).prefix(60))
        }
    }

    public func uploadAvatar(jpegData: Data) async throws {
        let me = try me()
        let path = "\(me)/avatar-\(UUID()).jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        try jpegData.write(to: url)
        state.withLock { $0.profiles[me]?.profile.avatarPath = path }
    }

    public func completeOnboarding() async throws {
        let me = try me()
        try state.withLock { s in
            if let name = s.profiles[me]?.profile.username, UsernameRules.isPlaceholder(name) {
                throw BackendError.server("Choose a username first.")
            }
            s.onboarded = true
        }
    }

    // MARK: Profiles

    public func profilePage(_ id: UserID) async throws -> ProfilePage {
        let me = try me()
        return try state.withLock { s in
            guard var page = s.profiles[id] else { throw BackendError.server("This profile isn't available.") }
            page.relationship = .init(
                iFollow: s.follows.contains([me, id]) ? "accepted" : nil,
                followsMe: s.follows.contains([id, me]) ? "accepted" : nil
            )
            page.followerCount = s.follows.filter { $0[1] == id }.count
            page.followingCount = s.follows.filter { $0[0] == id }.count
            return page
        }
    }

    public func updateProfile(_ update: ProfileUpdate) async throws {
        let me = try me()
        state.withLock { s in
            guard var page = s.profiles[me] else { return }
            page.profile.displayName = update.displayName
            page.profile.username = update.username
            page.profile.bio = update.bio
            page.profile.countryCode = update.countryCode
            page.profile.regionCode = update.regionCode
            page.profile.visibility = update.audience
            page.profile.presentation = update.presentation
            s.profiles[me] = page
        }
    }

    public func follow(_ id: UserID) async throws {
        let me = try me()
        _ = state.withLock { $0.follows.insert([me, id]) }
    }

    public func unfollow(_ id: UserID) async throws {
        let me = try me()
        _ = state.withLock { $0.follows.remove([me, id]) }
    }

    public func searchProfiles(_ query: String) async throws -> [ProfileStub] {
        let q = query.lowercased()
        return state.withLock { s in
            s.profiles.values.filter { $0.profile.username.hasPrefix(q) }
                .map { ProfileStub(id: $0.profile.id, username: $0.profile.username, displayName: $0.profile.displayName) }
        }
    }

    // MARK: Privacy

    public func privacySettings() async throws -> PrivacySettings { state.withLock { $0.privacy } }
    public func updatePrivacySettings(_ settings: PrivacySettings) async throws {
        state.withLock { s in
            if s.privacy.allowRouteSharing && !settings.allowRouteSharing {
                s.sharedRoutes.removeAll()
                for i in s.drives.indices { s.drives[i].hasSharedRoute = false }
            }
            s.privacy = settings
        }
    }
    public func privacyZones() async throws -> [PrivacyZone] { state.withLock { $0.zones } }
    public func addPrivacyZone(_ zone: PrivacyZone) async throws { state.withLock { $0.zones.append(zone) } }
    public func deletePrivacyZone(_ id: UUID) async throws { state.withLock { $0.zones.removeAll { $0.id == id } } }

    // MARK: Garage

    public func vehicles(owner: UserID) async throws -> [Vehicle] {
        let me = try me()
        return state.withLock { s in
            s.vehicles.filter { $0.ownerID == owner && (owner == me || $0.visibility == .public) }
                .sorted { $0.position < $1.position }
        }
    }

    public func saveVehicle(_ vehicle: Vehicle) async throws -> Vehicle {
        let me = try me()
        guard vehicle.ownerID == me else { throw BackendError.server("new row violates row-level security policy") }
        state.withLock { s in
            if let i = s.vehicles.firstIndex(where: { $0.id == vehicle.id }) { s.vehicles[i] = vehicle } else { s.vehicles.append(vehicle) }
        }
        return vehicle
    }

    public func deleteVehicle(_ id: UUID) async throws {
        state.withLock { s in
            s.vehicles.removeAll { $0.id == id }
            for i in s.drives.indices where s.drives[i].vehicleID == id { s.drives[i].vehicleID = nil }
        }
    }

    public func modifications(vehicle: UUID) async throws -> [VehicleModification] {
        state.withLock { $0.mods.filter { $0.vehicleID == vehicle } }
    }

    public func saveModification(_ mod: VehicleModification) async throws {
        state.withLock { s in
            if let i = s.mods.firstIndex(where: { $0.id == mod.id }) { s.mods[i] = mod } else { s.mods.append(mod) }
        }
    }

    public func deleteModification(_ id: UUID) async throws { state.withLock { $0.mods.removeAll { $0.id == id } } }

    public func photos(vehicle: UUID) async throws -> [VehiclePhoto] {
        state.withLock { $0.photos.filter { $0.vehicleID == vehicle } }
    }

    public func addPhoto(vehicle: Vehicle, jpegData: Data) async throws -> VehiclePhoto {
        // Demo mode keeps the bytes in a temp file so the UI can show them.
        let path = "\(vehicle.ownerID)/\(vehicle.id)/\(UUID()).jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        try jpegData.write(to: url)
        let photo = VehiclePhoto(vehicleID: vehicle.id, storagePath: path, position: 0)
        state.withLock { s in
            s.photos.append(photo)
            if let i = s.vehicles.firstIndex(where: { $0.id == vehicle.id }), s.vehicles[i].coverPhotoPath == nil {
                s.vehicles[i].coverPhotoPath = path
            }
        }
        return photo
    }

    // MARK: Drives

    public func drives(owner: UserID, limit: Int) async throws -> [Drive] {
        state.withLock { s in Array(s.drives.filter { $0.ownerID == owner }.sorted { $0.startedAt > $1.startedAt }.prefix(limit)) }
    }

    public func upload(drive: Drive, track: [LocationSample]) async throws -> Drive {
        var stored = drive
        // Mimic the server's verdict so the UI's states can be exercised.
        stored.validationStatus = track.count >= 30 ? .validated : .rejected
        state.withLock { s in
            if !s.drives.contains(where: { $0.id == drive.id }) {
                s.drives.append(stored)
                s.tracks[drive.id] = track
            }
        }
        return stored
    }

    public func updateDrive(_ id: UUID, title: String, audience: Audience) async throws {
        state.withLock { s in
            guard let i = s.drives.firstIndex(where: { $0.id == id }) else { return }
            s.drives[i].title = title
            s.drives[i].visibility = audience
        }
    }

    public func deleteDrive(_ id: UUID) async throws {
        state.withLock { s in
            s.drives.removeAll { $0.id == id }
            s.tracks[id] = nil
            s.sharedRoutes[id] = nil
        }
    }

    public func ownTrack(drive: UUID) async throws -> [LocationSample] { state.withLock { $0.tracks[drive] ?? [] } }
    public func sharedRoute(drive: UUID) async throws -> [[Coordinate]]? { state.withLock { $0.sharedRoutes[drive] } }

    public func shareRoute(drive: UUID) async throws -> [[Coordinate]] {
        try state.withLock { s in
            guard s.privacy.allowRouteSharing else { throw BackendError.server("Route sharing is turned off in privacy settings.") }
            let track = (s.tracks[drive] ?? []).map(\.coordinate)
            let segments = RoutePrivacy.redact(track, zones: s.zones, options: .init(endpointTrim: s.privacy.routeEndpointTrimMeters + 125))
            guard !segments.isEmpty else { throw BackendError.server("This drive is too short to share without revealing where it started.") }
            s.sharedRoutes[drive] = segments
            if let i = s.drives.firstIndex(where: { $0.id == drive }) { s.drives[i].hasSharedRoute = true }
            return segments
        }
    }

    public func unshareRoute(drive: UUID) async throws {
        state.withLock { s in
            s.sharedRoutes[drive] = nil
            if let i = s.drives.firstIndex(where: { $0.id == drive }) { s.drives[i].hasSharedRoute = false }
        }
    }

    // MARK: Feed

    public func feed(_ scope: FeedScope, before: Date?) async throws -> [Post] {
        let me = try me()
        return state.withLock { s in
            s.posts
                .filter { before == nil || $0.createdAt < before! }
                .filter { scope == .discover ? $0.visibility == .public || $0.authorID == me : ($0.authorID == me || s.follows.contains([me, $0.authorID])) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(20)
                .map { post in
                    var post = post
                    post.author = stub(post.authorID, in: s)
                    post.commentCount = s.comments.filter { $0.postID == post.id }.count
                    return post
                }
        }
    }

    public func createPost(_ post: NewPost) async throws -> Post {
        let me = try me()
        let created = Post(
            authorID: me, kind: post.kind, caption: post.caption, vehicleID: post.vehicleID, meetID: post.meetID,
            driveID: post.driveID, visibility: post.audience, createdAt: .now
        )
        state.withLock { $0.posts.append(created) }
        return created
    }

    public func setLiked(_ liked: Bool, post: UUID) async throws {
        state.withLock { s in
            guard let i = s.posts.firstIndex(where: { $0.id == post }), s.posts[i].likedByMe != liked else { return }
            s.posts[i].likedByMe = liked
            s.posts[i].likeCount += liked ? 1 : -1
        }
    }

    public func comments(post: UUID) async throws -> [Comment] {
        state.withLock { s in
            s.comments.filter { $0.postID == post }.sorted { $0.createdAt < $1.createdAt }.map { c in
                var c = c
                c.author = stub(c.authorID, in: s)
                return c
            }
        }
    }

    public func addComment(_ body: String, post: UUID) async throws -> Comment {
        let me = try me()
        return state.withLock { s in
            var comment = Comment(postID: post, authorID: me, body: body)
            s.comments.append(comment)
            comment.author = stub(me, in: s)
            return comment
        }
    }

    public func deletePost(_ id: UUID) async throws { state.withLock { $0.posts.removeAll { $0.id == id } } }

    // MARK: Meets

    public func meets(from: Date) async throws -> [Meet] {
        state.withLock { s in
            s.meets.filter { $0.endsAt >= from }.sorted { $0.startsAt < $1.startsAt }.map { m in
                var m = m
                m.host = stub(m.hostID, in: s)
                return m
            }
        }
    }

    public func createMeet(_ meet: Meet) async throws -> Meet {
        let me = try me()
        var created = meet
        created.hostID = me
        state.withLock { $0.meets.append(created) }
        return created
    }

    public func cancelMeet(_ id: UUID) async throws {
        state.withLock { s in
            if let i = s.meets.firstIndex(where: { $0.id == id }) { s.meets[i].cancelledAt = .now }
        }
    }

    public func setRSVP(_ rsvp: RSVP?, meet: UUID) async throws {
        try state.withLock { s in
            guard let i = s.meets.firstIndex(where: { $0.id == meet }) else { return }
            let old = s.meets[i].myRSVP
            if s.meets[i].isCancelled { throw BackendError.server("This meet was cancelled.") }
            if rsvp?.status == .going, old?.status != .going, s.meets[i].isFull { throw BackendError.server("This meet is full.") }
            if old?.status == .going { s.meets[i].goingCount -= 1 }
            if old?.status == .interested { s.meets[i].interestedCount -= 1 }
            if rsvp?.status == .going { s.meets[i].goingCount += 1 }
            if rsvp?.status == .interested { s.meets[i].interestedCount += 1 }
            s.meets[i].myRSVP = rsvp
        }
    }

    public func attendees(meet: UUID) async throws -> [ProfileStub] {
        state.withLock { s in
            guard let m = s.meets.first(where: { $0.id == meet }), m.myRSVP?.status == .going else { return [] }
            return [DemoSeed.mayaID, DemoSeed.kenjiID].compactMap { stub($0, in: s) }
        }
    }

    // MARK: Leaderboards

    public func leaderboard(_ query: LeaderboardQuery) async throws -> [LeaderboardEntry] {
        let optedIn = state.withLock { query.metric.isPerformance ? $0.privacy.performanceLeaderboardOptIn : $0.privacy.leaderboardOptIn }
        return DemoSeed.leaderboard(query, includeMe: optedIn)
    }

    // MARK: Notifications

    public func notifications() async throws -> [AppNotification] {
        state.withLock { s in s.notifications.sorted { $0.createdAt > $1.createdAt } }
    }

    public func markNotificationsRead() async throws {
        state.withLock { s in for i in s.notifications.indices where s.notifications[i].readAt == nil { s.notifications[i].readAt = .now } }
    }

    public func registerPushToken(_ token: String, sandbox: Bool) async throws {}

    // MARK: Media

    public func mediaURL(_ bucket: MediaBucket, path: String) async -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
