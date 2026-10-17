import Foundation
import PullUpDomain

/// What the live dashboard renders. Every speed is m/s; `nil` means "don't
/// show a number" rather than zero.
public struct LiveTelemetry: Equatable, Sendable {
    public enum SignalState: Equatable, Sendable {
        case acquiring
        case tracking
        /// No accepted fix for longer than the gap threshold.
        case lost(since: Date)
    }

    public var currentSpeed: Double?
    /// True when `currentSpeed` came from position deltas rather than Doppler.
    public var currentSpeedIsDerived: Bool
    public var topSpeed: Double?
    public var averageMovingSpeed: Double?
    /// Time-weighted average over the trailing window (30 s).
    public var rollingAverageSpeed: Double?
    public var distanceMeters: Double
    public var elapsedSeconds: Double
    public var movingSeconds: Double
    public var stoppedSeconds: Double
    public var altitude: Double?
    public var elevationGain: Double
    public var elevationLoss: Double
    public var horizontalAccuracy: Double?
    public var signal: SignalQuality
    public var signalState: SignalState
    public var zeroToSixty: AccelerationRun?
    public var isMoving: Bool
    public var heading: Double?

    public static let empty = LiveTelemetry(
        currentSpeed: nil, currentSpeedIsDerived: false, topSpeed: nil, averageMovingSpeed: nil,
        rollingAverageSpeed: nil, distanceMeters: 0, elapsedSeconds: 0, movingSeconds: 0, stoppedSeconds: 0,
        altitude: nil, elevationGain: 0, elevationLoss: 0, horizontalAccuracy: nil, signal: .none,
        signalState: .acquiring, zeroToSixty: nil, isMoving: false, heading: nil
    )
}

/// One point on the post-drive speed chart.
public struct SpeedPoint: Codable, Hashable, Sendable {
    public var offset: Double // seconds since drive start
    public var speed: Double  // m/s
    public var altitude: Double?

    public init(offset: Double, speed: Double, altitude: Double?) {
        self.offset = offset
        self.speed = speed
        self.altitude = altitude
    }
}

/// Turns a stream of raw fixes into drive statistics. A value type with no
/// clock or I/O of its own: callers pass time in, which makes every rule
/// deterministic under test and replayable from a stored track.
public struct TelemetryEngine: Sendable {
    public struct Configuration: Sendable {
        /// No accepted fix for longer than this is a signal gap.
        public var gapThreshold: Double = 10
        /// Hysteresis for moving / stopped (m/s): 1.3 ≈ 3 mph, 0.6 ≈ 1.3 mph.
        public var startMovingSpeed: Double = 1.3
        public var stopMovingSpeed: Double = 0.6
        /// Doppler readings with worse accuracy don't count toward top speed.
        public var maxSpeedAccuracyForTop: Double = 2.5
        public var maxVerticalAccuracy: Double = 15
        /// Altitude change needed before it counts as gain or loss.
        public var elevationHysteresis: Double = 3
        public var elevationSmoothing: Double = 0.35
        public var rollingWindow: Double = 30

        public init() {}
    }

    public let configuration: Configuration
    public let startedAt: Date
    private let filter: SampleFilter
    private var accelerations: AccelerationDetector

    public private(set) var accepted: [LocationSample] = []
    public private(set) var rejectionCounts: [RejectionReason: Int] = [:]
    public private(set) var speedSeries: [SpeedPoint] = []

    private var last: LocationSample?
    private var distanceAnchor: LocationSample?
    private var distance: Double = 0
    private var gapDistance: Double = 0
    private var moving: Double = 0
    private var longestGap: Double = 0
    private var isMoving = false
    private var recentSpeeds: [Double] = []
    private var topSpeed: Double?
    private var rolling: [(Date, Double)] = []
    private var smoothedAltitude: Double?
    private var elevationBaseline: Double?
    private var gain: Double = 0
    private var loss: Double = 0
    private var minAltitude: Double?
    private var maxAltitude: Double?
    private var currentSpeed: Double?
    private var currentSpeedDerived = false

