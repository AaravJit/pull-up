import Foundation

/// The public pages every build links to: privacy policy, support, service
/// and content terms, and community guidelines (docs/public/).
///
/// Each one is a build setting in `Config/Base.xcconfig`, written without
/// the scheme because xcconfig reads "//" as the start of a comment
/// (`PULLUP_PRIVACY_POLICY`, `PULLUP_SUPPORT_URL`, `PULLUP_TERMS_URL`,
/// `PULLUP_COMMUNITY_URL`), and copied into Info.plist. This adds https://
/// and returns nil when a value is empty, unexpanded or not a web address,
/// so a screen simply leaves the link out.
public enum LegalLinks {
    public enum Page: String, CaseIterable, Sendable {
        case privacy, support, terms, community

        /// The Info.plist key the build setting is copied into.
        public var infoPlistKey: String {
            switch self {
            case .privacy: "PullUpPrivacyPolicyURL"
            case .support: "PullUpSupportURL"
            case .terms: "PullUpTermsURL"
            case .community: "PullUpCommunityURL"
            }
        }

        /// A label for a link to the page.
        public var title: String {
            switch self {
            case .privacy: "Privacy Policy"
            case .support: "Support"
            case .terms: "Terms"
            case .community: "Community Guidelines"
            }
        }
    }

    public static var privacy: URL? { url(for: .privacy) }
    public static var support: URL? { url(for: .support) }
    public static var terms: URL? { url(for: .terms) }
    public static var community: URL? { url(for: .community) }

    /// The page's address from `bundle`'s Info.plist; nil when unset.
    public static func url(for page: Page, in bundle: Bundle = .main) -> URL? {
        url(from: bundle.object(forInfoDictionaryKey: page.infoPlistKey) as? String)
    }

    /// "github.com/owner/repo/page" or "https://github.com/owner/repo/page"
    /// gives the https address; anything else gives nil.
    public static func url(from value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        let url = URL(string: value.contains("://") ? value : "https://\(value)")
        // A dotted host: "https://pullup.app/x" left in an xcconfig reads as
        // "https:" ("//" starts a comment there) and would become "https://https:".
        return url?.scheme == "https" && (url?.host()?.contains(".") ?? false) ? url : nil
    }
}
