import Foundation
import Testing
@testable import PullUpData
import PullUpDomain

/// publish_post and post-media storage, in memory, with ways to fail.
actor FakePostServer: PostUploadTransport {
    private(set) var files: [String: Data] = [:]
    private(set) var posts: [UUID: PostPublication] = [:]
    private(set) var uploadCalls: [String] = []
    private(set) var publishCalls = 0
    private(set) var removed: [String] = []

    /// Upload calls (counted from 1) that fail as if the connection dropped.
    private var failingUploads: Set<Int> = []
    private var failNextPublish = false
    private var loseNextPublishResponse = false
    private var offline = false
    /// From this upload call on, uploads wait for `releaseUploads()`.
    private var holdFrom: Int?
    private var held: [CheckedContinuation<Void, Never>] = []

    func failUpload(call: Int) { failingUploads.insert(call) }
    /// The next publish never reaches the server.
    func failNextPublishRequest() { failNextPublish = true }
    /// The next publish commits on the server, but its response is lost.
    func loseNextPublishResponseAfterCommit() { loseNextPublishResponse = true }
    func setOffline(_ value: Bool) { offline = value }
    func holdUploads(fromCall call: Int) { holdFrom = call }
    func releaseUploads() {
        holdFrom = nil
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }
    var heldUploads: Int { held.count }
    /// The server's cleanup deleted this file.
    func deleteFile(_ path: String) { files[path] = nil }

    func upload(path: String, data: Data, contentType: String) async throws {
        uploadCalls.append(path)
        let call = uploadCalls.count
        if let holdFrom, call >= holdFrom {
            await withCheckedContinuation { held.append($0) }
        }
        try Task.checkCancellation()
        if offline || failingUploads.contains(call) { throw URLError(.networkConnectionLost) }
        files[path] = data
    }

    func remove(paths: [String]) async throws {
        if offline { throw URLError(.notConnectedToInternet) }
        removed += paths
        for path in paths { files[path] = nil }
    }

    func publish(_ publication: PostPublication) async throws -> UUID {
        publishCalls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        if failNextPublish {
            failNextPublish = false
            throw URLError(.timedOut)
        }
        // publish_post: the same id again returns the post already made.
        if posts[publication.id] == nil {
            guard publication.media.allSatisfy({ files[$0.path] != nil }) else { throw PostPublishError.mediaMissing }
            posts[publication.id] = publication
        }
        if loseNextPublishResponse {
            loseNextPublishResponse = false
            throw URLError(.timedOut)
        }
        return publication.id
    }

    func postExists(_ id: UUID) async throws -> Bool {
        if offline { throw URLError(.notConnectedToInternet) }
        return posts[id] != nil
    }
}

@Suite("Post publishing")
struct PostPublisherTests {
    let author = UUID()

    static func draft(media count: Int, id: UUID = UUID()) -> NewPost {
        NewPost(
            id: id, kind: .moment, caption: "Sunday", audience: .public,
            media: (0..<count).map { NewPost.Media(data: Data([UInt8($0)]), type: .image, width: 1080, height: 1350) }
        )
    }

    func path(_ post: NewPost, _ index: Int) -> String {
        PostPublisher.path(author: author, post: post.id, media: post.media[index])
    }

    /// Waits (bounded) until `condition` holds.
    static func until(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting")
    }

    @Test func publishesOnceEveryFileIsUp() async throws {
        let server = FakePostServer()
        let publisher = PostPublisher(transport: server)
        let post = Self.draft(media: 2)
        let id = try await publisher.publish(post, author: author)

        #expect(id == post.id)
        #expect(await server.uploadCalls == [path(post, 0), path(post, 1)])
        #expect(await server.publishCalls == 1)
        let published = try #require(await server.posts[post.id])
        #expect(published.media.map(\.path) == [path(post, 0), path(post, 1)])
        #expect(path(post, 0).hasPrefix("\(author.uuidString.lowercased())/\(post.id.uuidString.lowercased())/"))
    }

    @Test func aFailureMidUploadLeavesNoPostAndTheRetrySendsOnlyWhatIsMissing() async throws {
        let server = FakePostServer()
        let publisher = PostPublisher(transport: server)
        let post = Self.draft(media: 3)
        await server.failUpload(call: 2)

        await #expect(throws: URLError.self) { try await publisher.publish(post, author: author) }
        #expect(await server.posts.isEmpty, "no partial post")
        #expect(await server.publishCalls == 0)
        #expect(await publisher.pendingUploads(post.id) == [path(post, 0)])

        let id = try await publisher.publish(post, author: author)
        #expect(id == post.id)
        // The first file isn't sent again; the failed one is.
        #expect(await server.uploadCalls == [path(post, 0), path(post, 1), path(post, 1), path(post, 2)])
        #expect(await server.posts.count == 1)
        #expect(await server.posts[post.id]?.media.count == 3)
    }

