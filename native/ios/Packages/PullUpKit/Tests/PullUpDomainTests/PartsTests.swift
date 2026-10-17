import Foundation
import Testing
import PullUpDomain

@Suite("Parts finder links")
struct PartsTests {
    private let gsxr = Vehicle(
        ownerID: UUID(), kind: .motorcycle, make: "Suzuki", model: "GSX-R750", year: 2001,
        trim: " ", nickname: "Blue thunder", mileage: 31_200
    )

    private func items(_ url: URL?) -> [String: String] {
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func vehicleTermsAreYearMakeModelTrimOnly() {
        #expect(PartsQuery.terms(for: gsxr) == "2001 Suzuki GSX-R750")
        let query = PartsQuery(vehicle: gsxr, part: "  front   brake pads ")
        #expect(query.keywords == "2001 Suzuki GSX-R750 front brake pads")
        #expect(!query.keywords.contains("Blue thunder"), "nicknames never leave the phone")
    }

    @Test func linkSearchesPartsAndAccessoriesOnEbay() throws {
        let url = try #require(EbaySearchLink.url(for: PartsQuery(vehicle: "2001 Suzuki GSX-R750", part: "chain & sprockets")))
        #expect(url.host() == "www.ebay.com")
        #expect(url.path() == "/sch/i.html")
        let q = items(url)
        #expect(q["_nkw"] == "2001 Suzuki GSX-R750 chain & sprockets")
        #expect(q["_sacat"] == "6028")
        #expect(q["LH_ItemCondition"] == nil)
        #expect(q["campid"] == nil, "no affiliate parameters without a campaign")
        #expect(url.absoluteString.contains("chain%20%26%20sprockets"), "the ampersand is encoded, not a new parameter")
    }

    @Test func plusSignsStayPartOfTheKeywords() {
        let url = EbaySearchLink.url(for: PartsQuery(part: "C+ pads"))
        #expect(url?.absoluteString.contains("_nkw=C%2B%20pads") == true)
    }

    @Test func conditionFilters() {
        #expect(items(EbaySearchLink.url(for: PartsQuery(part: "mirror", condition: .new)))["LH_ItemCondition"] == "1000")
        #expect(items(EbaySearchLink.url(for: PartsQuery(part: "mirror", condition: .used)))["LH_ItemCondition"] == "3000")
    }

    @Test func noPartNoLink() {
        #expect(EbaySearchLink.url(for: PartsQuery(vehicle: "2001 Suzuki GSX-R750", part: "   ")) == nil)
    }

    @Test func affiliateCampaignOnlyWhenValid() {
        #expect(AffiliateCampaign(id: nil) == nil)
        #expect(AffiliateCampaign(id: "") == nil)
        #expect(AffiliateCampaign(id: "12345") == nil)
        #expect(AffiliateCampaign(id: "53370xxxxx") == nil)
        let campaign = AffiliateCampaign(id: "5337000000")
        #expect(campaign != nil)
        let q = items(EbaySearchLink.url(for: PartsQuery(part: "oil filter"), campaign: campaign))
        #expect(q["campid"] == "5337000000")
        #expect(q["mkrid"] == "711-53200-19255-0")
    }

    @Test func keywordsAreCapped() {
        let query = PartsQuery(part: String(repeating: "turbo ", count: 100))
        #expect(query.keywords.count <= PartsQuery.maxLength)
    }

    @Test func suggestionsFitTheVehicleKind() {
        #expect(PartsQuery.suggestions(for: .motorcycle).contains("Chain and sprockets"))
        #expect(!PartsQuery.suggestions(for: .car).contains("Chain and sprockets"))
    }
}
