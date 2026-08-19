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
