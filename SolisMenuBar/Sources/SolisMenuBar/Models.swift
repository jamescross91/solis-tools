import Foundation

enum StreamError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            let supported = StreamDecoder.supportedSchemaVersion
            return "solis-poll emits stream schema \(version) but this app reads schema "
                + "\(supported). Upgrade solis-tools with Homebrew."
        }
    }
}

struct StreamEnvelope: Decodable, Sendable {
    let schemaVersion: Int
    let timestamp: String
    let device: DeviceDetails
    let reading: InverterReading
    let health: ConnectionDetails
    let error: String?
}

struct DeviceDetails: Decodable, Sendable {
    let modelCode: Int
    let dspVersion: Int
    let hmiVersion: Int
    let protocolVersion: Int
    let typeDefinition: Int?
    let profileValidated: Bool
}

struct InverterReading: Decodable, Sendable {
    let gridVoltageV: Double
    let inverterTemperatureC: Double
    let inverterStatusCode: Int
    let inverterStatus: String
    let batterySocPercent: Int
    let houseLoadKw: Double
    let batteryKw: Double
    let batteryFlowKw: Double
    let batteryStatus: String
    let gridKw: Double
    let gridStatus: String
    let pvKw: Double?
    let pvTodayKwh: Double?
    let alarms: [InverterAlarm]

    /// Grid power with the display convention used by the menu bar: imports are positive and exports are negative.
    var gridImportPositiveKw: Double { -gridKw }
}

struct InverterAlarm: Decodable, Identifiable, Sendable {
    let code: String
    let message: String
    let severity: String

    var id: String { "\(code)-\(message)" }
}

struct ConnectionDetails: Decodable, Sendable {
    let lastSampleAgeS: Double?
    let latencyMs: Double
    let successfulPolls: Int
    let totalFailures: Int
    let consecutiveFailures: Int
    let reconnects: Int
    let rejectedSamples: Int?
}

struct HistoryPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let reading: InverterReading
}

struct HistoryBuffer: Sendable {
    static let displaySampleInterval: TimeInterval = 30
    static let retentionInterval: TimeInterval = 6 * 60 * 60

    private(set) var points: [HistoryPoint] = []

    @discardableResult
    mutating func append(_ point: HistoryPoint) -> Bool {
        if let last = points.last,
           point.date.timeIntervalSince(last.date) < Self.displaySampleInterval {
            return false
        }

        points.append(point)
        let cutoff = point.date.addingTimeInterval(-Self.retentionInterval)
        if let firstRetained = points.firstIndex(where: { $0.date >= cutoff }), firstRetained > 0 {
            points.removeFirst(firstRetained)
        }
        return true
    }

    mutating func removeAll() {
        points.removeAll(keepingCapacity: true)
    }
}

struct MonitorConfiguration: Equatable, Sendable {
    var host: String
    var port: Int
    var slave: Int
    var interval: Double
    var slowInterval: Double
    var inverterMaxKw: Double
    var gridMaxKw: Double
    var pvEnabled: Bool

    /// Read the settings the dashboard stores, or nil if no host is set yet.
    ///
    /// The keys match DashboardView's @AppStorage so the launch path and the
    /// settings form cannot drift apart.
    static func stored(_ defaults: UserDefaults = .standard) -> MonitorConfiguration? {
        let host = (defaults.string(forKey: "host") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        return MonitorConfiguration(
            host: host,
            port: defaults.object(forKey: "port") as? Int ?? 502,
            slave: defaults.object(forKey: "slave") as? Int ?? 1,
            interval: max(0.5, defaults.object(forKey: "pollInterval") as? Double ?? 1),
            slowInterval: max(1, defaults.object(forKey: "slowInterval") as? Double ?? 10),
            inverterMaxKw: max(0.1, defaults.object(forKey: "inverterMaxKw") as? Double ?? 10),
            gridMaxKw: max(0.1, defaults.object(forKey: "gridMaxKw") as? Double ?? 23),
            pvEnabled: defaults.bool(forKey: "pvEnabled")
        )
    }
}

enum HistoryMetric: String, CaseIterable, Identifiable {
    case house = "House"
    case battery = "Battery"
    case grid = "Grid"
    case voltage = "Voltage"
    case temperature = "Temperature"
    case pv = "PV"

    var id: Self { self }

    var unit: String {
        switch self {
        case .voltage: "V"
        case .temperature: "°C"
        default: "kW"
        }
    }

    /// Full-scale range this metric should show, from the configured maxima.
    ///
    /// Swift Charts otherwise fits the axis to whatever is on screen, so a
    /// quarter-kilowatt wobble filled the plot and looked like an event.
    func configuredRange(inverterMaxKw: Double, gridMaxKw: Double) -> ClosedRange<Double>? {
        switch self {
        case .house, .pv: 0...inverterMaxKw
        case .battery: -inverterMaxKw...inverterMaxKw
        case .grid: -gridMaxKw...gridMaxKw
        case .voltage, .temperature: nil
        }
    }

    func value(from reading: InverterReading) -> Double? {
        switch self {
        case .house: reading.houseLoadKw
        case .battery: reading.batteryFlowKw
        // Imports positive, matching the Grid card rather than the poller's
        // export-positive convention.
        case .grid: reading.gridImportPositiveKw
        case .voltage: reading.gridVoltageV
        case .temperature: reading.inverterTemperatureC
        case .pv: reading.pvKw
        }
    }
}

enum StreamDecoder {
    /// Stream schema this build knows how to read. solis_poll.py emits the same
    /// number; a newer poller means the app is out of date, not that the line
    /// is corrupt, and the two need telling apart in the UI.
    static let supportedSchemaVersion = 1

    static func decode(_ data: Data) throws -> StreamEnvelope {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(StreamEnvelope.self, from: data)
        guard envelope.schemaVersion == supportedSchemaVersion else {
            throw StreamError.unsupportedSchema(envelope.schemaVersion)
        }
        return envelope
    }

    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
