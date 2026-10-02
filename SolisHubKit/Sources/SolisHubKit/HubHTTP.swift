import Foundation

public enum HubHTTPError: Error, Equatable, LocalizedError {
    case status(Int)
    case invalidResponse
    case decoding

    public var errorDescription: String? {
        switch self {
        case let .status(code) where code == 401 || code == 403:
            return "The hub rejected the access token or Cloudflare Access credentials."
        case .status(429):
            return "The hub is rate limiting this client."
        case let .status(code):
            return "The hub answered HTTP \(code)."
        case .invalidResponse:
            return "The hub's answer was not an HTTP response."
        case .decoding:
            return "The hub's answer could not be read."
        }
    }
}

/// The seam between the HTTP calls and URLSession, for tests.
public protocol HubHTTPTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPTransport: HubHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubHTTPError.invalidResponse }
        return (data, http)
    }
}

/// One authenticated GET against one endpoint, shared by the typed clients.
struct HubRESTCore: Sendable {
    let endpoint: HubEndpoint
    let auth: HubAuth
    let transport: any HubHTTPTransport
    let timeout: TimeInterval

    func get<T: Decodable>(
        _ path: String,
        query: [(name: String, value: String)] = [],
        as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: endpoint.httpURL(path: path, query: query))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in auth.headers() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await transport.fetch(request)
        guard response.statusCode == 200 else { throw HubHTTPError.status(response.statusCode) }
        do {
            return try StreamDecoder.makeJSONDecoder().decode(type, from: data)
        } catch {
            throw HubHTTPError.decoding
        }
    }
}

public struct HubStatus: Decodable, Sendable, Equatable {
    public let hubVersion: String
    public let hubProtocolVersion: Int
    public let hubId: String
    public let poller: HubPollerStatus
    public let clients: Int
    public let envelopeAgeS: Double?
}

/// GET /v1/status: cheap, authenticated, and independent of the WebSocket,
/// which makes it the right call for "Test connection".
public struct HubStatusClient: Sendable {
    private let core: HubRESTCore

    public init(
        endpoint: HubEndpoint,
        auth: HubAuth,
        transport: any HubHTTPTransport = URLSessionHTTPTransport(),
        timeout: TimeInterval = 10
    ) {
        core = HubRESTCore(endpoint: endpoint, auth: auth, transport: transport, timeout: timeout)
    }

    public func status() async throws -> HubStatus {
        try await core.get("/v1/status", as: HubStatus.self)
    }
}

public struct HubConnectionTestResult: Sendable, Equatable {
    /// Which address answered, and so whether this was LAN or remote.
    public let endpoint: HubEndpoint
    public let status: HubStatus
}

public struct HubConnectionTestError: Error, LocalizedError, Sendable {
    public let attempts: [(endpoint: HubEndpoint, message: String)]

    public var errorDescription: String? {
        if attempts.isEmpty {
            return "No hub address to test. Enter a LAN or remote address, or pick a discovered hub."
        }
        return attempts
            .map { "\($0.endpoint.displayName): \($0.message)" }
            .joined(separator: "\n")
    }
}

public enum HubConnectionTester {
    /// Asks each candidate in order, with the same LAN-then-remote timeouts as
    /// the live connection, and reports the first to answer.
    public static func test(
        candidates: [HubEndpoint],
        auth: HubAuth,
        configuration: HubClientConfiguration = HubClientConfiguration(),
        transport: any HubHTTPTransport = URLSessionHTTPTransport()
    ) async throws -> HubConnectionTestResult {
        var attempts: [(endpoint: HubEndpoint, message: String)] = []
        for endpoint in candidates {
            let client = HubStatusClient(
                endpoint: endpoint,
                auth: auth,
                transport: transport,
                timeout: configuration.connectTimeout(for: endpoint.kind)
            )
            do {
                return HubConnectionTestResult(endpoint: endpoint, status: try await client.status())
            } catch {
                attempts.append((endpoint, error.localizedDescription))
            }
        }
        throw HubConnectionTestError(attempts: attempts)
    }
}
