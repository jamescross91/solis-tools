import XCTest

extension XCTestCase {
    /// A preferences suite of its own, kept out of ~/Library/Preferences.
    ///
    /// A named suite is a plist there, and every test run used to leave a few
    /// dozen more behind. Removing the domain or deleting the file at teardown
    /// does not help: the preferences daemon writes its cached copy back a
    /// moment later. CFPreferences takes an absolute path as a suite name, so
    /// each suite is a file in a temporary directory removed at teardown.
    ///
    /// Removed at teardown rather than when the caller is done with it: some
    /// tests build a second store over the same suite, as a relaunch would.
    func temporaryDefaults(prefix: String) throws -> UserDefaults {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return try XCTUnwrap(
            UserDefaults(suiteName: directory.appendingPathComponent("defaults.plist").path)
        )
    }
}
