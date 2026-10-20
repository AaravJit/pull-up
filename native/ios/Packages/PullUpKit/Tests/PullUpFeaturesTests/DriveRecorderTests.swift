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
    /// Seconds after "now" the track begins, e.g. to continue after an
    /// earlier track.
    let startOffset: TimeInterval

    init(
        permission: LocationPermission = .authorized, grantOnRequest: LocationPermission = .authorized,
        speeds: [Double], startOffset: TimeInterval = 0
    ) {
        self.permission = permission
        self.grantOnRequest = grantOnRequest
        self.speeds = speeds
        self.startOffset = startOffset
    }

    func requestPermission() async -> LocationPermission {
        permission = grantOnRequest
        return permission
    }

    func start() -> AsyncStream<LocationEvent> {
        startCount += 1
        let samples = DemoTracks.track(start: Date().addingTimeInterval(startOffset), speeds: speeds, headingSeed: 0.2)
        return AsyncStream { continuation in
            for sample in samples { continuation.yield(.sample(sample)) }
            continuation.finish()
        }
    }

    func stop() { stopCount += 1 }
}

/// Delivers a fixed list of events, for exact sequences.
@MainActor
final class ScriptedProvider: LocationProvider {
    let permission: LocationPermission = .authorized
    let events: [LocationEvent]
    init(events: [LocationEvent]) { self.events = events }
    func requestPermission() async -> LocationPermission { permission }
    func start() -> AsyncStream<LocationEvent> {
        let events = self.events
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func stop() {}
}

@MainActor
final class Counter {
    var value = 0
}

@MainActor
struct RecorderHarness {
    let backend: DemoBackend
    let defaults: UserDefaults
    let store: LocalDriveStore
    let recorder: DriveRecorder
    let provider: InstantProvider
    let requests = Counter()
    func providerRequests() -> Int { requests.value }

    static let drive: [Double] = Array(repeating: 0, count: 4) + (1...8).map { Double($0) * 3.5 } + Array(repeating: 28, count: 40)
    static let short: [Double] = [0, 1, 2, 3, 2, 1, 0]

    init(
        backend: DemoBackend = DemoBackend(), provider: InstantProvider = InstantProvider(speeds: drive),
        suite: String = "recorder-tests-\(UUID().uuidString)"
    ) async {
        self.backend = backend
        self.provider = provider
        defaults = UserDefaults(suiteName: suite)!
        let store = LocalDriveStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        self.store = store
        let counter = requests
        recorder = DriveRecorder(backend: backend, store: store, defaults: defaults) {
            counter.value += 1
            return provider
        }
        recorder.ownerID = await backend.currentUserID()
    }

