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

    /// Store `value`, returning the Keychain status (`errSecSuccess` on
    /// success). Updates an existing item in place and only adds when
    /// there is none — deleting first (as before) lost the old key for
    /// good whenever the add then failed.
    @discardableResult
    static func set(value: String, account: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }
        let match: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemUpdate(match as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else {
            if status != errSecSuccess { NSLog("PicaMD: Keychain update failed (\(status))") }
            return status
        }
        var add = match
        add[kSecValueData as String] = data
        // Never sync to iCloud, never expose without the device
        // being unlocked. Maximum local privacy.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess { NSLog("PicaMD: Keychain add failed (\(addStatus))") }
        return addStatus
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
        if status != errSecSuccess && status != errSecItemNotFound {
            // Denied access prompt, locked keychain, … — worth a log line
            // instead of silently looking like "no key configured".
            NSLog("PicaMD: Keychain read failed (\(status))")
        }
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
