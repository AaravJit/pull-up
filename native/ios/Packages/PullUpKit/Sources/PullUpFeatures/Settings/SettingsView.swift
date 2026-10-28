import MapKit
import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var privacy: PrivacySettings?
    @State private var savedPrivacy: PrivacySettings?
    @State private var privacyError: String?
    @State private var deleting = false
    @State private var showingPro = false
    @State private var proHighlight: ProFeature?
    @State private var showsAccents = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var store = app.themeStore
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                if app.pro.showsEntryPoints { proRow }
                appearance(theme: $store.theme)
                privacySection
                zonesLink
                dashboard(theme: $store.theme)
                account
                about
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.l)
            .frame(maxWidth: Space.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .canvasBackground()
        .clusterNavigation("Settings")
        .task { await loadPrivacy() }
        .onChange(of: privacy) { _, value in
            guard let value, value != savedPrivacy else { return }
            Task { await savePrivacy(value) }
        }
        .sheet(isPresented: $deleting) { DeleteAccountView() }
        .proSheet(isPresented: $showingPro, highlight: proHighlight)
        .task { await app.refreshAccount() }
        .accessibilityIdentifier("settings")
    }

    // MARK: Pro

    private var proRow: some View {
        Button {
            proHighlight = nil
            showingPro = true
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: "gauge.open.with.lines.needle.67percent.and.arrowtriangle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(app.themeStore.theme.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull Up Pro").font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                    Text(proSummary).font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(ClusterColor.inkTertiary)
            }
            .padding(Space.m)
            .plate()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("open-pro")
    }

    private var proSummary: String {
        let entitlement = app.pro.entitlement
        guard entitlement.isPro else { return "Extra faces, colours, drive analytics and export." }
        if let expires = entitlement.expiresAt {
            return "Active · \(entitlement.autoRenew ? "renews" : "ends") \(expires.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Active"
    }

    private func openPro(_ feature: ProFeature) {
        proHighlight = feature
        showingPro = true
    }

    // MARK: Look

    private func appearance(theme: Binding<ClusterTheme>) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SectionHeader("Appearance")
            HStack(spacing: Space.m) {
                ForEach(AppearancePreference.allCases) { option in
                    AppearanceTile(option: option, isSelected: theme.wrappedValue.appearance == option) {
                        withAnimation(Motion.resolved(Motion.select, reduceMotion: reduceMotion)) { theme.wrappedValue.appearance = option }
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: theme.wrappedValue.appearance)
            Text(theme.wrappedValue.appearance == .dark
                 ? "True black, edge to edge. Easy on OLED displays at night."
                 : theme.wrappedValue.appearance == .light ? "Always light." : "Follows your iPhone's Light and Dark setting, with OLED black in Dark.")
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
            DisclosureGroup(isExpanded: $showsAccents.animation(Motion.reveal)) {
                VStack(alignment: .leading, spacing: Space.s) {
                    AccentSwatches(selection: theme.accent, choices: app.pro.showsEntryPoints ? AccentChoice.allCases : AccentChoice.standard, locked: { $0.isPro && !app.pro.isPro }) {
                        openPro(.accentPalettes)
                    }
                    if theme.wrappedValue.accent != .defaultAccent {
                        Button("Use Electric Blue") { theme.wrappedValue.accent = .defaultAccent }
                            .font(ClusterFont.headline(.footnote))
                    }
                }
                .padding(.top, Space.m)
            } label: {
                HStack {
                    Text("Accent colour").font(ClusterFont.body()).foregroundStyle(ClusterColor.ink)
                    Spacer()
                    Circle().fill(theme.wrappedValue.accentColor).frame(width: 14, height: 14)
                    Text(theme.wrappedValue.accent.label).font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
                }
            }
            .tint(ClusterColor.inkSecondary)
            .accessibilityIdentifier("accent-disclosure")
        }
    }

    private func dashboard(theme: Binding<ClusterTheme>) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SectionHeader("Driving")
            VStack(alignment: .leading, spacing: Space.s) {
                Legend("Units")
                SwitchBank(SpeedUnit.allCases, selection: theme.unit) { $0 == .mph ? "MPH · mi · ft" : "KM/H · km · m" }
            }
            VStack(alignment: .leading, spacing: Space.s) {
                Legend("Speedometer")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)], spacing: Space.s) {
                    ForEach(SpeedometerStyle.allCases.filter { !$0.isPro || app.pro.showsEntryPoints }) { style in
                        let locked = style.isPro && !app.pro.isPro
                        SpeedometerChoice(style: style, unit: theme.wrappedValue.unit, isSelected: theme.wrappedValue.speedometer == style, locked: locked) {
                            if locked {
                                openPro(.speedometerFaces)
                            } else {
                                withAnimation(Motion.select) { theme.wrappedValue.speedometer = style }
                            }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: theme.wrappedValue.speedometer)
                Text("Previews show a sample reading.").font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkTertiary)
            }
            NavigationLink {
                DashboardLayoutView(metrics: theme.dashboard)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dashboard tiles").font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                        Text(theme.wrappedValue.dashboard.map(\.label).joined(separator: " · "))
                            .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(ClusterColor.inkTertiary)
                }
                .padding(Space.inset)
                .plate()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Privacy

    @ViewBuilder
    private var privacySection: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SectionHeader("Privacy")
            if let privacyError {
                if privacy == nil {
                    ErrorLine(message: privacyError) { Task { await loadPrivacy() } }
                } else {
                    ErrorLine(message: privacyError)
                }
            }
            if let binding = Binding($privacy) {
                AudiencePicker(title: "Profile", selection: binding.profileVisibility)
                AudiencePicker(title: "New vehicles default to", selection: binding.defaultVehicleVisibility)
                AudiencePicker(title: "Drive history", selection: binding.driveHistoryVisibility)
                PrivacyToggle(title: "Allow route sharing", detail: "Off: no route ever leaves your account, even for drives you share.", isOn: binding.allowRouteSharing)
                if binding.wrappedValue.allowRouteSharing {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Legend("Trim shared routes by \(Int(binding.wrappedValue.routeEndpointTrimMeters)) m at each end")
                        Slider(value: binding.routeEndpointTrimMeters, in: 200...1_500, step: 50)
                            .accessibilityLabel("Endpoint trim")
                            .accessibilityValue("\(Int(binding.wrappedValue.routeEndpointTrimMeters)) metres")
                        Text("The server also adds a random extra 0–250 m so start points can't be worked out from several drives.")
                            .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkTertiary)
                    }
                }
                PrivacyToggle(title: "Show me at meets by default", detail: "When on, new Going RSVPs list your name to other attendees. You can change it per meet.", isOn: binding.showEventAttendance)
                PrivacyToggle(title: "Appear on leaderboards", detail: "Shows your username, vehicle and totals on the boards you qualify for.", isOn: binding.leaderboardOptIn)
                PrivacyToggle(title: "Approve new followers", detail: "People must request to follow you.", isOn: binding.requireFollowApproval)
                MessagesFromPicker(selection: binding.messagesFrom)
                PrivacyToggle(title: "Read receipts", detail: "Shows people when you've read their messages. Off: you won't see theirs either.", isOn: binding.dmReadReceipts)
                    .accessibilityIdentifier("read-receipts")
            } else if privacyError == nil {
                ProgressView()
            }
        }
    }

    private var notificationsLink: some View {
        NavigationLink {
            NotificationPreferencesView()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications").font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                    Text("Which pushes you get, and whether they show message text.")
                        .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(ClusterColor.inkTertiary)
            }
            .padding(Space.m)
            .plate()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("open-notifications")
    }

    private var zonesLink: some View {
        NavigationLink {
            PrivacyZonesView()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Protected places").font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                    Text("Home, work, anywhere shared routes must never reveal.")
                        .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(ClusterColor.inkTertiary)
            }
            .padding(Space.m)
            .plate()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("open-privacy-zones")
    }

    private func loadPrivacy() async {
        privacyError = nil
        do {
            let loaded = try await app.backend.privacySettings()
            savedPrivacy = loaded
            privacy = loaded
        } catch {
            privacyError = error.localizedDescription
        }
    }

    private func savePrivacy(_ value: PrivacySettings) async {
        do {
            try await app.backend.updatePrivacySettings(value)
            savedPrivacy = value
            privacyError = nil
        } catch {
            privacyError = error.localizedDescription
            privacy = savedPrivacy
        }
    }

    // MARK: Account

    private var account: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Account")
            if let account = app.account {
                VStack(alignment: .leading, spacing: 0) {
                    SpecRow(label: "Username", value: "@\(account.username)")
                    SpecRow(label: "Signs in with", value: account.signInMethods.isEmpty ? "–" : account.signInMethods.map(\.label).joined(separator: ", "))
                    if account.usesPrivateRelayEmail {
                        SpecRow(label: "Email", value: "Hidden by Apple")
                    }
                }
                Text("Your email is never shown on your profile or to other people.")
                    .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkTertiary)
            }
            notificationsLink
            Button("Sign out") { Task { await app.signOut() } }
                .buttonStyle(.clusterSecondary)
            Button("Delete account") { deleting = true }
                .buttonStyle(.clusterDestructive)
                .accessibilityIdentifier("open-delete-account")
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("About")
            SpecRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
            SpecRow(label: "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–")
            SpecRow(label: "Data", value: app.isDemo ? "Demo (on this device only)" : serverName)
            // Privacy Policy, Support, Terms, Community Guidelines; a page
            // whose build setting is empty is left out.
            ForEach(LegalLinks.Page.allCases, id: \.self) { page in
                if let url = LegalLinks.url(for: page) {
                    LinkRow(label: page.title, destination: url)
                        .accessibilityIdentifier(page == .privacy ? "privacy-policy" : page.rawValue)
                }
            }
        }
    }

    /// Set per build (`PULLUP_SUPPORT_URL`, without the scheme), the same
    /// way as the privacy policy; nil when unset.
    static var supportURL: URL? { LegalLinks.support }

    /// Staging builds say so, so testers know their data isn't production's.
    private var serverName: String {
        let environment = Bundle.main.object(forInfoDictionaryKey: "PullUpBackendEnvironment") as? String ?? ""
        return environment == "staging" ? "Pull Up server (staging)" : "Pull Up server"
    }
}

