import Foundation
import PullUpDomain

/// One photo or video of a post, as `publish_post` receives it.
public struct PublishedMedia: Encodable, Equatable, Sendable {
    public var path: String
    public var type: PostMedia.MediaType
    public var width: Int
    public var height: Int
    public var durationSeconds: Double?

    public init(path: String, type: PostMedia.MediaType, width: Int, height: Int, durationSeconds: Double? = nil) {
        self.path = path
        self.type = type
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }

    enum CodingKeys: String, CodingKey {
        case path, type, width, height
        case durationSeconds = "duration_s"
    }
}

/// The arguments of `publish_post` (migration 20261025000200).
public struct PostPublication: Encodable, Equatable, Sendable {
    public var id: UUID
    public var kind: Post.Kind
    public var caption: String
    public var audience: Audience
    public var vehicleID: UUID?
    public var meetID: UUID?
    public var driveID: UUID?
    public var media: [PublishedMedia]

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case kind = "p_kind"
        case caption = "p_caption"
        case audience = "p_visibility"
        case vehicleID = "p_vehicle_id"
        case meetID = "p_meet_id"
        case driveID = "p_drive_id"
        case media = "p_media"
    }
}

/// What `PostPublisher` needs from the server. `SupabaseBackend` provides
/// it; tests use a fake.
public protocol PostUploadTransport: Sendable {
    /// Stores one file in post-media, replacing any earlier upload to the same path.
    func upload(path: String, data: Data, contentType: String) async throws
    func remove(paths: [String]) async throws
    /// Creates the post with all of its media in one step, or returns the
    /// post already created with this id. Throws `PostPublishError.mediaMissing`
    /// when a file isn't in storage.
    func publish(_ publication: PostPublication) async throws -> UUID
    /// Whether the signed-in author has a post with this id.
    func postExists(_ id: UUID) async throws -> Bool
}

public enum PostPublishError: Error, Equatable, Sendable, LocalizedError {
    /// The server couldn't find a file the post uses (the upload never
    /// finished, or an old draft's files were cleaned up). The next attempt
    /// uploads every file again.
    case mediaMissing

    public var errorDescription: String? {
        "Some photos or videos didn't finish uploading. Try posting again."
    }
}

/// A draft whose files may be in storage while it isn't published yet.
/// Written before each upload starts, so it outlives the app being closed.
public struct PendingPostUpload: Codable, Equatable, Sendable {
    public var postID: UUID
    public var authorID: UserID
    public var paths: Set<String>

    public init(postID: UUID, authorID: UserID, paths: Set<String>) {
        self.postID = postID
        self.authorID = authorID
        self.paths = paths
    }
}

/// Where `PostPublisher` keeps `PendingPostUpload`s between launches.
public protocol PostUploadJournal: Sendable {
    func entries() async -> [PendingPostUpload]
    func save(_ entry: PendingPostUpload) async
    func remove(_ postID: UUID) async
}

/// Keeps the journal in memory only (previews, demo, tests).
public actor InMemoryPostUploadJournal: PostUploadJournal {
    private var stored: [UUID: PendingPostUpload] = [:]

    public init() {}

    public func entries() -> [PendingPostUpload] { Array(stored.values) }
    public func save(_ entry: PendingPostUpload) { stored[entry.postID] = entry }
    public func remove(_ postID: UUID) { stored[postID] = nil }
}

/// Keeps the journal in one small JSON file (paths and ids only, never media).
public actor FilePostUploadJournal: PostUploadJournal {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// Application Support/PendingPostUploads.json, outside iCloud backup.
    public static func standard() -> FilePostUploadJournal {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FilePostUploadJournal(file: base.appendingPathComponent("PendingPostUploads.json"))
    }

    public func entries() -> [PendingPostUpload] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([PendingPostUpload].self, from: data)
        else { return [] }
        return entries
    }

    public func save(_ entry: PendingPostUpload) {
        var all = entries().filter { $0.postID != entry.postID }
        all.append(entry)
        write(all)
    }

    public func remove(_ postID: UUID) {
        let all = entries()
        let kept = all.filter { $0.postID != postID }
        if kept.count != all.count { write(kept) }
    }

    private func write(_ entries: [PendingPostUpload]) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: [.atomic])
            #endif
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            // The server still deletes unused files a day after upload.
        }
    }
}

