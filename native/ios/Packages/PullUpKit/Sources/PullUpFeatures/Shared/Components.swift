import SwiftUI
import UIKit
import PullUpDesign
import PullUpDomain

/// Permanent label shown while the app runs on the demo backend.
struct DemoStrip: View {
    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "flask").foregroundStyle(ClusterColor.estimate)
            Text("Demo data · not real, not saved")
        }
        .font(ClusterFont.legend(.caption))
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .foregroundStyle(ClusterColor.ink)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity)
        // Stays below the status bar so the clock keeps canvas contrast in both modes.
        .background(ClusterColor.estimate.opacity(0.16), ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo data. Nothing here is real or saved to a server.")
        .accessibilityIdentifier("demo-strip")
    }
}

/// Shown above every tab while a moderator has suspended the account.
struct SuspendedStrip: View {
    let suspension: Suspension

    var body: some View {
        NoticeStrip("\(suspension.title). \(suspension.message)", tone: .caution)
            .padding(.horizontal, Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClusterColor.canvas)
            .accessibilityIdentifier("suspended-strip")
    }
}

/// Inline error with optional retry.
struct ErrorLine: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(ClusterColor.caution)
            Text(message)
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let retry {
                Button("Retry", action: retry).font(ClusterFont.headline(.footnote))
            }
        }
        .padding(Space.m)
        .plate()
    }
}

/// Empty or not-yet-loaded state with a silhouette illustration.
struct EmptyState<Actions: View>: View {
    let title: String
    let message: String
    var style: BodyStyle = .coupe
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: Space.l) {
            VehicleSilhouette(style, color: ClusterColor.inkTertiary, lineWidth: 1.4)
                .frame(width: 140, height: 56)
                .accessibilityHidden(true)
            VStack(spacing: Space.s) {
                Text(title)
                    .font(ClusterFont.title(.title3))
                    .foregroundStyle(ClusterColor.ink)
                Text(message)
                    .font(ClusterFont.body(.subheadline))
                    .foregroundStyle(ClusterColor.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            actions()
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(title: String, message: String, style: BodyStyle = .coupe) {
        self.init(title: title, message: message, style: style) { EmptyView() }
    }
}

/// Canvas background for every screen.
struct CanvasBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ClusterColor.canvas.ignoresSafeArea())
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func canvasBackground() -> some View { modifier(CanvasBackground()) }

    /// A pushed or sheet screen's title: inline, on the system bar (Liquid
    /// Glass on iOS 26, the standard bar before it).
    func clusterNavigation(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    /// A tab's root screen: large title that collapses as the content scrolls.
    func rootNavigation(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
    }

    /// Sheets keep the canvas (OLED black in dark mode) instead of the
    /// system's elevated grey.
    func sheetCanvas() -> some View {
        presentationBackground(ClusterColor.canvas)
    }
}

/// Audience picker that explains each choice, used for vehicles, drives,
/// posts and meets.
struct AudiencePicker: View {
    let title: String
    @Binding var selection: Audience
    var allowed: [Audience] = Audience.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend(title)
            Picker(title, selection: $selection) {
                ForEach(allowed, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(selection.explanation)
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Labelled text field drawn as an instrument legend over a hairline.
struct FieldRow: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var keyboard: UIKeyboardType = .default
    var axis: Axis = .horizontal

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend(label)
            TextField(prompt, text: $text, axis: axis)
                .font(ClusterFont.body())
                .keyboardType(keyboard)
                .foregroundStyle(ClusterColor.ink)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.m)
                .frame(minHeight: Space.target)
                .background(ClusterColor.plate, in: ChamferedRectangle(cut: Radius.chamferSmall))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row in a settings-style list: legend, value, chevron.
struct SpecRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Legend(label)
            Spacer()
            Text(value)
                .font(ClusterFont.readout(.body))
                .foregroundStyle(ClusterColor.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, Space.s)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }
}

/// Swatches for choosing an accent or vehicle identity colour. Vehicles and
/// profiles use the standard set; the app accent adds the Pro colours, which
/// call `onLocked` instead of selecting while Pro is off.
struct AccentSwatches: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: AccentChoice
    var choices: [AccentChoice] = AccentChoice.standard
    var locked: (AccentChoice) -> Bool = { _ in false }
    var onLocked: () -> Void = {}

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 46, maximum: 46), spacing: Space.m)], alignment: .leading, spacing: Space.m) {
            ForEach(choices) { choice in
                let selected = choice == selection
                let isLocked = locked(choice)
                Button {
                    if isLocked {
                        onLocked()
                    } else {
                        withAnimation(Motion.resolved(Motion.select, reduceMotion: reduceMotion)) { selection = choice }
                    }
                } label: {
                    Circle()
                        .fill(ClusterColor.accentFill(choice))
                        .frame(width: 34, height: 34)
                        .overlay {
                            if selected {
                                Circle().inset(by: -5).stroke(ClusterColor.accent(choice), lineWidth: 2)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundStyle(ClusterColor.textOnAccent(choice))
                            } else if isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(ClusterColor.textOnAccent(choice))
                            }
                        }
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLocked ? "\(choice.label), Pull Up Pro" : choice.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("accent-\(choice.rawValue)")
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Label for a `PhotosPicker`. The picker builds its label in a nonisolated
/// context, so this view takes plain values through a nonisolated init and
/// applies the main-actor styling inside `body`.
struct MediaPickerLabel: View {
    let isLoading: Bool
    let symbol: String
    let title: String
    let width: CGFloat
    let height: CGFloat
    let cut: CGFloat

    nonisolated init(isLoading: Bool, symbol: String, title: String, width: CGFloat, height: CGFloat, cut: CGFloat) {
        self.isLoading = isLoading
        self.symbol = symbol
        self.title = title
        self.width = width
        self.height = height
        self.cut = cut
    }

    var body: some View {
        VStack(spacing: Space.xs) {
            if isLoading { ProgressView() } else { Image(systemName: symbol).font(.title2) }
            Legend(title)
        }
        .padding(.horizontal, Space.xs)
        .frame(width: width, height: height)
        .plate(cut: cut)
    }
}
