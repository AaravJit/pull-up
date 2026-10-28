import SwiftUI
import UIKit
import PullUpDomain

// Pull Up's design system. The type names still say "Cluster" (the first
// design language) so that every screen keeps compiling against the same
// tokens; the values below are the 1.0 identity:
//
//   • Content first. People's cars, photos and conversations carry the
//     colour; the interface is neutral black, white and grey around them.
//   • Native structure. System navigation bars, tab bars, sheets, lists and
//     menus, styled through these tokens rather than redrawn.
//   • One accent, electric blue by default, spent on what is selected,
//     actionable or live. Never on large decorative fills.
//   • Dark mode is OLED black (#000000) from edge to edge. Light mode is its
//     own white-and-zinc palette, not an inversion.
//   • Semantic colours (recording, verified, estimate, caution) keep their
//     meaning in both modes.
//
// Every value lives here so that screens never hard-code a colour, size or
// curve. See docs/DESIGN.md for the rationale and contrast figures.

public enum ClusterColor {
    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }

    /// The page: pure white in light mode, OLED black (#000000) in dark.
    public static let canvas = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// A raised surface on the canvas (grouped rows, inputs, chips).
    public static let plate = dynamic(light: 0xF4F4F5, dark: 0x111113)
    /// A surface that stands forward of a plate (selected, pressed, bubbles).
    public static let plateRaised = dynamic(light: 0xE4E4E7, dark: 0x1C1C1F)
    /// Primary text: 19.8:1 on white, 21:1 on black.
    public static let ink = dynamic(light: 0x09090B, dark: 0xFFFFFF)
    /// Secondary text: 7.7:1 on white, 8.2:1 on black, 7.4:1 on #111113.
    public static let inkSecondary = dynamic(light: 0x52525B, dark: 0xA1A1AA)
    /// Metadata and hints: 4.8:1 on white, 6.1:1 on black. Still AA, but
    /// never the only place an action is explained.
    public static let inkTertiary = dynamic(light: 0x71717A, dark: 0x8A8A93)
    /// Separators.
    public static let rule = dynamic(light: 0xE4E4E7, dark: 0x242428)
    public static let ruleStrong = dynamic(light: 0xD4D4D8, dark: 0x3F3F46)

    /// Something happening right now (recording, live meet), and likes.
    public static let live = dynamic(light: 0xD93A2B, dark: 0xFF453A)
    /// Server-verified data.
    public static let verified = dynamic(light: 0x15803D, dark: 0x30D158)
    /// Phone-GPS estimate. Shown wherever a number might be mistaken for a
    /// measurement, and on demo labels.
    public static let estimate = dynamic(light: 0x9A6700, dark: 0xFFD60A)
    public static let caution = dynamic(light: 0xC2410C, dark: 0xFF9F0A)

    /// Dark text for light accent fills (Titanium, Acid).
    public static let onAccent = Color(uiColor: UIColor(hex: 0x09090B, alpha: 1))

    /// The colour of text, icons and selection marks in an accent.
    public static func accent(_ choice: AccentChoice) -> Color {
        switch choice {
        // Electric blue, the default: 6.5:1 on black, 5.2:1 on white.
        case .gulf: dynamic(light: 0x2563EB, dark: 0x4F8CFF)
        case .sodium: dynamic(light: 0xD9821C, dark: 0xF2A03D)
        case .redline: dynamic(light: 0xC9241F, dark: 0xF0453B)
        case .britishGreen: dynamic(light: 0x1C6B42, dark: 0x3FAE73)
        case .ultraviolet: dynamic(light: 0x6542D6, dark: 0x9B80FF)
        case .titanium: dynamic(light: 0x5F646C, dark: 0xB9BDC4)
        case .papaya: dynamic(light: 0xD9531E, dark: 0xFF7A3D)
        case .acid: dynamic(light: 0x7FA300, dark: 0xC4EC2E)
        }
    }

    /// The fill behind a primary button or badge in an accent. For electric
    /// blue in dark mode it is a deeper blue, so white text on it keeps 4.5:1.
    public static func accentFill(_ choice: AccentChoice) -> Color {
        switch choice {
        case .gulf: dynamic(light: 0x2563EB, dark: 0x2F6FEB)
        default: accent(choice)
        }
    }

    /// Whether dark text reads better than light text on this accent's fill.
    public static func accentPrefersDarkText(_ choice: AccentChoice) -> Bool {
        switch choice {
        case .sodium, .titanium, .acid: true
        case .gulf, .redline, .britishGreen, .ultraviolet, .papaya: false
        }
    }

    /// Text and icons placed on `accentFill(choice)`.
    public static func textOnAccent(_ choice: AccentChoice) -> Color {
        accentPrefersDarkText(choice) ? onAccent : .white
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

/// 4-point spacing scale, plus the layout rules the screens share.
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
    /// Between tightly related controls (an icon and its count).
    public static let related: CGFloat = 8
    /// Between the parts of one content group (author row, media, caption).
    public static let group: CGFloat = 14
    /// Inside a container, when one is needed at all.
    public static let inset: CGFloat = 16
    /// Between major sections of a screen.
    public static let section: CGFloat = 28
    /// Smallest tappable size (Human Interface Guidelines).
    public static let target: CGFloat = 44
    /// Widest a column of reading content grows on a large display.
    public static let readableWidth: CGFloat = 640
}

/// Corner radii. Surfaces use continuous ("squircle") corners. The
/// `chamfer` names are kept from the first design language and now mean
/// corner radius.
public enum Radius {
    /// Containers and buttons.
    public static let chamfer: CGFloat = 14
    /// Small controls, thumbnails and chips.
    public static let chamferSmall: CGFloat = 10
    /// Photos inside content.
    public static let photo: CGFloat = 12
    public static let chip: CGFloat = 8
    /// Message bubbles.
    public static let bubble: CGFloat = 18
}

public enum ClusterFont {
    /// Big instrument numerals (speed), compressed width, tabular figures.
    /// Reserved for the drive screens.
    public static func numeral(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .system(size: size, weight: .heavy, design: .default).width(.compressed).monospacedDigit()
    }

    /// Numbers that sit in text: counts, distances, times. Tabular figures
    /// so they don't jitter as they change.
    public static func readout(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .default, weight: .semibold).monospacedDigit()
    }

    /// Screen and section titles.
    public static func title(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .default, weight: .bold)
    }

    public static func headline(_ style: Font.TextStyle = .headline) -> Font {
        .system(style, design: .default, weight: .semibold)
    }

    /// Small labels over values and controls, sentence case.
    public static func legend(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .default, weight: .medium)
    }

    public static func body(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .default, weight: .regular)
    }
}

public enum Tracking {
    public static let legend: CGFloat = 0
    public static let title: CGFloat = 0
}

public enum Motion {
    /// Needle and numeric readouts. Slightly damped so 1 Hz GPS updates
    /// glide instead of jumping.
    public static let needle = Animation.interpolatingSpring(stiffness: 70, damping: 14)
    public static let sheet = Animation.spring(response: 0.48, dampingFraction: 0.86)
    public static let select = Animation.spring(response: 0.32, dampingFraction: 0.72)
    public static let quick = Animation.easeOut(duration: 0.18)
    /// State changes inside a screen (a section expanding, a chip selected).
    public static let reveal = Animation.spring(response: 0.36, dampingFraction: 0.86)

    /// Returns `nil` (no animation) when Reduce Motion is on.
    public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
