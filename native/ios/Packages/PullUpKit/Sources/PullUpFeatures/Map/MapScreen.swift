import MapKit
import SwiftUI
import PullUpDesign
import PullUpDomain

/// Full-screen, map-first view of meets and the user's own routes.
///
/// It never shows anyone's live position. Meets are pinned at their venue;
/// routes are the user's own private tracks, visible only to them.
public struct MapScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    /// `.automatic` frames whatever the map contains: venues or your routes.
    /// An explicit region set before the tab has a size is applied to a
    /// zero-sized map and comes out wrong.
    @State private var position: MapCameraPosition = .automatic
    @State private var meets: [Meet] = []
    @State private var routes: [RouteLine] = []
    @State private var layer: Layer = .meets
    @State private var selectedMeet: Meet.ID?
    @State private var openMeet: Meet?
    @State private var error: String?

    enum Layer: String, CaseIterable, Identifiable {
        case meets, routes
        var id: String { rawValue }
        var label: String { self == .meets ? "Meets" : "My routes" }
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map
                VStack(spacing: Space.s) {
                    header
                    if let error { ErrorLine(message: error) { Task { await load() } } }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.s)
            }
            .safeAreaInset(edge: .bottom) {
                if layer == .meets, !meets.isEmpty { meetStrip }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openMeet) { meet in MeetDetailView(meetID: meet.id, initial: meet) }
            .task { await load() }
        }
    }

    private var map: some View {
        Map(position: $position, selection: $selectedMeet) {
            if layer == .meets {
                ForEach(meets) { meet in
                    Annotation(meet.title, coordinate: meet.coordinate.clLocation, anchor: .bottom) {
                        MeetPin(meet: meet, isSelected: selectedMeet == meet.id)
                    }
                    .tag(meet.id)
                }
            } else {
                ForEach(routes) { route in
                    MapPolyline(coordinates: route.coordinates.map(\.clLocation))
                        .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onChange(of: selectedMeet) { _, id in
            guard let meet = meets.first(where: { $0.id == id }) else { return }
            withAnimation(Motion.sheet) {
                position = .region(MKCoordinateRegion(center: meet.coordinate.clLocation, span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)))
            }
        }
        .onChange(of: layer) { _, _ in
            withAnimation(Motion.sheet) { frameContent() }
        }
        // Keeps automatic framing clear of the floating header.
        .safeAreaPadding(.top, 190)
        .ignoresSafeArea(edges: .top)
        .accessibilityIdentifier("map")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Map")
                    .font(ClusterFont.title(.title2))
                    .foregroundStyle(ClusterColor.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if app.isDemo { Legend("Demo", color: ClusterColor.estimate) }
            }
            SwitchBank(Layer.allCases, selection: $layer) { $0.label }
            Text(layer == .meets
                 ? "Venues only. Pull Up never shows anyone's live location."
                 : "Your own drives. Only you can see these.")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkSecondary)
        }
        .padding(Space.m)
        .background(.regularMaterial, in: ChamferedRectangle(cut: Radius.chamfer))
    }

    private var meetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Space.m) {
                ForEach(meets) { meet in
                    Button {
                        if selectedMeet == meet.id { openMeet = meet } else { selectedMeet = meet.id }
                    } label: {
                        MeetMapCard(meet: meet, isSelected: selectedMeet == meet.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(selectedMeet == meet.id ? "Opens the meet." : "Shows the venue on the map.")
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, Space.m)
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Space.gutter, for: .scrollContent)
    }

    private func load() async {
        do {
            meets = try await app.backend.meets(from: .now).filter { !$0.isCancelled }
            error = nil
            frameContent()
        } catch {
            self.error = error.localizedDescription
        }
        guard let me = app.userID, let drives = try? await app.backend.drives(owner: me, limit: 6) else { return }
        var loaded: [RouteLine] = []
        for drive in drives {
            if let track = try? await app.backend.ownTrack(drive: drive.id), track.count > 1 {
                loaded.append(RouteLine(id: drive.id, coordinates: track.map(\.coordinate)))
            }
        }
        routes = loaded
        frameContent()
    }

    /// Re-frames the camera to the visible layer's content, never to the
    /// device's location (the map has no user annotation).
    private func frameContent() {
        position = .automatic
    }
}

struct RouteLine: Identifiable {
    let id: UUID
    let coordinates: [Coordinate]
}

struct MeetPin: View {
    @Environment(\.clusterTheme) private var theme
    let meet: Meet
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: meet.kind.symbol)
                .font(.system(size: isSelected ? 16 : 13, weight: .bold))
                .foregroundStyle(ClusterColor.accentPrefersDarkText(theme.accent) ? ClusterColor.onAccent : .white)
                .frame(width: isSelected ? 38 : 30, height: isSelected ? 38 : 30)
                .background(ChamferedRectangle(cut: 6).fill(meet.isLive() ? ClusterColor.live : theme.accentColor))
            Rectangle().fill(meet.isLive() ? ClusterColor.live : theme.accentColor).frame(width: 2, height: 8)
        }
        .animation(Motion.select, value: isSelected)
        .accessibilityLabel(meet.title)
    }
}

struct MeetMapCard: View {
    @Environment(\.clusterTheme) private var theme
    let meet: Meet
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            DateStamp(date: meet.startsAt, isLive: meet.isLive())
            VStack(alignment: .leading, spacing: Space.xxs) {
                Legend(meet.kind.label)
                Text(meet.title)
                    .font(ClusterFont.headline(.subheadline))
                    .foregroundStyle(ClusterColor.ink)
                    .lineLimit(1)
                Text(meet.venueName)
                    .font(ClusterFont.body(.caption))
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .lineLimit(1)
                Text("\(meet.goingCount) going")
                    .font(ClusterFont.readout(.caption))
                    .foregroundStyle(ClusterColor.inkTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .frame(width: 270)
        .background(.regularMaterial, in: ChamferedRectangle(cut: Radius.chamfer))
        .overlay {
            ChamferedRectangle(cut: Radius.chamfer).strokeBorder(isSelected ? theme.accentColor : .clear, lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Meet.Kind {
    var symbol: String {
        switch self {
        case .meet: "car.2"
        case .cruise: "road.lanes"
        case .ride: "motorcycle"
        case .show: "star"
        case .trackDay: "flag.checkered"
        }
    }
}
