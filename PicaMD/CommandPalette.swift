import SwiftUI
import AppKit

/// One row of the command palette (⇧⌘P): a heading to jump to, or a
/// command with the shortcut the menu shows for it.
struct CommandPaletteItem: Identifiable {
    enum Section: Int, CaseIterable, Comparable {
        case headings, commands

        var title: String {
            switch self {
            case .headings: return "Headings"
            case .commands: return "Commands"
            }
        }

        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }
    }

    /// Stable within one palette session (scroll anchor, row identity).
    let id: String
    let section: Section
    let title: String
    var subtitle: String?
    var icon: String?
    /// Right-aligned shortcut (`⌃⌘S`), nil when the command has none.
    var shortcut: String?
    /// A checkmark for toggles that are on (Show Outline, Focus Mode …).
    var isOn: Bool?
    let perform: @MainActor () -> Void

    /// What VoiceOver reads for the row, as one phrase: "Show Outline, on".
    var accessibilityLabel: String {
        var parts = [title]
        if let subtitle { parts.append(subtitle) }
        if isOn == true { parts.append("on") }
        return parts.joined(separator: ", ")
    }

    /// The shortcut, read after the label.
    var accessibilityValue: String { shortcut ?? "" }

    /// Spoken when the arrow keys move the selection: focus stays in the
    /// search field, so VoiceOver would otherwise not say which row Return
    /// runs.
    var selectionAnnouncement: String {
        shortcut.map { "\(accessibilityLabel), \($0)" } ?? accessibilityLabel
    }
}

/// The palette's list as pure logic: which items match the query, in
/// which order, under which section header.
enum CommandPaletteFilter {
    struct Group: Identifiable {
        let section: CommandPaletteItem.Section
        let items: [CommandPaletteItem]
        var id: CommandPaletteItem.Section { section }
    }

    /// Only items whose title matches the query (`FuzzyMatch`), best
    /// first; equal scores keep their given order. Headings come before
    /// Commands, and a section without matches is left out. An empty
    /// query lists everything in the given order.
    static func groups(_ items: [CommandPaletteItem], query: String) -> [Group] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let ranked: [CommandPaletteItem]
        if trimmed.isEmpty {
            ranked = items
        } else {
            ranked = items.enumerated()
                .compactMap { offset, item -> (item: CommandPaletteItem, score: Int, offset: Int)? in
                    guard let score = FuzzyMatch.score(query: trimmed, in: item.title) else { return nil }
                    return (item, score, offset)
                }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
                .map(\.item)
        }
        return CommandPaletteItem.Section.allCases.compactMap { section in
            let members = ranked.filter { $0.section == section }
            return members.isEmpty ? nil : Group(section: section, items: members)
        }
    }

    /// Selection index moved by `delta`, held at both ends.
    static func moved(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }
}

/// Text on the palette's selection, which is filled with the theme
/// accent. White, as on every Mac selection, unless the accent is so
/// light that white falls below a 3:1 contrast (WCAG, large text and UI):
/// then black. Blue, Pink, Purple and Monochrome keep white; Warm Orange,
/// Green and pale custom colours get black.
enum PaletteSelectionStyle {
    static func usesDarkText(on accent: NSColor) -> Bool {
        let whiteContrast = 1.05 / (relativeLuminance(accent) + 0.05)
        return whiteContrast < 3
    }

    /// Subtitle, checkmark and shortcut on the selected row are as opaque
    /// as the title. White at 80 % over Blue, Pink or Purple falls below
    /// 3:1; a macOS menu highlight doesn't dim its shortcuts either.
    static let selectedSecondaryOpacity: CGFloat = 1

    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}

/// Spotlight-style palette floating inside the document window (board
/// `Palette`): a 10 % scrim over the whole window, a 640 pt glass panel
/// 90 pt from the top. Part of the window's own view tree rather than a
/// sheet, so keyboard focus moves into its field without a modal session
/// and Esc or a click on the scrim always closes it.
struct CommandPaletteOverlay: View {
    let items: [CommandPaletteItem]
    /// The theme accent for the selected row.
    let accent: NSColor
    /// Called once: with the chosen item, or nil when dismissed.
    let finish: (CommandPaletteItem?) -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private static let panelWidth: CGFloat = 640
    private static let topOffset: CGFloat = 90
    private static let rowHeight: CGFloat = 36
    private static let headerHeight: CGFloat = 29
    private static let maxListHeight: CGFloat = 420

