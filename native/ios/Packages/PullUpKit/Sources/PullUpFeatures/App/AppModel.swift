import Foundation
import Observation
import PullUpData
import PullUpDesign
import PullUpDomain
import PullUpLocation

/// Root state shared by every screen: which backend is in use, who is signed
/// in, and the long-lived stores (theme, garage, drive recorder).
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable {
        case launching
        /// The build has no server configuration.
        case setupRequired
        case signedOut
        case signedIn(UserID)
    }

    public private(set) var backend: any BackendService
    public private(set) var phase: Phase = .launching
    public private(set) var garage: GarageStore
    public private(set) var recorder: DriveRecorder
    public let themeStore: ThemeStore
    public let options: LaunchOptions
    public var selectedTab: MainTab = .drive
    public private(set) var unreadNotifications = 0

    /// The CarPlay scene and the phone UI must drive the same recorder.
    public private(set) static var shared: AppModel?

    public var userID: UserID? {
        if case let .signedIn(id) = phase { return id }
        return nil
    }

    public var isDemo: Bool { backend.mode == .demo }

    private var authTask: Task<Void, Never>?

    public init(options: LaunchOptions = .fromProcess()) {
        self.options = options
        let defaults = UserDefaults.standard
        if options.resetDefaults, let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
        }
        themeStore = ThemeStore(defaults: defaults, override: options.appearance)
        let backend = Self.makeBackend(options)
        self.backend = backend
        garage = GarageStore(backend: backend)
        recorder = Self.makeRecorder(backend: backend, defaults: defaults)
        if let tab = options.initialTab { selectedTab = tab }
        Self.shared = self
    }

    private static func makeBackend(_ options: LaunchOptions) -> any BackendService {
        if options.demo {
            return DemoBackend(signedIn: !options.signedOut, emptyGarage: options.emptyGarage)
        }
        if let configuration = BackendConfiguration.fromBundle() {
            return SupabaseBackend(configuration: configuration)
        }
        return UnconfiguredBackend()
    }

    private static func makeRecorder(backend: any BackendService, defaults: UserDefaults) -> DriveRecorder {
        let replay = backend.mode == .demo
        let store: LocalDriveStore = replay
            ? LocalDriveStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DemoDrives-\(UUID().uuidString)"))
            : .standard()
        return DriveRecorder(backend: backend, store: store, defaults: defaults, usesReplay: replay) {
            #if os(iOS)
            if replay {
                return ReplayLocationProvider(samples: DemoTracks.liveReplay(start: .now))
            }
            return CoreLocationProvider()
            #else
            return ReplayLocationProvider(samples: DemoTracks.liveReplay(start: .now))
            #endif
        }
    }

    /// Called once from the root view.
    public func start() async {
        guard phase == .launching else { return }
        if backend.mode == .unconfigured {
            phase = .setupRequired
            return
        }
        await apply(await backend.currentUserID())
        authTask = Task { [weak self] in
            guard let stream = self?.backend.authChanges() else { return }
            for await user in stream {
                guard let self else { return }
                await self.apply(user)
            }
        }
    }

    /// Switches a build without server configuration into labelled demo mode.
    public func enterDemo() async {
        let backend = DemoBackend()
        self.backend = backend
        garage = GarageStore(backend: backend)
        recorder = Self.makeRecorder(backend: backend, defaults: .standard)
        phase = .launching
        await start()
    }

    private func apply(_ user: UserID?) async {
        if let user {
            if case let .signedIn(current) = phase, current == user { return }
            phase = .signedIn(user)
            recorder.ownerID = user
            await garage.setOwner(user)
            await recorder.recoverInterrupted()
            await recorder.syncPending()
            await refreshNotifications()
        } else {
            guard !recorder.isRecording else { return }
            phase = .signedOut
            recorder.ownerID = nil
            await garage.setOwner(nil)
        }
    }

    public func refreshNotifications() async {
        unreadNotifications = ((try? await backend.notifications()) ?? []).filter { $0.readAt == nil }.count
    }

    public func signOut() async {
        try? await backend.signOut()
        await apply(nil)
    }

    public func deleteAccount() async throws {
        try await backend.deleteAccount()
        await apply(nil)
    }
}

