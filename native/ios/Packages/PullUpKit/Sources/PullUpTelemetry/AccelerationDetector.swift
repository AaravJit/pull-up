import Foundation
import PullUpDomain

/// Finds standing-start runs to a target speed (default 60 mph) inside a
/// stream of accepted fixes.
///
/// Phone GPS reports Doppler speed about once per second, so a 5 s run has
/// maybe six readings. Crossing times are linearly interpolated at both ends
/// and every result is labelled an estimate unless the run was dense and
/// accurate throughout. Even then it is "GPS consistent", never "measured".
public struct AccelerationDetector: Sendable {
    public struct Configuration: Sendable {
        public var targetSpeed: Double = Conversions.sixtyMphInMps
        /// At or below this the vehicle counts as standing still (1 mph).
        public var standstillSpeed: Double = 0.45
        /// A gap longer than this aborts a run in progress.
        public var maxIntervalForEstimate: Double = 2.0
        /// Gaps up to this, with tight speed accuracy, earn `.consistent`.
        public var maxIntervalForConsistent: Double = 1.1
        public var maxSpeedAccuracyForConsistent: Double = 1.0
        /// A drop of more than this from the run's peak means the driver
        /// lifted; the run is abandoned.
        public var maxSpeedDrop: Double = 1.5
        /// No production vehicle does 0–60 in under ~1.9 s; faster results are
        /// treated as artefacts.
        public var minimumPlausibleDuration: Double = 1.9
        public var maximumDuration: Double = 40

        public init() {}
    }

    private struct Run: Sendable {
        var start: Date
        var last: LocationSample
        var peak: Double
        var maxInterval: Double
        var maxSpeedAccuracy: Double
        var samples: Int
    }

    public let configuration: Configuration
    private var lastStill: LocationSample?
    private var run: Run?
    public private(set) var best: AccelerationRun?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Feed accepted samples in order. Returns a run when one completes.
    @discardableResult
    public mutating func ingest(_ sample: LocationSample) -> AccelerationRun? {
        guard sample.hasValidSpeed else {
            abort()
            return nil
        }

        if sample.speed <= configuration.standstillSpeed {
            run = nil
            lastStill = sample
            return nil
        }

        if var current = run {
            let dt = sample.timestamp.timeIntervalSince(current.last.timestamp)
            guard dt > 0, dt <= configuration.maxIntervalForEstimate,
                  sample.speed >= current.peak - configuration.maxSpeedDrop,
                  sample.timestamp.timeIntervalSince(current.start) <= configuration.maximumDuration
            else {
                abort()
                return nil
            }
            current.maxInterval = max(current.maxInterval, dt)
            current.maxSpeedAccuracy = max(current.maxSpeedAccuracy, sample.speedAccuracy)
            current.samples += 1

            if sample.speed >= configuration.targetSpeed {
                let crossing = Self.interpolate(from: current.last, to: sample, at: configuration.targetSpeed)
                let duration = crossing.timeIntervalSince(current.start)
                run = nil
                lastStill = nil
                return finish(start: current.start, duration: duration, current: current)
            }
            current.peak = max(current.peak, sample.speed)
            current.last = sample
            run = current
            return nil
        }

        // Not in a run: one can only begin right after a standstill fix.
        guard let still = lastStill else { return nil }
        let dt = sample.timestamp.timeIntervalSince(still.timestamp)
        guard dt > 0, dt <= configuration.maxIntervalForEstimate else {
            lastStill = nil
            return nil
        }
        let start = Self.interpolate(from: still, to: sample, at: configuration.standstillSpeed)
        let current = Run(
            start: start, last: sample, peak: sample.speed, maxInterval: dt,
            maxSpeedAccuracy: max(still.speedAccuracy, sample.speedAccuracy), samples: 2
        )
        if sample.speed >= configuration.targetSpeed {
            // Standstill to target in one interval; `finish` rejects it as implausible.
            lastStill = nil
            let crossing = Self.interpolate(from: still, to: sample, at: configuration.targetSpeed)
            return finish(start: start, duration: crossing.timeIntervalSince(start), current: current)
        }
        run = current
        return nil
    }

    private mutating func abort() {
        run = nil
        lastStill = nil
    }

    private mutating func finish(start: Date, duration: Double, current: Run) -> AccelerationRun? {
        guard duration >= configuration.minimumPlausibleDuration else { return nil }
        let consistent = current.maxInterval <= configuration.maxIntervalForConsistent
            && current.maxSpeedAccuracy <= configuration.maxSpeedAccuracyForConsistent
            && current.samples >= 4
        let result = AccelerationRun(
            startedAt: start, duration: duration, targetSpeed: configuration.targetSpeed,
            quality: consistent ? .consistent : .estimate, maxSampleInterval: current.maxInterval
        )
        // A consistent run always beats an estimate; within a quality, faster wins.
        let isBetter = best.map { result.quality > $0.quality || (result.quality == $0.quality && result.duration < $0.duration) } ?? true
        if isBetter { best = result }
        return result
    }

    /// Time at which speed crossed `target` between two fixes, assuming
    /// constant acceleration across the interval.
    static func interpolate(from a: LocationSample, to b: LocationSample, at target: Double) -> Date {
        let dv = b.speed - a.speed
        guard dv > 0 else { return b.timestamp }
        let fraction = min(1, max(0, (target - a.speed) / dv))
        return a.timestamp.addingTimeInterval(b.timestamp.timeIntervalSince(a.timestamp) * fraction)
    }
}
