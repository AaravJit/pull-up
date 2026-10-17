import Foundation
import PullUpDomain

/// Builds synthetic tracks heading due north from a fixed origin. One degree
/// of latitude is ~111,195 m on the haversine sphere the app uses.
struct TrackFactory {
    static let origin = Coordinate(latitude: 38.5816, longitude: -121.4944) // Sacramento
    static let metersPerDegreeLatitude = 6_371_008.8 * .pi / 180

    var start = Date(timeIntervalSince1970: 1_800_000_000)
    var accuracy = 5.0
    var speedAccuracy = 0.5
    var verticalAccuracy = 4.0

    /// Integrates a speed profile (m/s per second index) into samples.
    func samples(speeds: [Double], interval: Double = 1, altitudes: [Double]? = nil) -> [LocationSample] {
        var distance = 0.0
        var result: [LocationSample] = []
        for (i, speed) in speeds.enumerated() {
            if i > 0 { distance += (speeds[i - 1] + speed) / 2 * interval }
            result.append(sample(at: Double(i) * interval, northMeters: distance, speed: speed, altitude: altitudes?[i] ?? 20))
        }
        return result
    }

    func sample(at offset: Double, northMeters: Double, speed: Double, altitude: Double = 20, accuracy: Double? = nil) -> LocationSample {
        LocationSample(
            timestamp: start.addingTimeInterval(offset),
            latitude: Self.origin.latitude + northMeters / Self.metersPerDegreeLatitude,
            longitude: Self.origin.longitude,
            altitude: altitude,
            horizontalAccuracy: accuracy ?? self.accuracy,
            verticalAccuracy: verticalAccuracy,
            speed: speed,
            speedAccuracy: speed < 0 ? -1 : speedAccuracy,
            course: 0
        )
    }

    static func coordinate(northMeters: Double, eastMeters: Double = 0) -> Coordinate {
        let lat = origin.latitude + northMeters / metersPerDegreeLatitude
        let lon = origin.longitude + eastMeters / (metersPerDegreeLatitude * cos(origin.latitude * .pi / 180))
        return Coordinate(latitude: lat, longitude: lon)
    }
}