    @Test func aRetryAfterANetworkErrorPublishesOnce() async throws {
        let server = FakePostServer()
        let publisher = PostPublisher(transport: server)
        let post = Self.draft(media: 2)
        await server.failNextPublishRequest()

        await #expect(throws: URLError.self) { try await publisher.publish(post, author: author) }
        #expect(await server.posts.isEmpty)

        #expect(try await publisher.publish(post, author: author) == post.id)
        #expect(await server.uploadCalls.count == 2, "files aren't uploaded twice")
        #expect(await server.posts.count == 1)
    }

    @Test func aRetryAfterALostResponseIsTheSamePost() async throws {
        let server = FakePostServer()
        let publisher = PostPublisher(transport: server)
        let post = Self.draft(media: 2)
        await server.loseNextPublishResponseAfterCommit()

        await #expect(throws: URLError.self) { try await publisher.publish(post, author: author) }
        #expect(await server.posts.count == 1, "the server did make it")

        #expect(try await publisher.publish(post, author: author) == post.id)
        #expect(await server.posts.count == 1, "the retry didn't make a second post")
        #expect(await server.posts[post.id]?.media.count == 2, "or duplicate its media")
        #expect(await server.uploadCalls.count == 2)
        #expect(await server.publishCalls == 2)
    }

    @Test func aDoubleTapMakesOnePost() async throws {
        let server = FakePostServer()
        let publisher = PostPublisher(transport: server)
        let post = Self.draft(media: 2)
        let author = self.author
        await server.holdUploads(fromCall: 1)

        let first = Task { try await publisher.publish(post, author: author) }
        try await Self.until { await server.heldUploads == 1 }
        let second = Task { try await publisher.publish(post, author: author) }
        try await Task.sleep(for: .milliseconds(20))
        await server.releaseUploads()

        #expect(try await first.value == post.id)
        #expect(try await second.value == post.id)
        #expect(await server.uploadCalls.count == 2)
        #expect(await server.publishCalls == 1)
        #expect(await server.posts.count == 1)

        // Submitting a published draft again does nothing.
        #expect(try await publisher.publish(post, author: author) == post.id)
        #expect(await server.publishCalls == 1)
    }

