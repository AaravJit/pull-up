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
        #expect(PartsVehicle(gsxr).terms == "2001 Suzuki GSX-R750")
        let query = PartsQuery(vehicle: gsxr, part: "  front   brake pads ")
        #expect(query.keywords == "2001 Suzuki GSX-R750 front brake pads")
        #expect(!query.keywords.contains("Blue thunder"), "nicknames never leave the phone")
    }

    @Test func linkSearchesPartsAndAccessoriesOnEbay() throws {
        let url = try #require(EbaySearchLink.url(for: PartsQuery(vehicle: PartsVehicle(gsxr), part: "chain & sprockets")))
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
        #expect(EbaySearchLink.url(for: PartsQuery(vehicle: PartsVehicle(gsxr), part: "   ")) == nil)
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

    @Test func manualVehicleKeepsFieldOrderAndSkipsBlanks() {
        let bmw = PartsVehicle(year: " 2019 ", make: "BMW", model: "M340i", trim: "", engine: "B58  3.0")
        #expect(bmw.terms == "2019 BMW M340i B58 3.0")
        #expect(bmw.hasYearMakeModel)
        #expect(!PartsVehicle(make: "BMW").hasYearMakeModel)
        #expect(PartsVehicle(year: " ", make: "").isEmpty)
    }

    @Test func partNumberIsSearchedOnItsOwn() {
        var query = PartsQuery(vehicle: PartsVehicle(gsxr), part: "Brake pads", partNumber: "  59100-33E00 ", mode: .partNumber)
        #expect(query.keywords == "59100-33E00", "the vehicle and part name are left out")
        #expect(query.canSearch)
        query.source = .oem
        #expect(query.keywords == "59100-33E00 OEM")
        #expect(items(EbaySearchLink.url(for: query))["_nkw"] == "59100-33E00 OEM")
    }

    @Test func partNumbersNeedThreeLettersOrDigits() {
        #expect(!PartsQuery(partNumber: "12", mode: .partNumber).canSearch)
        #expect(!PartsQuery(partNumber: "- -/", mode: .partNumber).canSearch)
        #expect(PartsQuery(partNumber: "A12", mode: .partNumber).canSearch)
        #expect(!PartsQuery(part: "Brake pads", mode: .partNumber).canSearch, "a part name doesn't count as a number")
        let long = PartsQuery(partNumber: String(repeating: "9", count: 100), mode: .partNumber)
        #expect(long.normalizedPartNumber.count == PartsQuery.maxPartNumberLength)
    }

    @Test func sourceAddsOneWordOnly() {
        var query = PartsQuery(vehicle: PartsVehicle(gsxr), part: "mirror")
        #expect(query.keywords == "2001 Suzuki GSX-R750 mirror")
        query.source = .oem
        #expect(query.keywords == "2001 Suzuki GSX-R750 mirror OEM")
        query.source = .aftermarket
        #expect(query.keywords == "2001 Suzuki GSX-R750 mirror aftermarket")
    }

    @Test func fitmentIsNeverClaimed() {
        #expect(PartsQuery(vehicle: PartsVehicle(gsxr), part: "pads").fitment == .vehicle)
        #expect(PartsQuery(vehicle: PartsVehicle(make: "Suzuki"), part: "pads").fitment == .partialVehicle)
        #expect(PartsQuery(part: "pads").fitment == .noVehicle)
        #expect(PartsQuery(vehicle: PartsVehicle(gsxr), partNumber: "59100", mode: .partNumber).fitment == .partNumber)
        for fitment in [PartsQuery(vehicle: PartsVehicle(gsxr), part: "pads"), PartsQuery(part: "pads"),
                        PartsQuery(partNumber: "59100", mode: .partNumber), PartsQuery(vehicle: PartsVehicle(make: "Suzuki"), part: "pads")] {
            let note = fitment.fitmentNote.lowercased()
            #expect(!note.contains("guaranteed") && !note.contains("will fit") && !note.contains("verified"))
        }
    }
}
