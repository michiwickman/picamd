import SwiftUI
import AppKit

/// Opens the Settings window from code that isn't a SwiftUI view (an
/// NSAlert button, a palette action). `showSettingsWindow:` stopped
/// working on macOS 14 — it only logs "Please use SettingsLink" — so
/// this performs the app menu's own Settings… item (⌘,) instead.
@MainActor
enum SettingsOpener {
    static func open() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        let index = appMenu.items.firstIndex {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
        }
        if let index {
            appMenu.performActionForItem(at: index)
        }
    }

    /// Settings, showing `pane` (the window reads the stored pane, also
    /// while it is already open).
    static func open(_ pane: SettingsPane) {
        UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.storageKey)
        open()
    }
}

/// The four panes of the Settings window, in toolbar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, editor, ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    return "General"
        case .appearance: return "Appearance"
        case .editor:     return "Editor"
        case .ai:         return "AI"
        }
    }

    var systemImage: String {
        switch self {
        case .general:    return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .editor:     return "textformat"
        case .ai:         return "sparkles"
        }
    }

    /// Fixed content size per pane. The Settings window only resizes to
    /// a pane that has an explicit height (a `Form` alone leaves it at
    /// 450 pt whatever its content); width follows the design board.
    /// Heights are the measured form heights (macOS 27.0.1: General 208
    /// to 209, Appearance 505 or 595, Editor 621 to 622.5; they vary by
    /// a point or two between runs) plus at least 5 pt, so a rounding
    /// difference never brings up a scroll bar (`SettingsPaneSizeTests`).
    /// Appearance grows by the two colour-picker rows while Custom
    /// colours are on; the AI pane is longer than any screen-friendly
    /// height and scrolls.
    func contentSize(customColors: Bool) -> CGSize {
        switch self {
        case .general:    return CGSize(width: 640, height: 216)
        case .appearance: return CGSize(width: 640, height: customColors ? 600 : 510)
        case .editor:     return CGSize(width: 640, height: 630)
        case .ai:         return CGSize(width: 640, height: 600)
        }
    }

    /// PicaMD's own record of the open pane.
    static let storageKey = "PicaMD.settings.selectedPane"
    /// Where SwiftUI kept the tab index of the 0.9 Settings window (five
    /// tabs: Presets, Palette, Typography, Blocks, AI).
    static let legacyIndexKey = "com_apple_SwiftUI_Settings_selectedTabIndex"

    /// The pane to open. A stored pane name wins. Without one, the 0.9
    /// tab index is read: an index the four-pane layout has (0-3) opens
    /// the pane that now holds that tab's controls, and Blocks (3) is the
    /// only one of those outside Appearance. Any other index, including
    /// the old AI tab (4), opens Appearance: the first Settings visit
    /// after the redesign starts where most of the moved controls are.
    static func resolve(stored: String?, legacyIndex: Int?) -> SettingsPane {
        if let stored, let pane = SettingsPane(rawValue: stored) {
            return pane
        }
        switch legacyIndex {
        case 3: return .editor   // Blocks: code style, word count, typing
        default: return .appearance
        }
    }
}

/// macOS-native settings window behind ⌘,: toolbar tabs General /
/// Appearance / Editor / AI (design board "Settings"). Every control
/// writes through `ThemeStore` (theme) or `@AppStorage` (editor and
/// general switches); `SettingsRegistryTests` checks that every stored
/// theme field has a control here.
struct SettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @AppStorage(SettingsPane.storageKey) private var storedPane = ""

    private var selection: Binding<SettingsPane> {
        Binding(
            get: {
                SettingsPane.resolve(
                    stored: storedPane,
                    legacyIndex: UserDefaults.standard.object(forKey: SettingsPane.legacyIndexKey) as? Int)
            },
            set: { storedPane = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selection) {
            tab(.general)
            tab(.appearance)
            tab(.editor)
            tab(.ai)
        }
    }

    private func tab(_ pane: SettingsPane) -> some View {
        Self.content(of: pane, customColors: themeStore.theme.useCustomColors)
            .tabItem { Label(pane.title, systemImage: pane.systemImage) }
            .tag(pane)
    }

    /// A pane's form at its fixed size (`SettingsPaneSizeTests` measures
    /// the forms against these sizes).
    @ViewBuilder
    static func content(of pane: SettingsPane, customColors: Bool) -> some View {
        let size = pane.contentSize(customColors: customColors)
        Group {
            switch pane {
            case .general: GeneralSettingsPane()
            case .appearance: AppearanceSettingsPane()
            case .editor: EditorSettingsPane()
            case .ai: AISettingsPane()
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ThemeStore())
        .environmentObject(UpdaterController())
}
