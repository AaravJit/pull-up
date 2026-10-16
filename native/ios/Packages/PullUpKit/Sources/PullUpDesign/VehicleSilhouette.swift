import SwiftUI
import PullUpDomain

/// Side-profile line drawings, one per body style, used wherever a vehicle
/// has no photo. Drawn in a 120 × 48 design box facing right, like a
/// technical drawing: single stroke weight, closed body for cars with a
/// faint fill, open frame lines for motorcycles.
public struct VehicleSilhouette: View {
    let style: BodyStyle
    var color: Color
    var lineWidth: CGFloat
    var showsGround: Bool

    public init(_ style: BodyStyle, color: Color = ClusterColor.ink, lineWidth: CGFloat = 1.6, showsGround: Bool = true) {
        self.style = style
        self.color = color
        self.lineWidth = lineWidth
        self.showsGround = showsGround
    }

    public var body: some View {
        Canvas { context, size in
            let drawing = SilhouetteDrawing.drawing(for: style)
            let scale = min(size.width / 120, size.height / 48)
            let offset = CGPoint(x: (size.width - 120 * scale) / 2, y: (size.height - 48 * scale) / 2)
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: offset.x + p.x * scale, y: offset.y + p.y * scale) }
            let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            if let body = drawing.body {
                var path = Path()
                path.addLines(drawing.closedBody(body).map(map))
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.10)))
                context.stroke(path, with: .color(color), style: stroke)
            }
            for line in drawing.lines {
                var path = Path()
                path.addLines(line.map(map))
                context.stroke(path, with: .color(color), style: stroke)
            }
            for line in drawing.details {
                var path = Path()
                path.addLines(line.map(map))
                context.stroke(path, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: lineWidth * 0.8, lineCap: .round, lineJoin: .round))
            }
            for wheel in drawing.wheels {
                let center = map(wheel.center)
                let r = wheel.radius * scale
                let tire = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                context.stroke(tire, with: .color(color), style: stroke)
                let hubR = r * 0.32
                let hub = Path(ellipseIn: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))
                context.stroke(hub, with: .color(color.opacity(0.6)), lineWidth: lineWidth * 0.8)
            }
            if showsGround {
                let groundY = drawing.wheels.map { $0.center.y + $0.radius }.max() ?? 45
                var ground = Path()
                var x: CGFloat = 0
                while x < 120 {
                    ground.move(to: map(CGPoint(x: x, y: groundY + 1.5)))
                    ground.addLine(to: map(CGPoint(x: min(120, x + 4), y: groundY + 1.5)))
                    x += 7
                }
                context.stroke(ground, with: .color(color.opacity(0.3)), lineWidth: 1)
            }
        }
        .aspectRatio(120 / 48, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct SilhouetteDrawing {
    struct Wheel { var center: CGPoint; var radius: CGFloat }

    /// Top outline from rear-bottom to front-bottom. The underside with
    /// wheel arches is generated.
    var body: [CGPoint]?
    var lines: [[CGPoint]] = []
    var details: [[CGPoint]] = []
    var wheels: [Wheel]

    func closedBody(_ top: [CGPoint]) -> [CGPoint] {
        guard let first = top.first, let last = top.last else { return top }
        var points = top
        let sill = max(first.y, last.y)
        // Walk front to rear along the sill, arching over each wheel.
        for wheel in wheels.sorted(by: { $0.center.x > $1.center.x }) {
            let archRadius = wheel.radius + 2.2
            points.append(CGPoint(x: wheel.center.x + archRadius, y: sill))
            let steps = 12
            for i in 0...steps {
                let theta = CGFloat(i) / CGFloat(steps) * .pi
                points.append(CGPoint(x: wheel.center.x + archRadius * cos(theta), y: min(sill, wheel.center.y - archRadius * sin(theta) + 1)))
            }
            points.append(CGPoint(x: wheel.center.x - archRadius, y: sill))
        }
        return points
    }

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private static func carWheels(rear: CGFloat = 28, front: CGFloat = 92, y: CGFloat = 38, r: CGFloat = 7) -> [Wheel] {
        [Wheel(center: p(rear, y), radius: r), Wheel(center: p(front, y), radius: r)]
    }
    private static func bikeWheels(rear: CGFloat = 22, front: CGFloat = 98, y: CGFloat = 34, r: CGFloat = 11) -> [Wheel] {
        [Wheel(center: p(rear, y), radius: r), Wheel(center: p(front, y), radius: r)]
    }

    static func drawing(for style: BodyStyle) -> SilhouetteDrawing {
        switch style {
        case .sedan:
            SilhouetteDrawing(
                body: [p(6, 38), p(6, 29), p(10, 26), p(30, 24), p(44, 14), p(76, 13), p(90, 23), p(110, 25), p(115, 29), p(115, 38)],
                details: [[p(47, 16), p(74, 15), p(86, 23), p(40, 23.5), p(47, 16)], [p(61, 15.5), p(61, 23.5)]],
                wheels: carWheels()
            )
        case .coupe:
            SilhouetteDrawing(
                body: [p(6, 38), p(6, 29), p(12, 26), p(36, 22), p(52, 13), p(72, 13), p(92, 22), p(112, 25), p(116, 30), p(116, 38)],
                details: [[p(53, 14.5), p(70, 14.5), p(86, 22), p(42, 22.5), p(53, 14.5)], [p(8, 27), p(16, 26)]],
                wheels: carWheels()
            )
        case .hatchback:
            SilhouetteDrawing(
                body: [p(10, 38), p(10, 22), p(16, 13), p(66, 12), p(84, 22), p(106, 25), p(111, 30), p(111, 38)],
                details: [[p(18, 14.5), p(64, 14), p(78, 22), p(14, 22.5), p(18, 14.5)], [p(44, 14), p(44, 22.5)]],
                wheels: carWheels(rear: 27, front: 90)
            )
        case .wagon:
            SilhouetteDrawing(
                body: [p(6, 38), p(6, 24), p(10, 14), p(76, 13), p(90, 23), p(110, 25), p(115, 29), p(115, 38)],
                details: [[p(12, 15.5), p(74, 15), p(86, 23), p(9, 23.5), p(12, 15.5)], [p(34, 15.3), p(34, 23.5)], [p(58, 15.1), p(58, 23.5)]],
                wheels: carWheels()
            )
        case .convertible:
            SilhouetteDrawing(
                body: [p(6, 38), p(6, 27), p(40, 25), p(74, 25), p(86, 17), p(90, 24), p(110, 25), p(115, 30), p(115, 38)],
                details: [[p(44, 25), p(48, 19), p(56, 19), p(58, 25)], [p(78, 22), p(86, 17)]],
                wheels: carWheels()
            )
        case .suv:
            SilhouetteDrawing(
                body: [p(6, 37), p(6, 22), p(10, 10), p(80, 9), p(94, 20), p(112, 23), p(115, 28), p(115, 37)],
                details: [[p(14, 12), p(78, 11.5), p(89, 20.5), p(11, 21), p(14, 12)], [p(42, 11.8), p(42, 21)], [p(64, 11.6), p(64, 21)]],
                wheels: carWheels(y: 37, r: 8.5)
            )
        case .truck:
            SilhouetteDrawing(
                body: [p(4, 37), p(4, 22), p(52, 22), p(54, 10), p(80, 10), p(92, 21), p(112, 23), p(116, 28), p(116, 37)],
                details: [[p(58, 12), p(78, 12), p(87, 21), p(56, 21), p(58, 12)], [p(52, 22), p(52, 33)]],
                wheels: carWheels(rear: 24, front: 94, y: 37, r: 8.5)
            )
        case .van:
            SilhouetteDrawing(
                body: [p(6, 37), p(6, 8), p(84, 8), p(100, 20), p(114, 23), p(116, 28), p(116, 37)],
                details: [[p(86, 10.5), p(97, 20), p(84, 20), p(84, 10.5)], [p(56, 11), p(78, 11), p(78, 19), p(56, 19), p(56, 11)], [p(52, 9), p(52, 34)]],
                wheels: carWheels(rear: 26, front: 94, y: 37, r: 8)
            )
        case .other:
            SilhouetteDrawing(
                body: [p(8, 38), p(8, 24), p(20, 16), p(96, 16), p(112, 26), p(112, 38)],
                wheels: carWheels()
            )
        case .sport:
            SilhouetteDrawing(
                lines: [
                    [p(8, 15), p(30, 20), p(44, 20), p(56, 12), p(74, 12), p(88, 16), p(100, 9), p(108, 13), p(104, 24), p(90, 28), p(70, 30), p(52, 30), p(36, 26), p(22, 34)],
                    [p(98, 34), p(94, 18)],
                ],
                details: [[p(62, 12), p(66, 18), p(84, 18)], [p(48, 26), p(60, 30)]],
                wheels: bikeWheels()
            )
        case .naked:
            SilhouetteDrawing(
                lines: [
                    [p(12, 18), p(34, 20), p(48, 20), p(58, 13), p(76, 13), p(84, 18), p(92, 12), p(100, 12)],
                    [p(98, 34), p(92, 13)],
                    [p(22, 34), p(52, 30)],
                ],
                details: [[p(48, 22), p(70, 22), p(68, 32), p(52, 32), p(48, 22)], [p(84, 18), p(88, 24)]],
                wheels: bikeWheels()
            )
        case .cruiser:
            SilhouetteDrawing(
                lines: [
                    [p(6, 22), p(28, 24), p(42, 26), p(52, 19), p(72, 17), p(82, 20), p(92, 12), p(98, 11)],
                    [p(102, 34), p(90, 13)],
                    [p(20, 34), p(46, 30)],
                ],
                details: [[p(50, 26), p(58, 34), p(66, 26)], [p(28, 26), p(8, 30)]],
                wheels: bikeWheels(rear: 20, front: 102)
            )
        case .adventure:
            SilhouetteDrawing(
                lines: [
                    [p(8, 12), p(22, 15), p(40, 15), p(52, 9), p(78, 9), p(88, 6), p(92, 2)],
                    [p(98, 34), p(90, 7)],
                    [p(22, 34), p(46, 27)],
                ],
                details: [[p(3, 11), p(17, 11), p(17, 25), p(3, 25), p(3, 11)], [p(44, 29), p(70, 31)], [p(52, 15), p(70, 15), p(68, 27), p(50, 27), p(52, 15)]],
                wheels: bikeWheels()
            )
        case .scooter:
            SilhouetteDrawing(
                lines: [
                    [p(8, 27), p(12, 19), p(40, 19), p(48, 29), p(72, 30), p(80, 9), p(84, 6), p(90, 7)],
                    [p(80, 9), p(90, 34)],
                ],
                details: [[p(48, 31), p(74, 31)], [p(14, 23), p(36, 23)]],
                wheels: bikeWheels(rear: 24, front: 94, y: 37, r: 8)
            )
        }
    }
}

/// Square-ish tile used when a vehicle has no cover photo: silhouette on a
/// plate tinted with the vehicle's identity colour, plus a tick rule as a
/// ground plane.
public struct VehiclePlaceholder: View {
    let style: BodyStyle
    let identity: AccentChoice

    public init(style: BodyStyle, identity: AccentChoice) {
        self.style = style
        self.identity = identity
    }

    public var body: some View {
        let tint = ClusterColor.accent(identity)
        ZStack {
            Rectangle().fill(ClusterColor.plateRaised)
            Rectangle().fill(tint.opacity(0.08))
            VehicleSilhouette(style, color: tint, lineWidth: 1.6)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
    }
}
