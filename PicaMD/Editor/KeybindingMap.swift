import AppKit

/// User-customisable mapping from key combos to editor actions.
///
/// Loaded once at app start from
/// `~/Library/Application Support/PicaMD/keybindings.json`. Falls
/// back to the built-in default for every entry that is missing or
/// malformed. The Format menu and the command palette show the same
/// combos, so a rebinding moves the menu shortcut too.
///
/// JSON shape:
///
///     {
///       "headingH1": "cmd+1",
///       "headingH2": "cmd+2",
///       …
///       "moveLineUp": "cmd+option+up",
///       "duplicateLine": "cmd+shift+d",
///       "selectLine": "cmd+l",
///       "strikethrough": "cmd+shift+x"
///     }
///
/// Modifier names: `cmd`, `shift`, `option`, `ctrl` (any order, joined
/// by `+`). Keys: a single character (`a`–`z`, `0`–`9`, punctuation),
/// the literal name `up`/`down`/`left`/`right`, or `escape`/`return`/
/// `tab`/`space`.
///
/// Anything else falls back to the default.
enum KeybindingAction: String, CaseIterable, Codable {
    case headingParagraph = "headingParagraph"   // ⌘0 by default
    case headingH1 = "headingH1"
    case headingH2 = "headingH2"
    case headingH3 = "headingH3"
    case headingH4 = "headingH4"
    case headingH5 = "headingH5"
    case headingH6 = "headingH6"
    case moveLineUp = "moveLineUp"
    case moveLineDown = "moveLineDown"
    case duplicateLine = "duplicateLine"
    case selectLine = "selectLine"
    case bold = "bold"                           // ⌘B
    case italic = "italic"                       // ⌘I
    case strikethrough = "strikethrough"         // no default combo
    case inlineCode = "inlineCode"               // no default combo
    case link = "link"                           // ⌘K
    case checklist = "checklist"                 // no default combo
    case quote = "quote"                         // no default combo
    case table = "table"                         // no default combo

    /// Title in the Format menu and the command palette.
    var title: String {
        switch self {
        case .headingParagraph: return "Body"
        case .headingH1: return "Heading 1"
        case .headingH2: return "Heading 2"
        case .headingH3: return "Heading 3"
        case .headingH4: return "Heading 4"
        case .headingH5: return "Heading 5"
        case .headingH6: return "Heading 6"
        case .moveLineUp: return "Move Line Up"
        case .moveLineDown: return "Move Line Down"
        case .duplicateLine: return "Duplicate Line"
        case .selectLine: return "Select Line"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .inlineCode: return "Inline Code"
        case .link: return "Link…"
        case .checklist: return "Checklist"
        case .quote: return "Quote"
        case .table: return "Table"
        }
    }

    /// Edit ▸ Undo <name>. Nil for Select Line, which changes no text.
    var undoActionName: String? {
        switch self {
        case .selectLine: return nil
        case .link: return "Link"
        case .table: return "Insert Table"
        default: return title
        }
    }

    /// Symbol in the command palette.
    var symbolName: String {
        switch self {
        case .headingParagraph: return "text.alignleft"
        case .headingH1, .headingH2, .headingH3, .headingH4, .headingH5, .headingH6: return "number"
        case .moveLineUp: return "arrow.up"
        case .moveLineDown: return "arrow.down"
        case .duplicateLine: return "plus.square.on.square"
        case .selectLine: return "selection.pin.in.out"
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .checklist: return "checklist"
        case .quote: return "text.quote"
        case .table: return "tablecells"
        }
    }
}

struct KeyCombo: Equatable {
    /// Unicode-lowercased character, or one of the named keys
    /// (`"up"`, `"down"`, `"left"`, `"right"`, `"escape"`, `"return"`,
    /// `"tab"`, `"space"`). Stored as the canonical lowercase form
    /// regardless of how the user wrote it.
    let key: String
    /// `NSEvent.ModifierFlags` masked to the device-independent flags
    /// we care about (`cmd`/`shift`/`option`/`ctrl`).
    let modifiers: NSEvent.ModifierFlags

