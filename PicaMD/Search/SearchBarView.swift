import SwiftUI

/// The find/replace bar, docked under the toolbar across the editor
/// column like TextEdit's and Xcode's (board `FindReplace`): a search
/// field whose magnifier opens the options menu and that shows "n of m"
/// inside it, a ‹ › segment and Done; in Find and Replace mode a second
/// row with the replace field, Replace and All. Pure SwiftUI state bound
/// to a `SearchModel`; the editor does the matching and reports counts
/// back. No accent tint — the bar is chrome.
struct SearchBarView: View {
    @ObservedObject var model: SearchModel

    @FocusState private var queryFocused: Bool
    @FocusState private var replaceFocused: Bool

    /// Board `FindReplace`: rows of 36 pt, 20 pt in from the leading
    /// edge and 14 pt from the trailing one, 8 pt between controls.
    static let rowHeight: CGFloat = 36
    static let fieldHeight: CGFloat = 26
    static let fieldRadius: CGFloat = 7
    /// Done sits in its own column; Replace and All line up beside it.
    static let doneColumnWidth: CGFloat = 64
    static let replaceColumnWidth: CGFloat = 138

    var body: some View {
        VStack(spacing: 0) {
            findRow
            if model.showReplace {
                replaceRow
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity)
        // The system bar material, the surface toolbars and find bars use
        // on macOS 27 in both appearances, with the hairline under it.
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focusQueryField() }
        .onChange(of: model.focusToken) { _, _ in focusQueryField() }
        // ESC anywhere in the bar closes it.
        .onExitCommand { model.close() }
    }

    // MARK: - Find row

    private var findRow: some View {
        HStack(spacing: 8) {
            searchField
            navigationSegment
            Button("Done") { model.close() }
                .buttonBorderShape(.capsule)
                .help("Close the find bar (Esc)")
                .frame(width: Self.doneColumnWidth, alignment: .trailing)
        }
        .frame(height: Self.rowHeight)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            optionsMenu
            TextField("Find", text: $model.query)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($queryFocused)
                // Return: next match; Shift-Return: previous. onSubmit runs
                // inside the Return key event, so its modifiers are current.
                .onSubmit {
                    let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    model.submitQuery(shift: shift)
                }
                // Focus stays in the field while Return and ⌘G move the
                // match, so the count travels with it for VoiceOver.
                .accessibilityValue(model.statusText ?? "")
            if model.invalidRegex {
                // Red, not orange: system orange on the light bar is about
                // 2.2:1, under the 3:1 a status symbol needs.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 11))
                    .help("Invalid regular expression")
                    .accessibilityLabel("Invalid regular expression")
            }
            countLabel
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: Self.fieldHeight)
        .modifier(FieldChrome(focused: queryFocused))
    }

    /// Board: magnifier plus a small chevron, no icons in the menu.
    /// Contains / Starts With / Whole Word are one radio group; every
    /// binding writes the whole `model.options` struct, so its `didSet`
    /// persists the choice and re-runs the search.
    private var optionsMenu: some View {
        Menu {
            Toggle("Ignore Case", isOn: Binding(
                get: { !model.options.caseSensitive },
                set: { model.options.caseSensitive = !$0 }))
            Toggle("Wrap Around", isOn: $model.options.wrapAround)
            Divider()
            Picker("Match", selection: $model.options.matchStyle) {
                Text("Contains").tag(MatchStyle.contains)
                Text("Starts With").tag(MatchStyle.startsWith)
                Text("Whole Word").tag(MatchStyle.wholeWord)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle("Regular Expression", isOn: $model.options.regex)
            Toggle("Ignore Markdown Formatting", isOn: $model.options.ignoreFormatting)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Find options")
        .accessibilityLabel("Find options")
    }

    private var countLabel: some View {
        Group {
            if let status = model.statusText {
                // "Invalid" is the only explanation of the error, so it is
                // drawn in the primary colour (orange was about 2.2:1).
                Text(verbatim: status)
                    .foregroundStyle(model.invalidRegex ? .primary : .secondary)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        // The field keeps focus, and a Text beside it is not spoken when
        // it changes. Announced after a short pause, so typing a query
        // doesn't queue one announcement per keystroke.
        .accessibilityHidden(true)
        .task(id: model.statusText) {
            guard let status = model.statusText else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(status).post()
        }
    }

    /// Previous / next as one two-segment control.
    private var navigationSegment: some View {
        ControlGroup {
            Button { model.previous() } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous match (⇧⌘G)")
            .accessibilityLabel("Previous match")
            Button { model.next() } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next match (⌘G)")
            .accessibilityLabel("Next match")
        }
        .fixedSize()
        .disabled(model.resultCount == 0)
    }

    // MARK: - Replace row

    private var replaceRow: some View {
        HStack(spacing: 8) {
            TextField("Replace", text: $model.replaceText)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($replaceFocused)
                .onSubmit { model.replaceCurrent() }
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .frame(height: Self.fieldHeight)
                .modifier(FieldChrome(focused: replaceFocused))

            HStack(spacing: 6) {
                Button("Replace") { model.replaceCurrent() }
                    .buttonBorderShape(.capsule)
                    .disabled(!model.canReplace)
                // The board labels it "All"; VoiceOver needs the full name.
                Button("All") { model.replaceAll() }
                    .buttonBorderShape(.capsule)
                    .disabled(!model.canReplaceAll)
                    .accessibilityLabel("Replace All")
            }
            // Disabled buttons still show their tooltip, which is where
            // the reason belongs.
            .help(model.replaceDisabledReason ?? "")
            .frame(width: Self.replaceColumnWidth, alignment: .trailing)

            Color.clear.frame(width: Self.doneColumnWidth, height: 1)
        }
        .frame(height: Self.rowHeight)
    }

    /// Focus + select-all the query field. Deferred a runloop tick: a
    /// TextField that was just inserted into the layout isn't in the
    /// window's responder chain yet, so a synchronous focus request from
    /// `onAppear` is dropped and keystrokes keep going to the document.
    /// Resetting to `false` first makes ⌘F re-focus the field even when
    /// SwiftUI still believes it's focused after the editor took over.
    private func focusQueryField() {
        queryFocused = false
        DispatchQueue.main.async { queryFocused = true }
    }
}

/// The rounded field surface from the board: text background, a hairline
/// border and, while focused, a 3 pt ring in the system focus colour (the
/// keyboard-focus colour follows the system accent, not the editor's).
private struct FieldChrome: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SearchBarView.fieldRadius, style: .continuous)
        content
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: SearchBarView.fieldRadius + 3, style: .continuous)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
    }
}
