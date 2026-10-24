import Foundation
import Observation
import PullUpData
import PullUpDomain
import PullUpLocation
import PullUpTelemetry
import Synchronization

/// A finished drive as the summary screen shows it.
public struct FinishedDrive: Identifiable, Equatable, Sendable {
    public enum Upload: Equatable, Sendable {
        /// Stored on the server; validation status is on `drive`.
        case uploaded
        /// Kept on this device and retried automatically.
        case savedOffline(reason: String)
        /// Fewer than 30 clean fixes or under 200 m. Nothing was saved.
        case tooShort
        /// The server refused the drive's data for good. Kept on this device,
        /// but not retried until the person asks.
        case rejected
        /// Not stored on the server and couldn't be saved on this device
        /// either (its storage may be full).
        case notSaved
    }

    public var id: UUID { drive.id }
    public var drive: Drive
    public var summary: DriveSummary
    public var track: [LocationSample]
    public var speedSeries: [SpeedPoint]
    /// `nil` = guest vehicle.
    public var vehicle: Vehicle?
    public var upload: Upload
}

/// Records one drive at a time: owns the location stream, feeds the
/// telemetry engine, keeps a crash-safe copy on disk, and uploads the result.
///
/// Nothing here starts on its own. Location is requested and recording begins
/// only inside `start(with:)`, which the UI calls when the user confirms a
/// vehicle in the Start Drive picker. Opening the picker does not record.
@MainActor
@Observable
public final class DriveRecorder {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case recording
        case finishing
    }

    public enum StartFailure: Error, Equatable, Sendable {
        case notSignedIn
        case permissionDenied
        case permissionRestricted
        case reducedAccuracy
        case alreadyRecording

        public var message: String {
            switch self {
            case .notSignedIn: "Sign in to record drives."
            case .permissionDenied: "Location access is off for Pull Up. Turn it on in Settings to record a drive."
            case .permissionRestricted: "Location access is restricted on this device, so drives can't be recorded."
            case .reducedAccuracy: "Precise Location is off. Telemetry needs it; approximate location is accurate only to about a kilometre."
            case .alreadyRecording: "A drive is already recording."
            }
        }

        public var canOpenSettings: Bool { self == .permissionDenied || self == .reducedAccuracy }
    }

    public enum Choice: Hashable, Sendable {
        case vehicle(UUID)
        case guest
    }

    public private(set) var phase: Phase = .idle
    public private(set) var live: LiveTelemetry = .empty
    /// Vehicle the current drive is logged against. `nil` = guest.
    public private(set) var vehicle: Vehicle?
    /// Accepted fixes for the live mini-map, thinned to ~10 m spacing.
    public private(set) var route: [Coordinate] = []
    /// iOS paused updates because the phone isn't moving.
    public private(set) var isStationary = false
    /// Why recording stopped without the user asking.
    public private(set) var interruption: String?
    public private(set) var lastResult: FinishedDrive?
    public private(set) var pendingUploads = 0
    /// Finished drives the server refused, kept on this device.
    public private(set) var rejectedUploads = 0
    /// Goes up whenever the drives stored on the server change (an upload
    /// went through, a drive was deleted), so lists of them can reload.
    public private(set) var storedDrivesRevision = 0
    public private(set) var recoveredDrive: Date?
    /// The app was closed mid-drive and recording picked up where it left
    /// off. The time it wasn't running counts as a signal gap.
    public private(set) var resumedDrive: Date?
    /// Low Power Mode is on. iOS may deliver fixes less often.
    public private(set) var isLowPowerMode = false
    /// The location source replays a recorded track (demo mode).
    public let usesReplay: Bool

    public var isRecording: Bool { phase == .recording }
    public var startedAt: Date? { draft?.startedAt }
    public var acceptedCount: Int { engine?.accepted.count ?? 0 }
    public var rejectedCount: Int { engine?.rejectedCount ?? 0 }

    public var ownerID: UserID?

    private let backend: any BackendService
    private let store: LocalDriveStore
    private let defaults: UserDefaults
    private let makeProvider: @MainActor () -> any LocationProvider
    private var provider: (any LocationProvider)?
    private var engine: TelemetryEngine?
    private var draft: DriveDraft?
    private var streamTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var unsavedSamples = 0
    private var lastSave: Task<Void, Never>?
    /// Uploads under way, by drive.
    @ObservationIgnored private var uploads: [UUID: Task<Sent, Never>] = [:]
    @ObservationIgnored private var syncing: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false
    /// How a drive reaches the server. Tests swap in a slow or refusing one.
    @ObservationIgnored var sendDrive: @Sendable (Drive, [LocationSample]) async throws -> Drive
    /// How long the summary waits for an upload before saying it's saved on
    /// this device. The upload itself carries on.
    @ObservationIgnored var uploadTimeout: Duration = .seconds(15)

    static let minimumSamples = 30
    static let minimumDistance = 200.0
    /// The server refuses drives longer than 24 hours, so recording stops
    /// itself a little before that.
    static let maximumDuration: TimeInterval = 23 * 3600 + 50 * 60
    /// A drive cut short this recently is resumed rather than finished.
    static let resumeWindow: TimeInterval = 15 * 60
    /// Unsaved fixes are written to disk at least this often.
    static let flushInterval = 30

    public init(
        backend: any BackendService, store: LocalDriveStore, defaults: UserDefaults = .standard,
        usesReplay: Bool = false, makeProvider: @escaping @MainActor () -> any LocationProvider
    ) {
        self.backend = backend
        self.store = store
        self.defaults = defaults
        self.usesReplay = usesReplay
        self.makeProvider = makeProvider
        sendDrive = { [backend] drive, track in try await backend.upload(drive: drive, track: track) }
    }

    // MARK: Vehicle preference

    private var preferenceKey: String { "pullup.lastVehicle.\(ownerID?.uuidString ?? "anon")" }

    /// The vehicle to preselect: the last one used if it still exists,
    /// otherwise the first in the garage, otherwise guest.
    public func preferredChoice(among vehicles: [Vehicle]) -> Choice {
        if let stored = defaults.string(forKey: preferenceKey) {
            if stored == "guest" { return .guest }
            if let id = UUID(uuidString: stored), vehicles.contains(where: { $0.id == id }) { return .vehicle(id) }
        }
        return vehicles.first.map { .vehicle($0.id) } ?? .guest
    }

    private func remember(_ vehicle: Vehicle?) {
        defaults.set(vehicle?.id.uuidString ?? "guest", forKey: preferenceKey)
    }

    // MARK: Recording

    /// Requests permission if needed, then starts recording against
    /// `vehicle` (`nil` = guest). Returns why it couldn't start, if it didn't.
    public func start(with vehicle: Vehicle?) async -> StartFailure? {
        guard phase == .idle else { return .alreadyRecording }
        guard let ownerID else { return .notSignedIn }
        phase = .starting
        let provider = makeProvider()
        var permission = provider.permission
        if permission == .notDetermined { permission = await provider.requestPermission() }
        if permission == .reducedAccuracy { permission = await provider.requestFullAccuracy() }
        switch permission {
        case .authorized: break
        case .notDetermined, .denied:
            phase = .idle
            return .permissionDenied
        case .restricted:
            phase = .idle
            return .permissionRestricted
        case .reducedAccuracy:
            phase = .idle
            return .reducedAccuracy
        }

        let now = Date()
        remember(vehicle)
        resumedDrive = nil
        var draft = DriveDraft(ownerID: ownerID, vehicleID: vehicle?.id, startedAt: now, title: Drive.defaultTitle(startedAt: now))
        draft.vehicle = vehicle
        begin(provider: provider, vehicle: vehicle, draft: draft, engine: TelemetryEngine(startedAt: now))
        await persistDraft()
        return nil
    }

    private func begin(provider: any LocationProvider, vehicle: Vehicle?, draft: DriveDraft, engine: TelemetryEngine) {
        self.provider = provider
        self.vehicle = vehicle
        self.engine = engine
        self.draft = draft
        route = []
        for sample in engine.accepted { appendToRoute(sample.coordinate) }
        live = .empty
        isStationary = false
        interruption = nil
        lastResult = nil
        unsavedSamples = 0
        phase = .recording

        let stream = provider.start()
        streamTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        tickTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                ticks += 1
                self.tick(flush: ticks % Self.flushInterval == 0)
            }
        }
    }

    func tick(flush: Bool, now: Date = .now) {
        guard phase == .recording, let draft else { return }
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if now.timeIntervalSince(draft.startedAt) >= Self.maximumDuration {
            interruption = "Recording stopped on its own after almost 24 hours, the longest drive Pull Up keeps. Start a new drive to keep going."
            Task { await self.finish(now: now) }
            return
        }
        if flush, unsavedSamples > 0 { Task { await self.persistDraft() } }
        refreshLive(now: now)
    }

    /// Writes unsaved fixes to disk now, e.g. when the app goes to the
    /// background, so a crash or termination loses as little as possible.
    public func flush() async {
        guard phase == .recording, unsavedSamples > 0 else { return }
        await persistDraft()
    }

    private func handle(_ event: LocationEvent) {
        guard phase == .recording, var engine else { return }
        switch event {
        case let .sample(sample):
            let relocks = engine.relocks
            let verdict = engine.ingest(sample)
            self.engine = engine
            if engine.relocks != relocks {
                // The engine re-anchored on a cluster of fixes it had been
                // rejecting (a bad first fix, or a long multipath jump). Keep
                // the stored track identical to what the engine accepted.
                draft?.samples = engine.accepted
                route = []
                for fix in engine.accepted { appendToRoute(fix.coordinate) }
            } else if verdict == .accepted {
                draft?.samples.append(sample)
                appendToRoute(sample.coordinate)
            }
            if verdict == .accepted {
                isStationary = false
                unsavedSamples += 1
                if unsavedSamples >= 15 { Task { await self.persistDraft() } }
            }
            refreshLive()
        case let .stationary(still):
            engine.noteStationary(still)
            self.engine = engine
            if still {
                // Read before writing: `draft?.x = …draft…` would read the
                // property while the write's access is open, and crash.
                let pauses = (draft?.stationaryPauses ?? []) + [Date()]
                draft?.stationaryPauses = pauses
            }
            isStationary = still
            refreshLive()
        case .unavailable:
            // No fix and no pause (including a pause that ended without a
            // fix, as when the car pulls out of a garage): what happens
            // until the next fix is unknown.
            if !isStationary { noteUnknownSilence(&engine) }
            refreshLive()
        case .restarting:
            noteUnknownSilence(&engine)
            refreshLive()
        case .accuracyReduced:
            interruption = "Precise Location was turned off, so recording stopped. Everything up to that point was kept."
            Task { await self.finish() }
        case .denied:
            interruption = "Location access was turned off, so recording stopped. Everything up to that point was kept."
            Task { await self.finish() }
        }
    }

    /// A pause still open doesn't explain the silence that follows: drop it
    /// so the gap is bridged and disclosed, live and in later replays.
    private func noteUnknownSilence(_ engine: inout TelemetryEngine) {
        engine.noteInterruption()
        self.engine = engine
        if let lastFix = draft?.samples.last?.timestamp { draft?.stationaryPauses?.removeAll { $0 >= lastFix } }
        isStationary = false
    }

    private func appendToRoute(_ coordinate: Coordinate) {
        if let last = route.last, last.distance(to: coordinate) < 10 { return }
        route.append(coordinate)
    }

    private func refreshLive(now: Date = .now) {
        guard phase == .recording, let engine else { return }
        // A stationary pause (red light, parked) is handled by the engine:
        // a known zero, not a lost signal.
        live = engine.live(at: now)
    }

    /// Saves only while recording, one after another: a save still queued
    /// when finish() or discard() runs would otherwise land after them,
    /// overwriting the finished drive or bringing a discarded one back.
    private func persistDraft() async {
        guard phase == .recording, let draft else { return }
        unsavedSamples = 0
        let previous = lastSave
        let save = Task { [store] in
            await previous?.value
            try? await store.save(draft)
        }
        lastSave = save
        await save.value
    }

    /// Waits for saves already under way, before the drive's last write.
    private func settleSaves() async {
        await lastSave?.value
        lastSave = nil
    }

    /// Stops recording and produces the summary. Uploads when worth keeping;
    /// otherwise discards the local copy.
    @discardableResult
    public func finish(now: Date = .now) async -> FinishedDrive? {
        guard phase == .recording, var engine, var draft else { return nil }
        phase = .finishing
        streamTask?.cancel()
        tickTask?.cancel()
        provider?.stop()
        provider = nil
        await settleSaves()

        // iOS can suspend the app past the limit before the tick that stops
        // it runs; the server would then refuse the drive outright.
        var end = min(now, Self.limit(of: draft))
        if Self.trimToLimit(&draft) {
            engine = TelemetryEngine.replay(draft.samples, startedAt: draft.startedAt, stationaryPauses: draft.stationaryPauses ?? [])
        }
        // The server times a drive by its track. A stop long after the last
        // fix (parked with updates paused, or still in a tunnel after a
        // relaunch) would fail its duration check, so the drive ends there.
        if let lastFix = draft.samples.last?.timestamp { end = min(end, lastFix) }
        draft.endedAt = end
        let summary = engine.summary(endedAt: end)
        var result = FinishedDrive(
            drive: Self.makeDrive(from: draft, summary: summary),
            summary: summary, track: draft.samples, speedSeries: engine.speedSeries,
            vehicle: vehicle, upload: .tooShort
        )

        if Self.isWorthKeeping(summary) {
            // On disk before the upload, so a slow or lost upload loses nothing.
            let savedLocally = (try? await store.save(draft)) != nil
            let (state, uploaded) = await upload(draft, drive: result.drive)
            // Without a copy on disk there's nothing to keep or retry.
            result.upload = (savedLocally || state == .uploaded) ? state : .notSaved
            if let uploaded { result.drive = uploaded }
        } else {
            await store.delete(draft.id)
        }

        self.engine = nil
        self.draft = nil
        live = .empty
        route = []
        lastResult = result
        phase = .idle
        await refreshPendingCount()
        return result
    }

    /// Stops and throws the drive away without saving anything.
    public func discard() async {
        guard phase == .recording, let draft else { return }
        phase = .finishing
        streamTask?.cancel()
        tickTask?.cancel()
        provider?.stop()
        provider = nil
        await settleSaves()
        await store.delete(draft.id)
        engine = nil
        self.draft = nil
        live = .empty
        route = []
        phase = .idle
    }

    public func clearResult() {
        lastResult = nil
        interruption = nil
        resumedDrive = nil
    }

    /// After `owner`'s account is deleted: stops a drive in progress and
    /// removes every drive of theirs still on this phone (raw GPS, including
    /// protected places) and the vehicle remembered for them.
    public func eraseLocalData(for owner: UserID) async {
        if draft?.ownerID == owner { await discard() }
        await store.deleteAll(owner: owner)
        defaults.removeObject(forKey: "pullup.lastVehicle.\(owner.uuidString)")
        if lastResult?.drive.ownerID == owner { clearResult() }
        recoveredDrive = nil
        await refreshPendingCount()
    }

    static func isWorthKeeping(_ summary: DriveSummary) -> Bool {
        summary.acceptedSamples >= minimumSamples && summary.distanceMeters >= minimumDistance
    }

    /// The latest a drive may end: the server refuses drives over 24 hours.
    static func limit(of draft: DriveDraft) -> Date {
        draft.startedAt.addingTimeInterval(maximumDuration)
    }

    /// Drops fixes and pauses after the limit, which don't belong to the
    /// drive (iOS delivered them late). Returns whether any were dropped.
    @discardableResult
    static func trimToLimit(_ draft: inout DriveDraft) -> Bool {
        let cutoff = Self.limit(of: draft)
        guard draft.samples.contains(where: { $0.timestamp > cutoff }) else { return false }
        draft.samples.removeAll { $0.timestamp > cutoff }
        draft.stationaryPauses?.removeAll { $0 > cutoff }
        return true
    }

    static func makeDrive(from draft: DriveDraft, summary: DriveSummary) -> Drive {
        Drive(
            id: draft.id, ownerID: draft.ownerID ?? UUID(), vehicleID: draft.vehicleID,
            title: draft.title.isEmpty ? Drive.defaultTitle(startedAt: draft.startedAt) : draft.title,
            summary: summary, visibility: draft.audience
        )
    }

    // MARK: Upload and recovery

    /// One upload's outcome.
    private enum Sent: Sendable {
        case uploaded(Drive)
        case failed(reason: String)
        case rejected
    }

    private func upload(_ draft: DriveDraft, drive: Drive) async -> (FinishedDrive.Upload, Drive?) {
        guard backend.mode != .unconfigured else { return (.savedOffline(reason: "No server is configured in this build."), nil) }
        // A drive already on its way (an upload nobody waited for to the
        // end) is waited on again, never sent a second time alongside it.
        let attempt = uploads[draft.id] ?? send(draft, drive: drive)
        switch await Self.outcome(of: attempt, within: uploadTimeout) {
        case let .uploaded(stored)?: return (.uploaded, stored)
        case let .failed(reason)?: return (.savedOffline(reason: reason), nil)
        case .rejected?: return (.rejected, nil)
        case nil: return (.savedOffline(reason: "The connection is too slow right now."), nil)
        }
    }

    /// Sends one drive and records how it went on disk: removed once the
    /// server has it, marked when the server refuses it for good. It runs to
    /// the end even if nobody is waiting for it any more. The server keeps
    /// one copy however often a drive is sent.
    private func send(_ draft: DriveDraft, drive: Drive) -> Task<Sent, Never> {
        let id = draft.id
        let attempt = Task<Sent, Never> { [store, sendDrive] in
            let sent: Sent
            do {
                let stored = try await sendDrive(drive, draft.samples)
                await store.delete(id)
                sent = .uploaded(stored)
            } catch {
                if DriveDraft.isPermanentRejection(error) {
                    try? await store.markRejected(id, at: .now)
                    sent = .rejected
                } else {
                    sent = .failed(reason: Self.plainReason(error))
                }
            }
            self.uploads[id] = nil
            if case .uploaded = sent { self.storedDrivesRevision += 1 }
            await self.refreshPendingCount()
            return sent
        }
        uploads[id] = attempt
        return attempt
    }

    /// The upload's outcome, or `nil` once `timeout` has passed.
    private static func outcome(of attempt: Task<Sent, Never>, within timeout: Duration) async -> Sent? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Sent?, Never>) in
            let first = FirstValue(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                first.resume(returning: nil)
            }
            Task {
                let sent = await attempt.value
                first.resume(returning: sent)
                timer.cancel()
            }
        }
    }

    /// Why an upload didn't go through, in plain words.
    static func plainReason(_ error: any Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "There's no connection right now."
            case .timedOut:
                return "The connection is too slow right now."
            default:
                break
            }
        }
        return "The upload didn't go through this time."
    }

    /// Uploads finished drives that couldn't be sent earlier. Never runs
    /// twice at once: a call while a sync is under way waits for it, and one
    /// more pass follows for drives saved meanwhile.
    public func syncPending() async {
        syncAgain = true
        if let syncing {
            await syncing.value
            return
        }
        let sync = Task {
            while self.syncAgain {
                self.syncAgain = false
                await self.syncOnce()
            }
            self.syncing = nil
        }
        syncing = sync
        await sync.value
    }

    private func syncOnce() async {
        guard let ownerID, phase == .idle else { return }
        for var draft in await store.pendingUploads() where draft.ownerID == ownerID {
            // Deleted (or sent) since the list was read.
            guard await store.load(draft.id) != nil, let recorded = draft.endedAt else { continue }
            // Drafts finished past the limit (by older builds) would be
            // refused by the server forever.
            let end = min(recorded, Self.limit(of: draft))
            Self.trimToLimit(&draft)
            draft.endedAt = end
            let engine = TelemetryEngine.replay(draft.samples, startedAt: draft.startedAt, stationaryPauses: draft.stationaryPauses ?? [])
            let summary = engine.summary(endedAt: end)
            guard Self.isWorthKeeping(summary) else {
                await store.delete(draft.id)
                continue
            }
            _ = await upload(draft, drive: Self.makeDrive(from: draft, summary: summary))
        }
        await refreshPendingCount()
    }

    /// Removes from this device the drives the server refused.
    public func deleteRejectedUploads() async {
        guard let ownerID else { return }
        for draft in await store.rejectedUploads() where draft.ownerID == ownerID {
            // The server may have kept the drive's stats when only its track
            // was refused.
            try? await backend.deleteDrive(draft.id)
            await store.delete(draft.id)
        }
        storedDrivesRevision += 1
        await refreshPendingCount()
    }

    /// Deletes a drive from the server and from this device, so a copy
    /// still waiting here (its stats reached the server but not its track)
    /// isn't sent again by the next sync.
    public func deleteDrive(_ id: UUID) async throws {
        // An upload under way would store the drive again after the delete.
        while let attempt = uploads[id] { _ = await attempt.value }
        await store.delete(id)
        do {
            try await backend.deleteDrive(id)
        } catch {
            await refreshPendingCount()
            throw error
        }
        storedDrivesRevision += 1
        await refreshPendingCount()
    }

    /// Sends the drives the server refused once more, e.g. after an update.
    /// One refused again is marked again.
    public func retryRejectedUploads() async {
        guard let ownerID else { return }
        for draft in await store.rejectedUploads() where draft.ownerID == ownerID { try? await store.markRejected(draft.id, at: nil) }
        await refreshPendingCount()
        await syncPending()
    }

    /// Handles a recording that was cut short because the app was closed
    /// (iOS ended it, it crashed, or the person force-quit it).
    ///
    /// If the last fix is recent and precise location is still allowed (or
    /// allowed again at the prompt), recording resumes on the same drive; the
    /// time the app wasn't running is a signal gap, bridged and disclosed like
    /// any other. Otherwise the drive is finished at its last fix so it
    /// uploads instead of disappearing. `vehicles` resolves the drive's
    /// vehicle for display.
    public func recoverInterrupted(vehicles: [Vehicle] = [], now: Date = .now) async {
        guard phase == .idle, ownerID != nil else { return }
        guard var draft = await store.interrupted(), draft.ownerID == ownerID, phase == .idle else { return }
        let lastFix = draft.samples.last?.timestamp ?? draft.startedAt
        if now.timeIntervalSince(lastFix) <= Self.resumeWindow,
           now.timeIntervalSince(draft.startedAt) < Self.maximumDuration {
            // Held while iOS asks, so no other drive starts meanwhile.
            phase = .starting
            let provider = makeProvider()
            var permission = provider.permission
            // Precise location allowed for one drive ends with the app, so
            // it's asked for again before the drive is given up.
            if permission == .reducedAccuracy { permission = await provider.requestFullAccuracy() }
            if permission == .authorized {
                // A pause still open when the app closed doesn't explain the
                // silence that followed; drop it so later replays agree.
                draft.stationaryPauses?.removeAll { $0 >= lastFix }
                var engine = TelemetryEngine.replay(draft.samples, startedAt: draft.startedAt, stationaryPauses: draft.stationaryPauses ?? [])
                engine.noteInterruption()
                draft.samples = engine.accepted
                resumedDrive = draft.startedAt
                let vehicle = vehicles.first { $0.id == draft.vehicleID } ?? draft.vehicle
                begin(provider: provider, vehicle: vehicle, draft: draft, engine: engine)
                await persistDraft()
                return
            }
            phase = .idle
        }
        let end = min(lastFix, Self.limit(of: draft))
        Self.trimToLimit(&draft)
        draft.endedAt = end
        try? await store.save(draft)
        recoveredDrive = draft.startedAt
        await syncPending()
    }

    public func dismissRecoveryNotice() { recoveredDrive = nil }

    private func refreshPendingCount() async {
        guard let ownerID else {
            pendingUploads = 0
            rejectedUploads = 0
            return
        }
        pendingUploads = await store.pendingUploads().filter { $0.ownerID == ownerID }.count
        rejectedUploads = await store.rejectedUploads().filter { $0.ownerID == ownerID }.count
    }

    /// Updates title and audience after the summary screen edits them.
    public func updateResult(title: String, audience: Audience) async throws {
        guard var result = lastResult, result.upload == .uploaded else { return }
        try await backend.updateDrive(result.drive.id, title: title, audience: audience)
        result.drive.title = title
        result.drive.visibility = audience
        lastResult = result
    }
}

/// Resumes a continuation with whichever value arrives first.
private final class FirstValue<Value: Sendable>: Sendable {
    private let continuation: CheckedContinuation<Value, Never>
    private let resumed = Mutex(false)

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let isFirst = resumed.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if isFirst { continuation.resume(returning: value) }
    }
}
