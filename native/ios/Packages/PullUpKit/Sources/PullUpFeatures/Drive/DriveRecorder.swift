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
        self.provider = provider
        self.vehicle = vehicle
        remember(vehicle)
        engine = TelemetryEngine(startedAt: now)
        draft = DriveDraft(ownerID: ownerID, vehicleID: vehicle?.id, startedAt: now, title: Drive.defaultTitle(startedAt: now))
        route = []
        live = .empty
        isStationary = false
        interruption = nil
        lastResult = nil
        unsavedSamples = 0
        phase = .recording
        await persistDraft()

        let stream = provider.start()
        streamTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.refreshLive()
            }
        }
        return nil
    }

    private func handle(_ event: LocationEvent) {
        guard phase == .recording, var engine else { return }
        switch event {
        case let .sample(sample):
            let verdict = engine.ingest(sample)
            self.engine = engine
            if verdict == .accepted {
                draft?.samples.append(sample)
                isStationary = false
                appendToRoute(sample.coordinate)
                unsavedSamples += 1
                if unsavedSamples >= 15 { Task { await self.persistDraft() } }
            }
            refreshLive()
        case let .stationary(still):
            isStationary = still
            refreshLive()
        case .unavailable:
            refreshLive()
        case .accuracyReduced:
            interruption = "Precise Location was turned off, so recording stopped. Everything up to that point was kept."
            Task { await self.finish() }
        case .denied:
            interruption = "Location access was turned off, so recording stopped. Everything up to that point was kept."
            Task { await self.finish() }
        }
    }

    private func appendToRoute(_ coordinate: Coordinate) {
        if let last = route.last, last.distance(to: coordinate) < 10 { return }
        route.append(coordinate)
    }

    private func refreshLive(now: Date = .now) {
        guard phase == .recording, let engine else { return }
        var value = engine.live(at: now)
        if isStationary, engine.accepted.last != nil {
            // iOS stops delivering fixes while the phone is still (red light,
            // parked). That's a known zero, not a lost signal.
            value.signalState = .tracking
            value.currentSpeed = 0
            value.currentSpeedIsDerived = false
            value.isMoving = false
            value.rollingAverageSpeed = value.rollingAverageSpeed ?? 0
        }
        live = value
    }

    private func persistDraft() async {
        guard let draft else { return }
        unsavedSamples = 0
        try? await store.save(draft)
    }

    /// Stops recording and produces the summary. Uploads when worth keeping;
    /// otherwise discards the local copy.
    @discardableResult
    public func finish() async -> FinishedDrive? {
        guard phase == .recording, let engine, var draft else { return nil }
        phase = .finishing
        streamTask?.cancel()
        tickTask?.cancel()
        provider?.stop()
        provider = nil

        let end = Date()
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
    }

    static func isWorthKeeping(_ summary: DriveSummary) -> Bool {
        summary.acceptedSamples >= minimumSamples && summary.distanceMeters >= minimumDistance
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
        for draft in await store.pendingUploads() where draft.ownerID == ownerID {
            guard let end = draft.endedAt else { continue }
            let engine = TelemetryEngine.replay(draft.samples, startedAt: draft.startedAt)
            let summary = engine.summary(endedAt: end)
            guard Self.isWorthKeeping(summary) else {
                await store.delete(draft.id)
                continue
            }
            _ = await upload(draft, drive: Self.makeDrive(from: draft, summary: summary))
        }
        await refreshPendingCount()
    }

    /// Finalises a recording that was cut short by the app being killed, so
    /// that it uploads instead of disappearing.
    public func recoverInterrupted() async {
        guard phase == .idle, var draft = await store.interrupted(), draft.ownerID == ownerID else { return }
        draft.endedAt = draft.samples.last?.timestamp ?? draft.startedAt
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
