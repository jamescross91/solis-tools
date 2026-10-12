import Foundation

/// The controller settings a hub runs its poller with: the same ones the menu
/// bar edits in Direct mode. Field names match /v1/settings (snake_case on the
/// wire); connection, polling and file paths are not here because a client
/// cannot change them.
public struct HubControlSettings: Codable, Sendable, Equatable {
    public var dynamicVoltageEnabled: Bool
    public var dynamicImportEnabled: Bool
    public var dynamicExportEnabled: Bool
    public var minimumVoltage: Double
    public var maximumVoltage: Double
    public var voltageSafetyMargin: Double
    public var voltageDeadband: Double
    public var maximumImportKw: Double
    public var importHeadroomKw: Double
    public var exportHeadroomKw: Double
    public var maximumExportKw: Double
    public var siteExportPermissionKw: Double
    public var increaseStepW: Int
    public var reductionStepW: Int
    public var nearLimitReductionW: Int
    public var emergencyReductionW: Int
    public var controlSettleTime: Double
    public var controlActivationDelay: Double
    public var controlDeactivationDelay: Double
    public var importActivationKw: Double
    public var exportActivationKw: Double
    public var minimumWriteInterval: Double
    public var hypervoltEnabled: Bool
    public var evPriority: String
    public var octopusEnabled: Bool

    public init(
        dynamicVoltageEnabled: Bool,
        dynamicImportEnabled: Bool,
        dynamicExportEnabled: Bool,
        minimumVoltage: Double,
        maximumVoltage: Double,
        voltageSafetyMargin: Double,
        voltageDeadband: Double,
        maximumImportKw: Double,
        importHeadroomKw: Double,
        exportHeadroomKw: Double,
        maximumExportKw: Double,
        siteExportPermissionKw: Double,
        increaseStepW: Int,
        reductionStepW: Int,
        nearLimitReductionW: Int,
        emergencyReductionW: Int,
        controlSettleTime: Double,
        controlActivationDelay: Double,
        controlDeactivationDelay: Double,
        importActivationKw: Double,
        exportActivationKw: Double,
        minimumWriteInterval: Double,
        hypervoltEnabled: Bool,
        evPriority: String,
        octopusEnabled: Bool
    ) {
        self.dynamicVoltageEnabled = dynamicVoltageEnabled
        self.dynamicImportEnabled = dynamicImportEnabled
        self.dynamicExportEnabled = dynamicExportEnabled
        self.minimumVoltage = minimumVoltage
        self.maximumVoltage = maximumVoltage
        self.voltageSafetyMargin = voltageSafetyMargin
        self.voltageDeadband = voltageDeadband
        self.maximumImportKw = maximumImportKw
        self.importHeadroomKw = importHeadroomKw
        self.exportHeadroomKw = exportHeadroomKw
        self.maximumExportKw = maximumExportKw
        self.siteExportPermissionKw = siteExportPermissionKw
        self.increaseStepW = increaseStepW
        self.reductionStepW = reductionStepW
        self.nearLimitReductionW = nearLimitReductionW
        self.emergencyReductionW = emergencyReductionW
        self.controlSettleTime = controlSettleTime
        self.controlActivationDelay = controlActivationDelay
        self.controlDeactivationDelay = controlDeactivationDelay
        self.importActivationKw = importActivationKw
        self.exportActivationKw = exportActivationKw
        self.minimumWriteInterval = minimumWriteInterval
        self.hypervoltEnabled = hypervoltEnabled
        self.evPriority = evPriority
        self.octopusEnabled = octopusEnabled
    }
}

public struct HubHypervoltAccount: Decodable, Sendable, Equatable {
    public let signedIn: Bool
    public let chargerId: String?
}

public struct HubOctopusAccount: Decodable, Sendable, Equatable {
    public let signedIn: Bool
    public let accountNumber: String?
    public let deviceId: String?
}

