import AuthenticationServices
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
        /// Signed in, but the account still has the placeholder username.
        case onboarding(UserID)
        case signedIn(UserID)
    }

    public private(set) var backend: any BackendService
    public private(set) var phase: Phase = .launching
    public private(set) var garage: GarageStore
    public private(set) var recorder: DriveRecorder
    public let themeStore: ThemeStore
    /// Pull Up Pro: the server's entitlement and the App Store.
    public let pro: ProStore
    public let options: LaunchOptions
    public var selectedTab: MainTab = .drive
    public private(set) var unreadNotifications = 0
    /// Badge counts for the Messages button.
    public private(set) var unreadMessages = UnreadMessages()
    /// Bumped on every realtime change in the person's conversations, so open
    /// message screens can refresh without each holding a connection.
    private(set) var messagingPulse = MessagingPulse()
    /// The signed-in person's own account (username, sign-in methods).
    public private(set) var account: AccountState?
    /// People this account has blocked since it signed in on this phone.
    /// Screens that already loaded their posts, comments, meets or
    /// conversations drop them at once instead of waiting for a refetch. The
    /// server enforces the block itself (RLS, `is_blocked_between`).
    public private(set) var blockedUsers: Set<UserID> = []
    /// Shown once on the sign-in screen after the app signed someone out on
    /// its own (Apple credential revoked, account deleted).
    public var signedOutNotice: String?
    /// A tapped push waiting for its screen to open it.
    var pendingPush: PushRoute?
    /// This phone's APNs token, once iOS has issued one.
    @ObservationIgnored private var pushToken: PushToken?
    @ObservationIgnored private var openedLaunchPush = false
    /// Name Apple shared on first sign-in, offered as the display name.
    var appleSuggestedName: String?
    let appleCredentials: any AppleCredentialChecking

    /// The CarPlay scene and the phone UI must drive the same recorder.
    public private(set) static var shared: AppModel?

    public var userID: UserID? {
        switch phase {
        case let .signedIn(id), let .onboarding(id): id
        default: nil
        }
    }

    public var isDemo: Bool { backend.mode == .demo }

    private var authTask: Task<Void, Never>?
    private var messagingTask: Task<Void, Never>?

    /// `store` is the live App Store client from the app target. Demo mode
    /// always uses the demo store instead, so it can never take money.
    public convenience init(options: LaunchOptions = .fromProcess(), store: (any StoreClient)? = nil) {
        self.init(options: options, appleCredentials: SystemAppleCredentials(), store: store)
    }

    init(options: LaunchOptions, appleCredentials: any AppleCredentialChecking, store: (any StoreClient)? = nil) {
        self.options = options
        self.appleCredentials = appleCredentials
        let defaults = UserDefaults.standard
        if options.resetDefaults, let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
        }
        themeStore = ThemeStore(defaults: defaults, override: options.appearance)
        let backend = Self.makeBackend(options)
        self.backend = backend
        garage = GarageStore(backend: backend)
        recorder = Self.makeRecorder(backend: backend, defaults: defaults)
        let storeClient: any StoreClient = if backend.mode == .demo { DemoStoreClient() } else { store ?? UnavailableStoreClient() }
        pro = ProStore(store: storeClient, backend: backend, theme: themeStore)
        if let tab = options.initialTab { selectedTab = tab }
        Self.shared = self
    }

    private static func makeBackend(_ options: LaunchOptions) -> any BackendService {
        if options.demo {
            return DemoBackend(signedIn: !options.signedOut, emptyGarage: options.emptyGarage, onboarded: !options.onboarding)
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
        await verifyAppleCredential()
        if revocationObserver == nil {
            revocationObserver = NotificationCenter.default.addObserver(
                forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.verifyAppleCredential() }
            }
        }
    }

    private var revocationObserver: (any NSObjectProtocol)?

    /// Switches a build without server configuration into labelled demo mode.
    public func enterDemo() async {
        let backend = DemoBackend()
        self.backend = backend
        pro.configure(store: DemoStoreClient(), backend: backend)
        garage = GarageStore(backend: backend)
        recorder = Self.makeRecorder(backend: backend, defaults: .standard)
        phase = .launching
        await start()
    }

    private func apply(_ user: UserID?) async {
        if let user {
            if userID == user { return }
            // A failed lookup (offline) lets the person in rather than locking
            // them out; onboarding is shown whenever the server says it's due.
            account = try? await backend.account()
            if let account, !account.isOnboarded {
                phase = .onboarding(user)
                return
            }
            await enterApp(user)
        } else {
            guard !recorder.isRecording else { return }
            phase = .signedOut
            account = nil
            blockedUsers = []
            messagingTask?.cancel()
            messagingTask = nil
            unreadMessages = UnreadMessages()
            pro.stop()
            recorder.ownerID = nil
            await garage.setOwner(nil)
        }
    }

    private func enterApp(_ user: UserID) async {
        blockedUsers = []
        phase = .signedIn(user)
        recorder.ownerID = user
        await garage.setOwner(user)
        await recorder.recoverInterrupted(vehicles: garage.vehicles)
        await recorder.syncPending()
        await refreshNotifications()
        await refreshMessages()
        startMessagingUpdates()
        await registerPushTokenIfPossible()
        if let push = options.openPush, !openedLaunchPush {
            openedLaunchPush = true
            let parts = push.split(separator: ":", maxSplits: 1).map(String.init)
            openPush(kind: parts.first, conversationID: parts.count > 1 ? parts[1] : nil)
        }
        await pro.start(account: user)
    }

    // MARK: Push

    /// Called by the app delegate whenever iOS issues the APNs token. It's
    /// registered for the signed-in account now, or at the next sign-in.
    public func didReceivePushToken(_ token: String, sandbox: Bool) async {
        pushToken = PushToken(token: token, sandbox: sandbox)
        await registerPushTokenIfPossible()
    }

    private func registerPushTokenIfPossible() async {
        guard let pushToken, case .signedIn = phase else { return }
        try? await backend.registerPushToken(pushToken.token, sandbox: pushToken.sandbox)
    }

    /// Opens what a tapped push is about: the conversation for messages,
    /// the activity list for everything else.
    public func openPush(kind: String?, conversationID: String?) {
        guard let route = PushRoute(kind: kind, conversationID: conversationID) else { return }
        switch route {
        case .conversation: selectedTab = .feed
        case .activity: selectedTab = .drive
        }
        pendingPush = route
    }

    private func startMessagingUpdates() {
        messagingTask?.cancel()
        let changes = backend.messagingChanges()
        messagingTask = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                self.messagingPulse = MessagingPulse(count: self.messagingPulse.count + 1, conversationID: change.conversationID)
                await self.refreshMessages()
            }
        }
    }

    public func refreshMessages() async {
        if let counts = try? await backend.unreadMessages() { unreadMessages = counts }
    }

    /// Back in the foreground: anything that arrived while the app was
    /// suspended or offline wasn't heard over realtime, so open screens
    /// reload and the unread counts are fetched again.
    func catchUpMessages() async {
        guard case .signedIn = phase else { return }
        messagingPulse = MessagingPulse(count: messagingPulse.count + 1, conversationID: nil)
        await refreshMessages()
    }

    /// Back in the foreground: drives that couldn't upload earlier (no
    /// signal, or the app closed mid-upload) are sent again.
    func foregrounded() async {
        guard case .signedIn = phase else { return }
        await recorder.syncPending()
        // Picks up a suspension placed (or lifted) while the app was away.
        await refreshAccount()
    }

    // MARK: Blocking

    /// Blocks on the server, then hides the person everywhere in the app.
    public func block(_ user: UserID) async throws {
        try await backend.block(user)
        noteBlocked(user)
    }

    /// Records a block made through a conversation's own model.
    public func noteBlocked(_ user: UserID) {
        blockedUsers.insert(user)
    }

    /// Called by onboarding once the server has marked it complete.
    func finishOnboarding() async {
        guard case let .onboarding(user) = phase else { return }
        account = try? await backend.account()
        appleSuggestedName = nil
        await enterApp(user)
    }

    public func refreshAccount() async {
        if let fresh = try? await backend.account() { account = fresh }
    }

    // MARK: Sign in with Apple

    /// Records the Apple user behind a successful sign-in, for revocation checks.
    func didSignInWithApple(userIdentifier: String, suggestedName: String?) {
        appleCredentials.store(userID: userIdentifier)
        if let suggestedName, !suggestedName.isEmpty { appleSuggestedName = suggestedName }
    }

    /// Signs out locally when the person has stopped using Sign in with Apple
    /// for Pull Up. Runs at launch, on return to the foreground, and when
    /// Apple posts a revocation notice.
    public func verifyAppleCredential() async {
        guard userID != nil, let appleUser = appleCredentials.storedUserID() else { return }
        guard await appleCredentials.state(for: appleUser) == .revoked else { return }
        appleCredentials.store(userID: nil)
        try? await backend.signOut()
        await apply(nil)
        if phase == .signedOut {
            signedOutNotice = "Sign in with Apple was turned off for Pull Up in your Apple Account settings, so you've been signed out. Sign in again to keep using your account."
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
        // While still signed in, so the server lets this account drop the
        // phone: a shared phone stops getting this account's pushes.
        if let pushToken { try? await backend.unregisterPushToken(pushToken.token) }
        try? await backend.signOut()
        appleCredentials.store(userID: nil)
        DriveProSection.removeExports()
        await apply(nil)
    }

    /// Deletes the account on the server. `appleAuthorizationCode` comes from
    /// a fresh Sign in with Apple prompt so the server can revoke Apple's
    /// tokens; without it the account is still deleted.
    public func deleteAccount(appleAuthorizationCode: String?) async throws {
        let owner = userID
        let result = try await backend.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
        // The server copy is gone; nothing of the account should stay here
        // either. Before apply(nil), which keeps a drive that's recording.
        if let owner { await recorder.eraseLocalData(for: owner) }
        DriveProSection.removeExports()
        appleCredentials.store(userID: nil)
        await apply(nil)
        switch result.apple {
        case .notApplicable, .revoked:
            signedOutNotice = "Your account and everything in it have been deleted."
        case .notRevoked:
            signedOutNotice = "Your account and everything in it have been deleted. To also remove Pull Up from your Apple Account, open Settings ▸ your name ▸ Sign in with Apple ▸ Pull Up ▸ Stop Using."
        }
    }
}

