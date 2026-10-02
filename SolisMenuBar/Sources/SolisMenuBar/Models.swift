import Foundation
import SolisHubKit

struct HistoryPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let meterVoltageV: Double?
    let inverterTemperatureC: Double
    let houseLoadKw: Double
    let batteryFlowKw: Double
    let gridImportPositiveKw: Double
    let pvKw: Double?
    let controlState: String?
    let controlAction: String?
    let controlReason: String?
    let controlEmergency: Bool
    let controlMode: String?
    let importLimitW: Int?
    let exportLimitW: Int?

    init(date: Date, reading: InverterReading, voltageControl: VoltageControlDetails? = nil) {
        self.date = date
        meterVoltageV = reading.meterVoltageV
        inverterTemperatureC = reading.inverterTemperatureC
        houseLoadKw = reading.houseLoadKw
        batteryFlowKw = reading.batteryFlowKw
        gridImportPositiveKw = reading.gridImportPositiveKw
        pvKw = reading.pvKw
        controlState = voltageControl?.state
        controlAction = voltageControl?.action
        controlReason = voltageControl?.reason
        controlEmergency = voltageControl?.emergency ?? false
        controlMode = voltageControl?.mode
        importLimitW = voltageControl?.importActuator.commandedW
        exportLimitW = voltageControl?.exportActuator.commandedW
    }

    /// A point rebuilt from the hub's stored history. The hub keeps only the
    /// numeric fields of each sample, so the control reason is not available.
    init?(entry: HubHistoryEntry) {
        guard let date = entry.date else { return nil }
        let control = entry.voltageControl
        self.date = date
        meterVoltageV = entry.reading.meterVoltageV
        inverterTemperatureC = entry.reading.inverterTemperatureC
        houseLoadKw = entry.reading.houseLoadKw
        batteryFlowKw = entry.reading.batteryFlowKw
        gridImportPositiveKw = entry.reading.gridImportPositiveKw
        pvKw = entry.reading.pvKw
        controlState = control?.state
        controlAction = control?.action
        controlReason = nil
        controlEmergency = control?.emergency ?? false
        controlMode = control?.mode
        importLimitW = control?.importActuator?.commandedW
        exportLimitW = control?.exportActuator?.commandedW
    }
}

private struct TimeSeriesStorage<Element: Sendable>: Sendable {
    private var storage: [Element] = []
    private var startIndex = 0

    var elements: [Element] {
        guard startIndex < storage.count else { return [] }
        return Array(storage[startIndex...])
    }

    var last: Element? {
        startIndex < storage.count ? storage.last : nil
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func discardPrefix(while shouldDiscard: (Element) -> Bool) {
        while startIndex < storage.count, shouldDiscard(storage[startIndex]) {
            startIndex += 1
        }
        // Array.removeFirst shifts every retained element. Compact only
        // occasionally so steady-state history insertion remains amortised O(1).
        if startIndex >= 1_024, startIndex * 2 >= storage.count {
            storage.removeFirst(startIndex)
            startIndex = 0
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        startIndex = 0
    }
}

struct ControlHistoryBuffer: Sendable {
    static let retentionInterval: TimeInterval = 30 * 60
    private var storage = TimeSeriesStorage<HistoryPoint>()

    var points: [HistoryPoint] { storage.elements }

    mutating func append(_ point: HistoryPoint) {
        storage.append(point)
        let cutoff = point.date.addingTimeInterval(-Self.retentionInterval)
        storage.discardPrefix { $0.date < cutoff }
    }

    mutating func removeAll() {
        storage.removeAll()
    }

    /// Fold in older points fetched from the hub after live samples have
    /// already arrived, dropping any that share a timestamp.
    mutating func merge(backfill: [HistoryPoint]) {
        let live = points
        removeAll()
        for point in Self.ordered(backfill + live) {
            append(point)
        }
    }

    fileprivate static func ordered(_ points: [HistoryPoint]) -> [HistoryPoint] {
        var result: [HistoryPoint] = []
        for point in points.sorted(by: { $0.date < $1.date }) where point.date != result.last?.date {
            result.append(point)
        }
        return result
    }
}

struct HistoryBuffer: Sendable {
    static let displaySampleInterval: TimeInterval = 30
    static let retentionInterval: TimeInterval = 24 * 60 * 60

    private var storage = TimeSeriesStorage<HistoryPoint>()

    var points: [HistoryPoint] { storage.elements }

    @discardableResult
    mutating func append(_ point: HistoryPoint) -> Bool {
        if let last = storage.last,
           point.date.timeIntervalSince(last.date) < Self.displaySampleInterval {
            return false
        }

        storage.append(point)
        let cutoff = point.date.addingTimeInterval(-Self.retentionInterval)
        storage.discardPrefix { $0.date < cutoff }
        return true
    }

    mutating func removeAll() {
        storage.removeAll()
    }

    /// As ControlHistoryBuffer.merge: hub history first, then whatever live
    /// samples had already been kept, in time order.
    mutating func merge(backfill: [HistoryPoint]) {
        let live = points
        removeAll()
        for point in ControlHistoryBuffer.ordered(backfill + live) {
            append(point)
        }
    }
}

struct MonitorConfiguration: Equatable, Sendable {
    var host: String
    var port: Int
    var slave: Int
    var interval: Double
    var slowInterval: Double
    var idleInterval: Double
    var inverterMaxKw: Double
    var gridMaxKw: Double
    var pvEnabled: Bool
    var dynamicVoltageEnabled: Bool
    var dynamicImportEnabled: Bool
    var dynamicExportEnabled: Bool
    var minimumVoltage: Double
    var maximumVoltage: Double
    var voltageSafetyMargin: Double
    var voltageDeadband: Double
    var maximumImportKw: Double
    var importHeadroomKw: Double
    var maximumExportKw: Double
    var siteExportPermissionKw: Double
    var increaseStepW: Int
    var reductionStepW: Int
    var nearLimitReductionW: Int
    var emergencyReductionW: Int
    var controlSettleTime: Double
    var controlActivationDelay: Double
    var controlDeactivationDelay: Double
    var importActivationKw: Double
    var exportActivationKw: Double
    var minimumWriteInterval: Double
    var hypervoltEnabled: Bool
    var evPriority: String
    /// Empty means the poller's own default, <state dir>/hypervolt.json,
    /// written once by hypervolt-login.
    var hypervoltCredentialsPath: String
    var octopusEnabled: Bool
    /// Empty means the poller's own default, <state dir>/octopus.json,
    /// written once by octopus-login.
    var octopusCredentialsPath: String

    static var defaultOctopusCredentialsPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SolisTools", isDirectory: true)
            .appendingPathComponent("octopus.json")
            .path
    }

    /// Where hypervolt-login writes credentials when the user has not
    /// overridden the path, matching solis_poll.py's own default exactly so
    /// a poller launched without --hypervolt-credentials finds them.
    static var defaultHypervoltCredentialsPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SolisTools", isDirectory: true)
            .appendingPathComponent("hypervolt.json")
            .path
    }

