import SwiftUI
import UIKit
import PullUpDesign
import PullUpDomain

/// The panel that grows out of the Start Drive button.
///
/// * Lists the user's real garage (from `GarageStore`) plus a Guest option.
/// * Preselects the last vehicle used, but any can be picked.
/// * Opening it does nothing to location. Permission is requested, and
///   recording begins, only when the user taps Start recording.
/// * On success the recorder flips to `.recording` and the parent morphs this
///   panel into the live dashboard.
struct StartDrivePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let stage: Namespace.ID
    let onClose: () -> Void

    @State private var selection: DriveRecorder.Choice?
    @State private var failure: DriveRecorder.StartFailure?
    @State private var isStarting = false
    @State private var dragOffset: CGFloat = 0
    @State private var addingVehicle = false
    @State private var confirmTrigger = 0
    @AccessibilityFocusState private var titleFocused: Bool

    private var vehicles: [Vehicle] { app.garage.active }

    private var selectedVehicle: Vehicle? {
        guard case let .vehicle(id) = selection else { return nil }
        return app.garage.vehicle(id)
    }

    private var choices: [DriveRecorder.Choice] {
        vehicles.map { .vehicle($0.id) } + [.guest]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TickRule(ticks: 48, majorEvery: 8, height: 5)
                .padding(.horizontal, Space.gutter)
            content
        }
        .padding(.bottom, Space.l)
        .frame(maxWidth: 640)
        .background {
            ChamferedRectangle(cut: 18, corners: [.topLeading, .topTrailing])
                .fill(ClusterColor.plate)
                .overlay {
                    ChamferedRectangle(cut: 18, corners: [.topLeading, .topTrailing])
                        .strokeBorder(ClusterColor.ruleStrong, lineWidth: 1)
                }
                .stageGeometry("stage", in: stage, enabled: !reduceMotion)
                .ignoresSafeArea(edges: .bottom)
        }
        .offset(y: dragOffset)
        .simultaneousGesture(dismissDrag)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("start-drive-picker")
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.impact(weight: .heavy), trigger: confirmTrigger)
        .sensoryFeedback(trigger: failure) { _, new in new == nil ? nil : .error }
        .onAppear {
            if selection == nil { selection = app.recorder.preferredChoice(among: vehicles) }
            titleFocused = true
        }
        .onChange(of: vehicles.map(\.id)) { _, ids in
            // Keep the selection valid if the garage changes underneath.
            if case let .vehicle(id) = selection, !ids.contains(id) {
                selection = app.recorder.preferredChoice(among: vehicles)
            }
        }
        .sheet(isPresented: $addingVehicle) {
            VehicleEditorView(vehicle: nil) { saved in
                selection = .vehicle(saved.id)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Space.m) {
            Rectangle()
                .fill(ClusterColor.ruleStrong)
                .frame(width: 44, height: 4)
                .padding(.top, Space.s)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Legend("Start drive", color: theme.accentColor)
                    Text("What are you driving?")
                        .font(ClusterFont.title(.title2))
                        .tracking(Tracking.title)
                        .foregroundStyle(ClusterColor.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ClusterColor.inkSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("picker-close")
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.s)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !app.garage.isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 220)
                .accessibilityLabel("Loading your garage")
        } else if vehicles.isEmpty {
            emptyGarage
        } else if typeSize.isAccessibilitySize {
            // Large text: one scroll view for the list and the Start button,
            // so every vehicle can be reached instead of a squeezed inner list.
            ScrollView {
                choiceStack
            }
            .scrollIndicators(.visible)
        } else {
            choiceStack
        }
    }

    private var choiceStack: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if typeSize.isAccessibilitySize {
                accessibleList
            } else {
                carousel
            }
            selectionDetail
                .padding(.horizontal, Space.gutter)
            footer
                .padding(.horizontal, Space.gutter)
        }
        .padding(.top, Space.l)
    }

    private var cardWidth: CGFloat { verticalSizeClass == .compact ? 180 : 212 }

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Space.m) {
                    ForEach(choices, id: \.self) { choice in
                        let vehicle = vehicle(for: choice)
                        VehicleChoiceCard(vehicle: vehicle, isSelected: choice == selection, width: cardWidth) {
                            select(choice)
                            withAnimation(Motion.resolved(Motion.select, reduceMotion: reduceMotion)) {
                                proxy.scrollTo(choice, anchor: .center)
                            }
                        }
                        .id(choice)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, Space.s)
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, Space.gutter, for: .scrollContent)
            // A horizontal scroll view otherwise takes all the height offered,
            // leaving dead space above and below the cards.
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .accessibilityIdentifier("vehicle-carousel")
    }

    /// Vertical list used at accessibility text sizes, where cards would
    /// truncate.
    private var accessibleList: some View {
        VStack(spacing: Space.s) {
            ForEach(choices, id: \.self) { choice in
                let vehicle = vehicle(for: choice)
                VehicleChoiceRow(vehicle: vehicle, isSelected: choice == selection) { select(choice) }
            }
        }
        .padding(.horizontal, Space.gutter)
    }

    private func vehicle(for choice: DriveRecorder.Choice) -> Vehicle? {
        if case let .vehicle(id) = choice { return app.garage.vehicle(id) }
        return nil
    }

    private func select(_ choice: DriveRecorder.Choice) {
        failure = nil
        withAnimation(Motion.resolved(Motion.select, reduceMotion: reduceMotion)) { selection = choice }
    }

    private var selectionDetail: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Rectangle()
                .fill(selectedVehicle.map { ClusterColor.accent($0.identityColor) } ?? ClusterColor.ruleStrong)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Legend(selectedVehicle == nil ? "Guest drive" : "Logging to")
                Text(selectedVehicle?.displayName ?? "No garage vehicle")
                    .font(ClusterFont.headline())
                    .foregroundStyle(ClusterColor.ink)
                    .contentTransition(.opacity)
                Text(selectedVehicle == nil
                     ? "Stats count toward your totals but aren't attached to a car, so they don't appear in a vehicle's history."
                     : "Distance, speeds and the route are added to this vehicle's history.")
                    .font(ClusterFont.body(.footnote))
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("picker-selection-detail")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let failure {
                VStack(alignment: .leading, spacing: Space.s) {
                    NoticeStrip(failure.message, tone: .caution)
                    if failure.canOpenSettings {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .font(ClusterFont.headline(.subheadline))
                    }
                }
                .accessibilityElement(children: .contain)
            }
            Button(action: confirm) {
                HStack(spacing: Space.s) {
                    if isStarting {
                        ProgressView().tint(ClusterColor.onAccent)
                    } else {
                        Image(systemName: "record.circle")
                    }
                    Text(isStarting ? "Starting" : "Start recording")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.cluster)
            .disabled(isStarting || selection == nil)
            .accessibilityIdentifier("picker-confirm")
            .accessibilityHint("Starts recording location for this drive.")

            Label("Location is only used while a drive is recording.", systemImage: "location")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkTertiary)
        }
    }

    private var emptyGarage: some View {
        VStack(spacing: Space.l) {
            HStack(spacing: Space.l) {
                ForEach([BodyStyle.sedan, .sport, .suv], id: \.self) { style in
                    VehicleSilhouette(style, color: ClusterColor.inkTertiary, lineWidth: 1.2)
                        .frame(width: 86, height: 36)
                }
            }
            .padding(.top, Space.xl)
            .accessibilityHidden(true)
            VStack(spacing: Space.xs) {
                Text("Your garage is empty")
                    .font(ClusterFont.title(.title3))
                    .foregroundStyle(ClusterColor.ink)
                Text("Add a car or motorcycle to log drives against it, or go now as a guest.")
                    .font(ClusterFont.body(.subheadline))
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: Space.s) {
                Button {
                    addingVehicle = true
                } label: {
                    Label("Add a vehicle", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.cluster)
                .accessibilityIdentifier("picker-add-vehicle")
                Button {
                    selection = .guest
                    confirm()
                } label: {
                    Text("Start as guest").frame(maxWidth: .infinity)
                }
                .buttonStyle(.clusterSecondary)
                .disabled(isStarting)
                .accessibilityIdentifier("picker-start-guest")
            }
            if let failure { NoticeStrip(failure.message, tone: .caution) }
        }
        .padding(.horizontal, Space.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("picker-empty")
    }

    // MARK: Actions

    private func confirm() {
        guard !isStarting, selection != nil else { return }
        let vehicle = selectedVehicle
        isStarting = true
        failure = nil
        Task {
            let result = await app.recorder.start(with: vehicle)
            isStarting = false
            if let result {
                failure = result
            } else {
                confirmTrigger += 1
            }
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0, value.translation.height > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let shouldClose = dragOffset > 120 || value.predictedEndTranslation.height > 260
                withAnimation(Motion.resolved(Motion.sheet, reduceMotion: reduceMotion) ?? .easeOut(duration: 0.15)) {
                    dragOffset = 0
                }
                if shouldClose, !isStarting { onClose() }
            }
    }
}

/// One vehicle in the carousel: photo-led plate with a stamped spec line.
struct VehicleChoiceCard: View {
    @Environment(\.clusterTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let vehicle: Vehicle?
    let isSelected: Bool
    let width: CGFloat
    let action: () -> Void

    private var identity: Color {
        vehicle.map { ClusterColor.accent($0.identityColor) } ?? ClusterColor.inkTertiary
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                VehicleArtwork(vehicle: vehicle)
                    .frame(width: width, height: width * 0.6)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            SelectedStamp()
                                .padding(Space.s)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                Rectangle().fill(identity).frame(height: 3)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Legend(specLine)
                    Text(vehicle.map { "\($0.make) \($0.model)" } ?? "Guest vehicle")
                        .font(ClusterFont.headline())
                        .foregroundStyle(ClusterColor.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(ClusterFont.body(.footnote))
                        .foregroundStyle(ClusterColor.inkSecondary)
                        .lineLimit(1)
                }
                .padding(Space.m)
                .frame(width: width, alignment: .leading)
            }
            .background(ClusterColor.plateRaised)
            .clipShape(ChamferedRectangle(cut: Radius.chamfer))
            .overlay {
                ChamferedRectangle(cut: Radius.chamfer)
                    .strokeBorder(isSelected ? theme.accentColor : ClusterColor.rule, lineWidth: isSelected ? 2.5 : 1)
            }
            .scaleEffect(isSelected || reduceMotion ? 1 : 0.95)
            .opacity(isSelected ? 1 : 0.82)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(vehicle == nil ? "Records without attaching the drive to a vehicle." : "Logs this drive to this vehicle.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(vehicle.map { "vehicle-choice-\($0.model)" } ?? "vehicle-choice-guest")
    }

    private var specLine: String {
        guard let vehicle else { return "No garage car" }
        return "\(vehicle.year) · \(vehicle.bodyStyle.label)"
    }

    private var subtitle: String {
        guard let vehicle else { return "Not linked to a vehicle" }
        if !vehicle.nickname.isEmpty { return "“\(vehicle.nickname)”" }
        return vehicle.trim.isEmpty ? vehicle.kind.label : vehicle.trim
    }

    private var accessibilityText: String {
        guard let vehicle else { return "Guest vehicle" }
        return [vehicle.title, vehicle.nickname.isEmpty ? nil : vehicle.nickname, vehicle.kind.label, vehicle.bodyStyle.label]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// List row used for accessibility text sizes.
struct VehicleChoiceRow: View {
    @Environment(\.clusterTheme) private var theme
    let vehicle: Vehicle?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(vehicle?.displayName ?? "Guest vehicle")
                        .font(ClusterFont.headline())
                        .foregroundStyle(ClusterColor.ink)
                    Text(verbatim: vehicle.map { $0.nickname.isEmpty ? "\($0.kind.label) · \($0.bodyStyle.label)" : $0.title } ?? "Not linked to a vehicle")
                        .font(ClusterFont.body(.footnote))
                        .foregroundStyle(ClusterColor.inkSecondary)
                }
                Spacer(minLength: Space.s)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? theme.accentColor : ClusterColor.inkTertiary)
                    .font(.title2)
            }
            .padding(Space.m)
            .plate(raised: isSelected, stroke: isSelected ? theme.accentColor : nil)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(vehicle.map { "vehicle-choice-\($0.model)" } ?? "vehicle-choice-guest")
    }
}

/// Checkmark stamp shown on the selected card.
struct SelectedStamp: View {
    @Environment(\.clusterTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
            Text("Selected").font(ClusterFont.legend(.caption2)).textCase(.uppercase).tracking(1)
        }
        .foregroundStyle(ClusterColor.accentPrefersDarkText(theme.accent) ? ClusterColor.onAccent : .white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(ChamferedRectangle(cut: 4).fill(theme.accentColor))
        .accessibilityHidden(true)
    }
}

extension View {
    /// `matchedGeometryEffect` that can be switched off (Reduce Motion).
    @ViewBuilder
    func stageGeometry(_ id: String, in namespace: Namespace.ID, enabled: Bool, isSource: Bool = true) -> some View {
        if enabled {
            matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }
}