    public init(startedAt: Date, configuration: Configuration = .init(), filter: SampleFilter = .init()) {
        self.startedAt = startedAt
        self.configuration = configuration
        self.filter = filter
        self.accelerations = AccelerationDetector()
    }

    public var rejectedCount: Int { rejectionCounts.values.reduce(0, +) }

    @discardableResult
    public mutating func ingest(_ sample: LocationSample) -> SampleVerdict {
        // Fixes from before the user pressed start are cached readings.
        guard sample.timestamp >= startedAt.addingTimeInterval(-1) else {
            rejectionCounts[.outOfOrder, default: 0] += 1
            return .rejected(.outOfOrder)
        }
        let verdict = filter.evaluate(sample, previous: last)
        guard verdict == .accepted else {
            if case let .rejected(reason) = verdict { rejectionCounts[reason, default: 0] += 1 }
            return verdict
        }

        if let previous = last {
            integrate(from: previous, to: sample)
        } else {
            distanceAnchor = sample
            currentSpeed = sample.hasValidSpeed ? sample.speed : nil
            currentSpeedDerived = false
        }

        trackTopSpeed(sample)
        trackRolling(sample)
        trackElevation(sample)
        accelerations.ingest(sample)

        accepted.append(sample)
        speedSeries.append(SpeedPoint(
            offset: sample.timestamp.timeIntervalSince(startedAt),
            speed: max(0, currentSpeed ?? 0),
            altitude: smoothedAltitude
        ))
        last = sample
        return .accepted
    }

    private mutating func integrate(from previous: LocationSample, to sample: LocationSample) {
        let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
        let segment = previous.coordinate.distance(to: sample.coordinate)

        if dt > configuration.gapThreshold {
            // Bridge the gap with a straight line: a lower bound on true
            // distance, recorded separately so it can be disclosed.
            longestGap = max(longestGap, dt)
            distance += segment
            gapDistance += segment
            if segment / dt >= configuration.startMovingSpeed { moving += dt }
            distanceAnchor = sample
            currentSpeed = sample.hasValidSpeed ? sample.speed : nil
            currentSpeedDerived = false
            isMoving = (currentSpeed ?? 0) >= configuration.startMovingSpeed
            return
        }

        let impliedSpeed = segment / dt
        let speed: Double
        if sample.hasValidSpeed {
            speed = sample.speed
            currentSpeedDerived = false
        } else {
            speed = impliedSpeed
            currentSpeedDerived = true
        }
        currentSpeed = speed

        if isMoving {
            if speed < configuration.stopMovingSpeed { isMoving = false }
        } else if speed >= configuration.startMovingSpeed {
            isMoving = true
        }
        if isMoving { moving += dt }

        // While parked, GPS wanders inside its error radius. Only count
        // displacement from the last anchor that clearly exceeds that error.
        guard let anchor = distanceAnchor else { return }
        let fromAnchor = anchor.coordinate.distance(to: sample.coordinate)
        if isMoving || fromAnchor > max(5, sample.horizontalAccuracy + anchor.horizontalAccuracy) {
            distance += isMoving ? segment : fromAnchor
            distanceAnchor = sample
        }
    }

    private mutating func trackTopSpeed(_ sample: LocationSample) {
        guard sample.hasValidSpeed, sample.speedAccuracy <= configuration.maxSpeedAccuracyForTop else {
            recentSpeeds.removeAll()
            return
        }
        recentSpeeds.append(sample.speed)
        if recentSpeeds.count > 3 { recentSpeeds.removeFirst() }
        // Median of three consecutive readings: a single spike can never
        // become the top speed.
        guard recentSpeeds.count == 3 else { return }
        let median = recentSpeeds.sorted()[1]
        topSpeed = max(topSpeed ?? 0, median)
    }

    private mutating func trackRolling(_ sample: LocationSample) {
        guard let speed = currentSpeed else { return }
        rolling.append((sample.timestamp, speed))
        let cutoff = sample.timestamp.addingTimeInterval(-configuration.rollingWindow)
        rolling.removeAll { $0.0 < cutoff }
    }

