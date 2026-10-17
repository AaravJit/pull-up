import Foundation
import PullUpDesign

/// Switches read from launch arguments. Used by UI tests, screenshots and
/// developer schemes; none of them can be set by a user on a device, and
/// demo mode is always announced on screen.
public struct LaunchOptions: Sendable, Equatable {
    /// Use the in-memory demo backend instead of Supabase.
    public var demo = false
    /// Demo with an empty garage (picker empty state).
    public var emptyGarage = false
    /// Demo starting signed out (auth screen).
    public var signedOut = false
    /// Demo starting as a new Sign in with Apple account that hasn't onboarded.
    public var onboarding = false
    /// Start from fresh preferences (no remembered vehicle, default theme).
    public var resetDefaults = false
    public var appearance: AppearancePreference?
    /// Tab to open at launch.
    public var initialTab: MainTab?
    /// Acts as if a push was tapped after sign-in: "kind" or "kind:conversation-id".
    public var openPush: String?

    public init() {}

    public static func fromProcess(_ info: ProcessInfo = .processInfo) -> LaunchOptions {
        let args = info.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        var options = LaunchOptions()
        options.demo = args.contains("-PullUpDemo")
        options.emptyGarage = args.contains("-PullUpEmptyGarage")
        options.signedOut = args.contains("-PullUpSignedOut")
        options.onboarding = args.contains("-PullUpOnboarding")
        options.resetDefaults = args.contains("-PullUpResetDefaults")
        options.appearance = value(after: "-PullUpAppearance").flatMap(AppearancePreference.init(rawValue:))
        options.initialTab = value(after: "-PullUpTab").flatMap(MainTab.init(rawValue:))
        options.openPush = value(after: "-PullUpOpenPush")
        return options
    }
}

public enum MainTab: String, Hashable, Sendable, CaseIterable {
    case drive, map, feed, meets, garage
}
