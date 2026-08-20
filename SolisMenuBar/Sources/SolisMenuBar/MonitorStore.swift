import Combine
import Foundation

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
    @Published private(set) var latest: StreamEnvelope?
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var executablePath: String?

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var activeConfiguration: MonitorConfiguration?
    private var retryTask: Task<Void, Never>?
    private var shouldRun = false
    private var lastSuccessfulPolls = 0
    private var retryAttempt = 0
    private var historyBuffer = HistoryBuffer()

    private static let maximumBufferedBytes = 1 << 20
    private static let maximumRetryDelay: TimeInterval = 60

    var isRunning: Bool {
        switch state {
        case .stopped, .failed: false
        default: true
        }
    }

    var menuSymbol: String {
        if latest?.reading.alarms.contains(where: { $0.severity == "fault" }) == true {
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
        if latest?.reading.alarms.contains(where: { $0.severity == "fault" }) == true {
            return true
        }
        switch state {
        case .degraded, .failed: return true
        case .stopped, .connecting, .connected: return false
        }
    }

    var menuStatusLabel: String {
        if latest?.reading.alarms.contains(where: { $0.severity == "fault" }) == true {
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

    func start(configuration: MonitorConfiguration) {
        stop(clearReading: false)
        activeConfiguration = configuration
        shouldRun = true
        launch(configuration: configuration)
    }

    func stop(clearReading: Bool = false) {
        shouldRun = false
        retryTask?.cancel()
        retryTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        state = .stopped
        if clearReading {
            latest = nil
            historyBuffer.removeAll()
            history.removeAll(keepingCapacity: true)
            lastSuccessfulPolls = 0
        }
    }

    private func launch(configuration: MonitorConfiguration) {
        guard shouldRun else { return }
        guard let path = locatePoller() else {
            state = .failed(
                "solis-poll was not found. Install or upgrade solis-tools with Homebrew."
            )
            // A Homebrew upgrade replaces the binary, so this is often temporary.
            scheduleRetry()
            return
        }

        executablePath = path
        state = .connecting
        errorBuffer.removeAll(keepingCapacity: true)

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments(for: configuration)
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeOutput(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.errorBuffer.append(data)
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
            state = .failed("Could not start solis-poll: \(error.localizedDescription)")
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
            "--inverter-max-kw", String(configuration.inverterMaxKw),
            "--grid-max-kw", String(configuration.gridMaxKw),
            "--stream-json",
        ]
        if configuration.pvEnabled {
            result.append("--pv")
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

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let envelope = try StreamDecoder.decode(Data(line))
                receive(envelope)
            } catch let error as StreamError {
                // A schema the app cannot read will not fix itself; say so
                // rather than sitting on "degraded" indefinitely. stop() resets
                // state, so the message has to be set after it.
                stop()
                state = .failed(error.localizedDescription)
                return
            } catch {
                state = .degraded
            }
        }
        if outputBuffer.count > Self.maximumBufferedBytes {
            // A sample line is a few hundred bytes. This much without a newline
            // means the far end is not speaking the stream protocol.
            outputBuffer.removeAll(keepingCapacity: false)
            state = .degraded
        }
    }

    private func receive(_ envelope: StreamEnvelope) {
        retryAttempt = 0
        latest = envelope
        state = envelope.error == nil ? .connected : .degraded

        if envelope.health.successfulPolls != lastSuccessfulPolls {
            lastSuccessfulPolls = envelope.health.successfulPolls
            let sampleDate = StreamDecoder.date(from: envelope.timestamp) ?? Date()
            if historyBuffer.append(HistoryPoint(date: sampleDate, reading: envelope.reading)) {
                history = historyBuffer.points
            }
        }
    }

    private func processTerminated(status: Int32) {
        process = nil
        outputPipe = nil
        errorPipe = nil
        guard shouldRun else { return }
        let message = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        state = .failed(
            message?.isEmpty == false
                ? message!
                : "solis-poll stopped unexpectedly (exit status \(status))."
        )
        scheduleRetry()
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
