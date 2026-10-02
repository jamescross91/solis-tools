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
    var voltageControl: VoltageControlDetails?
    let cadence: StreamCadence?
    let error: String?
}

/// How often the poller is sampling. `idle` is true while nobody is watching
/// and dynamic control has nothing to regulate or restore.
struct StreamCadence: Decodable, Sendable {
    let intervalS: Double
    let idle: Bool
}

struct DeviceDetails: Decodable, Sendable {
    let modelCode: Int
    let dspVersion: Int
    let hmiVersion: Int
    let protocolVersion: Int
    let typeDefinition: Int?
    let profileValidated: Bool
    let remoteDispatchSupported: Bool?
    let remoteDispatchVersion: Int?
}

struct InverterReading: Decodable, Sendable {
    let gridVoltageV: Double
    let meterVoltageV: Double?
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

struct VoltageControlDetails: Decodable, Sendable {
    let state: String
    let action: String
    let mode: String?
    let desiredLimitW: Int?
    let rawVoltageV: Double?
    let filteredVoltageV: Double?
    let reason: String
    let emergency: Bool
    let voltageSource: String
    let estimatedVoltageSensitivityVPerKw: Double?
    let importDemandCeilingW: Int?
    let importActuator: ActuatorDetails
    let exportActuator: ActuatorDetails
    let exportWriteValidated: Bool
    /// Sent only when the log has changed since the previous sample.
    /// MonitorStore carries the last list forward, so views see nil only
    /// before the first control sample of a run.
    var recentEvents: [VoltageControlEvent]?
    let dailySummary: VoltageControlDailySummary?
    let recoveryNote: String?
    /// All three are nil unless --hypervolt-enable is on: which controllable
    /// load ("battery", "ev" or "balanced") is backed off first, whether a
    /// car is confirmed charging right now, and the EV actuator's own
    /// diagnostics. An older poller without Hypervolt support omits all
    /// three, which decodes the same way as Hypervolt simply being disabled.
    let evPriority: String?
    let evCharging: Bool?
    let hypervoltActuator: HypervoltActuatorDetails?
    /// Whether the EV charger's tighter band governed the last sample, and
    /// the band itself. Nil only from a poller older than the Octopus
    /// integration.
    let evVoltageLimitsActive: Bool?
    let effectiveMinimumVoltageV: Double?
    let effectiveMaximumVoltageV: Double?
    /// Nil unless --octopus-enable is on. Sent only when the plan or its
    /// active window changes; MonitorStore carries the last one forward.
    var octopusSchedule: OctopusScheduleDetails?
}

/// One planned Intelligent Octopus charge. Times carry their UTC offset.
struct OctopusChargeWindow: Decodable, Sendable, Identifiable {
    let start: String
    let end: String
    let kind: String
    /// Parsed once at decode. The window is carried forward for hours and
    /// its label is rendered on every dashboard refresh.
    let startDate: Date?
    let endDate: Date?

    var id: String { start }

    private enum CodingKeys: String, CodingKey {
        case start, end, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(String.self, forKey: .start)
        end = try container.decode(String.self, forKey: .end)
        kind = try container.decode(String.self, forKey: .kind)
        startDate = StreamDecoder.date(from: start)
        endDate = StreamDecoder.date(from: end)
    }

    var label: String {
        guard let from = startDate, let to = endDate else { return "\(start)–\(end)" }
        let sameDay = Calendar.current.isDate(from, inSameDayAs: Date())
        let day = sameDay ? "" : from.formatted(.dateTime.weekday(.abbreviated)) + " "
        return day + from.formatted(date: .omitted, time: .shortened) + "–"
            + to.formatted(date: .omitted, time: .shortened)
    }
}

/// The charge plan the poller last read from Octopus. A failed refresh keeps
/// the previous plan and reports `lastError`; see docs/octopus-integration.md.
struct OctopusScheduleDetails: Decodable, Sendable {
    let chargeWindowActive: Bool
    let activeWindow: OctopusChargeWindow?
    let nextWindow: OctopusChargeWindow?
    let plannedWindows: [OctopusChargeWindow]
    let leadTimeS: Double
    let fetchedAt: String?
    let lastError: String?
    /// The band held outside a charge and the band held during one, so the
    /// dashboard can say what a planned charge changes and what it returns
    /// to. Nil from a poller that predates them.
    let normalMinimumVoltageV: Double?
    let normalMaximumVoltageV: Double?
    let chargeMinimumVoltageV: Double?
    let chargeMaximumVoltageV: Double?

