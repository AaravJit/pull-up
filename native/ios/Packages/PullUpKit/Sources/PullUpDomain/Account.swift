import Foundation

/// The signed-in person's own account: what onboarding and Settings ▸ Account
/// need. Never shown to anyone else.
public struct AccountState: Hashable, Sendable {
    public enum SignInMethod: String, Hashable, Sendable, CaseIterable {
        case apple, google, email

        public var label: String {
            switch self {
            case .apple: "Apple"
            case .google: "Google"
            case .email: "Email"
            }
        }
    }

    public var id: UserID
    public var username: String
    public var displayName: String
    public var avatarPath: String?
    public var isOnboarded: Bool
    public var signInMethods: [SignInMethod]
    /// Apple's Hide My Email relay. The address is stored by the auth server
    /// only, and Pull Up never shows any email to other people.
    public var usesPrivateRelayEmail: Bool
    /// Set while a moderator has suspended the account
    /// (`my_moderation_status`). The server refuses its writes either way.
    public var suspension: Suspension?

    public init(
        id: UserID, username: String, displayName: String, avatarPath: String? = nil,
        isOnboarded: Bool, signInMethods: [SignInMethod], usesPrivateRelayEmail: Bool = false,
        suspension: Suspension? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarPath = avatarPath
        self.isOnboarded = isOnboarded
        self.signInMethods = signInMethods
        self.usesPrivateRelayEmail = usesPrivateRelayEmail
        self.suspension = suspension
    }

    /// The username the server assigns before onboarding.
    public var hasPlaceholderUsername: Bool { UsernameRules.isPlaceholder(username) }

    public static func isPrivateRelay(_ email: String?) -> Bool {
        email?.lowercased().hasSuffix("@privaterelay.appleid.com") ?? false
    }
}

/// A moderator's suspension of the signed-in account. While it lasts the
/// person can still read, change settings, sign out and delete the account;
/// posting, commenting, messaging, following, RSVPs and uploads are refused
/// by the server.
public struct Suspension: Hashable, Sendable {
    /// Nil until a moderator lifts it.
    public var until: Date?
    /// What the moderator told the person; may be empty.
    public var reason: String

    public init(until: Date?, reason: String) {
        self.until = until
        self.reason = reason
    }

    public var title: String {
        guard let until else { return "Your account is suspended" }
        return "Your account is suspended until \(until.formatted(date: .abbreviated, time: .shortened))"
    }

    public var message: String {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = "You can still look around, change settings, sign out or delete your account, but you can't post, comment, message, follow or RSVP."
        return why.isEmpty ? rest : "\(why) \(rest)"
    }
}

/// Result of checking a username, from the server (`username_status`) or
/// locally before asking it.
public enum UsernameStatus: String, Hashable, Sendable {
    case available
    case taken
    case reserved
    case format

    public var message: String {
        switch self {
        case .available: "Available"
        case .taken: "Someone already has this one"
        case .reserved: "This name is reserved"
        case .format: UsernameRules.formatHint
        }
    }
}

/// Mirrors `private.username_problem` in the accounts migration. The server
/// is the authority; this gives instant feedback while typing and powers the
/// demo backend.
public enum UsernameRules {
    public static let formatHint = "3–30 lowercase letters, numbers, _ or ., not starting or ending with _ or ."

    static let reserved: Set<String> = [
        "admin", "administrator", "root", "support", "help", "staff", "team", "moderator", "mod", "mods",
        "official", "verified", "security", "safety", "system", "api", "www", "app", "apple", "google",
        "ebay", "null", "undefined", "everyone", "settings", "me", "you", "anonymous",
    ]
    static let reservedPrefixes = ["pullup", "pull.up", "pull_up", "driver_"]

    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `nil` when the name passes every rule the client can check.
    public static func localProblem(_ raw: String) -> UsernameStatus? {
        let name = normalize(raw)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.")
        guard (3...30).contains(name.count), name.allSatisfy(allowed.contains) else { return .format }
        let separators: Set<Character> = ["_", "."]
        if let first = name.first, separators.contains(first) { return .format }
        if let last = name.last, separators.contains(last) { return .format }
        if zip(name, name.dropFirst()).contains(where: { separators.contains($0) && separators.contains($1) }) { return .format }
        if reserved.contains(name) || reservedPrefixes.contains(where: name.hasPrefix) { return .reserved }
        return nil
    }

    public static func isPlaceholder(_ name: String) -> Bool {
        name.wholeMatch(of: /driver_[0-9a-f]{10}/) != nil
    }

    /// A starting suggestion from the name Apple shares on first sign-in.
    public static func suggestion(from displayName: String) -> String {
        let folded = displayName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let words = folded.split(whereSeparator: { !allowed.contains($0) }).map(String.init)
        let joined = String(words.joined(separator: "_").prefix(30))
        return localProblem(joined) == nil ? joined : ""
    }
}
