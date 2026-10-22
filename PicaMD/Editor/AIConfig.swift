import Foundation
import Security

/// User-facing AI configuration:
///
///   1. `defaultProvider` + per-provider endpoint/model overrides for
///      the built-in HTTP providers, plus the user's own
///      OpenAI-compatible servers (`customProviders`).
///   2. `enabled` — master kill switch. When `false`, the editor's
///      ⌃⌘1…⌃⌘9 hotkeys and ⌃Space picker no-op out.
///
/// API keys live in `Keychain` (not in here). The default endpoint
/// + model strings live in the `AIProvider` enum.
///
/// AI is **off** until the user turns it on. Opt-in only.
struct AIConfig: Equatable {
    var enabled: Bool
    var defaultProvider: AIProviderRef

    /// Per-provider settings for the built-in HTTP providers, indexed by
    /// `AIProvider.rawValue`. Keeps each provider's state independent —
    /// switching from OpenAI to Anthropic doesn't lose your OpenAI
    /// endpoint customisation.
    var providers: [String: ProviderSettings]

    /// User-defined OpenAI-compatible servers, in Settings order.
    var customProviders: [CustomAIProvider]

    /// Which one-time migrations the stored blob has been through.
    /// Absent in blobs written before 0.10.0 (= 0).
    var revision: Int

    struct ProviderSettings: Equatable, Codable {
        var endpointURL: String
        var model: String

        init(endpointURL: String, model: String) {
            self.endpointURL = endpointURL
            self.model = model
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            endpointURL = (try? c.decodeIfPresent(String.self, forKey: .endpointURL)) ?? ""
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        }
    }

    /// 1 = custom providers replace the built-in "Local" entry, old
    /// default model IDs moved to the current ones (0.10.0).
    static let currentRevision = 1

    init(enabled: Bool,
         defaultProvider: AIProviderRef,
         providers: [String: ProviderSettings] = AIConfig.defaultHTTPProviderSettings,
         customProviders: [CustomAIProvider] = [],
         revision: Int = AIConfig.currentRevision) {
        self.enabled = enabled
        self.defaultProvider = defaultProvider
        self.providers = providers
        self.customProviders = customProviders
        self.revision = revision
    }

    static let defaultHTTPProviderSettings: [String: ProviderSettings] = Dictionary(
        uniqueKeysWithValues: AIProvider.httpProviders.map {
            ($0.rawValue, ProviderSettings(endpointURL: $0.defaultEndpoint, model: $0.defaultModel))
        }
    )

    /// Anthropic as default provider. Used where no environment is
    /// available (tests, previews) and as the fallback.
    static let `default` = AIConfig.makeDefault(appleIntelligenceAvailable: false)

    /// Fresh-install configuration: Apple Intelligence is the default
    /// provider when it can run on this Mac right now, else Anthropic.
    /// AI stays off either way.
    static func makeDefault(appleIntelligenceAvailable: Bool) -> AIConfig {
        AIConfig(enabled: false,
                 defaultProvider: appleIntelligenceAvailable ? .appleIntelligence : .anthropic)
    }

    // MARK: Accessors

    /// Convenience getters/setters for a built-in provider's fields.
    /// Fall back to defaults if the dictionary entry is missing.

    func endpoint(for provider: AIProvider) -> String {
        providers[provider.rawValue]?.endpointURL ?? provider.defaultEndpoint
    }

    func model(for provider: AIProvider) -> String {
        providers[provider.rawValue]?.model ?? provider.defaultModel
    }

    mutating func setEndpoint(_ url: String, for provider: AIProvider) {
        var s = providers[provider.rawValue]
            ?? ProviderSettings(endpointURL: provider.defaultEndpoint,
                                 model: provider.defaultModel)
        s.endpointURL = url
        providers[provider.rawValue] = s
    }

    mutating func setModel(_ model: String, for provider: AIProvider) {
        var s = providers[provider.rawValue]
            ?? ProviderSettings(endpointURL: provider.defaultEndpoint,
                                 model: provider.defaultModel)
        s.model = model
        providers[provider.rawValue] = s
    }

