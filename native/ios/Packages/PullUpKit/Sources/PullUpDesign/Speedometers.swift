import SwiftUI
import PullUpDomain

/// Input to every speedometer, already converted into the display unit.
public struct SpeedometerReading: Equatable, Sendable {
    public var speed: Double?
    public var topSpeed: Double?
    public var maximum: Double
    public var unit: SpeedUnit
    /// Speed came from position deltas, not Doppler. Rendered dimmer.
    public var isDerived: Bool

    public init(speed: Double?, topSpeed: Double?, unit: SpeedUnit, isDerived: Bool = false) {
        self.speed = speed
        self.topSpeed = topSpeed
        self.maximum = unit.gaugeMaximum
        self.unit = unit
        self.isDerived = isDerived
    }

    var displayValue: String {
        guard let speed else { return "––" }
        return String(Int(speed.rounded()))
    }

    var fraction: Double {
        guard let speed else { return 0 }
        return min(1, max(0, speed / maximum))
    }

    var accessibilityValue: String {
        guard let speed else { return "No GPS speed" }
        var text = "\(Int(speed.rounded())) \(unit.label)"
        if isDerived { text += ", estimated from position" }
        if let topSpeed { text += ", top \(Int(topSpeed.rounded()))" }
        return text
    }
}

public struct Speedometer: View {
    let reading: SpeedometerReading
    let style: SpeedometerStyle

    public init(_ reading: SpeedometerReading, style: SpeedometerStyle) {
        self.reading = reading
        self.style = style
    }

