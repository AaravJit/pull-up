import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// The You tab: who you are to others, then everything that's yours,
/// your vehicles, your drives, then settings. Driving starts here.
struct YouView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var page: ProfilePage?
    @State private var error: String?
    @State private var editing = false
    @State private var addingVehicle = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    identity
                    drive
                    garage
                    more
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: Space.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .canvasBackground()
            .refreshable { await load() }
            .rootNavigation("You")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: SettingsRoute()) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("open-settings")
                }
            }
            .navigationDestination(for: ProfileRoute.self) { ProfileView(userID: $0.id) }
            .navigationDestination(for: SettingsRoute.self) { _ in SettingsView() }
            .navigationDestination(for: YouRoute.self) { route in
                switch route {
                case .garage: GarageView()
                case .drives: DriveHistoryView()
                case .leaderboards: LeaderboardView()
                case .notifications: NotificationsView(showsDone: false)
                case .parts: PartsFinderView(vehicle: app.garage.active.first)
                }
            }
            .navigationDestination(for: Vehicle.ID.self) { VehicleDetailView(vehicleID: $0) }
            .task { await load() }
            .onChange(of: app.garageRequest, initial: true) { _, request in
                guard request > 0 else { return }
                app.garageRequest = 0
                path = NavigationPath([YouRoute.garage])
            }
            .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
                if let page { ProfileEditorView(page: page).sheetCanvas() }
            }
            .sheet(isPresented: $addingVehicle) { VehicleEditorView(vehicle: nil).sheetCanvas() }
        }
        .accessibilityIdentifier("you")
    }

    // MARK: Sections

    private var identity: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.l) {
                Avatar(name: page?.profile.displayName ?? app.account?.displayName ?? "You",
                       path: page?.profile.avatarPath ?? app.account?.avatarPath, size: 76)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(page?.profile.displayName ?? app.account?.displayName ?? " ")
                        .font(ClusterFont.title(.title2))
                        .foregroundStyle(ClusterColor.ink)
                        .lineLimit(2)
                    Text("@\(page?.profile.username ?? app.account?.username ?? "")")
                        .font(ClusterFont.body(.subheadline))
                        .foregroundStyle(ClusterColor.inkSecondary)
                    if let page {
                        HStack(spacing: Space.l) {
                            count(page.followerCount, "Followers")
                            count(page.followingCount, "Following")
                        }
                        .padding(.top, Space.xxs)
                    }
                }
                Spacer(minLength: 0)
            }
            if let bio = page?.profile.bio, !bio.isEmpty {
                Text(bio).font(ClusterFont.body()).foregroundStyle(ClusterColor.ink)
            }
            HStack(spacing: Space.s) {
                Button {
                    editing = true
                } label: {
                    Text("Edit profile").frame(maxWidth: .infinity)
                }
                .buttonStyle(.clusterSecondary)
                .disabled(page == nil)
                .accessibilityIdentifier("edit-profile")
                if let me = app.userID {
                    NavigationLink(value: ProfileRoute(id: me)) {
                        Text("View profile").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.clusterSecondary)
                    .accessibilityIdentifier("open-profile")
                }
            }
            if let error { ErrorLine(message: error) { Task { await load() } } }
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(Format.compactCount(value)).font(ClusterFont.readout(.subheadline)).foregroundStyle(ClusterColor.ink)
            Text(label).font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var drive: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Drive")
            Button {
                app.openDrive()
            } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: "steeringwheel")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(app.themeStore.theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(app.themeStore.theme.accentFill, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start a drive").font(ClusterFont.headline()).foregroundStyle(ClusterColor.ink)
                        Text("Pick a vehicle, then record. Drives stay private unless you share them.")
                            .font(ClusterFont.body(.footnote))
                            .foregroundStyle(ClusterColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ClusterColor.inkTertiary)
                }
                .padding(Space.inset)
                .plate()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Recording starts only after you pick a vehicle and confirm.")
            .accessibilityIdentifier("open-drive")
            RowGroup {
                NavRow(YouRoute.drives, title: "Drive history", symbol: "clock.arrow.circlepath")
                NavRow(YouRoute.leaderboards, title: "Leaderboards", symbol: "trophy", id: "open-leaderboards")
            }
        }
    }

    private var garage: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Garage") {
                if !app.garage.active.isEmpty {
                    NavigationLink("See all", value: YouRoute.garage)
                        .font(ClusterFont.headline(.subheadline))
                        .accessibilityIdentifier("open-garage")
                }
            }
            if app.garage.active.isEmpty {
                Button {
                    addingVehicle = true
                } label: {
                    HStack(spacing: Space.m) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(ClusterColor.plateRaised, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add a vehicle").font(ClusterFont.headline()).foregroundStyle(ClusterColor.ink)
                            Text("Optional. Make, model and year are enough.")
                                .font(ClusterFont.body(.footnote)).foregroundStyle(ClusterColor.inkSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Space.inset)
                    .plate()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("you-add-vehicle")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Space.m) {
                        ForEach(app.garage.active) { vehicle in
                            NavigationLink(value: vehicle.id) {
                                GarageTile(vehicle: vehicle).frame(width: 200)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
            }
        }
    }

    private var more: some View {
        RowGroup {
            NavRow(YouRoute.notifications, title: "Activity", symbol: "bell", badge: app.unreadNotifications)
            NavRow(YouRoute.parts, title: "Find parts", symbol: "wrench.and.screwdriver")
        }
    }

    private func load() async {
        guard let me = app.userID else { return }
        do {
            page = try await app.backend.profilePage(me)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum YouRoute: Hashable {
    case garage, drives, leaderboards, notifications, parts
}

/// Rows on one rounded surface, divided by inset hairlines: the grouped
/// list look without a List.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row
                    if index < rows.count - 1 { Hairline().padding(.leading, 56) }
                }
            }
        }
        .plate()
    }
}

/// A navigation row: symbol, title, optional badge, chevron.
struct NavRow<Value: Hashable>: View {
    let value: Value
    let title: String
    let symbol: String
    var badge = 0
    var id: String?

    init(_ value: Value, title: String, symbol: String, badge: Int = 0, id: String? = nil) {
        self.value = value
        self.title = title
        self.symbol = symbol
        self.badge = badge
        self.id = id
    }

    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ClusterColor.ink)
                    .frame(width: 28)
                Text(title).font(ClusterFont.body()).foregroundStyle(ClusterColor.ink)
                Spacer(minLength: Space.s)
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(ClusterFont.readout(.caption))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(ClusterColor.live, in: Capsule())
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ClusterColor.inkTertiary)
            }
            .padding(.horizontal, Space.inset)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(badge > 0 ? "\(badge) new" : "")
        .accessibilityIdentifier(id ?? "you-\(title)")
    }
}

/// Every drive on this account, newest first.
struct DriveHistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var drives: [Drive] = []
    @State private var isLoaded = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error {
                    ErrorLine(message: error) { Task { await load() } }
                } else if !isLoaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if drives.isEmpty {
                    EmptyState(title: "No drives yet", message: "Start a drive from You or Explore. Only you can see your drives unless you share one.")
                }
                ForEach(drives) { drive in
                    NavigationLink {
                        DriveHistoryDetail(drive: drive)
                    } label: {
                        DriveRow(drive: drive, vehicle: app.garage.vehicle(drive.vehicleID))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Space.gutter)
            .frame(maxWidth: Space.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .canvasBackground()
        .clusterNavigation("Drive history")
        .task(id: app.recorder.storedDrivesRevision) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let me = app.userID else { return }
        do {
            drives = try await app.backend.drives(owner: me, limit: 200)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
    }
}