    func customProvider(id: UUID) -> CustomAIProvider? {
        customProviders.first { $0.id == id }
    }

    /// Whether `ref` points at something that exists: always for a
    /// built-in provider, only while the entry is there for a custom one.
    func contains(_ ref: AIProviderRef) -> Bool {
        switch ref {
        case .builtIn:         return true
        case .custom(let id):  return customProvider(id: id) != nil
        }
    }

    /// Insert or replace (by id).
    mutating func upsertCustomProvider(_ provider: CustomAIProvider) {
        if let i = customProviders.firstIndex(where: { $0.id == provider.id }) {
            customProviders[i] = provider
        } else {
            customProviders.append(provider)
        }
    }

    /// Removes the entry. A default provider that pointed at it falls
    /// back to Apple Intelligence, so the picker never shows a dangling
    /// choice. Never to a cloud provider: text meant for the user's own
    /// server must not go to Anthropic unasked (the rule the executor
    /// applies to presets). Apple Intelligence runs on the device, and
    /// where it is unavailable the request fails instead.
    /// The caller deletes the entry's Keychain key.
    mutating func removeCustomProvider(id: UUID) {
        customProviders.removeAll { $0.id == id }
        if defaultProvider == .custom(id) {
            defaultProvider = .appleIntelligence
        }
    }

    /// Display name for any reference, for pickers and messages.
    func displayName(for ref: AIProviderRef) -> String {
        switch ref {
        case .builtIn(let p):  return p.displayName
        case .custom(let id):  return customProvider(id: id)?.displayName ?? "Removed provider"
        }
    }

    // MARK: - Persistence

    static let storageKey = "PicaMD.ai.config.v2"
    static let presetsStorageKey = "PicaMD.ai.presets.v1"

    /// Load the stored configuration, migrating older blobs once.
    ///
    /// - `keyStore`: Keychain access for moving the old "Local" key.
    /// - `appleIntelligenceAvailable`: asked only for a fresh install.
    static func load(defaults: UserDefaults = .standard,
                     keyStore: any AIKeyStore = KeychainKeyStore(),
                     appleIntelligenceAvailable: () -> Bool = { AppleIntelligence.isAvailable }) -> AIConfig {
        if let data = defaults.data(forKey: storageKey) {
            guard let stored = try? JSONDecoder().decode(StoredBlob.self, from: data) else {
                // Not even a JSON object. Run on defaults for this session
                // but don't save — that would overwrite the blob for good.
                NSLog("PicaMD: couldn't read the AI configuration, using defaults without saving")
                return .default
            }
            if (stored.revision ?? 0) >= currentRevision {
                return AIConfig(resolving: stored)
            }
            let migrated = migrate(stored,
                                   presetsData: defaults.data(forKey: presetsStorageKey),
                                   keyStore: keyStore)
            migrated.save(to: defaults)
            return migrated
        }
        if let v1 = StoredBlob.fromV1(defaults: defaults) {
            let migrated = migrate(v1,
                                   presetsData: defaults.data(forKey: presetsStorageKey),
                                   keyStore: keyStore)
            migrated.save(to: defaults)
            return migrated
        }
        // Fresh install: decide the default provider once and keep it,
        // so it doesn't flip later when Apple Intelligence finishes
        // downloading or gets switched off.
        let fresh = makeDefault(appleIntelligenceAvailable: appleIntelligenceAvailable())
        fresh.save(to: defaults)
        return fresh
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Codable

extension AIConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled, defaultProvider, providers, customProviders, revision
    }

    /// Never throws for a JSON object: unknown or broken values fall
    /// back field by field, so one value this version doesn't know
    /// can't silently reset the whole configuration (which the next
    /// save would then make permanent).
    init(from decoder: any Decoder) throws {
        self.init(resolving: try StoredBlob(from: decoder))
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(defaultProvider, forKey: .defaultProvider)
        try c.encode(providers, forKey: .providers)
        try c.encode(customProviders, forKey: .customProviders)
        try c.encode(revision, forKey: .revision)
    }

