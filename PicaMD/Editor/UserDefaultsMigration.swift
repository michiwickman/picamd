import Foundation

/// One-time migration of `UserDefaults` keys from the old `QuickMD.*`
/// namespace (pre-rename) to the new `PicaMD.*` namespace. Runs once
/// per app launch; bails out fast if the new keys already exist.
///
/// Why a migration rather than just letting the user re-pick their
/// settings? Because the rename is purely cosmetic — the user didn't
/// "change app", they're using the same editor with a new name. They
/// shouldn't have to re-pick palette / accent / preset / AI endpoint
/// just because we changed the bundle identifier.
///
/// What we migrate:
///   - `QuickMD.editorTheme.v1`           → `PicaMD.editorTheme.v1`
///   - `QuickMD.ai.{enabled,endpointURL,model,replaceSelection}`
///                                         → `PicaMD.ai.…`
///   - `@SceneStorage("QuickMD.{focusMode,showOutline,typewriterMode}")`
///     are per-window state, NOT in `UserDefaults` proper, so they
///     re-set themselves on next window open. Acceptable — they're
///     boolean toggles users don't tend to set globally.
///
/// What we DON'T migrate:
///   - `~/Library/Caches/QuickMD/{Math,Mermaid}/` — KaTeX gets re-
///     staged (~436 KB, instant) and Mermaid re-downloaded on first
///     use. Old cache eventually purged by macOS.
///   - LaunchServices / dock state — Spotlight handles re-indexing.
@MainActor
enum UserDefaultsMigration {

    /// Pairs of (old QuickMD key, new PicaMD key). Order doesn't
    /// matter — each migrates independently.
    private static let pairs: [(old: String, new: String)] = [
        ("QuickMD.editorTheme.v1",   "PicaMD.editorTheme.v1"),
        ("QuickMD.ai.enabled",       "PicaMD.ai.enabled"),
        ("QuickMD.ai.endpointURL",   "PicaMD.ai.endpointURL"),
        ("QuickMD.ai.model",         "PicaMD.ai.model"),
        ("QuickMD.ai.replaceSelection", "PicaMD.ai.replaceSelection"),
    ]

    /// Marker key — written once after migration completes so we
    /// don't re-run on every launch. Using a versioned marker so
    /// future migrations can be added without colliding.
    private static let markerKey = "PicaMD.migration.fromQuickMD.v1"

    static func migrateFromQuickMDIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: markerKey) else { return }
        defer { defaults.set(true, forKey: markerKey) }

        // API keys live in the Keychain, not the plist — migrate them
        // first and independently, so a missing/unreadable QuickMD plist
        // (the early-return below) doesn't strand the user's keys under
        // the old service, forcing them to re-paste every key.
        migrateKeychainFromQuickMD()

        // UserDefaults are scoped per bundle identifier. The rename
        // changed the identifier from `de.michaelwittmann.QuickMD` to
        // `de.michaelwittmann.PicaMD`, so PicaMD's `.standard` no
        // longer sees the QuickMD keys at all. Read the QuickMD plist
        // directly off disk and copy the values into our domain.
        let prefsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/de.michaelwittmann.QuickMD.plist")

        guard FileManager.default.fileExists(atPath: prefsURL.path),
              let plistData = try? Data(contentsOf: prefsURL),
              let plistObj = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil),
              let oldPrefs = plistObj as? [String: Any] else {
            // No QuickMD plist (fresh install or already cleaned up) —
            // nothing to migrate.
            return
        }

        for pair in pairs {
            guard let value = oldPrefs[pair.old] else { continue }
            // Never overwrite an explicit choice the user has already
            // made on the new bundle.
            guard defaults.object(forKey: pair.new) == nil else { continue }
            defaults.set(value, forKey: pair.new)
        }
        // We deliberately DON'T delete the old plist. The QuickMD app
        // is gone but the user might still want their old settings
        // around for reference / re-import / Time Machine purposes.
        // The migration marker prevents us from re-applying them.
    }

    /// Copy each provider's API key from the old QuickMD keychain
    /// (service + account both carried the `QuickMD` prefix) into the
    /// new PicaMD entries. Never overwrites a key the user has already
    /// set on the new bundle.
    private static func migrateKeychainFromQuickMD() {
        let oldService = "de.michaelwittmann.QuickMD.ai"
        for provider in AIProvider.allCases {
            let newAccount = provider.keychainAccount            // PicaMD.ai.<p>.apiKey
            guard Keychain.get(account: newAccount) == nil else { continue }
            let oldAccount = "QuickMD.ai.\(provider.rawValue).apiKey"
            if let key = Keychain.value(forService: oldService, account: oldAccount) {
                Keychain.set(value: key, account: newAccount)
            }
        }
    }
}
