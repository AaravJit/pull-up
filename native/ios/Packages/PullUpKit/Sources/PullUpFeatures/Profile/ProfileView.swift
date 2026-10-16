import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// A person's page. Its owner picks the layout, featured vehicle and accent,
/// and those choices render for every visitor.
struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var appTheme
    let userID: UserID

    @State private var page: ProfilePage?
    @State private var vehicles: [Vehicle] = []
    @State private var drives: [Drive] = []
    @State private var error: String?
    @State private var editing = false
    @State private var followBusy = false

    private var isMe: Bool { userID == app.userID }

    private var theme: ClusterTheme {
        var theme = appTheme
        if let accent = page?.profile.presentation.accent { theme.accent = accent }
        return theme
    }

    private var featured: Vehicle? {
        let id = page?.profile.presentation.featuredVehicleID
        return vehicles.first { $0.id == id } ?? vehicles.first
    }

    var body: some View {
        Group {
            if let page {
                content(page)
            } else if let error {
                ErrorLine(message: error) { Task { await load() } }.padding(Space.gutter)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .canvasBackground()
        .clusterNavigation(page.map { "@\($0.profile.username)" } ?? "Profile")
        .environment(\.clusterTheme, theme)
        .tint(theme.accentColor)
        .toolbar {
            if isMe {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: SettingsRoute()) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("open-settings")
                }
            }
        }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            if let page { ProfileEditorView(page: page) }
        }
        .task { await load() }
        .accessibilityIdentifier("profile")
    }

    @ViewBuilder
    private func content(_ page: ProfilePage) -> some View {
        let layout = page.profile.presentation.layout
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if layout == .showcase, let featured, page.canViewContent {
                    hero(featured)
                }
                VStack(alignment: .leading, spacing: Space.xl) {
                    identity(page, compact: layout == .garage)
                    if !page.canViewContent {
                        NoticeStrip(page.profile.visibility == .friends
                                    ? "Only friends can see \(page.profile.displayName)'s garage and drives."
                                    : "\(page.profile.displayName)'s profile is private.")
                    } else {
                        switch layout {
                        case .logbook:
                            if page.profile.presentation.showStats { stats(big: true) }
                            garage(list: true)
                        case .garage:
                            garage(list: false)
                            if page.profile.presentation.showStats { stats(big: false) }
                        case .showcase:
                            if page.profile.presentation.showStats { stats(big: false) }
                            garage(list: false, excluding: featured?.id)
                        }
                    }
                }
                .padding(.horizontal, Space.gutter)
            }
            .padding(.bottom, Space.xxl)
        }
        .refreshable { await load() }
    }

    private func hero(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay { VehicleArtwork(vehicle: vehicle) }
                .clipped()
            Rectangle().fill(ClusterColor.accent(vehicle.identityColor)).frame(height: 3)
            HStack {
                Legend("Featured · \(vehicle.year)")
                Text("\(vehicle.make) \(vehicle.model)").font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.s)
        }
    }

    private func identity(_ page: ProfilePage, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .center, spacing: Space.m) {
                Avatar(name: page.profile.displayName, path: page.profile.avatarPath, size: compact ? 52 : 68)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Text(page.profile.displayName)
                            .font(ClusterFont.title(compact ? .title3 : .title2))
                            .foregroundStyle(ClusterColor.ink)
                        if page.isVerifiedOrganizer {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(ClusterColor.verified)
                                .accessibilityLabel("Verified organiser")
                        }
                    }
                    Text("@\(page.profile.username)").font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
                }
                Spacer()
            }
            if !page.profile.bio.isEmpty {
                Text(page.profile.bio).font(ClusterFont.body()).foregroundStyle(ClusterColor.ink)
            }
            HStack(spacing: Space.xl) {
                Readout("Followers", value: Format.compactCount(page.followerCount), size: .small)
                Readout("Following", value: Format.compactCount(page.followingCount), size: .small)
                Readout("Vehicles", value: "\(vehicles.count)", size: .small)
                Spacer()
            }
            if isMe {
                Button {
                    editing = true
                } label: {
                    Text("Edit profile").frame(maxWidth: .infinity)
                }
                .buttonStyle(.clusterSecondary)
                .accessibilityIdentifier("edit-profile")
            } else {
                followButton(page)
            }
        }
    }

    private func followButton(_ page: ProfilePage) -> some View {
        let state = page.relationship.iFollow
        let title = state == "accepted" ? "Following" : state == "pending" ? "Requested" : "Follow"
        return Button {
            Task { await toggleFollow(page) }
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(ClusterButtonStyle(state == nil ? .primary : .secondary))
        .disabled(followBusy)
    }

    private func stats(big: Bool) -> some View {
        let distance = drives.reduce(0) { $0 + $1.distanceMeters }
        let moving = drives.reduce(0) { $0 + $1.movingSeconds }
        return VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Logbook")
            HStack(alignment: .top, spacing: Space.l) {
                Readout("Distance", value: Format.distance(distance, appTheme.unit), unit: appTheme.unit.distanceLabel, size: big ? .large : .medium)
                Readout("Drives", value: "\(drives.count)", size: big ? .large : .medium)
                Readout("Seat time", value: Format.duration(moving), size: big ? .large : .medium)
            }
            if drives.isEmpty {
                Text(isMe ? "Your drives are private by default, so visitors see zeros unless you change drive visibility." : "No drives visible to you.")
                    .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkTertiary)
            }
        }
    }

    private func garage(list: Bool, excluding: UUID? = nil) -> some View {
        let shown = vehicles.filter { $0.id != excluding }
        return VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Garage")
            if shown.isEmpty {
                Text(vehicles.isEmpty ? "No vehicles to show." : "Only the featured vehicle.")
                    .font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
            } else if list {
                ForEach(shown) { vehicle in
                    HStack(spacing: Space.m) {
                        VehicleArtwork(vehicle: vehicle).frame(width: 72, height: 46).clipShape(ChamferedRectangle(cut: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Legend("\(vehicle.year) · \(vehicle.kind.label)")
                            Text("\(vehicle.make) \(vehicle.model)").font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.m), GridItem(.flexible(), spacing: Space.m)], spacing: Space.l) {
                    ForEach(shown) { GarageTile(vehicle: $0) }
                }
            }
        }
    }

    private func load() async {
        do {
            page = try await app.backend.profilePage(userID)
            if isMe {
                vehicles = app.garage.active
            } else {
                vehicles = (try? await app.backend.vehicles(owner: userID)) ?? []
            }
            drives = (try? await app.backend.drives(owner: userID, limit: 500)) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggleFollow(_ page: ProfilePage) async {
        followBusy = true
        defer { followBusy = false }
        do {
            if page.relationship.iFollow == nil {
                try await app.backend.follow(userID)
            } else {
                try await app.backend.unfollow(userID)
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProfileEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let page: ProfilePage

    @State private var displayName: String
    @State private var username: String
    @State private var bio: String
    @State private var audience: Audience
    @State private var layout: ProfilePresentation.Layout
    @State private var featured: UUID?
    @State private var useOwnAccent: Bool
    @State private var accent: AccentChoice
    @State private var showStats: Bool
    @State private var error: String?
    @State private var saving = false

    init(page: ProfilePage) {
        self.page = page
        let p = page.profile
        _displayName = State(initialValue: p.displayName)
        _username = State(initialValue: p.username)
        _bio = State(initialValue: p.bio)
        _audience = State(initialValue: p.visibility)
        _layout = State(initialValue: p.presentation.layout)
        _featured = State(initialValue: p.presentation.featuredVehicleID)
        _useOwnAccent = State(initialValue: p.presentation.accent != nil)
        _accent = State(initialValue: p.presentation.accent ?? .sodium)
        _showStats = State(initialValue: p.presentation.showStats)
    }

    private var usernameValid: Bool {
        username.range(of: "^[a-z0-9._]{3,30}$", options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    FieldRow(label: "Name", text: $displayName)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        FieldRow(label: "Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !usernameValid {
                            Text("3–30 characters: lowercase letters, numbers, dots and underscores.")
                                .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.caution)
                        }
                    }
                    FieldRow(label: "Bio", text: $bio, axis: .vertical)
                    AudiencePicker(title: "Who can see your profile", selection: $audience)
                    VStack(alignment: .leading, spacing: Space.s) {
                        Legend("Layout")
                        SwitchBank(ProfilePresentation.Layout.allCases, selection: $layout) { $0.label }
                        Text(layoutExplanation).font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                    }
                    if !app.garage.active.isEmpty {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Legend("Featured vehicle")
                            Picker("Featured vehicle", selection: $featured) {
                                Text("First in garage").tag(UUID?.none)
                                ForEach(app.garage.active.filter { $0.visibility != .private }) { Text($0.displayName).tag(Optional($0.id)) }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        Toggle("Profile accent", isOn: $useOwnAccent)
                        if useOwnAccent { AccentSwatches(selection: $accent) }
                        Text("Visitors see your page in this colour.").font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                    }
                    Toggle("Show logbook stats", isOn: $showStats)
                    if let error { ErrorLine(message: error) }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.l)
            }
            .canvasBackground()
            .clusterNavigation("Edit profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving" : "Save") { Task { await save() } }
                        .disabled(saving || !usernameValid || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var layoutExplanation: String {
        switch layout {
        case .showcase: "Your featured vehicle leads, full width."
        case .garage: "A compact header with your garage grid first."
        case .logbook: "Driving stats first, vehicles as a list."
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let presentation = ProfilePresentation(layout: layout, featuredVehicleID: featured, accent: useOwnAccent ? accent : nil, showStats: showStats)
        do {
            try await app.backend.updateProfile(ProfileUpdate(
                displayName: displayName.trimmingCharacters(in: .whitespaces), username: username, bio: bio,
                countryCode: page.profile.countryCode, regionCode: page.profile.regionCode, audience: audience, presentation: presentation
            ))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