    /// The stored blob with every field optional and provider references
    /// kept as raw strings, so the migration can see values this version
    /// no longer has a case for.
    struct StoredBlob: Decodable {
        var enabled: Bool?
        var defaultProvider: String?
        var providers: [String: ProviderSettings]?
        var customProviders: [CustomAIProvider]?
        var revision: Int?

        init(enabled: Bool?, defaultProvider: String?, providers: [String: ProviderSettings]?,
             customProviders: [CustomAIProvider]? = nil, revision: Int? = nil) {
            self.enabled = enabled
            self.defaultProvider = defaultProvider
            self.providers = providers
            self.customProviders = customProviders
            self.revision = revision
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
            defaultProvider = try? c.decodeIfPresent(String.self, forKey: .defaultProvider)
            providers = (try? c.decodeIfPresent([String: LossyDecodable<ProviderSettings>].self, forKey: .providers))?
                .compactMapValues(\.value)
            customProviders = (try? c.decodeIfPresent([LossyDecodable<CustomAIProvider>].self, forKey: .customProviders))?
                .compactMap(\.value)
            revision = try? c.decodeIfPresent(Int.self, forKey: .revision)
        }

        /// The flat keys of the original LM-Studio-only AI hook (v1).
        /// That hook only knew a local server, so it reads as a
        /// `localOpenAICompat` default provider.
        static func fromV1(defaults: UserDefaults) -> StoredBlob? {
            let oldEnabledKey = "PicaMD.ai.enabled"
            let oldEndpointKey = "PicaMD.ai.endpointURL"
            let oldModelKey = "PicaMD.ai.model"
            let hasOldData = defaults.object(forKey: oldEnabledKey) != nil
                          || defaults.string(forKey: oldEndpointKey) != nil
            guard hasOldData else { return nil }
            let local = ProviderSettings(
                endpointURL: defaults.string(forKey: oldEndpointKey).flatMap { $0.isEmpty ? nil : $0 }
                    ?? AIConfig.legacyLocalDefaultEndpoint,
                model: defaults.string(forKey: oldModelKey).flatMap { $0.isEmpty ? nil : $0 }
                    ?? AIConfig.legacyLocalDefaultModel
            )
            return StoredBlob(enabled: defaults.bool(forKey: oldEnabledKey),
                              defaultProvider: AIProviderRef.legacyLocalRawValue,
                              providers: [AIProviderRef.legacyLocalRawValue: local])
        }
    }

    /// Side-effect-free mapping of a stored blob. An unknown reference
    /// falls back to Anthropic; a custom provider that is gone (removed,
    /// or an entry that no longer decodes) falls back to Apple
    /// Intelligence, for the reason given at `removeCustomProvider`.
    /// Missing built-in entries get their defaults.
    init(resolving stored: StoredBlob) {
        var providers = AIConfig.defaultHTTPProviderSettings
        for p in AIProvider.httpProviders {
            if let s = stored.providers?[p.rawValue] { providers[p.rawValue] = s }
        }
        let custom = stored.customProviders ?? []
        self.init(enabled: stored.enabled ?? false,
                  defaultProvider: .anthropic,
                  providers: providers,
                  customProviders: custom,
                  revision: stored.revision ?? 0)
        if let raw = stored.defaultProvider,
           let ref = AIProviderRef(storageValue: raw) {
            if contains(ref) {
                defaultProvider = ref
            } else if case .custom = ref {
                defaultProvider = .appleIntelligence
            }
        }
    }
}

/// Decodes `T` or yields `nil`, so one bad element doesn't fail its
/// whole container.
struct LossyDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

// MARK: - Migration to 0.10.0

extension AIConfig {
    /// Defaults of the removed "Local (LM Studio / Ollama)" entry. An
    /// entry still equal to both was never configured.
    static let legacyLocalDefaultEndpoint = "http://localhost:1234/v1"
    static let legacyLocalDefaultModel = "local-model"
    static let legacyLocalKeychainAccount = "PicaMD.ai.\(AIProviderRef.legacyLocalRawValue).apiKey"

