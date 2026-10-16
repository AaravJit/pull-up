import SwiftUI
import PullUpDesign
import PullUpDomain
import PullUpTelemetry

/// Drive tab at rest: the idle cluster, the last vehicle, recent drives and
/// the Start Drive button the picker grows out of.
struct DriveHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: Namespace.ID
    let showsButtonShape: Bool
    let onStart: () -> Void

    @State private var drives: [Drive] = []
    @State private var loadError: String?

    private var preferredVehicle: Vehicle? {
        guard case let .vehicle(id) = app.recorder.preferredChoice(among: app.garage.active) else { return nil }
        return app.garage.vehicle(id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(alignment: .bottom) {
                    ScreenTitle("Drive", subtitle: Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                    NotificationBell()
                }
                notices
                idleCluster
                recent
                standingsLink
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xl)
        }
        .canvasBackground()
        .safeAreaInset(edge: .bottom) { startButton }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Drive.self) { drive in
            DriveHistoryDetail(drive: drive)
        }
        .navigationDestination(for: LeaderboardRoute.self) { _ in LeaderboardView() }
        .task(id: app.recorder.lastResult?.id) { await loadDrives() }
        .refreshable { await loadDrives() }
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
        if let interruption = app.recorder.interruption, app.recorder.lastResult == nil {
            NoticeStrip(interruption, tone: .caution)
        }
    }

    /// A resting gauge: no speed, no fake numbers. It shows the chosen style
    /// and unit so the user sees what the dashboard will look like.
    private var idleCluster: some View {
        VStack(spacing: Space.l) {
            Speedometer(SpeedometerReading(speed: nil, topSpeed: nil, unit: theme.unit), style: theme.speedometer)
                .frame(maxWidth: 300)
                .frame(height: theme.speedometer == .analog ? 260 : 180)
                .frame(maxWidth: .infinity)
                .opacity(0.9)
            HStack(spacing: Space.m) {
                VehicleArtwork(vehicle: preferredVehicle)
                    .frame(width: 84, height: 50)
                    .clipShape(ChamferedRectangle(cut: Radius.chamferSmall))
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Legend(preferredVehicle == nil ? "Ready" : "Ready · last driven")
                    Text(preferredVehicle?.displayName ?? (app.garage.active.isEmpty ? "No vehicles yet" : "Guest vehicle"))
                        .font(ClusterFont.headline())
                        .foregroundStyle(ClusterColor.ink)
                    Text("You'll confirm the vehicle before recording.")
                        .font(ClusterFont.body(.caption))
                        .foregroundStyle(ClusterColor.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.m)
            .plate()
            .accessibilityElement(children: .combine)
        }
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
                    Legend("Standings")
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
            .padding(Space.m)
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
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(ClusterColor.accentPrefersDarkText(theme.accent) ? ClusterColor.onAccent : .white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background {
                if showsButtonShape {
                    ChamferedRectangle(cut: Radius.chamfer)
                        .fill(theme.accentColor)
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
            Rectangle()
                .fill(vehicle.map { ClusterColor.accent($0.identityColor) } ?? ClusterColor.ruleStrong)
                .frame(width: 3, height: 44)
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
                    Text(theme.unit.distanceLabel).font(ClusterFont.legend(.caption2)).foregroundStyle(ClusterColor.inkSecondary)
                }
                .foregroundStyle(ClusterColor.ink)
                if drive.validationStatus != .validated {
                    ValidationBadge(drive.validationStatus)
                } else {
                    Text("Top \(Format.speed(drive.topSpeed, theme.unit)) \(theme.unit.label)")
                        .font(ClusterFont.legend(.caption2))
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
        .sheet(isPresented: $showing) {
            NavigationStack { NotificationsView() }
                .clusterTheme(app.themeStore.theme)
        }
    }
}
