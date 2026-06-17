import SwiftUI

/// Compact find/replace bar that floats at the top-trailing corner of the
/// editor. Pure SwiftUI state bound to a `SearchModel`; the editor does the
/// matching and reports counts back. Mirrors the look of the rest of
/// PicaMD's chrome (`.bar` material, accent tint).
struct SearchBarView: View {
    @ObservedObject var model: SearchModel

    @FocusState private var queryFocused: Bool
    @FocusState private var replaceFocused: Bool

    private var accent: Color { Color(nsColor: ThemeStore.currentAccent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            findRow
            if model.showReplace {
                replaceRow
            }
        }
        .padding(8)
        .frame(width: 420)
        .background(.bar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.top, 8)
        .padding(.trailing, 14)
        .tint(accent)
        .onAppear { queryFocused = true }
        .onChange(of: model.focusToken) { _, _ in
            queryFocused = true
        }
        // ESC anywhere in the bar closes it.
        .onExitCommand { model.close() }
    }

    // MARK: - Find row

    private var findRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            queryField

            countLabel
                .frame(minWidth: 64, alignment: .trailing)

            navButtons

            Divider().frame(height: 16)

            optionToggles

            Divider().frame(height: 16)

            Button {
                model.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Schließen (Esc)")
        }
    }

    private var queryField: some View {
        TextField("Suchen", text: $model.query)
            .textFieldStyle(.roundedBorder)
            .focused($queryFocused)
            .onSubmit { model.next() }
            .frame(minWidth: 120)
            .overlay(alignment: .trailing) {
                if model.invalidRegex {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                        .padding(.trailing, 6)
                        .help("Ungültiges reguläres Ausdrucksmuster")
                }
            }
    }

    private var countLabel: some View {
        Group {
            if model.query.isEmpty {
                Text("")
            } else if model.invalidRegex {
                Text("Ungültig").foregroundStyle(.orange)
            } else if model.resultCount == 0 {
                Text("Kein Treffer").foregroundStyle(.secondary)
            } else {
                Text("\(model.currentIndex) von \(model.resultCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var navButtons: some View {
        HStack(spacing: 2) {
            Button { model.previous() } label: {
                Image(systemName: "chevron.up")
            }
            .help("Vorheriger Treffer (⇧⌘G)")
            Button { model.next() } label: {
                Image(systemName: "chevron.down")
            }
            .help("Nächster Treffer (⌘G)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .semibold))
        .disabled(model.resultCount == 0)
    }

    private var optionToggles: some View {
        HStack(spacing: 3) {
            toggle("Aa", isOn: $model.options.caseSensitive,
                   help: "Groß-/Kleinschreibung beachten")
            toggle(image: "textformat.abc.dottedunderline", isOn: $model.options.wholeWord,
                   help: "Nur ganze Wörter")
            toggle(".*", isOn: $model.options.regex,
                   help: "Regulärer Ausdruck", mono: true)
            toggle(image: "asterisk", isOn: $model.options.ignoreFormatting,
                   help: "Markdown-Formatierung ignorieren (findet **fett** über „fett“)")
        }
    }

    // MARK: - Replace row

    private var replaceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.2.squarepath")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            TextField("Ersetzen", text: $model.replaceText)
                .textFieldStyle(.roundedBorder)
                .focused($replaceFocused)
                .frame(minWidth: 120)

            Spacer(minLength: 4)

            Button("Ersetzen") { model.replaceCurrent() }
                .disabled(replaceDisabled || model.resultCount == 0)
            Button("Alle") { model.replaceAll() }
                .disabled(replaceDisabled || model.resultCount == 0)
        }
        .font(.system(size: 11))
        .help(model.options.ignoreFormatting
              ? "Ersetzen ist deaktiviert, solange „Formatierung ignorieren“ aktiv ist"
              : "")
    }

    private var replaceDisabled: Bool { model.options.ignoreFormatting }

    // MARK: - Toggle helpers

    @ViewBuilder
    private func toggle(_ title: String, isOn: Binding<Bool>, help: String, mono: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11, weight: .medium))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(help)
    }

    @ViewBuilder
    private func toggle(image: String, isOn: Binding<Bool>, help: String) -> some View {
        Toggle(isOn: isOn) {
            Image(systemName: image).font(.system(size: 11))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(help)
    }
}
