import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PullUpData
import PullUpDesign
import PullUpDomain

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

    private var vehicle: Vehicle? { app.garage.vehicle(vehicleID) }

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
                    mediaSection
                    FieldRow(label: "Caption", text: $caption, prompt: "What happened?", axis: .vertical)
                    VStack(alignment: .leading, spacing: Space.s) {
                        Legend("Type")
                        Picker("Type", selection: $kind) {
                            Text("Moment").tag(Post.Kind.moment)
                            Text("Build update").tag(Post.Kind.build)
                            Text("Meet").tag(Post.Kind.meet)
                        }
                        .pickerStyle(.segmented)
                    }
                    if !app.garage.active.isEmpty {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Legend("Vehicle")
                            Picker("Vehicle", selection: $vehicleID) {
                                Text("None").tag(UUID?.none)
                                ForEach(app.garage.active) { Text($0.displayName).tag(Optional($0.id)) }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    AudiencePicker(title: "Who can see this post", selection: $audience, allowed: allowedAudiences)
                    if let error { ErrorLine(message: error) }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.l)
            }
            .canvasBackground()
            .clusterNavigation("New post")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPosting ? "Posting" : "Post") { Task { await post() } }.disabled(!canPost)
                }
            }
            .onChange(of: vehicleID) { _, _ in
                if !allowedAudiences.contains(audience) { audience = allowedAudiences.last ?? .private }
            }
            .onChange(of: items) { _, items in Task { await loadMedia(items) } }
        }
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Legend("Photos and video")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(Array(previews.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 110, height: 138)
                            .clipShape(ChamferedRectangle(cut: 5))
                    }
                    let loading = isLoadingMedia
                    let pickerTitle = previews.isEmpty ? "Add" : "Change"
                    PhotosPicker(selection: $items, maxSelectionCount: 4, matching: .any(of: [.images, .videos])) {
                        MediaPickerLabel(isLoading: loading, symbol: "photo.badge.plus", title: pickerTitle, width: 110, height: 138, cut: 5)
                    }
                }
            }
            Text("Location metadata is removed from photos and videos before upload.")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkTertiary)
        }
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

    private func post() async {
        isPosting = true
        defer { isPosting = false }
        do {
            _ = try await app.backend.createPost(NewPost(
                kind: kind, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines), audience: audience,
                vehicleID: vehicleID, media: media
            ))
            dismiss()
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
