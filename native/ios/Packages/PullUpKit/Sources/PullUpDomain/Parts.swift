import Foundation

/// A parts search. Stage A of the parts finder (docs/MARKETPLACE_FEASIBILITY.md):
/// Pull Up builds an eBay search link and opens it in Safari. No listing,
/// price or seller is fetched or shown in the app, because without eBay's
/// Buy API approval Pull Up has none.
public struct PartsQuery: Equatable, Sendable {
    public enum Condition: String, CaseIterable, Sendable, Identifiable {
        case any, new, used
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// "2001 Suzuki GSX-R750", editable before searching. May be empty.
    public var vehicle: String
    public var part: String
    public var condition: Condition

    public init(vehicle: String = "", part: String = "", condition: Condition = .any) {
        self.vehicle = vehicle
        self.part = part
        self.condition = condition
    }

    public init(vehicle: Vehicle, part: String = "") {
        self.init(vehicle: PartsQuery.terms(for: vehicle), part: part)
    }

    /// Year, make, model and trim. Never the nickname, mileage or anything
    /// personal: this text goes to eBay.
    public static func terms(for vehicle: Vehicle) -> String {
        [String(vehicle.year), vehicle.make, vehicle.model, vehicle.trim]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Longest keyword string sent, so a pasted paragraph can't build a
    /// silly URL.
    public static let maxLength = 200

    /// Exactly what will be sent to eBay, shown before searching.
    public var keywords: String {
        let joined = [vehicle, part]
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(joined.prefix(Self.maxLength))
    }

    public var canSearch: Bool { !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
