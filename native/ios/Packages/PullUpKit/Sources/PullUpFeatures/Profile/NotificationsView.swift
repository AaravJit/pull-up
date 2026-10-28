import SwiftUI
import PullUpDesign
import PullUpDomain

struct NotificationsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// In a sheet (the Feed's bell) rather than pushed (You ▸ Activity).
    var showsDone = true
    @State private var items: [AppNotification] = []
    @State private var requests: [ProfileStub] = []
    @State private var answering: Set<UserID> = []
    @State private var requestError: String?
    @State private var isLoaded = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !requests.isEmpty || requestError != nil {
                    SectionHeader(requests.isEmpty ? "Follow requests" : "Follow requests (\(requests.count))")
                        .padding(.top, Space.m)
                    if let requestError {
                        ErrorLine(message: requestError).padding(.top, Space.m)
                    }
                    ForEach(requests) { person in
                        requestRow(person)
                    }
                    if !items.isEmpty {
                        SectionHeader("Activity").padding(.top, Space.l)
                    }
                }
                if let error {
                    ErrorLine(message: error) { Task { await load() } }
                } else if isLoaded, items.isEmpty, requests.isEmpty {
                    EmptyState(title: "All caught up", message: "Follows, likes, comments and meet updates show up here.")
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: Space.m) {
                        if let actor = item.actor {
                            Avatar(name: actor.displayName, path: actor.avatarPath, size: 34)
                        } else {
                            Image(systemName: symbol(item.kind))
                                .frame(width: 34, height: 34)
                                .plate(raised: true, cut: 6)
                                .foregroundStyle(ClusterColor.verified)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(text(item)).font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.ink)
                            Text(Format.relative(item.createdAt)).font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkTertiary)
                        }
                        Spacer(minLength: 0)
                        if item.readAt == nil {
                            Circle().fill(ClusterColor.live).frame(width: 7, height: 7).padding(.top, 6)
                                .accessibilityLabel("Unread")
                        }
                    }
                    .padding(.vertical, Space.m)
                    .overlay(alignment: .bottom) { Hairline() }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, Space.gutter)
        }
        .canvasBackground()
        .clusterNavigation("Activity")
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
    }

    private func requestRow(_ person: ProfileStub) -> some View {
        let name = person.displayName.isEmpty ? "@\(person.username)" : person.displayName
        let busy = answering.contains(person.id)
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Avatar(name: person.displayName, path: person.avatarPath, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(ClusterFont.body(.subheadline)).foregroundStyle(ClusterColor.ink)
                    Text("@\(person.username)").font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkTertiary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            HStack(spacing: Space.s) {
                Button { Task { await answer(person, accept: false) } } label: { Text("Decline").frame(maxWidth: .infinity) }
                    .buttonStyle(.clusterSecondary)
                    .accessibilityLabel("Decline \(name)")
                    .accessibilityIdentifier("decline-follow-\(person.username)")
                Button { Task { await answer(person, accept: true) } } label: { Text("Accept").frame(maxWidth: .infinity) }
                    .buttonStyle(.cluster)
                    .accessibilityLabel("Accept \(name)")
                    .accessibilityIdentifier("accept-follow-\(person.username)")
            }
            .disabled(busy)
        }
        .padding(.vertical, Space.m)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func load() async {
        do {
            items = try await app.backend.notifications()
            error = nil
            try? await app.backend.markNotificationsRead()
            await app.refreshNotifications()
        } catch {
            self.error = error.localizedDescription
        }
        do {
            requests = try await app.backend.followRequests()
            requestError = nil
        } catch {
            requestError = error.localizedDescription
        }
        isLoaded = true
    }

    private func answer(_ person: ProfileStub, accept: Bool) async {
        answering.insert(person.id)
        defer { answering.remove(person.id) }
        do {
            try await app.backend.answerFollowRequest(from: person.id, accept: accept)
            requests.removeAll { $0.id == person.id }
            requestError = nil
        } catch {
            requestError = error.localizedDescription
        }
    }

    private func symbol(_ kind: AppNotification.Kind) -> String {
        kind == .driveValidated ? "checkmark.seal" : "bell"
    }

    private func text(_ item: AppNotification) -> String {
        let name = item.actor?.displayName ?? "Someone"
        switch item.kind {
        case .follow: return "\(name) started following you."
        case .followRequest: return "\(name) asked to follow you."
        case .like: return "\(name) liked your post."
        case .comment: return "\(name) commented on your post."
        case .meetRSVP: return "\(name) is going to your meet."
        case .meetUpdated: return "\(name) updated a meet you're going to."
        case .meetCancelled: return "\(name) cancelled a meet you were going to."
        case .meetStartingSoon: return "A meet you're going to starts soon."
        case .driveValidated: return "Your drive was checked by the server."
        case .message: return "\(name) sent you a message."
        case .messageRequest: return "\(name) wants to send you a message."
        }
    }
}
