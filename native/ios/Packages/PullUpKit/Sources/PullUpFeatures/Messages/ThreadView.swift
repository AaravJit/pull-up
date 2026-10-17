import PhotosUI
import SwiftUI
import UIKit
import PullUpData
import PullUpDesign
import PullUpDomain

/// One conversation. Messages arrive live; the composer sends text, a photo
/// (re-encoded on the device, so no location or camera data), or a shared
/// vehicle, post, meet or drive.
struct ThreadView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.clusterTheme) private var theme
    let target: ConversationTarget
    /// Shown as a sheet (from a profile or vehicle) rather than pushed.
    var showsDone = false

    @State private var model: ThreadModel?
    @State private var draft = ""
    @State private var attachment: SharedRef?
    @State private var photo: OutgoingMessage.Photo?
    @State private var photoItem: PhotosPickerItem?
    @State private var preparingPhoto = false
    @State private var reporting: ReportSubject?
    @State private var confirmBlock = false
    @State private var confirmDelete = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .canvasBackground()
        .clusterNavigation("@\(target.peer.username)")
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            ToolbarItem(placement: .primaryAction) { menu }
        }
        .task {
            if model == nil, let me = app.userID {
                model = ThreadModel(backend: app.backend, me: me, target: target)
                attachment = target.attach
            }
            await model?.load()
            await app.refreshMessages()
        }
        .onChange(of: app.messagingPulse) { _, pulse in
            guard let model, pulse.conversationID == nil || pulse.conversationID == model.conversationID else { return }
            Task { await model.refresh() }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await preparePhoto(item) }
        }
        .sheet(item: $reporting) { subject in
            if let model { ReportView(model: model, message: subject.message) }
        }
        .confirmationDialog("Block @\(target.peer.username)?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await block() } }
        } message: {
            Text("They can't message you, and you won't see each other's profiles or posts. Pull Up doesn't tell them.")
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete for me", role: .destructive) { Task { await deleteConversation() } }
        } message: {
            Text("Your copy is deleted. @\(target.peer.username) keeps theirs.")
        }
        .accessibilityIdentifier("thread")
    }

    private var menu: some View {
        Menu {
            if let model, model.state == .active {
                Button { Task { await model.toggleMuted() } } label: {
                    Label(model.muted ? "Unmute" : "Mute", systemImage: model.muted ? "bell" : "bell.slash")
                }
            }
            Button { reporting = ReportSubject(message: nil) } label: { Label("Report @\(target.peer.username)", systemImage: "flag") }
            Button(role: .destructive) { confirmBlock = true } label: { Label("Block", systemImage: "hand.raised") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete conversation", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Conversation options")
        .accessibilityIdentifier("thread-options")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ model: ThreadModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xs) {
                header(model)
                if model.hasEarlier {
                    Button {
                        Task { await model.loadEarlier() }
                    } label: {
                        if model.loadingEarlier { ProgressView() } else { Legend("Load earlier messages") }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                    if index == 0 || !Calendar.current.isDate(model.messages[index - 1].createdAt, inSameDayAs: message.createdAt) {
                        DaySeparator(date: message.createdAt)
                    }
                    MessageRow(
                        message: message, isMine: message.senderID == model.me, me: model.me,
                        groupedWithPrevious: index > 0 && model.messages[index - 1].senderID == message.senderID
                            && message.createdAt.timeIntervalSince(model.messages[index - 1].createdAt) < 300,
                        onReact: { emoji in Task { await model.react(emoji, to: message) } },
                        onUnsend: { Task { await model.unsend(message) } },
                        onReport: { reporting = ReportSubject(message: message) }
                    )
                    .id(message.id)
                    if let status = model.latestDelivery, status.id == message.id {
                        DeliveryLine(delivery: status.delivery)
                    }
                }
                ForEach(model.pending) { item in
                    PendingRow(item: item)
                    if model.latestDelivery?.id == item.id {
                        DeliveryLine(delivery: item.failure.map(ThreadModel.Delivery.failed) ?? .sending) {
                            Task { await model.retry(item.id) }
                        } discard: {
                            model.discard(item.id)
                        }
                    }
                }
                if let error = model.error {
                    ErrorLine(message: error).padding(.top, Space.s)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.m)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.state == .request {
                RequestBar(username: target.peer.username) {
                    Task { await model.accept() }
                } delete: {
                    Task { await declineRequest(model) }
                } block: {
                    confirmBlock = true
                }
            } else if model.state == .declined {
                NoticeStrip("You deleted this request.").padding(Space.gutter)
            } else {
                composer(model)
            }
        }
    }

    private func header(_ model: ThreadModel) -> some View {
        VStack(spacing: Space.s) {
            Avatar(name: target.peer.displayName.isEmpty ? target.peer.username : target.peer.displayName, path: target.peer.avatarPath, size: 64)
            Text(target.peer.displayName.isEmpty ? "@\(target.peer.username)" : target.peer.displayName)
                .font(ClusterFont.headline())
                .foregroundStyle(ClusterColor.ink)
            Text("@\(target.peer.username)")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkSecondary)
            if app.isDemo {
                NoticeStrip("Demo conversation. Replies here are simulated on this device.", tone: .estimate)
            }
            Text("Messages aren't end-to-end encrypted. Pull Up reviews a message only when someone reports it. Locations and routes are never shared here.")
                .font(ClusterFont.body(.caption2))
                .foregroundStyle(ClusterColor.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.l)
    }

    // MARK: Composer

    private func composer(_ model: ThreadModel) -> some View {
        let canSend = MessageRules.canSend(body: draft, hasAttachment: photo != nil || attachment != nil) && !preparingPhoto
        return VStack(alignment: .leading, spacing: Space.s) {
            if let attachment {
                HStack(alignment: .top, spacing: Space.s) {
                    SharedCard(ref: attachment).frame(maxWidth: 260)
                    removeButton("Remove attachment") { self.attachment = nil }
                }
            }
            if let photo, let image = UIImage(data: photo.jpegData) {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(ChamferedRectangle(cut: 6))
                        .accessibilityLabel("Photo to send")
                    removeButton("Remove photo") { self.photo = nil }
                }
            }
            HStack(alignment: .bottom, spacing: Space.s) {
                // The picker builds its label off the main actor; pass plain values.
                let pickerSymbol = preparingPhoto ? "hourglass" : "photo"
                PhotosPicker(selection: $photoItem, matching: .images) {
                    ComposerIcon(symbol: pickerSymbol)
                }
                .disabled(preparingPhoto)
                .accessibilityLabel("Add photo")
                .accessibilityIdentifier("composer-photo")
                TextField("Message", text: $draft, axis: .vertical)
                    .font(ClusterFont.body())
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .background(ClusterColor.plateRaised, in: ChamferedRectangle(cut: 6))
                    .accessibilityIdentifier("composer-field")
                Button {
                    let text = draft
                    let sentPhoto = photo
                    let shared = attachment
                    draft = ""
                    photo = nil
                    attachment = nil
                    Task { await model.send(text: text, photo: sentPhoto, shared: shared) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(canSend ? (ClusterColor.accentPrefersDarkText(theme.accent) ? ClusterColor.onAccent : .white) : ClusterColor.inkTertiary)
                        .frame(width: 40, height: 40)
                        .background(canSend ? theme.accentColor : ClusterColor.plateRaised, in: ChamferedRectangle(cut: 6))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("composer-send")
            }
            if let remaining = MessageRules.remaining(draft) {
                Text(remaining >= 0 ? "\(remaining) characters left" : "\(-remaining) characters over the limit")
                    .font(ClusterFont.body(.caption2))
                    .foregroundStyle(remaining >= 0 ? ClusterColor.inkTertiary : ClusterColor.caution)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.s)
        .background(ClusterColor.plate)
        .overlay(alignment: .top) { Hairline() }
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(ClusterColor.inkTertiary)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label)
    }

    private func preparePhoto(_ item: PhotosPickerItem) async {
        preparingPhoto = true
        defer {
            preparingPhoto = false
            photoItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = ImageProcessing.uploadJPEG(from: data),
              let image = UIImage(data: jpeg) else {
            model?.error = "That photo couldn't be read."
            return
        }
        photo = OutgoingMessage.Photo(jpegData: jpeg, width: Int(image.size.width), height: Int(image.size.height))
    }

    // MARK: Actions

    private func declineRequest(_ model: ThreadModel) async {
        do {
            try await model.decline()
            try await model.hide(clearHistory: true)
            await app.refreshMessages()
            dismiss()
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func block() async {
        guard let model else { return }
        do {
            try await model.block()
            await app.refreshMessages()
            dismiss()
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func deleteConversation() async {
        guard let model else { return }
        do {
            try await model.hide(clearHistory: true)
            await app.refreshMessages()
            dismiss()
        } catch {
            model.error = error.localizedDescription
        }
    }
}

struct ReportSubject: Identifiable {
    let id = UUID()
    let message: DirectMessage?
}

private struct ComposerIcon: View {
    let symbol: String

    nonisolated init(symbol: String) {
        self.symbol = symbol
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(ClusterColor.ink)
            .frame(width: 40, height: 40)
    }
}

private struct DaySeparator: View {
    let date: Date

    var body: some View {
        Legend(Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.m)
    }
}

/// One message: a chamfered plate, accent-filled for your own.
struct MessageRow: View {
    @Environment(\.clusterTheme) private var theme
    let message: DirectMessage
    let isMine: Bool
    let me: UserID
    var groupedWithPrevious = false
    var onReact: (String) -> Void = { _ in }
    var onUnsend: () -> Void = {}
    var onReport: () -> Void = {}

    private var ink: Color {
        isMine ? (ClusterColor.accentPrefersDarkText(theme.accent) ? ClusterColor.onAccent : .white) : ClusterColor.ink
    }

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 56) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: Space.xxs) {
                if message.isUnsent {
                    Text(isMine ? "You unsent a message" : "Message unsent")
                        .font(ClusterFont.body(.footnote).italic())
                        .foregroundStyle(ClusterColor.inkTertiary)
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s)
                        .overlay(ChamferedRectangle(cut: 8).stroke(ClusterColor.rule))
                } else {
                    bubble
                        .contextMenu { menu }
                }
                if !message.reactionCounts.isEmpty {
                    HStack(spacing: Space.xxs) {
                        ForEach(message.reactionCounts) { reaction in
                            Button { onReact(reaction.emoji) } label: {
                                Text(verbatim: reaction.count > 1 ? "\(reaction.emoji) \(reaction.count)" : reaction.emoji)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        message.reaction(by: me) == reaction.emoji ? theme.accentColor.opacity(0.25) : ClusterColor.plateRaised,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(reaction.emoji), \(reaction.count)")
                        }
                    }
                }
            }
            if !isMine { Spacer(minLength: 56) }
        }
        .padding(.top, groupedWithPrevious ? 0 : Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let path = message.mediaPath {
                StorageImage(bucket: .dmMedia, path: path) { ClusterColor.plateRaised }
                    .aspectRatio(min(1.6, max(0.6, message.aspectRatio)), contentMode: .fit)
                    .frame(maxWidth: 240)
                    .clipShape(ChamferedRectangle(cut: 6))
                    .accessibilityLabel("Photo")
            }
            if let shared = message.shared {
                SharedCard(ref: shared).frame(maxWidth: 240)
            }
            if !MessageRules.trimmed(message.body).isEmpty {
                Text(message.body)
                    .font(ClusterFont.body())
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(isMine ? theme.accentColor : ClusterColor.plateRaised, in: ChamferedRectangle(cut: 8, corners: corners))
    }

    /// The corner nearest the sender stays square, like a speech tail.
    private var corners: ChamferedRectangle.Corners {
        isMine ? [.topLeading, .bottomLeading, .topTrailing] : [.topLeading, .topTrailing, .bottomTrailing]
    }

    @ViewBuilder
    private var menu: some View {
        ControlGroup {
            ForEach(MessageRules.reactions.prefix(4), id: \.self) { emoji in
                Button(emoji) { onReact(emoji) }
            }
        }
        Menu("More reactions") {
            ForEach(MessageRules.reactions.dropFirst(4), id: \.self) { emoji in
                Button(emoji) { onReact(emoji) }
            }
        }
        if !message.body.isEmpty {
            Button { UIPasteboard.general.string = message.body } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        if isMine {
            Button(role: .destructive, action: onUnsend) { Label("Unsend", systemImage: "arrow.uturn.backward") }
        } else {
            Button(role: .destructive, action: onReport) { Label("Report message", systemImage: "flag") }
        }
    }

    private var accessibilityText: String {
        var parts: [String] = [isMine ? "You" : "Them"]
        if message.isUnsent {
            parts.append("unsent a message")
        } else {
            if message.mediaPath != nil { parts.append("photo") }
            if let shared = message.shared { parts.append("shared a \(shared.kind.label.lowercased())") }
            if !message.body.isEmpty { parts.append(message.body) }
        }
        parts.append(message.createdAt.formatted(date: .omitted, time: .shortened))
        if !message.reactions.isEmpty { parts.append("reactions: " + message.reactions.map(\.emoji).joined(separator: " ")) }
        return parts.joined(separator: ", ")
    }
}

/// A message the server hasn't confirmed yet.
private struct PendingRow: View {
    @Environment(\.clusterTheme) private var theme
    let item: ThreadModel.Pending

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .leading, spacing: Space.s) {
                if let photo = item.outgoing.photo, let image = UIImage(data: photo.jpegData) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 240)
                        .clipShape(ChamferedRectangle(cut: 6))
                }
                if let shared = item.outgoing.shared {
                    SharedCard(ref: shared).frame(maxWidth: 240)
                }
                if !item.outgoing.body.isEmpty {
                    Text(item.outgoing.body)
                        .font(ClusterFont.body())
                        .foregroundStyle(ClusterColor.accentPrefersDarkText(theme.accent) ? ClusterColor.onAccent : .white)
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(theme.accentColor.opacity(item.failure == nil ? 0.6 : 0.35), in: ChamferedRectangle(cut: 8))
        }
        .padding(.top, Space.s)
        .accessibilityElement(children: .combine)
    }
}

private struct DeliveryLine: View {
    let delivery: ThreadModel.Delivery
    var retry: (() -> Void)?
    var discard: (() -> Void)?

    init(delivery: ThreadModel.Delivery, retry: (() -> Void)? = nil, discard: (() -> Void)? = nil) {
        self.delivery = delivery
        self.retry = retry
        self.discard = discard
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Spacer()
            if case .failed = delivery {
                Image(systemName: "exclamationmark.circle").foregroundStyle(ClusterColor.caution)
            }
            Text(delivery.label)
                .font(ClusterFont.body(.caption2))
                .foregroundStyle(ClusterColor.inkTertiary)
                .multilineTextAlignment(.trailing)
            if case .failed = delivery {
                if let retry { Button("Retry", action: retry).font(ClusterFont.headline(.caption)) }
                if let discard { Button("Delete", role: .destructive, action: discard).font(ClusterFont.headline(.caption)) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("delivery-status")
    }
}

/// Shown instead of the composer while a conversation is a request.
private struct RequestBar: View {
    let username: String
    let accept: () -> Void
    let delete: () -> Void
    let block: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("@\(username) wants to message you. Accept to reply. They won't know you've seen this unless you accept.")
                .font(ClusterFont.body(.footnote))
                .foregroundStyle(ClusterColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                Button("Block", action: block).buttonStyle(.clusterSecondary)
                Button("Delete", action: delete).buttonStyle(.clusterSecondary)
                Button(action: accept) { Text("Accept").frame(maxWidth: .infinity) }
                    .buttonStyle(.cluster)
                    .accessibilityIdentifier("accept-request")
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.m)
        .background(ClusterColor.plate)
        .overlay(alignment: .top) { Hairline() }
    }
}
