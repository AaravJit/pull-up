import Foundation
import Testing
import PullUpDomain

@Suite("Domain")
struct DomainTests {
    @Test func speedConversions() {
        #expect(abs(SpeedUnit.mph.speed(fromMetersPerSecond: Conversions.sixtyMphInMps) - 60) < 0.0001)
        #expect(abs(SpeedUnit.kmh.speed(fromMetersPerSecond: Conversions.hundredKmhInMps) - 100) < 0.0001)
        #expect(abs(SpeedUnit.mph.distance(fromMeters: 1_609.344) - 1) < 1e-9)
        #expect(abs(SpeedUnit.mph.elevation(fromMeters: 100) - 328.084) < 0.001)
    }

    @Test func haversineMatchesKnownDistance() {
        // Sacramento Capitol to San Francisco Ferry Building ≈ 117.2 km great-circle.
        let capitol = Coordinate(latitude: 38.5767, longitude: -121.4934)
        let ferry = Coordinate(latitude: 37.7955, longitude: -122.3937)
        let d = capitol.distance(to: ferry)
        #expect(abs(d - 117_204) < 50)
    }

    @Test func visibilityOrdering() {
        #expect(Visibility.private.openness < Visibility.friends.openness)
        #expect(Visibility.friends.openness < Visibility.public.openness)
    }

    @Test func privacyDefaultsAreConservative() {
        let settings = PrivacySettings()
        #expect(settings.driveHistoryVisibility == .private)
        #expect(settings.allowRouteSharing == false)
        #expect(settings.leaderboardOptIn == false)
        #expect(settings.performanceLeaderboardOptIn == false)
        #expect(settings.showEventAttendance == false)
    }

    @Test func vehicleDecodesFromBackendJSON() throws {
        let json = """
        {"id":"7d0f4a5e-1b7a-4f0e-9a51-3f1c2d6a7b80","owner_id":"0b6f3e3e-9c1d-4b6a-8f6e-2a1d3c4b5e6f",
         "kind":"motorcycle","body_style":"naked","make":"Yamaha","model":"MT-09","year":2019,"trim":"SP",
         "nickname":"","mileage":12000,"mileage_unit":"mph","summary":"","visibility":"friends",
         "cover_photo_path":null,"identity_color":"gulf","position":1,"is_archived":false}
        """
        let vehicle = try JSONDecoder().decode(Vehicle.self, from: Data(json.utf8))
        #expect(vehicle.kind == .motorcycle)
        #expect(vehicle.bodyStyle == .naked)
        #expect(vehicle.displayName == "2019 Yamaha MT-09")
        #expect(vehicle.identityColor == .gulf)
    }

    @Test func bodyStylesBelongToTheirKind() {
        #expect(BodyStyle.styles(for: .motorcycle).allSatisfy { $0 == .other || $0.kind == .motorcycle })
        #expect(BodyStyle.styles(for: .car).contains(.suv))
        #expect(!BodyStyle.styles(for: .car).contains(.cruiser))
    }

    @Test func meetLiveWindow() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var meet = Meet(hostID: UUID(), title: "Sac Nights", kind: .meet, startsAt: start, endsAt: start.addingTimeInterval(7_200), venueName: "Sutter Lot", latitude: 38.57, longitude: -121.48)
        #expect(meet.isLive(at: start.addingTimeInterval(60)))
        #expect(!meet.isLive(at: start.addingTimeInterval(-60)))
        meet.cancelledAt = start
        #expect(!meet.isLive(at: start.addingTimeInterval(60)))
    }
}