    public var body: some View {
        Group {
            switch style {
            case .analog: AnalogSpeedometer(reading: reading)
            case .digital: DigitalSpeedometer(reading: reading)
            case .tape: TapeSpeedometer(reading: reading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed")
        .accessibilityValue(reading.accessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Sweep

struct AnalogSpeedometer: View {
    let reading: SpeedometerReading
    @Environment(\.clusterTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize: CGFloat = 76

    static let startAngle = 135.0
    static let sweep = 270.0

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                GaugeScale(maximum: reading.maximum, unit: reading.unit, accent: theme.accentColor, topSpeed: reading.topSpeed)
                GaugeNeedle(fraction: reading.fraction, color: theme.accentColor, dimmed: reading.speed == nil)
                    .animation(Motion.resolved(Motion.needle, reduceMotion: reduceMotion), value: reading.fraction)
                VStack(spacing: 0) {
                    Text(reading.displayValue)
                        .font(ClusterFont.numeral(min(numeralSize, side * 0.3)))
                        .foregroundStyle(reading.speed == nil ? ClusterColor.inkTertiary : ClusterColor.ink)
                        .opacity(reading.isDerived ? 0.75 : 1)
                        .contentTransition(.numericText(value: reading.speed ?? 0))
                        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: reading.displayValue)
                    Legend(reading.unit.label, color: ClusterColor.inkSecondary)
                }
                .offset(y: side * 0.12)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct GaugeScale: View {
    let maximum: Double
    let unit: SpeedUnit
    let accent: Color
    let topSpeed: Double?

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side / 2 - 4
            let minorStep = unit == .mph ? 5.0 : 10.0
            let majorStep = unit == .mph ? 20.0 : 40.0
            let redlineStart = maximum * 0.8

            func angle(for value: Double) -> Angle {
                .degrees(AnalogSpeedometer.startAngle + AnalogSpeedometer.sweep * value / maximum)
            }
            func point(_ value: Double, _ r: CGFloat) -> CGPoint {
                let a = angle(for: value).radians
                return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            }

            // Redline band.
            var band = Path()
            band.addArc(center: center, radius: radius - 3, startAngle: angle(for: redlineStart), endAngle: angle(for: maximum), clockwise: false)
            context.stroke(band, with: .color(ClusterColor.live.opacity(0.55)), lineWidth: 4)

            // Outer bezel arc.
            var bezel = Path()
            bezel.addArc(center: center, radius: radius, startAngle: angle(for: 0), endAngle: angle(for: maximum), clockwise: false)
            context.stroke(bezel, with: .color(ClusterColor.ruleStrong), lineWidth: 1)

            var value = 0.0
            while value <= maximum + 0.001 {
                let isMajor = value.truncatingRemainder(dividingBy: majorStep) == 0
                let inner = radius - (isMajor ? 16 : 8)
                var tick = Path()
                tick.move(to: point(value, radius - 1))
                tick.addLine(to: point(value, inner))
                let color = value >= redlineStart ? ClusterColor.live : (isMajor ? ClusterColor.ink : ClusterColor.inkTertiary)
                context.stroke(tick, with: .color(color), lineWidth: isMajor ? 2 : 1)
                if isMajor {
                    let label = Text("\(Int(value))")
                        .font(.system(size: max(10, side * 0.045), weight: .semibold).width(.condensed).monospacedDigit())
                        .foregroundStyle(ClusterColor.inkSecondary)
                    context.draw(label, at: point(value, radius - 30))
                }
                value += minorStep
            }

            // Top-speed marker: a small open chevron outside the bezel.
            if let topSpeed, topSpeed > 0 {
                let v = min(topSpeed, maximum)
                let a = angle(for: v).radians
                let tip = point(v, radius - 18)
                let left = CGPoint(x: tip.x + 7 * cos(a - 0.45), y: tip.y + 7 * sin(a - 0.45))
                let right = CGPoint(x: tip.x + 7 * cos(a + 0.45), y: tip.y + 7 * sin(a + 0.45))
                var marker = Path()
                marker.move(to: left)
                marker.addLine(to: tip)
                marker.addLine(to: right)
                context.stroke(marker, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct GaugeNeedle: View, Animatable {
    var fraction: Double
    let color: Color
    let dimmed: Bool

    nonisolated var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side / 2 - 4
            let a = Angle.degrees(AnalogSpeedometer.startAngle + AnalogSpeedometer.sweep * fraction).radians
            // Lit arc from zero to the needle: the "fuel" of the sweep.
            var lit = Path()
            lit.addArc(center: center, radius: radius - 8, startAngle: .degrees(AnalogSpeedometer.startAngle), endAngle: .radians(a), clockwise: false)
            context.stroke(lit, with: .color(color.opacity(dimmed ? 0 : 0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .butt))

            let tip = CGPoint(x: center.x + (radius - 6) * cos(a), y: center.y + (radius - 6) * sin(a))
            let tail = CGPoint(x: center.x + (radius - 46) * cos(a), y: center.y + (radius - 46) * sin(a))
            var needle = Path()
            needle.move(to: tail)
            needle.addLine(to: tip)
            context.stroke(needle, with: .color(dimmed ? ClusterColor.inkTertiary : color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Digital

struct DigitalSpeedometer: View {
    let reading: SpeedometerReading
    @Environment(\.clusterTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize: CGFloat = 156

    private let segments = 32

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(reading.displayValue)
                    .font(ClusterFont.numeral(numeralSize))
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .foregroundStyle(reading.speed == nil ? ClusterColor.inkTertiary : ClusterColor.ink)
                    .opacity(reading.isDerived ? 0.75 : 1)
                    .contentTransition(.numericText(value: reading.speed ?? 0))
                    .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: reading.displayValue)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Legend(reading.unit.label, color: ClusterColor.inkSecondary)
                    if let top = reading.topSpeed {
                        Legend("Top \(Int(top.rounded()))", color: theme.accentColor)
                    }
                }
            }
            GeometryReader { proxy in
                let lit = Int((reading.fraction * Double(segments)).rounded(.down))
                let topIndex = reading.topSpeed.map { Int(min(1, $0 / reading.maximum) * Double(segments)) }
                HStack(spacing: 3) {
                    ForEach(0..<segments, id: \.self) { i in
                        let redline = Double(i) >= Double(segments) * 0.8
                        Rectangle()
                            .fill(i < lit ? (redline ? ClusterColor.live : theme.accentColor) : ClusterColor.rule)
                            .overlay(alignment: .top) {
                                if i == topIndex { Rectangle().fill(theme.accentColor).frame(height: 2).offset(y: -5) }
                            }
                    }
                }
                .frame(width: proxy.size.width, height: 14)
                .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: lit)
            }
            .frame(height: 20)
        }
    }
}

// MARK: - Tape

struct TapeSpeedometer: View {
    let reading: SpeedometerReading
    @Environment(\.clusterTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize: CGFloat = 96

    var body: some View {
        VStack(spacing: Space.m) {
            Text(reading.displayValue)
                .font(ClusterFont.numeral(numeralSize))
                .minimumScaleFactor(0.5)
                .foregroundStyle(reading.speed == nil ? ClusterColor.inkTertiary : ClusterColor.ink)
                .opacity(reading.isDerived ? 0.75 : 1)
                .contentTransition(.numericText(value: reading.speed ?? 0))
                .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: reading.displayValue)
            TapeStrip(value: reading.speed ?? 0, topSpeed: reading.topSpeed, accent: theme.accentColor, unit: reading.unit)
                .frame(height: 58)
                .animation(Motion.resolved(Motion.needle, reduceMotion: reduceMotion), value: reading.speed ?? 0)
            Legend(reading.unit.label, color: ClusterColor.inkSecondary)
        }
    }
}

private struct TapeStrip: View, Animatable {
    var value: Double
    let topSpeed: Double?
    let accent: Color
    let unit: SpeedUnit

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let pointsPerUnit: CGFloat = unit == .mph ? 9 : 6
            let center = size.width / 2
            let minor = unit == .mph ? 2.0 : 5.0
            let major = unit == .mph ? 10.0 : 20.0
            let visible = Double(size.width / pointsPerUnit) / 2 + major
            var v = max(0, (value - visible) / minor).rounded(.down) * minor
            while v <= value + visible {
                let x = center + CGFloat(v - value) * pointsPerUnit
                let isMajor = v.truncatingRemainder(dividingBy: major) == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 0))
                tick.addLine(to: CGPoint(x: x, y: isMajor ? 22 : 10))
                // Fade ticks toward the edges like a curved tape.
                let fade = 1 - min(1, abs(x - center) / center) * 0.85
                context.stroke(tick, with: .color(ClusterColor.ink.opacity(fade)), lineWidth: isMajor ? 2 : 1)
                if isMajor {
                    let label = Text("\(Int(v))")
                        .font(.system(size: 13, weight: .semibold).width(.condensed).monospacedDigit())
                        .foregroundStyle(ClusterColor.inkSecondary.opacity(fade))
                    context.draw(label, at: CGPoint(x: x, y: 38))
                }
                v += minor
            }
            if let topSpeed {
                let x = center + CGFloat(topSpeed - value) * pointsPerUnit
                if x > 0, x < size.width {
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: size.height))
                    marker.addLine(to: CGPoint(x: x, y: size.height - 8))
                    context.stroke(marker, with: .color(accent), lineWidth: 2)
                }
            }
            // Fixed pointer.
            var pointer = Path()
            pointer.move(to: CGPoint(x: center - 7, y: size.height))
            pointer.addLine(to: CGPoint(x: center, y: size.height - 12))
            pointer.addLine(to: CGPoint(x: center + 7, y: size.height))
            pointer.closeSubpath()
            context.fill(pointer, with: .color(accent))
            var line = Path()
            line.move(to: CGPoint(x: center, y: 0))
            line.addLine(to: CGPoint(x: center, y: size.height - 12))
            context.stroke(line, with: .color(accent), lineWidth: 2)
        }
    }
}
