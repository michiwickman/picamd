import SwiftUI
import Sparkle

/// Bridges Sparkle's `SPUStandardUpdaterController` into SwiftUI so we
/// can present "Check for Updates…" from a `Button` in the menu and
/// have Sparkle's automatic-check loop run in the background once
/// PicaMD is properly hosted.
///
/// Important — placeholder-URL guard: until the user replaces the
/// `PLACEHOLDER_OWNER` token in `Info.plist`'s `SUFeedURL` with a
/// real GitHub org slug AND generates a real `SUPublicEDKey`, we
/// **don't start the updater at all**. Otherwise Sparkle pops a
/// "Couldn't check for updates" alert on every window-open / scene
/// init, once per attempt — which can show up as 20 stacked dialogs
/// the first time you open the app.
///
/// The "Check for Updates…" menu item is also disabled in this
/// state, so a curious user clicking it doesn't get a worse error.
@MainActor
final class UpdaterController: ObservableObject {
    @Published var canCheckForUpdates = false

    /// `true` once `Info.plist`'s `SUFeedURL` no longer contains the
    /// `PLACEHOLDER_OWNER` token. While `false`, we never instantiate
    /// `SPUStandardUpdaterController` so Sparkle stays completely
    /// silent. The check runs once at init and never changes for the
    /// process lifetime — replacing the token requires a rebuild
    /// anyway.
    let updaterIsConfigured: Bool

    /// `nil` until the user configures a real `SUFeedURL`. Holding
    /// this as an optional rather than always-allocating a "muted"
    /// updater is what actually stops the alert spam — Sparkle
    /// fetches the feed in its initialiser when auto-checks are on.
    let updater: SPUStandardUpdaterController?

    init() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = (feedURL?.contains("PLACEHOLDER") == false)
                       && (publicKey?.contains("PLACEHOLDER") == false)
        self.updaterIsConfigured = configured

        if configured {
            let ctrl = SPUStandardUpdaterController(
                startingUpdater: Self.startsUpdater,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            self.updater = ctrl
            ctrl.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
        } else {
            self.updater = nil
            self.canCheckForUpdates = false
        }
    }

    /// Off in the test host: Sparkle would check the network for updates
    /// in the middle of a test run. The updater still exists there, so
    /// Settings shows what the app shows.
    static let startsUpdater = !AppEnvironment.isolatesUserData

    /// Settings ▸ General ▸ "Check for updates automatically". Sparkle
    /// persists the value in the app's own user defaults, so there is no
    /// PicaMD key for it. Off (and the switch disabled) while the updater
    /// isn't configured.
    var automaticallyChecksForUpdates: Bool {
        get { updater?.updater.automaticallyChecksForUpdates ?? false }
        set {
            guard let updater else { return }
            objectWillChange.send()
            updater.updater.automaticallyChecksForUpdates = newValue
        }
    }
}

/// SwiftUI `Commands` entry that adds "Check for Updates…" under the
/// app menu. Disabled when the updater isn't configured (placeholder
/// SUFeedURL) so the user doesn't get a "couldn't check" alert.
struct UpdaterCommands: Commands {
    @ObservedObject var controller: UpdaterController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                controller.updater?.checkForUpdates(nil)
            }
            .disabled(!controller.canCheckForUpdates || !controller.updaterIsConfigured)
        }
    }
}
