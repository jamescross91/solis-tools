import Combine
import Foundation

struct MenuBarSnapshot: Sendable {
    let reading: InverterReading?
    let symbol: String
    let hasAlert: Bool
    let statusLabel: String
}

@MainActor
final class MenuBarPresentation: ObservableObject {
    @Published private(set) var snapshot = MenuBarSnapshot(
        reading: nil,
        symbol: "bolt.house",
        hasAlert: false,
        statusLabel: "Solis stopped"
    )

    func update(_ snapshot: MenuBarSnapshot) {
        self.snapshot = snapshot
    }
}

private struct DashboardPresentation {
    var latest: StreamEnvelope?
    var history: [HistoryPoint] = []
    var controlHistory: [HistoryPoint] = []
}

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

@MainActor
final class MonitorStore: ObservableObject {
    enum State: Equatable {
        case stopped
        case connecting
        case connected
        case degraded
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private var presentation = DashboardPresentation()
    @Published private(set) var executablePath: String?
    @Published private(set) var shutdownMessage: String?

    let menuPresentation = MenuBarPresentation()

    var latest: StreamEnvelope? { presentation.latest }
    var history: [HistoryPoint] { presentation.history }
    var controlHistory: [HistoryPoint] { presentation.controlHistory }

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var errorBuffer = Data()
    private var activeConfiguration: MonitorConfiguration?
    private var retryTask: Task<Void, Never>?
    private var shouldRun = false
    private var lastSuccessfulPolls = 0
    private var retryAttempt = 0
    private var historyBuffer = HistoryBuffer()
    private var controlHistoryBuffer = ControlHistoryBuffer()
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleRevision = 0
    private var terminationRequested = false
    private var latestReceived: StreamEnvelope?
    private var streamProcessor: StreamProcessor?
    private var dashboardVisible = false
    private var lastMenuUpdate = Date.distantPast
    private var lastUrgentSignature: String?

    private static let maximumBufferedBytes = 1 << 20
    private static let maximumRetryDelay: TimeInterval = 60
    private static let closedMenuRefreshInterval: TimeInterval = 5

    var isRunning: Bool {
        switch state {
        case .stopped, .failed: false
        default: true
        }
    }

    var menuSymbol: String {
        if latestReceived?.reading.alarms.contains(where: { $0.severity == "fault" }) == true {
            return "exclamationmark.triangle.fill"
        }
        switch state {
        case .connected: return "bolt.house.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .degraded, .failed: return "wifi.exclamationmark"
        case .stopped: return "bolt.house"
        }
    }

    var hasMenuAlert: Bool {
        if latestReceived?.reading.alarms.contains(where: { $0.severity == "fault" }) == true {
            return true
        }
        switch state {
        case .degraded, .failed: return true
        case .stopped, .connecting, .connected: return false
        }
    }

    var menuStatusLabel: String {
        if latestReceived?.reading.alarms.contains(where: { $0.severity == "fault" }) == true {
            return "Solis inverter fault"
        }
        switch state {
        case .degraded: return "Solis connection degraded"
        case .failed: return "Solis connection failed"
        case .stopped: return "Solis stopped"
        case .connecting: return "Solis connecting"
        case .connected: return "Solis connected"
        }
    }

    func exportControlValidated(host: String, port: Int, slave: Int) -> Bool {
        guard let activeConfiguration else { return false }
        return activeConfiguration.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && activeConfiguration.port == port
            && activeConfiguration.slave == slave
            && latestReceived?.voltageControl?.exportWriteValidated == true
    }

    /// Start from stored settings if they are complete and nothing is running.
    ///
    /// Called when the menu-bar item itself appears, so a configured install
    /// begins polling at login rather than waiting for its first click.
    func startIfConfigured() {
        guard !isRunning, let configuration = MonitorConfiguration.stored() else { return }
        start(configuration: configuration)
    }

    func start(configuration: MonitorConfiguration) {
        lifecycleRevision += 1
        let revision = lifecycleRevision
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            guard revision == lifecycleRevision, await stopAndWaitForRestoration() else { return }
            guard revision == lifecycleRevision else { return }
            activeConfiguration = configuration
            shutdownMessage = nil
            shouldRun = true
            launch(configuration: configuration)
        }
    }

