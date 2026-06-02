import SwiftUI
import AppKit

/// Launch / welcome screen, shown in an AppKit-hosted window by
/// `WelcomeWindowController` when PicaMD has no open document. Lists
/// recently opened documents and offers New / Open actions — so a
/// double-click lands you on a hub instead of a Finder open panel.
///
/// The view is hosted OUTSIDE the SwiftUI `DocumentGroup` scene (via
/// `NSHostingView`), so it has no access to the scene's `themeStore`.
/// It stays self-contained and reads recents straight from
/// `NSDocumentController`. It only borrows the user's accent colour
/// (via `ThemeStore.currentAccent`) for a light brand tint.
struct WelcomeView: View {
    let onNew: () -> Void
    let onOpen: () -> Void
    let onOpenRecent: (URL) -> Void
    let onClearRecents: () -> Void

    /// Recents passed in at show-time (already existence-filtered by the
    /// controller). Kept as state so "Clear" can empty the list live.
    @State var recents: [URL]

    private var accent: Color { Color(nsColor: ThemeStore.currentAccent) }

    var body: some View {
        HStack(spacing: 0) {
            identityColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)

            Divider()

            recentsColumn
                .frame(width: 300)
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
        }
        .frame(width: 720, height: 440)
        .tint(accent)
    }

    // MARK: - Left: identity + actions

    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                appLogo
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PicaMD")
                        .font(.system(size: 28, weight: .bold))
                    Text("Markdown, schnell und schön.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer().frame(height: 6)

            Button(action: onNew) {
                Label("New Document", systemImage: "doc.badge.plus")
                    .frame(maxWidth: 230)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)

            Button(action: onOpen) {
                Label("Open Document…", systemImage: "folder")
                    .frame(maxWidth: 230)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .keyboardShortcut("o", modifiers: .command)

            Spacer()

            Text(appVersion)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var appLogo: some View {
        Group {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "doc.richtext")
                    .resizable().scaledToFit()
                    .foregroundStyle(accent)
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    // MARK: - Right: recents

    private var recentsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recently Opened")
                    .font(.headline)
                Spacer()
                if !recents.isEmpty {
                    Button("Clear") {
                        onClearRecents()
                        recents = []
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if recents.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("No recent documents.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(recents, id: \.self) { url in
                            recentRow(url)
                        }
                    }
                }
            }
        }
    }

    private func recentRow(_ url: URL) -> some View {
        Button {
            onOpenRecent(url)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
    }
}
