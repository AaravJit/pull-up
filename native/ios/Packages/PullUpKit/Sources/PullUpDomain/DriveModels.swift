import Foundation

/// One raw fix from the location provider, already converted out of
/// Core Location so that telemetry logic never depends on it.
///
/// Negative values follow Core Location's convention for "invalid".
public struct LocationSample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    /// Metres above mean sea level.
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    /// Doppler-derived ground speed, m/s. Negative means unavailable.
    public var speed: Double
    public var speedAccuracy: Double
    public var course: Double

    public init(
        timestamp: Date, latitude: Double, longitude: Double, altitude: Double = 0,
        horizontalAccuracy: Double, verticalAccuracy: Double = -1,
        speed: Double = -1, speedAccuracy: Double = -1, course: Double = -1
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    public var hasValidSpeed: Bool { speed >= 0 && speedAccuracy >= 0 }
    public var hasValidAltitude: Bool { verticalAccuracy > 0 }
}

public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in metres (haversine, mean Earth radius).
    /// Mirrored exactly by `public.haversine_m` in the database so client and
    /// server agree on distances to well under a metre per segment.
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_008.8
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

/// How much a number should be trusted. Shown next to every derived figure
/// so the app never presents a phone-GPS estimate as a measurement.
public enum MeasurementQuality: String, Codable, Sendable, Comparable {
    /// Not enough clean data to say anything.
    case insufficient
    /// Derived from ~1 Hz phone GPS with interpolation. Indicative only.
    case estimate
    /// Clean, dense data that passed every consistency check. Still phone GPS.
    case consistent

    private var rank: Int {
        switch self {
        case .insufficient: 0
        case .estimate: 1
        case .consistent: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    public var label: String {
        switch self {
        case .insufficient: "Not enough data"
        case .estimate: "Estimate"
        case .consistent: "GPS consistent"
        }
    }
}

public struct AccelerationRun: Codable, Hashable, Sendable {
    public var startedAt: Date
    /// Seconds from rolling start to target speed.
    public var duration: Double
    public var targetSpeed: Double
    public var quality: MeasurementQuality
    /// Largest interval between fixes during the run. Above ~1.2 s the
    /// interpolation error dominates and the run is downgraded.
    public var maxSampleInterval: Double

    public init(startedAt: Date, duration: Double, targetSpeed: Double, quality: MeasurementQuality, maxSampleInterval: Double) {
        self.startedAt = startedAt
        self.duration = duration
        self.targetSpeed = targetSpeed
        self.quality = quality
        self.maxSampleInterval = maxSampleInterval
    }

    enum CodingKeys: String, CodingKey {
        case duration, quality
        case startedAt = "started_at"
        case targetSpeed = "target_speed"
        case maxSampleInterval = "max_sample_interval"
    }
}

/// Final statistics of a drive, all SI units.
public struct DriveSummary: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var distanceMeters: Double
    /// Portion of distance bridged across a signal gap (straight line).
    public var gapDistanceMeters: Double
    public var elapsedSeconds: Double
    public var movingSeconds: Double
    public var stoppedSeconds: Double
    public var topSpeed: Double?
    public var averageMovingSpeed: Double?
    public var elevationGain: Double
    public var elevationLoss: Double
    public var minAltitude: Double?
    public var maxAltitude: Double?
    public var zeroToSixty: AccelerationRun?
    public var acceptedSamples: Int
    public var rejectedSamples: Int
    public var longestSignalGap: Double

    public init(
        startedAt: Date, endedAt: Date, distanceMeters: Double, gapDistanceMeters: Double,
        elapsedSeconds: Double, movingSeconds: Double, stoppedSeconds: Double, topSpeed: Double?,
        averageMovingSpeed: Double?, elevationGain: Double, elevationLoss: Double,
        minAltitude: Double?, maxAltitude: Double?, zeroToSixty: AccelerationRun?,
        acceptedSamples: Int, rejectedSamples: Int, longestSignalGap: Double
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.gapDistanceMeters = gapDistanceMeters
        self.elapsedSeconds = elapsedSeconds
        self.movingSeconds = movingSeconds
        self.stoppedSeconds = stoppedSeconds
        self.topSpeed = topSpeed
        self.averageMovingSpeed = averageMovingSpeed
        self.elevationGain = elevationGain
        self.elevationLoss = elevationLoss
        self.minAltitude = minAltitude
        self.maxAltitude = maxAltitude
        self.zeroToSixty = zeroToSixty
        self.acceptedSamples = acceptedSamples
        self.rejectedSamples = rejectedSamples
        self.longestSignalGap = longestSignalGap
    }
}

public enum DriveValidationStatus: String, Codable, Sendable {
    case pending
    case validated
    case flagged
    case rejected

