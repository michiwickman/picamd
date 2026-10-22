import XCTest
import Security
@testable import PicaMD

// MARK: - Keychain unit tests

/// Tests the `Keychain` enum (Keychain.swift) and the QuickMD→PicaMD
/// keychain migration path inside `UserDefaultsMigration.swift`.
///
/// All tests touch the real login keychain, but only under the test
/// host's services (`Keychain.service`, `legacyKeychainService`), never
/// PicaMD's or QuickMD's, so they can't read, overwrite or delete the
/// user's API keys. Every entry written is cleaned up again.
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
        let customService = "\(AppEnvironment.testHostBundleIdentifier).TEST-\(runID!)"
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
    // @MainActor (just this method): migrateFromQuickMDIfNeeded is
    // main-actor-isolated, and running the whole test on the main actor
    // avoids "sending" the non-Sendable UserDefaults across an isolation
    // boundary — both of which Xcode 16 rejects.
    @MainActor
    func testMigrationCopiesOldKeyToNew() {
        // Both services belong to the test host, so the user's keys are
        // out of reach and the test needn't skip when he has one.
        let oldService  = UserDefaultsMigration.legacyKeychainService
        let oldAccount  = "QuickMD.ai.anthropic.apiKey"
        let newAccount  = AIProvider.anthropic.keychainAccount  // "PicaMD.ai.anthropic.apiKey"
        let seedValue   = "sk-test-\(runID!)"
        let oldQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: oldService,
            kSecAttrAccount as String: oldAccount,
        ]
        func removeItems() {
            SecItemDelete(oldQuery as CFDictionary)
            Keychain.delete(account: newAccount)
        }

        // A run that crashed half-way may have left both behind.
        removeItems()
        defer { removeItems() }

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
        XCTAssertEqual(addStatus, errSecSuccess,
                       "SecItemAdd for old-service seed failed with OSStatus \(addStatus)")

        // ── Run migration with a fresh, isolated UserDefaults ────────────
        let isolatedDefaults = makeTestDefaults("QuickMDMigration")
        // The suite is brand-new, so the migration marker is absent and the
        // migration will run unconditionally. (This test is @MainActor, so
        // the @MainActor migration is called directly.)
        UserDefaultsMigration.migrateFromQuickMDIfNeeded(defaults: isolatedDefaults)

        // ── Assert the new account now holds the seeded value ────────────
        let migrated = Keychain.get(account: newAccount)
        XCTAssertEqual(migrated, seedValue,
                       "Migration should copy the old QuickMD keychain entry to the new PicaMD account")
    }
}