private struct PushToken: Sendable {
    let token: String
    let sandbox: Bool
}

/// A realtime nudge as seen by screens: `count` changes on every event.
struct MessagingPulse: Equatable {
    var count = 0
    var conversationID: UUID?
}

/// Backend used when the build has no Supabase keys. Every call fails with a
/// clear message; the UI shows the setup screen instead of fake content.
final class UnconfiguredBackend: BackendService, Sendable {
    var mode: BackendMode { .unconfigured }

    func currentUserID() async -> UserID? { nil }
    func authChanges() -> AsyncStream<UserID?> { AsyncStream { $0.finish() } }
    func signIn(email: String, password: String) async throws { throw BackendError.notConfigured }
    func signInWithApple(idToken: String, nonce: String) async throws { throw BackendError.notConfigured }
    func signOut() async throws {}
    func deleteAccount(appleAuthorizationCode: String?) async throws -> AccountDeletion { throw BackendError.notConfigured }
    func account() async throws -> AccountState { throw BackendError.notConfigured }
    func usernameStatus(_ username: String) async throws -> UsernameStatus { throw BackendError.notConfigured }
    func claimUsername(_ username: String, displayName: String) async throws { throw BackendError.notConfigured }
    func uploadAvatar(jpegData: Data) async throws { throw BackendError.notConfigured }
    func completeOnboarding() async throws { throw BackendError.notConfigured }
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
    func startConversation(with user: UserID) async throws -> UUID { throw BackendError.notConfigured }
    func inbox(_ state: ConversationState, before: Date?) async throws -> [InboxEntry] { throw BackendError.notConfigured }
    func messages(conversation: UUID, before: Date?, limit: Int) async throws -> [DirectMessage] { throw BackendError.notConfigured }
    func send(_ message: OutgoingMessage) async throws -> DirectMessage { throw BackendError.notConfigured }
    func setReaction(_ emoji: String?, message: UUID) async throws { throw BackendError.notConfigured }
    func unsend(message: UUID) async throws { throw BackendError.notConfigured }
    func markRead(conversation: UUID) async throws { throw BackendError.notConfigured }
    func respondToRequest(conversation: UUID, accept: Bool) async throws { throw BackendError.notConfigured }
    func setMuted(_ muted: Bool, conversation: UUID) async throws { throw BackendError.notConfigured }
    func hideConversation(_ id: UUID, clearHistory: Bool) async throws { throw BackendError.notConfigured }
    func peerReadAt(conversation: UUID) async throws -> Date? { throw BackendError.notConfigured }
    func unreadMessages() async throws -> UnreadMessages { throw BackendError.notConfigured }
    func sharedPreview(_ ref: SharedRef) async throws -> SharedPreview { throw BackendError.notConfigured }
    func report(user: UserID, reason: ReportReason, details: String, message: UUID?) async throws { throw BackendError.notConfigured }
    func report(_ content: ReportedContent, author: UserID, reason: ReportReason, note: String) async throws { throw BackendError.notConfigured }
    func block(_ user: UserID) async throws { throw BackendError.notConfigured }
    func messagingChanges() -> AsyncStream<MessagingChange> { AsyncStream { $0.finish() } }
    func entitlement() async throws -> Entitlement { throw BackendError.notConfigured }
    func verifySubscription(signedTransaction: String) async throws -> Entitlement { throw SubscriptionError.notConfigured }
    func notifications() async throws -> [AppNotification] { throw BackendError.notConfigured }
    func markNotificationsRead() async throws { throw BackendError.notConfigured }
    func registerPushToken(_ token: String, sandbox: Bool) async throws {}
    func unregisterPushToken(_ token: String) async throws {}
    func notificationPreferences() async throws -> NotificationPreferences { throw BackendError.notConfigured }
    func updateNotificationPreferences(_ preferences: NotificationPreferences) async throws { throw BackendError.notConfigured }
    func mediaURL(_ bucket: MediaBucket, path: String) async -> URL? { nil }
}
