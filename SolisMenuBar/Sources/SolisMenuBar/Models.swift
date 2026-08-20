import Foundation

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

    func value(from reading: InverterReading) -> Double? {
        switch self {
        case .house: reading.houseLoadKw
        case .battery: reading.batteryFlowKw
        case .grid: reading.gridKw
        case .voltage: reading.gridVoltageV
        case .temperature: reading.inverterTemperatureC
        case .pv: reading.pvKw
        }
    }
}

enum StreamDecoder {
    static func decode(_ data: Data) throws -> StreamEnvelope {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(StreamEnvelope.self, from: data)
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
