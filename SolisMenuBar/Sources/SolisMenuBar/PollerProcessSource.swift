import Foundation
import SolisHubKit

private enum StreamProcessingResult: Sendable {
    case envelope(StreamEnvelope?)
    case unsupportedSchema(Int)
    case malformed
}

private actor StreamProcessor {
    private var buffer = Data()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func consume(_ data: Data) -> StreamProcessingResult {
        buffer.append(data)
        var latest: StreamEnvelope?
        var searchStart = buffer.startIndex
        while searchStart < buffer.endIndex,
              let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
            let line = buffer[searchStart..<newline]
            searchStart = buffer.index(after: newline)
            guard !line.isEmpty else { continue }
            let envelope: StreamEnvelope
            do {
                envelope = try decoder.decode(StreamEnvelope.self, from: Data(line))
            } catch {
                return .malformed
            }
            guard envelope.schemaVersion == StreamDecoder.supportedSchemaVersion else {
                return .unsupportedSchema(envelope.schemaVersion)
            }
            // UI telemetry is a snapshot. If several complete frames arrive in
            // one read, rendering only the newest avoids replaying stale work.
            latest = envelope
        }
        if searchStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<searchStart)
        }
        if buffer.count > 1 << 20 {
            buffer.removeAll(keepingCapacity: false)
            return .malformed
        }
        return .envelope(latest)
    }
}

/// Direct mode: this Mac runs `solis-poll --stream-json` as a child process.
/// This is the code that used to live in MonitorStore, moved rather than
/// rewritten, so Direct mode behaves as it always has. Where MonitorStore
/// used to set its own state, this yields an event instead.
///
/// Never constructed in Hub mode; see ConnectionPolicy.
@MainActor
final class PollerProcessSource: TelemetrySource {
    let events: AsyncStream<TelemetryEvent>

    private let continuation: AsyncStream<TelemetryEvent>.Continuation
    private let configuration: MonitorConfiguration
    /// Asked before every launch, including each restart after a crash, so the
    /// hub-detected guard also holds back a retry that would otherwise bring
    /// up a second controller.
    private let canLaunch: @MainActor () -> Bool

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var errorBuffer = Data()
    private var retryTask: Task<Void, Never>?
    private var shouldRun = false
    private var retryAttempt = 0
    private var terminationRequested = false
    private var streamProcessor: StreamProcessor?
    private var dashboardVisible = false

    private static let maximumBufferedBytes = 1 << 20
    private static let maximumRetryDelay: TimeInterval = 60

    init(configuration: MonitorConfiguration, canLaunch: @escaping @MainActor () -> Bool) {
        let (stream, continuation) = makeTelemetryStream()
        events = stream
        self.continuation = continuation
        self.configuration = configuration
        self.canLaunch = canLaunch
    }

    func start() {
        shouldRun = true
        launch()
    }

    /// The person has decided about a detected hub. Launches only if nothing
    /// is running already and a launch was being held back.
    func resumeAfterHubDecision() {
        guard shouldRun, process == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        launch()
    }

    /// Tell the poller whether anyone is looking, so it can slow its cadence
    /// while the popover is closed and nothing is being regulated.
    func setAttention(_ visible: Bool) {
        dashboardVisible = visible
        sendAttention()
    }

    private func sendAttention() {
        guard let handle = inputPipe?.fileHandleForWriting else { return }
        let line = Data("attention \(dashboardVisible ? "on" : "off")\n".utf8)
        // A poller that has just exited leaves a broken pipe. SIGPIPE is
        // ignored at launch, so that surfaces here as an error to drop, and
        // the restart path sends the state again.
        try? handle.write(contentsOf: line)
    }

    func stop() async -> Bool {
        let stopped = await stopAndWaitForRestoration()
        if stopped {
            continuation.finish()
        }
        return stopped
    }

    private func emit(_ event: TelemetryEvent) {
        continuation.yield(event)
    }

    private func clearStoppedProcess() {
        shouldRun = false
        retryTask?.cancel()
        retryTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process = nil
        terminationRequested = false
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        errorBuffer.removeAll(keepingCapacity: true)
        streamProcessor = nil
        emit(.status(.stopped))
    }

