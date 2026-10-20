import Foundation
import Testing
@testable import PullUpTelemetry
import PullUpDomain

/// Seeded noise, so every run replays exactly the same tracks.
struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    mutating func gaussian() -> Double {
        let u1 = max(uniform(), .leastNonzeroMagnitude)
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// What the phone reports during a synthetic drive, one entry per event.
enum ScenarioEvent {
    case fix(LocationSample)
    case stationary(Bool)
}

/// Builds a synthetic drive along a straight road heading north, second by
/// second, keeping the true distance alongside what the GPS would report.
///
/// GPS position error is strongly correlated from one fix to the next, so it
/// is modelled as a slow random walk (AR(1)) with `positionError` metres of
/// spread on each axis, not as independent noise per fix. These are
/// synthetic tracks: they test the algorithms, not a phone's GPS.
struct ScenarioBuilder {
    var factory = TrackFactory()
    var positionError = 3.0
    var correlation = 0.95
    var speedError = 0.2
    var accuracy: ClosedRange<Double> = 4...10

    private(set) var events: [ScenarioEvent] = []
    private(set) var trueDistance = 0.0
    private(set) var trueTopSpeed = 0.0
    private(set) var time = 0.0
    private(set) var speed = 0.0
    private var north = 0.0
    private var errorNorth = 0.0
    private var errorEast = 0.0
    private var noise: SeededNoise

    init(seed: UInt64) { noise = SeededNoise(seed: seed) }

    var date: Date { factory.start.addingTimeInterval(time) }

    /// Changes speed linearly to `target` over `seconds`. With `report`
    /// false the phone has no fix (tunnel, garage).
    mutating func drive(to target: Double, over seconds: Int, report: Bool = true) {
        let initial = speed
        for i in 1...max(1, seconds) {
            let next = initial + (target - initial) * Double(i) / Double(max(1, seconds))
            let step = (speed + next) / 2
            north += step
            trueDistance += step
            speed = next
            trueTopSpeed = max(trueTopSpeed, speed)
            time += 1
            if report { emit() } else { drift() }
        }
    }

    mutating func hold(_ seconds: Int, report: Bool = true) {
        drive(to: speed, over: seconds, report: report)
    }

    /// Stopped for `seconds`. With `pauseAfter`, iOS pauses updates once the
    /// phone has been still that long, as it does at lights.
    mutating func stop(for seconds: Int, pauseAfter: Int? = nil) {
        speed = 0
        var paused = false
        for i in 1...seconds {
            time += 1
            if let pauseAfter, i > pauseAfter {
                if !paused {
                    events.append(.stationary(true))
                    paused = true
                }
                drift()
            } else {
                emit()
            }
        }
        if paused { events.append(.stationary(false)) }
    }

    /// One extra fix half a second after the last, displaced sideways
    /// (multipath off a building, a bad first fix). The car doesn't move.
    mutating func outlier(east meters: Double, accuracy: Double = 15) {
        let c = TrackFactory.coordinate(northMeters: north + errorNorth, eastMeters: errorEast + meters)
        events.append(.fix(sample(at: time + 0.5, coordinate: c, accuracy: accuracy, speed: speed)))
    }

    private mutating func drift() {
        let k = (1 - correlation * correlation).squareRoot()
        errorNorth = correlation * errorNorth + k * positionError * noise.gaussian()
        errorEast = correlation * errorEast + k * positionError * noise.gaussian()
    }

    private mutating func emit() {
        drift()
        let c = TrackFactory.coordinate(northMeters: north + errorNorth, eastMeters: errorEast)
        let horizontal = accuracy.lowerBound + (accuracy.upperBound - accuracy.lowerBound) * noise.uniform()
        let reported = max(0, speed + (speed < 0.3 ? 0.1 : speedError) * noise.gaussian())
        events.append(.fix(sample(at: time, coordinate: c, accuracy: horizontal, speed: reported)))
    }

    private func sample(at offset: Double, coordinate: Coordinate, accuracy: Double, speed: Double) -> LocationSample {
        LocationSample(
            timestamp: factory.start.addingTimeInterval(offset),
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            altitude: 20, horizontalAccuracy: accuracy, verticalAccuracy: 4,
            speed: speed, speedAccuracy: 0.5, course: 0
        )
    }

    func run(upTo count: Int? = nil) -> TelemetryEngine {
        var engine = TelemetryEngine(startedAt: factory.start)
        for event in events.prefix(count ?? events.count) {
            switch event {
            case let .fix(sample): engine.ingest(sample)
            case let .stationary(still): engine.noteStationary(still)
            }
        }
        return engine
    }

    var stationaryPauses: [Date] {
        var result: [Date] = []
        var last: Date?
        for event in events {
            switch event {
            case let .fix(sample): last = sample.timestamp
            case .stationary(true): result.append((last ?? factory.start).addingTimeInterval(0.5))
            case .stationary(false): break
            }
        }
        return result
    }
}

/// End-to-end drives replayed through the engine. Each reports one line with
/// its measured error; `docs/TELEMETRY_VALIDATION.md` records them.
@Suite("Replay scenarios")
struct ScenarioTests {
    @discardableResult
    private func report(_ name: String, _ builder: ScenarioBuilder, _ engine: TelemetryEngine) -> (summary: DriveSummary, error: Double) {
        let summary = engine.summary(endedAt: builder.date)
        let error = (summary.distanceMeters - builder.trueDistance) / builder.trueDistance * 100
        let line = String(
            format: "SCENARIO %@: true %.0f m, measured %.0f m (%+.2f%%), bridged %.0f m, longest gap %.0f s, top %.1f/%.1f m/s, moving %.0f s, accepted %d, rejected %d, relocks %d",
            name, builder.trueDistance, summary.distanceMeters, error, summary.gapDistanceMeters, summary.longestSignalGap,
            summary.topSpeed ?? 0, builder.trueTopSpeed, summary.movingSeconds, summary.acceptedSamples, summary.rejectedSamples, engine.relocks
        )
        print(line)
        // Test output printed in the simulator doesn't reach the result
        // bundle's console log, so CI reads the line from this attachment.
        Attachment.record(line, named: "scenario-\(name).txt")
        return (summary, error)
    }

    @Test func urbanBlocksWithLights() {
        var b = ScenarioBuilder(seed: 1)
        for block in 0..<8 {
            b.drive(to: 13, over: 8)
            b.hold(20 + block * 3)
            b.drive(to: 0, over: 6)
            b.stop(for: 25, pauseAfter: 3)
        }
        let engine = b.run()
        let (summary, error) = report("urban", b, engine)
        #expect(abs(error) < 3)
        #expect(summary.longestSignalGap == 0, "stops at lights are not signal loss")
        #expect(summary.gapDistanceMeters == 0)
        #expect((summary.topSpeed ?? 0) < b.trueTopSpeed + 1)
        #expect(summary.stoppedSeconds > 8 * 20)
    }

    @Test func highwayCruise() {
        var b = ScenarioBuilder(seed: 2)
        b.drive(to: 31, over: 25)
        for i in 0..<30 {
            b.hold(50)
            b.drive(to: i.isMultiple(of: 2) ? 33 : 29, over: 10)
        }
        let engine = b.run()
        let (summary, error) = report("highway", b, engine)
        #expect(abs(error) < 1)
        #expect(abs((summary.topSpeed ?? 0) - b.trueTopSpeed) < 1)
        #expect(summary.longestSignalGap == 0)
    }

    @Test func stopAndGoTraffic() {
        var b = ScenarioBuilder(seed: 3)
        for _ in 0..<40 {
            b.drive(to: 5, over: 5)
            b.hold(8)
            b.drive(to: 0, over: 4)
            b.stop(for: 6)
        }
        let engine = b.run()
        let (summary, error) = report("stop-and-go", b, engine)
        #expect(abs(error) < 5)
        #expect(summary.stoppedSeconds > 40 * 4)
    }

    @Test func tunnelIsBridgedAndDisclosed() throws {
        var b = ScenarioBuilder(seed: 4)
        b.drive(to: 22, over: 10)
        b.hold(60)
        let beforeTunnel = b.events.count
        let entered = b.date
        b.hold(90, report: false)
        b.hold(60)

        let inside = b.run(upTo: beforeTunnel).live(at: entered.addingTimeInterval(30))
        #expect(inside.signalState == .lost(since: entered))
        #expect(inside.currentSpeed == nil, "no speed is shown without a fix")

        let engine = b.run()
        let (summary, error) = report("tunnel", b, engine)
        #expect(abs(error) < 2)
        #expect(summary.longestSignalGap >= 90)
        #expect(abs(summary.gapDistanceMeters - 22 * 91) < 22 * 91 * 0.05)
    }

    @Test func multipathJumpsAddNoDistance() {
        var b = ScenarioBuilder(seed: 5)
        b.drive(to: 15, over: 8)
        b.hold(30)
        b.outlier(east: 60)
        b.hold(30)
        b.drive(to: 0, over: 6)
        b.stop(for: 20)
        b.outlier(east: 40)
        b.stop(for: 20)
        b.drive(to: 15, over: 8)
        b.hold(30)
        let engine = b.run()
        let (summary, error) = report("multipath", b, engine)
        #expect(abs(error) < 2)
        #expect((engine.rejectionCounts[.implausibleJump] ?? 0) + (engine.rejectionCounts[.implausibleAcceleration] ?? 0) >= 2)
        #expect((summary.topSpeed ?? 0) < b.trueTopSpeed + 1)
        #expect(engine.relocks == 0)
    }

    @Test func badFirstFixIsDropped() {
        var b = ScenarioBuilder(seed: 6)
        // A cached, wrong first fix 500 m away, then the real position.
        b.outlier(east: 500, accuracy: 30)
        b.stop(for: 10)
        b.drive(to: 14, over: 10)
        b.hold(60)
        let engine = b.run()
        let (summary, error) = report("bad first fix", b, engine)
        #expect(engine.relocks == 1)
        #expect(abs(error) < 2)
        let origin = TrackFactory.coordinate(northMeters: 0)
        #expect(engine.accepted.allSatisfy { abs($0.longitude - origin.longitude) < 0.001 }, "the bad fix is gone")
        #expect(summary.acceptedSamples > 70)
    }

    @Test func parkingLotLowSpeed() {
        var b = ScenarioBuilder(seed: 7)
        b.drive(to: 2, over: 3)
        b.hold(120)
        b.drive(to: 0, over: 3)
        b.stop(for: 10)
        let engine = b.run()
        let (_, error) = report("low speed", b, engine)
        #expect(abs(error) < 5)
    }

    @Test func twoHourMixedDrive() {
        var b = ScenarioBuilder(seed: 8)
        for leg in 0..<12 {
            for _ in 0..<4 {
                b.drive(to: 13, over: 8)
                b.hold(30)
                b.drive(to: 0, over: 6)
                b.stop(for: 20, pauseAfter: 3)
            }
            b.drive(to: 30, over: 20)
            b.hold(240)
            if leg.isMultiple(of: 3) { b.hold(30, report: false) }
            b.hold(60)
            b.drive(to: 0, over: 15)
            b.stop(for: 15)
        }
        #expect(b.time > 7000)
        let engine = b.run()
        let (summary, error) = report("two hours", b, engine)
        #expect(abs(error) < 2)
        #expect(summary.longestSignalGap >= 30 && summary.longestSignalGap < 40)

        // Recovery and retried uploads rebuild the drive from what was
        // stored; the result must match what was shown while recording.
        let replayed = TelemetryEngine.replay(engine.accepted, startedAt: b.factory.start, stationaryPauses: b.stationaryPauses)
        let again = replayed.summary(endedAt: b.date)
        #expect(abs(again.distanceMeters - summary.distanceMeters) < 1)
        #expect(again.longestSignalGap == summary.longestSignalGap)
        #expect(again.movingSeconds == summary.movingSeconds)
    }

    @Test func stationaryPauseIsAKnownZero() {
        var b = ScenarioBuilder(seed: 9)
        b.drive(to: 12, over: 8)
        b.hold(20)
        b.drive(to: 0, over: 5)
        b.stop(for: 60, pauseAfter: 3)
        let paused = b.date
        var engine = b.run()
        // The pause is still open: iOS hasn't reported movement yet.
        engine.noteStationary(true)
        let live = engine.live(at: paused)
        #expect(live.signalState == .tracking)
        #expect(live.currentSpeed == 0)
        #expect(live.isMoving == false)
    }
}
