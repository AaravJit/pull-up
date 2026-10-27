import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

extension AppModel {
    /// Finds or starts the conversation with someone, for "Message" buttons.
    func conversation(with peer: ProfileStub, attach: SharedRef? = nil) async throws -> ConversationTarget {
        let id = try await backend.startConversation(with: peer.id)
        return ConversationTarget(conversationID: id, peer: peer, attach: attach)
    }
}

/// Sends a post, meet, drive or vehicle to one or more people. The server
/// re-checks that the sender can see it, and each recipient sees it only if
/// they could anyway.
struct ShareToMessageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let shared: SharedRef

    @State private var recent: [InboxEntry] = []
    @State private var query = ""
    @State private var results: [ProfileStub] = []
    @State private var note = ""
    @State private var sent: Set<UserID> = []
    @State private var sending: Set<UserID> = []
    @State private var error: String?

    private var people: [ProfileStub] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return recent.map(\.peer) }
        return results.filter { $0.id != app.userID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    SharedCard(ref: shared)
                    FieldRow(label: "Add a note (optional)", text: $note, axis: .vertical)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Legend("To")
                        TextField("Search by username", text: $query)
                            .font(ClusterFont.body())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.vertical, Space.xs)
                            .accessibilityIdentifier("share-search")
                        Hairline(color: ClusterColor.ruleStrong)
                    }
                    if let error { ErrorLine(message: error) }
                    SectionHeader(query.count >= 2 ? "People" : "Recent")
                    if people.isEmpty {
                        Text(query.count >= 2 ? "Nobody by that name." : "Search for someone to send this to.")
                            .font(ClusterFont.body(.subheadline))
                            .foregroundStyle(ClusterColor.inkSecondary)
                    }
                    ForEach(people) { person in
                        HStack(spacing: Space.m) {
                            Avatar(name: person.displayName.isEmpty ? person.username : person.displayName, path: person.avatarPath, size: 40)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(person.displayName.isEmpty ? "@\(person.username)" : person.displayName)
                                    .font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                                Text("@\(person.username)").font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                            }
                            Spacer()
                            if sent.contains(person.id) {
                                Label("Sent", systemImage: "checkmark").font(ClusterFont.headline(.footnote)).foregroundStyle(ClusterColor.verified)
                            } else {
                                Button(sending.contains(person.id) ? "Sending" : "Send") { Task { await send(to: person) } }
                                    .font(ClusterFont.headline(.footnote))
                                    .disabled(sending.contains(person.id))
                                    .accessibilityIdentifier("share-send-\(person.username)")
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(Space.gutter)
            }
            .canvasBackground()
            .clusterNavigation("Send to")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { recent = (try? await app.backend.inbox(.active, before: nil)) ?? [] }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                results = (try? await app.backend.searchProfiles(q)) ?? []
            }
        }
    }

    private func send(to person: ProfileStub) async {
        sending.insert(person.id)
        defer { sending.remove(person.id) }
        do {
            let conversation = try await app.conversation(with: person)
            _ = try await app.backend.send(OutgoingMessage(conversationID: conversation.conversationID, body: note, shared: shared))
            sent.insert(person.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Someone else's vehicle, opened from their profile, with "Message owner".
struct VehicleGlanceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle
    let owner: ProfileStub

    @State private var conversation: ConversationTarget?
    @State private var busy = false
    @State private var error: String?
    @State private var reporting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    Color.clear
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .overlay { VehicleArtwork(vehicle: vehicle) }
                        .clipped()
                    Rectangle().fill(ClusterColor.accent(vehicle.identityColor)).frame(height: 4)
                    VStack(alignment: .leading, spacing: Space.l) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Legend("\(String(vehicle.year)) · \(vehicle.kind.label)")
                            Text("\(vehicle.make) \(vehicle.model)")
                                .font(ClusterFont.title(.title2))
                                .foregroundStyle(ClusterColor.ink)
                            if !vehicle.trim.isEmpty {
                                Text(vehicle.trim).font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
                            }
                        }
                        if !vehicle.summary.isEmpty {
                            Text(vehicle.summary).font(ClusterFont.body()).foregroundStyle(ClusterColor.ink)
                        }
                        Button {
                            Task { await messageOwner() }
                        } label: {
                            Label(busy ? "Opening" : "Message @\(owner.username)", systemImage: "paperplane")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.cluster)
                        .disabled(busy)
                        .accessibilityIdentifier("message-owner")
                        Text("The \(vehicle.model) is attached to your first message, so @\(owner.username) knows what you're asking about.")
                            .font(ClusterFont.body(.caption))
                            .foregroundStyle(ClusterColor.inkTertiary)
                        if let error { ErrorLine(message: error) }
                    }
                    .padding(.horizontal, Space.gutter)
                }
                .padding(.bottom, Space.xl)
            }
            .canvasBackground()
            .clusterNavigation(vehicle.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if owner.id != app.userID {
                    ToolbarItem(placement: .primaryAction) {
                        Button { reporting = true } label: { Label("Report", systemImage: "flag") }
                            .accessibilityIdentifier("report-vehicle")
                    }
                }
            }
            .sheet(isPresented: $reporting) {
                // Name, description, mods and photos are copied for review.
                ReportPersonView(
                    person: owner,
                    question: "What's wrong with this \(vehicle.kind == .car ? "car" : "bike")?",
                    content: ReportedContent(.vehicle, id: vehicle.id),
                    onBlocked: { dismiss() }
                )
                .clusterTheme(app.themeStore.theme)
            }
            .navigationDestination(item: $conversation) { ThreadView(target: $0) }
        }
    }

    private func messageOwner() async {
        busy = true
        defer { busy = false }
        do {
            conversation = try await app.conversation(with: owner, attach: SharedRef(kind: .vehicle, id: vehicle.id))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
