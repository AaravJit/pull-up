import SwiftUI
import UIKit
import UserNotifications
import PullUpDesign

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
                Button("Allow") { Task { await request() } }.buttonStyle(.clusterSecondary)
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
        case .denied: "Turned off in iOS Settings."
        case .notDetermined: "Follows, comments and changes to meets you're going to."
        default: "On for follows, comments and meet changes."
        }
    }

    private func request() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
