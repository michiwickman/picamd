import SwiftUI
import AppKit

/// The editor side of the find bar. Implemented by
/// `MarkdownTextView.Coordinator`, which owns the text view.
@MainActor
protocol SearchDriver: AnyObject {
    /// Query, options, or open state changed — re-run the search.
    func searchParametersChanged()
    /// Run a one-shot command (next, previous, replace…).
    func performSearchAction(_ action: SearchModel.Action)
    /// The bar is closing: settle the selection on the current match and
    /// hand focus back to the editor.
    func searchDidClose()
    /// The editor's selected text, for Use Selection for Find (⌘E).
    func selectedTextForFind() -> String?
}

/// The find options are one app-wide setting, like the find options of
/// every Mac app: the last choice is remembered across launches and a
/// change in one window applies to all of them.
/// Stored as separate keys so an option added later reads its default
/// instead of invalidating the rest.
enum SearchPreferences {
    static let ignoreCaseKey = "PicaMD.find.ignoreCase"
    static let wrapAroundKey = "PicaMD.find.wrapAround"
    static let matchStyleKey = "PicaMD.find.matchStyle"
    static let regexKey = "PicaMD.find.regularExpression"
    static let ignoreFormattingKey = "PicaMD.find.ignoreMarkdownFormatting"

    /// Posted (object: the `SearchModel` that changed them) after the
    /// options were written; every other window's model reloads them.
    static let didChange = Notification.Name("PicaMD.findOptionsDidChange")

    static func load(from defaults: UserDefaults) -> SearchOptions {
        var options = SearchOptions()
        if defaults.object(forKey: ignoreCaseKey) != nil {
            options.caseSensitive = !defaults.bool(forKey: ignoreCaseKey)
        }
        if defaults.object(forKey: wrapAroundKey) != nil {
            options.wrapAround = defaults.bool(forKey: wrapAroundKey)
        }
        if let raw = defaults.string(forKey: matchStyleKey), let style = MatchStyle(rawValue: raw) {
            options.matchStyle = style
        }
        options.regex = defaults.bool(forKey: regexKey)
        options.ignoreFormatting = defaults.bool(forKey: ignoreFormattingKey)
        return options
    }

    static func save(_ options: SearchOptions, to defaults: UserDefaults) {
        defaults.set(!options.caseSensitive, forKey: ignoreCaseKey)
        defaults.set(options.wrapAround, forKey: wrapAroundKey)
        defaults.set(options.matchStyle.rawValue, forKey: matchStyleKey)
        defaults.set(options.regex, forKey: regexKey)
        defaults.set(options.ignoreFormatting, forKey: ignoreFormattingKey)
    }
}

