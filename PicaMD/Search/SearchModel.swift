import SwiftUI

/// Source-of-truth for the in-editor find/replace bar. Owned by
/// `ContentView` as a `@StateObject` and published to the App's command
/// menu via `focusedSceneValue` so ⌘F / ⌘G etc. can drive it.
///
/// The model holds the user-facing query/options/state; the actual
/// matching against the live text buffer is done by the editor's
/// `MarkdownTextView.Coordinator`, which reports `resultCount` /
/// `currentIndex` / `invalidRegex` back here. Imperative one-shot
/// commands (next, previous, replace…) are delivered to the coordinator
/// through `pendingAction` + a fresh `actionToken` it consumes once.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query: String = ""
    @Published var replaceText: String = ""
    @Published var options = SearchOptions()
    @Published var isOpen = false
    @Published var showReplace = false

    /// Reported by the editor coordinator after each search pass.
    @Published private(set) var resultCount = 0
    /// 1-based index of the current match; 0 = no current match.
    @Published private(set) var currentIndex = 0
    @Published private(set) var invalidRegex = false

    /// One-shot imperative commands the editor coordinator consumes.
    enum Action: Equatable {
        case next, previous, replaceCurrent, replaceAll, useSelection
    }
    @Published private(set) var pendingAction: Action?
    /// Bumped on every dispatched action so the coordinator can tell a
    /// repeated command (⌘G, ⌘G) apart from a no-op re-render.
    private(set) var actionToken = UUID()

    /// Bumped whenever the bar should (re)grab keyboard focus and select
    /// its query text — e.g. pressing ⌘F while the bar is already open.
    @Published private(set) var focusToken = UUID()

    private func dispatch(_ action: Action) {
        pendingAction = action
        actionToken = UUID()
    }

    // MARK: - Commands (from the Find menu / bar buttons)

    func open(replace: Bool) {
        if replace { showReplace = true }
        isOpen = true
        focusToken = UUID()   // focus + select-all the query field
    }

    func close() {
        isOpen = false
    }

    func toggle(replace: Bool) {
        if isOpen && showReplace == replace {
            close()
        } else {
            open(replace: replace)
        }
    }

    func next() { guard isOpen else { return }; dispatch(.next) }
    func previous() { guard isOpen else { return }; dispatch(.previous) }
    func replaceCurrent() { guard isOpen, !options.ignoreFormatting else { return }; dispatch(.replaceCurrent) }
    func replaceAll() { guard isOpen, !options.ignoreFormatting else { return }; dispatch(.replaceAll) }

    func useSelection() {
        isOpen = true
        dispatch(.useSelection)
    }

    // MARK: - Reporting (from the editor coordinator)

    func report(count: Int, index: Int, invalidRegex: Bool) {
        if resultCount != count { resultCount = count }
        if currentIndex != index { currentIndex = index }
        if self.invalidRegex != invalidRegex { self.invalidRegex = invalidRegex }
    }

    /// Set by the coordinator when "Use Selection for Find" (⌘E) fires.
    func setQuery(_ text: String) {
        if !text.isEmpty { query = text }
    }
}
