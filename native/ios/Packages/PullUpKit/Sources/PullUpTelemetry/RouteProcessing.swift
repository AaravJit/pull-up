import Foundation
import PullUpDomain

public enum RouteSimplifier {
    /// Ramer–Douglas–Peucker in a local equirectangular projection. Accurate
    /// to centimetres over a city-sized drive, which is all a map needs.
    public static func simplify(_ points: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard points.count > 2 else { return points }
        let origin = points[0]
        let cosLat = cos(origin.latitude * .pi / 180)
        let metersPerDegree = 111_320.0
        let projected = points.map {
            (($0.longitude - origin.longitude) * metersPerDegree * cosLat, ($0.latitude - origin.latitude) * metersPerDegree)
        }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]

        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let (ax, ay) = projected[start]
            let (bx, by) = projected[end]
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            var maxDistance = 0.0
            var index = start
            for i in (start + 1)..<end {
                let (px, py) = projected[i]
                let distance: Double
                if lengthSquared == 0 {
                    distance = hypot(px - ax, py - ay)
                } else {
                    let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
                    distance = hypot(px - (ax + t * dx), py - (ay + t * dy))
                }
                if distance > maxDistance {
                    maxDistance = distance
                    index = i
                }
            }
            if maxDistance > tolerance {
                keep[index] = true
                stack.append((start, index))
                stack.append((index, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}

/// Client-side preview of what a shared route will look like. The database
/// applies the same rules authoritatively in `share_drive_route`; this copy
/// exists so the user sees the result before sharing and so tests pin the
/// behaviour down.
public enum RoutePrivacy {
    public struct Options: Sendable {
        /// Distance removed from both ends regardless of zones.
        public var endpointTrim: Double
        /// Added to every zone's radius so the route never visibly "aims" at
        /// the zone's centre.
        public var zoneMargin: Double = 150

        public init(endpointTrim: Double, zoneMargin: Double = 150) {
            self.endpointTrim = endpointTrim
            self.zoneMargin = zoneMargin
        }
    }

    /// Returns the visible segments. Passing through a zone splits the route.
    public static func redact(_ points: [Coordinate], zones: [PrivacyZone], options: Options) -> [[Coordinate]] {
        guard points.count >= 2 else { return [] }

        // Cumulative distance along the route, for endpoint trimming.
        var along = [0.0]
        along.reserveCapacity(points.count)
        for i in 1..<points.count {
            along.append(along[i - 1] + points[i - 1].distance(to: points[i]))
        }
        let total = along.last ?? 0
        guard total > options.endpointTrim * 2 else { return [] }

        var segments: [[Coordinate]] = []
        var current: [Coordinate] = []
        for (i, point) in points.enumerated() {
            let trimmed = along[i] < options.endpointTrim || along[i] > total - options.endpointTrim
            let hidden = trimmed || zones.contains {
                $0.center.distance(to: point) <= $0.radiusMeters + options.zoneMargin
            }
            if hidden {
                if current.count >= 2 { segments.append(current) }
                current = []
            } else {
                current.append(point)
            }
        }
        if current.count >= 2 { segments.append(current) }
        return segments
    }
}

public enum SeriesDownsampler {
    /// Bucket-average to at most `maxPoints` for charting. Keeps the true
    /// peak of each bucket's speed so a short top-speed burst stays visible.
    public static func downsample(_ series: [SpeedPoint], maxPoints: Int) -> [SpeedPoint] {
        guard series.count > maxPoints, maxPoints > 1 else { return series }
        let bucketSize = Double(series.count) / Double(maxPoints)
        var result: [SpeedPoint] = []
        result.reserveCapacity(maxPoints)
        for bucket in 0..<maxPoints {
            let lower = Int(Double(bucket) * bucketSize)
            let upper = min(series.count, Int(Double(bucket + 1) * bucketSize))
            guard lower < upper else { continue }
            let slice = series[lower..<upper]
            let peak = slice.max { $0.speed < $1.speed }!
            let altitudes = slice.compactMap(\.altitude)
            result.append(SpeedPoint(
                offset: slice.map(\.offset).reduce(0, +) / Double(slice.count),
                speed: peak.speed,
                altitude: altitudes.isEmpty ? nil : altitudes.reduce(0, +) / Double(altitudes.count)
            ))
        }
        return result
    }
}
