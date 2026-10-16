import Foundation
import Observation
import PullUpDesign
import PullUpDomain

/// Persists the user's look-and-feel choices on this device. These are
/// display preferences, not account data, so they stay in UserDefaults.
@MainActor
@Observable
public final class ThemeStore {
    public var theme: ClusterTheme {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private static let key = "pullup.theme.v1"

    private struct Stored: Codable {
        var accent: AccentChoice
        var appearance: AppearancePreference
        var speedometer: SpeedometerStyle
        var unit: SpeedUnit
        var dashboard: [DashboardMetric]
    }

    public init(defaults: UserDefaults = .standard, override appearance: AppearancePreference? = nil) {
        self.defaults = defaults
        var theme = ClusterTheme(unit: Locale.current.measurementSystem == .metric ? .kmh : .mph)
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            theme = ClusterTheme(
                accent: stored.accent, appearance: stored.appearance, speedometer: stored.speedometer,
                unit: stored.unit, dashboard: Array(stored.dashboard.prefix(DashboardMetric.maximumCount))
            )
        }
        if let appearance { theme.appearance = appearance }
        self.theme = theme
    }

    private func save() {
        let stored = Stored(accent: theme.accent, appearance: theme.appearance, speedometer: theme.speedometer, unit: theme.unit, dashboard: theme.dashboard)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}