    private var rollingAverage: Double? {
        guard rolling.count >= 2, let first = rolling.first, let lastPoint = rolling.last else {
            return rolling.first?.1
        }
        let span = lastPoint.0.timeIntervalSince(first.0)
        guard span > 0 else { return lastPoint.1 }
        var area = 0.0
        for i in 1..<rolling.count {
            let dt = rolling[i].0.timeIntervalSince(rolling[i - 1].0)
            area += (rolling[i].1 + rolling[i - 1].1) / 2 * dt
        }
        return area / span
    }

    private mutating func trackElevation(_ sample: LocationSample) {
        guard sample.hasValidAltitude, sample.verticalAccuracy <= configuration.maxVerticalAccuracy else { return }
        let smoothed: Double
        if let previous = smoothedAltitude {
            smoothed = previous + configuration.elevationSmoothing * (sample.altitude - previous)
        } else {
            smoothed = sample.altitude
        }
        smoothedAltitude = smoothed
        minAltitude = min(minAltitude ?? smoothed, smoothed)
        maxAltitude = max(maxAltitude ?? smoothed, smoothed)

        guard let baseline = elevationBaseline else {
            elevationBaseline = smoothed
            return
        }
        let delta = smoothed - baseline
        if delta >= configuration.elevationHysteresis {
            gain += delta
            elevationBaseline = smoothed
        } else if delta <= -configuration.elevationHysteresis {
            loss += -delta
            elevationBaseline = smoothed
        }
    }

    /// Snapshot for the HUD at wall-clock time `now`.
    public func live(at now: Date) -> LiveTelemetry {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let state: LiveTelemetry.SignalState
        if let last {
            let silence = now.timeIntervalSince(last.timestamp)
            state = silence > configuration.gapThreshold ? .lost(since: last.timestamp) : .tracking
        } else {
            state = .acquiring
        }
        let tracking = state == .tracking
        return LiveTelemetry(
            currentSpeed: tracking ? currentSpeed.map { max(0, $0) } : nil,
            currentSpeedIsDerived: currentSpeedDerived,
            topSpeed: topSpeed,
            averageMovingSpeed: moving > 5 ? distance / moving : nil,
            rollingAverageSpeed: tracking ? rollingAverage : nil,
            distanceMeters: distance,
            elapsedSeconds: elapsed,
            movingSeconds: moving,
            stoppedSeconds: max(0, elapsed - moving),
            altitude: smoothedAltitude,
            elevationGain: gain,
            elevationLoss: loss,
            horizontalAccuracy: tracking ? last?.horizontalAccuracy : nil,
            signal: tracking ? SignalQuality(horizontalAccuracy: last?.horizontalAccuracy) : .none,
            signalState: state,
            zeroToSixty: accelerations.best,
            isMoving: tracking && isMoving,
            heading: tracking ? last.flatMap { $0.course >= 0 ? $0.course : nil } : nil
        )
    }

    public func summary(endedAt: Date) -> DriveSummary {
        let elapsed = max(0, endedAt.timeIntervalSince(startedAt))
        return DriveSummary(
            startedAt: startedAt,
            endedAt: endedAt,
            distanceMeters: distance,
            gapDistanceMeters: gapDistance,
            elapsedSeconds: elapsed,
            movingSeconds: moving,
            stoppedSeconds: max(0, elapsed - moving),
            topSpeed: topSpeed,
            averageMovingSpeed: moving > 5 ? distance / moving : nil,
            elevationGain: gain,
            elevationLoss: loss,
            minAltitude: minAltitude,
            maxAltitude: maxAltitude,
            zeroToSixty: accelerations.best,
            acceptedSamples: accepted.count,
            rejectedSamples: rejectedCount,
            longestSignalGap: longestGap
        )
    }

    /// Rebuild an engine from a stored track (crash recovery, re-analysis).
    public static func replay(_ samples: [LocationSample], startedAt: Date, configuration: Configuration = .init()) -> TelemetryEngine {
        var engine = TelemetryEngine(startedAt: startedAt, configuration: configuration)
        for sample in samples { engine.ingest(sample) }
        return engine
    }
}
