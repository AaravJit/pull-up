import Testing
@testable import PullUpFeatures
import PullUpDesign
import PullUpDomain

@Suite("Driving safety")
struct DrivingSafetyTests {
    @Test func theLiveDashboardHasNoZeroToSixtyTimer() {
        #expect(!DashboardMetric.liveSelectable.contains(.zeroToSixty))
        #expect(DashboardMetric.defaultLayout.allSatisfy { DashboardMetric.liveSelectable.contains($0) })
    }

    @Test func noSpeedOrAccelerationBoardIsOffered() {
        #expect(LeaderboardView.metrics.allSatisfy { !$0.isPerformance })
    }
}
