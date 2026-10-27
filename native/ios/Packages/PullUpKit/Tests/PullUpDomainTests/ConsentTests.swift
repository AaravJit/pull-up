import Foundation
import Testing
@testable import PullUpDomain

@Suite("Terms and minimum age")
struct ConsentTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(timeZone: .current, year: year, month: month, day: day, hour: 12))!
    }

    @Test func decodesTheServerStatus() throws {
        let json = #"{"terms_version":"2026-10-27","terms_summary":"","terms_accepted":false,"accepted_version":null,"accepted_at":null,"minimum_age":13,"age_check":null}"#
        let status = try JSONDecoder().decode(ConsentStatus.self, from: Data(json.utf8))
        #expect(status.termsVersion == "2026-10-27")
        #expect(status.needsAgeCheck && status.needsTerms && !status.isSatisfied)
        #expect(!status.isTermsUpdate)
        #expect(status.minimumAge == 13)
    }

    @Test func satisfiedOnlyWithBoth() {
        let both = ConsentStatus(termsVersion: "2026-10-27", termsAccepted: true, ageCheck: .meetsMinimum)
        #expect(both.isSatisfied)
        #expect(!ConsentStatus(termsVersion: "2026-10-27", termsAccepted: true, ageCheck: nil).isSatisfied)
        #expect(!ConsentStatus(termsVersion: "2026-10-27", termsAccepted: false, ageCheck: .meetsMinimum).isSatisfied)
        let under = ConsentStatus(termsVersion: "2026-10-27", termsAccepted: true, ageCheck: .underMinimum)
        #expect(!under.isSatisfied && under.isUnderMinimum)
    }

    @Test func anEarlierAcceptanceMeansUpdatedTerms() {
        let status = ConsentStatus(termsVersion: "2026-12-01", termsSummary: "Clearer meet rules.", termsAccepted: false,
                                   acceptedVersion: "2026-10-27", ageCheck: .meetsMinimum)
        #expect(status.isTermsUpdate)
        #expect(status.termsDateText.contains("2026"))
    }

    @Test func ageIsCountedFromTheBirthday() {
        let now = date(2026, 10, 27)
        #expect(AgeGate.meetsMinimum(birthDate: date(2013, 10, 27), minimumAge: 13, now: now, calendar: calendar))
        #expect(!AgeGate.meetsMinimum(birthDate: date(2013, 10, 28), minimumAge: 13, now: now, calendar: calendar))
        #expect(AgeGate.meetsMinimum(birthDate: date(1990, 1, 1), minimumAge: 13, now: now, calendar: calendar))
        // An untouched picker (today) or a future date never passes.
        #expect(!AgeGate.meetsMinimum(birthDate: now, minimumAge: 13, now: now, calendar: calendar))
        #expect(!AgeGate.meetsMinimum(birthDate: date(2030, 1, 1), minimumAge: 13, now: now, calendar: calendar))
    }
}
