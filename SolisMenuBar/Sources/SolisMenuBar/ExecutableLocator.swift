import Foundation

/// Finds a Homebrew-installed command line tool next to solis-poll: in a
/// developer build's own bin directory beside the app bundle, or on the
/// Apple Silicon or Intel Homebrew prefixes. Shared by MonitorStore (for
/// solis-poll itself) and HypervoltLoginRunner (for hypervolt-login), which
/// are installed side by side by the same Homebrew formula.
enum ExecutableLocator {
    static func locate(named name: String, environmentOverride: String? = nil) -> String? {
        var candidates: [String] = []
        if let key = environmentOverride, let override = ProcessInfo.processInfo.environment[key] {
            candidates.append(override)
        }
        let bundlePrefix = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(bundlePrefix.appendingPathComponent("bin/\(name)").path)
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ])
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
