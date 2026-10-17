import Foundation

/// Speed display unit. Storage and telemetry are always SI (m/s, metres);
/// conversion happens only at the presentation edge.
public enum SpeedUnit: String, Codable, CaseIterable, Sendable, Identifiable {
    case mph
    case kmh

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mph: "MPH"
        case .kmh: "KM/H"
        }
    }

    public var distanceLabel: String {
        switch self {
        case .mph: "mi"
        case .kmh: "km"
        }
    }

    public var elevationLabel: String {
        switch self {
        case .mph: "ft"
        case .kmh: "m"
        }
    }

    /// Converts metres per second to this unit.
    public func speed(fromMetersPerSecond mps: Double) -> Double {
        switch self {
        case .mph: mps * Conversions.mpsToMph
        case .kmh: mps * Conversions.mpsToKmh
        }
    }

    public func distance(fromMeters meters: Double) -> Double {
        switch self {
        case .mph: meters / Conversions.metersPerMile
        case .kmh: meters / 1000
        }
    }

    public func elevation(fromMeters meters: Double) -> Double {
        switch self {
        case .mph: meters * Conversions.feetPerMeter
        case .kmh: meters
        }
    }

    /// The scale top used by gauges, chosen so typical road speeds sit in the
    /// upper-middle of the sweep rather than pinned at either end.
    public var gaugeMaximum: Double {
        switch self {
        case .mph: 160
        case .kmh: 260
        }
    }
}

public enum Conversions {
    public static let mpsToMph = 2.236_936_292_054_402
    public static let mpsToKmh = 3.6
    public static let metersPerMile = 1_609.344
    public static let feetPerMeter = 3.280_839_895
    /// 60 mph in m/s, the standard acceleration benchmark target.
    public static let sixtyMphInMps = 26.8224
    /// 100 km/h in m/s.
    public static let hundredKmhInMps = 27.777_777_8
}
