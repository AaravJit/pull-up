import SwiftUI
import UIKit
import PullUpDomain

// "Cluster", Pull Up's design language.
//
// It borrows from instrument clusters and motorsport timing screens, not
// from SaaS dashboards:
//   • Hairline rules and tick scales separate content instead of cards.
//   • Numbers are the hero. They're set in compressed, tabular figures.
//   • Labels read like stamped instrument legends: small, tracked, uppercase.
//   • Surfaces are flat plates with a small chamfer, never pill-shaped.
//   • One accent colour at a time, chosen by the user and used sparingly for
//     what is live, selected or actionable.
//
// Every value lives here so that screens never hard-code a colour, size or
// curve. See docs/DESIGN.md for the rationale and do / don't examples.

public enum ClusterColor {
    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }

    /// The page. Warm "spec sheet" paper in light mode, near-black in dark.
    public static let canvas = dynamic(light: 0xF2F0EB, dark: 0x0A0B0D)
    /// A flat plate sitting on the canvas.
    public static let plate = dynamic(light: 0xFBFAF7, dark: 0x121418)
    /// A plate that needs to stand forward (selected row, sheet header).
    public static let plateRaised = dynamic(light: 0xE8E5DE, dark: 0x1B1E23)
    public static let ink = dynamic(light: 0x111214, dark: 0xF1EFE9)
    public static let inkSecondary = dynamic(light: 0x111214, dark: 0xF1EFE9, lightAlpha: 0.62, darkAlpha: 0.62)
    public static let inkTertiary = dynamic(light: 0x111214, dark: 0xF1EFE9, lightAlpha: 0.40, darkAlpha: 0.38)
    public static let rule = dynamic(light: 0x111214, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.09)
    public static let ruleStrong = dynamic(light: 0x111214, dark: 0xFFFFFF, lightAlpha: 0.22, darkAlpha: 0.20)

    /// Something happening right now (recording, live meet).
    public static let live = dynamic(light: 0xD93A2B, dark: 0xFF5240)
    /// Server-verified data.
    public static let verified = dynamic(light: 0x1E8A55, dark: 0x45D08E)
    /// Phone-GPS estimate. Shown wherever a number might be mistaken for a
    /// measurement.
    public static let estimate = dynamic(light: 0xA86E00, dark: 0xE9B44C)
    public static let caution = dynamic(light: 0xB4471B, dark: 0xFF8A4C)

    /// Text and icons placed on an accent fill.
    public static let onAccent = Color(uiColor: UIColor(hex: 0x0A0B0D, alpha: 1))

    public static func accent(_ choice: AccentChoice) -> Color {
        switch choice {
        case .sodium: dynamic(light: 0xD9821C, dark: 0xF2A03D)
        case .redline: dynamic(light: 0xC9241F, dark: 0xF0453B)
        case .britishGreen: dynamic(light: 0x1C6B42, dark: 0x3FAE73)
        case .gulf: dynamic(light: 0x2E7FB8, dark: 0x8CC4EA)
        case .ultraviolet: dynamic(light: 0x6542D6, dark: 0x9B80FF)
        case .titanium: dynamic(light: 0x5F646C, dark: 0xB9BDC4)
        }
    }

    /// Whether dark text reads better than light text on this accent.
    public static func accentPrefersDarkText(_ choice: AccentChoice) -> Bool {
        switch choice {
        case .sodium, .gulf, .titanium: true
        case .redline, .britishGreen, .ultraviolet: false
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// 4-point spacing scale.
public enum Space {
    public static let hairline: CGFloat = 1
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
    /// Leading/trailing page margin.
    public static let gutter: CGFloat = 20
}

public enum Radius {
    /// Plates use a chamfer rather than a radius; this is the cut length.
    public static let chamfer: CGFloat = 10
    public static let chamferSmall: CGFloat = 6
    /// Photos get a barely-there radius so they don't look like web cards.
    public static let photo: CGFloat = 4
    public static let chip: CGFloat = 3
}

public enum ClusterFont {
    /// Big instrument numerals (speed). Scales with Dynamic Type from a
    /// large base, compressed width, tabular figures.
    public static func numeral(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .system(size: size, weight: .heavy, design: .default).width(.compressed).monospacedDigit()
    }

    /// Mid-size readouts (distance, time).
    public static func readout(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .default, weight: .bold).width(.condensed).monospacedDigit()
    }

    /// Screen and section titles: wide, confident, mixed case.
    public static func title(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .default, weight: .bold).width(.expanded)
    }

    public static func headline(_ style: Font.TextStyle = .headline) -> Font {
        .system(style, design: .default, weight: .semibold).width(.standard)
    }

    /// Stamped legend: use with `.textCase(.uppercase)` and `.tracking(Tracking.legend)`.
    public static func legend(_ style: Font.TextStyle = .caption2) -> Font {
        .system(style, design: .default, weight: .semibold).width(.expanded)
    }

    public static func body(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .default, weight: .regular)
    }
}

public enum Tracking {
    public static let legend: CGFloat = 1.4
    public static let title: CGFloat = -0.4
}

public enum Motion {
    /// Needle and numeric readouts. Slightly damped so 1 Hz GPS updates
    /// glide instead of jumping.
    public static let needle = Animation.interpolatingSpring(stiffness: 70, damping: 14)
    public static let sheet = Animation.spring(response: 0.48, dampingFraction: 0.86)
    public static let select = Animation.spring(response: 0.32, dampingFraction: 0.72)
    public static let quick = Animation.easeOut(duration: 0.18)

    /// Returns `nil` (no animation) when Reduce Motion is on.
    public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
