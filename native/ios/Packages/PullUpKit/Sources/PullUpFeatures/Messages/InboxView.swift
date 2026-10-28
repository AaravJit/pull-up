import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// Messages inbox: conversations, and requests from people you don't follow.
struct InboxView: View {
    @Environment(AppModel.self) private var app

    enum Folder: String, CaseIterable, Identifiable {
        case messages, requests
        var id: String { rawValue }
        var state: ConversationState { self == .messages ? .active : .request }
    }

    @State private var folder: Folder = .messages
    @State private var entries: [InboxEntry] = []
    @State private var isLoaded = false
    @State private var hasMore = false
    @State private var error: String?
    @State private var confirmDelete: InboxEntry?
    /// Opened from a tapped push rather than a row.
    @State private var opened: ConversationTarget?
    @State private var query = ""

    /// Conversations, minus blocked people, narrowed by the search field.
    private var shown: [InboxEntry] {
        let visible = entries.filter { !app.blockedUsers.contains($0.peer.id) }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return visible }
        return visible.filter {
            $0.peer.username.localizedCaseInsensitiveContains(q) || $0.peer.displayName.localizedCaseInsensitiveContains(q)
                || $0.preview.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            Section {
                SwitchBank(Folder.allCases, selection: $folder) { folderLabel($0) }
                    .listRowInsets(EdgeInsets(top: Space.s, leading: Space.gutter, bottom: Space.s, trailing: Space.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(ClusterColor.canvas)
                    .accessibilityIdentifier("inbox-folders")
                if folder == .requests {
                    NoticeStrip("Requests are from people you don't follow. They can't see that you've read them until you accept.")
                        .listRowInsets(EdgeInsets(top: 0, leading: Space.gutter, bottom: Space.s, trailing: Space.gutter))
                        .listRowSeparator(.hidden)
                        .listRowBackground(ClusterColor.canvas)
                }
                if let error {
                    ErrorLine(message: error) { Task { await load() } }
                        .listRowSeparator(.hidden)
                        .listRowBackground(ClusterColor.canvas)
                } else if !isLoaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                        .listRowSeparator(.hidden)
                        .listRowBackground(ClusterColor.canvas)
                } else if entries.isEmpty {
                    EmptyState(
                        title: folder == .messages ? "No messages yet" : "No requests",
                        message: folder == .messages
                            ? "Tap New message, or Message on someone's profile. To share a post, tap its paper plane."
                            : "Messages from people you don't follow wait here until you accept them."
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(ClusterColor.canvas)
                }
            }
            ForEach(shown) { entry in
                NavigationLink(value: ConversationTarget(entry)) {
                    InboxRow(entry: entry)
                }
                .accessibilityIdentifier("inbox-row-\(entry.peer.username)")
                .listRowInsets(EdgeInsets(top: 0, leading: Space.gutter, bottom: 0, trailing: Space.gutter))
                .listRowBackground(ClusterColor.canvas)
                .listRowSeparatorTint(ClusterColor.rule)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { confirmDelete = entry } label: { Label("Delete", systemImage: "trash") }
                    Button { Task { await hide(entry) } } label: { Label("Hide", systemImage: "eye.slash") }
                }
                .swipeActions(edge: .leading) {
                    if entry.state == .active {
                        Button { Task { await toggleMute(entry) } } label: {
                            Label(entry.muted ? "Unmute" : "Mute", systemImage: entry.muted ? "bell" : "bell.slash")
                        }
                    }
                }
                .contextMenu {
                    if entry.state == .active {
                        Button { Task { await toggleMute(entry) } } label: {
                            Label(entry.muted ? "Unmute" : "Mute", systemImage: entry.muted ? "bell" : "bell.slash")
                        }
                    }
                    Button { Task { await hide(entry) } } label: { Label("Hide", systemImage: "eye.slash") }
                    Button(role: .destructive) { confirmDelete = entry } label: { Label("Delete", systemImage: "trash") }
                }
                .onAppear {
                    if entry.id == entries.last?.id, hasMore { Task { await loadMore() } }
                }
            }
            // Search only covers loaded conversations, and paging is driven by
            // the last loaded row appearing. When the filter hides that row,
            // offer older pages explicitly so a match there is still reachable.
            if hasMore, let last = entries.last, !shown.contains(where: { $0.id == last.id }) {
                Button {
                    Task { await loadMore() }
                } label: {
                    Label("Search older conversations", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("inbox-load-older")
                .listRowSeparator(.hidden)
                .listRowBackground(ClusterColor.canvas)
            }
        }
        .listStyle(.plain)
        .canvasBackground()
        .rootNavigation("Messages")
        .searchable(text: $query, prompt: "Search messages")
        .navigationDestination(for: ConversationTarget.self) { ThreadView(target: $0) }
        .navigationDestination(item: $opened) { ThreadView(target: $0) }
        .refreshable { await load() }
        .task(id: folder) {
            await load()
            openPendingPush()
        }
        .onChange(of: app.pendingPush) {
            if isLoaded { Task { await load(); openPendingPush() } }
        }
        .onChange(of: app.messagingPulse) { Task { await load() } }
        .confirmationDialog(
            "Delete this conversation?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible, presenting: confirmDelete
        ) { entry in
            Button("Delete for me", role: .destructive) { Task { await delete(entry) } }
        } message: { entry in
            Text("Your copy of the conversation with @\(entry.peer.username) is deleted. They keep theirs.")
        }
        .accessibilityIdentifier("inbox")
    }

    /// Opens the conversation a tapped push is about, once its folder has
    /// loaded. If it's gone (deleted, blocked) the inbox stays open.
    private func openPendingPush() {
        guard case let .conversation(id, isRequest) = app.pendingPush else { return }
        let wanted: Folder = isRequest ? .requests : .messages
        if folder != wanted, !entries.contains(where: { $0.conversationID == id }) {
            folder = wanted
            return
        }
        app.pendingPush = nil
        if let entry = entries.first(where: { $0.conversationID == id }) {
            opened = ConversationTarget(entry)
        }
    }

    private func folderLabel(_ folder: Folder) -> String {
        switch folder {
        case .messages: "Messages"
        case .requests: app.unreadMessages.requests > 0 ? "Requests · \(app.unreadMessages.requests)" : "Requests"
        }
    }

    private func load() async {
        do {
            let page = try await app.backend.inbox(folder.state, before: nil)
            entries = page
            hasMore = page.count >= 30
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
        await app.refreshMessages()
    }

    private func loadMore() async {
        guard let before = entries.last?.lastMessageAt else { return }
        do {
            let page = try await app.backend.inbox(folder.state, before: before)
            let known = Set(entries.map(\.id))
            entries += page.filter { !known.contains($0.id) }
            hasMore = page.count >= 30
        } catch {
            hasMore = false
        }
    }

    private func hide(_ entry: InboxEntry) async {
        do {
            try await app.backend.hideConversation(entry.conversationID, clearHistory: false)
            entries.removeAll { $0.id == entry.id }
            await app.refreshMessages()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ entry: InboxEntry) async {
        do {
            if entry.state == .request {
                try await app.backend.respondToRequest(conversation: entry.conversationID, accept: false)
            }
            try await app.backend.hideConversation(entry.conversationID, clearHistory: true)
            entries.removeAll { $0.id == entry.id }
            await app.refreshMessages()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggleMute(_ entry: InboxEntry) async {
        do {
            try await app.backend.setMuted(!entry.muted, conversation: entry.conversationID)
            if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i].muted.toggle() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct InboxRow: View {
    @Environment(\.clusterTheme) private var theme
    let entry: InboxEntry

    private var unread: Bool { entry.unreadCount > 0 }

    var body: some View {
        HStack(spacing: Space.m) {
            Avatar(name: entry.peer.displayName.isEmpty ? entry.peer.username : entry.peer.displayName, path: entry.peer.avatarPath, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.xs) {
                    Text(entry.peer.displayName.isEmpty ? "@\(entry.peer.username)" : entry.peer.displayName)
                        .font(unread ? ClusterFont.headline(.body) : ClusterFont.body(.body))
                        .foregroundStyle(ClusterColor.ink)
                        .lineLimit(1)
                    if entry.muted {
                        Image(systemName: "bell.slash").font(.caption2).foregroundStyle(ClusterColor.inkTertiary)
                            .accessibilityLabel("Muted")
                    }
                    Spacer(minLength: Space.s)
                    if let date = entry.lastMessageAt {
                        Text(Format.relative(date))
                            .font(ClusterFont.body(.subheadline))
                            .foregroundStyle(unread ? theme.accentColor : ClusterColor.inkTertiary)
                    }
                }
                HStack(spacing: Space.s) {
                    Text(entry.lastMessageFromMe ? "You: \(entry.preview)" : entry.preview)
                        .font(unread ? ClusterFont.headline(.subheadline) : ClusterFont.body(.subheadline))
                        .foregroundStyle(unread ? ClusterColor.ink : ClusterColor.inkSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if unread {
                        Text(verbatim: "\(entry.unreadCount)")
                            .font(ClusterFont.readout(.caption))
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(theme.accentFill, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityValue(unread ? "\(entry.unreadCount) unread" : "")
    }
}

/// Paper-plane button with the unread badge, for screen headers.
struct MessagesButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let count = app.unreadMessages.total
        NavigationLink(value: MessagesRoute()) {
            Image(systemName: "paperplane")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ClusterColor.ink)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Circle().fill(ClusterColor.live).frame(width: 9, height: 9).offset(x: -8, y: 9)
                    }
                }
        }
        .accessibilityLabel(count > 0 ? "Messages, \(count) unread" : "Messages")
        .accessibilityIdentifier("open-messages")
    }
}

struct MessagesRoute: Hashable {}
