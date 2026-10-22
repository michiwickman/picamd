import SwiftUI
import AppKit
import Security

/// Settings ▸ AI: the master switch, the default provider, the settings
/// of each provider (Anthropic, OpenAI, Apple Intelligence, the user's
/// own OpenAI-compatible servers) and the presets.
///
/// Self-contained on purpose: it loads and saves `AIConfig`, the
/// Keychain keys and the shared preset store itself, so the settings
/// window can host it in any tab layout.
struct AISettingsPane: View {
    @State private var config: AIConfig = AIConfig.load()
    /// Keys typed but not saved yet, by Keychain account.
    @State private var typedKeys: [String: String] = [:]
    /// Keychain accounts that hold a key. Cached instead of querying the
    /// Keychain from `body` on every render.
    @State private var storedKeys: Set<String> = []
    @State private var keychainError: String?
    @State private var appleIntelligence = AppleIntelligenceMonitor()
    @State private var editingCustomProvider: CustomProviderDraft?

    @StateObject private var presetStore = PicaMDTextView.presetStore
    @State private var editingPreset: AIPreset?
    @State private var showingNewPreset = false

    var body: some View {
        Form {
            generalSection
            // Same order as the provider picker.
            ForEach(AIProvider.httpProviders) { provider in
                httpProviderSection(provider)
            }
            appleIntelligenceSection
            customProvidersSection
            presetsSection
        }
        .formStyle(.grouped)
        .onChange(of: config) { _, newValue in newValue.save() }
        .onAppear {
            refreshStoredKeys()
            appleIntelligence.refresh()
        }
        // Coming back from System Settings: the system may not notify
        // about a changed Apple Intelligence state, so re-read it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appleIntelligence.refresh()
        }
        .sheet(item: $editingCustomProvider) { draft in
            CustomProviderEditor(
                draft: draft,
                hasStoredKey: storedKeys.contains(draft.provider.keychainAccount),
                onSave: { saveCustomProvider($0, newKey: $1, removeKey: $2) },
                onRemove: { removeCustomProvider(draft.provider) },
                onCancel: { editingCustomProvider = nil }
            )
        }
        .sheet(item: $editingPreset) { preset in
            AIPresetEditor(preset: preset) { updated in
                presetStore.update(updated)
                editingPreset = nil
            } onCancel: {
                editingPreset = nil
            }
        }
        .sheet(isPresented: $showingNewPreset) {
            AIPresetEditor(
                preset: AIPreset(
                    id: UUID(),
                    name: "New preset",
                    systemPrompt: nil,
                    userPromptTemplate: "{{selection}}",
                    insertionMode: .appendBelow,
                    hotkey: nil
                )
            ) { newPreset in
                presetStore.add(newPreset)
                showingNewPreset = false
            } onCancel: {
                showingNewPreset = false
            }
        }
        .alert("Couldn't save the API key",
               isPresented: Binding(get: { keychainError != nil },
                                    set: { if !$0 { keychainError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(keychainError ?? "")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            Toggle("Enable AI assistance", isOn: $config.enabled)
            Picker("Default provider", selection: $config.defaultProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(AIProviderRef.builtIn(provider))
                }
                if !config.customProviders.isEmpty {
                    Divider()
                    ForEach(config.customProviders) { custom in
                        Text(custom.displayName).tag(AIProviderRef.custom(custom.id))
                    }
                }
            }
            .disabled(!config.enabled)
        } footer: {
            Text("Off by default. **⌃Space** opens the preset picker; **⌃⌘1**…**⌃⌘9** invoke presets directly. API keys are stored in the macOS keychain (never in plaintext).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Apple Intelligence

    private var appleIntelligenceSection: some View {
        let status = appleIntelligence.status
        return Section {
            LabeledContent("Status") {
                Label(status.title, systemImage: statusSymbol(status))
                    .foregroundStyle(status == .available ? Color.green : Color.secondary)
            }
            if status == .available {
                LabeledContent("Model", value: appleIntelligence.variantName ?? "On-device model")
                LabeledContent("Context", value: "\(appleIntelligence.contextSize.formatted()) tokens")
            }
            if status.offersSystemSettings {
                Button("Open System Settings…") {
                    NSWorkspace.shared.open(AppleIntelligenceStatus.systemSettingsURL)
                }
            }
        } header: {
            Text(AIProvider.appleIntelligence.displayName)
        } footer: {
            Text(status == .available
                 ? "\(status.message) Long selections don't fit the on-device model; use Anthropic or OpenAI for those."
                 : status.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusSymbol(_ status: AppleIntelligenceStatus) -> String {
        switch status {
        case .available:          return "checkmark.circle.fill"
        case .modelNotReady:      return "arrow.down.circle"
        case .notEnabled:         return "exclamationmark.triangle.fill"
        case .deviceNotEligible,
             .unavailable:        return "xmark.circle"
        }
    }

    // MARK: - Anthropic / OpenAI

    private func httpProviderSection(_ provider: AIProvider) -> some View {
        let endpoint = Binding<String>(
            get: { config.endpoint(for: provider) },
            set: { config.setEndpoint($0, for: provider) }
        )
        let model = Binding<String>(
            get: { config.model(for: provider) },
            set: { config.setModel($0, for: provider) }
        )
        let account = provider.keychainAccount
        return Section(provider.displayName) {
            TextField("Endpoint URL", text: endpoint, prompt: Text(provider.defaultEndpoint))
                .disableAutocorrection(true)
            TextField("Model", text: model, prompt: Text(provider.defaultModel))
                .disableAutocorrection(true)
            SecureField("API key", text: typedKeyBinding(account),
                        prompt: Text(storedKeys.contains(account) ? "Stored in Keychain" : "Required"))
                .onSubmit { saveTypedKey(account: account) }
            HStack {
                if storedKeys.contains(account) {
                    Label("Key stored in Keychain", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Save Key") { saveTypedKey(account: account) }
                    .disabled((typedKeys[account] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove Key") {
                    Keychain.delete(account: account)
                    typedKeys[account] = ""
                    refreshStoredKeys()
                }
                .disabled(!storedKeys.contains(account))
            }
        }
        .disabled(!config.enabled)
    }

    // MARK: - Custom providers

    private var customProvidersSection: some View {
        Section {
            ForEach(config.customProviders) { custom in
                Button {
                    editingCustomProvider = CustomProviderDraft(provider: custom, isNew: false)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(custom.displayName)
                            Text(custom.model.isEmpty ? custom.endpointURL : "\(custom.model) · \(custom.endpointURL)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if storedKeys.contains(custom.keychainAccount) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.secondary)
                                .help("API key stored in Keychain")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit…") {
                        editingCustomProvider = CustomProviderDraft(provider: custom, isNew: false)
                    }
                    Button("Remove", role: .destructive) { removeCustomProvider(custom) }
                }
            }
            HStack {
                Spacer()
                Button("Add Provider…") {
                    editingCustomProvider = CustomProviderDraft(
                        provider: CustomAIProvider(name: "", endpointURL: "", model: ""),
                        isNew: true
                    )
                }
            }
        } header: {
            Text("Custom providers")
        } footer: {
            Text("Any OpenAI-compatible server, e.g. Ollama or LM Studio on another machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!config.enabled)
    }

    private func saveCustomProvider(_ provider: CustomAIProvider, newKey: String?, removeKey: Bool) {
        if removeKey {
            Keychain.delete(account: provider.keychainAccount)
        }
        if let newKey, !newKey.isEmpty {
            let status = Keychain.set(value: newKey, account: provider.keychainAccount)
            if status != errSecSuccess {
                // Keep the editor open so the typed key isn't lost.
                keychainError = (SecCopyErrorMessageString(status, nil) as String?)
                    ?? "Keychain error \(status)."
                refreshStoredKeys()
                return
            }
        }
        config.upsertCustomProvider(provider)
        editingCustomProvider = nil
        refreshStoredKeys()
    }

    private func removeCustomProvider(_ provider: CustomAIProvider) {
        config.removeCustomProvider(id: provider.id)
        Keychain.delete(account: provider.keychainAccount)
        editingCustomProvider = nil
        refreshStoredKeys()
    }

    // MARK: - Presets

    private var presetsSection: some View {
        Section {
            ForEach(presetStore.presets) { preset in
                Button {
                    editingPreset = preset
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text(preset.insertionMode.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let key = preset.hotkey {
                            Text("⌃⌘\(key)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit…") { editingPreset = preset }
                    Button("Delete", role: .destructive) { presetStore.remove(id: preset.id) }
                }
            }
            .onMove { source, destination in presetStore.move(from: source, to: destination) }
            .onDelete { offsets in presetStore.remove(at: offsets) }
            HStack {
                Button("Reset to Built-ins") { presetStore.resetToDefaults() }
                    .help("Replace all presets with the 9 built-in starter presets.")
                Spacer()
                Button("Add Preset…") { showingNewPreset = true }
            }
        } header: {
            Text("Presets")
        }
    }

    // MARK: - Keychain helpers

    private func typedKeyBinding(_ account: String) -> Binding<String> {
        Binding(get: { typedKeys[account] ?? "" },
                set: { typedKeys[account] = $0 })
    }

    private func refreshStoredKeys() {
        let accounts = AIProvider.httpProviders.map(\.keychainAccount)
            + config.customProviders.map(\.keychainAccount)
        storedKeys = Set(accounts.filter { Keychain.get(account: $0) != nil })
    }

    private func saveTypedKey(account: String) {
        let value = (typedKeys[account] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let status = Keychain.set(value: value, account: account)
        guard status == errSecSuccess else {
            // Keep the typed key in the field so nothing is lost.
            keychainError = (SecCopyErrorMessageString(status, nil) as String?)
                ?? "Keychain error \(status)."
            return
        }
        // Clear the field after save so the secret doesn't sit in
        // memory longer than necessary.
        typedKeys[account] = ""
        refreshStoredKeys()
    }
}

// MARK: - Custom provider editor

/// Sheet item: the provider being edited and whether it's new.
private struct CustomProviderDraft: Identifiable {
    var provider: CustomAIProvider
    var isNew: Bool
    var id: UUID { provider.id }
}

private struct CustomProviderEditor: View {
    @State private var provider: CustomAIProvider
    @State private var apiKey = ""
    @State private var removeStoredKey = false
    private let isNew: Bool
    private let hasStoredKey: Bool
    /// (provider, key to store or nil, remove the stored key)
    private let onSave: (CustomAIProvider, String?, Bool) -> Void
    private let onRemove: () -> Void
    private let onCancel: () -> Void

    init(draft: CustomProviderDraft,
         hasStoredKey: Bool,
         onSave: @escaping (CustomAIProvider, String?, Bool) -> Void,
         onRemove: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        _provider = State(initialValue: draft.provider)
        self.isNew = draft.isNew
        self.hasStoredKey = hasStoredKey
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
    }

    private var endpointIsValid: Bool {
        AIClient.endpointURL(from: provider.endpointURL) != nil
    }

    private var canSave: Bool {
        endpointIsValid
            && !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $provider.name, prompt: Text("Ollama on the studio Mac"))
                TextField("Base URL", text: $provider.endpointURL, prompt: Text("http://192.168.1.20:11434/v1"))
                    .disableAutocorrection(true)
                TextField("Model", text: $provider.model, prompt: Text("llama3.3"))
                    .disableAutocorrection(true)
                SecureField("API key", text: $apiKey,
                            prompt: Text(hasStoredKey ? "Stored in Keychain" : "Optional"))
                if hasStoredKey {
                    Toggle("Remove stored key", isOn: $removeStoredKey)
                        .disabled(!apiKey.isEmpty)
                }
            } header: {
                Text(isNew ? "Add Provider" : "Edit Provider")
            } footer: {
                Text(!provider.endpointURL.isEmpty && !endpointIsValid
                     ? "Enter an http:// or https:// address, e.g. http://192.168.1.20:11434/v1."
                     : "PicaMD sends requests to <Base URL>/chat/completions. Most local servers need no key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if !isNew {
                    Button("Remove Provider", role: .destructive) { onRemove() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var cleaned = provider
                    cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleaned.endpointURL = cleaned.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleaned.model = cleaned.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(cleaned, key.isEmpty ? nil : key, removeStoredKey && key.isEmpty)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 460, height: 340)
    }
}

// MARK: - Preset editor

private struct AIPresetEditor: View {
    @State var preset: AIPreset
    let onSave: (AIPreset) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $preset.name)
                Picker("Hotkey", selection: hotkeyBinding) {
                    Text("None").tag(0)
                    ForEach(1...9, id: \.self) { d in
                        Text("⌃⌘\(d)").tag(d)
                    }
                }
            }
            Section("Prompt") {
                TextField(
                    "System prompt (optional)",
                    text: Binding(
                        get: { preset.systemPrompt ?? "" },
                        set: { preset.systemPrompt = $0.isEmpty ? nil : $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(2...6)

                TextField(
                    "User prompt template (use {{selection}})",
                    text: $preset.userPromptTemplate,
                    axis: .vertical
                )
                .lineLimit(3...10)
            }
            Section("Insertion") {
                Picker("Mode", selection: $preset.insertionMode) {
                    ForEach(AIPreset.InsertionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { onCancel() }
                    Button("Save") { onSave(preset) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
    }

    private var hotkeyBinding: Binding<Int> {
        Binding(
            get: { preset.hotkey ?? 0 },
            set: { preset.hotkey = $0 == 0 ? nil : $0 }
        )
    }
}