    /// Read the settings the dashboard stores, or nil if no host is set yet.
    ///
    /// The keys match DashboardView's @AppStorage so the launch path and the
    /// settings form cannot drift apart.
    static func stored(_ defaults: UserDefaults = .standard) -> MonitorConfiguration? {
        let host = (defaults.string(forKey: "host") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let interval = max(0.5, defaults.object(forKey: "pollInterval") as? Double ?? 2)
        return MonitorConfiguration(
            host: host,
            port: defaults.object(forKey: "port") as? Int ?? 502,
            slave: defaults.object(forKey: "slave") as? Int ?? 1,
            interval: interval,
            slowInterval: max(1, defaults.object(forKey: "slowInterval") as? Double ?? 10),
            // The poller rejects an idle interval shorter than the fast one.
            idleInterval: max(interval, defaults.object(forKey: "idlePollInterval") as? Double ?? 5),
            inverterMaxKw: max(0.1, defaults.object(forKey: "inverterMaxKw") as? Double ?? 10),
            gridMaxKw: max(0.1, defaults.object(forKey: "gridMaxKw") as? Double ?? 23),
            pvEnabled: defaults.bool(forKey: "pvEnabled"),
            dynamicVoltageEnabled: defaults.bool(forKey: "dynamicVoltageEnabled"),
            dynamicImportEnabled: defaults.object(forKey: "dynamicImportEnabled") as? Bool ?? true,
            dynamicExportEnabled: defaults.bool(forKey: "dynamicExportEnabled"),
            minimumVoltage: min(279, max(180, defaults.object(forKey: "minimumVoltage") as? Double ?? 215)),
            maximumVoltage: min(280, max(181, defaults.object(forKey: "maximumVoltage") as? Double ?? 258)),
            voltageSafetyMargin: max(0.1, defaults.object(forKey: "voltageSafetyMargin") as? Double ?? 1.5),
            voltageDeadband: max(0.1, defaults.object(forKey: "voltageDeadband") as? Double ?? 0.75),
            maximumImportKw: max(1, defaults.object(forKey: "maximumImportKw") as? Double ?? 14),
            importHeadroomKw: max(
                0, defaults.object(forKey: "importHeadroomKw") as? Double ?? 2
            ),
            maximumExportKw: max(0, defaults.object(forKey: "maximumExportKw") as? Double ?? 10),
            siteExportPermissionKw: max(0, defaults.object(forKey: "siteExportPermissionKw") as? Double ?? 10),
            increaseStepW: max(100, defaults.object(forKey: "increaseStepW") as? Int ?? 200),
            reductionStepW: max(100, defaults.object(forKey: "reductionStepW") as? Int ?? 500),
            nearLimitReductionW: max(100, defaults.object(forKey: "nearLimitReductionW") as? Int ?? 1_000),
            emergencyReductionW: max(100, defaults.object(forKey: "emergencyReductionW") as? Int ?? 2_000),
            controlSettleTime: max(0, defaults.object(forKey: "controlSettleTime") as? Double ?? 5),
            controlActivationDelay: max(0, defaults.object(forKey: "controlActivationDelay") as? Double ?? 5),
            controlDeactivationDelay: max(0, defaults.object(forKey: "controlDeactivationDelay") as? Double ?? 10),
            importActivationKw: max(0, defaults.object(forKey: "importActivationKw") as? Double ?? 1),
            exportActivationKw: max(0, defaults.object(forKey: "exportActivationKw") as? Double ?? 0.5),
            minimumWriteInterval: max(5, defaults.object(forKey: "minimumWriteInterval") as? Double ?? 5),
            hypervoltEnabled: defaults.bool(forKey: "hypervoltEnabled"),
            evPriority: defaults.string(forKey: "evPriority") ?? "battery",
            hypervoltCredentialsPath: defaults.string(forKey: "hypervoltCredentialsPath") ?? "",
            octopusEnabled: defaults.bool(forKey: "octopusEnabled"),
            octopusCredentialsPath: defaults.string(forKey: "octopusCredentialsPath") ?? ""
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

    func value(from point: HistoryPoint) -> Double? {
        switch self {
        case .house: point.houseLoadKw
        case .battery: point.batteryFlowKw
        case .grid: point.gridImportPositiveKw
        case .voltage: point.meterVoltageV
        case .temperature: point.inverterTemperatureC
        case .pv: point.pvKw
        }
    }
}
