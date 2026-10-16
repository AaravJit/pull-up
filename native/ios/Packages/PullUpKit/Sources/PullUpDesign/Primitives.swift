import SwiftUI
import PullUpDomain

/// Rectangle with the top-leading and bottom-trailing corners cut at 45°.
/// The signature Pull Up silhouette: reads as machined bezel or number plate,
/// never as a web card.
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
        public static let signature: Corners = [.topLeading, .bottomTrailing]
        public static let all: Corners = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
    }

    public init(cut: CGFloat = Radius.chamfer, corners: Corners = .signature) {
        self.cut = cut
        self.corners = corners
    }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = min(cut, r.width / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + (corners.contains(.topLeading) ? c : 0), y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - (corners.contains(.topTrailing) ? c : 0), y: r.minY))
        if corners.contains(.topTrailing) { p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c)) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - (corners.contains(.bottomTrailing) ? c : 0)))
        if corners.contains(.bottomTrailing) { p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY)) }
        p.addLine(to: CGPoint(x: r.minX + (corners.contains(.bottomLeading) ? c : 0), y: r.maxY))
        if corners.contains(.bottomLeading) { p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c)) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + (corners.contains(.topLeading) ? c : 0)))
        p.closeSubpath()
        return p
    }

    public func inset(by amount: CGFloat) -> ChamferedRectangle {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// Stamped instrument legend: "TOP SPEED", "GPS ±".
public struct Legend: View {
    let text: String
    var color: Color = ClusterColor.inkTertiary

    public init(_ text: String, color: Color = ClusterColor.inkTertiary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(ClusterFont.legend())
            .textCase(.uppercase)
            .tracking(Tracking.legend)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// A hairline with a tick scale, used instead of card borders to divide
/// sections. Major ticks every `majorEvery` minor ticks.
public struct TickRule: View {
    var ticks: Int = 40
    var majorEvery: Int = 5
    var height: CGFloat = 6
    var color: Color = ClusterColor.ruleStrong

    public init(ticks: Int = 40, majorEvery: Int = 5, height: CGFloat = 6, color: Color = ClusterColor.ruleStrong) {
        self.ticks = ticks
        self.majorEvery = majorEvery
        self.height = height
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(base, with: .color(color), lineWidth: 1)
            guard ticks > 0 else { return }
            let step = size.width / CGFloat(ticks)
            for i in 0...ticks {
                let major = i % majorEvery == 0
                var tick = Path()
                let x = min(size.width - 0.5, CGFloat(i) * step + 0.5)
                tick.move(to: CGPoint(x: x, y: size.height))
                tick.addLine(to: CGPoint(x: x, y: size.height - (major ? size.height : size.height * 0.45)))
                context.stroke(tick, with: .color(color), lineWidth: 1)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Plain hairline.
public struct Hairline: View {
    var color: Color = ClusterColor.rule
    public init(color: Color = ClusterColor.rule) { self.color = color }
    public var body: some View {
        Rectangle().fill(color).frame(height: 1).accessibilityHidden(true)
    }
}

public extension View {
    /// Flat chamfered plate. `raised` for the forward layer.
    func plate(raised: Bool = false, cut: CGFloat = Radius.chamfer, stroke: Color? = nil) -> some View {
        background {
            ChamferedRectangle(cut: cut)
                .fill(raised ? ClusterColor.plateRaised : ClusterColor.plate)
                .overlay {
                    ChamferedRectangle(cut: cut).strokeBorder(stroke ?? ClusterColor.rule, lineWidth: 1)
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
                        .font(ClusterFont.legend(.caption))
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
            .font(.system(size: 9, weight: .bold).width(.expanded))
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
        .font(ClusterFont.legend())
        .textCase(.uppercase)
        .tracking(1)
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

/// Visibility icon + label, with the consequence available to VoiceOver.
public struct VisibilityTag: View {
    let visibility: Visibility
    public init(_ visibility: Visibility) { self.visibility = visibility }

    public var body: some View {
        Label(visibility.label, systemImage: visibility.symbol)
            .font(ClusterFont.legend())
            .textCase(.uppercase)
            .tracking(1)
            .foregroundStyle(ClusterColor.inkSecondary)
            .accessibilityHint(visibility.explanation)
    }
}

public extension Visibility {
    var symbol: String {
        switch self {
        case .public: "globe"
        case .friends: "person.2"
        case .private: "lock"
        }
    }
}

/// Primary action. Chamfered, accent-filled, with a subtle press scale.
public struct ClusterButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, destructive }
    @Environment(\.clusterTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var kind: Kind

    public init(_ kind: Kind = .primary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch kind {
        case .primary: theme.accentColor
        case .secondary: ClusterColor.plateRaised
        case .destructive: ClusterColor.live
        }
        let text: Color = switch kind {
        case .primary: ClusterColor.accentPrefersDarkText(theme.accent) ? ClusterColor.onAccent : .white
        case .secondary: ClusterColor.ink
        case .destructive: .white
        }
        configuration.label
            .font(ClusterFont.headline())
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(text)
            .padding(.vertical, Space.m + 2)
            .padding(.horizontal, Space.xl)
            .frame(minHeight: 50)
            .background(ChamferedRectangle(cut: Radius.chamferSmall).fill(fill))
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

/// Segmented selector drawn as an instrument switch bank.
public struct SwitchBank<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    @Environment(\.clusterTheme) private var theme
    @Namespace private var namespace

    public init(_ options: [Value], selection: Binding<Value>, label: @escaping (Value) -> String) {
        self.options = options
        self._selection = selection
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    withAnimation(Motion.select) { selection = option }
                } label: {
                    Text(label(option))
                        .font(ClusterFont.legend(.caption))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundStyle(selected ? ClusterColor.ink : ClusterColor.inkTertiary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Rectangle().fill(theme.accentColor).frame(height: 2)
                                    .matchedGeometryEffect(id: "indicator", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) { Hairline() }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Section header: legend on the left, optional action on the right, tick rule below.
public struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(spacing: Space.s) {
            HStack {
                Legend(title, color: ClusterColor.inkSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing
            }
            TickRule(ticks: 32, majorEvery: 8, height: 4)
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
                .tracking(Tracking.title)
                .foregroundStyle(ClusterColor.ink)
                .accessibilityAddTraits(.isHeader)
        }
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

    public var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Rectangle().fill(color).frame(width: 2)
            Text(text)
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Space.xs)
    }
}
