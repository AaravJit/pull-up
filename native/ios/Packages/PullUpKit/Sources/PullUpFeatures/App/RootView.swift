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
            if app.showsDemoLabels { DemoStrip() }
            if case .signedIn = app.phase, let suspension = app.account?.suspension {
                SuspendedStrip(suspension: suspension)
            }
            Group {
                switch app.phase {
                case .launching:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .setupRequired:
                    SetupRequiredView()
                case .signedOut:
                    AuthView()
                case .onboarding:
                    if app.consentGate { ConsentGateView() } else { OnboardingView() }
                case .signedIn:
                    // Never in the middle of a drive; it waits until the drive ends.
                    if app.consentGate && !app.recorder.isRecording { ConsentGateView() } else { MainTabView() }
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
                    await app.foregrounded()
                    await app.recheckConsent()
                }
            }
        }
    }
}

/// Feed, Messages, Explore and You. Driving is one tap from You and from
/// Explore, and takes the whole screen while a drive records.
struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Feed", systemImage: "house", value: MainTab.feed) { FeedView() }
            Tab("Messages", systemImage: "bubble.left.and.bubble.right", value: MainTab.messages) { MessagesTab() }
                .badge(app.unreadMessages.total)
            Tab("Explore", systemImage: "map", value: MainTab.explore) { ExploreView() }
            Tab("You", systemImage: "person.crop.circle", value: MainTab.you) { YouView() }
        }
        .modifier(MinimizingTabBar())
        .fullScreenCover(isPresented: Binding(get: { app.driveIsPresented }, set: { if !$0 { app.driveOpen = false } })) {
            DriveTabView()
                .environment(app)
                .clusterTheme(app.themeStore.theme)
        }
    }
}

/// On iOS 26 the tab bar shrinks while content scrolls down, so photos get
/// the room. Earlier versions keep the standard bar.
private struct MinimizingTabBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
