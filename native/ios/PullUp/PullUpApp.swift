import SwiftUI
import UIKit
import UserNotifications
import PullUpFeatures

@main
struct PullUpApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(app: model)
        }
    }
}

/// Forwards the APNs token to the backend. Permission is requested from
/// Settings, never at launch; this only re-registers when it's already on.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
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
            try? await AppModel.shared?.backend.registerPushToken(token, sandbox: sandbox)
        }
    }
}
