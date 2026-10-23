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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Both `.automatic` and an explicit region depend on the map's size and
    /// insets, and in a tab they came out at world or coast zoom. A camera
    /// (centre plus distance) doesn't, so the map is framed with one, after
    /// its content has loaded.
    @State private var position: MapCameraPosition = .automatic
    @State private var didLoad = false
    @State private var meets: [Meet] = []
    @State private var routes: [RouteLine] = []
    @State private var layer: Layer = .meets
    @State private var selectedMeet: Meet.ID?
    @State private var openMeet: Meet?
    @State private var error: String?
    /// Where the map, the header over it and the meet strip under it are,
    /// in one coordinate space, so framing fits the window's real shape.
    @State private var mapFrame: CGRect = .zero
    @State private var headerFrame: CGRect = .zero
    @State private var stripFrame: CGRect = .zero

    enum Layer: String, CaseIterable, Identifiable {
        case meets, routes
        var id: String { rawValue }
        var label: String { self == .meets ? "Meets" : "My routes" }
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if didLoad {
                    map.id(layer)
                } else {
                    ClusterColor.canvas.ignoresSafeArea()
                }
                VStack(spacing: Space.s) {
                    header
                    if let error { ErrorLine(message: error) { Task { await load() } } }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { headerFrame = $0 }
                // Capped and centred, so a wide window doesn't stretch it.
                .frame(maxWidth: 600)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.s)
            }
            .background {
                // Same extent as the map, which runs up under the status bar.
                Color.clear
                    .ignoresSafeArea(edges: .top)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mapFrame = $0 }
            }
            .safeAreaInset(edge: .bottom) {
                if layer == .meets, !meets.isEmpty {
                    meetStrip
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stripFrame = $0 }
                        .onDisappear { stripFrame = .zero }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openMeet) { meet in MeetDetailView(meetID: meet.id, initial: meet) }
            .task {
                await load()
                frameContent()
                didLoad = true
            }
            .onChange(of: layer) { _, _ in withAnimation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion)) { frameContent() } }
            // A rotation, Split View or a foldable opening changes the map's
            // shape: fit the content to the new one, unless a meet is in focus.
            .onChange(of: [mapFrame.size.width, mapFrame.size.height, clearArea.minY, clearArea.maxY]) { _, _ in
                if didLoad, selectedMeet == nil { frameContent() }
            }
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
            withAnimation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion)) {
                position = .region(MKCoordinateRegion(center: meet.coordinate.clLocation, span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)))
            }
        }
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
                        MeetMapCard(meet: meet, isSelected: selectedMeet == meet.id, width: MapLayout.meetCardWidth(availableWidth: mapFrame.width))
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
        // A horizontal scroll view otherwise takes all the height offered,
        // which floated the cards mid-screen and squeezed the map above them.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func load() async {
        do {
            meets = try await app.backend.meets(from: .now).filter { !$0.isCancelled }
            error = nil
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
    }

    /// The part of the map the header and the meet strip leave uncovered, in
    /// the map's own coordinates.
    private var clearArea: CGRect {
        let top = headerFrame.isEmpty ? 0 : max(0, headerFrame.maxY - mapFrame.minY)
        let bottom = stripFrame.isEmpty ? mapFrame.height : min(mapFrame.height, stripFrame.minY - mapFrame.minY)
        return CGRect(x: 0, y: top, width: mapFrame.width, height: max(0, bottom - top))
    }

    /// Frames the visible layer's content (venues or your routes), never the
    /// device's location.
    private func frameContent() {
        let points: [Coordinate] = layer == .meets ? meets.map(\.coordinate) : routes.flatMap(\.coordinates)
        guard !points.isEmpty else { return }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let latSpan = (lats.max()! - lats.min()!), lonSpan = (lons.max()! - lons.min()!)
        let camera = MapLayout.camera(contentWidth: lonSpan * 87_000, contentHeight: latSpan * 111_000, map: mapFrame.size, clear: clearArea)
        let center = CLLocationCoordinate2D(
            latitude: (lats.max()! + lats.min()!) / 2 + camera.northOffset / 111_000,
            longitude: (lons.max()! + lons.min()!) / 2
        )
        position = .camera(MapCamera(centerCoordinate: center, distance: camera.distance))
    }
}

struct RouteLine: Identifiable {
    let id: UUID
    let coordinates: [Coordinate]
}

struct MeetPin: View {
    @Environment(\.clusterTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .animation(Motion.resolved(Motion.select, reduceMotion: reduceMotion), value: isSelected)
        .accessibilityLabel(meet.title)
    }
}

struct MeetMapCard: View {
    @Environment(\.clusterTheme) private var theme
    let meet: Meet
    let isSelected: Bool
    var width: CGFloat = 270

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
        .frame(width: width)
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
