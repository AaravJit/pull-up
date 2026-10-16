import PhotosUI
import SwiftUI
import UIKit
import PullUpDesign
import PullUpDomain

struct VehicleDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    let vehicleID: UUID

    @State private var mods: [VehicleModification] = []
    @State private var photos: [VehiclePhoto] = []
    @State private var drives: [Drive] = []
    @State private var editing = false
    @State private var addingMod = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var error: String?

    private var vehicle: Vehicle? { app.garage.vehicle(vehicleID) }

    var body: some View {
        Group {
            if let vehicle {
                content(vehicle)
            } else {
                EmptyState(title: "Vehicle removed", message: "This vehicle is no longer in your garage.")
            }
        }
        .canvasBackground()
        .clusterNavigation(vehicle?.displayName ?? "Vehicle")
        .toolbar {
            if vehicle != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("vehicle-edit")
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let vehicle { VehicleEditorView(vehicle: vehicle) }
        }
        .sheet(isPresented: $addingMod) {
            ModEditorView(vehicleID: vehicleID) { await load() }
        }
        .task { await load() }
        .onChange(of: photoItem) { _, item in
            guard let item, let vehicle else { return }
            Task { await upload(item, to: vehicle) }
        }
    }

    private func content(_ vehicle: Vehicle) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                hero(vehicle)
                VStack(alignment: .leading, spacing: Space.xl) {
                    titleBlock(vehicle)
                    statsStrip
                    specs(vehicle)
                    modsSection
                    drivesSection
                    if let error { ErrorLine(message: error) }
                }
                .padding(.horizontal, Space.gutter)
            }
            .padding(.bottom, Space.xxl)
        }
    }

    private func hero(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { VehicleArtwork(vehicle: vehicle) }
                .clipped()
            Rectangle().fill(ClusterColor.accent(vehicle.identityColor)).frame(height: 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(photos) { photo in
                        StorageImage(bucket: .vehicleMedia, path: photo.storagePath) { ClusterColor.plateRaised }
                            .frame(width: 88, height: 66)
                            .clipShape(ChamferedRectangle(cut: 4))
                    }
                    let isUploading = uploading
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        MediaPickerLabel(isLoading: isUploading, symbol: "camera", title: "Add photo", width: 88, height: 66, cut: 4)
                    }
                    .disabled(uploading)
                    .accessibilityLabel("Add photo")
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.m)
            }
        }
    }

    private func titleBlock(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend("\(vehicle.year) · \(vehicle.kind.label) · \(vehicle.bodyStyle.label)")
            Text("\(vehicle.make) \(vehicle.model)")
                .font(ClusterFont.title(.largeTitle))
                .tracking(Tracking.title)
                .foregroundStyle(ClusterColor.ink)
            if !vehicle.nickname.isEmpty {
                Text("“\(vehicle.nickname)”").font(ClusterFont.headline()).foregroundStyle(ClusterColor.inkSecondary)
            }
            HStack {
                VisibilityTag(vehicle.visibility)
                if vehicle.isArchived { Legend("Archived", color: ClusterColor.estimate) }
            }
            if !vehicle.summary.isEmpty {
                Text(vehicle.summary)
                    .font(ClusterFont.body())
                    .foregroundStyle(ClusterColor.ink)
                    .padding(.top, Space.xs)
            }
        }
    }

    private var statsStrip: some View {
        let distance = drives.reduce(0) { $0 + $1.distanceMeters }
        let top = drives.compactMap(\.topSpeed).max()
        return HStack(alignment: .top, spacing: Space.l) {
            Readout("Drives", value: "\(drives.count)")
            Readout("Logged", value: Format.distance(distance, theme.unit), unit: theme.unit.distanceLabel)
            Readout("Top", value: Format.speed(top, theme.unit), unit: theme.unit.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { TickRule(ticks: 40, majorEvery: 10, height: 5) }
    }

    private func specs(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Spec")
            SpecRow(label: "Make", value: vehicle.make)
            SpecRow(label: "Model", value: vehicle.model)
            if !vehicle.trim.isEmpty { SpecRow(label: "Trim", value: vehicle.trim) }
            SpecRow(label: "Year", value: String(vehicle.year))
            if let mileage = vehicle.mileage {
                SpecRow(label: "Odometer", value: "\(mileage.formatted()) \(vehicle.mileageUnit == .mph ? "mi" : "km")")
            }
        }
    }

    private var modsSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Modifications") {
                Button {
                    addingMod = true
                } label: {
                    Label("Add", systemImage: "plus").font(ClusterFont.headline(.footnote))
                }
                .accessibilityLabel("Add modification")
            }
            if mods.isEmpty {
                Text("Stock, or not logged yet.")
                    .font(ClusterFont.body(.subheadline))
                    .foregroundStyle(ClusterColor.inkSecondary)
            } else {
                let groups = Dictionary(grouping: mods, by: \.category)
                ForEach(VehicleModification.Category.allCases.filter { groups[$0] != nil }) { category in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Legend(category.label, color: ClusterColor.inkSecondary)
                        ForEach(groups[category] ?? []) { mod in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mod.title).font(ClusterFont.headline(.subheadline)).foregroundStyle(ClusterColor.ink)
                                    if !mod.brand.isEmpty || !mod.notes.isEmpty {
                                        Text([mod.brand, mod.notes].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                                    }
                                }
                                Spacer()
                                if let installed = mod.installedOn {
                                    Text(installed.formatted(.dateTime.month(.abbreviated).year()))
                                        .font(ClusterFont.readout(.caption)).foregroundStyle(ClusterColor.inkTertiary)
                                }
                            }
                            .padding(.vertical, Space.xs)
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task {
                                        try? await app.backend.deleteModification(mod.id)
                                        await load()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, Space.xs)
                    .overlay(alignment: .bottom) { Hairline() }
                }
            }
        }
    }

    private var drivesSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Drives")
            if drives.isEmpty {
                Text("Pick this vehicle in Start Drive and its drives collect here.")
                    .font(ClusterFont.body(.subheadline))
                    .foregroundStyle(ClusterColor.inkSecondary)
            } else {
                ForEach(drives.prefix(10)) { drive in
                    NavigationLink {
                        DriveHistoryDetail(drive: drive)
                    } label: {
                        DriveRow(drive: drive, vehicle: vehicle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        guard let owner = app.userID else { return }
        let backend = app.backend
        let id = vehicleID
        async let mods = backend.modifications(vehicle: id)
        async let photos = backend.photos(vehicle: id)
        async let drives = backend.drives(owner: owner, limit: 200)
        self.mods = (try? await mods) ?? []
        self.photos = (try? await photos) ?? []
        self.drives = ((try? await drives) ?? []).filter { $0.vehicleID == vehicleID }
    }

    private func upload(_ item: PhotosPickerItem, to vehicle: Vehicle) async {
        uploading = true
        defer {
            uploading = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let jpeg = ImageProcessing.uploadJPEG(from: data) else {
                error = "That photo couldn't be read."
                return
            }
            try await app.garage.addPhoto(jpeg, to: vehicle)
            photos = (try? await app.backend.photos(vehicle: vehicleID)) ?? photos
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum ImageProcessing {
    /// Downscales to at most 2048 px and re-encodes as JPEG. Re-encoding from
    /// pixels drops EXIF, including the GPS position the photo was taken at,
    /// so uploads never leak where someone parks.
    static func uploadJPEG(from data: Data, maxDimension: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.84)
    }
}

struct ModEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let vehicleID: UUID
    let onSaved: () async -> Void

    @State private var category: VehicleModification.Category = .engine
    @State private var title = ""
    @State private var brand = ""
    @State private var notes = ""
    @State private var hasDate = false
    @State private var installedOn = Date.now
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Legend("Category")
                        Picker("Category", selection: $category) {
                            ForEach(VehicleModification.Category.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    FieldRow(label: "Part", text: $title, prompt: "Coilovers")
                    FieldRow(label: "Brand", text: $brand, prompt: "Optional")
                    FieldRow(label: "Notes", text: $notes, prompt: "Optional", axis: .vertical)
                    Toggle("Installed on a known date", isOn: $hasDate)
                    if hasDate { DatePicker("Installed", selection: $installedOn, displayedComponents: .date) }
                    if let error { ErrorLine(message: error) }
                }
                .padding(Space.gutter)
            }
            .canvasBackground()
            .clusterNavigation("Add modification")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            do {
                                try await app.backend.saveModification(VehicleModification(
                                    vehicleID: vehicleID, category: category, title: title.trimmingCharacters(in: .whitespaces),
                                    brand: brand, notes: notes, installedOn: hasDate ? installedOn : nil
                                ))
                                await onSaved()
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
