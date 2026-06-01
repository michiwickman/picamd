import Foundation
import Security

/// Tiny generic-password Keychain wrapper. Only used for AI API keys —
/// they're the one piece of secret data PicaMD persists.
///
/// Why Keychain instead of UserDefaults? UserDefaults is a plist file
/// readable by anything that can read the user's home, including
/// third-party Spotlight importers, malware, file-watch tools, and
/// Time Machine backups. Keychain is per-app encrypted storage with
/// access controls. For an API key — which can rack up a real bill if
/// stolen — Keychain is non-negotiable.
///
/// API: dead-simple. Three functions on the type:
///   - `set(value:account:)` to write
///   - `get(account:)` to read (`nil` if absent)
///   - `delete(account:)` to clear
///
/// Account is the unique identifier — we use one per provider, e.g.
/// "PicaMD.ai.anthropic.apiKey".
enum Keychain {
    static let service = "de.michaelwittmann.PicaMD.ai"

    static func set(value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete any existing entry first; SecItemAdd otherwise errors
        // out with `errSecDuplicateItem`. Two calls is the boring-but-
        // bulletproof idiom Apple's own sample code uses.
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecValueData as String:    data,
            // Never sync to iCloud, never expose without the device
            // being unlocked. Maximum local privacy.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Read a value from an explicit service identifier. Used by the
    /// QuickMD→PicaMD migration to reach API keys stored under the old
    /// service (`de.michaelwittmann.QuickMD.ai`); normal code paths use
    /// `get(account:)` which targets the current `service`.
    static func value(forService service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