/// Source-of-truth for the in-editor find/replace bar. Owned by
/// `ContentView` as a `@StateObject` and published to the App's command
/// menu via `focusedSceneValue` so ⌘F / ⌘G etc. can drive it.
///
/// The model holds the user-facing query/options/state and forwards every
/// change straight to its `driver` (the editor coordinator), which does the
/// matching against the live text buffer and reports `resultCount` /
/// `currentIndex` / `invalidRegex` back. The editor used to poll this
/// model from `updateNSView`, but SwiftUI doesn't re-run a representable's
/// update when only a reference-type property changed, so typing a query
/// or pressing ⌘G often never reached the editor.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query: String = "" {
        didSet { if query != oldValue { driver?.searchParametersChanged() } }
    }
    @Published var replaceText: String = ""
    /// Every write goes through the whole struct (menu bindings use
    /// `$model.options.<field>`), so this `didSet` is the one place that
    /// persists the options, tells the other windows and re-runs the
    /// search.
    @Published var options: SearchOptions {
        didSet {
            guard options != oldValue else { return }
            if !applyingSharedOptions {
                SearchPreferences.save(options, to: defaults)
                notificationCenter.post(name: SearchPreferences.didChange, object: self)
            }
            driver?.searchParametersChanged()
        }
    }
    @Published private(set) var isOpen = false
    @Published var showReplace = false

    /// Reported by the editor after each search pass.
    @Published private(set) var resultCount = 0
    /// 1-based index of the current match; 0 = no current match.
    @Published private(set) var currentIndex = 0
    @Published private(set) var invalidRegex = false

    /// Bumped whenever the bar should (re)grab keyboard focus and select
    /// its query text — e.g. pressing ⌘F while the bar is already open.
    @Published private(set) var focusToken = UUID()

    /// The editor this bar searches. Weak: the coordinator owns the model's
    /// lifetime only indirectly (via ContentView), never the reverse.
    weak var driver: SearchDriver?

    enum Action: Equatable {
        case next, previous, replaceCurrent, replaceAll, useSelection, jumpToSelection
    }

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    /// The system-wide find pasteboard: ⌘E publishes the search string
    /// there, and an empty bar picks up what another app put there.
    private let findPasteboard: NSPasteboard
    private var applyingSharedOptions = false
    nonisolated(unsafe) private var optionsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard,
         notificationCenter: NotificationCenter = .default,
         findPasteboard: NSPasteboard = NSPasteboard(name: .find)) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.findPasteboard = findPasteboard
        self.options = SearchPreferences.load(from: defaults)
        optionsObserver = notificationCenter.addObserver(
            forName: SearchPreferences.didChange, object: nil, queue: nil
        ) { [weak self] note in
            // Delivered synchronously on the posting thread, which is the
            // main actor: only `SearchModel.options` posts this.
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self) else { return }
                self.applySharedOptions()
            }
        }
    }

    deinit {
        if let optionsObserver { notificationCenter.removeObserver(optionsObserver) }
    }

    /// Another window changed the options: adopt them without writing
    /// them back (that would ping-pong between windows).
    private func applySharedOptions() {
        applyingSharedOptions = true
        options = SearchPreferences.load(from: defaults)
        applyingSharedOptions = false
    }

    // MARK: - Commands (from the Find menu / bar buttons)

    /// ⌘F shows the find row, ⌥⌘F find + replace. Pressing either while the
    /// bar is already open just re-focuses the query field (like every
    /// other Mac find bar) instead of closing it.
    func open(replace: Bool) {
        showReplace = replace
        focusToken = UUID()
        guard !isOpen else { return }
        adoptFindPasteboardIfEmpty()
        isOpen = true
        driver?.searchParametersChanged()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        driver?.searchDidClose()
    }

    /// ⌘G / ⇧⌘G. With the bar closed they search again for the last query
    /// (or the find pasteboard's string) and select the match, as in every
    /// Mac app; the bar stays closed.
    func next() { findAgain(.next) }
    func previous() { findAgain(.previous) }

    private func findAgain(_ action: Action) {
        if !isOpen {
            adoptFindPasteboardIfEmpty()
            guard !query.isEmpty else { NSSound.beep(); return }
        }
        driver?.performSearchAction(action)
    }

    /// Return in the find field: next match; with Shift, the previous one.
    func submitQuery(shift: Bool) {
        if shift { previous() } else { next() }
    }

    /// Replace and All are off while Ignore Markdown Formatting is on (and
    /// the field explains why in this tooltip): a match in the visible
    /// text can span hidden markers, so it has no single stretch of
    /// Markdown source that a replacement could swap without eating them.
    static let replaceUnavailableReason =
        "Replace is unavailable while Ignore Markdown Formatting is on: a match can span hidden Markdown markers."

    var replaceDisabledReason: String? {
        options.ignoreFormatting ? Self.replaceUnavailableReason : nil
    }

    /// The find bar's status beside the field ("3 of 12", "No matches",
    /// "Invalid"), nil while the query is empty. Also the field's
    /// accessibility value and what VoiceOver announces when it changes.
    var statusText: String? {
        if query.isEmpty { return nil }
        if invalidRegex { return "Invalid" }
        if resultCount == 0 { return "No matches" }
        if currentIndex == 0 { return resultCount == 1 ? "1 match" : "\(resultCount) matches" }
        return "\(currentIndex) of \(resultCount)"
    }

    /// Replace swaps the current match only. With Wrap Around off and the
    /// caret behind the last match there are matches but no current one
    /// ("N matches"), so Replace has nothing to act on while All still
    /// does.
    var canReplace: Bool {
        canReplaceAll && currentIndex > 0
    }

    var canReplaceAll: Bool {
        isOpen && !options.ignoreFormatting && resultCount > 0
    }

    func replaceCurrent() {
        guard isOpen, !options.ignoreFormatting else { return }
        driver?.performSearchAction(.replaceCurrent)
    }
    func replaceAll() {
        guard isOpen, !options.ignoreFormatting else { return }
        driver?.performSearchAction(.replaceAll)
    }

    /// ⌘E: search for the editor's current selection. Also writes it to
    /// the find pasteboard, so ⌘G in another app finds the same string.
    func useSelection() {
        if !isOpen {
            isOpen = true
            focusToken = UUID()
        }
        if let selected = driver?.selectedTextForFind(), !selected.isEmpty {
            query = selected
            findPasteboard.clearContents()
            findPasteboard.setString(selected, forType: .string)
        }
        driver?.performSearchAction(.useSelection)
    }

    /// ⌘J: scroll the editor back to its selection.
    func jumpToSelection() {
        driver?.performSearchAction(.jumpToSelection)
    }

    /// An empty bar starts from the find pasteboard (set by ⌘E here or in
    /// any other app). A query typed in this window wins over it.
    private func adoptFindPasteboardIfEmpty() {
        guard query.isEmpty,
              let shared = findPasteboard.string(forType: .string), !shared.isEmpty else { return }
        query = shared
    }

    // MARK: - Reporting (from the editor)

    func report(count: Int, index: Int, invalidRegex: Bool) {
        if resultCount != count { resultCount = count }
        if currentIndex != index { currentIndex = index }
        if self.invalidRegex != invalidRegex { self.invalidRegex = invalidRegex }
    }
}
