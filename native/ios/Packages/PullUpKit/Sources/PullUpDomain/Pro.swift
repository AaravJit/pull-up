import Foundation

/// Pull Up Pro plans. The product IDs must match App Store Connect; the
/// prices are placeholders until the product owner approves them, and live
/// prices always come from the App Store, never from this file.
public enum ProPlan: String, CaseIterable, Codable, Sendable, Identifiable {
    case monthly = "app.pullup.pro.monthly"
    case yearly = "app.pullup.pro.yearly"

    public var id: String { rawValue }
    public var productID: String { rawValue }

    public var label: String {
        switch self {
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    public var period: String {
        switch self {
        case .monthly: "month"
        case .yearly: "year"
        }
    }

    /// Placeholder shown only in demo mode and used by the local StoreKit
    /// configuration. Not a published price.
    public var placeholderPrice: Decimal {
        switch self {
        case .monthly: Decimal(string: "3.99")!
        case .yearly: Decimal(string: "29.99")!
        }
    }
}

/// What Pro adds. Everything else in Pull Up stays free.
public enum ProFeature: String, CaseIterable, Sendable, Identifiable {
    case speedometerFaces, accentPalettes, driveAnalytics, trackExport

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .speedometerFaces: "More speedometer faces"
        case .accentPalettes: "Extra accent colours"
        case .driveAnalytics: "Drive analytics"
        case .trackExport: "GPX and CSV export"
        }
    }

    public var detail: String {
        switch self {
        case .speedometerFaces: "The Ring face, alongside Sweep, Digital and Tape."
        case .accentPalettes: "Papaya and Acid for the cluster and accents."
        case .driveAnalytics: "Time spent in each speed band for every drive."
        case .trackExport: "Take your own drives to other apps and tools."
        }
    }

    public var symbol: String {
        switch self {
        case .speedometerFaces: "gauge.open.with.lines.needle.33percent"
        case .accentPalettes: "paintpalette"
        case .driveAnalytics: "chart.bar.xaxis"
        case .trackExport: "square.and.arrow.up"
        }
    }

    /// Stays free forever, listed on the paywall so nobody wonders.
    public static let freeForever = [
        "Speedometer and drive recording",
        "Garage, feed, meets and messages",
        "Privacy controls and protected places",
        "Leaderboards and drive history",
    ]
}

/// The person's Pro entitlement as the server records it. The server is the
/// source of truth; the app never decides on its own that someone is Pro.
public struct Entitlement: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case active
        case gracePeriod = "grace_period"
        case billingRetry = "billing_retry"
        case expired
        case revoked

        public var label: String {
            switch self {
            case .active: "Active"
            case .gracePeriod: "Payment issue (still active)"
            case .billingRetry: "Payment issue"
            case .expired: "Expired"
            case .revoked: "Refunded or revoked"
            }
        }
    }

    public var isPro: Bool
    public var status: Status?
    public var plan: ProPlan?
    public var expiresAt: Date?
    public var graceExpiresAt: Date?
    public var autoRenew: Bool
    /// "Production" or "Sandbox". Sandbox means a test purchase.
    public var environment: String?

    public init(
        isPro: Bool, status: Status? = nil, plan: ProPlan? = nil, expiresAt: Date? = nil,
        graceExpiresAt: Date? = nil, autoRenew: Bool = false, environment: String? = nil
    ) {
        self.isPro = isPro
        self.status = status
        self.plan = plan
        self.expiresAt = expiresAt
        self.graceExpiresAt = graceExpiresAt
        self.autoRenew = autoRenew
        self.environment = environment
    }

    public static let none = Entitlement(isPro: false)

    enum CodingKeys: String, CodingKey {
        case status, environment
        case isPro = "is_pro"
        case plan = "product_id"
        case expiresAt = "expires_at"
        case graceExpiresAt = "grace_expires_at"
        case autoRenew = "auto_renew"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isPro = try c.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:))
        plan = (try? c.decodeIfPresent(String.self, forKey: .plan)).flatMap(ProPlan.init(rawValue:))
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        graceExpiresAt = try c.decodeIfPresent(Date.self, forKey: .graceExpiresAt)
        autoRenew = try c.decodeIfPresent(Bool.self, forKey: .autoRenew) ?? false
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
    }
}

