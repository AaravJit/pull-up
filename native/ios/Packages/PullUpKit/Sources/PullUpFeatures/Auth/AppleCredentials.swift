import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// Remembers which Apple ID signed in on this device, so the app can notice
/// when the person stops using Sign in with Apple for Pull Up (Settings ▸
/// Apple Account ▸ Sign in with Apple ▸ Stop Using) and sign out locally.
///
/// The value is Apple's opaque, app-scoped user identifier, not an email. It
/// lives in the Keychain, readable only by this app on this device.
protocol AppleCredentialChecking: Sendable {
    func storedUserID() -> String?
    func store(userID: String?)
    func state(for userID: String) async -> AppleCredentialState
}

enum AppleCredentialState: Sendable, Equatable {
    case authorized
    /// Revoked by the person, or the Apple ID no longer has a credential for
    /// Pull Up (signed out of the Apple Account, or account deleted).
    case revoked
    /// Couldn't tell (no network, simulator without an Apple Account).
    case unknown
}

struct SystemAppleCredentials: AppleCredentialChecking {
    private static let service = "app.pullup.sign-in-with-apple"
    private static let account = "user-identifier"

    func storedUserID() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func store(userID: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let userID else { return }
        var item = base
        item[kSecValueData as String] = Data(userID.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func state(for userID: String) async -> AppleCredentialState {
        do {
            switch try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID) {
            case .authorized: return .authorized
            case .revoked, .notFound: return .revoked
            default: return .unknown
            }
        } catch {
            return .unknown
        }
    }
}

/// Nonce for Sign in with Apple. Apple embeds the SHA-256 of `raw` in the
/// identity token; Supabase checks it against `raw`, so a captured token
/// can't be replayed.
enum Nonce {
    static func random(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset[Int.random(in: 0..<charset.count, using: &generator)] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Plain-language messages for sign-in failures.
enum AuthMessages {
    static func apple(_ error: any Error) -> String? {
        if let error = error as? ASAuthorizationError {
            switch error.code {
            case .canceled: return nil
            case .unknown, .notInteractive:
                return "Sign in with Apple isn't available right now. Check that you're signed in to your Apple Account in Settings, then try again."
            case .failed, .invalidResponse, .notHandled:
                return "Apple couldn't complete the sign-in. Try again in a moment."
            default:
                return "Apple couldn't complete the sign-in. Try again in a moment."
            }
        }
        return server(error)
    }

    static func server(_ error: any Error) -> String {
        let text = error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("automatic account linking") {
            return "This email already belongs to a Pull Up account that signs in another way. Sign in that way, then add Apple in Settings ▸ Account."
        }
        if lower.contains("provider is not enabled") || lower.contains("unsupported provider") || lower.contains("unacceptable audience") {
            return "Sign in with Apple isn't switched on for this Pull Up server yet."
        }
        if lower.contains("invalid login credentials") {
            return "That email and password don't match an account."
        }
        if lower.contains("network") || lower.contains("offline") || lower.contains("internet") {
            return "You're offline. Connect and try again."
        }
        return text
    }
}
