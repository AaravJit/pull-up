import Foundation

/// The vehicle a parts search is for: picked from the garage or typed in.
/// Every field is optional and editable, because a search still works with
/// only some of them.
public struct PartsVehicle: Equatable, Sendable {
    public var year: String
    public var make: String
    public var model: String
    public var trim: String
    /// Not stored on garage vehicles, so always typed in ("2.0 TDI", "750cc").
    public var engine: String

    public init(year: String = "", make: String = "", model: String = "", trim: String = "", engine: String = "") {
        self.year = year
        self.make = make
        self.model = model
        self.trim = trim
        self.engine = engine
    }

    /// Year, make, model and trim from the garage. Never the nickname,
    /// mileage or anything personal: this text goes to eBay.
    public init(_ vehicle: Vehicle) {
        self.init(year: vehicle.year > 0 ? String(vehicle.year) : "", make: vehicle.make, model: vehicle.model, trim: vehicle.trim)
    }

    private var fields: [String] { [year, make, model, trim, engine] }

    /// "2001 Suzuki GSX-R750 K1", in that order, blanks left out.
    public var terms: String { PartsQuery.tidy(fields) }

    public var isEmpty: Bool { terms.isEmpty }

    /// Year, make and model are what eBay listings are usually titled by.
    public var hasYearMakeModel: Bool {
        [year, make, model].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// A parts search. Stage A of the parts finder (docs/MARKETPLACE_FEASIBILITY.md):
/// Pull Up builds an eBay search link and opens it. No listing, price or
/// seller is fetched or shown in the app, because without eBay's Buy API
/// approval Pull Up has none, and nothing here checks fitment.
public struct PartsQuery: Equatable, Sendable {
    public enum Condition: String, CaseIterable, Sendable, Identifiable {
        case any, new, used
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// Searching by what the part is, or by its exact number.
    public enum Mode: String, CaseIterable, Sendable, Identifiable {
        case description, partNumber
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .description: "Part"
            case .partNumber: "Part number"
            }
        }
    }

    /// OEM parts come from the vehicle's maker or its supplier; aftermarket
    /// parts are other brands. eBay sellers label these themselves, so the
    /// choice only adds a word to the search.
    public enum Source: String, CaseIterable, Sendable, Identifiable {
        case any, oem, aftermarket
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .any: "Any"
            case .oem: "OEM"
            case .aftermarket: "Aftermarket"
            }
        }
        /// The word added to the search, as sellers usually write it.
        public var keyword: String? {
            switch self {
            case .any: nil
            case .oem: "OEM"
            case .aftermarket: "aftermarket"
            }
        }
    }

    public var vehicle: PartsVehicle
    public var part: String
    public var partNumber: String
    public var mode: Mode
    public var condition: Condition
    public var source: Source

    public init(
        vehicle: PartsVehicle = PartsVehicle(), part: String = "", partNumber: String = "",
        mode: Mode = .description, condition: Condition = .any, source: Source = .any
    ) {
        self.vehicle = vehicle
        self.part = part
        self.partNumber = partNumber
        self.mode = mode
        self.condition = condition
        self.source = source
    }

    public init(vehicle: Vehicle, part: String = "") {
        self.init(vehicle: PartsVehicle(vehicle), part: part)
    }

    /// Longest keyword string sent, so a pasted paragraph can't build a
    /// silly URL.
    public static let maxLength = 200

    /// Part numbers are short; anything longer was pasted by mistake.
    public static let maxPartNumberLength = 40

    static func tidy(_ words: [String]) -> String {
        words
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The part number as it will be searched: spaces collapsed, at most
    /// `maxPartNumberLength` characters.
    public var normalizedPartNumber: String {
        String(Self.tidy([partNumber]).prefix(Self.maxPartNumberLength))
    }

    /// Exactly what will be sent to eBay, shown before searching. A part
    /// number is searched on its own: listings rarely repeat the vehicle
    /// next to it, so adding the vehicle would hide matches.
    public var keywords: String {
        let words: [String] = switch mode {
        case .description: [vehicle.terms, part, source.keyword ?? ""]
        case .partNumber: [normalizedPartNumber, source.keyword ?? ""]
        }
        return String(Self.tidy(words).prefix(Self.maxLength))
    }

    public var canSearch: Bool {
        switch mode {
        case .description:
            !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .partNumber:
            // At least three letters or digits: "12" would match everything.
            normalizedPartNumber.filter { $0.isLetter || $0.isNumber }.count >= 3
        }
    }

    /// How much the search says about fit. None of these is a fitment
    /// check: Pull Up never verifies that a listing fits.
    public enum Fitment: Equatable, Sendable {
        case partNumber, vehicle, partialVehicle, noVehicle
    }

    public var fitment: Fitment {
        if mode == .partNumber { return .partNumber }
        if vehicle.hasYearMakeModel { return .vehicle }
        return vehicle.isEmpty ? .noVehicle : .partialVehicle
    }

    /// Shown next to the search so nobody mistakes a keyword match for a fit.
    public var fitmentNote: String {
        switch fitment {
        case .partNumber:
            "eBay matches the number as text. Listings that \u{201C}replace\u{201D} or \u{201C}fit\u{201D} it are the seller's claim; check it against your vehicle before you buy."
        case .vehicle:
            "Results match these words, not checked fitment. Confirm on the listing (eBay's compatibility list or the seller's details) that it fits your exact year, trim and engine."
        case .partialVehicle:
            "Add the year, make and model to narrow results to your vehicle. Either way, Pull Up doesn't check that a listing fits."
        case .noVehicle:
            "No vehicle in the search, so results aren't narrowed to one. Pull Up doesn't check that a listing fits."
        }
    }

    /// Common parts to start from, by vehicle kind.
    public static func suggestions(for kind: VehicleKind?) -> [String] {
        switch kind {
        case .motorcycle?: ["Brake pads", "Chain and sprockets", "Oil filter", "Spark plugs", "Air filter", "Levers", "Tyres"]
        case .car?, nil: ["Brake pads", "Oil filter", "Spark plugs", "Air filter", "Headlight", "Wiper blades", "Battery"]
        }
    }
}

