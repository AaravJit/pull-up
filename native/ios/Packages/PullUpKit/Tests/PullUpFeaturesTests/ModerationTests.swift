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

    @Test func reportNotesAreTrimmedToTheServerLimit() {
        #expect(ReportDetails.note("  ") == "")
        #expect(ReportDetails.note(" spam link \n") == "spam link")
        #expect(ReportDetails.note(String(repeating: "b", count: 2_000)).count == ReportDetails.limit)
    }

    @Test func reportingAPostNamesItsAuthorAndYourOwnIsRefused() async throws {
        let feed = try await backend.feed(.discover, before: nil)
        let post = try #require(feed.first { $0.authorID == DemoSeed.mayaID })
        try await backend.report(ReportedContent(.post, id: post.id), author: post.authorID, reason: .spam, note: "")
        let mine = try #require(feed.first { $0.authorID == DemoSeed.meID })
        await #expect(throws: BackendError.self) {
            try await backend.report(ReportedContent(.post, id: mine.id), author: DemoSeed.meID, reason: .spam, note: "")
        }
    }

    @Test func deletingYourPostRemovesItFromTheFeed() async throws {
        let feed = try await backend.feed(.discover, before: nil)
        let mine = try #require(feed.first { $0.authorID == DemoSeed.meID })
        try await backend.deletePost(mine.id)
        let after = try await backend.feed(.discover, before: nil)
        #expect(!after.contains { $0.id == mine.id })
    }

    @Test func blockingHidesThePersonAppWideUntilSignOut() async throws {
        var options = LaunchOptions()
        options.demo = true
        let app = AppModel(options: options, appleCredentials: FakeAppleCredentials(storedID: nil, state: .authorized))
        await app.start()
        try await app.block(DemoSeed.mayaID)
        #expect(app.blockedUsers == [DemoSeed.mayaID])
        await app.signOut()
        #expect(app.blockedUsers.isEmpty)
    }

    @Test func vehiclesAreReportedUnderTheServersKind() {
        // report_content accepts post, comment, meet, profile and vehicle.
        #expect(ReportedContent.Kind.vehicle.rawValue == "vehicle")
    }

    @Test func suspensionSaysWhatStillWorks() {
        let open = Suspension(until: nil, reason: "")
        #expect(open.title == "Your account is suspended")
        #expect(open.message.hasPrefix("You can still look around"))
        let dated = Suspension(until: Date(timeIntervalSince1970: 1_800_000_000), reason: "Spam links.")
        #expect(dated.title.hasPrefix("Your account is suspended until "))
        #expect(dated.message.hasPrefix("Spam links. You can still"))
    }

    @Test func blockingDropsTheFollow() async throws {
        try await backend.block(DemoSeed.mayaID)
        let following = try await backend.feed(.following, before: nil)
        #expect(!following.contains { $0.authorID == DemoSeed.mayaID })
    }
}