/// Posts a draft so that it appears complete or not at all.
///
/// Every file goes to post-media under `<author>/<post id>/` first; only then
/// does `publish_post` create the post and attach all its media in one
/// transaction. The post id comes from the draft (`NewPost.id`), so:
///   * a retry after a failure uploads only the files still missing, and
///     publishing the same id twice (a retry after a lost response) returns
///     the post the first call made instead of a second one;
///   * a second submit while the first is still running joins it;
///   * cancelling before the publish step deletes what was uploaded and no
///     post appears. Once the publish request is sent the server may finish
///     the post anyway, so from then on cancelling has no effect;
///   * the journal records each file before it's uploaded. After the app was
///     closed mid-upload, `recoverInterrupted` (run at the next sign-in)
///     deletes the files of drafts that never published and forgets drafts
///     that did. Whatever this misses (another device, the app deleted) the
///     server deletes a day after upload (`post_orphaned_media`, the
///     post-media-cleanup function).
public actor PostPublisher {
    private let transport: any PostUploadTransport
    private let journal: any PostUploadJournal
    /// Files already uploaded for each unpublished draft.
    private var uploaded: [UUID: Set<String>] = [:]
    /// Every file an unpublished draft has started uploading, finished or not:
    /// what has to be deleted if it's abandoned.
    private var attempted: [UUID: Set<String>] = [:]
    /// Publishes in progress, by draft id.
    private var running: [UUID: Task<UUID, any Error>] = [:]
    /// Drafts this publisher has published; submitting one again is a no-op.
    private var published: Set<UUID> = []

    public init(transport: any PostUploadTransport, journal: any PostUploadJournal = InMemoryPostUploadJournal()) {
        self.transport = transport
        self.journal = journal
    }

    public static func path(author: UserID, post: UUID, media: NewPost.Media) -> String {
        let ext = media.type == .video ? "mp4" : "jpg"
        return "\(author.uuidString.lowercased())/\(post.uuidString.lowercased())/\(media.id.uuidString.lowercased()).\(ext)"
    }

    /// Uploads what's missing and publishes. Returns the post's id.
    public func publish(_ post: NewPost, author: UserID) async throws -> UUID {
        if published.contains(post.id) {
            return post.id
        }
        if let task = running[post.id] {
            return try await task.value
        }
        let task = Task { try await self.run(post, author: author) }
        running[post.id] = task
        defer { running[post.id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Gives up on a draft: cancels it if it's still uploading and deletes
    /// its files. Does nothing to a post that was published.
    public func discard(_ id: UUID) async {
        if let task = running[id] {
            task.cancel()
            _ = try? await task.value
        }
        await removeUploads(of: id, including: nil)
    }

    /// Cleans up after drafts a closed app left behind: forgets the ones the
    /// server published (the app closed before hearing back) and deletes the
    /// files of the rest. Entries it can't settle (offline) wait for next time.
    public func recoverInterrupted(author: UserID) async {
        for entry in await journal.entries() where entry.authorID == author {
            guard running[entry.postID] == nil, attempted[entry.postID] == nil, !published.contains(entry.postID) else { continue }
            do {
                if try await transport.postExists(entry.postID) == false, !entry.paths.isEmpty {
                    try await transport.remove(paths: entry.paths.sorted())
                }
                await journal.remove(entry.postID)
            } catch {
                continue
            }
        }
    }

    /// Paths uploaded for a draft that hasn't published yet (for tests).
    public func pendingUploads(_ id: UUID) -> Set<String> {
        uploaded[id] ?? []
    }

    private func run(_ post: NewPost, author: UserID) async throws -> UUID {
        var media: [PublishedMedia] = []
        var inFlight: String?
        do {
            for item in post.media {
                let path = Self.path(author: author, post: post.id, media: item)
                if !(uploaded[post.id]?.contains(path) ?? false) {
                    try Task.checkCancellation()
                    inFlight = path
                    attempted[post.id, default: []].insert(path)
                    // Recorded first: the app may be closed while the file is on its way.
                    await journal.save(PendingPostUpload(postID: post.id, authorID: author, paths: attempted[post.id] ?? [path]))
                    try await transport.upload(path: path, data: item.data, contentType: item.type == .video ? "video/mp4" : "image/jpeg")
                    uploaded[post.id, default: []].insert(path)
                    inFlight = nil
                }
                media.append(PublishedMedia(path: path, type: item.type, width: item.width, height: item.height, durationSeconds: item.duration))
            }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                await removeUploads(of: post.id, including: inFlight)
                throw CancellationError()
            }
            throw error
        }

        let publication = PostPublication(
            id: post.id, kind: post.kind, caption: post.caption, audience: post.audience,
            vehicleID: post.vehicleID, meetID: post.meetID, driveID: post.driveID, media: media
        )
        let transport = self.transport
        let id: UUID
        do {
            // A separate task, so cancelling now can't abandon a request the
            // server may already be completing; the caller learns the outcome.
            id = try await Task { try await transport.publish(publication) }.value
        } catch PostPublishError.mediaMissing {
            uploaded[post.id] = nil
            throw PostPublishError.mediaMissing
        }
        // Files uploaded for media the author removed before this attempt.
        let unused = (attempted[post.id] ?? []).subtracting(media.map(\.path))
        uploaded[post.id] = nil
        attempted[post.id] = nil
        published.insert(post.id)
        if !unused.isEmpty {
            let paths = unused.sorted()
            _ = await Task { try? await transport.remove(paths: paths) }.value
        }
        await journal.remove(post.id)
        return id
    }

    private func removeUploads(of id: UUID, including extra: String?) async {
        var paths = attempted[id] ?? []
        if let extra { paths.insert(extra) }
        uploaded[id] = nil
        attempted[id] = nil
        let transport = self.transport
        let sorted = paths.sorted()
        // A fresh task: requests made from a cancelled one are cancelled too.
        let removed = await Task { () -> Bool in
            if sorted.isEmpty { return true }
            do {
                try await transport.remove(paths: sorted)
                return true
            } catch {
                return false
            }
        }.value
        // If deleting failed, the journal keeps the draft for the next launch.
        if removed { await journal.remove(id) }
    }
}
