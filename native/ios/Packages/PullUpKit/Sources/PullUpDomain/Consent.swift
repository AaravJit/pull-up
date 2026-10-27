import Foundation

/// Where the signed-in account stands on the two things the server requires
/// before it may publish anything (`my_consent_status`,
/// supabase/migrations/20261025000400): a passing minimum-age check and
/// acceptance of the current Terms and Community Guidelines. The server
/// refuses writes without them (SQLSTATE PUC02 / PUC01) whatever the app shows.
public struct ConsentStatus: Hashable, Sendable, Decodable {
    public enum AgeCheck: String, Hashable, Sendable, Decodable {
        case meetsMinimum = "meets_minimum"
        case underMinimum = "under_minimum"
    }

    /// The current version: the terms' "Last updated" date, e.g. 2026-10-27.
    public var termsVersion: String
    /// What changed, for people asked to accept again; may be empty.
    public var termsSummary: String
    public var termsAccepted: Bool
    /// The last version this account accepted, if any.
    public var acceptedVersion: String?
    public var minimumAge: Int
    /// Nil until the age question is answered (or after the minimum rose).
    public var ageCheck: AgeCheck?

    public init(
        termsVersion: String, termsSummary: String = "", termsAccepted: Bool, acceptedVersion: String? = nil,
        minimumAge: Int = 13, ageCheck: AgeCheck?
    ) {
        self.termsVersion = termsVersion
        self.termsSummary = termsSummary
        self.termsAccepted = termsAccepted
        self.acceptedVersion = acceptedVersion
        self.minimumAge = minimumAge
        self.ageCheck = ageCheck
    }

    enum CodingKeys: String, CodingKey {
        case termsVersion = "terms_version"
        case termsSummary = "terms_summary"
        case termsAccepted = "terms_accepted"
        case acceptedVersion = "accepted_version"
        case minimumAge = "minimum_age"
        case ageCheck = "age_check"
    }

    public var isUnderMinimum: Bool { ageCheck == .underMinimum }
    public var needsAgeCheck: Bool { ageCheck == nil }
    public var needsTerms: Bool { !termsAccepted }
    /// True when this account accepted an earlier version, so the app says
    /// "updated" rather than introducing the rules for the first time.
    public var isTermsUpdate: Bool { needsTerms && acceptedVersion != nil }
    public var isSatisfied: Bool { ageCheck == .meetsMinimum && termsAccepted }

    /// "October 27, 2026" for a "2026-10-27" version; the raw version otherwise.
    public var termsDateText: String {
        let parts = termsVersion.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return termsVersion }
        return date.formatted(.dateTime.year().month(.wide).day())
    }
}

/// The minimum-age question. The date of birth is used on the phone only:
/// the app sends the server whether the person meets the minimum, never the
/// date. A self-declared answer isn't verified; see the migration's notes.
public enum AgeGate {
    /// Whole years between `birthDate` and `now`, in the Gregorian calendar.
    public static func age(birthDate: Date, now: Date = .now, calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        calendar.dateComponents([.year], from: calendar.startOfDay(for: birthDate), to: now).year ?? 0
    }

    public static func meetsMinimum(birthDate: Date, minimumAge: Int, now: Date = .now, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        birthDate <= now && age(birthDate: birthDate, now: now, calendar: calendar) >= minimumAge
    }

    /// Oldest date the picker offers.
    public static func earliestBirthDate(now: Date = .now, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        calendar.date(byAdding: .year, value: -120, to: now) ?? now
    }
}
