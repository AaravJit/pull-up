import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PullUpData
import PullUpDesign
import PullUpDomain

/// What the composer remembers between posts on this phone: the unsent
/// caption, the audience last chosen and the vehicle last tagged. Nothing
/// here is ever applied without being shown on screen first.
struct ComposerMemory {
    let defaults: UserDefaults
    let owner: UserID?

    private func key(_ name: String) -> String { "pullup.composer.\(name).\(owner?.uuidString ?? "anon")" }

    var draft: String {
        get { defaults.string(forKey: key("draft")) ?? "" }
        nonmutating set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { defaults.removeObject(forKey: key("draft")) } else { defaults.set(newValue, forKey: key("draft")) }
        }
    }

    var audience: Audience {
        get { defaults.string(forKey: key("audience")).flatMap(Audience.init(rawValue:)) ?? .public }
        nonmutating set { defaults.set(newValue.rawValue, forKey: key("audience")) }
    }

    var lastTagged: UUID? {
        get { defaults.string(forKey: key("vehicle")).flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: key("vehicle")) }
    }

    /// The vehicle to offer as a one-tap tag (never tagged automatically):
    /// the one last tagged, else the only one, else the one last driven.
    static func suggestedVehicle(garage: [Vehicle], lastTagged: UUID?, lastDriven: UUID?) -> Vehicle? {
        if let lastTagged, let vehicle = garage.first(where: { $0.id == lastTagged }) { return vehicle }
        if garage.count == 1 { return garage[0] }
        if let lastDriven, let vehicle = garage.first(where: { $0.id == lastDriven }) { return vehicle }
        return nil
    }
}

