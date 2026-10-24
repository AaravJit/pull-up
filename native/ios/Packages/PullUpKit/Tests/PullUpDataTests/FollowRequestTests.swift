import Foundation
import Testing
@testable import PullUpData
import PullUpDomain

@Suite("Demo follow requests")
struct FollowRequestTests {
    @Test func demoDriverApprovesFollowersAndSamIsWaiting() async throws {
        let backend = DemoBackend()
        #expect(try await backend.privacySettings().requireFollowApproval)
        #expect(try await backend.followRequests().map(\.id) == [DemoSeed.samID])
        #expect(try await backend.profilePage(DemoSeed.samID).relationship.followsMe == "pending")
    }

    @Test func acceptingMovesTheRequestToFollowers() async throws {
        let backend = DemoBackend()
        let before = try await backend.profilePage(DemoSeed.meID).followerCount
        try await backend.answerFollowRequest(from: DemoSeed.samID, accept: true)
        #expect(try await backend.followRequests().isEmpty)
        #expect(try await backend.profilePage(DemoSeed.meID).followerCount == before + 1)
        #expect(try await backend.profilePage(DemoSeed.samID).relationship.followsMe == "accepted")
    }

    @Test func decliningRemovesTheRequest() async throws {
        let backend = DemoBackend()
        let before = try await backend.profilePage(DemoSeed.meID).followerCount
        try await backend.answerFollowRequest(from: DemoSeed.samID, accept: false)
        #expect(try await backend.followRequests().isEmpty)
        #expect(try await backend.profilePage(DemoSeed.meID).followerCount == before)
        #expect(try await backend.profilePage(DemoSeed.samID).relationship.followsMe == nil)
    }

    @Test func answeringSomeoneWhoDidNotAskChangesNothing() async throws {
        let backend = DemoBackend()
        let before = try await backend.profilePage(DemoSeed.meID).followerCount
        try await backend.answerFollowRequest(from: DemoSeed.dreID, accept: true)
        #expect(try await backend.profilePage(DemoSeed.meID).followerCount == before)
        #expect(try await backend.followRequests().map(\.id) == [DemoSeed.samID])
    }

    @Test func blockingDropsTheRequest() async throws {
        let backend = DemoBackend()
        try await backend.block(DemoSeed.samID)
        #expect(try await backend.followRequests().isEmpty)
    }

    @Test func newAccountsHaveNoRequests() async throws {
        let backend = DemoBackend(onboarded: false)
        #expect(try await backend.followRequests().isEmpty)
    }

    @Test func signedOutCannotListRequests() async throws {
        let backend = DemoBackend(signedIn: false)
        await #expect(throws: BackendError.self) { try await backend.followRequests() }
    }
}
