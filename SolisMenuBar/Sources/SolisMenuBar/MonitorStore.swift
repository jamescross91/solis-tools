import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject, @unchecked Sendable {
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

    var isRunning: Bool {
        switch state {
        case .stopped, .failed: false
        default: true
        }
    }

    var menuTitle: String {
        guard let reading = latest?.reading else { return "Solis" }
        return String(format: "%.2f kW", reading.houseLoadKw)
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
            history.removeAll()
            lastSuccessfulPolls = 0
        }
    }

    private func launch(configuration: MonitorConfiguration) {
        guard shouldRun else { return }
        guard let path = locatePoller() else {
            state = .failed(
                "solis-poll was not found. Install or upgrade solis-tools with Homebrew."
            )
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
            } catch {
                state = .degraded
            }
        }
    }

    private func receive(_ envelope: StreamEnvelope) {
        latest = envelope
        state = envelope.error == nil ? .connected : .degraded

        if envelope.health.successfulPolls != lastSuccessfulPolls {
            lastSuccessfulPolls = envelope.health.successfulPolls
            let sampleDate = StreamDecoder.date(from: envelope.timestamp) ?? Date()
            history.append(HistoryPoint(date: sampleDate, reading: envelope.reading))
            let cutoff = sampleDate.addingTimeInterval(-6 * 60 * 60)
            history.removeAll(where: { $0.date < cutoff })
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
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.launch(configuration: configuration)
        }
    }
}
