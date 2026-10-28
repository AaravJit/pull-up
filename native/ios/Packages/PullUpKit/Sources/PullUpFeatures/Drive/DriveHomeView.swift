import SwiftUI
import PullUpDesign
import PullUpDomain
import PullUpTelemetry

/// The Drive screen at rest: the vehicle you'll drive, recent drives and the
/// Start Drive button the picker grows out of.
struct DriveHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: Namespace.ID
    let showsButtonShape: Bool
    let onStart: () -> Void

    @State private var drives: [Drive] = []
    @State private var loadError: String?
    @State private var confirmingDeleteRejected = false

    /// Recent drives reload after a recording, a background upload or a delete.
    private struct RecentKey: Equatable {
        let result: UUID?
        let revision: Int
    }

    private var preferredVehicle: Vehicle? {
        guard case let .vehicle(id) = app.recorder.preferredChoice(among: app.garage.active) else { return nil }
        return app.garage.vehicle(id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                notices
                idleCluster
                recent
                standingsLink
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: Space.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .canvasBackground()
        .safeAreaInset(edge: .bottom) { startButton }
        .rootNavigation("Drive")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    app.driveOpen = false
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .accessibilityIdentifier("close-drive")
            }
        }
        .navigationDestination(for: Drive.self) { drive in
            DriveHistoryDetail(drive: drive)
        }
        .navigationDestination(for: LeaderboardRoute.self) { _ in LeaderboardView() }
        .task(id: RecentKey(result: app.recorder.lastResult?.id, revision: app.recorder.storedDrivesRevision)) { await loadDrives() }
        .refreshable { await loadDrives() }
        .confirmationDialog(
            app.recorder.rejectedUploads == 1 ? "Delete this drive?" : "Delete these drives?",
            isPresented: $confirmingDeleteRejected, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await app.recorder.deleteRejectedUploads() } }
        } message: {
            Text(app.recorder.rejectedUploads == 1
                 ? "It's removed from this phone. The server never accepted it, so no other copy exists."
                 : "They're removed from this phone. The server never accepted them, so no other copy exists.")
        }
    }

    private func loadDrives() async {
        guard let me = app.userID else { return }
        do {
            drives = try await app.backend.drives(owner: me, limit: 12)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let recovered = app.recorder.recoveredDrive {
            HStack(alignment: .top) {
                NoticeStrip("A drive from \(recovered.formatted(date: .abbreviated, time: .shortened)) was interrupted when the app closed. It was saved up to the last GPS fix.")
                Button("Dismiss") { app.recorder.dismissRecoveryNotice() }.font(ClusterFont.headline(.footnote))
            }
        }
        if app.recorder.pendingUploads > 0 {
            HStack(alignment: .top) {
                NoticeStrip("\(app.recorder.pendingUploads) drive\(app.recorder.pendingUploads == 1 ? "" : "s") saved on this device, waiting to upload.", tone: .estimate)
                Button("Retry") { Task { await app.recorder.syncPending() } }.font(ClusterFont.headline(.footnote))
            }
        }
        if app.recorder.rejectedUploads > 0 {
            let count = app.recorder.rejectedUploads
            HStack(alignment: .top) {
                NoticeStrip(count == 1
                            ? "Couldn't upload a drive: the server didn't accept it. It's still on this phone."
                            : "Couldn't upload \(count) drives: the server didn't accept them. They're still on this phone.",
                            tone: .caution)
                VStack(alignment: .trailing, spacing: Space.s) {
                    Button("Delete", role: .destructive) { confirmingDeleteRejected = true }
                    Button("Keep trying") { Task { await app.recorder.retryRejectedUploads() } }
                }
                .font(ClusterFont.headline(.footnote))
            }
            .accessibilityIdentifier("rejected-uploads")
        }
        if let interruption = app.recorder.interruption, app.recorder.lastResult == nil {
            NoticeStrip(interruption, tone: .caution)
        }
    }

    /// The vehicle the next drive will most likely use. No gauge at rest:
    /// there's nothing to measure yet, and the picker confirms the vehicle.
    private var idleCluster: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { VehicleArtwork(vehicle: preferredVehicle) }
                .clipShape(ChamferedRectangle(cut: Radius.photo))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(preferredVehicle?.displayName ?? (app.garage.active.isEmpty ? "No vehicles yet" : "Guest vehicle"))
                    .font(ClusterFont.title(.title2))
                    .foregroundStyle(ClusterColor.ink)
                Text(preferredVehicle == nil
                     ? "Start a drive and pick what you're driving."
                     : "Last driven. You'll confirm the vehicle before recording starts.")
                    .font(ClusterFont.body(.subheadline))
                    .foregroundStyle(ClusterColor.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Recent drives") {
                if !drives.isEmpty {
                    Text("\(drives.count)").font(ClusterFont.readout(.footnote)).foregroundStyle(ClusterColor.inkTertiary)
                }
            }
            if let loadError {
                ErrorLine(message: loadError) { Task { await loadDrives() } }
            } else if drives.isEmpty {
                Text("Your drives will appear here. Only you can see them unless you choose otherwise.")
                    .font(ClusterFont.body(.subheadline))
                    .foregroundStyle(ClusterColor.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(drives) { drive in
                        NavigationLink(value: drive) {
                            DriveRow(drive: drive, vehicle: app.garage.vehicle(drive.vehicleID))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var standingsLink: some View {
        NavigationLink(value: LeaderboardRoute()) {
            HStack {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Leaderboards")
                        .font(ClusterFont.headline())
                        .foregroundStyle(ClusterColor.ink)
                    Text("Distance, exploration and community. Opt-in only.")
                        .font(ClusterFont.body(.caption))
                        .foregroundStyle(ClusterColor.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(ClusterColor.inkTertiary)
            }
            .padding(Space.inset)
            .plate()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("open-leaderboards")
    }

    private var startButton: some View {
        Button(action: onStart) {
            HStack(spacing: Space.s) {
                Image(systemName: "steeringwheel")
                Text("Start drive")
            }
            .font(ClusterFont.headline())
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                if showsButtonShape {
                    ChamferedRectangle(cut: Radius.chamfer)
                        .fill(theme.accentFill)
                        .stageGeometry("stage", in: stage, enabled: !reduceMotion)
                } else {
                    ChamferedRectangle(cut: Radius.chamfer).fill(theme.accentColor.opacity(0.0))
                }
            }
            .opacity(showsButtonShape ? 1 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.s)
        .frame(maxWidth: Space.readableWidth)
        .frame(maxWidth: .infinity)
        .background(ClusterColor.canvas.opacity(0.94))
        .accessibilityIdentifier("start-drive")
        .accessibilityHint("Choose a vehicle. Recording doesn't start until you confirm.")
    }
}

struct LeaderboardRoute: Hashable {}

/// One drive in a history list.
struct DriveRow: View {
    @Environment(\.clusterTheme) private var theme
    let drive: Drive
    let vehicle: Vehicle?

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ClusterColor.inkSecondary)
                .frame(width: 40, height: 40)
                .background(ClusterColor.plate, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(drive.title)
                    .font(ClusterFont.headline())
                    .foregroundStyle(ClusterColor.ink)
                Text("\(drive.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(vehicle?.displayName ?? "Guest vehicle")")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            VStack(alignment: .trailing, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(Format.distance(drive.distanceMeters, theme.unit)).font(ClusterFont.readout(.title3))
                    Text(theme.unit.distanceLabel).font(ClusterFont.legend(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                }
                .foregroundStyle(ClusterColor.ink)
                if drive.validationStatus != .validated {
                    ValidationBadge(drive.validationStatus)
                } else {
                    Text("Top \(Format.speed(drive.topSpeed, theme.unit)) \(theme.unit.label)")
                        .font(ClusterFont.legend(.caption))
                        .foregroundStyle(ClusterColor.inkTertiary)
                }
            }
        }
        .padding(.vertical, Space.m)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Bell with unread count, opens notifications.
struct NotificationBell: View {
    @Environment(AppModel.self) private var app
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: app.unreadNotifications > 0 ? "bell.badge" : "bell")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ClusterColor.ink)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(app.unreadNotifications > 0 ? "Notifications, \(app.unreadNotifications) unread" : "Notifications")
        .onChange(of: app.pendingPush, initial: true) { _, route in
            guard route == .activity else { return }
            app.pendingPush = nil
            showing = true
        }
        .sheet(isPresented: $showing) {
            NavigationStack { NotificationsView() }
                .clusterTheme(app.themeStore.theme)
        }
    }
}