    /// When the tighter band starts: the lead-in before the next charge.
    var nextLeadInDate: Date? {
        nextWindow?.startDate.map { $0.addingTimeInterval(-leadTimeS) }
    }
}

extension OctopusScheduleDetails {
    /// Plain-language lines for the dashboard: when the next slot is, what it
    /// does to the voltage band and when the band goes back.
    func summaryLines(now: Date) -> [String] {
        let normal = Self.band(normalMinimumVoltageV, normalMaximumVoltageV)
        let charge = Self.band(chargeMinimumVoltageV, chargeMaximumVoltageV)
        let unchanged = normal != nil && normal == charge
        var lines: [String] = []
        if let active = activeWindow {
            if let start = active.startDate, start > now {
                lines.append("Charging slot starts at \(Self.clock(start, now: now)): \(active.label)")
            } else {
                lines.append("Charging slot now: \(active.label)")
            }
            if let normal, let charge, !unchanged {
                lines.append("Voltage band held at \(charge) for the charger, instead of \(normal).")
            }
            if let end = active.endDate {
                lines.append(
                    "Returns to \(normal ?? "the normal band") at \(Self.clock(end, now: now)) when the slot ends."
                )
            }
        } else if let next = nextWindow {
            lines.append("Next charging slot: \(next.label)")
            if let normal, let charge, !unchanged {
                let from = nextLeadInDate.map { "From \(Self.clock($0, now: now))" } ?? "During it"
                lines.append("\(from) the voltage band narrows from \(normal) to \(charge).")
            }
            if let end = next.endDate {
                lines.append(
                    "It reverts to \(normal ?? "the normal band") at \(Self.clock(end, now: now)) when the slot ends."
                )
            }
        } else {
            lines.append("No charging slot planned.")
        }
        if unchanged {
            lines.append("The charger's limits already sit inside the normal band, so nothing changes.")
        }
        // The first planned window is the one described above.
        let later = plannedWindows.count - 1
        if later > 0 {
            lines.append("\(later) more slot\(later == 1 ? "" : "s") planned after that.")
        }
        return lines
    }

    private static func band(_ minimum: Double?, _ maximum: Double?) -> String? {
        guard let minimum, let maximum else { return nil }
        return "\(Self.volts(minimum))–\(Self.volts(maximum)) V"
    }

    private static func volts(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func clock(_ date: Date, now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard !Calendar.current.isDate(date, inSameDayAs: now) else { return time }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }
}

/// Diagnostics for the Hypervolt current actuator. Deliberately not
/// ActuatorDetails: that shape is a Solis register (a PDU address, a
/// watt-per-raw-tick resolution); Hypervolt's own control surface is a
/// current in amps with no register behind it, so the two do not share one.
struct HypervoltActuatorDetails: Decodable, Sendable {
    let connected: Bool
    let commandedCurrentA: Double
    let minimumCurrentA: Double
    let maximumCurrentA: Double
    let totalWriteCount: Int
    let lastError: String?
    /// What the car is actually drawing, as distinct from the commanded cap.
    /// Nil from a poller that predates them, or before the charger reports.
    let measuredCurrentA: Double?
    let chargingPowerKw: Double?
    let sessionEnergyKwh: Double?
    let telemetryAgeS: Double?
}

struct VoltageControlDailySummary: Decodable, Sendable {
    let lowestVoltageV: Double
    let highestVoltageV: Double
    let importRegulatingS: Double
    let exportRegulatingS: Double
    let emergencyInterventions: Int
    let maximumImportKw: Double
    let maximumExportKw: Double
    let averageGridKw: Double
}

struct ActuatorDetails: Decodable, Sendable {
    let pduAddress: Int
    let resolutionW: Int
    let baselineRaw: Int?
    let lastCommandedRaw: Int?
    let lastRequestedRaw: Int?
    let lastWriteAt: String?
    let writesLastHour: Int
    let totalWriteCount: Int?
    let lastError: String?

    var commandedW: Int? { lastCommandedRaw.map { $0 * resolutionW } }
}

struct VoltageControlEvent: Decodable, Identifiable, Sendable {
    let timestamp: String
    let state: String
    let action: String
    let mode: String?
    let message: String
    let voltageV: Double?
    let gridKw: Double?
    let limitW: Int?
    let previousLimitW: Int?
    let limitDeltaW: Int?

    var id: String { "\(timestamp)-\(state)-\(message)" }

    var date: Date? { StreamDecoder.date(from: timestamp) }

    var timeLabel: String {
        date?.formatted(date: .omitted, time: .standard) ?? timestamp
    }

    var changeLabel: String {
        let subject = mode.map { "\($0.capitalized) limit" } ?? "Control limit"
        guard let limitW else { return state }
        let current = Self.power(limitW)
        guard let previousLimitW else { return "\(subject) \(current)" }
        if previousLimitW == limitW {
            return "\(subject) held at \(current)"
        }
        let delta = limitDeltaW ?? limitW - previousLimitW
        return "\(subject) \(Self.power(previousLimitW)) → \(current) (\(Self.signedPower(delta)))"
    }

    private static func power(_ watts: Int) -> String {
        String(format: "%.1f kW", Double(watts) / 1_000)
    }

    private static func signedPower(_ watts: Int) -> String {
        String(format: "%+.1f kW", Double(watts) / 1_000)
    }
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

enum StreamDecoder {
    /// Stream schema this build knows how to read. solis_poll.py emits the same
    /// number; a newer poller means the app is out of date, not that the line
    /// is corrupt, and the two need telling apart in the UI.
    static let supportedSchemaVersion = 2
    private static let fractionalDateStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let wholeSecondDateStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false
    )

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
        if let date = try? Date(value, strategy: fractionalDateStyle) {
            return date
        }
        return try? Date(value, strategy: wholeSecondDateStyle)
    }
}