/// "Who can message you", with what each choice means.
struct MessagesFromPicker: View {
    @Binding var selection: MessagesFrom

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend("Who can message you")
            SwitchBank(MessagesFrom.allCases, selection: $selection) { $0.label }
            Text(selection.explanation)
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messages-from")
    }
}

/// An About row that opens a web page.
struct LinkRow: View {
    let label: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(alignment: .firstTextBaseline) {
                Legend(label, color: ClusterColor.ink)
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(ClusterColor.inkTertiary)
            }
            .padding(.vertical, Space.s)
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct PrivacyToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                Text(detail).font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SpeedometerChoice: View {
    @Environment(\.clusterTheme) private var theme
    let style: SpeedometerStyle
    let unit: SpeedUnit
    let isSelected: Bool
    var locked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s) {
                // Rendered at dashboard size and scaled down, so the preview is
                // the real layout rather than a squeezed one.
                Speedometer(SpeedometerReading(speed: unit == .mph ? 48 : 77, topSpeed: unit == .mph ? 71 : 114, unit: unit), style: style)
                    .environment(\.dynamicTypeSize, .large)
                    .frame(width: 320, height: 320)
                    .scaleEffect(0.27)
                    .frame(width: 86, height: 86)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                HStack(spacing: Space.xs) {
                    Legend(style.label, color: isSelected ? ClusterColor.ink : ClusterColor.inkTertiary)
                    if locked { ProBadge() }
                }
            }
            .padding(Space.s)
            .frame(maxWidth: .infinity)
            .plate(raised: isSelected, cut: Radius.chamferSmall, stroke: isSelected ? theme.accentColor : nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locked ? "\(style.label) speedometer, Pull Up Pro" : "\(style.label) speedometer")
        .accessibilityIdentifier("speedometer-\(style.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Choose and order up to six dashboard tiles.
struct DashboardLayoutView: View {
    @Binding var metrics: [DashboardMetric]

    var body: some View {
        List {
            Section {
                ForEach(metrics) { metric in
                    Text(metric.label).font(ClusterFont.headline(.subheadline))
                }
                .onMove { metrics.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { metrics.remove(atOffsets: $0) }
            } header: {
                Text("Shown (\(metrics.count) of \(DashboardMetric.maximumCount))")
            }
            Section("Available") {
                ForEach(DashboardMetric.liveSelectable.filter { !metrics.contains($0) }) { metric in
                    Button {
                        metrics.append(metric)
                    } label: {
                        Label(metric.label, systemImage: "plus.circle")
                    }
                    .disabled(metrics.count >= DashboardMetric.maximumCount)
                }
            }
            Section {
                Button("Restore default") { metrics = DashboardMetric.defaultLayout }
            } footer: {
                Text("Values marked EST are phone-GPS estimates.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .canvasBackground()
        .clusterNavigation("Dashboard tiles")
    }
}

/// Places that shared routes are cut back from.
struct PrivacyZonesView: View {
    @Environment(AppModel.self) private var app
    @State private var zones: [PrivacyZone] = []
    @State private var adding = false
    @State private var error: String?
    /// Set when the list couldn't be fetched, so an empty list isn't taken
    /// to mean there are no protected places.
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                Text("Shared routes never show anything within a protected place plus a 150 m margin. Your own private tracks are unaffected.")
                    .font(ClusterFont.body(.footnote))
                    .foregroundStyle(ClusterColor.inkSecondary)
                if let loadError {
                    ErrorLine(message: "Couldn't load your protected places. \(loadError)") { Task { await load() } }
                }
                if let error { ErrorLine(message: error) }
                ForEach(zones) { zone in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(zone.label).font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                            Text("\(Int(zone.radiusMeters)) m radius").font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task {
                                do {
                                    try await app.backend.deletePrivacyZone(zone.id)
                                    zones.removeAll { $0.id == zone.id }
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Remove \(zone.label)")
                    }
                    .padding(Space.m)
                    .plate()
                }
                Button {
                    adding = true
                } label: {
                    Label("Add a protected place", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.clusterSecondary)
            }
            .padding(Space.gutter)
        }
        .canvasBackground()
        .clusterNavigation("Protected places")
        .task { await load() }
        .sheet(isPresented: $adding) {
            PrivacyZoneEditor { zone in
                try await app.backend.addPrivacyZone(zone)
                zones.append(zone)
            }
        }
    }

    private func load() async {
        do {
            zones = try await app.backend.privacyZones()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct PrivacyZoneEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (PrivacyZone) async throws -> Void
    @State private var label = "Home"
    @State private var radius = 300.0
    @State private var center = CLLocationCoordinate2D(latitude: 38.5816, longitude: -121.4944)
    /// Metres covered by the map's height, to draw the radius to scale.
    @State private var spanMeters = 3_300.0
    @State private var position: MapCameraPosition = .userLocation(fallback: .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 38.5816, longitude: -121.4944),
        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
    )))
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.l) {
                FieldRow(label: "Name", text: $label)
                Map(position: $position) {
                    UserAnnotation()
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    center = context.region.center
                    spanMeters = context.region.span.latitudeDelta * 111_195
                }
                .overlay {
                    GeometryReader { proxy in
                        let diameter = min(proxy.size.width, max(8, 2 * radius / max(spanMeters, 1) * proxy.size.height))
                        Circle()
                            .stroke(ClusterColor.live, lineWidth: 2)
                            .background(Circle().fill(ClusterColor.live.opacity(0.12)))
                            .frame(width: diameter, height: diameter)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                    .allowsHitTesting(false)
                }
                .clipShape(ChamferedRectangle(cut: Radius.chamfer))
                .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Legend("Radius \(Int(radius)) m")
                    Slider(value: $radius, in: 100...1_000, step: 50)
                }
                Text("Centre the circle on the place. Its exact position is stored privately and only used to trim shared routes.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
                if let error { ErrorLine(message: error) }
            }
            .padding(Space.gutter)
            .canvasBackground()
            .clusterNavigation("Protected place")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            do {
                                try await onSave(PrivacyZone(label: label, center: Coordinate(latitude: center.latitude, longitude: center.longitude), radiusMeters: radius))
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// A small picture of the app in one appearance, like Settings ▸ Display.
struct AppearanceTile: View {
    @Environment(\.clusterTheme) private var theme
    let option: AppearancePreference
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s) {
                preview
                    .aspectRatio(0.62, contentMode: .fit)
                    .frame(maxWidth: 92)
                    .overlay {
                        ChamferedRectangle(cut: 12).strokeBorder(isSelected ? theme.accentColor : ClusterColor.ruleStrong, lineWidth: isSelected ? 2.5 : 1)
                    }
                Text(option.label)
                    .font(isSelected ? ClusterFont.headline(.footnote) : ClusterFont.body(.footnote))
                    .foregroundStyle(ClusterColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? theme.accentColor : ClusterColor.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("appearance-\(option.rawValue)")
    }

    /// Fixed colours on purpose: each tile shows its own mode whatever the
    /// current one is.
    @ViewBuilder
    private var preview: some View {
        switch option {
        case .light: sample(background: .white, surface: Color(white: 0.955), ink: Color(white: 0.06))
        case .dark: sample(background: .black, surface: Color(white: 0.07), ink: .white)
        case .system:
            HStack(spacing: 0) {
                sample(background: .white, surface: Color(white: 0.955), ink: Color(white: 0.06), corners: [.topLeading, .bottomLeading])
                sample(background: .black, surface: Color(white: 0.07), ink: .white, corners: [.topTrailing, .bottomTrailing])
            }
        }
    }

    private func sample(background: Color, surface: Color, ink: Color, corners: ChamferedRectangle.Corners = .all) -> some View {
        ChamferedRectangle(cut: 12, corners: corners)
            .fill(background)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(ink).frame(width: 26, height: 5)
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(surface).frame(height: 34)
                    Capsule().fill(ink.opacity(0.5)).frame(width: 34, height: 4)
                    Capsule().fill(theme.accentColor).frame(width: 18, height: 4)
                }
                .padding(8)
            }
            .clipShape(ChamferedRectangle(cut: 12, corners: corners))
    }
}