/// New post. Text, photos and Post are all there is at first; a vehicle
/// tag is one tap on a suggestion; audience is always shown because it
/// decides who sees the post; the post type is under More options.
struct PostComposerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var kind: Post.Kind = .moment
    @State private var audience: Audience = .public
    @State private var vehicleID: UUID?
    @State private var items: [PhotosPickerItem] = []
    @State private var media: [NewPost.Media] = []
    @State private var previews: [UIImage] = []
    @State private var isLoadingMedia = false
    @State private var isPosting = false
    @State private var error: String?
    @State private var showsMore = false
    @State private var didRestore = false
    @FocusState private var captionFocused: Bool
    /// The post's id for this draft. Kept across retries so a retry finishes
    /// the same post instead of making a second one (see PostPublisher).
    @State private var postID = UUID()
    @State private var postTask: Task<Void, Never>?
    @State private var posted = false

    private var memory: ComposerMemory { ComposerMemory(defaults: .standard, owner: app.userID) }
    private var vehicle: Vehicle? { app.garage.vehicle(vehicleID) }

    private var suggestion: Vehicle? {
        guard vehicleID == nil else { return nil }
        var lastDriven: UUID?
        if case let .vehicle(id) = app.recorder.preferredChoice(among: app.garage.active) { lastDriven = id }
        return ComposerMemory.suggestedVehicle(garage: app.garage.active, lastTagged: memory.lastTagged, lastDriven: lastDriven)
    }

    /// A post can't be more visible than the vehicle it shows. The server
    /// enforces this; the picker just doesn't offer the impossible choice.
    private var allowedAudiences: [Audience] {
        guard let vehicle else { return Audience.allCases }
        return Audience.allCases.filter { $0.openness <= vehicle.visibility.openness }
    }

    private var canPost: Bool {
        (!caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !media.isEmpty) && !isPosting && !isLoadingMedia
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    HStack(alignment: .top, spacing: Space.m) {
                        Avatar(name: app.account?.displayName ?? "You", path: app.account?.avatarPath, size: 40)
                        TextField("What's happening with your car or bike?", text: $caption, axis: .vertical)
                            .font(ClusterFont.body(.title3))
                            .foregroundStyle(ClusterColor.ink)
                            .lineLimit(3...12)
                            .focused($captionFocused)
                            .padding(.top, Space.xs)
                            .accessibilityLabel("Caption")
                            .accessibilityIdentifier("composer-caption")
                    }
                    mediaSection
                    tagSection
                    audienceSection
                    moreOptions
                    VStack(alignment: .leading, spacing: Space.s) {
                        ContentRulesNote(context: .post, failure: error)
                        if let error { ErrorLine(message: error) }
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.l)
                .frame(maxWidth: Space.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .canvasBackground()
            .clusterNavigation("New post")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Stops an upload in progress; onDisappear deletes what it sent.
                        postTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPosting ? "Posting" : "Post") { postTask = Task { await post() } }
                        .disabled(!canPost)
                        .accessibilityIdentifier("composer-post")
                }
            }
            .interactiveDismissDisabled(isPosting)
            .onAppear {
                guard !didRestore else { return }
                didRestore = true
                caption = memory.draft
                audience = memory.audience
                captionFocused = true
            }
            .onChange(of: caption) { _, text in if !posted { memory.draft = text } }
            .onDisappear {
                guard !posted else { return }
                postTask?.cancel()
                let backend = app.backend
                let id = postID
                Task { await backend.discardPostDraft(id) }
            }
            .onChange(of: vehicleID) { _, _ in
                if !allowedAudiences.contains(audience) { audience = allowedAudiences.last ?? .private }
            }
            .onChange(of: items) { _, items in Task { await loadMedia(items) } }
        }
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(Array(previews.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 150)
                            .clipShape(ChamferedRectangle(cut: Radius.photo))
                    }
                    let loading = isLoadingMedia
                    let pickerTitle = previews.isEmpty ? "Photos or video" : "Change"
                    let pickerWidth: CGFloat = previews.isEmpty ? 150 : 120
                    let pickerCut = Radius.photo
                    PhotosPicker(selection: $items, maxSelectionCount: 4, matching: .any(of: [.images, .videos])) {
                        MediaPickerLabel(isLoading: loading, symbol: "photo.on.rectangle.angled", title: pickerTitle, width: pickerWidth, height: 150, cut: pickerCut)
                    }
                    .disabled(isPosting)
                    .accessibilityIdentifier("composer-media")
                }
            }
            Text("Location data is removed from photos and videos before upload.")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkTertiary)
        }
    }

    /// A tagged vehicle shows as a removable chip; an untagged post shows
    /// the suggested one (or a menu of the garage) to add in one tap.
    @ViewBuilder
    private var tagSection: some View {
        if !app.garage.active.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Legend("Vehicle (optional)")
                HStack(spacing: Space.s) {
                    if let vehicle {
                        Button {
                            withAnimation(Motion.reveal) { vehicleID = nil }
                        } label: {
                            chip(vehicle.displayName, symbol: vehicle.kind == .car ? "car.side.fill" : "motorcycle", selected: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Tagged \(vehicle.displayName)")
                        .accessibilityHint("Removes the tag")
                        .accessibilityIdentifier("composer-vehicle-tagged")
                    } else if let suggestion {
                        Button {
                            withAnimation(Motion.reveal) { vehicleID = suggestion.id }
                        } label: {
                            chip(suggestion.displayName, symbol: "plus", selected: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Tag \(suggestion.displayName)")
                        .accessibilityIdentifier("composer-vehicle-suggestion")
                    }
                    if app.garage.active.count > 1 {
                        Menu {
                            ForEach(app.garage.active) { option in
                                Button(option.displayName) { vehicleID = option.id }
                            }
                            if vehicleID != nil {
                                Divider()
                                Button("No vehicle", role: .destructive) { vehicleID = nil }
                            }
                        } label: {
                            chip(vehicleID == nil && suggestion == nil ? "Choose a vehicle" : "Other", symbol: "chevron.down", selected: false)
                        }
                        .accessibilityIdentifier("composer-vehicle-menu")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chip(_ title: String, symbol: String, selected: Bool) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).font(.footnote.weight(.semibold))
            Text(title).font(ClusterFont.headline(.subheadline)).lineLimit(1)
            if selected { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
        }
        .foregroundStyle(selected ? app.themeStore.theme.onAccent : ClusterColor.ink)
        .padding(.horizontal, Space.m)
        .frame(minHeight: 36)
        .background(selected ? app.themeStore.theme.accentFill : ClusterColor.plate, in: Capsule())
        .frame(minHeight: Space.target)
        .contentShape(Capsule())
    }

    private var audienceSection: some View {
        AudiencePicker(title: "Who can see this post", selection: $audience, allowed: allowedAudiences)
    }

    private var moreOptions: some View {
        DisclosureGroup(isExpanded: $showsMore.animation(Motion.reveal)) {
            VStack(alignment: .leading, spacing: Space.s) {
                Legend("Post type")
                Picker("Post type", selection: $kind) {
                    Text("Moment").tag(Post.Kind.moment)
                    Text("Build update").tag(Post.Kind.build)
                    Text("Meet").tag(Post.Kind.meet)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.top, Space.m)
        } label: {
            Text("More options")
                .font(ClusterFont.headline(.subheadline))
                .foregroundStyle(ClusterColor.ink)
        }
        .tint(ClusterColor.inkSecondary)
        .accessibilityIdentifier("composer-more")
    }

    private func loadMedia(_ items: [PhotosPickerItem]) async {
        isLoadingMedia = true
        defer { isLoadingMedia = false }
        var loaded: [NewPost.Media] = []
        var thumbs: [UIImage] = []
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if isVideo {
                guard data.count <= 100 * 1024 * 1024 else {
                    error = "Videos must be under 100 MB."
                    continue
                }
                // Uploaded as MP4 without the clip's location and device details.
                guard let shared = await VideoInfo.shareable(data) else {
                    error = "This video couldn't be prepared for posting. Try another clip."
                    continue
                }
                let info = await VideoInfo.read(shared)
                loaded.append(.init(data: shared, type: .video, width: info.width, height: info.height, duration: info.duration))
                if let thumb = info.thumbnail { thumbs.append(thumb) }
            } else if let jpeg = ImageProcessing.uploadJPEG(from: data), let image = UIImage(data: jpeg) {
                loaded.append(.init(data: jpeg, type: .image, width: Int(image.size.width), height: Int(image.size.height)))
                thumbs.append(image)
            }
        }
        media = loaded
        previews = thumbs
    }

    /// The post appears only once every photo and video is uploaded. After a
    /// failure, Post again retries the same draft: files already uploaded
    /// aren't sent twice and a post that did get through isn't duplicated.
    private func post() async {
        isPosting = true
        error = nil
        defer { isPosting = false }
        do {
            _ = try await app.backend.createPost(NewPost(
                id: postID, kind: kind, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines), audience: audience,
                vehicleID: vehicleID, media: media
            ))
            posted = true
            memory.draft = ""
            memory.audience = audience
            if let vehicleID { memory.lastTagged = vehicleID }
            dismiss()
        } catch is CancellationError {
            // Cancelled from the toolbar; the sheet is already closing.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Reads a video's dimensions, duration and a poster frame.
enum VideoInfo {
    /// Rewraps a picked video as MP4 without re-encoding, dropping the
    /// metadata `AVMetadataItemFilter.forSharing()` removes (location, device
    /// and personal details), so a clip filmed at home doesn't publish where
    /// home is. `nil` if it can't be converted; the clip isn't posted then.
    static func shareable(_ data: Data) async -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("picked.mov")
            let output = folder.appendingPathComponent("shared.mp4")
            try data.write(to: source)
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
                return nil
            }
            session.metadataItemFilter = .forSharing()
            session.shouldOptimizeForNetworkUse = true
            try await session.export(to: output, as: .mp4)
            return try Data(contentsOf: output)
        } catch {
            return nil
        }
    }

    struct Result {
        var width = 1080
        var height = 1920
        var duration: Double?
        var thumbnail: UIImage?
    }

    @MainActor
    static func read(_ data: Data) async -> Result {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil else { return Result() }
        let asset = AVURLAsset(url: url)
        var result = Result()
        if let duration = try? await asset.load(.duration) { result.duration = duration.seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let geometry = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: geometry.0).applying(geometry.1)
            result.width = Int(abs(rect.width))
            result.height = Int(abs(rect.height))
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let image = try? await generator.image(at: .zero).image {
            result.thumbnail = UIImage(cgImage: image)
        }
        return result
    }
}