/// Why the server didn't record a purchase.
public enum SubscriptionError: LocalizedError, Equatable, Sendable {
    /// The App Store secrets aren't set on the server yet.
    case notConfigured
    /// Local StoreKit testing; Apple can't confirm these.
    case testEnvironment
    /// Bought for, or already recorded on, another Pull Up account.
    case otherAccount
    /// Apple has no record of it.
    case notFound
    /// Apple or the server couldn't be reached. Worth retrying.
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Pull Up Pro can't be activated yet because subscriptions aren't set up on the Pull Up server."
        case .testEnvironment: "This is a StoreKit test purchase, which the Pull Up server can't confirm with Apple."
        case .otherAccount: "This subscription belongs to a different Pull Up account. Sign in to that account to use it."
        case .notFound: "Apple has no record of this purchase."
        case let .unavailable(reason): "Pro couldn't be activated right now (\(reason)). It will retry automatically."
        }
    }

    /// Keep the StoreKit transaction unfinished so it's delivered again.
    public var isRetryable: Bool {
        switch self {
        case .notConfigured, .unavailable: true
        case .testEnvironment, .otherAccount, .notFound: false
        }
    }
}

/// Time spent in each speed band while moving, for the Pro analytics card.
public struct SpeedBand: Equatable, Sendable, Identifiable {
    /// Lower bound in the display unit; the band is [lower, lower + width).
    public var lower: Int
    public var width: Int
    public var seconds: Double

    public var id: Int { lower }
    public var upper: Int { lower + width }
}

public enum SpeedDistribution {
    /// Below this the vehicle counts as stopped (≈ 3.6 km/h).
    public static let movingThreshold = 1.0

    /// Buckets `(offset seconds, speed m/s)` samples into bands of `width`
    /// display units. Each sample counts for the time until the next one,
    /// capped at 5 s so a signal gap isn't credited to one band.
    public static func bands(
        offsets: [Double], speeds: [Double], unit: SpeedUnit, width: Int
    ) -> [SpeedBand] {
        precondition(offsets.count == speeds.count)
        guard offsets.count > 1, width > 0 else { return [] }
        var seconds: [Int: Double] = [:]
        for i in 0..<(offsets.count - 1) {
            let dt = min(5, max(0, offsets[i + 1] - offsets[i]))
            guard dt > 0, speeds[i] >= movingThreshold else { continue }
            let value = unit.speed(fromMetersPerSecond: speeds[i])
            let lower = Int(value / Double(width)) * width
            seconds[lower, default: 0] += dt
        }
        guard let top = seconds.keys.max() else { return [] }
        return stride(from: 0, through: top, by: width).map { SpeedBand(lower: $0, width: width, seconds: seconds[$0] ?? 0) }
    }
}

/// Your own track as GPX or CSV, for Pro export. Includes the full route,
/// protected places too, because it is your data leaving on your request.
public enum TrackExport {
    public enum Format: String, CaseIterable, Sendable {
        case gpx, csv
        public var fileExtension: String { rawValue }
        public var label: String { rawValue.uppercased() }
    }

    public static func render(_ track: [LocationSample], name: String, format: Format) -> String {
        switch format {
        case .gpx: gpx(track, name: name)
        case .csv: csv(track)
        }
    }

    public static func gpx(_ track: [LocationSample], name: String) -> String {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Pull Up" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(escape(name))</name>
            <trkseg>

        """
        for s in track {
            out += "      <trkpt lat=\"\(fixed(s.latitude, 7))\" lon=\"\(fixed(s.longitude, 7))\">"
            if s.hasValidAltitude { out += "<ele>\(fixed(s.altitude, 1))</ele>" }
            out += "<time>\(time.string(from: s.timestamp))</time>"
            if s.hasValidSpeed { out += "<extensions><speed>\(fixed(s.speed, 2))</speed></extensions>" }
            out += "</trkpt>\n"
        }
        out += """
            </trkseg>
          </trk>
        </gpx>

        """
        return out
    }

    public static func csv(_ track: [LocationSample]) -> String {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = "time,latitude,longitude,altitude_m,speed_mps,horizontal_accuracy_m,vertical_accuracy_m,speed_accuracy_mps\n"
        for s in track {
            let fields = [
                time.string(from: s.timestamp), fixed(s.latitude, 7), fixed(s.longitude, 7),
                s.hasValidAltitude ? fixed(s.altitude, 1) : "",
                s.hasValidSpeed ? fixed(s.speed, 2) : "",
                fixed(s.horizontalAccuracy, 1),
                s.verticalAccuracy > 0 ? fixed(s.verticalAccuracy, 1) : "",
                s.speedAccuracy >= 0 ? fixed(s.speedAccuracy, 2) : "",
            ]
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }

    private static func fixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