/// Backend used when the build has no Supabase keys. Every call fails with a
/// clear message; the UI shows the setup screen instead of fake content.
final class UnconfiguredBackend: BackendService, Sendable {
    var mode: BackendMode { .unconfigured }
    private func fail<T>() throws -> T { throw BackendError.notConfigured }

    func currentUserID() async -> UserID? { nil }
    func authChanges() -> AsyncStream<UserID?> { AsyncStream { $0.finish() } }
    func signIn(email: String, password: String) async throws { try fail() }
    func signUp(email: String, password: String, username: String) async throws -> SignUpOutcome { try fail() }
    func signInWithApple(idToken: String, nonce: String) async throws { try fail() }
    func signOut() async throws {}
    func deleteAccount() async throws { try fail() }
    func profilePage(_ id: UserID) async throws -> ProfilePage { try fail() }
    func updateProfile(_ update: ProfileUpdate) async throws { try fail() }
    func follow(_ id: UserID) async throws { try fail() }
    func unfollow(_ id: UserID) async throws { try fail() }
    func searchProfiles(_ query: String) async throws -> [ProfileStub] { try fail() }
    func privacySettings() async throws -> PrivacySettings { try fail() }
    func updatePrivacySettings(_ settings: PrivacySettings) async throws { try fail() }
    func privacyZones() async throws -> [PrivacyZone] { try fail() }
    func addPrivacyZone(_ zone: PrivacyZone) async throws { try fail() }
    func deletePrivacyZone(_ id: UUID) async throws { try fail() }
    func vehicles(owner: UserID) async throws -> [Vehicle] { try fail() }
    func saveVehicle(_ vehicle: Vehicle) async throws -> Vehicle { try fail() }
    func deleteVehicle(_ id: UUID) async throws { try fail() }
    func modifications(vehicle: UUID) async throws -> [VehicleModification] { try fail() }
    func saveModification(_ mod: VehicleModification) async throws { try fail() }
    func deleteModification(_ id: UUID) async throws { try fail() }
    func photos(vehicle: UUID) async throws -> [VehiclePhoto] { try fail() }
    func addPhoto(vehicle: Vehicle, jpegData: Data) async throws -> VehiclePhoto { try fail() }
    func drives(owner: UserID, limit: Int) async throws -> [Drive] { try fail() }
    func upload(drive: Drive, track: [LocationSample]) async throws -> Drive { try fail() }
    func updateDrive(_ id: UUID, title: String, audience: Audience) async throws { try fail() }
    func deleteDrive(_ id: UUID) async throws { try fail() }
    func ownTrack(drive: UUID) async throws -> [LocationSample] { try fail() }
    func sharedRoute(drive: UUID) async throws -> [[Coordinate]]? { try fail() }
    func shareRoute(drive: UUID) async throws -> [[Coordinate]] { try fail() }
    func unshareRoute(drive: UUID) async throws { try fail() }
    func feed(_ scope: FeedScope, before: Date?) async throws -> [Post] { try fail() }
    func createPost(_ post: NewPost) async throws -> Post { try fail() }
    func setLiked(_ liked: Bool, post: UUID) async throws { try fail() }
    func comments(post: UUID) async throws -> [Comment] { try fail() }
    func addComment(_ body: String, post: UUID) async throws -> Comment { try fail() }
    func deletePost(_ id: UUID) async throws { try fail() }
    func meets(from: Date) async throws -> [Meet] { try fail() }
    func createMeet(_ meet: Meet) async throws -> Meet { try fail() }
    func cancelMeet(_ id: UUID) async throws { try fail() }
    func setRSVP(_ rsvp: RSVP?, meet: UUID) async throws { try fail() }
    func attendees(meet: UUID) async throws -> [ProfileStub] { try fail() }
    func leaderboard(_ query: LeaderboardQuery) async throws -> [LeaderboardEntry] { try fail() }
    func notifications() async throws -> [AppNotification] { try fail() }
    func markNotificationsRead() async throws { try fail() }
    func registerPushToken(_ token: String, sandbox: Bool) async throws {}
    func mediaURL(_ bucket: MediaBucket, path: String) async -> URL? { nil }
}
