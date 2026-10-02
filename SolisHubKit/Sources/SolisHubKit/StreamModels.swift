import Foundation

public enum StreamError: LocalizedError {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            let supported = StreamDecoder.supportedSchemaVersion
            return "solis-poll emits stream schema \(version) but this app reads schema "
                + "\(supported). Upgrade solis-tools with Homebrew."
        }
    }
}

public struct StreamEnvelope: Decodable, Sendable {
    public let schemaVersion: Int
    public let timestamp: String
    public let device: DeviceDetails
    public let reading: InverterReading
    public let health: ConnectionDetails
    public var voltageControl: VoltageControlDetails?
    public let cadence: StreamCadence?
    public let error: String?
}

/// How often the poller is sampling. `idle` is true while nobody is watching
/// and dynamic control has nothing to regulate or restore.
public struct StreamCadence: Decodable, Sendable, Equatable {
    public let intervalS: Double
    public let idle: Bool
}

public struct DeviceDetails: Decodable, Sendable {
    public let modelCode: Int
    public let dspVersion: Int
    public let hmiVersion: Int
    public let protocolVersion: Int
    public let typeDefinition: Int?
    public let profileValidated: Bool
    public let remoteDispatchSupported: Bool?
    public let remoteDispatchVersion: Int?
}

public struct InverterReading: Decodable, Sendable {
    public let gridVoltageV: Double
    public let meterVoltageV: Double?
    public let inverterTemperatureC: Double
    public let inverterStatusCode: Int
    public let inverterStatus: String
    public let batterySocPercent: Int
    public let houseLoadKw: Double
    public let batteryKw: Double
    public let batteryFlowKw: Double
    public let batteryStatus: String
    public let gridKw: Double
    public let gridStatus: String
    public let pvKw: Double?
    public let pvTodayKwh: Double?
    public let alarms: [InverterAlarm]

    /// Grid power with the display convention used by the menu bar: imports are positive and exports are negative.
    public var gridImportPositiveKw: Double { -gridKw }
}

public struct VoltageControlDetails: Decodable, Sendable {
    public let state: String
    public let action: String
    public let mode: String?
    public let desiredLimitW: Int?
    public let rawVoltageV: Double?
    public let filteredVoltageV: Double?
    public let reason: String
    public let emergency: Bool
    public let voltageSource: String
    public let estimatedVoltageSensitivityVPerKw: Double?
    public let importDemandCeilingW: Int?
    public let importActuator: ActuatorDetails
    public let exportActuator: ActuatorDetails
    public let exportWriteValidated: Bool
    /// Sent only when the log has changed since the previous sample.
    /// StreamStateMerger carries the last list forward, so views see nil only
    /// before the first control sample of a run.
    public var recentEvents: [VoltageControlEvent]?
    public let dailySummary: VoltageControlDailySummary?
    public let recoveryNote: String?
    /// All three are nil unless --hypervolt-enable is on: which controllable
    /// load ("battery", "ev" or "balanced") is backed off first, whether a
    /// car is confirmed charging right now, and the EV actuator's own
    /// diagnostics. An older poller without Hypervolt support omits all
    /// three, which decodes the same way as Hypervolt simply being disabled.
    public let evPriority: String?
    public let evCharging: Bool?
    public let hypervoltActuator: HypervoltActuatorDetails?
    /// Whether the EV charger's tighter band governed the last sample, and
    /// the band itself. Nil only from a poller older than the Octopus
    /// integration.
    public let evVoltageLimitsActive: Bool?
    public let effectiveMinimumVoltageV: Double?
    public let effectiveMaximumVoltageV: Double?
    /// Nil unless --octopus-enable is on. Sent only when the plan or its
    /// active window changes; StreamStateMerger carries the last one forward.
    public var octopusSchedule: OctopusScheduleDetails?
    /// The controller's effective settings. Sent in the first sample of a run
    /// only, so StreamStateMerger carries it forward; a client that does not run
    /// the poller shows these read-only. Nil from a poller that predates the
    /// field being decoded, or before the first sample of a run.
    public var configuration: VoltageControlConfiguration?
}

/// The poller's effective control settings, as sent in `configuration`.
///
/// Every field is optional and numeric fields are Doubles whatever Python's
/// dataclass calls them: this is display-only, and a poller that adds, drops
/// or retypes a field must not stop the whole sample decoding.
public struct VoltageControlConfiguration: Decodable, Sendable, Equatable {
    public let enabled: Bool?
    public let importEnabled: Bool?
    public let exportEnabled: Bool?
    public let exportControlValidated: Bool?
    public let minimumVoltageV: Double?
    public let maximumVoltageV: Double?
    public let safetyMarginV: Double?
    public let deadbandV: Double?
    public let maximumImportW: Double?
    public let maximumExportW: Double?
    public let siteExportPermissionW: Double?
    public let minimumImportW: Double?
    public let importHeadroomW: Double?
    public let increaseStepW: Double?
    public let reductionStepW: Double?
    public let nearLimitReductionW: Double?
    public let emergencyReductionW: Double?
    public let settleTimeS: Double?
    public let activationDelayS: Double?
    public let deactivationDelayS: Double?
    public let importActivationW: Double?
    public let exportActivationW: Double?
    public let hypervoltEnabled: Bool?
    public let evPriority: String?
    public let octopusEnabled: Bool?
    public let octopusLeadTimeS: Double?
}

/// One planned Intelligent Octopus charge. Times carry their UTC offset.
public struct OctopusChargeWindow: Decodable, Sendable, Identifiable {
    public let start: String
    public let end: String
    public let kind: String
    /// Parsed once at decode. The window is carried forward for hours and
    /// its label is rendered on every dashboard refresh.
    public let startDate: Date?
    public let endDate: Date?