    /// Waits until the recorder has consumed the provider's track.
    /// Waits up to 10 s: a loaded CI simulator can take seconds to deliver
    /// a scripted drive.
    func drain(expecting count: Int) async throws {
        for _ in 0..<1000 where recorder.acceptedCount + recorder.rejectedCount < count {
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

    @Test func deletedAccountLeavesNoDrivesOnThePhone() async throws {
        let h = await RecorderHarness()
        let me = try #require(await h.backend.currentUserID())
        let waiting = DriveDraft(ownerID: me, vehicleID: nil, startedAt: .now.addingTimeInterval(-900), endedAt: .now.addingTimeInterval(-600))
        let someoneElse = DriveDraft(ownerID: UUID(), vehicleID: nil, startedAt: .now.addingTimeInterval(-900), endedAt: .now.addingTimeInterval(-600))
        try await h.store.save(waiting)
        try await h.store.save(someoneElse)
        #expect(await h.recorder.start(with: nil) == nil)
        #expect(h.defaults.string(forKey: "pullup.lastVehicle.\(me.uuidString)") == "guest")

        await h.recorder.eraseLocalData(for: me)
        #expect(h.recorder.phase == .idle)
        #expect(await h.store.all().map(\.id) == [someoneElse.id])
        #expect(h.defaults.string(forKey: "pullup.lastVehicle.\(me.uuidString)") == nil)
        #expect(h.recorder.pendingUploads == 0)
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

    // MARK: Interruptions

    /// The app was closed mid-drive: a new recorder on the same disk store
    /// (what a relaunch builds) picks the drive up again.
    @Test func recentInterruptedDriveResumes() async throws {
        let suite = "recorder-tests-\(UUID().uuidString)"
        let backend = DemoBackend()
        let first = await RecorderHarness(backend: backend, suite: suite)
        let me = try #require(await backend.currentUserID())
        let vehicle = try #require(try await backend.vehicles(owner: me).first)
        _ = await first.recorder.start(with: vehicle)
        try await first.drain(expecting: RecorderHarness.drive.count)
        await first.recorder.flush()
        let before = first.recorder.acceptedCount
        #expect(before > 30)

        // The first track's fixes run about a minute ahead; the relaunched
        // one continues two minutes on, so the closed app leaves a gap.
        let relaunched = await RecorderHarness(
            backend: backend, provider: InstantProvider(speeds: RecorderHarness.drive, startOffset: 120), suite: suite
        )
        await relaunched.recorder.recoverInterrupted(vehicles: try await backend.vehicles(owner: me))
        #expect(relaunched.recorder.phase == .recording)
        #expect(relaunched.recorder.resumedDrive != nil)
        #expect(relaunched.recorder.vehicle?.id == vehicle.id)
        #expect(relaunched.recorder.acceptedCount >= before)
        try await relaunched.drain(expecting: before + RecorderHarness.drive.count)

        let result = try #require(await relaunched.recorder.finish())
        #expect(result.upload == .uploaded)
        #expect(result.track.count > before)
        #expect(result.drive.vehicleID == vehicle.id)
        #expect(result.summary.longestSignalGap > 10, "the time the app was closed is disclosed as a gap")
    }

    /// Too long ago to resume: the drive is finished at its last fix and
    /// uploaded instead of being lost.
    @Test func staleInterruptedDriveIsFinished() async throws {
        let suite = "recorder-tests-\(UUID().uuidString)"
        let backend = DemoBackend()
        let first = await RecorderHarness(backend: backend, suite: suite)
        let me = try #require(await backend.currentUserID())
        _ = await first.recorder.start(with: nil)
        try await first.drain(expecting: RecorderHarness.drive.count)
        await first.recorder.flush()
        let before = try await backend.drives(owner: me, limit: 50).count

        let relaunched = await RecorderHarness(backend: backend, suite: suite)
        await relaunched.recorder.recoverInterrupted(now: Date().addingTimeInterval(DriveRecorder.resumeWindow + 120))
        #expect(relaunched.recorder.phase == .idle)
        #expect(relaunched.recorder.recoveredDrive != nil)
        #expect(relaunched.recorder.pendingUploads == 0)
        #expect(try await backend.drives(owner: me, limit: 50).count == before + 1)
    }

    /// Relaunched offline: the garage hasn't loaded, but the drive still
    /// knows its vehicle instead of turning into a guest drive.
    @Test func resumedOfflineDriveKeepsItsVehicle() async throws {
        let suite = "recorder-tests-\(UUID().uuidString)"
        let backend = DemoBackend()
        let first = await RecorderHarness(backend: backend, suite: suite)
        let me = try #require(await backend.currentUserID())
        let vehicle = try #require(try await backend.vehicles(owner: me).first)
        _ = await first.recorder.start(with: vehicle)
        try await first.drain(expecting: RecorderHarness.drive.count)
        await first.recorder.flush()

        let relaunched = await RecorderHarness(
            backend: backend, provider: InstantProvider(speeds: RecorderHarness.drive, startOffset: 120), suite: suite
        )
        await relaunched.recorder.recoverInterrupted(vehicles: [])
        #expect(relaunched.recorder.phase == .recording)
        #expect(relaunched.recorder.vehicle?.id == vehicle.id)
        await relaunched.recorder.discard()
    }

    /// Closed after iOS delivered fixes past the limit: the recovered drive
    /// ends at the limit, so the server accepts it.
    @Test func recoveredDrivePastTheLimitIsCapped() async throws {
        let suite = "recorder-tests-\(UUID().uuidString)"
        let backend = DemoBackend()
        let first = await RecorderHarness(
            backend: backend,
            provider: InstantProvider(speeds: RecorderHarness.drive, startOffset: DriveRecorder.maximumDuration - 40),
            suite: suite
        )
        let me = try #require(await backend.currentUserID())
        _ = await first.recorder.start(with: nil)
        try await first.drain(expecting: RecorderHarness.drive.count)
        await first.recorder.flush()
        let started = try #require(first.recorder.startedAt)
        let before = Set(try await backend.drives(owner: me, limit: 50).map(\.id))

        let relaunched = await RecorderHarness(backend: backend, suite: suite)
        await relaunched.recorder.recoverInterrupted(now: started.addingTimeInterval(25 * 3600))
        #expect(relaunched.recorder.phase == .idle)
        #expect(relaunched.recorder.pendingUploads == 0)
        let uploaded = try #require(try await backend.drives(owner: me, limit: 50).first { !before.contains($0.id) })
        #expect(uploaded.endedAt.timeIntervalSince(started) <= DriveRecorder.maximumDuration + 0.001)
    }

    private static func fix(_ start: Date, _ t: Double, north: Double, speed: Double) -> LocationEvent {
        .sample(LocationSample(
            timestamp: start.addingTimeInterval(t), latitude: 38.58 + north / 111_195, longitude: -121.49,
            altitude: 20, horizontalAccuracy: 5, verticalAccuracy: 4, speed: speed, speedAccuracy: 0.5, course: 0
        ))
    }

    /// Parked with updates paused, then stopped minutes later: the drive
    /// ends at its last fix, which is how the server times it.
    @Test func driveEndsAtItsLastFix() async throws {
        let backend = DemoBackend()
        let suite = "recorder-tests-\(UUID().uuidString)"
        let store = LocalDriveStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let start = Date()
        let events = (0..<40).map { Self.fix(start, Double($0), north: Double($0) * 10, speed: 10) } + [.stationary(true)]
        let provider = ScriptedProvider(events: events)
        let recorder = DriveRecorder(backend: backend, store: store, defaults: UserDefaults(suiteName: suite)!) { provider }
        recorder.ownerID = await backend.currentUserID()
        _ = await recorder.start(with: nil)
        for _ in 0..<1000 where !recorder.isStationary { try await Task.sleep(for: .milliseconds(10)) }
        try #require(recorder.isStationary)
        let result = try #require(await recorder.finish(now: start.addingTimeInterval(400)))
        #expect(result.summary.endedAt == start.addingTimeInterval(39))
        #expect(result.upload == .uploaded)
    }

    /// A stop iOS paused updates for, then `middle`, then the car 600 m on
    /// a minute later. Returns the finished drive's summary.
    private func scriptedStop(then middle: [LocationEvent]) async throws -> DriveSummary {
        let backend = DemoBackend()
        let suite = "recorder-tests-\(UUID().uuidString)"
        let store = LocalDriveStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let start = Date()
        func fix(_ t: Double, north: Double, speed: Double) -> LocationEvent { Self.fix(start, t, north: north, speed: speed) }
        var events = (0..<40).map { fix(Double($0), north: Double($0) * 10, speed: 10) }
        events += (40..<45).map { fix(Double($0), north: 390, speed: 0) }
        events += [.stationary(true)] + middle
        events += (105..<115).map { fix(Double($0), north: 990 + Double($0 - 105) * 10, speed: 10) }
        let provider = ScriptedProvider(events: events)
        let recorder = DriveRecorder(backend: backend, store: store, defaults: UserDefaults(suiteName: suite)!) { provider }
        recorder.ownerID = await backend.currentUserID()
        _ = await recorder.start(with: nil)
        for _ in 0..<1000 where recorder.acceptedCount < 54 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(recorder.isStationary == false)
        return try #require(await recorder.finish(now: start.addingTimeInterval(115))).summary
    }

    /// iOS paused updates at a stop, then the updates stream failed and was
    /// restarted. The car moved meanwhile: that's a signal gap, not a stop.
    @Test func restartAfterAPauseIsASignalGap() async throws {
        let summary = try await scriptedStop(then: [.restarting])
        #expect(summary.longestSignalGap >= 60)
        #expect(summary.gapDistanceMeters > 500)
    }

    /// The pause ended but no fix came (the car pulled out of a garage):
    /// the silence until the next fix is a signal gap, not a stop.
    @Test func pauseEndingWithoutAFixIsASignalGap() async throws {
        let summary = try await scriptedStop(then: [.stationary(false), .unavailable])
        #expect(summary.longestSignalGap >= 60)
        #expect(summary.gapDistanceMeters > 500)
    }

    /// A periodic save was still queued when the drive was thrown away; it
    /// must not write the drive back to disk afterwards.
    @Test func queuedSaveDoesNotBringBackADiscardedDrive() async throws {
        let h = await RecorderHarness()
        _ = await h.recorder.start(with: nil)
        try await h.drain(expecting: RecorderHarness.drive.count)
        h.recorder.tick(flush: true)
        await h.recorder.discard()
        for _ in 0..<5 { await Task.yield() }
        #expect(await h.store.all().isEmpty)
    }

    /// Precise location was turned off while the app wasn't running.
    @Test func interruptedDriveIsNotResumedWithoutPermission() async throws {
        let suite = "recorder-tests-\(UUID().uuidString)"
        let backend = DemoBackend()
        let first = await RecorderHarness(backend: backend, suite: suite)
        _ = await first.recorder.start(with: nil)
        try await first.drain(expecting: RecorderHarness.drive.count)
        await first.recorder.flush()

        let relaunched = await RecorderHarness(
            backend: backend, provider: InstantProvider(permission: .reducedAccuracy, speeds: RecorderHarness.drive), suite: suite
        )
        await relaunched.recorder.recoverInterrupted()
        #expect(relaunched.recorder.phase == .idle)
        #expect(relaunched.recorder.recoveredDrive != nil)
        #expect(relaunched.provider.startCount == 0)
    }

    /// The server keeps drives up to 24 hours; recording stops before that.
    @Test func stopsItselfBeforeTheDurationLimit() async throws {
        let h = await RecorderHarness()
        _ = await h.recorder.start(with: nil)
        try await h.drain(expecting: RecorderHarness.drive.count)
        let started = try #require(h.recorder.startedAt)
        h.recorder.tick(flush: false, now: started.addingTimeInterval(DriveRecorder.maximumDuration))
        for _ in 0..<1000 where h.recorder.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.recorder.phase == .idle)
        #expect(h.recorder.interruption != nil)
        #expect(h.recorder.lastResult?.upload == .uploaded)
    }

    /// The app was suspended past the limit, so the stopping tick runs late.
    @Test func lateStopEndsTheDriveWithinTheLimit() async throws {
        let h = await RecorderHarness()
        _ = await h.recorder.start(with: nil)
        try await h.drain(expecting: RecorderHarness.drive.count)
        let started = try #require(h.recorder.startedAt)
        h.recorder.tick(flush: false, now: started.addingTimeInterval(25 * 3600))
        for _ in 0..<1000 where h.recorder.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        let result = try #require(h.recorder.lastResult)
        #expect(result.summary.endedAt.timeIntervalSince(started) <= DriveRecorder.maximumDuration)
        #expect(result.upload == .uploaded)
    }

    /// Fixes iOS delivers after the limit are dropped, not uploaded.
    @Test func fixesAfterTheLimitAreDropped() async throws {
        let provider = InstantProvider(speeds: RecorderHarness.drive, startOffset: DriveRecorder.maximumDuration - 20)
        let h = await RecorderHarness(provider: provider)
        _ = await h.recorder.start(with: nil)
        try await h.drain(expecting: RecorderHarness.drive.count)
        let started = try #require(h.recorder.startedAt)
        let result = try #require(await h.recorder.finish(now: started.addingTimeInterval(25 * 3600)))
        let end = result.summary.endedAt
        #expect(end.timeIntervalSince(started) <= DriveRecorder.maximumDuration)
        #expect(!result.track.isEmpty)
        #expect(result.track.allSatisfy { $0.timestamp <= end })
        #expect(result.track.count < RecorderHarness.drive.count)
        #expect(result.summary.movingSeconds <= result.summary.elapsedSeconds)
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

@Suite("Location event order")
struct LocationEventOrderTests {
    let fix = LocationSample(
        timestamp: Date(timeIntervalSince1970: 1_800_000_000), latitude: 38.58, longitude: -121.49,
        altitude: 20, horizontalAccuracy: 5, verticalAccuracy: 4, speed: 0, speedAccuracy: 0.5, course: 0
    )

    /// iOS's last update before it pauses carries a fix and the stationary
    /// flag; the pause must outlive that fix.
    @Test func lastFixComesBeforeThePause() {
        let events = LocationEvent.forUpdate(location: fix, stationary: true, locationUnavailable: false, wasStationary: false)
        #expect(events == [.sample(fix), .stationary(true)])
    }

    @Test func pauseEndsBeforeTheNextFix() {
        let events = LocationEvent.forUpdate(location: fix, stationary: false, locationUnavailable: false, wasStationary: true)
        #expect(events == [.stationary(false), .sample(fix)])
    }

    /// Ingesting a fix clears the pause, so a fix iOS delivers while still
    /// paused is followed by the pause again.
    @Test func fixDuringAPauseKeepsThePause() {
        let events = LocationEvent.forUpdate(location: fix, stationary: true, locationUnavailable: false, wasStationary: true)
        #expect(events == [.sample(fix), .stationary(true)])
    }

    @Test func unchangedFlagAddsNoMarker() {
        #expect(LocationEvent.forUpdate(location: nil, stationary: true, locationUnavailable: false, wasStationary: true) == [])
        #expect(LocationEvent.forUpdate(location: nil, stationary: false, locationUnavailable: true, wasStationary: false) == [.unavailable])
    }
}