/// What GET /v1/settings returns, and what a change or sign-in answers with.
/// Account fields are only what is safe to show: never a key or a token.
public struct HubSettingsState: Decodable, Sendable, Equatable {
    public let settings: HubControlSettings
    /// "hub_config" until an app saves settings, then "app".
    public let source: String
    public let exportControlValidated: Bool
    public let hypervolt: HubHypervoltAccount
    public let octopus: HubOctopusAccount
    /// Whether the change restarted the hub's poller; absent on a plain GET.
    public let restarted: Bool?
    /// The login command's own confirmation, after a sign-in.
    public let message: String?

    public var setFromApp: Bool { source == "app" }
}

public enum HubAdminError: Error, LocalizedError, Sendable {
    /// The hub predates the settings API.
    case unsupported

    public var errorDescription: String? {
        "This hub cannot be configured from the app yet. Upgrade solis-tools on the hub."
    }
}

/// Settings and sign-in against one hub endpoint.
///
/// Every call changes or reveals what the poller runs, so each one carries the
/// same token as the stream. Secrets are sent once in the request body and are
/// handled on the hub only by hypervolt-login or octopus-login.
public struct HubAdminClient: Sendable {
    public let endpoint: HubEndpoint
    private let core: HubRESTCore
    private let signInCore: HubRESTCore

    public init(
        endpoint: HubEndpoint,
        auth: HubAuth,
        transport: any HubHTTPTransport = URLSessionHTTPTransport(),
        timeout: TimeInterval = 15
    ) {
        self.endpoint = endpoint
        core = HubRESTCore(endpoint: endpoint, auth: auth, transport: transport, timeout: timeout)
        // The hub gives a login command a minute to reach Hypervolt or Octopus.
        signInCore = HubRESTCore(endpoint: endpoint, auth: auth, transport: transport, timeout: 75)
    }

    public func settings() async throws -> HubSettingsState {
        try await Self.translating { try await core.get("/v1/settings", as: HubSettingsState.self) }
    }

    /// Saves the settings and, when they differ from what is running, restarts
    /// the hub's poller, which restores the inverter's limits on its way out.
    public func save(_ settings: HubControlSettings) async throws -> HubSettingsState {
        try await Self.translating {
            try await core.send("PUT", "/v1/settings", body: settings, as: HubSettingsState.self)
        }
    }

    private struct HypervoltSignIn: Encodable {
        let email: String
        let password: String
    }

    public func signInToHypervolt(email: String, password: String) async throws -> HubSettingsState {
        try await Self.translating {
            try await signInCore.send(
                "POST", "/v1/credentials/hypervolt",
                body: HypervoltSignIn(email: email, password: password),
                as: HubSettingsState.self
            )
        }
    }

    private struct OctopusSignIn: Encodable {
        let apiKey: String
        let account: String?
        let device: String?
    }

    public func signInToOctopus(
        apiKey: String, account: String? = nil, device: String? = nil
    ) async throws -> HubSettingsState {
        try await Self.translating {
            try await signInCore.send(
                "POST", "/v1/credentials/octopus",
                body: OctopusSignIn(apiKey: apiKey, account: account, device: device),
                as: HubSettingsState.self
            )
        }
    }

    private static func translating<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch HubHTTPError.status(404) {
            throw HubAdminError.unsupported
        }
    }

    /// The first endpoint that answers GET /v1/settings, LAN before remote, as
    /// the stream connects; later changes go to the same one.
    public static func connect(
        candidates: [HubEndpoint],
        auth: HubAuth,
        configuration: HubClientConfiguration = HubClientConfiguration(),
        transport: any HubHTTPTransport = URLSessionHTTPTransport()
    ) async throws -> (client: HubAdminClient, state: HubSettingsState) {
        var attempts: [(endpoint: HubEndpoint, message: String)] = []
        for endpoint in candidates {
            let probe = HubAdminClient(
                endpoint: endpoint, auth: auth, transport: transport,
                timeout: configuration.connectTimeout(for: endpoint.kind)
            )
            do {
                let state = try await probe.settings()
                return (HubAdminClient(endpoint: endpoint, auth: auth, transport: transport), state)
            } catch let error as HubAdminError {
                // An old hub answered: trying the other address would reach the same hub.
                throw error
            } catch {
                attempts.append((endpoint, error.localizedDescription))
            }
        }
        throw HubConnectionTestError(attempts: attempts)
    }
}
