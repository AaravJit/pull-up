import Foundation
import Testing
import PullUpFeatures

@Suite("Public page links")
struct LegalLinksTests {
    /// native/ios, found from this file so the test reads the real config.
    private static let iosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PullUpFeaturesTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // PullUpKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // ios

    private static let settings: [LegalLinks.Page: String] = [
        .privacy: "PULLUP_PRIVACY_POLICY", .support: "PULLUP_SUPPORT_URL",
        .terms: "PULLUP_TERMS_URL", .community: "PULLUP_COMMUNITY_URL",
    ]

    @Test func addsTheSchemeAndRejectsUnsetOrUnsafeValues() {
        #expect(LegalLinks.url(from: "github.com/AaravJit/pull-up/blob/main/docs/public/terms.md")?.absoluteString
                == "https://github.com/AaravJit/pull-up/blob/main/docs/public/terms.md")
        #expect(LegalLinks.url(from: "https://github.com/AaravJit/pull-up")?.absoluteString == "https://github.com/AaravJit/pull-up")
        #expect(LegalLinks.url(from: nil) == nil)
        #expect(LegalLinks.url(from: "  ") == nil)
        #expect(LegalLinks.url(from: "$(PULLUP_TERMS_URL)") == nil)
        #expect(LegalLinks.url(from: "http://github.com/x") == nil)
        #expect(LegalLinks.url(from: "https:") == nil)
    }

    @Test func aBundleWithoutTheKeysGivesNoLinks() {
        // The test runner's bundle has none of the app's keys.
        for page in LegalLinks.Page.allCases {
            #expect(LegalLinks.url(for: page, in: Bundle(for: Marker.self)) == nil)
        }
    }

    /// Every page has its build setting in Base.xcconfig, giving a public
    /// docs/public page, and Info.plist copies that setting into the key
    /// the app reads.
    @Test func everyPageIsConfiguredForEveryBuild() throws {
        let config = try String(contentsOf: Self.iosRoot.appendingPathComponent("Config/Base.xcconfig"), encoding: .utf8)
        let plistData = try Data(contentsOf: Self.iosRoot.appendingPathComponent("PullUp/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        for page in LegalLinks.Page.allCases {
            let setting = try #require(Self.settings[page])
            let line = config.split(separator: "\n").first { $0.hasPrefix("\(setting) =") }
            let value = line.map { $0.dropFirst(setting.count + 2).trimmingCharacters(in: .whitespaces) }
            let url = try #require(LegalLinks.url(from: value), "\(setting) in Base.xcconfig")
            #expect(url.absoluteString.hasPrefix("https://github.com/AaravJit/pull-up/blob/main/docs/public/"))
            #expect(plist[page.infoPlistKey] as? String == "$(\(setting))", "Info.plist \(page.infoPlistKey)")
        }
    }

    private final class Marker {}
}
