import SwiftUI
import PullUpDomain

/// System, Light or OLED Black. The raw values are what's stored, so
/// `dark` (saved by earlier versions) now means OLED Black.
public enum AppearancePreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "OLED Black"
        }
    }

    public var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public enum SpeedometerStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 270° sweep with a needle, tick scale and redline band.
    case analog
    /// Large compressed numerals with a segmented bar beneath.
    case digital
    /// Horizontal moving tape, like an aircraft HUD speed tape.
    case tape
    /// Open ring that fills with speed. Pull Up Pro.
    case ring

    public var id: String { rawValue }
    public var isPro: Bool { self == .ring }
    public var label: String {
        switch self {
        case .analog: "Sweep"
        case .digital: "Digital"
        case .tape: "Tape"
        case .ring: "Ring"
        }
    }
}

/// Metrics the user can place on the drive dashboard.
public enum DashboardMetric: String, Codable, CaseIterable, Sendable, Identifiable {
    case topSpeed, averageSpeed, rollingAverage, distance, elapsed, movingTime, stoppedTime
    case altitude, elevationGain, elevationLoss, zeroToSixty, gpsAccuracy, heading

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .topSpeed: "Top"
        case .averageSpeed: "Avg moving"
        case .rollingAverage: "30 s avg"
        case .distance: "Distance"
        case .elapsed: "Elapsed"
        case .movingTime: "Moving"
        case .stoppedTime: "Stopped"
        case .altitude: "Altitude"
        case .elevationGain: "Climb"
        case .elevationLoss: "Descent"
        case .zeroToSixty: "0–60 est."
        case .gpsAccuracy: "GPS ±"
        case .heading: "Heading"
        }
    }

    /// What the live dashboard offers. A running 0–60 readout while driving
    /// would invite launches on public roads, so 0–60 appears only after a
    /// drive, as an estimate (DriveSummaryView).
    public static let liveSelectable = allCases.filter { $0 != .zeroToSixty }

    public static let defaultLayout: [DashboardMetric] = [.distance, .elapsed, .topSpeed, .averageSpeed, .elevationGain, .gpsAccuracy]
    public static let maximumCount = 6
}

/// User-tunable look. Persisted by the app shell; read through the environment.
public struct ClusterTheme: Equatable, Sendable {
    public var accent: AccentChoice
    public var appearance: AppearancePreference
    public var speedometer: SpeedometerStyle
    public var unit: SpeedUnit
    public var dashboard: [DashboardMetric]

    public init(
        accent: AccentChoice = .defaultAccent, appearance: AppearancePreference = .system,
        speedometer: SpeedometerStyle = .analog, unit: SpeedUnit = .mph,
        dashboard: [DashboardMetric] = DashboardMetric.defaultLayout
    ) {
        self.accent = accent
        self.appearance = appearance
        self.speedometer = speedometer
        self.unit = unit
        self.dashboard = dashboard
    }

    public var accentColor: Color { ClusterColor.accent(accent) }
    /// Behind primary buttons and badges.
    public var accentFill: Color { ClusterColor.accentFill(accent) }
    /// Text and icons on `accentFill`.
    public var onAccent: Color { ClusterColor.textOnAccent(accent) }

    /// The same theme with Pro-only choices swapped for the defaults, shown
    /// while Pro isn't active. The person's picks are kept for when it is.
    public var withoutPro: ClusterTheme {
        var theme = self
        if accent.isPro { theme.accent = ClusterTheme().accent }
        if speedometer.isPro { theme.speedometer = ClusterTheme().speedometer }
        return theme
    }
}

private struct ClusterThemeKey: EnvironmentKey {
    static let defaultValue = ClusterTheme()
}

public extension EnvironmentValues {
    var clusterTheme: ClusterTheme {
        get { self[ClusterThemeKey.self] }
        set { self[ClusterThemeKey.self] = newValue }
    }
}

public extension AccentChoice {
    /// Electric blue. Stored as `gulf`, the identifier the server already
    /// accepts for profile and vehicle colours.
    static let defaultAccent: AccentChoice = .gulf
}

public extension View {
    /// Applies the theme: accent tint, appearance override, canvas colour.
    func clusterTheme(_ theme: ClusterTheme) -> some View {
        environment(\.clusterTheme, theme)
            .tint(theme.accentColor)
            .preferredColorScheme(theme.appearance.colorScheme)
    }
}
