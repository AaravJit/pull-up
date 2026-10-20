import Foundation
import Security
import Supabase

/// Where the signed-in session (access and refresh tokens) is kept.
/// supabase-swift's default keychain items are `AfterFirstUnlock`, so an
/// encrypted backup or a phone-to-phone transfer carries the session to the
/// new device. These are `AfterFirstUnlockThisDeviceOnly`: they never leave
/// this phone, and stay readable while it's locked so a drive recorded with
/// the screen off can still upload.
struct SessionKeychain: AuthLocalStorage {
    static let service = "app.pullup.session"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The keychain refused the request (\(status))." }
    }

    /// Sessions saved by builds that used the library's default storage.
    private let legacy = KeychainLocalStorage()

    static func query(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    static func item(key: String, value: Data) -> [String: Any] {
        var item = query(key: key)
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return item
    }

    func store(key: String, value: Data) throws {
        SecItemDelete(Self.query(key: key) as CFDictionary)
        let status = SecItemAdd(Self.item(key: key, value: value) as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func retrieve(key: String) throws -> Data? {
        var query = Self.query(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess { return result as? Data }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        // Move a session saved the old way, so nobody is signed out by the
        // update and no copy is left that a backup would carry.
        guard let old = try? legacy.retrieve(key: key) else { return nil }
        try store(key: key, value: old)
        try? legacy.remove(key: key)
        return old
    }

    func remove(key: String) throws {
        try? legacy.remove(key: key)
        let status = SecItemDelete(Self.query(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