/// eBay Partner Network campaign, set per build in Info.plist
/// (`PullUpEPNCampaignID`) once the account holder has joined EPN. Without
/// it, links carry no affiliate parameters and no disclosure is needed.
public struct AffiliateCampaign: Equatable, Sendable {
    public let id: String

    /// EPN campaign IDs are 10 digits; anything else is ignored.
    public init?(id: String?) {
        guard let id = id?.trimmingCharacters(in: .whitespaces), id.count == 10, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else {
            return nil
        }
        self.id = id
    }

    /// Shown next to the links whenever a campaign is set (EPN disclosure rules).
    public static let disclosure = "Links to eBay are affiliate links. Pull Up may earn a commission when you buy, at no extra cost to you. It never changes what you see."
}

public enum EbaySearchLink {
    /// eBay Motors ▸ Parts & Accessories.
    public static let partsCategory = "6028"

    /// A search on ebay.com for the query's keywords in Parts & Accessories,
    /// optionally new or used only, with EPN tracking when a campaign is set.
    public static func url(for query: PartsQuery, campaign: AffiliateCampaign? = nil) -> URL? {
        guard query.canSearch else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.ebay.com"
        components.path = "/sch/i.html"
        var items = [
            URLQueryItem(name: "_nkw", value: query.keywords),
            URLQueryItem(name: "_sacat", value: partsCategory),
        ]
        switch query.condition {
        case .any: break
        case .new: items.append(URLQueryItem(name: "LH_ItemCondition", value: "1000"))
        case .used: items.append(URLQueryItem(name: "LH_ItemCondition", value: "3000"))
        }
        if let campaign {
            // EPN's documented link parameters for ebay.com (rotation ID 711-53200-19255-0).
            items += [
                URLQueryItem(name: "mkcid", value: "1"),
                URLQueryItem(name: "mkrid", value: "711-53200-19255-0"),
                URLQueryItem(name: "siteid", value: "0"),
                URLQueryItem(name: "campid", value: campaign.id),
                URLQueryItem(name: "toolid", value: "10001"),
                URLQueryItem(name: "mkevt", value: "1"),
            ]
        }
        // Encode "+", "&" and "=" too, so a part like "C+ pads" or "nuts & bolts"
        // stays one keyword string.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#/")
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return components.url
    }
}
