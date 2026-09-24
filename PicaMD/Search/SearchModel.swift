import SwiftUI

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
    @Published var options = SearchOptions() {
        didSet { if options != oldValue { driver?.searchParametersChanged() } }
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

    // MARK: - Commands (from the Find menu / bar buttons)

    /// ⌘F shows the find row, ⌥⌘F find + replace. Pressing either while the
    /// bar is already open just re-focuses the query field (like every
    /// other Mac find bar) instead of closing it.
    func open(replace: Bool) {
        showReplace = replace
        focusToken = UUID()
        guard !isOpen else { return }
        isOpen = true
        driver?.searchParametersChanged()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        driver?.searchDidClose()
    }

    func next() { guard isOpen else { return }; driver?.performSearchAction(.next) }
    func previous() { guard isOpen else { return }; driver?.performSearchAction(.previous) }
    func replaceCurrent() {
        guard isOpen, !options.ignoreFormatting else { return }
        driver?.performSearchAction(.replaceCurrent)
    }
    func replaceAll() {
        guard isOpen, !options.ignoreFormatting else { return }
        driver?.performSearchAction(.replaceAll)
    }

    /// ⌘E: search for the editor's current selection.
    func useSelection() {
        if !isOpen {
            isOpen = true
            focusToken = UUID()
        }
        driver?.performSearchAction(.useSelection)
    }

    /// ⌘J: scroll the editor back to its selection.
    func jumpToSelection() {
        driver?.performSearchAction(.jumpToSelection)
    }

    // MARK: - Reporting (from the editor)

    func report(count: Int, index: Int, invalidRegex: Bool) {
        if resultCount != count { resultCount = count }
        if currentIndex != index { currentIndex = index }
        if self.invalidRegex != invalidRegex { self.invalidRegex = invalidRegex }
    }
}
