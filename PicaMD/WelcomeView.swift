import SwiftUI
import AppKit

/// Launch / welcome screen (board `Welcome`), shown in an AppKit-hosted
/// window by `WelcomeWindowController` when PicaMD has no open document.
/// Left: app icon, name, version, New and Open, the launch checkbox.
/// Right: recent documents, the first one selected.
///
/// The view is hosted OUTSIDE the SwiftUI `DocumentGroup` scene (via
/// `NSHostingView`), so it has no access to the scene's `themeStore`. It
/// borrows the user's accent through `ThemeStore.currentAccent` for the
/// icons, the checkbox and the selected row. Light and dark
/// come from semantic system colours: on macOS 27 the window background
/// is white / #1E1E1E, and the recents column's secondary fill over it
/// gives the board's #ECECEF (dark: #2F2F2F).
struct WelcomeView: View {
    let onNew: () -> Void
    let onOpen: () -> Void
    let onOpenRecent: (URL) -> Void

    @ObservedObject var recents: RecentDocumentsMenuModel
    @AppStorage(EditorPreferences.showWelcomeWindowKey) private var showOnLaunch = true

    private var accent: NSColor { ThemeStore.currentAccent }

    static let size = CGSize(width: 800, height: 500)
    static let leftWidth: CGFloat = 440

    var body: some View {
        HStack(spacing: 0) {
            identityColumn
                .frame(width: Self.leftWidth)
                .frame(maxHeight: .infinity)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 0.5)
            WelcomeRecentsList(
                urls: recents.urls,
                accent: accent,
                subtitle: { RecentDocumentsStore.list.subtitle(for: $0) },
                onOpen: onOpenRecent
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .secondarySystemFill))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color(nsColor: accent))
        .ignoresSafeArea()
    }

    // MARK: - Left: identity + actions

    private var identityColumn: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                appIcon
                Text("PicaMD")
                    .font(.system(size: 26, weight: .bold))
                    .padding(.top, 18)
                Text("Version \(Self.version.short)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .help("Build \(Self.version.build)")
                VStack(spacing: 8) {
                    WelcomeActionCard(
                        symbol: "doc.badge.plus", title: "New Document",
                        subtitle: "Start writing", shortcut: "⌘N",
                        accent: accent, action: onNew)
                    WelcomeActionCard(
                        symbol: "folder", title: "Open…",
                        subtitle: "Any Markdown file", shortcut: "⌘O",
                        accent: accent, action: onOpen)
                }
                .padding(.top, 30)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 58)

            Toggle("Show this window when PicaMD opens", isOn: $showOnLaunch)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
                .padding(.bottom, 18)
        }
    }

    /// The app's own icon as the system renders it, so it follows the
    /// `.icon` file (and any future replacement) without an asset name.
    /// The image carries the icon grid's transparent margin (the shape
    /// fills about 80 % of it): drawn at 120 pt the shape is the board's
    /// 96 pt, and the negative padding keeps the board's spacing.
    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 120, height: 120)
            .padding(-12)
            .accessibilityHidden(true)
    }

    static var version: (short: String, build: String) {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "?",
                info?["CFBundleVersion"] as? String ?? "?")
    }
}

/// One of the two 300 × 52 action cards on the left. The shortcut is a
/// hint only: ⌘N and ⌘O go through the File menu, so a press in the
/// welcome window can't fire both a button and the menu item.
private struct WelcomeActionCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let shortcut: String
    let accent: NSColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color(nsColor: accent))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(width: 300, height: 52)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(WelcomeCardButtonStyle())
        .accessibilityHint(subtitle)
    }
}

/// Card fill: a tertiary fill at rest (#F2F2F2 on white, the board's
/// #F4F4F6; #2A2A2A on dark), one step stronger on hover and press.
private struct WelcomeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration)
    }

    /// A view of its own, because hover state can't live in the style.
    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            let fill: NSColor = configuration.isPressed ? .systemFill
                : hovering ? .secondarySystemFill : .tertiarySystemFill
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: fill))
                )
                .onHover { hovering = $0 }
        }
    }
}

/// The recents column: "Recent" header, rows of 46 pt, the selection
/// filled with the accent. A click opens a row; arrow keys move the
/// selection and Return opens it.
struct WelcomeRecentsList: View {
    let urls: [URL]
    let accent: NSColor
    let subtitle: (URL) -> String
    let onOpen: (URL) -> Void

    @State private var selection = 0
    @State private var hovered: URL?
    @FocusState private var focused: Bool

    static let rowHeight: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            if urls.isEmpty {
                Text("No Recent Documents")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 44)
            } else {
                rows
            }
        }
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.return) { openSelection() }
        .onChange(of: urls) { _, new in
            selection = WelcomeRecentsSelection.clamped(selection, count: new.count)
        }
        .task {
            // The list joins the window's key loop one pass after the
            // hosting view, as in the command palette.
            await Task.yield()
            focused = true
        }
        .contextMenu {
            Button("Clear Recents") { RecentDocumentsStore.clear() }
                .disabled(urls.isEmpty)
        }
    }

    private var rows: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                        row(url, selected: index == selection)
                            .id(url)
                    }
                }
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selection) { _, index in
                guard urls.indices.contains(index) else { return }
                scroller.scrollTo(urls[index])
            }
        }
    }

    private func row(_ url: URL, selected: Bool) -> some View {
        let darkText = PaletteSelectionStyle.usesDarkText(on: accent)
        let primary: Color = selected ? (darkText ? .black : .white) : .primary
        let secondary: Color = selected
            ? primary.opacity(PaletteSelectionStyle.selectedSecondaryOpacity) : .secondary
        let fill: Color = selected ? Color(nsColor: accent)
            : hovered == url ? Color(nsColor: .tertiarySystemFill) : .clear
        let place = subtitle(url)
        return Button { onOpen(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .font(.system(size: 17))
                    .foregroundStyle(primary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(place)
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { hovered = $0 ? url : (hovered == url ? nil : hovered) }
        .help(url.path)
        .contextMenu {
            Button("Open") { onOpen(url) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Remove from Recents") { RecentDocumentsStore.remove(url) }
            Button("Clear Recents") { RecentDocumentsStore.clear() }
        }
        .accessibilityLabel("\(url.lastPathComponent), \(place)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(by delta: Int) -> KeyPress.Result {
        guard !urls.isEmpty else { return .ignored }
        selection = WelcomeRecentsSelection.moved(selection, by: delta, count: urls.count)
        // Focus stays on the list, so VoiceOver would not say which file
        // Return opens.
        let url = urls[selection]
        AccessibilityNotification.Announcement("\(url.lastPathComponent), \(subtitle(url))").post()
        return .handled
    }

    private func openSelection() -> KeyPress.Result {
        guard urls.indices.contains(selection) else { return .ignored }
        onOpen(urls[selection])
        return .handled
    }
}

/// Selection arithmetic for the recents list, kept out of the view for
/// tests: held at both ends (no wrap, like Finder and the palette), and
/// pulled back inside the list when entries are removed.
enum WelcomeRecentsSelection {
    static func moved(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }

    static func clamped(_ index: Int, count: Int) -> Int {
        count == 0 ? 0 : min(max(index, 0), count - 1)
    }
}
