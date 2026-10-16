import Foundation
import PullUpDomain

/// Presentation formatting. Telemetry stays SI; this is the only place
/// numbers become strings, so precision rules live in one spot:
///   * speeds are whole numbers (phone GPS is not good to a decimal place)
///   * distances get one decimal below 100 units, none above
///   * 0–60 gets one decimal and is always labelled as an estimate elsewhere
enum Format {
    static let placeholder = "––"

    static func speed(_ mps: Double?, _ unit: SpeedUnit) -> String {
        guard let mps else { return placeholder }
        return String(Int(unit.speed(fromMetersPerSecond: mps).rounded()))
    }

    static func distance(_ meters: Double, _ unit: SpeedUnit) -> String {
        let value = unit.distance(fromMeters: meters)
        return value < 100 ? value.formatted(.number.precision(.fractionLength(1))) : value.formatted(.number.precision(.fractionLength(0)))
    }

    static func elevation(_ meters: Double?, _ unit: SpeedUnit) -> String {
        guard let meters else { return placeholder }
        return Int(unit.elevation(fromMeters: meters).rounded()).formatted()
    }

    static func accuracy(_ meters: Double?, _ unit: SpeedUnit) -> String {
        guard let meters else { return placeholder }
        return String(Int(unit.elevation(fromMeters: meters).rounded()))
    }

    /// 1:05:09 or 5:09.
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Spoken form for VoiceOver: "1 hour, 5 minutes".
    static func spokenDuration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: max(0, seconds)) ?? ""
    }

    static func zeroToSixty(_ seconds: Double?) -> String {
        guard let seconds else { return placeholder }
        return seconds.formatted(.number.precision(.fractionLength(1)))
    }

    static func heading(_ degrees: Double?) -> String {
        guard let degrees else { return placeholder }
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees.truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
        return points[index]
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func compactCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    /// The detector measures 0–60 mph only, so the label never changes with
    /// the display unit (0–100 km/h would be a different, unmeasured run).
    static let zeroToSixtyLabel = "0–60 mph"
}

extension Drive {
    /// Default title from the time of day the drive started.
    static func defaultTitle(startedAt: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: startedAt) {
        case 5..<12: "Morning drive"
        case 12..<17: "Afternoon drive"
        case 17..<21: "Evening drive"
        default: "Night drive"
        }
    }
}