    public var id: String { start }

    private enum CodingKeys: String, CodingKey {
        case start, end, kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(String.self, forKey: .start)
        end = try container.decode(String.self, forKey: .end)
        kind = try container.decode(String.self, forKey: .kind)
        startDate = StreamDecoder.date(from: start)
        endDate = StreamDecoder.date(from: end)
    }

    public var label: String {
        guard let from = startDate, let to = endDate else { return "\(start)–\(end)" }
        let sameDay = Calendar.current.isDate(from, inSameDayAs: Date())
        let day = sameDay ? "" : from.formatted(.dateTime.weekday(.abbreviated)) + " "
        return day + from.formatted(date: .omitted, time: .shortened) + "–"
            + to.formatted(date: .omitted, time: .shortened)
    }
}

/// The charge plan the poller last read from Octopus. A failed refresh keeps
/// the previous plan and reports `lastError`; see docs/octopus-integration.md.
public struct OctopusScheduleDetails: Decodable, Sendable {
    public let chargeWindowActive: Bool
    public let activeWindow: OctopusChargeWindow?
    public let nextWindow: OctopusChargeWindow?
    public let plannedWindows: [OctopusChargeWindow]
    public let leadTimeS: Double
    public let fetchedAt: String?
    public let lastError: String?
    /// The band held outside a charge and the band held during one, so the
    /// dashboard can say what a planned charge changes and what it returns
    /// to. Nil from a poller that predates them.
    public let normalMinimumVoltageV: Double?
    public let normalMaximumVoltageV: Double?
    public let chargeMinimumVoltageV: Double?
    public let chargeMaximumVoltageV: Double?

    /// When the tighter band starts: the lead-in before the next charge.
    public var nextLeadInDate: Date? {
        nextWindow?.startDate.map { $0.addingTimeInterval(-leadTimeS) }
    }
}

extension OctopusScheduleDetails {
    /// Plain-language lines for the dashboard: when the next slot is, what it
    /// does to the voltage band and when the band goes back.
    public func summaryLines(now: Date) -> [String] {
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
public struct HypervoltActuatorDetails: Decodable, Sendable {
    public let connected: Bool
    public let commandedCurrentA: Double
    public let minimumCurrentA: Double
    public let maximumCurrentA: Double
    public let totalWriteCount: Int
    public let lastError: String?
    /// What the car is actually drawing, as distinct from the commanded cap.
    /// Nil from a poller that predates them, or before the charger reports.
    public let measuredCurrentA: Double?
    public let chargingPowerKw: Double?
    public let sessionEnergyKwh: Double?
    public let telemetryAgeS: Double?
}

public struct VoltageControlDailySummary: Decodable, Sendable {
    public let lowestVoltageV: Double
    public let highestVoltageV: Double
    public let importRegulatingS: Double
    public let exportRegulatingS: Double
    public let emergencyInterventions: Int
    public let maximumImportKw: Double
    public let maximumExportKw: Double
    public let averageGridKw: Double
}

public struct ActuatorDetails: Decodable, Sendable {
    public let pduAddress: Int
    public let resolutionW: Int
    public let baselineRaw: Int?
    public let lastCommandedRaw: Int?
    public let lastRequestedRaw: Int?
    public let lastWriteAt: String?
    public let writesLastHour: Int
    public let totalWriteCount: Int?
    public let lastError: String?

    public var commandedW: Int? { lastCommandedRaw.map { $0 * resolutionW } }
}

public struct VoltageControlEvent: Decodable, Identifiable, Sendable {
    public let timestamp: String
    public let state: String
    public let action: String
    public let mode: String?
    public let message: String
    public let voltageV: Double?
    public let gridKw: Double?
    public let limitW: Int?
    public let previousLimitW: Int?
    public let limitDeltaW: Int?

    public var id: String { "\(timestamp)-\(state)-\(message)" }

    public var date: Date? { StreamDecoder.date(from: timestamp) }

    public var timeLabel: String {
        date?.formatted(date: .omitted, time: .standard) ?? timestamp
    }

    public var changeLabel: String {
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

public struct InverterAlarm: Decodable, Identifiable, Sendable {
    public let code: String
    public let message: String
    public let severity: String

    public var id: String { "\(code)-\(message)" }
}

public struct ConnectionDetails: Decodable, Sendable {
    public let lastSampleAgeS: Double?
    public let latencyMs: Double
    public let successfulPolls: Int
    public let totalFailures: Int
    public let consecutiveFailures: Int
    public let reconnects: Int
    public let rejectedSamples: Int?
}

public enum StreamDecoder {
    /// Stream schema this build knows how to read. solis_poll.py emits the same
    /// number; a newer poller means the app is out of date, not that the line
    /// is corrupt, and the two need telling apart in the UI.
    public static let supportedSchemaVersion = 2
    private static let fractionalDateStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let wholeSecondDateStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false
    )

    /// One decoder shape for the stream and the hub's messages, so the
    /// snake_case convention cannot drift between them.
    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func decode(_ data: Data) throws -> StreamEnvelope {
        let decoder = makeJSONDecoder()
        let envelope = try decoder.decode(StreamEnvelope.self, from: data)
        guard envelope.schemaVersion == supportedSchemaVersion else {
            throw StreamError.unsupportedSchema(envelope.schemaVersion)
        }
        return envelope
    }

    public static func date(from value: String) -> Date? {
        if let date = try? Date(value, strategy: fractionalDateStyle) {
            return date
        }
        return try? Date(value, strategy: wholeSecondDateStyle)
    }
}
