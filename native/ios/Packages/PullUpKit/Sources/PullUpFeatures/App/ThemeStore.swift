import Foundation
import Observation
import PullUpDesign
import PullUpDomain

/// Persists the user's look-and-feel choices on this device. These are
/// display preferences, not account data, so they stay in UserDefaults.
@MainActor
@Observable
public final class ThemeStore {
    /// What the person picked, Pro choices included. Kept while Pro is off so
    /// they come back when it returns.
    public private(set) var chosen: ClusterTheme

    /// Whether Pro looks may be shown. Set from the server's entitlement by
    /// `ProStore`; remembered between launches only to avoid a flash of the
    /// default look. Pro looks are cosmetic, so this hint decides nothing else.
    public var proUnlocked: Bool {
        didSet { defaults.set(proUnlocked, forKey: Self.proKey) }
    }

    /// The theme to render. Pro choices fall back to the defaults while Pro
    /// is off; changing anything else keeps them.
    public var theme: ClusterTheme {
        get { proUnlocked ? chosen : chosen.withoutPro }
        set {
            var next = newValue
            if !proUnlocked {
                let fallback = ClusterTheme()
                if chosen.accent.isPro, next.accent == fallback.accent { next.accent = chosen.accent }
                if chosen.speedometer.isPro, next.speedometer == fallback.speedometer { next.speedometer = chosen.speedometer }
            }
            chosen = next
            save()
        }
    }

    private let defaults: UserDefaults
    private static let key = "pullup.theme.v1"
    private static let proKey = "pullup.pro.hint.v1"

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
        chosen = theme
        proUnlocked = defaults.bool(forKey: Self.proKey)
    }

    private func save() {
        let theme = chosen
        let stored = Stored(accent: theme.accent, appearance: theme.appearance, speedometer: theme.speedometer, unit: theme.unit, dashboard: theme.dashboard)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}