    var body: some View {
        let groups = CommandPaletteFilter.groups(items, query: query)
        let flat = groups.flatMap(\.items)
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(0.10)
                    .contentShape(Rectangle())
                    .onTapGesture { finish(nil) }
                panel(groups: groups, flat: flat)
                    .frame(width: min(Self.panelWidth, max(proxy.size.width - 32, 0)))
                    .padding(.top, Self.topOffset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        // Esc closes the palette wherever focus is inside it, not only in
        // the search field.
        .onExitCommand { finish(nil) }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .task {
            // The field joins the window one pass after the overlay.
            await Task.yield()
            searchFocused = true
        }
    }

    private func panel(groups: [CommandPaletteFilter.Group], flat: [CommandPaletteItem]) -> some View {
        VStack(spacing: 0) {
            searchField(flat: flat)
            if !flat.isEmpty {
                Divider()
                results(groups: groups, flat: flat)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.3), radius: 40, y: 30)
        // Clicks on the panel's empty parts stay in the panel instead of
        // reaching the scrim behind it.
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { searchFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Palette")
        // VoiceOver stays inside the panel instead of wandering into the
        // editor, sidebar and inspector behind the scrim.
        .accessibilityAddTraits(.isModal)
    }

    private func searchField(flat: [CommandPaletteItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $query, prompt: Text("Commands and headings"))
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($searchFocused)
                .onSubmit { run(flat) }
                .onExitCommand { finish(nil) }
                .onKeyPress(.escape) { finish(nil); return .handled }
                .onKeyPress(.downArrow) {
                    move(by: 1, in: flat)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1, in: flat)
                    return .handled
                }
                // The rows can't take focus, so Tab would leave the palette
                // for the editor behind it while the palette stays open.
                .onKeyPress(.tab) { .handled }
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
    }

    private func results(groups: [CommandPaletteFilter.Group], flat: [CommandPaletteItem]) -> some View {
        let contentHeight = CGFloat(groups.count) * Self.headerHeight
            + CGFloat(flat.count) * Self.rowHeight + 8
        let selectedID = flat.indices.contains(selectedIndex) ? flat[selectedIndex].id : nil
        return ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Text(group.section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(EdgeInsets(top: 10, leading: 20, bottom: 4, trailing: 20))
                            .frame(height: Self.headerHeight, alignment: .bottomLeading)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in
                            row(item, selected: item.id == selectedID)
                                .id(item.id)
                                .onTapGesture {
                                    if let index = flat.firstIndex(where: { $0.id == item.id }) {
                                        selectedIndex = index
                                    }
                                    finish(item)
                                }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, Self.maxListHeight))
            .onChange(of: selectedIndex) { _, _ in
                guard let selectedID else { return }
                scroller.scrollTo(selectedID)
            }
        }
    }

    private func row(_ item: CommandPaletteItem, selected: Bool) -> some View {
        let darkText = PaletteSelectionStyle.usesDarkText(on: accent)
        let primary: Color = selected ? (darkText ? .black : .white) : .primary
        let secondary: Color = selected
            ? primary.opacity(PaletteSelectionStyle.selectedSecondaryOpacity) : .secondary
        return HStack(spacing: 10) {
            Image(systemName: item.icon ?? "command")
                .font(.system(size: 16))
                .frame(width: 20)
                .foregroundStyle(selected ? primary : .secondary)
                .accessibilityHidden(true)
            Text(item.title)
                .font(.system(size: 14))
                .foregroundStyle(primary)
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.isOn == true {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondary)
                    .accessibilityLabel("On")
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: accent))
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        // One VoiceOver stop per row instead of one per text, with the
        // row's own action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(item.accessibilityValue)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { finish(item) }
    }

    private func move(by delta: Int, in flat: [CommandPaletteItem]) {
        let next = CommandPaletteFilter.moved(selectedIndex, by: delta, count: flat.count)
        selectedIndex = next
        guard flat.indices.contains(next) else { return }
        AccessibilityNotification.Announcement(flat[next].selectionAnnouncement).post()
    }

    private func run(_ flat: [CommandPaletteItem]) {
        guard flat.indices.contains(selectedIndex) else { return }
        finish(flat[selectedIndex])
    }
}
