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
    /// Tab to open at launch. Also accepts the pre-1.0 tab names (drive,
    /// map, meets, garage), mapped to where those screens live now.
    public var initialTab: MainTab?
    /// Explore's segment at launch (`-PullUpTab map` or `meets`).
    public var initialExplore: ExploreMode?
    /// Opens the Drive screen at launch (`-PullUpTab drive`, `-PullUpOpenDrive`).
    public var opensDrive = false
    /// Opens the garage from You at launch (`-PullUpTab garage`).
    public var opensGarage = false
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
        if let tab = value(after: "-PullUpTab") { options.applyTab(tab) }
        if args.contains("-PullUpOpenDrive") { options.opensDrive = true }
        options.openPush = value(after: "-PullUpOpenPush")
        return options
    }

    /// Maps a `-PullUpTab` value onto the 1.0 navigation.
    public mutating func applyTab(_ name: String) {
        if let tab = MainTab(rawValue: name) {
            initialTab = tab
            return
        }
        switch name {
        case "map":
            initialTab = .explore
            initialExplore = .map
        case "meets":
            initialTab = .explore
            initialExplore = .meets
        case "people":
            initialTab = .explore
            initialExplore = .people
        case "garage":
            initialTab = .you
            opensGarage = true
        case "drive":
            initialTab = .you
            opensDrive = true
        case "dms", "inbox":
            initialTab = .messages
        default:
            break
        }
    }
}

/// The four tabs. Posting and messaging lead; meets, the map and people
/// are under Explore; your profile, garage, drives and settings under You.
public enum MainTab: String, Hashable, Sendable, CaseIterable {
    case feed, messages, explore, you
}

/// Explore's three views.
public enum ExploreMode: String, Hashable, Sendable, CaseIterable, Identifiable {
    case meets, map, people
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .meets: "Meets"
        case .map: "Map"
        case .people: "People"
        }
    }
}
