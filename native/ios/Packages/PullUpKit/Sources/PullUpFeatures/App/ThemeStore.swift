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
    /// 2: the 1.0 identity (electric blue default, OLED Black).
    nonisolated static let currentVersion = 2

    /// What's saved. Every field decodes on its own, so one value this
    /// version doesn't know (or a missing one) falls back to its default
    /// instead of throwing the whole theme away.
    struct Stored: Codable, Equatable {
        var version: Int
        var accent: AccentChoice?
        var appearance: AppearancePreference?
        var speedometer: SpeedometerStyle?
        var unit: SpeedUnit?
        var dashboard: [DashboardMetric]?

        init(version: Int, accent: AccentChoice?, appearance: AppearancePreference?, speedometer: SpeedometerStyle?,
             unit: SpeedUnit?, dashboard: [DashboardMetric]?) {
            self.version = version
            self.accent = accent
            self.appearance = appearance
            self.speedometer = speedometer
            self.unit = unit
            self.dashboard = dashboard
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Themes saved before 1.0 have no version.
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            accent = try? c.decodeIfPresent(AccentChoice.self, forKey: .accent)
            appearance = try? c.decodeIfPresent(AppearancePreference.self, forKey: .appearance)
            speedometer = try? c.decodeIfPresent(SpeedometerStyle.self, forKey: .speedometer)
            unit = try? c.decodeIfPresent(SpeedUnit.self, forKey: .unit)
            if let raw = try? c.decodeIfPresent([String].self, forKey: .dashboard) {
                dashboard = raw.compactMap(DashboardMetric.init(rawValue:))
            }
        }

        /// Brings an older theme up to date. Sodium was the default accent
        /// before 1.0 and almost nobody picked it on purpose, so it becomes
        /// electric blue once; a person can choose Sodium again afterwards.
        /// Everything else they chose is kept.
        func migrated() -> Stored {
            var next = self
            if version < 2, accent == .sodium { next.accent = .defaultAccent }
            next.version = ThemeStore.currentVersion
            return next
        }
    }

    public init(defaults: UserDefaults = .standard, override appearance: AppearancePreference? = nil) {
        self.defaults = defaults
        var theme = ClusterTheme(unit: Locale.current.measurementSystem == .metric ? .kmh : .mph)
        var needsSave = false
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            let stored = decoded.migrated()
            needsSave = stored != decoded
            if let accent = stored.accent { theme.accent = accent }
            if let appearance = stored.appearance { theme.appearance = appearance }
            if let speedometer = stored.speedometer { theme.speedometer = speedometer }
            if let unit = stored.unit { theme.unit = unit }
            if let dashboard = stored.dashboard {
                theme.dashboard = Array(dashboard.filter { DashboardMetric.liveSelectable.contains($0) }.prefix(DashboardMetric.maximumCount))
            }
        }
        chosen = theme
        proUnlocked = defaults.bool(forKey: Self.proKey)
        // The launch override (UI tests, screenshots) isn't a choice, so
        // it isn't written back.
        if needsSave { save() }
        if let appearance { chosen.appearance = appearance }
    }

    private func save() {
        let theme = chosen
        let stored = Stored(version: Self.currentVersion, accent: theme.accent, appearance: theme.appearance,
                            speedometer: theme.speedometer, unit: theme.unit, dashboard: theme.dashboard)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}
