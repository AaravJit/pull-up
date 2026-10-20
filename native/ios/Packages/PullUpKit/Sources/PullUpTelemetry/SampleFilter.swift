import Foundation
import PullUpDomain

/// Why a fix was thrown away. Counted per drive so that the summary can say
/// how clean the data was, and so the server can cross-check.
public enum RejectionReason: String, Sendable, CaseIterable {
    case invalidAccuracy
    case poorAccuracy
    case outOfOrder
    case duplicate
    case implausibleJump
    case implausibleAcceleration
}

public enum SampleVerdict: Equatable, Sendable {
    case accepted
    case rejected(RejectionReason)
}

/// Stateless gatekeeper for raw fixes. Thresholds are deliberately
/// conservative: a dropped good fix costs a second of resolution, an accepted
/// bad fix can add a phantom 140 mph top speed.
public struct SampleFilter: Sendable {
    public struct Configuration: Sendable {
        /// Fixes with worse horizontal accuracy are discarded outright.
        /// Cell/Wi-Fi fixes (≥ 65 m) never pass.
        public var maxHorizontalAccuracy: Double = 35
        /// No production road vehicle sustains this; anything faster between
        /// two fixes is a position jump.
        public var maxPlausibleSpeed: Double = 120 // m/s ≈ 268 mph
        /// Peak sustained longitudinal acceleration of very fast road cars is
        /// ~1.3 g. Above 1.6 g between Doppler readings is a sensor glitch.
        public var maxPlausibleAcceleration: Double = 16 // m/s²
        /// Between fixes this close together, the position can't have moved
        /// further than Doppler speed allows, plus this slack and both
        /// accuracy radii. Longer intervals (tunnels) skip the check, since
        /// the car may have sped up and slowed down in between.
        public var dopplerSlack: Double = 2 // m/s
        public var maxIntervalForDopplerCheck: Double = 5

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func evaluate(_ sample: LocationSample, previous: LocationSample?) -> SampleVerdict {
        guard sample.horizontalAccuracy >= 0,
              sample.latitude.isFinite, sample.longitude.isFinite,
              abs(sample.latitude) <= 90, abs(sample.longitude) <= 180
        else { return .rejected(.invalidAccuracy) }

        guard sample.horizontalAccuracy <= configuration.maxHorizontalAccuracy else {
            return .rejected(.poorAccuracy)
        }

        guard let previous else { return .accepted }

        let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
        if dt < 0 { return .rejected(.outOfOrder) }
        if dt == 0 { return .rejected(.duplicate) }

        // Position jump: implied speed between fixes, with the combined
        // accuracy radius forgiven so that two honest fixes 1 s apart with
        // 10 m error each are not treated as 20 m/s of motion.
        let distance = previous.coordinate.distance(to: sample.coordinate)
        let forgiven = max(0, distance - previous.horizontalAccuracy - sample.horizontalAccuracy)
        if forgiven / dt > configuration.maxPlausibleSpeed {
            return .rejected(.implausibleJump)
        }

        // Multipath: a fix reflected off a building can land 30–60 m away
        // while the car sits at a red light. The implied speed looks
        // possible, but Doppler (measured independently of position) says
        // the car can't have got there. Each reading's own uncertainty is
        // allowed for, so a near-zero speed iOS isn't sure of can't reject
        // honest fixes from a moving car.
        if previous.hasValidSpeed, sample.hasValidSpeed, dt <= configuration.maxIntervalForDopplerCheck {
            let fastest = max(previous.speed + previous.speedAccuracy, sample.speed + sample.speedAccuracy)
            let reach = (fastest + configuration.dopplerSlack) * dt
                + previous.horizontalAccuracy + sample.horizontalAccuracy
            if distance > reach { return .rejected(.implausibleJump) }
        }

        if previous.hasValidSpeed, sample.hasValidSpeed {
            let dv = abs(sample.speed - previous.speed)
            let tolerance = previous.speedAccuracy + sample.speedAccuracy
            if max(0, dv - tolerance) / dt > configuration.maxPlausibleAcceleration {
                return .rejected(.implausibleAcceleration)
            }
        }

        return .accepted
    }
}

/// Signal quality bucketed from horizontal accuracy, for the live HUD.
public enum SignalQuality: Int, Sendable, Comparable, CaseIterable {
    case none = 0
    case poor
    case fair
    case good
    case excellent

    public init(horizontalAccuracy: Double?) {
        guard let accuracy = horizontalAccuracy, accuracy >= 0 else {
            self = .none
            return
        }
        switch accuracy {
        case ...5: self = .excellent
        case ...12: self = .good
        case ...25: self = .fair
        default: self = .poor
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .none: "No GPS"
        case .poor: "Weak"
        case .fair: "Fair"
        case .good: "Good"
        case .excellent: "Strong"
        }
    }

    /// Bars lit on a four-bar indicator.
    public var bars: Int { rawValue }
}
