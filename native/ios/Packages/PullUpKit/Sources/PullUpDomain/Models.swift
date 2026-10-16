import Foundation

// Wire-compatible models. Field names mirror the Supabase schema
// (supabase/migrations) via CodingKeys so that the future Android client can
// share the same contract. Keep these dumb: rules live in dedicated types.

public typealias UserID = UUID

/// Who may see a piece of content. Enforced by Postgres row-level security;
/// the client only uses it to render controls and explain consequences.
public enum Audience: String, Codable, CaseIterable, Sendable, Identifiable {
    case `public`
    case friends
    case `private`

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .public: "Public"
        case .friends: "Friends"
        case .private: "Only me"
        }
    }

    public var explanation: String {
        switch self {
        case .public: "Anyone on Pull Up can see this."
        case .friends: "Only people you follow who follow you back."
        case .private: "Nobody else. Not shown on your profile or in search."
        }
    }

    /// Ordering from most to least restrictive, used to prevent a post from
    /// being more visible than what it attaches.
    public var openness: Int {
        switch self {
        case .private: 0
        case .friends: 1
        case .public: 2
        }
    }
}

public enum VehicleKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case car
    case motorcycle

    public var id: String { rawValue }
    public var label: String { self == .car ? "Car" : "Motorcycle" }
    public var pluralLabel: String { self == .car ? "Cars" : "Motorcycles" }
}

public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id: UserID
    public var username: String
    public var displayName: String
    public var bio: String
    public var countryCode: String?
    public var regionCode: String?
    public var avatarPath: String?
    public var visibility: Audience
    /// Presentation choices the user makes for their own profile page.
    public var presentation: ProfilePresentation

    public init(
        id: UserID, username: String, displayName: String, bio: String = "",
        countryCode: String? = nil, regionCode: String? = nil, avatarPath: String? = nil,
        visibility: Audience = .public, presentation: ProfilePresentation = .init()
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.countryCode = countryCode
        self.regionCode = regionCode
        self.avatarPath = avatarPath
        self.visibility = visibility
        self.presentation = presentation
    }

    enum CodingKeys: String, CodingKey {
        case id, username, bio, visibility, presentation
        case displayName = "display_name"
        case countryCode = "country_code"
        case regionCode = "region_code"
        case avatarPath = "avatar_path"
    }
}

public struct ProfilePresentation: Codable, Hashable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Hero image of the featured vehicle dominates the header.
        case showcase
        /// Compact header, garage grid first.
        case garage
        /// Stats strip first, for people who mostly drive.
        case logbook

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .showcase: "Showcase"
            case .garage: "Garage"
            case .logbook: "Logbook"
            }
        }
    }

    public var layout: Layout
    public var featuredVehicleID: UUID?
    public var accent: AccentChoice?
    public var showStats: Bool

    public init(layout: Layout = .showcase, featuredVehicleID: UUID? = nil, accent: AccentChoice? = nil, showStats: Bool = true) {
        self.layout = layout
        self.featuredVehicleID = featuredVehicleID
        self.accent = accent
        self.showStats = showStats
    }

    enum CodingKeys: String, CodingKey {
        case layout, accent
        case featuredVehicleID = "featured_vehicle_id"
        case showStats = "show_stats"
    }
}

/// Accent palette the user can pick from. Raw values are stable identifiers
/// shared with the backend and Android; colours themselves live in the design
/// system.
public enum AccentChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case sodium      // warm amber, the original Pull Up colour
    case redline     // signal red
    case britishGreen
    case gulf        // pale blue
    case ultraviolet
    case titanium    // neutral, for people who want no colour

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sodium: "Sodium"
        case .redline: "Redline"
        case .britishGreen: "Heritage Green"
        case .gulf: "Gulf"
        case .ultraviolet: "Ultraviolet"
        case .titanium: "Titanium"
        }
    }
}

