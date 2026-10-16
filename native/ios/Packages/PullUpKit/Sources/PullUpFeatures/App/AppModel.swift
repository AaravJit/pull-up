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

    /// Handles pullup:// links. Only the email-confirmation callback exists today.
    public func open(_ url: URL) async {
        guard url.scheme == "pullup", url.host() == "auth-callback" else { return }
        try? await backend.handleAuthCallback(url)
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

    func currentUserID() async -> UserID? { nil }
    func authChanges() -> AsyncStream<UserID?> { AsyncStream { $0.finish() } }
    func signIn(email: String, password: String) async throws { throw BackendError.notConfigured }
    func signUp(email: String, password: String, username: String) async throws -> SignUpOutcome { throw BackendError.notConfigured }
    func signInWithApple(idToken: String, nonce: String) async throws { throw BackendError.notConfigured }
    func signOut() async throws {}
    func deleteAccount() async throws { throw BackendError.notConfigured }
    func profilePage(_ id: UserID) async throws -> ProfilePage { throw BackendError.notConfigured }
    func updateProfile(_ update: ProfileUpdate) async throws { throw BackendError.notConfigured }
    func follow(_ id: UserID) async throws { throw BackendError.notConfigured }
    func unfollow(_ id: UserID) async throws { throw BackendError.notConfigured }
    func searchProfiles(_ query: String) async throws -> [ProfileStub] { throw BackendError.notConfigured }
    func privacySettings() async throws -> PrivacySettings { throw BackendError.notConfigured }
    func updatePrivacySettings(_ settings: PrivacySettings) async throws { throw BackendError.notConfigured }
    func privacyZones() async throws -> [PrivacyZone] { throw BackendError.notConfigured }
    func addPrivacyZone(_ zone: PrivacyZone) async throws { throw BackendError.notConfigured }
    func deletePrivacyZone(_ id: UUID) async throws { throw BackendError.notConfigured }
    func vehicles(owner: UserID) async throws -> [Vehicle] { throw BackendError.notConfigured }
    func saveVehicle(_ vehicle: Vehicle) async throws -> Vehicle { throw BackendError.notConfigured }
    func deleteVehicle(_ id: UUID) async throws { throw BackendError.notConfigured }
    func modifications(vehicle: UUID) async throws -> [VehicleModification] { throw BackendError.notConfigured }
    func saveModification(_ mod: VehicleModification) async throws { throw BackendError.notConfigured }
    func deleteModification(_ id: UUID) async throws { throw BackendError.notConfigured }
    func photos(vehicle: UUID) async throws -> [VehiclePhoto] { throw BackendError.notConfigured }
    func addPhoto(vehicle: Vehicle, jpegData: Data) async throws -> VehiclePhoto { throw BackendError.notConfigured }
    func drives(owner: UserID, limit: Int) async throws -> [Drive] { throw BackendError.notConfigured }
    func upload(drive: Drive, track: [LocationSample]) async throws -> Drive { throw BackendError.notConfigured }
    func updateDrive(_ id: UUID, title: String, audience: Audience) async throws { throw BackendError.notConfigured }
    func deleteDrive(_ id: UUID) async throws { throw BackendError.notConfigured }
    func ownTrack(drive: UUID) async throws -> [LocationSample] { throw BackendError.notConfigured }
    func sharedRoute(drive: UUID) async throws -> [[Coordinate]]? { throw BackendError.notConfigured }
    func shareRoute(drive: UUID) async throws -> [[Coordinate]] { throw BackendError.notConfigured }
    func unshareRoute(drive: UUID) async throws { throw BackendError.notConfigured }
    func feed(_ scope: FeedScope, before: Date?) async throws -> [Post] { throw BackendError.notConfigured }
    func createPost(_ post: NewPost) async throws -> Post { throw BackendError.notConfigured }
    func setLiked(_ liked: Bool, post: UUID) async throws { throw BackendError.notConfigured }
    func comments(post: UUID) async throws -> [Comment] { throw BackendError.notConfigured }
    func addComment(_ body: String, post: UUID) async throws -> Comment { throw BackendError.notConfigured }
    func deletePost(_ id: UUID) async throws { throw BackendError.notConfigured }
    func meets(from: Date) async throws -> [Meet] { throw BackendError.notConfigured }
    func createMeet(_ meet: Meet) async throws -> Meet { throw BackendError.notConfigured }
    func cancelMeet(_ id: UUID) async throws { throw BackendError.notConfigured }
    func setRSVP(_ rsvp: RSVP?, meet: UUID) async throws { throw BackendError.notConfigured }
    func attendees(meet: UUID) async throws -> [ProfileStub] { throw BackendError.notConfigured }
    func leaderboard(_ query: LeaderboardQuery) async throws -> [LeaderboardEntry] { throw BackendError.notConfigured }
    func notifications() async throws -> [AppNotification] { throw BackendError.notConfigured }
    func markNotificationsRead() async throws { throw BackendError.notConfigured }
    func registerPushToken(_ token: String, sandbox: Bool) async throws {}
    func mediaURL(_ bucket: MediaBucket, path: String) async -> URL? { nil }
}
