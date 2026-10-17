import Foundation
import Testing
import PullUpDomain

@Suite("Pull Up Pro")
struct ProTests {
    @Test func entitlementDecodesFromMyEntitlement() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = """
        {"is_pro":true,"status":"grace_period","product_id":"app.pullup.pro.yearly","expires_at":"2026-11-17T01:02:03Z",
         "grace_expires_at":"2026-11-23T01:02:03Z","auto_renew":true,"environment":"Sandbox"}
        """
        let e = try decoder.decode(Entitlement.self, from: Data(json.utf8))
        #expect(e.isPro)
        #expect(e.status == .gracePeriod)
        #expect(e.plan == .yearly)
        #expect(e.graceExpiresAt != nil)
    }

    @Test func emptyRowMeansNotPro() throws {
        let json = """
        {"is_pro":false,"status":null,"product_id":null,"expires_at":null,"grace_expires_at":null,"auto_renew":null,"environment":null}
        """
        let e = try JSONDecoder().decode(Entitlement.self, from: Data(json.utf8))
        #expect(e == .none)
    }

    @Test func unknownProductOrStatusDoesNotUnlockAnything() throws {
        let json = """
        {"is_pro":false,"status":"lifetime","product_id":"app.pullup.pro.forever"}
        """
        let e = try JSONDecoder().decode(Entitlement.self, from: Data(json.utf8))
        #expect(!e.isPro)
        #expect(e.status == nil)
        #expect(e.plan == nil)
    }

    @Test func productIDsMatchTheServer() {
        #expect(ProPlan.allCases.map(\.productID) == ["app.pullup.pro.monthly", "app.pullup.pro.yearly"])
        #expect(ProPlan.monthly.placeholderPrice == Decimal(string: "3.99"))
    }

    @Test func retryableErrorsKeepTheTransaction() {
        #expect(SubscriptionError.notConfigured.isRetryable)
        #expect(SubscriptionError.unavailable("offline").isRetryable)
        #expect(!SubscriptionError.otherAccount.isRetryable)
        #expect(!SubscriptionError.testEnvironment.isRetryable)
    }

    @Test func proAccentsStayOutOfVehicleColours() {
        #expect(AccentChoice.standard.allSatisfy { !$0.isPro })
        #expect(AccentChoice.allCases.filter(\.isPro) == [.papaya, .acid])
    }

    @Test func speedBandsCountMovingTimeOnly() {
        // 10 s at 35 mph, 10 s stopped, then 45 mph across a 60 s gap that counts as 5 s.
        let mph = 0.44704
        var offsets: [Double] = []
        var speeds: [Double] = []
        for i in 0..<10 { offsets.append(Double(i)); speeds.append(35 * mph) }
        for i in 10..<20 { offsets.append(Double(i)); speeds.append(0) }
        for i in 20..<25 { offsets.append(Double(i)); speeds.append(45 * mph) }
        offsets.append(85); speeds.append(45 * mph)
        offsets.append(86); speeds.append(0)
        let bands = SpeedDistribution.bands(offsets: offsets, speeds: speeds, unit: .mph, width: 10)
        #expect(bands.map(\.lower) == [0, 10, 20, 30, 40])
        #expect(bands.first { $0.lower == 30 }?.seconds == 10)
        #expect(bands.first { $0.lower == 40 }?.seconds == 10)
        #expect(bands.first { $0.lower == 0 }?.seconds == 0)
    }

    @Test func gpxAndCsvExport() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let track = [
            LocationSample(timestamp: start, latitude: 38.5816, longitude: -121.4944, altitude: 9, horizontalAccuracy: 5, verticalAccuracy: 4, speed: 12.5, speedAccuracy: 0.5),
            LocationSample(timestamp: start.addingTimeInterval(1), latitude: 38.5817, longitude: -121.4945, horizontalAccuracy: 6),
        ]
        let gpx = TrackExport.gpx(track, name: "Levee <loop> & back")
        #expect(gpx.hasPrefix("<?xml version=\"1.0\""))
        #expect(gpx.contains("<name>Levee &lt;loop&gt; &amp; back</name>"))
        #expect(gpx.contains("<trkpt lat=\"38.5816000\" lon=\"-121.4944000\"><ele>9.0</ele>"))
        #expect(gpx.components(separatedBy: "<trkpt").count == 3)
        #expect(!gpx.components(separatedBy: "\n").filter { $0.contains("38.5817000") }.first!.contains("<ele>"), "no altitude when it's invalid")
        let csv = TrackExport.csv(track).split(separator: "\n")
        #expect(csv.count == 3)
        #expect(csv[0].hasPrefix("time,latitude,longitude"))
        #expect(csv[1].hasSuffix(",38.5816000,-121.4944000,9.0,12.50,5.0,4.0,0.50"))
        #expect(csv[2].hasSuffix(",38.5817000,-121.4945000,,,6.0,,"))
    }
}
