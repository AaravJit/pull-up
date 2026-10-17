import Foundation
import Testing
@testable import PullUpFeatures
import PullUpData
import PullUpDomain
import PullUpLocation

/// Delivers a whole track at once so tests don't wait in real time.
@MainActor
final class InstantProvider: LocationProvider {
    var permission: LocationPermission
    var grantOnRequest: LocationPermission
    private(set) var startCount = 0
    private(set) var stopCount = 0
    let speeds: [Double]

    init(permission: LocationPermission = .authorized, grantOnRequest: LocationPermission = .authorized, speeds: [Double]) {
        self.permission = permission
        self.grantOnRequest = grantOnRequest
        self.speeds = speeds
    }

    func requestPermission() async -> LocationPermission {
        permission = grantOnRequest
        return permission
    }

    func start() -> AsyncStream<LocationEvent> {
        startCount += 1
        let samples = DemoTracks.track(start: Date(), speeds: speeds, headingSeed: 0.2)
        return AsyncStream { continuation in
            for sample in samples { continuation.yield(.sample(sample)) }
            continuation.finish()
        }
    }

    func stop() { stopCount += 1 }
}

@MainActor
final class Counter {
    var value = 0
}

@MainActor
struct RecorderHarness {
    let backend: DemoBackend
    let defaults: UserDefaults
    let recorder: DriveRecorder
    let provider: InstantProvider
    let requests = Counter()
    func providerRequests() -> Int { requests.value }

    static let drive: [Double] = Array(repeating: 0, count: 4) + (1...8).map { Double($0) * 3.5 } + Array(repeating: 28, count: 40)
    static let short: [Double] = [0, 1, 2, 3, 2, 1, 0]

    init(backend: DemoBackend = DemoBackend(), provider: InstantProvider = InstantProvider(speeds: drive)) async {
        self.backend = backend
        self.provider = provider
        let suite = "recorder-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        let store = LocalDriveStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let counter = requests
        recorder = DriveRecorder(backend: backend, store: store, defaults: defaults) {
            counter.value += 1
            return provider
        }
        recorder.ownerID = await backend.currentUserID()
    }

