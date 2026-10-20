import Foundation
import Testing
@testable import PullUpTelemetry
import PullUpDomain

@Suite("Telemetry engine")
struct TelemetryEngineTests {
    let factory = TrackFactory()

    @Test func constantSpeedProducesExpectedDistanceAndAverages() {
        let speeds = [Double](repeating: 20, count: 61) // 60 s at 20 m/s
        let engine = TelemetryEngine.replay(factory.samples(speeds: speeds), startedAt: factory.start)
        let summary = engine.summary(endedAt: factory.start.addingTimeInterval(60))

        #expect(abs(summary.distanceMeters - 1_200) < 2)
        #expect(abs((summary.averageMovingSpeed ?? 0) - 20) < 0.1)
        #expect(abs((summary.topSpeed ?? 0) - 20) < 0.001)
        #expect(abs(summary.movingSeconds - 60) < 0.001)
        #expect(summary.stoppedSeconds < 0.001)
        #expect(summary.rejectedSamples == 0)
        #expect(summary.gapDistanceMeters == 0)
    }

    @Test func singleSpeedSpikeNeverBecomesTopSpeed() {
        var samples = factory.samples(speeds: [Double](repeating: 25, count: 30))
        samples[15].speed = 70 // one bogus Doppler reading
        samples[15].speedAccuracy = 3 // forgiving tolerance keeps it past the acceleration gate
        let engine = TelemetryEngine.replay(samples, startedAt: factory.start)
        let top = engine.summary(endedAt: factory.start.addingTimeInterval(30)).topSpeed ?? 0
        #expect(top < 26)
    }

    @Test func parkedJitterDoesNotAccumulateDistance() {
        // Five minutes parked, fixes wandering ±4 m around the same spot.
        var samples: [LocationSample] = []
        for i in 0..<300 {
            let wobble = Double((i * 37) % 9) - 4
            samples.append(factory.sample(at: Double(i), northMeters: wobble, speed: 0, accuracy: 8))
        }
        let engine = TelemetryEngine.replay(samples, startedAt: factory.start)
        let summary = engine.summary(endedAt: factory.start.addingTimeInterval(300))
        #expect(summary.distanceMeters < 1)
        #expect(summary.movingSeconds == 0)
        #expect(abs(summary.stoppedSeconds - 300) < 0.001)
    }

    @Test func positionJumpIsRejected() {
        var samples = factory.samples(speeds: [Double](repeating: 15, count: 20))
        // Teleport 5 km for one fix (multipath / cached fix).
        samples[10].latitude += 5_000 / TrackFactory.metersPerDegreeLatitude
        samples[10].speed = -1
        samples[10].speedAccuracy = -1
        let engine = TelemetryEngine.replay(samples, startedAt: factory.start)
        let summary = engine.summary(endedAt: factory.start.addingTimeInterval(19))
        #expect(summary.rejectedSamples == 1)
        #expect(engine.rejectionCounts[.implausibleJump] == 1)
        #expect(abs(summary.distanceMeters - 285) < 3)
    }

    @Test func uncertainDopplerDoesNotRejectAMovingCar() {
        // iOS briefly reports ~0 m/s with a wide uncertainty while the car
        // keeps going at 20 m/s. The positions are fine, so none of them is
        // a jump.
        var samples = factory.samples(speeds: [Double](repeating: 20, count: 30))
        for i in 10..<15 {
            samples[i].speed = 0
            samples[i].speedAccuracy = 25
        }
        let engine = TelemetryEngine.replay(samples, startedAt: factory.start)
        let summary = engine.summary(endedAt: factory.start.addingTimeInterval(29))
        #expect(summary.rejectedSamples == 0)
        #expect(engine.relocks == 0)
        #expect(abs(summary.distanceMeters - 580) < 580 * 0.03)
    }

    @Test func poorAccuracyFixesAreRejected() {
        var samples = factory.samples(speeds: [Double](repeating: 10, count: 10))
        samples[3].horizontalAccuracy = 65 // Wi-Fi fix
        samples[4].horizontalAccuracy = -1 // invalid
        let engine = TelemetryEngine.replay(samples, startedAt: factory.start)
        #expect(engine.rejectionCounts[.poorAccuracy] == 1)
        #expect(engine.rejectionCounts[.invalidAccuracy] == 1)
    }