    private func stopAndWaitForRestoration() async -> Bool {
        shouldRun = false
        retryTask?.cancel()
        retryTask = nil
        if let running = process, running.isRunning {
            // SIGTERM is handled by the poller, which ownership-checks and
            // restores captured limits before closing its one Modbus session.
            running.terminationHandler = nil
            emit(.status(.degraded(nil)))
            emit(.shutdownMessage("Stopping control and checking baseline restoration…"))
            if !terminationRequested {
                terminationRequested = true
                running.terminate()
            }
            let deadline = Date().addingTimeInterval(15)
            while running.isRunning {
                if Date() >= deadline {
                    emit(.status(.failed("Restoration is still pending. The poller is retained; try stopping again.")))
                    emit(.shutdownMessage("Restoration is still pending; the poller has not been replaced."))
                    return false
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let diagnostics = String(data: errorBuffer, encoding: .utf8) ?? ""
            emit(.shutdownMessage(diagnostics.components(separatedBy: .newlines).last {
                $0.contains("voltage control shutdown:") && ($0.contains("deferred") || $0.contains("failed"))
            }))
        }
        clearStoppedProcess()
        return true
    }

    private func launch() {
        guard shouldRun else { return }
        guard canLaunch() else {
            emit(.status(.degraded(
                "A solis-hub is on this network. Choose how to continue before this Mac starts its own poller."
            )))
            return
        }
        guard let path = locatePoller() else {
            emit(.status(.failed(
                "solis-poll was not found. Install or upgrade solis-tools with Homebrew."
            )))
            // A Homebrew upgrade replaces the binary, so this is often temporary.
            scheduleRetry()
            return
        }

        emit(.executablePath(path))
        emit(.status(.connecting))
        // Each run sends its plan (or null when Octopus is off) first; a
        // plan from an earlier run must not survive a settings change.
        emit(.runStarted)
        errorBuffer.removeAll(keepingCapacity: true)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let streamProcessor = StreamProcessor()
        self.streamProcessor = streamProcessor
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments(for: configuration)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self, streamProcessor] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task(priority: .utility) { [weak self, streamProcessor] in
                switch await streamProcessor.consume(data) {
                case let .envelope(envelope):
                    if let envelope {
                        await self?.deliver(envelope)
                    }
                case let .unsupportedSchema(version):
                    await self?.unsupportedStreamSchema(version)
                case .malformed:
                    await self?.malformedStream()
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.errorBuffer.append(data)
                if self.errorBuffer.count > Self.maximumBufferedBytes {
                    // Keep the tail: the last thing written before it died is
                    // what explains why.
                    self.errorBuffer.removeFirst(
                        self.errorBuffer.count - Self.maximumBufferedBytes
                    )
                }
            }
        }
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task { @MainActor [weak self] in
                self?.processTerminated(status: status)
            }
        }

        self.process = process
        inputPipe = input
        outputPipe = output
        errorPipe = errors
        do {
            try process.run()
            sendAttention()
        } catch {
            emit(.status(.failed("Could not start solis-poll: \(error.localizedDescription)")))
            scheduleRetry()
        }
    }

    private func arguments(for configuration: MonitorConfiguration) -> [String] {
        var result = [
            "--host", configuration.host,
            "--port", String(configuration.port),
            "--slave", String(configuration.slave),
            "--interval", String(configuration.interval),
            "--slow-interval", String(configuration.slowInterval),
            "--idle-interval", String(configuration.idleInterval),
            "--meter-voltage",
            "--stream-json",
        ]
        if configuration.pvEnabled {
            result.append("--pv")
        }
        if configuration.dynamicVoltageEnabled {
            let stateDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appendingPathComponent("SolisTools", isDirectory: true)
            result.append(contentsOf: [
                "--dynamic-voltage-control",
                configuration.dynamicImportEnabled
                    ? "--dynamic-import-control" : "--no-dynamic-import-control",
                "--minimum-voltage", String(configuration.minimumVoltage),
                "--maximum-voltage", String(configuration.maximumVoltage),
                "--voltage-safety-margin", String(configuration.voltageSafetyMargin),
                "--voltage-deadband", String(configuration.voltageDeadband),
                "--maximum-import-kw", String(configuration.maximumImportKw),
                "--import-headroom-kw", String(configuration.importHeadroomKw),
                "--maximum-export-kw", String(configuration.maximumExportKw),
                "--site-export-permission-kw", String(configuration.siteExportPermissionKw),
                "--increase-step-w", String(configuration.increaseStepW),
                "--reduction-step-w", String(configuration.reductionStepW),
                "--near-limit-reduction-w", String(configuration.nearLimitReductionW),
                "--emergency-reduction-w", String(configuration.emergencyReductionW),
                "--control-settle-time", String(configuration.controlSettleTime),
                "--control-activation-delay", String(configuration.controlActivationDelay),
                "--control-deactivation-delay", String(configuration.controlDeactivationDelay),
                "--import-activation-kw", String(configuration.importActivationKw),
                "--export-activation-kw", String(configuration.exportActivationKw),
                "--minimum-write-interval", String(configuration.minimumWriteInterval),
                "--control-journal",
                stateDirectory.appendingPathComponent("voltage-control-journal.json").path,
                "--voltage-history-db",
                stateDirectory.appendingPathComponent("voltage-history.sqlite3").path,
            ])
            if configuration.dynamicExportEnabled {
                result.append("--dynamic-export-control")
            }
            if configuration.hypervoltEnabled {
                result.append(contentsOf: ["--hypervolt-enable", "--ev-priority", configuration.evPriority])
                if !configuration.hypervoltCredentialsPath.isEmpty {
                    result.append(contentsOf: [
                        "--hypervolt-credentials", configuration.hypervoltCredentialsPath,
                    ])
                }
            }
            if configuration.octopusEnabled {
                result.append("--octopus-enable")
                if !configuration.octopusCredentialsPath.isEmpty {
                    result.append(contentsOf: [
                        "--octopus-credentials", configuration.octopusCredentialsPath,
                    ])
                }
            }
        }
        return result
    }

    private func locatePoller() -> String? {
        ExecutableLocator.locate(named: "solis-poll", environmentOverride: "SOLIS_POLL_PATH")
    }

    private func deliver(_ envelope: StreamEnvelope) {
        retryAttempt = 0
        emit(.envelope(envelope))
    }

    private func unsupportedStreamSchema(_ version: Int) {
        emit(.unsupportedSchema(version))
    }

    private func malformedStream() {
        emit(.status(.degraded(nil)))
    }

    private func processTerminated(status: Int32) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        streamProcessor = nil
        guard shouldRun else { return }
        let message = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        emit(.status(.failed(
            message?.isEmpty == false
                ? message!
                : "solis-poll stopped unexpectedly (exit status \(status))."
        )))
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard shouldRun else { return }
        retryTask?.cancel()
        let delay = min(Self.maximumRetryDelay, pow(2, Double(min(retryAttempt, 6))) * 2)
        retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }
}
