import Foundation

public enum HubHistoryResolution: String, Sendable {
    /// Every sample, for the last `history_native_minutes`.
    case native
    /// One sample per thirty seconds, for the last `history_compact_hours`.
    case compact
}

/// The reading as the hub stores it for history: everything a chart needs
/// and nothing it does not. Alarms are left out by the hub, which is why this
/// is not an InverterReading.
public struct HubHistoryReading: Decodable, Sendable, Equatable {
    public let gridVoltageV: Double?
    public let meterVoltageV: Double?
    public let inverterTemperatureC: Double
    public let batterySocPercent: Int?
    public let houseLoadKw: Double
    public let batteryKw: Double?
    public let batteryFlowKw: Double
    public let gridKw: Double
    public let pvKw: Double?
    public let pvTodayKwh: Double?

    /// Imports positive, as the menu bar shows them.
    public var gridImportPositiveKw: Double { -gridKw }
}

public struct HubHistoryActuator: Decodable, Sendable, Equatable {
    public let lastCommandedRaw: Int?
    public let resolutionW: Int?

    public var commandedW: Int? {
        guard let lastCommandedRaw, let resolutionW else { return nil }
        return lastCommandedRaw * resolutionW
    }
}

/// The numeric part of a sample's voltage_control, kept per history entry.
public struct HubHistoryControl: Decodable, Sendable, Equatable {
    public let state: String?
    public let action: String?
    public let mode: String?
    public let rawVoltageV: Double?
    public let filteredVoltageV: Double?
    public let desiredLimitW: Int?
    public let emergency: Bool?
    public let effectiveMinimumVoltageV: Double?
    public let effectiveMaximumVoltageV: Double?
    public let evVoltageLimitsActive: Bool?
    public let evCharging: Bool?
    public let importActuator: HubHistoryActuator?
    public let exportActuator: HubHistoryActuator?
}

public struct HubHistoryEntry: Decodable, Sendable, Equatable {
    public let timestamp: String
    public let reading: HubHistoryReading
    public let cadence: StreamCadence?
    /// Nil when dynamic control was off for that sample.
    public let voltageControl: HubHistoryControl?

    public var date: Date? { StreamDecoder.date(from: timestamp) }
}

/// One row of the poller's `voltage_minutes` table. Columns are named exactly
/// as the database names them.
public struct HubControlMinute: Decodable, Sendable, Equatable {
    /// Epoch seconds at the start of the minute.
    public let minute: Int
    public let voltageMin: Double
    public let voltageMax: Double
    public let voltageSum: Double
    public let gridKwMin: Double
    public let gridKwMax: Double
    public let gridKwSum: Double
    public let limitWMin: Int?
    public let limitWMax: Int?
    public let limitWSum: Int
    public let sampleCount: Int
    public let secondsImport: Double
    public let secondsExport: Double
    public let secondsIncreasing: Double
    public let secondsHolding: Double
    public let secondsReducing: Double
    public let emergencyCount: Int

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(minute)) }
}

/// One row of the poller's `voltage_events` table.
public struct HubControlEventRow: Decodable, Sendable, Equatable {
    public let timestamp: String
    public let state: String
    public let action: String
    public let message: String
    public let voltageV: Double?
    public let gridKw: Double?
    public let limitW: Int?

    public var date: Date? { StreamDecoder.date(from: timestamp) }
}

/// Typed calls for the hub's two history endpoints. Responses may be gzip;
/// URLSession undoes that before this sees the body.
public struct HubHistoryClient: Sendable {
    private let core: HubRESTCore

    public init(
        endpoint: HubEndpoint,
        auth: HubAuth,
        transport: any HubHTTPTransport = URLSessionHTTPTransport(),
        timeout: TimeInterval = 30
    ) {
        core = HubRESTCore(endpoint: endpoint, auth: auth, transport: transport, timeout: timeout)
    }

    /// In-memory samples newer than `since`, oldest first.
    public func samples(
        since: Date?, resolution: HubHistoryResolution
    ) async throws -> [HubHistoryEntry] {
        var query: [(name: String, value: String)] = [("resolution", resolution.rawValue)]
        if let since {
            query.append(("since", Self.timestamp(since)))
        }
        return try await core.get("/v1/history/samples", query: query, as: [HubHistoryEntry].self)
    }

    /// Per-minute control aggregates from the poller's SQLite history.
    public func controlMinutes(since: Date?) async throws -> [HubControlMinute] {
        try await core.get(
            "/v1/history/control", query: controlQuery(kind: "minutes", since: since),
            as: [HubControlMinute].self
        )
    }

    /// Control events from the poller's SQLite history, oldest first.
    public func controlEvents(since: Date?) async throws -> [HubControlEventRow] {
        try await core.get(
            "/v1/history/control", query: controlQuery(kind: "events", since: since),
            as: [HubControlEventRow].self
        )
    }

    private func controlQuery(kind: String, since: Date?) -> [(name: String, value: String)] {
        var query: [(name: String, value: String)] = [("kind", kind)]
        if let since {
            query.append(("since", Self.timestamp(since)))
        }
        return query
    }

    /// UTC with a Z suffix: no "+" to be misread as a space in a query.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
