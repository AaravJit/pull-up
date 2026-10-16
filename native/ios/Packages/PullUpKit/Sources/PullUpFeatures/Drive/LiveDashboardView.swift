import MapKit
import SwiftUI
import UIKit
import PullUpDesign
import PullUpDomain
import PullUpTelemetry

/// Full-screen instrument cluster while a drive records.
struct LiveDashboardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let stage: Namespace.ID

    @State private var confirmingDiscard = false

    private var recorder: DriveRecorder { app.recorder }
    private var live: LiveTelemetry { recorder.live }

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: Space.xl) {
                    VStack(spacing: Space.m) {
                        statusBar
                        speedometer
                    }
                    VStack(spacing: Space.m) {
                        notices
                        metricsGrid(columns: 2)
                        Spacer(minLength: 0)
                        controls
                    }
                }
            } else {
                VStack(spacing: Space.l) {
                    statusBar
                    notices
                    speedometer
                    metricsGrid(columns: 3)
                    if recorder.route.count > 1 { miniMap }
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(ClusterColor.canvas)
                .stageGeometry("stage", in: stage, enabled: !reduceMotion)
                .ignoresSafeArea()
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Discard this drive?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard drive", role: .destructive) { Task { await recorder.discard() } }
        } message: {
            Text("Nothing from this drive will be saved.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-dashboard")
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(alignment: .center, spacing: Space.m) {
            HStack(spacing: Space.s) {
                LiveDot()
                Text("REC")
                    .font(ClusterFont.legend(.caption))
                    .tracking(Tracking.legend)
                    .foregroundStyle(ClusterColor.live)
                Text(Format.duration(live.elapsedSeconds))
                    .font(ClusterFont.readout(.headline))
                    .foregroundStyle(ClusterColor.ink)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")
            .accessibilityValue(Format.spokenDuration(live.elapsedSeconds))

            Spacer(minLength: Space.s)

            VStack(alignment: .center, spacing: 0) {
                Legend(recorder.vehicle == nil ? "Guest" : "Vehicle")
                Text(recorder.vehicle?.displayName ?? "Guest vehicle")
                    .font(ClusterFont.headline(.subheadline))
                    .foregroundStyle(ClusterColor.ink)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("live-vehicle-name")

            Spacer(minLength: Space.s)

            HStack(spacing: Space.xs) {
                SignalBars(bars: live.signal.bars, tint: signalTint)
                Text(live.horizontalAccuracy.map { "±\(Format.accuracy($0, theme.unit))" } ?? "––")
                    .font(ClusterFont.readout(.caption))
                    .foregroundStyle(ClusterColor.inkSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("GPS")
            .accessibilityValue(live.signal.label)
        }
    }

    private var signalTint: Color {
        switch live.signal {
        case .excellent, .good: ClusterColor.verified
        case .fair: ClusterColor.estimate
        case .poor, .none: ClusterColor.caution
        }
    }

    @ViewBuilder
    private var notices: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if recorder.usesReplay {
                NoticeStrip("Demo: replaying a recorded track instead of live GPS.", tone: .estimate)
            }
            switch live.signalState {
            case .acquiring:
                NoticeStrip("Waiting for a GPS fix. Speeds appear once the signal is good enough to trust.")
            case let .lost(since):
                NoticeStrip("GPS signal lost \(since.formatted(.relative(presentation: .numeric))). Distance will be bridged with a straight line and flagged in the summary.", tone: .caution)
            case .tracking:
                if recorder.isStationary {
                    NoticeStrip("Stopped. Location updates are paused to save battery and resume when you move.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Gauge

    private var speedometer: some View {
        let reading = SpeedometerReading(
            speed: live.currentSpeed.map { theme.unit.speed(fromMetersPerSecond: $0) },
            topSpeed: live.topSpeed.map { theme.unit.speed(fromMetersPerSecond: $0) },
            unit: theme.unit,
            isDerived: live.currentSpeedIsDerived
        )
        return Speedometer(reading, style: theme.speedometer)
            .frame(maxWidth: 360)
            .frame(height: theme.speedometer == .analog ? 300 : 210)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : Motion.needle, value: reading)
            .accessibilityIdentifier("live-speedometer")
    }

    // MARK: Metrics

    private func metricsGrid(columns: Int) -> some View {
        let metrics = theme.dashboard
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.m, alignment: .leading), count: columns), alignment: .leading, spacing: Space.m) {
            ForEach(metrics) { metric in
                let value = DashboardValue(metric: metric, live: live, unit: theme.unit)
                Readout(value.legend, value: value.value, unit: value.unit, quality: value.quality, size: .small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Space.s)
                    .overlay(alignment: .top) { Hairline(color: ClusterColor.ruleStrong) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drive metrics")
    }

    private var miniMap: some View {
        Map(interactionModes: []) {
            MapPolyline(coordinates: recorder.route.map(\.clLocation))
                .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let last = recorder.route.last {
                Annotation("", coordinate: last.clLocation) {
                    Circle().fill(theme.accentColor).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .frame(height: 110)
        .clipShape(ChamferedRectangle(cut: Radius.chamferSmall))
        .accessibilityLabel("Route so far")
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: Space.m) {
            Button {
                confirmingDiscard = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24)
            }
            .buttonStyle(.clusterSecondary)
            .accessibilityLabel("Discard drive")
            .accessibilityIdentifier("discard-drive")

            HoldToStopButton(isBusy: recorder.phase == .finishing) {
                Task { await recorder.finish() }
            }
        }
    }
}

/// What one dashboard tile shows, already formatted. Estimates carry a
/// quality so the tile can mark them.
struct DashboardValue {
    let legend: String
    let value: String
    let unit: String?
    let quality: MeasurementQuality?

    init(metric: DashboardMetric, live: LiveTelemetry, unit: SpeedUnit) {
        legend = metric.label
        switch metric {
        case .topSpeed:
            value = Format.speed(live.topSpeed, unit); self.unit = unit.label; quality = nil
        case .averageSpeed:
            value = Format.speed(live.averageMovingSpeed, unit); self.unit = unit.label; quality = nil
        case .rollingAverage:
            value = Format.speed(live.rollingAverageSpeed, unit); self.unit = unit.label; quality = nil
        case .distance:
            value = Format.distance(live.distanceMeters, unit); self.unit = unit.distanceLabel; quality = nil
        case .elapsed:
            value = Format.duration(live.elapsedSeconds); self.unit = nil; quality = nil
        case .movingTime:
            value = Format.duration(live.movingSeconds); self.unit = nil; quality = nil
        case .stoppedTime:
            value = Format.duration(live.stoppedSeconds); self.unit = nil; quality = nil
        case .altitude:
            // Phone GPS altitude is good to roughly ±10 m at best.
            value = Format.elevation(live.altitude, unit); self.unit = unit.elevationLabel; quality = live.altitude == nil ? .insufficient : .estimate
        case .elevationGain:
            value = Format.elevation(live.elevationGain, unit); self.unit = unit.elevationLabel; quality = nil
        case .elevationLoss:
            value = Format.elevation(live.elevationLoss, unit); self.unit = unit.elevationLabel; quality = nil
        case .zeroToSixty:
            value = Format.zeroToSixty(live.zeroToSixty?.duration); self.unit = "s"
            quality = live.zeroToSixty.map { min($0.quality, .estimate) } ?? .insufficient
        case .gpsAccuracy:
            value = live.horizontalAccuracy.map { "±" + Format.accuracy($0, unit) } ?? Format.placeholder
            self.unit = unit.elevationLabel; quality = nil
        case .heading:
            value = Format.heading(live.heading); self.unit = nil; quality = nil
        }
    }
}

/// Stop control that needs a deliberate one-second hold, so a bump on a
/// mount can't end a drive. VoiceOver gets a plain activate action.
struct HoldToStopButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isBusy: Bool
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var fired = 0

    private let holdDuration = 1.0

    var body: some View {
        ZStack(alignment: .leading) {
            ChamferedRectangle(cut: Radius.chamferSmall).fill(ClusterColor.live.opacity(0.18))
            GeometryReader { proxy in
                ChamferedRectangle(cut: Radius.chamferSmall)
                    .fill(ClusterColor.live)
                    .frame(width: max(0, proxy.size.width * progress))
            }
            HStack(spacing: Space.s) {
                if isBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "stop.fill")
                }
                Text(isBusy ? "Saving" : progress > 0 ? "Keep holding" : "Hold to stop")
            }
            .font(ClusterFont.headline())
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(progress > 0.5 ? .white : ClusterColor.ink)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 54)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 40) {
            fired += 1
            action()
        } onPressingChanged: { pressing in
            if pressing {
                withAnimation(.linear(duration: holdDuration)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .disabled(isBusy)
        .sensoryFeedback(.success, trigger: fired)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stop and save drive")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityIdentifier("hold-to-stop")
    }
}

extension Coordinate {
    var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