    /// One-time migration of a pre-0.10.0 blob:
    ///
    /// - The built-in "Local" entry (`localOpenAICompat`) becomes a
    ///   custom provider named "Local" when it was in use: it was the
    ///   default provider, a preset pointed at it, it had a Keychain key,
    ///   or its endpoint/model differ from the old defaults. The key
    ///   moves to the new entry. Otherwise the entry is dropped.
    /// - Stored models equal to the old defaults (`claude-sonnet-4-6`,
    ///   `gpt-4o-mini`) become the current ones; other models stay.
    ///
    /// Idempotent: running it on its own output changes nothing. If the
    /// Keychain key can't be moved, the revision stays where it was, so
    /// the next launch runs the migration again and retries the move.
    static func migrate(_ stored: StoredBlob, presetsData: Data?, keyStore: any AIKeyStore) -> AIConfig {
        var cfg = AIConfig(resolving: stored)
        var keyMoved = true

        for p in AIProvider.httpProviders {
            if let legacy = p.legacyDefaultModel, cfg.model(for: p) == legacy {
                cfg.setModel(p.defaultModel, for: p)
            }
        }

        let legacyRaw = AIProviderRef.legacyLocalRawValue
        let local = stored.providers?[legacyRaw]
        let localWasDefault = stored.defaultProvider == legacyRaw
        let presetsUseLocal = presetsReferenceLegacyLocal(presetsData)
        let legacyKey = keyStore.get(account: legacyLocalKeychainAccount)
        let localWasCustomised = local.map {
            $0.endpointURL != legacyLocalDefaultEndpoint || $0.model != legacyLocalDefaultModel
        } ?? false

        if localWasDefault || presetsUseLocal || legacyKey != nil || localWasCustomised {
            let id = AIProviderRef.legacyLocalProviderID
            var entry = cfg.customProvider(id: id) ?? CustomAIProvider(
                id: id,
                name: "Local",
                endpointURL: local.flatMap { $0.endpointURL.isEmpty ? nil : $0.endpointURL }
                    ?? legacyLocalDefaultEndpoint,
                model: local.flatMap { $0.model.isEmpty ? nil : $0.model }
                    ?? legacyLocalDefaultModel
            )
            if entry.name.isEmpty { entry.name = "Local" }
            cfg.upsertCustomProvider(entry)
            if let legacyKey {
                // Delete the old item only once the new one is written.
                if keyStore.set(legacyKey, account: entry.keychainAccount) {
                    keyStore.delete(account: legacyLocalKeychainAccount)
                } else {
                    keyMoved = false
                }
            }
            if localWasDefault {
                cfg.defaultProvider = .custom(id)
            }
        }
        cfg.revision = keyMoved ? currentRevision : (stored.revision ?? 0)
        return cfg
    }

    /// Whether any stored preset overrides its provider with the removed
    /// "Local" entry. Reads the raw JSON so that it works whatever else
    /// in the preset blob this version can or can't decode.
    static func presetsReferenceLegacyLocal(_ data: Data?) -> Bool {
        guard let data,
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return false
        }
        return array.contains { ($0["providerOverride"] as? String) == AIProviderRef.legacyLocalRawValue }
    }
}

// MARK: - Keychain access

/// The Keychain operations the AI settings need, behind a protocol so
/// the migration can be tested without touching the real Keychain.
protocol AIKeyStore {
    func get(account: String) -> String?
    /// `true` when the value was written.
    @discardableResult func set(_ value: String, account: String) -> Bool
    func delete(account: String)
}

struct KeychainKeyStore: AIKeyStore {
    func get(account: String) -> String? { Keychain.get(account: account) }
    @discardableResult func set(_ value: String, account: String) -> Bool {
        Keychain.set(value: value, account: account) == errSecSuccess
    }
    func delete(account: String) { Keychain.delete(account: account) }
}
