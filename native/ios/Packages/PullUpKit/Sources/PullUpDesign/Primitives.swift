import SwiftUI
import PullUpDomain

/// The standard surface shape: a rectangle with continuous corners.
///
/// The name is kept from the first design language, whose plates had cut
/// corners, so every screen picked up the new shape at once. `cut` is the
/// corner radius; `corners` picks which corners are rounded.
public struct ChamferedRectangle: InsettableShape {
    public var cut: CGFloat
    public var corners: Corners
    var inset: CGFloat = 0

    public struct Corners: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let topLeading = Corners(rawValue: 1)
        public static let topTrailing = Corners(rawValue: 2)
        public static let bottomLeading = Corners(rawValue: 4)
        public static let bottomTrailing = Corners(rawValue: 8)
        public static let all: Corners = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
        /// Every corner. (It meant two cut corners in the old language.)
        public static let signature: Corners = all
    }

    public init(cut: CGFloat = Radius.chamfer, corners: Corners = .all) {
        self.cut = cut
        self.corners = corners
    }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = max(0, min(cut, r.width / 2, r.height / 2))
        return UnevenRoundedRectangle(
            topLeadingRadius: corners.contains(.topLeading) ? c : 0,
            bottomLeadingRadius: corners.contains(.bottomLeading) ? c : 0,
            bottomTrailingRadius: corners.contains(.bottomTrailing) ? c : 0,
            topTrailingRadius: corners.contains(.topTrailing) ? c : 0,
            style: .continuous
        ).path(in: r)
    }

    public func inset(by amount: CGFloat) -> ChamferedRectangle {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// A small label over a value or control: "Top speed", "Who can see this".
public struct Legend: View {
    let text: String
    var color: Color = ClusterColor.inkSecondary

    public init(_ text: String, color: Color = ClusterColor.inkSecondary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(ClusterFont.legend())
            .foregroundStyle(color)
            .lineLimit(2)
    }
}

/// A section divider. It drew an instrument tick scale in the first design
/// language; it is a plain hairline now, kept so call sites still compile.
public struct TickRule: View {
    var color: Color

    public init(ticks: Int = 40, majorEvery: Int = 5, height: CGFloat = 6, color: Color = ClusterColor.rule) {
        self.color = color
    }

    public var body: some View {
        Hairline(color: color)
    }
}

/// Plain hairline.
public struct Hairline: View {
    @Environment(\.displayScale) private var displayScale
    var color: Color = ClusterColor.rule
    public init(color: Color = ClusterColor.rule) { self.color = color }
    public var body: some View {
        Rectangle().fill(color).frame(height: 1 / max(displayScale, 1)).accessibilityHidden(true)
    }
}

public extension View {
    /// A raised surface with continuous corners and no border (pass
    /// `stroke` for a selection ring). `raised` for the forward layer.
    func plate(raised: Bool = false, cut: CGFloat = Radius.chamfer, stroke: Color? = nil) -> some View {
        background {
            ChamferedRectangle(cut: cut)
                .fill(raised ? ClusterColor.plateRaised : ClusterColor.plate)
                .overlay {
                    if let stroke {
                        ChamferedRectangle(cut: cut).strokeBorder(stroke, lineWidth: 2)
                    }
                }
        }
    }
}

/// Number + unit + legend, the core typographic unit of the app.
public struct Readout: View {
    let legend: String
    let value: String
    let unit: String?
    var quality: MeasurementQuality?
    var size: Size

    public enum Size: Sendable { case small, medium, large }

    public init(_ legend: String, value: String, unit: String? = nil, quality: MeasurementQuality? = nil, size: Size = .medium) {
        self.legend = legend
        self.value = value
        self.unit = unit
        self.quality = quality
        self.size = size
    }

    private var valueFont: Font {
        switch size {
        case .small: ClusterFont.readout(.title3)
        case .medium: ClusterFont.readout(.title)
        case .large: ClusterFont.readout(.largeTitle)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Legend(legend)
                if let quality, quality != .consistent {
                    QualityMark(quality: quality)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(valueFont)
                    .foregroundStyle(quality == .insufficient ? ClusterColor.inkTertiary : ClusterColor.ink)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(ClusterFont.legend(.subheadline))
                        .foregroundStyle(ClusterColor.inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(legend)
        .accessibilityValue([value, unit, quality.map { $0 == .consistent ? nil : $0.label } ?? nil].compactMap { $0 }.joined(separator: " "))
    }
}

/// Tiny marker that flags an estimate. Dashed outline = "not measured".
public struct QualityMark: View {
    let quality: MeasurementQuality
    public init(quality: MeasurementQuality) { self.quality = quality }

    public var body: some View {
        Text(quality == .estimate ? "EST" : quality == .insufficient ? "—" : "GPS")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(ClusterColor.estimate)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(ClusterColor.estimate, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
            }
            .accessibilityLabel(quality.label)
    }
}

/// Server validation state for a drive or leaderboard entry.
public struct ValidationBadge: View {
    let status: DriveValidationStatus
    public init(_ status: DriveValidationStatus) { self.status = status }

    private var color: Color {
        switch status {
        case .validated: ClusterColor.verified
        case .pending: ClusterColor.inkTertiary
        case .flagged: ClusterColor.estimate
        case .rejected: ClusterColor.caution
        }
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: status == .validated ? "checkmark.seal.fill" : status == .pending ? "clock" : "exclamationmark.triangle")
                .imageScale(.small)
            Text(status.label)
        }
        .font(ClusterFont.legend(.caption))
        .foregroundStyle(color)
    }
}

/// Four-bar GPS indicator.
public struct SignalBars: View {
    let bars: Int
    var tint: Color

    public init(bars: Int, tint: Color = ClusterColor.ink) {
        self.bars = bars
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { level in
                Rectangle()
                    .fill(level <= bars ? tint : ClusterColor.ruleStrong)
                    .frame(width: 3, height: CGFloat(3 + level * 3))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Blinking dot for live state. Holds steady under Reduce Motion.
public struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    var size: CGFloat

    public init(size: CGFloat = 8) { self.size = size }

    public var body: some View {
        Circle()
            .fill(ClusterColor.live)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// Audience icon + label, with the consequence available to VoiceOver.
public struct VisibilityTag: View {
    let visibility: Audience
    public init(_ visibility: Audience) { self.visibility = visibility }

    public var body: some View {
        Label(visibility.label, systemImage: visibility.symbol)
            .font(ClusterFont.legend(.caption))
            .foregroundStyle(ClusterColor.inkSecondary)
            .accessibilityHint(visibility.explanation)
    }
}

public extension Audience {
    var symbol: String {
        switch self {
        case .public: "globe"
        case .friends: "person.2"
        case .private: "lock"
        }
    }
}

/// Full-width actions: primary (accent fill), secondary (neutral surface),
/// destructive. A subtle press scale, none under Reduce Motion.
public struct ClusterButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, destructive }
    @Environment(\.clusterTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var kind: Kind

    public init(_ kind: Kind = .primary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch kind {
        case .primary: theme.accentFill
        case .secondary: ClusterColor.plate
        case .destructive: ClusterColor.live
        }
        let text: Color = switch kind {
        case .primary: theme.onAccent
        case .secondary: ClusterColor.ink
        case .destructive: .white
        }
        configuration.label
            .font(ClusterFont.headline())
            .multilineTextAlignment(.center)
            .foregroundStyle(text)
            .padding(.vertical, Space.m)
            .padding(.horizontal, Space.l)
            .frame(minHeight: 50)
            .background(ChamferedRectangle(cut: Radius.chamfer).fill(fill))
            .contentShape(ChamferedRectangle(cut: Radius.chamfer))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == ClusterButtonStyle {
    static var cluster: ClusterButtonStyle { ClusterButtonStyle(.primary) }
    static var clusterSecondary: ClusterButtonStyle { ClusterButtonStyle(.secondary) }
    static var clusterDestructive: ClusterButtonStyle { ClusterButtonStyle(.destructive) }
}

/// Scope selector: sentence-case labels with an accent underline on the
/// selected one, or a checked list at accessibility text sizes.
public struct SwitchBank<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    @Environment(\.clusterTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    public init(_ options: [Value], selection: Binding<Value>, label: @escaping (Value) -> String) {
        self.options = options
        self._selection = selection
        self.label = label
    }

    public var body: some View {
        // Every segment at full size on one line if they all fit; otherwise
        // labels may wrap to two lines. Shrinking each label on its own made
        // long ones visibly smaller than their neighbours.
        Group {
            if typeSize.isAccessibilitySize && options.count >= 4 {
                // Four or more labels at accessibility sizes truncate even on
                // two lines, so they stack as a list instead.
                ViewThatFits(in: .horizontal) {
                    bank(lines: 1)
                    list
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    bank(lines: 1)
                    bank(lines: 2)
                }
            }
        }
        .overlay(alignment: .bottom) { Hairline() }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func select(_ option: Value) {
        withAnimation(Motion.resolved(Motion.select, reduceMotion: reduceMotion)) { selection = option }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    select(option)
                } label: {
                    HStack(spacing: Space.s) {
                        Text(label(option))
                            .font(selected ? ClusterFont.headline(.subheadline) : ClusterFont.body(.subheadline))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(selected ? ClusterColor.ink : ClusterColor.inkSecondary)
                        Spacer(minLength: Space.s)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(ClusterFont.legend(.caption))
                                .foregroundStyle(theme.accentColor)
                        }
                    }
                    .padding(.vertical, Space.s)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .overlay(alignment: .leading) {
                        if selected {
                            Rectangle().fill(theme.accentColor).frame(width: 2)
                                .offset(x: -Space.s)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .overlay(alignment: .bottom) {
                    if option != options.last { Hairline() }
                }
            }
        }
        .padding(.leading, Space.s)
    }

    private func bank(lines: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    select(option)
                } label: {
                    Text(label(option))
                        .font(selected ? ClusterFont.headline(.subheadline) : ClusterFont.body(.subheadline))
                        .lineLimit(lines)
                        .multilineTextAlignment(.center)
                        .allowsTightening(true)
                        .minimumScaleFactor(lines == 1 ? 1 : 0.8)
                        .fixedSize(horizontal: lines == 1, vertical: false)
                        .foregroundStyle(selected ? ClusterColor.ink : ClusterColor.inkSecondary)
                        .padding(.horizontal, Space.xs)
                        .frame(maxWidth: .infinity, minHeight: Space.target)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule().fill(theme.accentColor).frame(height: 2.5)
                                    .padding(.horizontal, Space.l)
                                    .matchedGeometryEffect(id: "indicator", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Section header: a bold title on the left, an optional action on the right.
public struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(ClusterFont.title(.title3))
                .foregroundStyle(ClusterColor.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
    }
}

public struct ScreenTitle: View {
    let title: String
    let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let subtitle { Legend(subtitle) }
            Text(title)
                .font(ClusterFont.title())
                .foregroundStyle(ClusterColor.ink)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Explicit "this part isn't connected yet" banner, so unfinished
/// integrations are never mistaken for real data.
public struct NoticeStrip: View {
    public enum Tone: Sendable { case info, caution, estimate }
    let text: String
    let tone: Tone

    public init(_ text: String, tone: Tone = .info) {
        self.text = text
        self.tone = tone
    }

    private var color: Color {
        switch tone {
        case .info: ClusterColor.inkSecondary
        case .caution: ClusterColor.caution
        case .estimate: ClusterColor.estimate
        }
    }

    private var symbol: String {
        switch tone {
        case .info: "info.circle"
        case .caution: "exclamationmark.triangle"
        case .estimate: "location.slash"
        }
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol)
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xs)
    }
}

/// The surface for controls floating over content (map overlays, the
/// live-drive bar): Liquid Glass on iOS 26, a material before it. Content
/// itself never sits on glass.
public struct FloatingControlSurface: ViewModifier {
    var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = Radius.chamfer + 4) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
