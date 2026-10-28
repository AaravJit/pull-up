import SwiftUI
import PullUpDesign
import PullUpDomain

/// You ▸ Garage. Photography-led: the first vehicle in the user's order gets
/// a full-width hero, the rest sit in a grid that widens on large displays.
struct GarageView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .all
    @State private var adding = false
    @State private var arranging = false
    @State private var findingParts = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, cars, motorcycles
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        func includes(_ vehicle: Vehicle) -> Bool {
            switch self {
            case .all: true
            case .cars: vehicle.kind == .car
            case .motorcycles: vehicle.kind == .motorcycle
            }
        }
    }

    private var vehicles: [Vehicle] { app.garage.active.filter(filter.includes) }

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if app.garage.isLoaded, !app.garage.active.isEmpty {
                        Text(countLine)
                            .font(ClusterFont.body(.subheadline))
                            .foregroundStyle(ClusterColor.inkSecondary)
                    }
                    if hasBothKinds {
                        SwitchBank(Filter.allCases, selection: $filter) { $0.label }
                    }
                    content
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .canvasBackground()
            .refreshable { await app.garage.reload() }
            .navigationTitle("Garage")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add vehicle", systemImage: "plus") { adding = true }
                        Button("Arrange", systemImage: "arrow.up.arrow.down") { arranging = true }
                            .disabled(app.garage.active.count < 2)
                        Button("Find parts", systemImage: "wrench.and.screwdriver") { findingParts = true }
                    } label: {
                        Label("Garage actions", systemImage: "plus")
                    }
                    .accessibilityIdentifier("garage-actions")
                }
            }
            .navigationDestination(isPresented: $findingParts) { PartsFinderView(vehicle: app.garage.active.first) }
            .sheet(isPresented: $adding) { VehicleEditorView(vehicle: nil).sheetCanvas() }
            .sheet(isPresented: $arranging) { ArrangeGarageView().sheetCanvas() }
            .accessibilityIdentifier("garage")
    }

    private var hasBothKinds: Bool {
        Set(app.garage.active.map(\.kind)).count > 1
    }

    private var countLine: String {
        let cars = app.garage.active.filter { $0.kind == .car }.count
        let bikes = app.garage.active.count - cars
        var parts: [String] = []
        if cars > 0 { parts.append("\(cars) car\(cars == 1 ? "" : "s")") }
        if bikes > 0 { parts.append("\(bikes) motorcycle\(bikes == 1 ? "" : "s")") }
        return parts.isEmpty ? "Your vehicles" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let error = app.garage.loadError {
            ErrorLine(message: error) { Task { await app.garage.reload() } }
        } else if !app.garage.isLoaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if app.garage.active.isEmpty {
            EmptyState(title: "No vehicles yet", message: "Add your car or motorcycle. Each one gets its own drive history, mods log and photos.") {
                Button {
                    adding = true
                } label: {
                    Label("Add a vehicle", systemImage: "plus")
                }
                .buttonStyle(.cluster)
            }
        } else {
            if let hero = vehicles.first {
                NavigationLink(value: hero.id) { GarageHeroTile(vehicle: hero) }
                    .buttonStyle(.plain)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Space.l)], spacing: Space.xl) {
                ForEach(vehicles.dropFirst()) { vehicle in
                    NavigationLink(value: vehicle.id) { GarageTile(vehicle: vehicle) }
                        .buttonStyle(.plain)
                }
            }
            if !app.garage.archived.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionHeader("Archived")
                    ForEach(app.garage.archived) { vehicle in
                        NavigationLink(value: vehicle.id) {
                            HStack {
                                Text(vehicle.displayName).font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.inkSecondary)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(ClusterColor.inkTertiary)
                            }
                            .padding(.vertical, Space.s)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct GarageHeroTile: View {
    let vehicle: Vehicle

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay { VehicleArtwork(vehicle: vehicle) }
                .clipShape(ChamferedRectangle(cut: Radius.photo))
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("\(vehicle.make) \(vehicle.model)")
                        .font(ClusterFont.title(.title2))
                        .foregroundStyle(ClusterColor.ink)
                    Text(detail)
                        .font(ClusterFont.body(.subheadline))
                        .foregroundStyle(ClusterColor.inkSecondary)
                }
                Spacer()
                VisibilityTag(vehicle.visibility)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("garage-tile-\(vehicle.model)")
    }

    private var detail: String {
        var parts = ["\(vehicle.year)"]
        if !vehicle.nickname.isEmpty { parts.append("“\(vehicle.nickname)”") } else if !vehicle.trim.isEmpty { parts.append(vehicle.trim) }
        return parts.joined(separator: " · ")
    }
}

struct GarageTile: View {
    let vehicle: Vehicle

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { VehicleArtwork(vehicle: vehicle) }
                .clipShape(ChamferedRectangle(cut: Radius.photo))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(vehicle.make) \(vehicle.model)")
                    .font(ClusterFont.headline(.subheadline))
                    .foregroundStyle(ClusterColor.ink)
                    .lineLimit(2)
                Text("\(vehicle.year) · \(vehicle.kind.label)")
                    .font(ClusterFont.body(.footnote))
                    .foregroundStyle(ClusterColor.inkSecondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("garage-tile-\(vehicle.model)")
    }
}

/// Manual garage order, also the picker's order.
struct ArrangeGarageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var order: [Vehicle] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(order) { vehicle in
                    HStack(spacing: Space.m) {
                        VehicleArtwork(vehicle: vehicle).frame(width: 64, height: 40).clipShape(ChamferedRectangle(cut: 4))
                        Text(vehicle.displayName).font(ClusterFont.headline(.subheadline))
                    }
                    .listRowBackground(ClusterColor.plate)
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .canvasBackground()
            .clusterNavigation("Arrange garage")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await app.garage.reorder(order)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { order = app.garage.active }
        }
    }
}
