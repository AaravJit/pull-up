import MapKit
import SwiftUI
import PullUpDesign
import PullUpDomain

/// Event-focused list: a date stamp leads every row, today's live meets
/// lead the page.
public struct MeetsView: View {
    @Environment(AppModel.self) private var app
    @State private var meets: [Meet] = []
    @State private var focus: Meet.Focus = .all
    @State private var creating = false
    @State private var error: String?
    @State private var isLoaded = false

    public init() {}

    private var filtered: [Meet] {
        meets.filter { focus == .all || $0.focus == .all || $0.focus == focus }
    }

    private var grouped: [(day: Date, meets: [Meet])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.startsAt) }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.startsAt < $1.startsAt }) }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    HStack(alignment: .bottom) {
                        ScreenTitle("Meets", subtitle: "Upcoming")
                        Button {
                            creating = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ClusterColor.ink)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Host a meet")
                    }
                    SwitchBank(Meet.Focus.allCases, selection: $focus) { $0.label }
                    if let error {
                        ErrorLine(message: error) { Task { await load() } }
                    } else if !isLoaded {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else if filtered.isEmpty {
                        EmptyState(title: "Nothing scheduled", message: "No upcoming meets match. Host one and it appears here and on the map.")
                    }
                    ForEach(grouped, id: \.day) { group in
                        VStack(alignment: .leading, spacing: Space.s) {
                            SectionHeader(dayTitle(group.day))
                            ForEach(group.meets) { meet in
                                NavigationLink(value: meet) { MeetRow(meet: meet) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xl)
            }
            .canvasBackground()
            .refreshable { await load() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Meet.self) { meet in
                MeetDetailView(meetID: meet.id, initial: meet, onBlocked: { host in meets.removeAll { $0.hostID == host } })
            }
            .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { MeetComposerView() }
            .task { await load() }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func load() async {
        do {
            meets = try await app.backend.meets(from: .now.addingTimeInterval(-3 * 3600))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
    }
}

/// Calendar stamp: day number over month, or LIVE.
struct DateStamp: View {
    let date: Date
    var isLive = false

    var body: some View {
        VStack(spacing: 0) {
            if isLive {
                LiveDot(size: 7).padding(.bottom, 3)
                Text("Live").font(ClusterFont.legend(.caption2)).textCase(.uppercase).foregroundStyle(ClusterColor.live)
            } else {
                Text(date.formatted(.dateTime.month(.abbreviated)))
                    .font(ClusterFont.legend(.caption2))
                    .textCase(.uppercase)
                    .foregroundStyle(ClusterColor.inkSecondary)
                Text(date.formatted(.dateTime.day()))
                    .font(ClusterFont.numeral(26))
                    .foregroundStyle(ClusterColor.ink)
            }
        }
        .frame(width: 48, height: 52)
        .plate(raised: true, cut: 5)
        .accessibilityHidden(true)
    }
}

struct MeetRow: View {
    let meet: Meet

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            DateStamp(date: meet.startsAt, isLive: meet.isLive())
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    Legend(meet.focus == .all ? meet.kind.label : "\(meet.kind.label) · \(meet.focus.label)")
                    if meet.isCancelled { Legend("Cancelled", color: ClusterColor.caution) }
                }
                Text(meet.title)
                    .font(ClusterFont.headline())
                    .foregroundStyle(meet.isCancelled ? ClusterColor.inkTertiary : ClusterColor.ink)
                    .strikethrough(meet.isCancelled)
                Text("\(meet.startsAt.formatted(date: .omitted, time: .shortened)) · \(meet.venueName)")
                    .font(ClusterFont.body(.footnote))
                    .foregroundStyle(ClusterColor.inkSecondary)
                HStack(spacing: Space.m) {
                    Text("\(meet.goingCount) going").font(ClusterFont.readout(.caption))
                    if meet.interestedCount > 0 { Text("\(meet.interestedCount) interested").font(ClusterFont.readout(.caption)) }
                    if let rsvp = meet.myRSVP {
                        Legend(rsvp.status == .going ? "You're going" : "Interested", color: ClusterColor.verified)
                    }
                }
                .foregroundStyle(ClusterColor.inkTertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(ClusterColor.inkTertiary).padding(.top, Space.l)
        }
        .padding(.vertical, Space.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meet-row-\(meet.title)")
    }
}

struct MeetDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let meetID: UUID
    /// Called with the host's ID after you block them, so a list can drop their meets.
    var onBlocked: ((UserID) -> Void)?
    @State private var meet: Meet
    @State private var attendees: [ProfileStub] = []
    @State private var showMe = false
    @State private var error: String?
    @State private var busy = false
    @State private var confirmingCancel = false
    @State private var sharing = false
    @State private var reporting = false
    @State private var confirmingBlock = false
    @State private var hostBlocked = false

    init(meetID: UUID, initial: Meet, onBlocked: ((UserID) -> Void)? = nil) {
        self.meetID = meetID
        self.onBlocked = onBlocked
        _meet = State(initialValue: initial)
        _showMe = State(initialValue: initial.myRSVP?.showMe ?? false)
    }

    private var isHost: Bool { meet.hostID == app.userID }
    private var hasEnded: Bool { meet.endsAt < .now }
    private var host: ProfileStub { meet.host ?? ProfileStub(id: meet.hostID, username: "", displayName: "") }
    private var hostHandle: String { host.username.isEmpty ? "the host" : "@\(host.username)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Map(initialPosition: .region(MKCoordinateRegion(center: meet.coordinate.clLocation, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))), interactionModes: []) {
                    Annotation(meet.venueName, coordinate: meet.coordinate.clLocation, anchor: .bottom) {
                        MeetPin(meet: meet, isSelected: true)
                    }
                }
                .frame(height: 200)
                .clipShape(ChamferedRectangle(cut: Radius.chamfer))
                .accessibilityLabel("Map of \(meet.venueName)")

                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Legend(meet.kind.label, color: theme.accentColor)
                        if meet.isLive() {
                            LiveDot(size: 7)
                            Legend("Happening now", color: ClusterColor.live)
                        }
                        if meet.isCancelled { Legend("Cancelled", color: ClusterColor.caution) }
                    }
                    Text(meet.title)
                        .font(ClusterFont.title(.title))
                        .tracking(Tracking.title)
                        .foregroundStyle(ClusterColor.ink)
                    if let host = meet.host {
                        Text("Hosted by \(host.displayName)").font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
                    }
                }

                VStack(spacing: 0) {
                    SpecRow(label: "Starts", value: meet.startsAt.formatted(date: .abbreviated, time: .shortened))
                    SpecRow(label: "Ends", value: meet.endsAt.formatted(date: .abbreviated, time: .shortened))
                    SpecRow(label: "Venue", value: meet.venueName)
                    if !meet.address.isEmpty { SpecRow(label: "Area", value: meet.address) }
                    SpecRow(label: "For", value: meet.focus.label)
                    SpecRow(label: "Going", value: meet.capacity.map { "\(meet.goingCount) of \($0)" } ?? "\(meet.goingCount)")
                }

                if !meet.details.isEmpty {
                    Text(meet.details).font(ClusterFont.body()).foregroundStyle(ClusterColor.ink)
                }

                if meet.kind == .trackDay {
                    NoticeStrip("Closed-course event. Pull Up doesn't rank speed or acceleration.", tone: .info)
                }

                rsvpSection
                attendeeSection

                if isHost, !meet.isCancelled, !hasEnded {
                    Button("Cancel this meet", role: .destructive) { confirmingCancel = true }
                        .buttonStyle(.clusterDestructive)
                }
                if let error { ErrorLine(message: error) }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.l)
        }
        .canvasBackground()
        .clusterNavigation(meet.title)
        .toolbar {
            if !meet.isCancelled {
                ToolbarItem(placement: .primaryAction) {
                    Button { sharing = true } label: { Image(systemName: "paperplane") }
                        .accessibilityLabel("Send in a message")
                        .accessibilityIdentifier("share-meet")
                }
            }
            if !isHost {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { reporting = true } label: { Label("Report meet", systemImage: "flag") }
                        Button(role: .destructive) { confirmingBlock = true } label: { Label("Block \(hostHandle)", systemImage: "hand.raised") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Meet options")
                    .accessibilityIdentifier("meet-options")
                }
            }
        }
        .sheet(isPresented: $sharing) {
            ShareToMessageView(shared: SharedRef(kind: .meet, id: meet.id))
        }
        .sheet(isPresented: $reporting, onDismiss: { if hostBlocked { dismiss() } }) {
            ReportPersonView(
                person: host,
                question: "What's wrong with this meet?",
                subject: ReportDetails.subject("meet", id: meet.id, excerpt: meet.title),
                onBlocked: { hostWasBlocked() }
            )
        }
        .confirmationDialog("Block \(hostHandle)?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await blockHost() } }
        } message: {
            Text("You won't see each other's meets, posts or profiles, and they can't message you. Pull Up doesn't tell them.")
        }
        .task { await loadAttendees() }
        .confirmationDialog("Cancel \(meet.title)?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancel meet", role: .destructive) {
                Task {
                    do {
                        try await app.backend.cancelMeet(meet.id)
                        meet.cancelledAt = .now
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Everyone who RSVP'd is notified.")
        }
        .accessibilityIdentifier("meet-detail")
    }

    private var rsvpSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Your RSVP")
            if meet.isCancelled || hasEnded {
                Text(meet.isCancelled ? "This meet was cancelled." : "This meet has ended.")
                    .font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
            } else {
                // One row when the words fit without breaking, else stacked.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s) { rsvpButtons }
                    VStack(spacing: Space.s) { rsvpButtons }
                }
                if meet.myRSVP?.status == .going {
                    Toggle(isOn: Binding(get: { showMe }, set: { value in
                        showMe = value
                        Task { await setRSVP(RSVP(status: .going, showMe: value)) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show me in the attendee list").font(ClusterFont.headline(.subheadline))
                            Text("Off by default. Others going see your name only, never your location.")
                                .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                        }
                    }
                    .accessibilityIdentifier("rsvp-show-me")
                }
                if meet.isFull, meet.myRSVP?.status != .going {
                    NoticeStrip("This meet is at capacity.", tone: .caution)
                }
            }
            Text("An RSVP never shares where you are. Pull Up doesn't track attendees' locations.")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkTertiary)
        }
    }

    @ViewBuilder
    private var rsvpButtons: some View {
        rsvpButton("Going", status: .going)
        rsvpButton("Interested", status: .interested)
        if meet.myRSVP != nil {
            Button { Task { await setRSVP(nil) } } label: {
                Text("Not going").lineLimit(1).fixedSize().frame(maxWidth: .infinity)
            }
            .buttonStyle(.clusterSecondary)
            .disabled(busy)
        }
    }

    private func rsvpButton(_ title: String, status: RSVP.Status) -> some View {
        let selected = meet.myRSVP?.status == status
        return Button {
            Task { await setRSVP(RSVP(status: status, showMe: status == .going ? showMe : false)) }
        } label: {
            Label(title, systemImage: selected ? "checkmark" : status == .going ? "car" : "star")
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ClusterButtonStyle(selected ? .primary : .secondary))
        .disabled(busy || (status == .going && meet.isFull && !selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("rsvp-\(status.rawValue)")
    }

    @ViewBuilder
    private var attendeeSection: some View {
        if meet.myRSVP?.status == .going || isHost {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("Attendees who chose to be shown")
                if attendees.isEmpty {
                    Text("Nobody has opted in to being listed yet.")
                        .font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
                } else {
                    ForEach(attendees) { person in
                        HStack(spacing: Space.m) {
                            Avatar(name: person.displayName, path: person.avatarPath, size: 32)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(person.displayName).font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                                Text("@\(person.username)").font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func setRSVP(_ rsvp: RSVP?) async {
        busy = true
        defer { busy = false }
        do {
            try await app.backend.setRSVP(rsvp, meet: meet.id)
            if let updated = try await app.backend.meets(from: .distantPast).first(where: { $0.id == meet.id }) {
                meet = updated
            }
            error = nil
            await loadAttendees()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadAttendees() async {
        attendees = (try? await app.backend.attendees(meet: meet.id)) ?? []
    }

    private func blockHost() async {
        do {
            try await app.backend.block(meet.hostID)
            hostWasBlocked()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func hostWasBlocked() {
        hostBlocked = true
        onBlocked?(meet.hostID)
    }
}
