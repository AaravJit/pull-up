import Foundation
import PullUpDomain

/// What a location source reports while a drive is recording.
public enum LocationEvent: Sendable, Equatable {
    case sample(LocationSample)
    /// iOS paused updates because the device is not moving (red light,
    /// parked). Not a signal loss.
    case stationary(Bool)
    /// No fix available (tunnel, parking garage).
    case unavailable
    /// The updates stream ended or failed and is being started again. What
    /// happens until the next fix is unknown, even if iOS had said the
    /// phone was still.
    case restarting
    /// The user granted approximate location only. Telemetry is not
    /// possible at ~1 km accuracy, so recording must stop and say why.
    case accuracyReduced
    case denied

    /// The events for one Core Location update, in the order the recorder
    /// needs them. iOS's last update before it pauses carries both a fix and
    /// the stationary flag; the fix goes first, or ingesting it would clear
    /// the pause and the stop would look like lost signal. For the same
    /// reason the pause is reapplied after any further fix iOS delivers
    /// while still paused. When moving again, the pause ends before the fix
    /// that follows it.
    public static func forUpdate(
        location: LocationSample?, stationary: Bool, locationUnavailable: Bool, wasStationary: Bool
    ) -> [LocationEvent] {
        var events: [LocationEvent] = []
        if !stationary, wasStationary { events.append(.stationary(false)) }
        if let location {
            events.append(.sample(location))
        } else if locationUnavailable {
            events.append(.unavailable)
        }
        if stationary, !wasStationary || location != nil { events.append(.stationary(true)) }
        return events
    }
}

public enum LocationPermission: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    /// Granted, but only approximate location.
    case reducedAccuracy
    case authorized
}

/// Abstracts the location source so the recorder can run against Core
/// Location on a device, or against a replayed track in previews, UI tests
/// and the simulator.
@MainActor
public protocol LocationProvider: AnyObject {
    var permission: LocationPermission { get }
    /// Asks for When-In-Use permission if undecided. Returns the outcome.
    func requestPermission() async -> LocationPermission
    /// Starts updates. Background continuation is requested only here, i.e.
    /// only while the user is actively recording a drive.
    func start() -> AsyncStream<LocationEvent>
    func stop()
}

/// Replays a stored track in real time with timestamps re-based to "now".
/// Used for demo mode and UI tests; never selected on a device with a real
/// server.
@MainActor
public final class ReplayLocationProvider: LocationProvider {
    private let samples: [LocationSample]
    private let speedMultiplier: Double
    private var task: Task<Void, Never>?

    public init(samples: [LocationSample], speedMultiplier: Double = 1) {
        self.samples = samples
        self.speedMultiplier = max(0.1, speedMultiplier)
    }

    public var permission: LocationPermission { .authorized }
    public func requestPermission() async -> LocationPermission { .authorized }

    public func start() -> AsyncStream<LocationEvent> {
        let samples = samples
        let multiplier = speedMultiplier
        return AsyncStream { continuation in
            let task = Task {
                guard let first = samples.first else {
                    continuation.finish()
                    return
                }
                let origin = Date()
                for sample in samples {
                    let offset = sample.timestamp.timeIntervalSince(first.timestamp)
                    let due = origin.addingTimeInterval(offset / multiplier)
                    let wait = due.timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    if Task.isCancelled { break }
                    var rebased = sample
                    rebased.timestamp = origin.addingTimeInterval(offset)
                    continuation.yield(.sample(rebased))
                }
                continuation.finish()
            }
            self.task = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
