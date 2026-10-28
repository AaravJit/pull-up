import SwiftUI
import PullUpDesign
import PullUpDomain

/// The Explore tab: meets, the map and people, one segmented control apart.
/// Each keeps its own state while you switch, and the last one you used is
/// where Explore opens next.
struct ExploreView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var query = ""

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $path) {
            Group {
                switch app.exploreMode {
                case .meets: MeetsList()
                case .map: MapScreen()
                case .people: people
                }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Explore", selection: $app.exploreMode) {
                        ForEach(ExploreMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("explore-mode")
                }
                ToolbarItem(placement: .topBarLeading) {
                    DriveButton()
                }
            }
            .navigationDestination(for: ProfileRoute.self) { ProfileView(userID: $0.id) }
            .sensoryFeedback(.selection, trigger: app.exploreMode)
        }
    }

    private var people: some View {
        PeopleList(query: query) { person in
            path.append(ProfileRoute(id: person.id))
        } trailing: { _ in
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ClusterColor.inkTertiary)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find people by name or username")
        .accessibilityIdentifier("explore-people")
    }
}

/// Opens the Drive screen. Nothing records until a vehicle is confirmed.
struct DriveButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.openDrive()
        } label: {
            Label("Drive", systemImage: "steeringwheel")
        }
        .accessibilityHint("Opens Drive. Recording starts only after you pick a vehicle and confirm.")
        .accessibilityIdentifier("open-drive")
    }
}
