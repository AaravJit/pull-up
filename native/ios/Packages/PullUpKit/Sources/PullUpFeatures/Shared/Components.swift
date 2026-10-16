import SwiftUI
import UIKit
import PullUpDesign
import PullUpDomain

/// Permanent label shown while the app runs on the demo backend.
struct DemoStrip: View {
    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "flask")
            Text("Demo data · nothing here is real or saved to a server")
        }
        .font(ClusterFont.legend(.caption2))
        .textCase(.uppercase)
        .tracking(0.8)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(ClusterColor.onAccent)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity)
        .background(ClusterColor.estimate)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo data. Nothing here is real or saved to a server.")
        .accessibilityIdentifier("demo-strip")
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
                .frame(width: 160, height: 64)
            VStack(spacing: Space.xs) {
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

    /// Standard navigation title styling for Cluster screens.
    func clusterNavigation(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ClusterColor.canvas, for: .navigationBar)
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
            SwitchBank(allowed, selection: $selection) { $0.label }
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
        VStack(alignment: .leading, spacing: Space.xs) {
            Legend(label)
            TextField(prompt, text: $text, axis: axis)
                .font(ClusterFont.body())
                .keyboardType(keyboard)
                .foregroundStyle(ClusterColor.ink)
                .padding(.vertical, Space.xs)
            Hairline(color: ClusterColor.ruleStrong)
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

/// Swatch row for choosing an accent or vehicle identity colour.
struct AccentSwatches: View {
    @Binding var selection: AccentChoice

    var body: some View {
        HStack(spacing: Space.m) {
            ForEach(AccentChoice.allCases) { choice in
                let selected = choice == selection
                Button {
                    withAnimation(Motion.select) { selection = choice }
                } label: {
                    ChamferedRectangle(cut: 7)
                        .fill(ClusterColor.accent(choice))
                        .frame(width: 38, height: 38)
                        .overlay {
                            if selected {
                                ChamferedRectangle(cut: 9).inset(by: -4).stroke(ClusterColor.ink, lineWidth: 1.5)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundStyle(ClusterColor.accentPrefersDarkText(choice) ? ClusterColor.onAccent : .white)
                            }
                        }
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
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
        .frame(width: width, height: height)
        .plate(cut: cut)
    }
}
