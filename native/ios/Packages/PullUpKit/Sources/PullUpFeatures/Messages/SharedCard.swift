import SwiftUI
import PullUpData
import PullUpDesign
import PullUpDomain

/// A vehicle, post, meet or drive inside a message. The preview is fetched
/// for the reader, so something they can't see shows as unavailable even if
/// the sender could see it. Drives show totals only, never a route.
struct SharedCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.clusterTheme) private var theme
    let ref: SharedRef
    @State private var preview: SharedPreview?
    @State private var failed = false

    var body: some View {
        HStack(spacing: Space.m) {
            artwork
                .frame(width: 64, height: 48)
                .clipShape(ChamferedRectangle(cut: 4))
            VStack(alignment: .leading, spacing: 2) {
                Legend(ref.kind.label)
                if let preview, preview.available {
                    Text(preview.title ?? "")
                        .font(ClusterFont.headline(.subheadline))
                        .foregroundStyle(ClusterColor.ink)
                        .lineLimit(2)
                    if let detail = detail(preview) {
                        Text(detail)
                            .font(ClusterFont.body(.caption))
                            .foregroundStyle(ClusterColor.inkSecondary)
                            .lineLimit(2)
                    }
                } else if preview != nil || failed {
                    Text(failed ? "Couldn't load this." : "No longer available")
                        .font(ClusterFont.body(.footnote))
                        .foregroundStyle(ClusterColor.inkSecondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s)
        .background(ClusterColor.plate, in: ChamferedRectangle(cut: 6))
        .overlay(ChamferedRectangle(cut: 6).stroke(ClusterColor.rule))
        .accessibilityElement(children: .combine)
        .task(id: ref) {
            do {
                preview = try await app.backend.sharedPreview(ref)
                failed = false
            } catch {
                failed = true
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let preview, preview.available {
            switch preview.kind {
            case .vehicle:
                StorageImage(bucket: .vehicleMedia, path: preview.imagePath) {
                    VehiclePlaceholder(style: preview.bodyStyle ?? .coupe, identity: preview.identityColor ?? theme.accent)
                }
            case .post:
                StorageImage(bucket: .postMedia, path: preview.imagePath) { symbol("text.quote") }
            case .meet:
                symbol(preview.cancelled == true ? "calendar.badge.exclamationmark" : "calendar")
            case .drive:
                symbol("gauge.with.needle")
            }
        } else {
            symbol("lock")
        }
    }

    private func symbol(_ name: String) -> some View {
        ZStack {
            ClusterColor.plateRaised
            Image(systemName: name).foregroundStyle(ClusterColor.inkSecondary)
        }
        .accessibilityHidden(true)
    }

    private func detail(_ preview: SharedPreview) -> String? {
        switch preview.kind {
        case .vehicle:
            return [preview.subtitle, preview.ownerUsername.map { "@\($0)" }].compactMap { $0 }.joined(separator: " · ")
        case .post:
            return preview.subtitle
        case .meet:
            if preview.cancelled == true { return "Cancelled" }
            let when = preview.startsAt?.formatted(date: .abbreviated, time: .shortened)
            return [when, preview.subtitle].compactMap { $0 }.joined(separator: " · ")
        case .drive:
            var parts: [String] = []
            if let meters = preview.distanceMeters { parts.append("\(Format.distance(meters, theme.unit)) \(theme.unit.distanceLabel)") }
            if let seconds = preview.movingSeconds { parts.append(Format.duration(seconds)) }
            if let vehicle = preview.vehicleTitle { parts.append(vehicle) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

/// Report a person, or one of their messages. The server keeps the report
/// with a copy of the reported message for review; the person isn't told who
/// reported.
struct ReportView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: ThreadModel
    let message: DirectMessage?

    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var alsoBlock = false
    @State private var busy = false
    @State private var sent = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if sent {
                        EmptyState(
                            title: "Thanks for reporting",
                            message: "Your report is saved with a copy of what you reported, for Pull Up to review. @\(model.peer.username) isn't told who reported them."
                        )
                    } else {
                        Text(message == nil ? "What's wrong with @\(model.peer.username)'s messages?" : "What's wrong with this message?")
                            .font(ClusterFont.headline())
                            .foregroundStyle(ClusterColor.ink)
                        VStack(spacing: 0) {
                            ForEach(ReportReason.allCases) { option in
                                Button {
                                    reason = option
                                } label: {
                                    HStack {
                                        Text(option.label).font(ClusterFont.body()).foregroundStyle(ClusterColor.ink)
                                        Spacer()
                                        if reason == option { Image(systemName: "checkmark").foregroundStyle(ClusterColor.verified) }
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(reason == option ? .isSelected : [])
                                Hairline()
                            }
                        }
                        FieldRow(label: "Anything else (optional)", text: $details, axis: .vertical)
                        PrivacyToggle(title: "Also block @\(model.peer.username)", detail: "They won't be able to message you or see your profile.", isOn: $alsoBlock)
                        if let error { ErrorLine(message: error) }
                        Button {
                            Task { await submit() }
                        } label: {
                            Text(busy ? "Sending" : "Send report").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.cluster)
                        .disabled(reason == nil || busy)
                        .accessibilityIdentifier("send-report")
                    }
                }
                .padding(Space.gutter)
            }
            .canvasBackground()
            .clusterNavigation("Report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sent ? "Done" : "Cancel") { dismiss() } }
            }
        }
    }

    private func submit() async {
        guard let reason else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.report(reason, details: String(details.prefix(1000)), message: message)
            if alsoBlock {
                try await model.block()
                app.noteBlocked(model.peer.id)
            }
            sent = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
