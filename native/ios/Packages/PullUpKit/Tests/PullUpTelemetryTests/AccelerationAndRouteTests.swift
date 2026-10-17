import Foundation
import Testing
@testable import PullUpTelemetry
import PullUpDomain

@Suite("0–60 estimation")
struct AccelerationDetectorTests {
    let factory = TrackFactory()

    /// Constant acceleration from rest; 60 mph is reached at 26.8224 / a s.
    func launch(acceleration a: Double, interval: Double = 1, stillSamples: Int = 3, speedAccuracy: Double = 0.5) -> [LocationSample] {
        var f = factory
        f.speedAccuracy = speedAccuracy
        var speeds = [Double](repeating: 0, count: stillSamples)
        var t = 0.0
        while t <= 12 {
            t += interval
            speeds.append(a * t)
        }
        return f.samples(speeds: speeds, interval: interval)
    }

    @Test func denseCleanLaunchIsConsistentAndAccurate() throws {
        var detector = AccelerationDetector()
        let a = 5.0 // ≈ 0.51 g → 5.36 s
        var result: AccelerationRun?
        for s in launch(acceleration: a) { result = detector.ingest(s) ?? result }
        let run = try #require(result)
        // Launch start interpolates to the 1 mph crossing, so expect ~0.09 s less.
        let expected = (Conversions.sixtyMphInMps - 0.45) / a
        #expect(abs(run.duration - expected) < 0.05)
        #expect(run.quality == .consistent)
    }

    @Test func sparseFixesAreOnlyAnEstimate() {
        var detector = AccelerationDetector()
        var result: AccelerationRun?
        for s in launch(acceleration: 4, interval: 1.8) { result = detector.ingest(s) ?? result }
        #expect(result?.quality == .estimate)
    }

    @Test func rollingStartIsNotCounted() {
        var detector = AccelerationDetector()
        let samples = factory.samples(speeds: (0..<15).map { 10 + Double($0) * 2 })
        for s in samples { #expect(detector.ingest(s) == nil) }
        #expect(detector.best == nil)
    }

    @Test func liftingOffAbortsTheRun() {
        var detector = AccelerationDetector()
        let speeds: [Double] = [0, 0, 4, 8, 12, 16, 12, 16, 20, 24, 28]
        for s in factory.samples(speeds: speeds) { detector.ingest(s) }
        #expect(detector.best == nil)
    }

    @Test func impossibleLaunchIsDiscarded() {
        var detector = AccelerationDetector()
        let speeds: [Double] = [0, 0, 15, 30] // 0–60 in ~1.8 s
        for s in factory.samples(speeds: speeds) { detector.ingest(s) }
        #expect(detector.best == nil)
    }

    @Test func gapDuringRunAborts() {
        var detector = AccelerationDetector()
        var samples = launch(acceleration: 4)
        samples.remove(at: 6)
        samples.remove(at: 6)
        samples.remove(at: 6) // 4 s hole
        for s in samples { detector.ingest(s) }
        #expect(detector.best == nil)
    }

    @Test func bestRunIsKept() throws {
        var detector = AccelerationDetector()
        let slow = launch(acceleration: 3)
        var fastFactory = factory
        fastFactory.start = factory.start.addingTimeInterval(100)
        var speeds = [Double](repeating: 0, count: 3)
        for t in 1...10 { speeds.append(6 * Double(t)) }
        let fast = fastFactory.samples(speeds: speeds)
        for s in slow + fast { detector.ingest(s) }
        let best = try #require(detector.best)
        #expect(best.duration < 5)
    }
}

@Suite("Route processing")
struct RouteProcessingTests {
    @Test func simplifierKeepsCornersAndDropsCollinearPoints() {
        var points: [Coordinate] = []
        for i in 0...100 { points.append(TrackFactory.coordinate(northMeters: Double(i) * 10)) }
        for i in 1...100 { points.append(TrackFactory.coordinate(northMeters: 1_000, eastMeters: Double(i) * 10)) }
        let simplified = RouteSimplifier.simplify(points, tolerance: 2)
        #expect(simplified.count == 3)
        #expect(simplified[1] == points[100])
    }

    @Test func redactionTrimsEndpoints() {
        let points = (0...300).map { TrackFactory.coordinate(northMeters: Double($0) * 10) } // 3 km
        let segments = RoutePrivacy.redact(points, zones: [], options: .init(endpointTrim: 400))
        #expect(segments.count == 1)
        let first = segments[0].first!
        let last = segments[0].last!
        #expect(points[0].distance(to: first) >= 400)
        #expect(points.last!.distance(to: last) >= 400)
    }

    @Test func redactionRemovesEverythingNearAZoneAndSplitsTheRoute() {
        let points = (0...300).map { TrackFactory.coordinate(northMeters: Double($0) * 10) }
        let home = PrivacyZone(label: "Home", center: TrackFactory.coordinate(northMeters: 1_500), radiusMeters: 200)
        let segments = RoutePrivacy.redact(points, zones: [home], options: .init(endpointTrim: 100))
        #expect(segments.count == 2)
        for point in segments.flatMap({ $0 }) {
            #expect(home.center.distance(to: point) > 350)
        }
    }

    @Test func shortRoutesAreNotSharedAtAll() {
        let points = (0...50).map { TrackFactory.coordinate(northMeters: Double($0) * 10) } // 500 m
        #expect(RoutePrivacy.redact(points, zones: [], options: .init(endpointTrim: 400)).isEmpty)
    }

    @Test func downsampleKeepsPeaks() {
        var series = (0..<1_000).map { SpeedPoint(offset: Double($0), speed: 20, altitude: nil) }
        series[537].speed = 45
        let reduced = SeriesDownsampler.downsample(series, maxPoints: 100)
        #expect(reduced.count == 100)
        #expect(reduced.map(\.speed).max() == 45)
    }
}

@Suite("Signal quality")
struct SignalQualityTests {
    @Test(arguments: [(3.0, SignalQuality.excellent), (10, .good), (20, .fair), (40, .poor), (-1, .none)])
    func buckets(accuracy: Double, expected: SignalQuality) {
        #expect(SignalQuality(horizontalAccuracy: accuracy) == expected)
    }
}