    /// Waits until the recorder has consumed the provider's track.
    func drain(expecting count: Int) async throws {
        for _ in 0..<200 where recorder.acceptedCount + recorder.rejectedCount < count {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
@Suite("Drive recorder")
struct DriveRecorderTests {
    @Test func doesNothingUntilAVehicleIsConfirmed() async throws {
        let h = await RecorderHarness()
        // Building the recorder and asking for the preferred vehicle (what the
        // picker does when it opens) must not touch location.
        let me = try #require(await h.backend.currentUserID())
        _ = h.recorder.preferredChoice(among: try await h.backend.vehicles(owner: me))
        #expect(h.providerRequests() == 0)
        #expect(h.provider.startCount == 0)
        #expect(h.recorder.phase == .idle)
    }

    @Test func driveIsLoggedToTheChosenVehicle() async throws {
        let h = await RecorderHarness()
        let me = try #require(await h.backend.currentUserID())
        let vehicle = try #require(try await h.backend.vehicles(owner: me).last)

        #expect(await h.recorder.start(with: vehicle) == nil)
        #expect(h.recorder.phase == .recording)
        #expect(h.recorder.vehicle?.id == vehicle.id)
        try await h.drain(expecting: RecorderHarness.drive.count)
        #expect(h.recorder.live.distanceMeters > 200)

        let result = try #require(await h.recorder.finish())
        #expect(result.upload == .uploaded)
        #expect(result.vehicle?.id == vehicle.id)
        #expect(result.drive.vehicleID == vehicle.id)
        #expect(h.provider.stopCount >= 1)

        let stored = try #require(try await h.backend.drives(owner: me, limit: 50).first { $0.id == result.drive.id })
        #expect(stored.vehicleID == vehicle.id)
        #expect(stored.distanceMeters == result.drive.distanceMeters)
        #expect(try await h.backend.ownTrack(drive: stored.id).count == result.track.count)
    }

    @Test func guestDriveHasNoVehicle() async throws {
        let h = await RecorderHarness()
        let me = try #require(await h.backend.currentUserID())
        #expect(await h.recorder.start(with: nil) == nil)
        try await h.drain(expecting: RecorderHarness.drive.count)
        let result = try #require(await h.recorder.finish())
        #expect(result.vehicle == nil)
        let stored = try #require(try await h.backend.drives(owner: me, limit: 50).first { $0.id == result.drive.id })
        #expect(stored.vehicleID == nil)
    }

    @Test func remembersTheLastChoiceIncludingGuest() async throws {
        let h = await RecorderHarness()
        let me = try #require(await h.backend.currentUserID())
        let vehicles = try await h.backend.vehicles(owner: me)
        let second = try #require(vehicles.dropFirst().first)
        #expect(h.recorder.preferredChoice(among: vehicles) == .vehicle(vehicles[0].id))

        _ = await h.recorder.start(with: second)
        await h.recorder.discard()
        #expect(h.recorder.preferredChoice(among: vehicles) == .vehicle(second.id))

        _ = await h.recorder.start(with: nil)
        await h.recorder.discard()
        #expect(h.recorder.preferredChoice(among: vehicles) == .guest)

        // A remembered vehicle that was deleted falls back to the first one.
        _ = await h.recorder.start(with: second)
        await h.recorder.discard()
        #expect(h.recorder.preferredChoice(among: vehicles.filter { $0.id != second.id }) == .vehicle(vehicles[0].id))
    }

    @Test func deniedPermissionDoesNotRecord() async throws {
        let provider = InstantProvider(permission: .notDetermined, grantOnRequest: .denied, speeds: RecorderHarness.drive)
        let h = await RecorderHarness(provider: provider)
        #expect(await h.recorder.start(with: nil) == .permissionDenied)
        #expect(h.recorder.phase == .idle)
        #expect(provider.startCount == 0)
    }

    @Test func approximateLocationIsRefused() async throws {
        let provider = InstantProvider(permission: .reducedAccuracy, speeds: RecorderHarness.drive)
        let h = await RecorderHarness(provider: provider)
        #expect(await h.recorder.start(with: nil) == .reducedAccuracy)
        #expect(provider.startCount == 0)
    }

    @Test func tooShortDrivesAreNotSaved() async throws {
        let h = await RecorderHarness(provider: InstantProvider(speeds: RecorderHarness.short))
        let me = try #require(await h.backend.currentUserID())
        let before = try await h.backend.drives(owner: me, limit: 50).count
        _ = await h.recorder.start(with: nil)
        try await h.drain(expecting: RecorderHarness.short.count)
        let result = try #require(await h.recorder.finish())
        #expect(result.upload == .tooShort)
        #expect(try await h.backend.drives(owner: me, limit: 50).count == before)
        #expect(h.recorder.pendingUploads == 0)
    }

    @Test func cannotStartTwice() async throws {
        let h = await RecorderHarness()
        _ = await h.recorder.start(with: nil)
        #expect(await h.recorder.start(with: nil) == .alreadyRecording)
        await h.recorder.discard()
    }

    @Test func signedOutCannotRecord() async throws {
        let h = await RecorderHarness()
        h.recorder.ownerID = nil
        #expect(await h.recorder.start(with: nil) == .notSignedIn)
    }
}

@MainActor
@Suite("Garage store")
struct GarageStoreTests {
    @Test func newVehicleIsImmediatelyAvailable() async throws {
        let backend = DemoBackend(emptyGarage: true)
        let me = try #require(await backend.currentUserID())
        let store = GarageStore(backend: backend)
        await store.setOwner(me)
        #expect(store.isLoaded)
        #expect(store.active.isEmpty)

        let saved = try await store.save(Vehicle(ownerID: me, kind: .motorcycle, bodyStyle: .naked, make: "Triumph", model: "Street Triple", year: 2022))
        #expect(store.active.map(\.id) == [saved.id])
        #expect(store.vehicle(saved.id)?.bodyStyle == .naked)
    }

    @Test func archivedVehiclesLeaveThePicker() async throws {
        let backend = DemoBackend()
        let me = try #require(await backend.currentUserID())
        let store = GarageStore(backend: backend)
        await store.setOwner(me)
        var first = try #require(store.active.first)
        first.isArchived = true
        try await store.save(first)
        #expect(!store.active.contains { $0.id == first.id })
        #expect(store.archived.contains { $0.id == first.id })
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test func speedsAreWholeNumbers() {
        #expect(Format.speed(26.8224, .mph) == "60")
        #expect(Format.speed(nil, .mph) == Format.placeholder)
        #expect(Format.speed(27.7778, .kmh) == "100")
    }

    @Test func durations() {
        #expect(Format.duration(65) == "1:05")
        #expect(Format.duration(3_725) == "1:02:05")
    }

    @Test func zeroToSixtyLabelNeverChangesWithUnit() {
        #expect(Format.zeroToSixtyLabel == "0–60 mph")
    }
}