    func stop(clearReading: Bool = false) {
        lifecycleRevision += 1
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            if await stopAndWaitForRestoration() {
                clearStoppedProcess(clearReading: clearReading)
            }
        }
    }

    private func clearStoppedProcess(clearReading: Bool) {
        shouldRun = false
        retryTask?.cancel()
        retryTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process = nil
        terminationRequested = false
        outputPipe = nil
        errorPipe = nil
        errorBuffer.removeAll(keepingCapacity: true)
        streamProcessor = nil
        setState(.stopped)
        if clearReading {
            latestReceived = nil
            historyBuffer.removeAll()
            controlHistoryBuffer.removeAll()
            presentation = DashboardPresentation()
            publishMenu(force: true)
            lastSuccessfulPolls = 0
        }
    }

    func setDashboardVisible(_ visible: Bool) {
        guard dashboardVisible != visible else { return }
        dashboardVisible = visible
        if visible {
            publishDashboard()
        }
    }

    func stopForApplicationTermination() async -> Bool {
        lifecycleRevision += 1
        await lifecycleTask?.value
        return await stopAndWaitForRestoration()
    }

    private func stopAndWaitForRestoration() async -> Bool {
        shouldRun = false
        retryTask?.cancel()
        retryTask = nil
        if let running = process, running.isRunning {
            // SIGTERM is handled by the poller, which ownership-checks and
            // restores captured limits before closing its one Modbus session.
            running.terminationHandler = nil
            setState(.degraded)
            shutdownMessage = "Stopping control and checking baseline restoration…"
            if !terminationRequested {
                terminationRequested = true
                running.terminate()
            }
            let deadline = Date().addingTimeInterval(15)
            while running.isRunning {
                if Date() >= deadline {
                    setState(.failed("Restoration is still pending. The poller is retained; try stopping again."))
                    shutdownMessage = "Restoration is still pending; the poller has not been replaced."
                    return false
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let diagnostics = String(data: errorBuffer, encoding: .utf8) ?? ""
            shutdownMessage = diagnostics.components(separatedBy: .newlines).last {
                $0.contains("voltage control shutdown:") && ($0.contains("deferred") || $0.contains("failed"))
            }
        }
        clearStoppedProcess(clearReading: false)
        return true
    }

    private func launch(configuration: MonitorConfiguration) {
        guard shouldRun else { return }
        guard let path = locatePoller() else {
            setState(.failed(
                "solis-poll was not found. Install or upgrade solis-tools with Homebrew."
            ))
            // A Homebrew upgrade replaces the binary, so this is often temporary.
            scheduleRetry()
            return
        }

        executablePath = path
        setState(.connecting)
        errorBuffer.removeAll(keepingCapacity: true)

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let streamProcessor = StreamProcessor()
        self.streamProcessor = streamProcessor
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments(for: configuration)
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self, streamProcessor] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task(priority: .utility) { [weak self, streamProcessor] in
                switch await streamProcessor.consume(data) {
                case let .envelope(envelope):
                    if let envelope {
                        await self?.receive(envelope)
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
        outputPipe = output
        errorPipe = errors
        do {
            try process.run()
        } catch {
            setState(.failed("Could not start solis-poll: \(error.localizedDescription)"))
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
        }
        return result
    }

    private func locatePoller() -> String? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["SOLIS_POLL_PATH"] {
            candidates.append(override)
        }
        let bundlePrefix = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(bundlePrefix.appendingPathComponent("bin/solis-poll").path)
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/solis-poll",
            "/usr/local/bin/solis-poll",
        ])
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func unsupportedStreamSchema(_ version: Int) {
        // A schema the app cannot read will not fix itself; say so rather than
        // sitting on "degraded" indefinitely.
        stop()
        let error = StreamError.unsupportedSchema(version)
        setState(.failed(error.localizedDescription))
    }

    private func malformedStream() {
        setState(.degraded)
    }

    private func receive(_ envelope: StreamEnvelope) {
        retryAttempt = 0
        latestReceived = envelope
        setState(envelope.error == nil ? .connected : .degraded)

        if envelope.health.successfulPolls != lastSuccessfulPolls {
            lastSuccessfulPolls = envelope.health.successfulPolls
            let sampleDate = StreamDecoder.date(from: envelope.timestamp) ?? Date()
            let point = HistoryPoint(
                date: sampleDate,
                reading: envelope.reading,
                voltageControl: envelope.voltageControl
            )
            controlHistoryBuffer.append(point)
            historyBuffer.append(point)
        }

        let signature = urgentSignature(envelope)
        let urgent = signature != lastUrgentSignature
        lastUrgentSignature = signature
        if dashboardVisible {
            publishDashboard()
        }
        publishMenu(force: urgent)
    }

    private func processTerminated(status: Int32) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil
        errorPipe = nil
        streamProcessor = nil
        guard shouldRun else { return }
        let message = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        setState(.failed(
            message?.isEmpty == false
                ? message!
                : "solis-poll stopped unexpectedly (exit status \(status))."
        ))
        scheduleRetry()
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        publishMenu(force: true)
    }

    private func publishDashboard() {
        presentation = DashboardPresentation(
            latest: latestReceived,
            history: historyBuffer.points,
            controlHistory: controlHistoryBuffer.points
        )
    }

    private func publishMenu(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastMenuUpdate) >= Self.closedMenuRefreshInterval else {
            return
        }
        lastMenuUpdate = now
        menuPresentation.update(
            MenuBarSnapshot(
                reading: latestReceived?.reading,
                symbol: menuSymbol,
                hasAlert: hasMenuAlert,
                statusLabel: menuStatusLabel
            )
        )
    }

    private func urgentSignature(_ envelope: StreamEnvelope) -> String {
        let alarms = envelope.reading.alarms.map { "\($0.code):\($0.severity)" }.joined(separator: ",")
        let control = envelope.voltageControl
        let newestEvent = control?.recentEvents.first?.id ?? ""
        return [
            envelope.error ?? "",
            alarms,
            control?.state ?? "",
            control?.action ?? "",
            control?.emergency == true ? "emergency" : "normal",
            newestEvent,
        ].joined(separator: "|")
    }

    private func scheduleRetry() {
        guard shouldRun, let configuration = activeConfiguration else { return }
        retryTask?.cancel()
        let delay = min(Self.maximumRetryDelay, pow(2, Double(min(retryAttempt, 6))) * 2)
        retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch(configuration: configuration)
        }
    }
}