    @Test func signalGapIsBridgedAndDisclosed() {
        var samples = factory.samples(speeds: [Double](repeating: 20, count: 10))
        // Tunnel: nothing for 30 s, then resume 600 m further on.
        let resume = factory.samples(speeds: [Double](repeating: 20, count: 10)).map { s -> LocationSample in
            var s = s
            s.timestamp = s.timestamp.addingTimeInterval(39)
            s.latitude += (180 + 600) / TrackFactory.metersPerDegreeLatitude
            return s
        }
        samples += resume
        let engine = TelemetryEngine.replay(samples, startedAt: factory.start)
        let summary = engine.summary(endedAt: factory.start.addingTimeInterval(48))
        #expect(summary.longestSignalGap >= 30)
        #expect(abs(summary.gapDistanceMeters - 600) < 2)
        #expect(abs(summary.distanceMeters - (180 + 600 + 180)) < 3)
    }

    @Test func liveSnapshotReportsLostSignalAndHidesSpeed() {
        let engine = TelemetryEngine.replay(factory.samples(speeds: [Double](repeating: 20, count: 5)), startedAt: factory.start)
        let live = engine.live(at: factory.start.addingTimeInterval(30))
        guard case .lost = live.signalState else {
            Issue.record("expected lost signal, got \(live.signalState)")
            return
        }
        #expect(live.currentSpeed == nil)
        #expect(live.signal == .none)
        #expect(live.topSpeed != nil) // history is kept
    }

    @Test func derivedSpeedIsFlaggedWhenDopplerMissing() {
        var samples = factory.samples(speeds: [Double](repeating: 12, count: 5))
        for i in samples.indices { samples[i].speed = -1; samples[i].speedAccuracy = -1 }
        let engine = TelemetryEngine.replay(samples, startedAt: factory.start)
        let live = engine.live(at: factory.start.addingTimeInterval(4))
        #expect(live.currentSpeedIsDerived)
        #expect(abs((live.currentSpeed ?? 0) - 12) < 0.2)
        // Derived speeds never set a top speed.
        #expect(live.topSpeed == nil)
    }

    @Test func elevationHysteresisIgnoresNoise() {
        // Flat road with ±1.5 m noise, then a steady 30 m climb.
        var altitudes: [Double] = (0..<60).map { 100 + ($0 % 2 == 0 ? 1.5 : -1.5) }
        altitudes += (0..<60).map { 100 + Double($0) * 0.5 }
        altitudes += [Double](repeating: 130, count: 20)
        let samples = factory.samples(speeds: [Double](repeating: 15, count: altitudes.count), altitudes: altitudes)
        let engine = TelemetryEngine.replay(samples, startedAt: factory.start)
        let summary = engine.summary(endedAt: factory.start.addingTimeInterval(Double(altitudes.count)))
        #expect(summary.elevationGain > 24 && summary.elevationGain < 31)
        #expect(summary.elevationLoss < 3)
    }

    @Test func samplesBeforeStartAreIgnored() {
        var early = factory
        early.start = factory.start.addingTimeInterval(-60)
        let stale = early.sample(at: 0, northMeters: 0, speed: 0)
        var engine = TelemetryEngine(startedAt: factory.start)
        #expect(engine.ingest(stale) == .rejected(.outOfOrder))
    }

    @Test func stopAndGoSplitsMovingAndStoppedTime() {
        let speeds = [Double](repeating: 15, count: 60) + [Double](repeating: 0, count: 60) + [Double](repeating: 15, count: 61)
        let engine = TelemetryEngine.replay(factory.samples(speeds: speeds), startedAt: factory.start)
        let summary = engine.summary(endedAt: factory.start.addingTimeInterval(180))
        #expect(abs(summary.movingSeconds - 120) <= 2)
        #expect(abs(summary.stoppedSeconds - 60) <= 2)
    }
}
