import SwiftUI
import UIKit
import UserNotifications
import PullUpDesign
import PullUpDomain

/// Push permission is asked for here, when the user chooses, never at launch.
struct NotificationSettingsRow: View {
    @State private var status: UNAuthorizationStatus = .notDetermined
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Push notifications").font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                Text(detail).font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .notDetermined:
                Button("Allow") { Task { await request() } }
                    .buttonStyle(.clusterSecondary)
                    .accessibilityIdentifier("allow-push")
            case .denied:
                Button("Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.clusterSecondary)
            default:
                Image(systemName: "checkmark").foregroundStyle(ClusterColor.verified).accessibilityLabel("On")
            }
        }
        .task { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }

    private var detail: String {
        switch status {
        case .denied: "Turned off in iOS Settings, so none of the choices below reach this phone."
        case .notDetermined: "Allow pushes on this phone, then choose which ones below."
        default: "On for this phone."
        }
    }

    private func request() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// Which pushes to send. Saved to the server, which applies them before
/// pushing, so they follow the account to every phone.
struct NotificationPreferencesView: View {
    @Environment(AppModel.self) private var app
    @State private var preferences: NotificationPreferences?
    @State private var saved: NotificationPreferences?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                NotificationSettingsRow()
                    .padding(Space.m)
                    .plate()
                if let error {
                    ErrorLine(message: error) { Task { await load() } }
                }
                if preferences != nil {
                    categories
                    previews
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
                Text("These only change pushes. Everything still shows up in Activity and Messages, and muted conversations never push.")
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.l)
        }
        .canvasBackground()
        .clusterNavigation("Notifications")
        .task { await load() }
        .onChange(of: preferences) { _, value in
            guard let value, value != saved else { return }
            Task { await save(value) }
        }
        .accessibilityIdentifier("notification-preferences")
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Push me about")
            ForEach(NotificationPreferences.Category.allCases) { category in
                PrivacyToggle(title: category.title, detail: category.detail, isOn: binding(category))
                    .accessibilityIdentifier("push-\(category.rawValue)")
            }
        }
    }

    private var previews: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Lock screen")
            PrivacyToggle(
                title: "Show message text",
                detail: "Off: pushes say who wrote, never what. On: the first line of a message from someone in your inbox appears in the push. Requests never show text.",
                isOn: Binding(
                    get: { preferences?.messagePreviews ?? false },
                    set: { preferences?.messagePreviews = $0 }
                )
            )
            .disabled(preferences?.messages == false)
            .accessibilityIdentifier("push-previews")
        }
    }

    private func binding(_ category: NotificationPreferences.Category) -> Binding<Bool> {
        Binding(get: { preferences?[category] ?? true }, set: { preferences?[category] = $0 })
    }

    private func load() async {
        do {
            let value = try await app.backend.notificationPreferences()
            saved = value
            preferences = value
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ value: NotificationPreferences) async {
        do {
            try await app.backend.updateNotificationPreferences(value)
            saved = value
            error = nil
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            preferences = saved
        }
    }
}
