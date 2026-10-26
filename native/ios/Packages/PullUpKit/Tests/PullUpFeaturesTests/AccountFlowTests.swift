import Foundation
import Synchronization
import Testing
@testable import PullUpFeatures
import PullUpData
import PullUpDomain

final class FakeAppleCredentials: AppleCredentialChecking {
    private let stored = Mutex<String?>(nil)
    let reported: AppleCredentialState

    init(storedID: String?, state: AppleCredentialState) {
        stored.withLock { $0 = storedID }
        reported = state
    }

    func storedUserID() -> String? { stored.withLock { $0 } }
    func store(userID: String?) { stored.withLock { $0 = userID } }
    func state(for userID: String) async -> AppleCredentialState { reported }
}

@MainActor
@Suite("Account flow")
struct AccountFlowTests {
    private func model(onboarding: Bool = false, apple: FakeAppleCredentials = .init(storedID: nil, state: .authorized)) -> AppModel {
        var options = LaunchOptions()
        options.demo = true
        options.onboarding = onboarding
        return AppModel(options: options, appleCredentials: apple)
    }

    @Test func newAccountGoesThroughOnboarding() async throws {
        let app = model(onboarding: true)
        await app.start()
        guard case .onboarding = app.phase else {
            Issue.record("Expected onboarding, got \(app.phase)")
            return
        }
        #expect(app.account?.hasPlaceholderUsername == true)
        await #expect(throws: BackendError.self) { try await app.backend.completeOnboarding() }

        #expect(try await app.backend.usernameStatus("maya.s15") == .taken)
        #expect(try await app.backend.usernameStatus("support") == .reserved)
        try await app.backend.claimUsername("rx7_kenji", displayName: "Kenji")
        try await app.backend.completeOnboarding()
        await app.finishOnboarding()
        guard case .signedIn = app.phase else {
            Issue.record("Expected signed in, got \(app.phase)")
            return
        }
        #expect(app.account?.username == "rx7_kenji")
        #expect(app.account?.isOnboarded == true)
    }

    @Test func onboardedAccountSkipsOnboarding() async {
        let app = model()
        await app.start()
        guard case .signedIn = app.phase else {
            Issue.record("Expected signed in, got \(app.phase)")
            return
        }
    }

    @Test func revokedAppleCredentialSignsOut() async {
        let apple = FakeAppleCredentials(storedID: "001234.abcd", state: .revoked)
        let app = model(apple: apple)
        await app.start()
        #expect(app.phase == .signedOut)
        #expect(app.signedOutNotice?.contains("Sign in with Apple") == true)
        #expect(apple.storedUserID() == nil)
    }

    @Test func authorizedAppleCredentialStaysSignedIn() async {
        let app = model(apple: FakeAppleCredentials(storedID: "001234.abcd", state: .authorized))
        await app.start()
        #expect(app.userID != nil)
        #expect(app.signedOutNotice == nil)
    }

    @Test func unknownStateDoesNotSignOut() async {
        // Offline or no Apple Account on the simulator: never lock people out on a guess.
        let app = model(apple: FakeAppleCredentials(storedID: "001234.abcd", state: .unknown))
        await app.start()
        #expect(app.userID != nil)
    }

    @Test func deletionExplainsWhatHappened() async throws {
        let app = model()
        await app.start()
        try await app.deleteAccount(appleAuthorizationCode: nil)
        #expect(app.phase == .signedOut)
        #expect(app.signedOutNotice?.contains("deleted") == true)
    }

    @Test func deletionDuringADriveStopsItAndRemovesExports() async throws {
        let app = model()
        await app.start()
        let export = DriveProSection.exportsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        #expect(await app.recorder.start(with: nil) == nil)
        try await app.deleteAccount(appleAuthorizationCode: nil)
        #expect(!app.recorder.isRecording)
        #expect(app.phase == .signedOut)
        #expect(!FileManager.default.fileExists(atPath: DriveProSection.exportsFolder.path))
    }

    @Test func deletionClearsCachedMedia() async throws {
        let app = model()
        await app.start()
        let url = URL(string: "https://example.supabase.co/storage/v1/object/sign/avatars/me.jpg?token=t")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "max-age=31536000"])!
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: Data([0xff, 0xd8])), for: URLRequest(url: url))
        // Let the store land first, so it can't arrive after the clearing.
        for _ in 0..<30 where URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await app.deleteAccount(appleAuthorizationCode: nil)
        // URLCache works on its own queue: allow it a moment, no more.
        var cached = URLCache.shared.cachedResponse(for: URLRequest(url: url))
        for _ in 0..<30 where cached != nil {
            try await Task.sleep(for: .milliseconds(100))
            cached = URLCache.shared.cachedResponse(for: URLRequest(url: url))
        }
        #expect(cached == nil)
    }

    @Test func authMessagesAreReadable() {
        struct Server: LocalizedError { let errorDescription: String? }
        #expect(AuthMessages.server(Server(errorDescription: "automatic account linking is disabled: sign in with your existing method")).contains("signs in another way"))
        #expect(AuthMessages.server(Server(errorDescription: "Provider is not enabled")).contains("isn't switched on"))
    }
}
