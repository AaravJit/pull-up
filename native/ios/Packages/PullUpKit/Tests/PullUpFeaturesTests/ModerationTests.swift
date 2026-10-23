import Foundation
import Testing
@testable import PullUpFeatures
@testable import PullUpData
import PullUpDomain

/// Reports, blocks and deletes outside messages. Who may see what after a
/// block is enforced by RLS (`is_blocked_between`), not here.
@MainActor
@Suite("Moderation")
struct ModerationTests {
    private let backend = DemoBackend(replyDelay: .zero)

    @Test func leaderboardsNeverOfferSpeed() {
        #expect(!LeaderboardView.metrics.contains(.topSpeed))
        #expect(!LeaderboardView.metrics.contains(.zeroToSixty))
        #expect(LeaderboardView.metrics.first == .distance)
    }

    @Test func reportDetailsNameTheContent() {
        let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000f1")!
        #expect(ReportDetails.subject("post", id: id, excerpt: "  Night run\nat the lot ") == "post:00000000-0000-4000-8000-0000000000f1 \"Night run at the lot\"")
        #expect(ReportDetails.subject("profile", id: id, excerpt: "") == "profile:00000000-0000-4000-8000-0000000000f1")
        let long = ReportDetails.subject("comment", id: id, excerpt: String(repeating: "a", count: 300))
        #expect(long.hasSuffix("…\""))
        #expect(long.count < 200)
    }

    @Test func reportDetailsKeepTheNoteWithinTheServerLimit() {
        #expect(ReportDetails.combined(subject: "post:x", note: "  ") == "post:x")
        #expect(ReportDetails.combined(subject: "post:x", note: " spam link ") == "post:x\nspam link")
        let capped = ReportDetails.combined(subject: "post:x", note: String(repeating: "b", count: 2_000))
        #expect(capped.count == ReportDetails.limit)
        #expect(capped.hasPrefix("post:x\n"))
    }

    @Test func reportingAPostNamesItsAuthorAndYourOwnIsRefused() async throws {
        let feed = try await backend.feed(.discover, before: nil)
        let post = try #require(feed.first { $0.authorID == DemoSeed.mayaID })
        try await backend.report(
            user: post.authorID, reason: .spam,
            details: ReportDetails.combined(subject: ReportDetails.subject("post", id: post.id, excerpt: post.caption), note: ""),
            message: nil
        )
        await #expect(throws: BackendError.self) { try await backend.report(user: DemoSeed.meID, reason: .spam, details: "", message: nil) }
    }

    @Test func deletingYourPostRemovesItFromTheFeed() async throws {
        let feed = try await backend.feed(.discover, before: nil)
        let mine = try #require(feed.first { $0.authorID == DemoSeed.meID })
        try await backend.deletePost(mine.id)
        let after = try await backend.feed(.discover, before: nil)
        #expect(!after.contains { $0.id == mine.id })
    }

    @Test func blockingDropsTheFollow() async throws {
        try await backend.block(DemoSeed.mayaID)
        let following = try await backend.feed(.following, before: nil)
        #expect(!following.contains { $0.authorID == DemoSeed.mayaID })
    }
}
