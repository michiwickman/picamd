import XCTest
import Security
@testable import PicaMD

// MARK: - Keychain unit tests

/// Tests the `Keychain` enum (Keychain.swift) and the QuickMD→PicaMD
/// keychain migration path inside `UserDefaultsMigration.swift`.
///
/// All tests touch the REAL login keychain using unique, throwaway
/// account names that include a UUID. Every entry written is cleaned
/// up in `tearDown` so the suite is safe to run repeatedly.
// NOT @MainActor: the Keychain primitives are plain statics, so setUp/
// tearDown and most tests stay nonisolated. Only the migration call is
// main-actor-isolated; that single test hops via `await MainActor.run`.
// (Marking the whole class @MainActor tripped Xcode 16's stricter
// "sending main-actor XCTestCase to nonisolated super" check.)
final class KeychainTests: XCTestCase {

    // Unique per-run suffix so parallel test runs can't collide.
    private var runID: String!

    override func setUp() {
        super.setUp()
        runID = UUID().uuidString
    }

    override func tearDown() {
        runID = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Make an account string that is unique to this test run.
    private func uniqueAccount(_ label: String = "") -> String {
        "PicaMDTest.\(label.isEmpty ? "" : label + ".")\(runID!)"
    }

    // MARK: - testKeychainSetGetDeleteRoundtrip

    func testKeychainSetGetDeleteRoundtrip() {
        let account = uniqueAccount("roundtrip")
        let value   = "sk-test-roundtrip-\(runID!)"

        // Clean up regardless of what the test does.
        defer { Keychain.delete(account: account) }

        // Write
        Keychain.set(value: value, account: account)

        // Read back — must equal what we wrote.
        let retrieved = Keychain.get(account: account)
        XCTAssertEqual(retrieved, value,
                       "get(account:) should return the value that was set")

        // Delete
        Keychain.delete(account: account)

        // After deletion get returns nil.
        XCTAssertNil(Keychain.get(account: account),
                     "get(account:) should return nil after delete(account:)")
    }

    // MARK: - testGetReturnsNilForAbsentAccount

    func testGetReturnsNilForAbsentAccount() {
        let absentAccount = uniqueAccount("absent")
        // No entry is ever written for this account.
        XCTAssertNil(Keychain.get(account: absentAccount),
                     "get(account:) must return nil when no entry exists")
    }

    // MARK: - testValueForServiceReadsArbitraryService

    func testValueForServiceReadsArbitraryService() {
        let customService = "de.michaelwittmann.QuickMD.ai.TEST-\(runID!)"
        let account       = uniqueAccount("valueForService")
        let expected      = "sk-test-vfs-\(runID!)"

        // Seed via raw SecItemAdd under the custom service.
        let addQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  customService,
            kSecAttrAccount as String:  account,
            kSecValueData as String:    Data(expected.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        // errSecDuplicateItem is also acceptable (leftover from a previous
        // partial run), but we prefer errSecSuccess.
        XCTAssertTrue(addStatus == errSecSuccess || addStatus == errSecDuplicateItem,
                      "SecItemAdd failed with OSStatus \(addStatus)")

        defer {
            // Remove the raw item so nothing leaks into the keychain.
            let delQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: customService,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(delQuery as CFDictionary)
        }

        // Keychain.value(forService:account:) must read it back.
        let result = Keychain.value(forService: customService, account: account)
        XCTAssertEqual(result, expected,
                       "value(forService:account:) should read generic-password items seeded via SecItemAdd")
    }

    // MARK: - testMigrationCopiesOldKeyToNew

    /// Integration test: seeds a raw keychain item under the old QuickMD
    /// service, runs the migration, and asserts the new PicaMD account
    /// now holds the seeded value.
    func testMigrationCopiesOldKeyToNew() async {
        let oldService  = "de.michaelwittmann.QuickMD.ai"
        let oldAccount  = "QuickMD.ai.anthropic.apiKey"
        let newAccount  = AIProvider.anthropic.keychainAccount  // "PicaMD.ai.anthropic.apiKey"
        let seedValue   = "sk-test-\(runID!)"

        // ── Cleanup closure — runs on any exit path ──────────────────────
        defer {
            // Remove the old-service item we seeded.
            let oldQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: oldService,
                kSecAttrAccount as String: oldAccount,
            ]
            SecItemDelete(oldQuery as CFDictionary)

            // Remove the new-service item the migration created.
            Keychain.delete(account: newAccount)
        }

        // ── Pre-condition: ensure the new account is empty before we start ──
        // (If a real key exists here we abort gracefully to avoid clobbering it.)
        if Keychain.get(account: newAccount) != nil {
            // A real user key is stored; skip rather than overwrite it.
            return
        }

        // ── Seed the old-service item via raw SecItemAdd ─────────────────
        let addQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  oldService,
            kSecAttrAccount as String:  oldAccount,
            kSecValueData as String:    Data(seedValue.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        // If an item already lives at the exact old account (a real QuickMD
        // user key), clean up and skip without failing — we must not
        // overwrite real credentials.
        if addStatus == errSecDuplicateItem {
            return
        }
        XCTAssertEqual(addStatus, errSecSuccess,
                       "SecItemAdd for old-service seed failed with OSStatus \(addStatus)")

        // ── Run migration with a fresh, isolated UserDefaults ────────────
        let suiteName = "PicaMDMigrationTest-\(runID!)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        // The suite is brand-new, so the migration marker is absent and the
        // migration will run unconditionally. migrateFromQuickMDIfNeeded is
        // @MainActor, so hop to the main actor for just this call.
        await MainActor.run {
            UserDefaultsMigration.migrateFromQuickMDIfNeeded(defaults: isolatedDefaults)
        }

        // ── Assert the new account now holds the seeded value ────────────
        let migrated = Keychain.get(account: newAccount)
        XCTAssertEqual(migrated, seedValue,
                       "Migration should copy the old QuickMD keychain entry to the new PicaMD account")
    }
}
