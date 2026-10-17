import SwiftUI
import PullUpDesign
import PullUpDomain

/// Create or edit a vehicle. Saves through `GarageStore`, so the new car is
/// selectable in the Start Drive picker the moment this closes.
struct VehicleEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let original: Vehicle?
    var onSave: (Vehicle) -> Void = { _ in }

    @State private var kind: VehicleKind
    @State private var bodyStyle: BodyStyle
    @State private var make: String
    @State private var model: String
    @State private var year: String
    @State private var trim: String
    @State private var nickname: String
    @State private var mileage: String
    @State private var mileageUnit: SpeedUnit
    @State private var identity: AccentChoice
    @State private var audience: Audience
    @State private var summary: String
    @State private var isArchived: Bool
    @State private var isSaving = false
    @State private var error: String?
    @State private var confirmingDelete = false

    init(vehicle: Vehicle?, onSave: @escaping (Vehicle) -> Void = { _ in }) {
        original = vehicle
        self.onSave = onSave
        _kind = State(initialValue: vehicle?.kind ?? .car)
        _bodyStyle = State(initialValue: vehicle?.bodyStyle ?? .coupe)
        _make = State(initialValue: vehicle?.make ?? "")
        _model = State(initialValue: vehicle?.model ?? "")
        _year = State(initialValue: vehicle.map { String($0.year) } ?? "")
        _trim = State(initialValue: vehicle?.trim ?? "")
        _nickname = State(initialValue: vehicle?.nickname ?? "")
        _mileage = State(initialValue: vehicle?.mileage.map(String.init) ?? "")
        _mileageUnit = State(initialValue: vehicle?.mileageUnit ?? .mph)
        _identity = State(initialValue: vehicle?.identityColor ?? .sodium)
        _audience = State(initialValue: vehicle?.visibility ?? .friends)
        _summary = State(initialValue: vehicle?.summary ?? "")
        _isArchived = State(initialValue: vehicle?.isArchived ?? false)
    }

    private var parsedYear: Int? {
        guard let value = Int(year.trimmingCharacters(in: .whitespaces)) else { return nil }
        let maxYear = Calendar.current.component(.year, from: .now) + 2
        return (1885...maxYear).contains(value) ? value : nil
    }

    private var canSave: Bool {
        !make.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty && parsedYear != nil && !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    preview
                    VStack(alignment: .leading, spacing: Space.s) {
                        Legend("Type")
                        SwitchBank(VehicleKind.allCases, selection: $kind) { $0.label }
                    }
                    bodyStylePicker
                    VStack(alignment: .leading, spacing: Space.l) {
                        HStack(spacing: Space.l) {
                            FieldRow(label: "Make", text: $make, prompt: "Mazda")
                            FieldRow(label: "Year", text: $year, prompt: "1994", keyboard: .numberPad).frame(width: 90)
                        }
                        FieldRow(label: "Model", text: $model, prompt: "RX-7")
                        FieldRow(label: "Trim", text: $trim, prompt: "Optional")
                        FieldRow(label: "Nickname", text: $nickname, prompt: "Optional")
                        HStack(alignment: .bottom, spacing: Space.l) {
                            FieldRow(label: "Odometer", text: $mileage, prompt: "Optional", keyboard: .numberPad)
                            SwitchBank([SpeedUnit.mph, .kmh], selection: $mileageUnit) { $0 == .mph ? "mi" : "km" }.frame(width: 110)
                        }
                        FieldRow(label: "About", text: $summary, prompt: "Build notes, history", axis: .vertical)
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        Legend("Identity colour")
                        AccentSwatches(selection: $identity)
                        Text("Used for this vehicle's plate, gauge needle and garage tile.")
                            .font(ClusterFont.body(.caption))
                            .foregroundStyle(ClusterColor.inkTertiary)
                    }
                    AudiencePicker(title: "Who can see this vehicle", selection: $audience)
                    if original != nil { manageSection }
                    if let error { ErrorLine(message: error) }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.l)
            }
            .canvasBackground()
            .clusterNavigation(original == nil ? "Add vehicle" : "Edit vehicle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save") { Task { await save() } }
                        .disabled(!canSave)
                        .accessibilityIdentifier("vehicle-save")
                }
            }
            .onChange(of: kind) { _, newKind in
                if bodyStyle.kind != newKind, bodyStyle != .other { bodyStyle = newKind == .car ? .coupe : .sport }
            }
            .task {
                guard original == nil, let settings = try? await app.backend.privacySettings() else { return }
                audience = settings.defaultVehicleVisibility
            }
            .confirmationDialog("Delete \(original?.displayName ?? "vehicle")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete vehicle", role: .destructive) { Task { await delete() } }
            } message: {
                Text("Its photos and mods are deleted. Drives stay in your history as guest drives.")
            }
        }
    }

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            VehiclePlaceholder(style: bodyStyle, identity: identity)
                .frame(height: 150)
                .clipShape(ChamferedRectangle(cut: Radius.chamfer))
            Legend(previewTitle, color: ClusterColor.inkSecondary)
                .padding(Space.m)
        }
        .animation(Motion.select, value: bodyStyle)
        .accessibilityHidden(true)
    }

    private var previewTitle: String {
        let name = [year, make, model].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? bodyStyle.label : name
    }

    private var bodyStylePicker: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend("Body")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Space.s)], spacing: Space.s) {
                ForEach(BodyStyle.styles(for: kind)) { style in
                    let selected = style == bodyStyle
                    Button {
                        withAnimation(Motion.select) { bodyStyle = style }
                    } label: {
                        VStack(spacing: Space.xs) {
                            VehicleSilhouette(style, color: selected ? ClusterColor.accent(identity) : ClusterColor.inkSecondary, lineWidth: 1.2, showsGround: false)
                                .frame(height: 30)
                            Text(style.label)
                                .font(ClusterFont.legend(.caption2))
                                .textCase(.uppercase)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .foregroundStyle(selected ? ClusterColor.ink : ClusterColor.inkTertiary)
                        }
                        .padding(Space.s)
                        .frame(maxWidth: .infinity)
                        .plate(raised: selected, cut: Radius.chamferSmall, stroke: selected ? ClusterColor.accent(identity) : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: bodyStyle)
        }
    }

    private var manageSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Manage")
            Toggle(isOn: $isArchived) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Archive").font(ClusterFont.headline(.subheadline))
                    Text("Sold or stored. Hidden from the picker and your garage, history kept.")
                        .font(ClusterFont.body(.caption)).foregroundStyle(ClusterColor.inkSecondary)
                }
            }
            Button("Delete vehicle", role: .destructive) { confirmingDelete = true }
                .font(ClusterFont.headline(.subheadline))
        }
    }

    private func save() async {
        guard let owner = app.userID, let parsedYear else { return }
        isSaving = true
        defer { isSaving = false }
        var vehicle = original ?? Vehicle(ownerID: owner, kind: kind, make: "", model: "", year: parsedYear)
        vehicle.kind = kind
        vehicle.bodyStyle = bodyStyle
        vehicle.make = make.trimmingCharacters(in: .whitespaces)
        vehicle.model = model.trimmingCharacters(in: .whitespaces)
        vehicle.year = parsedYear
        vehicle.trim = trim.trimmingCharacters(in: .whitespaces)
        vehicle.nickname = nickname.trimmingCharacters(in: .whitespaces)
        vehicle.mileage = Int(mileage.filter(\.isNumber))
        vehicle.mileageUnit = mileageUnit
        vehicle.identityColor = identity
        vehicle.visibility = audience
        vehicle.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        vehicle.isArchived = isArchived
        do {
            let saved = try await app.garage.save(vehicle)
            onSave(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let original else { return }
        do {
            try await app.garage.delete(original)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
