import Foundation
import Testing
@testable import PullUpData
import PullUpDomain
import Security

@Suite("Track encoding")
struct TrackEncodingTests {
    @Test func roundTripsWithinWirePrecision() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = DemoTracks.track(start: start, speeds: [0, 5, 10, 15, 20], headingSeed: 0)
        let decoded = TrackEncoding.decode(TrackEncoding.encode(samples, start: start), start: start)
        #expect(decoded.count == samples.count)
        for (a, b) in zip(samples, decoded) {
            #expect(abs(a.timestamp.timeIntervalSince(b.timestamp)) < 0.01)
            #expect(a.latitude == b.latitude)
            #expect(abs(a.speed - b.speed) < 0.01)
            #expect(abs(a.horizontalAccuracy - b.horizontalAccuracy) < 0.06)
        }
    }

    @Test func malformedRowsAreSkipped() {
        let decoded = TrackEncoding.decode([[1, 2], [0, 38.5, -121.4, 10, 3, 5, 4, 0.5]], start: .now)
        #expect(decoded.count == 1)
    }
}

@Suite("Local drive store")
struct LocalDriveStoreTests {
    func makeStore() -> LocalDriveStore {
        LocalDriveStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("drives-\(UUID())"))
    }

    @Test func savesAndRecoversInterruptedDrive() async throws {
        let store = makeStore()
        let draft = DriveDraft(ownerID: UUID(), vehicleID: UUID(), startedAt: .now)
        try await store.save(draft)
        #expect(await store.interrupted()?.id == draft.id)
        #expect(await store.pendingUploads().isEmpty)
    }

    @Test func finishedDrivesQueueForUploadUntilDeleted() async throws {
        let store = makeStore()
        var draft = DriveDraft(ownerID: UUID(), vehicleID: nil, startedAt: .now)
        draft.endedAt = .now.addingTimeInterval(60)
        try await store.save(draft)
        #expect(await store.pendingUploads().map(\.id) == [draft.id])
        await store.delete(draft.id)
        #expect(await store.pendingUploads().isEmpty)
    }

    @Test func guestDrivePreservesNilVehicle() async throws {
        let store = makeStore()
        let draft = DriveDraft(ownerID: UUID(), vehicleID: nil, startedAt: .now)
        try await store.save(draft)
        let loaded = await store.load(draft.id)
        #expect(loaded != nil)
        #expect(loaded?.vehicleID == nil)
    }
}

@Suite("Demo backend")
struct DemoBackendTests {
    @Test func routeSharingRequiresOptIn() async throws {
        let backend = DemoBackend()
        let me = try #require(await backend.currentUserID())
        let drive = try #require(try await backend.drives(owner: me, limit: 1).first)
        await #expect(throws: BackendError.self) { try await backend.shareRoute(drive: drive.id) }

        var settings = try await backend.privacySettings()
        settings.allowRouteSharing = true
        try await backend.updatePrivacySettings(settings)
        let segments = try await backend.shareRoute(drive: drive.id)
        #expect(!segments.isEmpty)

        settings.allowRouteSharing = false
        try await backend.updatePrivacySettings(settings)
        #expect(try await backend.sharedRoute(drive: drive.id) == nil)
    }

    @Test func rsvpUpdatesCounts() async throws {
        let backend = DemoBackend()
        let meet = try #require(try await backend.meets(from: .distantPast).first)
        try await backend.setRSVP(RSVP(status: .going), meet: meet.id)
        let after = try #require(try await backend.meets(from: .distantPast).first { $0.id == meet.id })
        #expect(after.goingCount == meet.goingCount + 1)
        try await backend.setRSVP(nil, meet: meet.id)
        let cancelled = try #require(try await backend.meets(from: .distantPast).first { $0.id == meet.id })
        #expect(cancelled.goingCount == meet.goingCount)
    }

    @Test func emptyGarageIsEmpty() async throws {
        let backend = DemoBackend(emptyGarage: true)
        let me = try #require(await backend.currentUserID())
        #expect(try await backend.vehicles(owner: me).isEmpty)
    }

    @Test func leaderboardsAreOptIn() async throws {
        let backend = DemoBackend()
        let query = LeaderboardQuery(metric: .distance, scope: .global, period: .allTime, vehicleKind: nil)
        #expect(try await backend.leaderboard(query).contains { $0.isMe } == false)
        var settings = try await backend.privacySettings()
        settings.leaderboardOptIn = true
        try await backend.updatePrivacySettings(settings)
        #expect(try await backend.leaderboard(query).contains { $0.isMe })
    }

    @Test func demoDrivesComeFromTheTelemetryEngine() async throws {
        let backend = DemoBackend()
        let me = try #require(await backend.currentUserID())
        let drives = try await backend.drives(owner: me, limit: 10)
        #expect(drives.count == 3)
        for drive in drives {
            #expect(drive.distanceMeters > 1_000)
            #expect(drive.topSpeed != nil)
        }
    }
}

/// Security re-check G10 (docs/SECURITY_REPORT.md).
@Suite("Session keychain")
struct SessionKeychainTests {
    @Test func sessionNeverLeavesThePhone() {
        let item = SessionKeychain.item(key: "session", value: Data("token".utf8))
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(item[kSecAttrService as String] as? String == SessionKeychain.service)
        #expect(item[kSecAttrSynchronizable as String] == nil)
    }
}
