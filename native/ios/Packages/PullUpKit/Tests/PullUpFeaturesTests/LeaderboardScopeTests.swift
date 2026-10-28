import Testing
@testable import PullUpFeatures
import PullUpDomain

@Suite("Leaderboard scopes")
struct LeaderboardScopeTests {
    /// Country and region boards need a country nobody can set yet; offering
    /// them would only show an error (App Review 2.1).
    @Test func onlyBoardsAnyoneCanOpenAreOffered() {
        #expect(LeaderboardView.scopes == [.global, .friends])
    }
}
