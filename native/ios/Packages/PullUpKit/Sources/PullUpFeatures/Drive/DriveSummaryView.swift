import Charts
import MapKit
import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain
import PullUpTelemetry

/// Post-drive summary. Used straight after recording (`isFresh`) and when
/// opening a drive from history.
struct DriveSummaryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let isFresh: Bool
    @State private var result: FinishedDrive
    @State private var title: String
    @State private var audience: Audience
    @State private var sharedRoute: [[Coordinate]]?
    @State private var shareMessage: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmingDelete = false
    @State private var deleteError: String?
    @State private var sharingSummary = false

    init(result: FinishedDrive, isFresh: Bool) {
        self.isFresh = isFresh
        _result = State(initialValue: result)
        _title = State(initialValue: result.drive.title)
        _audience = State(initialValue: result.drive.visibility)
    }

    private var drive: Drive { result.drive }
    private var unit: SpeedUnit { theme.unit }
    private var isStored: Bool { result.upload == .uploaded }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                if let deleteError { ErrorLine(message: deleteError) }
                // Why recording stopped on its own (Precise Location or
                // location access turned off mid-drive, the 24-hour limit).
                if isFresh, let interruption = app.recorder.interruption {
                    NoticeStrip(interruption, tone: .caution)
                }
                uploadNotice
                if result.track.count > 1 { routeMap }
                heroNumbers
                if result.speedSeries.count > 2 { speedChart }
                zeroToSixty
                details
                if result.speedSeries.count > 2 {
                    DriveProSection(drive: drive, track: result.track, series: result.speedSeries)
                }
                if isStored {
                    editSection
                    shareSection
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.l)
        }
        .canvasBackground()
        .clusterNavigation(isFresh ? "Drive summary" : drive.title)
        .toolbar {
            if isFresh {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("summary-done")
                }
            } else if isStored {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Send summary in a message", systemImage: "paperplane") { sharingSummary = true }
                        Button("Delete drive", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .sheet(isPresented: $sharingSummary) {
            // Totals only: messages never carry a route or GPS track.
            ShareToMessageView(shared: SharedRef(kind: .drive, id: drive.id))
        }
        .confirmationDialog("Delete this drive?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await delete() }
            }
        } message: {
            Text("The drive, its track and any shared route are removed from the server.")
        }
        .task {
            guard isStored else { return }
            sharedRoute = try? await app.backend.sharedRoute(drive: drive.id)
        }
        .accessibilityIdentifier("drive-summary")
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend(drive.startedAt.formatted(date: .complete, time: .shortened))
            Text(drive.title)
                .font(ClusterFont.title(.title))
                .tracking(Tracking.title)
                .foregroundStyle(ClusterColor.ink)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Space.m) {
                VehicleArtwork(vehicle: result.vehicle)
                    .frame(width: 56, height: 34)
                    .clipShape(ChamferedRectangle(cut: 4))
                Text(result.vehicle?.displayName ?? "Guest vehicle")
                    .font(ClusterFont.headline(.subheadline))
                    .foregroundStyle(ClusterColor.ink)
                    .accessibilityIdentifier("summary-vehicle-name")
                Spacer()
                if isStored {
                    // The demo backend has no server checks, so it never claims a verdict.
                    if app.isDemo {
                        Legend("Demo · not server-checked", color: ClusterColor.estimate)
                    } else {
                        ValidationBadge(drive.validationStatus)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var uploadNotice: some View {
        switch result.upload {
        case .uploaded:
            if drive.validationStatus == .flagged {
                NoticeStrip("The server flagged inconsistencies in this track. It still counts for you, but it won't appear on leaderboards until reviewed.", tone: .estimate)
            } else if drive.validationStatus == .rejected {
                NoticeStrip("The server couldn't verify this track, so it's excluded from leaderboards. Your own history keeps it.", tone: .caution)
            }
        case let .savedOffline(reason):
            NoticeStrip("Saved on this device and will upload automatically. \(reason)", tone: .estimate)
        case .rejected:
            NoticeStrip("The server didn't accept this drive, so it's kept on this device and not retried. You can delete it or try again from the Drive tab.", tone: .caution)
        case .tooShort:
            NoticeStrip("Too short to save: a drive needs at least 30 clean GPS fixes and 200 m. Nothing was stored.", tone: .caution)
        case .notSaved:
            NoticeStrip("Couldn't save this drive on your phone (storage may be full) and the upload didn't go through.", tone: .caution)
        }
    }

    private var routeMap: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                MapPolyline(coordinates: result.track.map(\.coordinate.clLocation))
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                if let shared = sharedRoute {
                    ForEach(Array(shared.enumerated()), id: \.offset) { _, segment in
                        MapPolyline(coordinates: segment.map(\.clLocation))
                            .stroke(ClusterColor.verified, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 240)
            .clipShape(ChamferedRectangle(cut: Radius.chamfer))
            .accessibilityLabel("Map of this drive's route")
            Text(sharedRoute == nil
                 ? "Only you can see this full route."
                 : "Dashed: the trimmed route others can see. Solid: your private full track.")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkTertiary)
        }
    }

    private var heroNumbers: some View {
        HStack(alignment: .top, spacing: Space.l) {
            Readout("Distance", value: Format.distance(drive.distanceMeters, unit), unit: unit.distanceLabel, size: .large)
            Readout("Moving", value: Format.duration(drive.movingSeconds), size: .large)
            Readout("Top", value: Format.speed(drive.topSpeed, unit), unit: unit.label, size: .large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speedChart: some View {
        let points = SeriesDownsampler.downsample(result.speedSeries, maxPoints: 320)
        let top = drive.topSpeed.map { unit.speed(fromMetersPerSecond: $0) }
        let hasAltitude = points.contains { $0.altitude != nil }
        let peak = points.map { unit.speed(fromMetersPerSecond: $0.speed) }.max() ?? 0
        return VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Speed")
            Chart {
                ForEach(points, id: \.offset) { point in
                    AreaMark(x: .value("Minutes", point.offset / 60), y: .value("Speed", unit.speed(fromMetersPerSecond: point.speed)))
                        .foregroundStyle(LinearGradient(colors: [theme.accentColor.opacity(0.28), theme.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Minutes", point.offset / 60), y: .value("Speed", unit.speed(fromMetersPerSecond: point.speed)))
                        .foregroundStyle(theme.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
                if let top {
                    RuleMark(y: .value("Top", top))
                        .foregroundStyle(ClusterColor.inkTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Legend("Top \(Int(top.rounded()))")
                        }
                }
            }
            .chartXAxisLabel("min")
            .chartYAxisLabel(unit.label)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(ClusterColor.rule)
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(ClusterColor.rule)
                    AxisValueLabel()
                }
            }
            .frame(height: 180)
            .accessibilityLabel("Speed over time")
            .accessibilityValue("Top speed \(Format.speed(drive.topSpeed, unit)) \(unit.label)")
            if let top, peak > top + 0.5 {
                // The line is every reading; top speed is a median of three,
                // so a single spike can sit above it.
                Text("The line shows every GPS reading. Top speed takes the middle of every three readings in a row, so one brief spike can sit above it.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if hasAltitude {
                SectionHeader("Elevation")
                Chart {
                    ForEach(points.filter { $0.altitude != nil }, id: \.offset) { point in
                        LineMark(x: .value("Minutes", point.offset / 60), y: .value("Elevation", unit.elevation(fromMeters: point.altitude ?? 0)))
                            .foregroundStyle(ClusterColor.inkSecondary)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxisLabel(unit.elevationLabel)
                .frame(height: 100)
                .accessibilityLabel("Elevation over time")
            }
        }
    }

    private var zeroToSixty: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Acceleration")
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Readout(Format.zeroToSixtyLabel, value: Format.zeroToSixty(drive.zeroToSixtySeconds), unit: "s",
                        quality: drive.zeroToSixtySeconds == nil ? .insufficient : .estimate, size: .large)
                Spacer()
            }
            Text(drive.zeroToSixtySeconds == nil
                 ? "No clean run from a standstill to 60 mph was detected."
                 : "Estimated from phone GPS at about one fix per second\(drive.zeroToSixtyQuality == .consistent ? ", with consistent data" : ""). It isn't a measured time. Pull Up doesn't rank speed or acceleration.")
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Details")
            SpecRow(label: "Elapsed", value: Format.duration(drive.elapsedSeconds))
            SpecRow(label: "Stopped", value: Format.duration(drive.stoppedSeconds))
            SpecRow(label: "Avg moving", value: "\(Format.speed(drive.averageMovingSpeed, unit)) \(unit.label)")
            SpecRow(label: "Climb", value: "\(Format.elevation(drive.elevationGain, unit)) \(unit.elevationLabel)")
            SpecRow(label: "Descent", value: "\(Format.elevation(drive.elevationLoss, unit)) \(unit.elevationLabel)")
            SpecRow(label: "GPS fixes used", value: "\(result.summary.acceptedSamples)")
            if result.summary.rejectedSamples > 0 {
                SpecRow(label: "Fixes rejected", value: "\(result.summary.rejectedSamples)")
            }
            if result.summary.gapDistanceMeters > 1 {
                SpecRow(label: "Bridged signal gaps", value: "\(Format.distance(result.summary.gapDistanceMeters, unit)) \(unit.distanceLabel)")
                Text("Distance across GPS gaps is a straight line, so the true distance was a little longer.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
                    .padding(.top, Space.xs)
            }
        }
    }

    private var editSection: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SectionHeader("Name and audience")
            FieldRow(label: "Title", text: $title)
            AudiencePicker(title: "Who can see this drive", selection: $audience)
            if let saveError { ErrorLine(message: saveError) }
            Button {
                Task { await save() }
            } label: {
                Text(isSaving ? "Saving" : "Save changes").frame(maxWidth: .infinity)
            }
            .buttonStyle(.clusterSecondary)
            .disabled(isSaving || (title == drive.title && audience == drive.visibility) || title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Route sharing")
            Text("Sharing publishes a trimmed copy of the route to people who can see this drive. The server removes the start and end, everything near your privacy zones, and rounds positions. Your full track never leaves your account.")
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let shareMessage { NoticeStrip(shareMessage, tone: .caution) }
            if sharedRoute == nil {
                Button {
                    Task { await share() }
                } label: {
                    Label("Share trimmed route", systemImage: "point.topleft.down.to.point.bottomright.curvepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(.clusterSecondary)
                .disabled(audience == .private)
                if audience == .private {
                    Text("This drive is private. Change its audience to share a route.")
                        .font(ClusterFont.body(.caption))
                        .foregroundStyle(ClusterColor.inkTertiary)
                }
            } else {
                Button {
                    Task { await unshare() }
                } label: {
                    Text("Stop sharing route").frame(maxWidth: .infinity)
                }
                .buttonStyle(.clusterSecondary)
            }
        }
    }

    // MARK: Actions

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            try await app.backend.updateDrive(drive.id, title: trimmed, audience: audience)
            result.drive.title = trimmed
            result.drive.visibility = audience
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func share() async {
        do {
            sharedRoute = try await app.backend.shareRoute(drive: drive.id)
            shareMessage = nil
        } catch {
            shareMessage = error.localizedDescription
        }
    }

    /// The server decides: the route counts as unshared only once it says so.
    private func unshare() async {
        do {
            try await app.backend.unshareRoute(drive: drive.id)
            sharedRoute = nil
            shareMessage = nil
        } catch {
            shareMessage = "Couldn't stop sharing, so the trimmed route is still visible to people who can see this drive. Try again."
        }
    }

    private func delete() async {
        do {
            // Through the recorder, so a copy still waiting on this phone
            // goes too and isn't uploaded again.
            try await app.recorder.deleteDrive(drive.id)
            deleteError = nil
            dismiss()
        } catch {
            deleteError = "Couldn't delete this drive. It's still saved. Try again."
        }
    }
}

/// Loads a stored drive's private track, then shows the summary.
struct DriveHistoryDetail: View {
    @Environment(AppModel.self) private var app
    let drive: Drive
    @State private var result: FinishedDrive?
    @State private var error: String?

    var body: some View {
        Group {
            if let result {
                DriveSummaryView(result: result, isFresh: false)
            } else if let error {
                ErrorLine(message: error) { Task { await load() } }.padding(Space.gutter)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .canvasBackground()
        .task { await load() }
    }

    private func load() async {
        do {
            let track = try await app.backend.ownTrack(drive: drive.id)
            // The server doesn't keep stationary markers; infer them so a
            // stop at a light isn't shown as lost signal.
            let engine = TelemetryEngine.replay(
                track, startedAt: drive.startedAt, stationaryPauses: TelemetryEngine.inferredStationaryPauses(track)
            )
            result = FinishedDrive(
                drive: drive, summary: engine.summary(endedAt: drive.endedAt), track: track,
                speedSeries: engine.speedSeries, vehicle: app.garage.vehicle(drive.vehicleID), upload: .uploaded
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
