import Foundation

/// Reads a pipe to EOF. Outside the runner's @MainActor isolation because it
/// runs from Process.terminationHandler, on an arbitrary thread.
private func readToEnd(_ handle: FileHandle) -> String {
    let data = (try? handle.readToEnd()).flatMap { $0 } ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Drives `octopus-login` as a one-shot subprocess for the dashboard's
/// sign-in form, the same way HypervoltLoginRunner drives `hypervolt-login`.
/// The API key is written to the subprocess's stdin, which `getpass` reads
/// once it sees stdin is not a terminal, so the key never appears in an
/// argument list, UserDefaults or a log; only `octopus-login` itself writes
/// it, to the 0600 credentials file. The account number and device ID are not
/// secrets and go as arguments, and only when the user has more than one. See
/// docs/octopus-integration.md.
@MainActor
final class OctopusLoginRunner: ObservableObject {
    enum Outcome: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    @Published private(set) var outcome: Outcome = .idle
    /// Bumped on every successful sign-in so the settings form re-reads the
    /// credentials file once, rather than polling it.
    @Published private(set) var completedSignIns = 0

    func signIn(apiKey: String, accountNumber: String, deviceID: String, credentialsPath: String) {
        guard
            let path = ExecutableLocator.locate(
                named: "octopus-login", environmentOverride: "OCTOPUS_LOGIN_PATH"
            )
        else {
            outcome = .failed("octopus-login was not found. Install or upgrade solis-tools with Homebrew.")
            return
        }

        var arguments = ["--credentials", credentialsPath]
        if !accountNumber.isEmpty {
            arguments.append(contentsOf: ["--account", accountNumber])
        }
        if !deviceID.isEmpty {
            arguments.append(contentsOf: ["--device", deviceID])
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        process.terminationHandler = { [weak self] terminated in
            let stdout = readToEnd(output.fileHandleForReading)
            let stderr = readToEnd(errors.fileHandleForReading)
            Task { @MainActor [weak self] in
                self?.finished(status: terminated.terminationStatus, stdout: stdout, stderr: stderr)
            }
        }

        outcome = .running
        do {
            try process.run()
        } catch {
            outcome = .failed("Could not start octopus-login: \(error.localizedDescription)")
            return
        }
        // An already-exited process leaves a broken pipe here; its exit code
        // reaches the termination handler instead of crashing the app.
        try? input.fileHandleForWriting.write(contentsOf: Data("\(apiKey)\n".utf8))
        try? input.fileHandleForWriting.close()
    }

    private func finished(status: Int32, stdout: String, stderr: String) {
        if status == 0 {
            let message = stdout.components(separatedBy: .newlines)
                .first { $0.hasPrefix("Saved Octopus credentials") }
            outcome = .succeeded(message ?? "Signed in to Octopus.")
            completedSignIns += 1
            return
        }
        let message = stderr.components(separatedBy: .newlines)
            .last { $0.hasPrefix("error: ") }
        outcome = .failed(message.map { String($0.dropFirst("error: ".count)) } ?? "Octopus sign-in failed.")
    }
}