    public var label: String {
        switch self {
        case .pending: "Checking"
        case .validated: "Verified by server"
        case .flagged: "Under review"
        case .rejected: "Not eligible"
        }
    }
}

/// A drive as stored by the backend. Raw tracks live in a separate,
/// owner-only table and are never part of this record.
public struct Drive: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var ownerID: UserID
    public var vehicleID: UUID?
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var distanceMeters: Double
    public var movingSeconds: Double
    public var stoppedSeconds: Double
    public var elapsedSeconds: Double
    public var topSpeed: Double?
    public var averageMovingSpeed: Double?
    public var elevationGain: Double
    public var elevationLoss: Double
    public var zeroToSixtySeconds: Double?
    public var zeroToSixtyQuality: MeasurementQuality?
    public var visibility: Audience
    public var validationStatus: DriveValidationStatus
    public var hasSharedRoute: Bool

    public init(id: UUID, ownerID: UserID, vehicleID: UUID?, title: String, summary: DriveSummary, visibility: Audience = .private) {
        self.id = id
        self.ownerID = ownerID
        self.vehicleID = vehicleID
        self.title = title
        self.startedAt = summary.startedAt
        self.endedAt = summary.endedAt
        self.distanceMeters = summary.distanceMeters
        self.movingSeconds = summary.movingSeconds
        self.stoppedSeconds = summary.stoppedSeconds
        self.elapsedSeconds = summary.elapsedSeconds
        self.topSpeed = summary.topSpeed
        self.averageMovingSpeed = summary.averageMovingSpeed
        self.elevationGain = summary.elevationGain
        self.elevationLoss = summary.elevationLoss
        self.zeroToSixtySeconds = summary.zeroToSixty?.duration
        self.zeroToSixtyQuality = summary.zeroToSixty?.quality
        self.visibility = visibility
        self.validationStatus = .pending
        self.hasSharedRoute = false
    }

    enum CodingKeys: String, CodingKey {
        case id, title, visibility
        case ownerID = "owner_id"
        case vehicleID = "vehicle_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case distanceMeters = "distance_m"
        case movingSeconds = "moving_s"
        case stoppedSeconds = "stopped_s"
        case elapsedSeconds = "elapsed_s"
        case topSpeed = "top_speed_mps"
        case averageMovingSpeed = "avg_moving_speed_mps"
        case elevationGain = "elevation_gain_m"
        case elevationLoss = "elevation_loss_m"
        case zeroToSixtySeconds = "zero_to_sixty_s"
        case zeroToSixtyQuality = "zero_to_sixty_quality"
        case validationStatus = "validation_status"
        case hasSharedRoute = "has_shared_route"
    }
}

/// A place the user never wants revealed (home, work, a friend's house).
/// Shared routes are cut back so that they never enter or start near one.
public struct PrivacyZone: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var center: Coordinate
    public var radiusMeters: Double

    public init(id: UUID = UUID(), label: String, center: Coordinate, radiusMeters: Double) {
        self.id = id
        self.label = label
        self.center = center
        self.radiusMeters = radiusMeters
    }

    enum CodingKeys: String, CodingKey {
        case id, label
        case latitude = "lat"
        case longitude = "lon"
        case radiusMeters = "radius_m"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        center = Coordinate(latitude: try c.decode(Double.self, forKey: .latitude), longitude: try c.decode(Double.self, forKey: .longitude))
        radiusMeters = try c.decode(Double.self, forKey: .radiusMeters)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(center.latitude, forKey: .latitude)
        try c.encode(center.longitude, forKey: .longitude)
        try c.encode(radiusMeters, forKey: .radiusMeters)
    }
}
