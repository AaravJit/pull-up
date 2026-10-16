import SwiftUI
import PullUpDesign
import PullUpDomain

/// The Drive tab. One stage, three states, one continuous shape:
///
///   idle      Start Drive button pinned to the bottom
///   picking   that button grows upward into the vehicle picker
///   recording the picker grows to fill the screen as the live dashboard
///
/// The morph is a shared `matchedGeometryEffect` on the background shape of
/// each state. Under Reduce Motion the states crossfade instead.
public struct DriveTabView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var stage
    @State private var pickerOpen = false

    public init() {}

    private var recorder: DriveRecorder { app.recorder }
    private var isLive: Bool { recorder.phase == .recording || recorder.phase == .finishing }

    private var stateKey: Int { isLive ? 2 : pickerOpen ? 1 : 0 }

    private var stageAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : Motion.sheet
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            NavigationStack {
                DriveHomeView(stage: stage, showsButtonShape: !pickerOpen && !isLive) {
                    pickerOpen = true
                }
            }
            .accessibilityHidden(pickerOpen || isLive)

            if pickerOpen && !isLive {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { pickerOpen = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                StartDrivePicker(stage: stage) { pickerOpen = false }
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .identity, removal: .opacity))
                    .zIndex(1)
            }

            if isLive {
                LiveDashboardView(stage: stage)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(stageAnimation, value: stateKey)
        .toolbar(isLive ? .hidden : .visible, for: .tabBar)
        .onChange(of: recorder.phase) { _, phase in
            if phase == .recording { pickerOpen = false }
        }
        .sheet(item: Binding(get: { recorder.lastResult }, set: { if $0 == nil { recorder.clearResult() } })) { result in
            NavigationStack {
                DriveSummaryView(result: result, isFresh: true)
            }
            .clusterTheme(app.themeStore.theme)
        }
    }
}
