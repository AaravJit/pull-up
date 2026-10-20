import SwiftUI
import PullUpDesign
import PullUpDomain

/// Entry point used by the app target.
public struct RootView: View {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(app: AppModel) {
        _app = State(initialValue: app)
    }

    public var body: some View {
        let theme = app.themeStore.theme
        VStack(spacing: 0) {
            if app.isDemo { DemoStrip() }
            Group {
                switch app.phase {
                case .launching:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .setupRequired:
                    SetupRequiredView()
                case .signedOut:
                    AuthView()
                case .onboarding:
                    OnboardingView()
                case .signedIn:
                    MainTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ClusterColor.canvas.ignoresSafeArea())
        .environment(app)
        .clusterTheme(theme)
        .task { await app.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await app.verifyAppleCredential()
                    await app.catchUpMessages()
                }
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Drive", systemImage: "gauge.with.needle", value: MainTab.drive) { DriveTabView() }
            Tab("Map", systemImage: "map", value: MainTab.map) { MapScreen() }
            Tab("Feed", systemImage: "photo.stack", value: MainTab.feed) { FeedView() }
            Tab("Meets", systemImage: "calendar", value: MainTab.meets) { MeetsView() }
            Tab("Garage", systemImage: "car.side", value: MainTab.garage) { GarageView() }
        }
    }
}
