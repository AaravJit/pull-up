import MapKit
import SwiftUI
import PullUpDesign
import PullUpDomain

/// Someone else's drive: its totals and, only if they shared it, the
/// trimmed route the server keeps for viewers (`drive_shared_routes`, which
/// RLS limits to people who can see the drive). It never asks for the
/// private track; that stays with the driver.
struct SharedDriveView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    let drive: Drive
    let owner: ProfileStub
    var vehicle: Vehicle?

    @State private var route: [[Coordinate]] = []
    @State private var isLoaded = false
    @State private var error: String?

    private var unit: SpeedUnit { theme.unit }
    private var segments: [[Coordinate]] { route.filter { $0.count > 1 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                totals
                routeSection
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.l)
        }
        .canvasBackground()
        .clusterNavigation(drive.title)
        .task { await load() }
        .accessibilityIdentifier("shared-drive")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend(drive.startedAt.formatted(date: .complete, time: .shortened))
            Text(drive.title)
                .font(ClusterFont.title(.title))
                .tracking(Tracking.title)
                .foregroundStyle(ClusterColor.ink)
                .accessibilityAddTraits(.isHeader)
            if !byline.isEmpty {
                Text(byline)
                    .font(ClusterFont.body(.subheadline))
                    .foregroundStyle(ClusterColor.inkSecondary)
            }
        }
    }

    private var byline: String {
        var parts: [String] = []
        if !owner.username.isEmpty { parts.append("@\(owner.username)") }
        if let vehicle { parts.append(vehicle.displayName) }
        return parts.joined(separator: " · ")
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .top, spacing: Space.l) {
                Readout("Distance", value: Format.distance(drive.distanceMeters, unit), unit: unit.distanceLabel, size: .large)
                Readout("Moving", value: Format.duration(drive.movingSeconds), size: .large)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) {
                SpecRow(label: "Elapsed", value: Format.duration(drive.elapsedSeconds))
                SpecRow(label: "Stopped", value: Format.duration(drive.stoppedSeconds))
                SpecRow(label: "Climb", value: "\(Format.elevation(drive.elevationGain, unit)) \(unit.elevationLabel)")
                SpecRow(label: "Descent", value: "\(Format.elevation(drive.elevationLoss, unit)) \(unit.elevationLabel)")
            }
        }
    }

    @ViewBuilder
    private var routeSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Route")
            if let error {
                ErrorLine(message: error) { Task { await load() } }
            } else if !isLoaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if segments.isEmpty {
                Text("Route not shared")
                    .font(ClusterFont.headline(.subheadline))
                    .foregroundStyle(ClusterColor.ink)
                    .accessibilityIdentifier("route-not-shared")
                Text("Only the totals are visible to you.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
            } else {
                Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        MapPolyline(coordinates: segment.map(\.clLocation))
                            .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .frame(height: 240)
                .clipShape(ChamferedRectangle(cut: Radius.chamfer))
                .accessibilityLabel("Map of the shared route")
                .accessibilityIdentifier("shared-route-map")
                Text("The start, the finish and any privacy zones are trimmed off.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
            }
        }
    }

    private func load() async {
        // Only the shared route: never `ownTrack`, which is the driver's alone.
        do {
            route = try await app.backend.sharedRoute(drive: drive.id) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
    }
}

/// One of someone else's drives in a profile's list.
struct SharedDriveRow: View {
    @Environment(\.clusterTheme) private var theme
    let drive: Drive

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(drive.title)
                    .font(ClusterFont.headline())
                    .foregroundStyle(ClusterColor.ink)
                Text(drive.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            VStack(alignment: .trailing, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(Format.distance(drive.distanceMeters, theme.unit)).font(ClusterFont.readout(.title3))
                    Text(theme.unit.distanceLabel).font(ClusterFont.legend(.caption2)).foregroundStyle(ClusterColor.inkSecondary)
                }
                .foregroundStyle(ClusterColor.ink)
                Text(Format.duration(drive.movingSeconds))
                    .font(ClusterFont.legend(.caption2))
                    .foregroundStyle(ClusterColor.inkTertiary)
            }
        }
        .padding(.vertical, Space.m)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
