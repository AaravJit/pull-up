import Foundation
import Observation
import PullUpData
import PullUpDomain
import PullUpLocation
import PullUpTelemetry

/// A finished drive as the summary screen shows it.
public struct FinishedDrive: Identifiable, Equatable, Sendable {
    public enum Upload: Equatable, Sendable {
        /// Stored on the server; validation status is on `drive`.
        case uploaded
        /// Kept on this device and retried automatically.
        case savedOffline(reason: String)
        /// Fewer than 30 clean fixes or under 200 m. Nothing was saved.
        case tooShort
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

    private func persistDraft() async {
        guard let draft else { return }
        unsavedSamples = 0
        try? await store.save(draft)
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

        // iOS can suspend the app past the limit before the tick that stops
        // it runs; the server would then refuse the drive outright.
        let end = min(now, Self.limit(of: draft))
        if Self.trim(&draft, after: end) {
            engine = TelemetryEngine.replay(draft.samples, startedAt: draft.startedAt, stationaryPauses: draft.stationaryPauses ?? [])
        }
        draft.endedAt = end
        let summary = engine.summary(endedAt: end)
        var result = FinishedDrive(
            drive: Self.makeDrive(from: draft, summary: summary),
            summary: summary, track: draft.samples, speedSeries: engine.speedSeries,
            vehicle: vehicle, upload: .tooShort
        )

        if Self.isWorthKeeping(summary) {
            try? await store.save(draft)
            let (state, uploaded) = await upload(draft, drive: result.drive)
            result.upload = state
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
        streamTask?.cancel()
        tickTask?.cancel()
        provider?.stop()
        provider = nil
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

    /// Drops fixes and pauses after `end`, which don't belong to the drive
    /// (iOS delivered them after the limit). Returns whether any were dropped.
    @discardableResult
    static func trim(_ draft: inout DriveDraft, after end: Date) -> Bool {
        guard draft.samples.contains(where: { $0.timestamp > end }) else { return false }
        draft.samples.removeAll { $0.timestamp > end }
        draft.stationaryPauses?.removeAll { $0 > end }
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

    private func upload(_ draft: DriveDraft, drive: Drive) async -> (FinishedDrive.Upload, Drive?) {
        guard backend.mode != .unconfigured else { return (.savedOffline(reason: "No server is configured in this build."), nil) }
        do {
            let stored = try await backend.upload(drive: drive, track: draft.samples)
            await store.delete(draft.id)
            return (.uploaded, stored)
        } catch {
            return (.savedOffline(reason: error.localizedDescription), nil)
        }
    }

    /// Uploads finished drives that couldn't be sent earlier.
    public func syncPending() async {
        guard let ownerID, phase == .idle else { return }
        for var draft in await store.pendingUploads() where draft.ownerID == ownerID {
            guard let recorded = draft.endedAt else { continue }
            // Drafts finished past the limit (by older builds) would be
            // refused by the server forever.
            let end = min(recorded, Self.limit(of: draft))
            Self.trim(&draft, after: end)
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

    /// Handles a recording that was cut short because the app was closed
    /// (iOS ended it, it crashed, or the person force-quit it).
    ///
    /// If the last fix is recent and precise location is still allowed,
    /// recording resumes on the same drive; the time the app wasn't running
    /// is a signal gap, bridged and disclosed like any other. Otherwise the
    /// drive is finished at its last fix so it uploads instead of
    /// disappearing. `vehicles` resolves the drive's vehicle for display.
    public func recoverInterrupted(vehicles: [Vehicle] = [], now: Date = .now) async {
        guard phase == .idle, var draft = await store.interrupted(), draft.ownerID == ownerID else { return }
        let lastFix = draft.samples.last?.timestamp ?? draft.startedAt
        if now.timeIntervalSince(lastFix) <= Self.resumeWindow,
           now.timeIntervalSince(draft.startedAt) < Self.maximumDuration {
            let provider = makeProvider()
            if provider.permission == .authorized {
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
        }
        let end = min(lastFix, Self.limit(of: draft))
        Self.trim(&draft, after: end)
        draft.endedAt = end
        try? await store.save(draft)
        recoveredDrive = draft.startedAt
        await syncPending()
    }

    public func dismissRecoveryNotice() { recoveredDrive = nil }

    private func refreshPendingCount() async {
        guard let ownerID else {
            pendingUploads = 0
            return
        }
        pendingUploads = await store.pendingUploads().filter { $0.ownerID == ownerID }.count
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
