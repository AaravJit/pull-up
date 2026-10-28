import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// The Messages tab: the inbox, with New message in the bar. Starting a
/// conversation never sends anything; the thread opens with the keyboard up.
struct MessagesTab: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var composing = false

    var body: some View {
        NavigationStack(path: $path) {
            InboxView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            composing = true
                        } label: {
                            Label("New message", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("new-message")
                    }
                }
                .navigationDestination(for: ProfileRoute.self) { ProfileView(userID: $0.id) }
        }
        .sheet(isPresented: $composing) {
            NewMessageView { target in
                composing = false
                path.append(target)
            }
            .presentationDetents([.large])
            .sheetCanvas()
        }
        .onChange(of: app.pendingPush) { _, route in
            // A tapped message push: back to the inbox, which opens the conversation.
            guard case .conversation = route else { return }
            path = NavigationPath()
        }
    }
}

/// Pick someone to message: recent conversations first, search by name.
struct NewMessageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onOpen: (ConversationTarget) -> Void

    @State private var query = ""
    @State private var recent: [ProfileStub] = []
    @State private var opening: UserID?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            PeopleList(query: query, recent: recent, recentTitle: "Recent") { person in
                Task { await open(person) }
            } trailing: { person in
                if opening == person.id { ProgressView() }
            }
            .safeAreaInset(edge: .top) {
                if let error { ErrorLine(message: error).padding(.horizontal, Space.gutter) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or username")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .clusterNavigation("New message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                let entries = (try? await app.backend.inbox(.active, before: nil)) ?? []
                recent = entries.map(\.peer).filter { !app.blockedUsers.contains($0.id) }
            }
        }
    }

    private func open(_ person: ProfileStub) async {
        guard opening == nil else { return }
        opening = person.id
        defer { opening = nil }
        do {
            onOpen(try await app.conversation(with: person))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// People as a native list: `recent` while the query is short, otherwise
/// search results from the server. Shared by New message and Explore.
struct PeopleList<Trailing: View>: View {
    @Environment(AppModel.self) private var app
    let query: String
    var recent: [ProfileStub] = []
    var recentTitle = "Suggested"
    let onSelect: (ProfileStub) -> Void
    @ViewBuilder var trailing: (ProfileStub) -> Trailing

    @State private var results: [ProfileStub] = []
    @State private var searching = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var isSearching: Bool { trimmed.count >= 2 }

    private var people: [ProfileStub] {
        (isSearching ? results : recent).filter { $0.id != app.userID && !app.blockedUsers.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                if people.isEmpty {
                    Text(isSearching ? (searching ? "Searching…" : "Nobody by that name.") : "Search for someone by name or username.")
                        .font(ClusterFont.body(.subheadline))
                        .foregroundStyle(ClusterColor.inkSecondary)
                        .listRowBackground(ClusterColor.canvas)
                }
                ForEach(people) { person in
                    Button { onSelect(person) } label: {
                        PersonRow(person: person) { trailing(person) }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(ClusterColor.canvas)
                    .listRowSeparatorTint(ClusterColor.rule)
                    .accessibilityIdentifier("person-\(person.username)")
                }
            } header: {
                if !people.isEmpty {
                    Text(isSearching ? "People" : recentTitle)
                }
            }
        }
        .listStyle(.plain)
        .canvasBackground()
        .scrollDismissesKeyboard(.immediately)
        .task(id: trimmed) {
            guard isSearching else {
                results = []
                return
            }
            searching = true
            defer { searching = false }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = (try? await app.backend.searchProfiles(trimmed)) ?? []
        }
    }
}

/// Avatar, name and handle.
struct PersonRow<Trailing: View>: View {
    let person: ProfileStub
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Space.m) {
            Avatar(name: person.displayName.isEmpty ? person.username : person.displayName, path: person.avatarPath, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.displayName.isEmpty ? "@\(person.username)" : person.displayName)
                    .font(ClusterFont.headline(.body))
                    .foregroundStyle(ClusterColor.ink)
                    .lineLimit(1)
                Text("@\(person.username)")
                    .font(ClusterFont.body(.subheadline))
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            trailing()
        }
        .padding(.vertical, Space.xs)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
