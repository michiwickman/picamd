import SwiftUI

/// Settings ▸ Editor: heading and code-block structure, layout switches,
/// typing aids, and resetting the look.
struct EditorSettingsPane: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @AppStorage(EditorPreferences.autoPairKey) private var autoPair = true
    @AppStorage(EditorPreferences.smartPunctuationKey) private var smartPunctuation = false
    @State private var confirmingReset = false

    private var theme: EditorTheme { themeStore.theme }

    var body: some View {
        Form {
            Section("Headings") {
                Picker("Heading scale", selection: Binding(
                    get: { theme.headingScale },
                    set: { themeStore.setHeadingScale($0) }
                )) {
                    ForEach(HeadingScale.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                // The rule is drawn under H1 and H2 (SyntaxHighlighter,
                // `level <= 2`); the label used to say H1 only.
                Toggle("Hairline under H1 and H2", isOn: Binding(
                    get: { theme.headingRule },
                    set: { themeStore.setHeadingRule($0) }
                ))
            }

            Section("Blocks") {
                Picker("Code block style", selection: Binding(
                    get: { theme.codeStyle },
                    set: { themeStore.setCodeStyle($0) }
                )) {
                    ForEach(CodeBlockStyle.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { theme.cardLayout },
                    set: { themeStore.setCardLayout($0) }
                )) {
                    Text("Card layout")
                    Text("Draws the page as a card on a tinted background, the Tahoe look.")
                }
                Toggle("Show word count", isOn: Binding(
                    get: { theme.showStatusBar },
                    set: { themeStore.setShowStatusBar($0) }
                ))
            } header: {
                Text("Window")
            }

            Section {
                Toggle("Auto-pair brackets and quotes", isOn: $autoPair)
                Toggle("Smart punctuation (– — … “ ”)", isOn: $smartPunctuation)
            } header: {
                Text("Typing")
            } footer: {
                Text("Smart punctuation rewrites what you type and stays out of code, frontmatter and HTML. Markdown syntax like `---` and `|---|` is left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Appearance…") { confirmingReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the appearance to the defaults?",
                            isPresented: $confirmingReset) {
            Button("Reset Appearance", role: .destructive) { themeStore.resetToDefault() }
        } message: {
            Text("Preset, colours, fonts, size, line width and the switches above go back to their defaults. Auto-pair and smart punctuation stay as they are.")
        }
    }
}
