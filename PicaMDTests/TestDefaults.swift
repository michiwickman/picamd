import XCTest
@testable import PicaMD

extension XCTestCase {
    /// A defaults suite for this test, empty at the start and emptied again
    /// when the test ends.
    ///
    /// A suite is a plist in ~/Library/Preferences, and removing its domain
    /// leaves the file behind. Suites named with a fresh UUID added dozens
    /// of files to the user's Preferences folder on every run (about 1,300
    /// after one day). These names repeat from run to run, so the files
    /// stay a small fixed set, all named after the test host.
    /// - Parameter label: unique among the suites one test uses at a time.
    func makeTestDefaults(_ label: String) -> UserDefaults {
        let name = "\(AppEnvironment.testHostBundleIdentifier).tests.\(label)"
        UserDefaults.standard.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }
}