    /// Parse a string like `"cmd+shift+d"` or `"cmd+option+up"`.
    static func parse(_ raw: String) -> KeyCombo? {
        let parts = raw
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces).lowercased() }
        guard let last = parts.last, !last.isEmpty else { return nil }
        // The last token is the *key*, not a modifier. Reject input
        // like `"cmd"` that's just a modifier name with no key.
        let modifierNames: Set<String> = [
            "cmd", "command", "shift", "option", "opt", "alt", "ctrl", "control"
        ]
        if modifierNames.contains(last) { return nil }
        var mods: NSEvent.ModifierFlags = []
        for token in parts.dropLast() {
            switch token {
            case "cmd", "command":     mods.insert(.command)
            case "shift":              mods.insert(.shift)
            case "option", "opt", "alt": mods.insert(.option)
            case "ctrl", "control":    mods.insert(.control)
            default: return nil
            }
        }
        return KeyCombo(key: last, modifiers: mods)
    }

    /// The combo as a menu shows it: modifiers in Apple's order
    /// (⌃⌥⇧⌘), then the key (`⌥⌘↑`, `⇧⌘D`).
    var displayString: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        switch key {
        case "up": out += "↑"
        case "down": out += "↓"
        case "left": out += "←"
        case "right": out += "→"
        case "escape": out += "⎋"
        case "return": out += "↩"
        case "tab": out += "⇥"
        case "space": out += "Space"
        default: out += key.uppercased()
        }
        return out
    }

    /// The modifier keys shortcuts are built from.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Match the combo against an `NSEvent`. Modifiers must match
    /// exactly (so `cmd+1` doesn't fire when the user holds
    /// `cmd+shift+1`).
    func matches(_ event: NSEvent) -> Bool {
        // Compare only the modifiers a shortcut can be made of. The
        // device-independent mask also keeps Caps Lock, and arrow keys
        // always carry `.numericPad` + `.function` — with those included,
        // ⌘⌥↑/↓ (move line) could never match and Caps Lock disabled
        // every editor shortcut.
        let eventMods = event.modifierFlags.intersection(Self.relevantModifiers)
        let wantedMods = modifiers.intersection(Self.relevantModifiers)
        guard eventMods == wantedMods else { return false }

        // Named keys: arrow / escape / return / tab / space — match by keyCode.
        switch key {
        case "up":     return event.keyCode == 0x7E
        case "down":   return event.keyCode == 0x7D
        case "left":   return event.keyCode == 0x7B
        case "right":  return event.keyCode == 0x7C
        case "escape": return event.keyCode == 0x35
        case "return": return event.keyCode == 0x24 || event.keyCode == 0x4C
        case "tab":    return event.keyCode == 0x30
        case "space":  return event.keyCode == 0x31
        default:
            // Single-character keys: compare against
            // charactersIgnoringModifiers so cmd+shift+d still reports "d".
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            return chars == key
        }
    }
}

/// The full action → combo mapping.
struct KeybindingMap: Equatable {
    private let table: [KeybindingAction: KeyCombo]

    static let `default`: KeybindingMap = {
        KeybindingMap(table: [
            .headingParagraph: KeyCombo(key: "0",   modifiers: .command),
            .headingH1:        KeyCombo(key: "1",   modifiers: .command),
            .headingH2:        KeyCombo(key: "2",   modifiers: .command),
            .headingH3:        KeyCombo(key: "3",   modifiers: .command),
            .headingH4:        KeyCombo(key: "4",   modifiers: .command),
            .headingH5:        KeyCombo(key: "5",   modifiers: .command),
            .headingH6:        KeyCombo(key: "6",   modifiers: .command),
            .moveLineUp:       KeyCombo(key: "up",  modifiers: [.command, .option]),
            .moveLineDown:     KeyCombo(key: "down", modifiers: [.command, .option]),
            .duplicateLine:    KeyCombo(key: "d",   modifiers: [.command, .shift]),
            .selectLine:       KeyCombo(key: "l",   modifiers: .command),
            .bold:             KeyCombo(key: "b",   modifiers: .command),
            .italic:           KeyCombo(key: "i",   modifiers: .command),
            .link:             KeyCombo(key: "k",   modifiers: .command),
        ])
    }()

    init(table: [KeybindingAction: KeyCombo]) {
        self.table = table
    }

    /// The combo bound to `action`, nil when it has none (Strikethrough,
    /// Inline Code, Checklist, Quote and Table start unbound).
    func combo(for action: KeybindingAction) -> KeyCombo? {
        table[action]
    }

    /// Look up which action (if any) matches the given event. Walks the
    /// actions in declaration order: with two actions on one combo in
    /// keybindings.json, the same one wins on every launch (a dictionary's
    /// order changes with the per-process hash seed).
    func action(for event: NSEvent) -> KeybindingAction? {
        KeybindingAction.allCases.first { table[$0]?.matches(event) == true }
    }

    /// Build a map by overlaying user JSON onto the defaults — any
    /// missing or malformed entry falls back to its default value.
    static func merging(userJSON: [String: String]?,
                        onto base: KeybindingMap = .default) -> KeybindingMap {
        guard let userJSON = userJSON else { return base }
        var merged = base.table
        for (rawAction, rawCombo) in userJSON {
            guard let action = KeybindingAction(rawValue: rawAction),
                  let combo = KeyCombo.parse(rawCombo) else {
                continue
            }
            merged[action] = combo
        }
        return KeybindingMap(table: merged)
    }
}

// MARK: - File loader

enum KeybindingLoader {
    /// `~/Library/Application Support/PicaMD/keybindings.json`; in the
    /// test host a file that doesn't exist, so tests see the default
    /// bindings whatever the user has customised.
    static let configURL: URL? = AppEnvironment.applicationSupportDirectory
        .appendingPathComponent("keybindings.json")

    /// Read the JSON file (if present and well-formed) and return a
    /// merged `KeybindingMap`. Logs and falls back to defaults on any
    /// kind of failure — missing file, JSON parse error, IO error —
    /// so a typo in keybindings.json never breaks the editor.
    static func load() -> KeybindingMap {
        guard let url = configURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
            return KeybindingMap.merging(userJSON: json)
        } catch {
            NSLog("PicaMD: failed to load \(url.path): \(error)")
            return .default
        }
    }
}
