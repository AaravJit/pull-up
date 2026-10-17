import SwiftUI
import PullUpDesign
import PullUpDomain

struct NotificationsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AppNotification] = []
    @State private var isLoaded = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error {
                    ErrorLine(message: error) { Task { await load() } }
                } else if isLoaded, items.isEmpty {
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
        .clusterNavigation("Notifications")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { await load() }
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
        isLoaded = true
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