    @Test func cancellingMidUploadLeavesNoPostAndNoFiles() async throws {
        let server = FakePostServer()
        let journal = InMemoryPostUploadJournal()
        let publisher = PostPublisher(transport: server, journal: journal)
        let post = Self.draft(media: 3)
        let author = self.author
        await server.holdUploads(fromCall: 2)

        let task = Task { try await publisher.publish(post, author: author) }
        try await Self.until { await server.heldUploads == 1 }
        task.cancel()
        await server.releaseUploads()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await server.posts.isEmpty)
        #expect(await server.publishCalls == 0)
        #expect(await server.files.isEmpty, "the uploaded photo is deleted")
        #expect(await Set(server.removed) == [path(post, 0), path(post, 1)], "including the one in flight")
        #expect(await journal.entries().isEmpty)
    }

    @Test func discardingAFailedDraftDeletesItsFilesButNeverAPublishedPost() async throws {
        let server = FakePostServer()
        let publisher = PostPublisher(transport: server)
        let failed = Self.draft(media: 2)
        await server.failUpload(call: 2)
        await #expect(throws: URLError.self) { try await publisher.publish(failed, author: author) }
        await publisher.discard(failed.id)
        #expect(await server.files.isEmpty)
        #expect(await server.posts.isEmpty)

        let posted = Self.draft(media: 1)
        _ = try await publisher.publish(posted, author: author)
        await publisher.discard(posted.id)
        #expect(await server.files[path(posted, 0)] != nil, "a published post keeps its photo")
    }

    @Test func filesCleanedUpByTheServerAreUploadedAgain() async throws {
        let server = FakePostServer()
        let publisher = PostPublisher(transport: server)
        let post = Self.draft(media: 2)
        await server.failUpload(call: 2)
        await #expect(throws: URLError.self) { try await publisher.publish(post, author: author) }
        // A day passes; the server deletes the unused file.
        await server.deleteFile(path(post, 0))

        await #expect(throws: PostPublishError.mediaMissing) { try await publisher.publish(post, author: author) }
        #expect(await server.posts.isEmpty)
        #expect(try await publisher.publish(post, author: author) == post.id)
        #expect(await server.posts[post.id]?.media.count == 2)
    }

    @Test func mediaRemovedBeforeARetryIsDeleted() async throws {
        let server = FakePostServer()
        let publisher = PostPublisher(transport: server)
        var post = Self.draft(media: 2)
        await server.failNextPublishRequest()
        await #expect(throws: URLError.self) { try await publisher.publish(post, author: author) }
        let dropped = path(post, 1)
        post.media.removeLast()

        _ = try await publisher.publish(post, author: author)
        #expect(await server.posts[post.id]?.media.map(\.path) == [path(post, 0)])
        #expect(await server.removed == [dropped])
    }

    @Test func aTextPostUploadsNothing() async throws {
        let server = FakePostServer()
        let publisher = PostPublisher(transport: server)
        let post = Self.draft(media: 0)
        #expect(try await publisher.publish(post, author: author) == post.id)
        #expect(await server.uploadCalls.isEmpty)
        #expect(await server.posts.count == 1)
    }

    // MARK: The app closed mid-upload

    @Test func afterTheAppIsClosedMidUploadTheNextLaunchDeletesTheDraftsFiles() async throws {
        let server = FakePostServer()
        let journal = InMemoryPostUploadJournal()
        let post = Self.draft(media: 3)
        let author = self.author
        await server.holdUploads(fromCall: 2)
        let closedApp = PostPublisher(transport: server, journal: journal)
        // The app is closed while the second file is on its way.
        let abandoned = Task { try await closedApp.publish(post, author: author) }
        try await Self.until { await server.heldUploads == 1 }
        #expect(await server.posts.isEmpty, "nothing is visible")
        #expect(await journal.entries().first?.paths == [path(post, 0), path(post, 1)], "both files are on record")

        // Relaunch: a new publisher over the same journal.
        let relaunched = PostPublisher(transport: server, journal: journal)
        await relaunched.recoverInterrupted(author: author)
        #expect(await server.files.isEmpty, "the draft's file is deleted")
        #expect(await Set(server.removed) == [path(post, 0), path(post, 1)])
        #expect(await server.posts.isEmpty)
        #expect(await journal.entries().isEmpty)

        // (Tidy up the stand-in for the closed app.)
        abandoned.cancel()
        await server.releaseUploads()
        _ = try? await abandoned.value
    }

    @Test func aDraftThatPublishedBeforeTheAppClosedKeepsItsFiles() async throws {
        let server = FakePostServer()
        let journal = InMemoryPostUploadJournal()
        let post = Self.draft(media: 1)
        // The server published it, but the app closed before hearing back.
        _ = try await PostPublisher(transport: server).publish(post, author: author)
        await journal.save(PendingPostUpload(postID: post.id, authorID: author, paths: [path(post, 0)]))

        await PostPublisher(transport: server, journal: journal).recoverInterrupted(author: author)
        #expect(await server.files[path(post, 0)] != nil)
        #expect(await server.removed.isEmpty)
        #expect(await journal.entries().isEmpty)
    }

    @Test func recoveryOfflineTriesAgainNextLaunch() async throws {
        let server = FakePostServer()
        let journal = InMemoryPostUploadJournal()
        let post = Self.draft(media: 2)
        await server.failUpload(call: 2)
        await #expect(throws: URLError.self) {
            try await PostPublisher(transport: server, journal: journal).publish(post, author: author)
        }
        await server.setOffline(true)
        await PostPublisher(transport: server, journal: journal).recoverInterrupted(author: author)
        #expect(await journal.entries().count == 1, "kept for next time")

        await server.setOffline(false)
        await PostPublisher(transport: server, journal: journal).recoverInterrupted(author: author)
        #expect(await server.files.isEmpty)
        #expect(await journal.entries().isEmpty)
    }

    @Test func recoveryLeavesOtherAccountsDraftsAlone() async throws {
        let server = FakePostServer()
        let journal = InMemoryPostUploadJournal()
        let someoneElse = UUID()
        await journal.save(PendingPostUpload(postID: UUID(), authorID: someoneElse, paths: ["\(someoneElse.uuidString.lowercased())/x/y.jpg"]))
        await PostPublisher(transport: server, journal: journal).recoverInterrupted(author: author)
        #expect(await journal.entries().count == 1)
        #expect(await server.removed.isEmpty)
    }

    @Test func theJournalSurvivesARelaunch() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("post-journal-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let entry = PendingPostUpload(postID: UUID(), authorID: author, paths: ["a/b/c.jpg"])
        await FilePostUploadJournal(file: file).save(entry)
        #expect(await FilePostUploadJournal(file: file).entries() == [entry])
        await FilePostUploadJournal(file: file).remove(entry.postID)
        #expect(await FilePostUploadJournal(file: file).entries().isEmpty)
    }

    @Test func demoBackendMakesOnePostPerDraft() async throws {
        let backend = DemoBackend()
        let post = Self.draft(media: 0)
        let first = try await backend.createPost(post)
        let again = try await backend.createPost(post)
        #expect(first.id == post.id && again.id == post.id)
        #expect(try await backend.feed(.following, before: nil).filter { $0.id == post.id }.count == 1)
    }
}
