import Foundation

/// Drives `hypervolt-login` as a one-shot subprocess for the dashboard's own
/// sign-in form, so the account password only ever passes through that one
/// short-lived process — never written to UserDefaults, a file, or logged by
/// this app. The email is passed as an argument (not a secret); the password
/// is written to the subprocess's stdin, which `getpass.getpass` reads
/// directly once it sees stdin is not a terminal, exactly as it does for a
/// piped `hypervolt-login` invocation from a shell script. See
/// docs/hypervolt-integration.md.
@MainActor
final class HypervoltLoginRunner: ObservableObject {
    enum Outcome: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    @Published private(set) var outcome: Outcome = .idle

    func signIn(email: String, password: String, credentialsPath: String) {
        guard
            let path = ExecutableLocator.locate(
                named: "hypervolt-login", environmentOverride: "HYPERVOLT_LOGIN_PATH"
            )
        else {
            outcome = .failed("hypervolt-login was not found. Install or upgrade solis-tools with Homebrew.")
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--credentials", credentialsPath, "--email", email]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        process.terminationHandler = { [weak self] terminated in
            let stdout = Self.readAll(output.fileHandleForReading)
            let stderr = Self.readAll(errors.fileHandleForReading)
            Task { @MainActor [weak self] in
                self?.finished(status: terminated.terminationStatus, stdout: stdout, stderr: stderr)
            }
        }

        outcome = .running
        do {
            try process.run()
        } catch {
            outcome = .failed("Could not start hypervolt-login: \(error.localizedDescription)")
            return
        }
        // A process that has already exited (a bad executable, for example)
        // leaves a broken pipe here; that surfaces as the exit code the
        // termination handler above reports, not as a crash.
        try? input.fileHandleForWriting.write(contentsOf: Data("\(password)\n".utf8))
        try? input.fileHandleForWriting.close()
    }

    private static func readAll(_ handle: FileHandle) -> String {
        let data = (try? handle.readToEnd()).flatMap { $0 } ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func finished(status: Int32, stdout: String, stderr: String) {
        if status == 0 {
            let message = stdout.components(separatedBy: .newlines)
                .first { $0.hasPrefix("Saved a Hypervolt refresh token") }
            outcome = .succeeded(message ?? "Signed in to Hypervolt.")
            return
        }
        let message = stderr.components(separatedBy: .newlines)
            .last { $0.hasPrefix("error: ") }
        outcome = .failed(message.map { String($0.dropFirst("error: ".count)) } ?? "Hypervolt sign-in failed.")
    }
}