public struct Vehicle: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var ownerID: UserID
    public var kind: VehicleKind
    public var bodyStyle: BodyStyle
    public var make: String
    public var model: String
    public var year: Int
    public var trim: String
    public var nickname: String
    public var mileage: Int?
    public var mileageUnit: SpeedUnit
    public var summary: String
    public var visibility: Audience
    public var coverPhotoPath: String?
    /// Vehicle-specific identity: the colour used for this car's plate,
    /// gauge needle and garage tile. Stored as an accent identifier.
    public var identityColor: AccentChoice
    /// Manual sort position in the garage.
    public var position: Int
    public var isArchived: Bool

    public init(
        id: UUID = UUID(), ownerID: UserID, kind: VehicleKind, bodyStyle: BodyStyle? = nil, make: String, model: String, year: Int,
        trim: String = "", nickname: String = "", mileage: Int? = nil, mileageUnit: SpeedUnit = .mph,
        summary: String = "", visibility: Audience = .public, coverPhotoPath: String? = nil,
        identityColor: AccentChoice = .sodium, position: Int = 0, isArchived: Bool = false
    ) {
        self.id = id
        self.ownerID = ownerID
        self.kind = kind
        self.bodyStyle = bodyStyle ?? (kind == .car ? .coupe : .sport)
        self.make = make
        self.model = model
        self.year = year
        self.trim = trim
        self.nickname = nickname
        self.mileage = mileage
        self.mileageUnit = mileageUnit
        self.summary = summary
        self.visibility = visibility
        self.coverPhotoPath = coverPhotoPath
        self.identityColor = identityColor
        self.position = position
        self.isArchived = isArchived
    }

    public var title: String { "\(year) \(make) \(model)" }
    public var displayName: String { nickname.isEmpty ? title : nickname }

    enum CodingKeys: String, CodingKey {
        case id, kind, make, model, year, trim, nickname, mileage, summary, visibility, position
        case ownerID = "owner_id"
        case bodyStyle = "body_style"
        case mileageUnit = "mileage_unit"
        case coverPhotoPath = "cover_photo_path"
        case identityColor = "identity_color"
        case isArchived = "is_archived"
    }
}

public struct VehicleModification: Codable, Hashable, Sendable, Identifiable {
    public enum Category: String, Codable, CaseIterable, Sendable, Identifiable {
        case engine, intake, exhaust, forcedInduction = "forced_induction", tune, drivetrain
        case suspension, brakes, wheels, tires, aero, exterior, interior, lighting, electronics, other

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .forcedInduction: "Forced induction"
            default: rawValue.capitalized
            }
        }
    }

    public var id: UUID
    public var vehicleID: UUID
    public var category: Category
    public var title: String
    public var brand: String
    public var notes: String
    public var installedOn: Date?

    public init(id: UUID = UUID(), vehicleID: UUID, category: Category, title: String, brand: String = "", notes: String = "", installedOn: Date? = nil) {
        self.id = id
        self.vehicleID = vehicleID
        self.category = category
        self.title = title
        self.brand = brand
        self.notes = notes
        self.installedOn = installedOn
    }

    enum CodingKeys: String, CodingKey {
        case id, category, title, brand, notes
        case vehicleID = "vehicle_id"
        case installedOn = "installed_on"
    }
}

public struct VehiclePhoto: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var vehicleID: UUID
    public var storagePath: String
    public var position: Int

    public init(id: UUID = UUID(), vehicleID: UUID, storagePath: String, position: Int) {
        self.id = id
        self.vehicleID = vehicleID
        self.storagePath = storagePath
        self.position = position
    }

    enum CodingKeys: String, CodingKey {
        case id, position
        case vehicleID = "vehicle_id"
        case storagePath = "storage_path"
    }
}

/// Body style drives the silhouette shown wherever a vehicle has no photo.
public enum BodyStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    // Cars
    case sedan, coupe, hatchback, wagon, convertible, suv, truck, van
    // Motorcycles
    case sport, naked, cruiser, adventure, scooter
    case other

    public var id: String { rawValue }

    public var kind: VehicleKind {
        switch self {
        case .sport, .naked, .cruiser, .adventure, .scooter: .motorcycle
        default: .car
        }
    }

    public static func styles(for kind: VehicleKind) -> [BodyStyle] {
        allCases.filter { $0 == .other || $0.kind == kind }
    }

    public var label: String {
        switch self {
        case .suv: "SUV"
        case .sport: "Sport bike"
        case .naked: "Naked"
        case .adventure: "Adventure"
        default: rawValue.capitalized
        }
    }
}
