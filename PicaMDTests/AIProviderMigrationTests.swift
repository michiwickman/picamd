import XCTest
@testable import PicaMD

/// Keychain stand-in, so no test reads or writes the real Keychain.
final class InMemoryKeyStore: AIKeyStore {
    var items: [String: String]
    var failWrites = false

    init(_ items: [String: String] = [:]) { self.items = items }

    func get(account: String) -> String? { items[account] }
    @discardableResult func set(_ value: String, account: String) -> Bool {
        guard !failWrites else { return false }
        items[account] = value
        return true
    }
    func delete(account: String) { items[account] = nil }
}

/// The 0.10.0 migration: the built-in "Local (LM Studio / Ollama)" entry
/// becomes a custom provider only when it was in use, the old default
/// models move to the current ones, and nothing unknown wipes a config.
final class AIProviderMigrationTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Named after the test host and emptied after each test, like
        // every other suite (see `makeTestDefaults`).
        defaults = makeTestDefaults("AIProviderMigration")
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    /// A typical 0.9 config: AI on, Anthropic default, the untouched built-in "Local" entry.
    private let typical09ConfigJSON = #"""
    {"defaultProvider":"anthropic","enabled":true,"providers":{"anthropic":{"model":"claude-sonnet-4-6","endpointURL":"https:\/\/api.anthropic.com\/v1"},"openai":{"model":"gpt-4o-mini","endpointURL":"https:\/\/api.openai.com\/v1"},"localOpenAICompat":{"model":"local-model","endpointURL":"http:\/\/localhost:1234\/v1"}}}
    """#

    private func store(config json: String) {
        defaults.set(Data(json.utf8), forKey: AIConfig.storageKey)
    }

    private func store(presets json: String) {
        defaults.set(Data(json.utf8), forKey: AIConfig.presetsStorageKey)
    }

    private func load(keyStore: InMemoryKeyStore = InMemoryKeyStore(),
                      appleAvailable: Bool = true) -> AIConfig {
        AIConfig.load(defaults: defaults, keyStore: keyStore,
                      appleIntelligenceAvailable: { appleAvailable })
    }

    private func storedJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: AIConfig.storageKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func presetJSON(override: String?) -> String {
        let field = override.map { #","providerOverride":"\#($0)""# } ?? ""
        return #"{"id":"\#(UUID().uuidString)","name":"P","userPromptTemplate":"{{selection}}","insertionMode":"replaceSelection","hotkey":1\#(field)}"#
    }

    // MARK: Typical 0.9 configuration

    func testTypical09ConfigKeepsAnthropicDropsLocalAndBumpsModels() throws {
        store(config: typical09ConfigJSON)
        // Apple Intelligence being available must not change an
        // existing user's default (that rule is for new installs only).
        let cfg = load(appleAvailable: true)

        XCTAssertTrue(cfg.enabled)
        XCTAssertEqual(cfg.defaultProvider, .anthropic)
        XCTAssertTrue(cfg.customProviders.isEmpty, "the unused Local entry is dropped silently")
        XCTAssertEqual(cfg.model(for: .anthropic), "claude-sonnet-5-5")
        XCTAssertEqual(cfg.model(for: .openai), "gpt-6-luna")
        XCTAssertEqual(cfg.endpoint(for: .anthropic), "https://api.anthropic.com/v1")
        XCTAssertEqual(cfg.endpoint(for: .openai), "https://api.openai.com/v1")

        let json = try storedJSON()
        XCTAssertEqual(json["revision"] as? Int, AIConfig.currentRevision, "the migration is saved")
        let providers = try XCTUnwrap(json["providers"] as? [String: Any])
        XCTAssertNil(providers["localOpenAICompat"])
        XCTAssertEqual(json["defaultProvider"] as? String, "anthropic")
    }

    func testMigrationRunsOnlyOnce() {
        store(config: typical09ConfigJSON)
        var cfg = load()
        // The user deliberately picks the old model again afterwards.
        cfg.setModel("claude-sonnet-4-6", for: .anthropic)
        cfg.save(to: defaults)
        XCTAssertEqual(load().model(for: .anthropic), "claude-sonnet-4-6")
    }

    func testMigrationIsIdempotent() throws {
        let data = Data(typical09ConfigJSON.utf8)
        let stored = try JSONDecoder().decode(AIConfig.StoredBlob.self, from: data)
        let once = AIConfig.migrate(stored, presetsData: nil, keyStore: InMemoryKeyStore())
        let reencoded = try JSONDecoder().decode(AIConfig.StoredBlob.self, from: JSONEncoder().encode(once))
        let twice = AIConfig.migrate(reencoded, presetsData: nil, keyStore: InMemoryKeyStore())
        XCTAssertEqual(once, twice)
    }

    func testUserChosenModelsAreKept() {
        store(config: #"""
        {"defaultProvider":"openai","enabled":true,"providers":{"anthropic":{"model":"claude-opus-5-5","endpointURL":"https://api.anthropic.com/v1"},"openai":{"model":"llama-3.1-70b","endpointURL":"https://api.groq.com/openai/v1"}}}
        """#)
        let cfg = load()
        XCTAssertEqual(cfg.defaultProvider, .openai)
        XCTAssertEqual(cfg.model(for: .anthropic), "claude-opus-5-5")
        XCTAssertEqual(cfg.model(for: .openai), "llama-3.1-70b")
        XCTAssertEqual(cfg.endpoint(for: .openai), "https://api.groq.com/openai/v1")
    }

    // MARK: Old "Local" entry in use

    func testLocalAsDefaultProviderBecomesSelectedCustomProvider() throws {
        store(config: #"""
        {"defaultProvider":"localOpenAICompat","enabled":true,"providers":{"localOpenAICompat":{"model":"qwen2.5","endpointURL":"http://10.0.0.5:11434/v1"}}}
        """#)
        let cfg = load()
        let local = try XCTUnwrap(cfg.customProvider(id: AIProviderRef.legacyLocalProviderID))
        XCTAssertEqual(local.name, "Local")
        XCTAssertEqual(local.endpointURL, "http://10.0.0.5:11434/v1")
        XCTAssertEqual(local.model, "qwen2.5")
        XCTAssertEqual(cfg.defaultProvider, .custom(local.id))
        XCTAssertTrue(cfg.enabled)
        XCTAssertEqual(try storedJSON()["defaultProvider"] as? String, "custom:\(local.id.uuidString)")
    }

    func testLocalAsDefaultWithOldDefaultsStillMigrates() throws {
        store(config: #"""
        {"defaultProvider":"localOpenAICompat","enabled":true,"providers":{"localOpenAICompat":{"model":"local-model","endpointURL":"http://localhost:1234/v1"}}}
        """#)
        let cfg = load()
        let local = try XCTUnwrap(cfg.customProvider(id: AIProviderRef.legacyLocalProviderID))
        XCTAssertEqual(local.endpointURL, "http://localhost:1234/v1")
        XCTAssertEqual(cfg.defaultProvider, .custom(local.id))
    }

    func testCustomisedLocalEntryIsKeptButNotSelected() throws {
        store(config: #"""
        {"defaultProvider":"anthropic","enabled":true,"providers":{"localOpenAICompat":{"model":"local-model","endpointURL":"http://192.168.1.20:1234/v1"}}}
        """#)
        let cfg = load()
        let local = try XCTUnwrap(cfg.customProvider(id: AIProviderRef.legacyLocalProviderID))
        XCTAssertEqual(local.endpointURL, "http://192.168.1.20:1234/v1")
        XCTAssertEqual(cfg.defaultProvider, .anthropic)
    }

    func testLegacyKeychainKeyMovesToTheLocalProvider() throws {
        store(config: typical09ConfigJSON)
        let keys = InMemoryKeyStore([AIConfig.legacyLocalKeychainAccount: "sk-local"])
        let cfg = load(keyStore: keys)
        let local = try XCTUnwrap(cfg.customProvider(id: AIProviderRef.legacyLocalProviderID),
                                  "a stored key means the entry was in use")
        XCTAssertEqual(keys.items[local.keychainAccount], "sk-local")
        XCTAssertNil(keys.items[AIConfig.legacyLocalKeychainAccount])
        XCTAssertEqual(cfg.defaultProvider, .anthropic)
    }

    func testLegacyKeyIsKeptWhenTheNewItemCantBeWritten() {
        store(config: typical09ConfigJSON)
        let keys = InMemoryKeyStore([AIConfig.legacyLocalKeychainAccount: "sk-local"])
        keys.failWrites = true
        _ = load(keyStore: keys)
        XCTAssertEqual(keys.items[AIConfig.legacyLocalKeychainAccount], "sk-local")
    }

    /// A failed key move (e.g. locked Keychain) is retried on the next
    /// launch instead of leaving the key behind for good.
    func testFailedKeyMoveIsRetriedOnTheNextLoad() throws {
        store(config: typical09ConfigJSON)
        let keys = InMemoryKeyStore([AIConfig.legacyLocalKeychainAccount: "sk-local"])
        keys.failWrites = true
        _ = load(keyStore: keys)
        XCTAssertNotEqual(try storedJSON()["revision"] as? Int, AIConfig.currentRevision)

        keys.failWrites = false
        let cfg = load(keyStore: keys)
        let local = try XCTUnwrap(cfg.customProvider(id: AIProviderRef.legacyLocalProviderID))
        XCTAssertEqual(keys.items[local.keychainAccount], "sk-local")
        XCTAssertNil(keys.items[AIConfig.legacyLocalKeychainAccount])
        XCTAssertEqual(cfg.customProviders.count, 1)
        XCTAssertEqual(cfg.model(for: .anthropic), "claude-sonnet-5-5")
        XCTAssertEqual(try storedJSON()["revision"] as? Int, AIConfig.currentRevision)
    }

    @MainActor
    func testPresetOverrideOfLocalCreatesLocalAndKeepsThePresetOnIt() throws {
        store(config: typical09ConfigJSON)
        store(presets: "[\(presetJSON(override: nil)),\(presetJSON(override: "localOpenAICompat"))]")

        let cfg = load()
        let local = try XCTUnwrap(cfg.customProvider(id: AIProviderRef.legacyLocalProviderID))
        XCTAssertEqual(cfg.defaultProvider, .anthropic)

        let presets = AIPresetStore(defaults: defaults).presets
        XCTAssertEqual(presets.count, 2)
        XCTAssertNil(presets[0].providerOverride)
        XCTAssertEqual(presets[1].providerOverride, .custom(local.id))

        guard case .http(let client) = try AICommandExecutor.resolveProvider(
            for: presets[1], config: cfg, apiKey: { _ in nil }) else {
            return XCTFail("the Local override should resolve to an HTTP client")
        }
        XCTAssertEqual(client.format, .openAICompatible)
        XCTAssertEqual(client.endpoint.absoluteString, "http://localhost:1234/v1")
    }

    // MARK: Tolerant decoding

    func testUnknownDefaultProviderDoesNotDropTheConfig() {
        store(config: #"""
        {"defaultProvider":"somethingNew","enabled":true,"revision":1,"providers":{"openai":{"model":"m","endpointURL":"https://api.groq.com/openai/v1"}},"customProviders":[{"id":"6A1D6F43-6C55-4E33-9F2B-0F5B2D0B7A11","name":"Box","endpointURL":"http://box:8080/v1","model":"x"},{"name":"broken entry without id"}]}
        """#)
        let cfg = load()
        XCTAssertTrue(cfg.enabled)
        XCTAssertEqual(cfg.defaultProvider, .anthropic)
        XCTAssertEqual(cfg.endpoint(for: .openai), "https://api.groq.com/openai/v1")
        XCTAssertEqual(cfg.customProviders.map(\.name), ["Box"], "one broken entry doesn't drop the others")
    }

    /// A default that pointed at the user's own server must not turn into
    /// a cloud provider: the text would go to Anthropic unasked.
    func testDefaultPointingAtARemovedCustomProviderFallsBackOnDevice() {
        store(config: #"""
        {"defaultProvider":"custom:6A1D6F43-6C55-4E33-9F2B-0F5B2D0B7A11","enabled":true,"revision":1,"providers":{},"customProviders":[]}
        """#)
        XCTAssertEqual(load().defaultProvider, .appleIntelligence)
    }

    func testDefaultPointingAtAnEntryThatNoLongerDecodesFallsBackOnDevice() {
        store(config: #"""
        {"defaultProvider":"custom:6A1D6F43-6C55-4E33-9F2B-0F5B2D0B7A11","enabled":true,"revision":1,"providers":{},"customProviders":[{"id":42,"name":"Box","endpointURL":"http://box:8080/v1"}]}
        """#)
        XCTAssertEqual(load().defaultProvider, .appleIntelligence)
    }

    @MainActor
    func testUnknownPresetOverrideKeepsAllPresets() {
        store(presets: "[\(presetJSON(override: "somethingNew")),\(presetJSON(override: "openai")),\(presetJSON(override: nil))]")
        let presets = AIPresetStore(defaults: defaults).presets
        XCTAssertEqual(presets.count, 3, "not the starter set")
        XCTAssertNil(presets[0].providerOverride)
        XCTAssertEqual(presets[1].providerOverride, .openai)
    }

    func testPresetOverrideRoundTripsAsAString() throws {
        let id = UUID()
        let preset = AIPreset(id: UUID(), name: "x", systemPrompt: nil, userPromptTemplate: "{{selection}}",
                              insertionMode: .appendBelow, hotkey: nil, providerOverride: .custom(id))
        let data = try JSONEncoder().encode(preset)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["providerOverride"] as? String, "custom:\(id.uuidString)")
        XCTAssertEqual(try JSONDecoder().decode(AIPreset.self, from: data), preset)
    }

    func testProviderReferenceStorageValues() {
        let id = UUID()
        XCTAssertEqual(AIProviderRef(storageValue: "anthropic"), .anthropic)
        XCTAssertEqual(AIProviderRef(storageValue: "openai"), .openai)
        XCTAssertEqual(AIProviderRef(storageValue: "appleIntelligence"), .appleIntelligence)
        XCTAssertEqual(AIProviderRef(storageValue: "custom:\(id.uuidString)"), .custom(id))
        XCTAssertEqual(AIProviderRef(storageValue: "localOpenAICompat"), .custom(AIProviderRef.legacyLocalProviderID))
        XCTAssertNil(AIProviderRef(storageValue: "custom:not-a-uuid"))
        XCTAssertNil(AIProviderRef(storageValue: "somethingNew"))
        XCTAssertEqual(AIProviderRef.custom(id).storageValue, "custom:\(id.uuidString)")
    }

    // MARK: New installs

    func testFreshInstallPrefersAppleIntelligenceWhenAvailable() {
        let cfg = load(appleAvailable: true)
        XCTAssertEqual(cfg.defaultProvider, .appleIntelligence)
        XCTAssertFalse(cfg.enabled, "AI stays opt-in")
        XCTAssertEqual(cfg.model(for: .anthropic), "claude-sonnet-5-5")
        XCTAssertEqual(cfg.model(for: .openai), "gpt-6-luna")
        // Decided once: Apple Intelligence going away later doesn't flip it.
        XCTAssertEqual(load(appleAvailable: false).defaultProvider, .appleIntelligence)
    }

    func testFreshInstallFallsBackToAnthropic() {
        XCTAssertEqual(load(appleAvailable: false).defaultProvider, .anthropic)
    }

    // MARK: Editing

    func testRemovingTheDefaultCustomProviderFallsBackOnDevice() {
        var cfg = AIConfig.default
        let box = CustomAIProvider(name: "Box", endpointURL: "http://box:8080/v1", model: "x")
        cfg.upsertCustomProvider(box)
        cfg.defaultProvider = .custom(box.id)
        cfg.removeCustomProvider(id: box.id)
        XCTAssertTrue(cfg.customProviders.isEmpty)
        XCTAssertEqual(cfg.defaultProvider, .appleIntelligence, "never a cloud provider")
    }
}
