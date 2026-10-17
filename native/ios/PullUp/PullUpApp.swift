import SwiftUI
import UIKit
import UserNotifications
import PullUpFeatures

@main
struct PullUpApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(store: StoreKitClient())

    var body: some Scene {
        WindowGroup {
            RootView(app: model)
                .onOpenURL { url in Task { await model.open(url) } }
        }
    }
}

/// Forwards the APNs token to the backend and opens tapped pushes.
/// Permission is requested from Settings, never at launch; this only
/// re-registers when it's already on.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .authorized { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            #if DEBUG
            let sandbox = true
            #else
            let sandbox = false
            #endif
            await AppModel.shared?.didReceivePushToken(token, sandbox: sandbox)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String
        let conversationID = info["conversation_id"] as? String
        Task { @MainActor in AppModel.shared?.openPush(kind: kind, conversationID: conversationID) }
        completionHandler()
    }
}
