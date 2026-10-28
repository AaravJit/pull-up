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
    @State private var conversation: ConversationTarget?
    @State private var glance: Vehicle?
    @State private var messageBusy = false
    @State private var reporting = false
    @State private var confirmingBlock = false
    @State private var blocked = false

    private var isMe: Bool { userID == app.userID }
    /// Blocked here, or anywhere else in the app since this screen loaded.
    private var isBlocked: Bool { blocked || app.blockedUsers.contains(userID) }
    private var handle: String { page.map { "@\($0.profile.username)" } ?? "this person" }

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
            if isBlocked {
                EmptyState(title: "Blocked", message: "You won't see each other's profiles, posts or meets, and \(handle) can't message you. Pull Up doesn't tell them.")
            } else if let page {
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
            if !isMe, page != nil, !isBlocked {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { reporting = true } label: { Label("Report \(handle)", systemImage: "flag") }
                        Button(role: .destructive) { confirmingBlock = true } label: { Label("Block", systemImage: "hand.raised") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Profile options")
                    .accessibilityIdentifier("profile-options")
                }
            }
        }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            if let page { ProfileEditorView(page: page) }
        }
        .sheet(isPresented: $reporting) {
            if let page {
                ReportPersonView(
                    person: stub(page),
                    question: "What's wrong with \(handle)'s profile?",
                    content: ReportedContent(.profile, id: userID),
                    onBlocked: { blocked = true }
                )
                .clusterTheme(app.themeStore.theme)
            }
        }
        .confirmationDialog("Block \(handle)?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await block() } }
        } message: {
            Text("You won't see each other's profiles, posts or meets, and they can't message you. Pull Up doesn't tell them.")
        }
        .sheet(item: $conversation) { target in
            NavigationStack { ThreadView(target: target, showsDone: true) }
                .clusterTheme(app.themeStore.theme)
        }
        .sheet(item: $glance) { vehicle in
            if let page { VehicleGlanceView(vehicle: vehicle, owner: stub(page)).clusterTheme(app.themeStore.theme) }
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
                    glanceButton(featured) { hero(featured) }
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
                        if !isMe, !drives.isEmpty { driveList(page) }
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
                HStack(spacing: Space.s) {
                    followButton(page)
                    messageButton(page)
                }
            }
            if let error { ErrorLine(message: error) }
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

    private func messageButton(_ page: ProfilePage) -> some View {
        Button {
            Task { await openConversation(page) }
        } label: {
            Label(messageBusy ? "Opening" : "Message", systemImage: "paperplane").frame(maxWidth: .infinity)
        }
        .buttonStyle(.clusterSecondary)
        .disabled(messageBusy)
        .accessibilityIdentifier("message-profile")
    }

    private func stub(_ page: ProfilePage) -> ProfileStub {
        ProfileStub(id: page.profile.id, username: page.profile.username, displayName: page.profile.displayName, avatarPath: page.profile.avatarPath)
    }

    private func openConversation(_ page: ProfilePage) async {
        messageBusy = true
        defer { messageBusy = false }
        do {
            conversation = try await app.conversation(with: stub(page))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
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

    /// Drives the server lets you see (RLS on `drives`). Each opens its
    /// totals, and the trimmed route only if the driver shared it.
    private func driveList(_ page: ProfilePage) -> some View {
        let shown = drives.sorted { $0.startedAt > $1.startedAt }.prefix(20)
        return VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Drives")
            ForEach(shown) { drive in
                NavigationLink {
                    SharedDriveView(drive: drive, owner: stub(page), vehicle: vehicles.first { $0.id == drive.vehicleID })
                } label: {
                    SharedDriveRow(drive: drive)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile-drive-\(drive.title)")
            }
            if drives.count > shown.count {
                Text("Latest \(shown.count) of \(drives.count).")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
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
                    glanceButton(vehicle) {
                        HStack(spacing: Space.m) {
                            VehicleArtwork(vehicle: vehicle).frame(width: 72, height: 46).clipShape(ChamferedRectangle(cut: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Legend("\(vehicle.year) · \(vehicle.kind.label)")
                                Text("\(vehicle.make) \(vehicle.model)").font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.m), GridItem(.flexible(), spacing: Space.m)], spacing: Space.l) {
                    ForEach(shown) { vehicle in glanceButton(vehicle) { GarageTile(vehicle: vehicle) } }
                }
            }
        }
    }

    /// Other people's vehicles open a glance with "Message owner"; your own
    /// are managed from the Garage tab.
    @ViewBuilder
    private func glanceButton<Content: View>(_ vehicle: Vehicle, @ViewBuilder label: () -> Content) -> some View {
        if isMe {
            label()
        } else {
            Button { glance = vehicle } label: { label() }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the vehicle, with a button to message the owner")
                .accessibilityIdentifier("glance-\(vehicle.model)")
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

    private func block() async {
        do {
            try await app.block(userID)
            blocked = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Report a person for something they put in the app: a post, a comment,
/// a meet or their profile. The same flow as reporting a message
/// (`ReportView`); what was reported goes to staff in `details`.
struct ReportPersonView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let person: ProfileStub
    let question: String
    /// What's reported. The server copies it for staff.
    let content: ReportedContent
    /// Called after "Also block" succeeds.
    var onBlocked: (() -> Void)?

    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var alsoBlock = false
    @State private var busy = false
    @State private var sent = false
    /// Filed already, so a retry after a failed block doesn't file it twice.
    @State private var reported = false
    @State private var error: String?

    private var handle: String { person.username.isEmpty ? "this person" : "@\(person.username)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if sent {
                        EmptyState(
                            title: "Thanks for reporting",
                            message: "Your report is saved with a copy of what you reported, for Pull Up to review. \(handle) isn't told who reported them."
                        )
                    } else {
                        Text(question)
                            .font(ClusterFont.headline())
                            .foregroundStyle(ClusterColor.ink)
                        VStack(spacing: 0) {
                            ForEach(ReportReason.allCases) { option in
                                Button {
                                    reason = option
                                } label: {
                                    HStack {
                                        Text(option.label).font(ClusterFont.body()).foregroundStyle(ClusterColor.ink)
                                        Spacer()
                                        if reason == option { Image(systemName: "checkmark").foregroundStyle(ClusterColor.verified) }
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(reason == option ? .isSelected : [])
                                Hairline()
                            }
                        }
                        FieldRow(label: "Anything else (optional)", text: $details, axis: .vertical)
                        PrivacyToggle(title: "Also block \(handle)", detail: "You won't see each other's posts, meets or profiles, and they can't message you.", isOn: $alsoBlock)
                        if let error { ErrorLine(message: error) }
                        Button {
                            Task { await submit() }
                        } label: {
                            Text(busy ? "Sending" : "Send report").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.cluster)
                        .disabled(reason == nil || busy)
                        .accessibilityIdentifier("send-report")
                    }
                }
                .padding(Space.gutter)
            }
            .canvasBackground()
            .clusterNavigation("Report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sent ? "Done" : "Cancel") { dismiss() } }
            }
        }
    }

    private func submit() async {
        guard let reason else { return }
        busy = true
        defer { busy = false }
        do {
            if !reported {
                try await app.backend.report(content, author: person.id, reason: reason, note: ReportDetails.note(details))
                reported = true
            }
            if alsoBlock {
                try await app.block(person.id)
                onBlocked?()
            }
            sent = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The reporter's own note, as the server keeps it (at most 1,000 characters).
enum ReportDetails {
    static let limit = 1000

    static func note(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
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
        _accent = State(initialValue: p.presentation.accent ?? .defaultAccent)
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
