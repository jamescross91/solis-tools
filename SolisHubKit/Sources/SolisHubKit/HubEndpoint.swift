import Foundation

public enum HubEndpointKind: String, Sendable, Equatable, Hashable {
    case lan
    case remote

    public var label: String {
        switch self {
        case .lan: "LAN"
        case .remote: "remote"
        }
    }
}

/// One address a hub can be reached at, as an http(s) base URL. The WebSocket
/// and HTTP calls are both derived from it so they cannot disagree about host.
public struct HubEndpoint: Sendable, Equatable, Hashable, Identifiable {
    public let kind: HubEndpointKind
    public let baseURL: URL

    public init(kind: HubEndpointKind, baseURL: URL) {
        self.kind = kind
        self.baseURL = baseURL
    }

    public var id: String { "\(kind.rawValue) \(baseURL.absoluteString)" }

    /// ws:// on the LAN, wss:// through the tunnel.
    public var webSocketURL: URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = HubProtocol.streamPath
        components.query = nil
        return components.url ?? baseURL
    }

    public func httpURL(path: String, query: [(name: String, value: String)] = []) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        components.path = path
        // URLComponents leaves "+" alone in a query value, which a server
        // reads as a space, and ISO 8601 offsets contain one.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        components.percentEncodedQuery = query.isEmpty
            ? nil
            : query.map { item in
                let value = item.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(item.name)=\(value)"
            }.joined(separator: "&")
        return components.url ?? baseURL
    }

    /// For the UI; never includes credentials, which are never in the URL.
    public var displayName: String {
        let host = baseURL.host ?? baseURL.absoluteString
        guard let port = baseURL.port else { return "\(kind.label) \(host)" }
        return "\(kind.label) \(host):\(port)"
    }
}

/// Turns what a person types into a base URL. Kept apart from the UI so the
/// forgiving parsing is testable.
public enum HubURLInput {
    /// A LAN address: "192.168.1.5", "pi.local:8765", "http://pi.local:8765".
    /// A bare host gets the default port. Plain http is allowed here only;
    /// the LAN is where the token alone protects the hub.
    public static func lan(_ text: String) -> URL? {
        guard var components = parse(text, defaultScheme: "http"),
              let scheme = components.scheme
        else { return nil }
        switch scheme {
        case "http", "ws": components.scheme = "http"
        case "https", "wss": components.scheme = "https"
        default: return nil
        }
        if components.port == nil, components.scheme == "http" {
            components.port = HubProtocol.defaultPort
        }
        return components.url
    }

    /// A remote address, always TLS: a plain-text token over the internet is
    /// never what anyone wants, so "http://" and "ws://" are refused.
    public static func remote(_ text: String) -> URL? {
        guard var components = parse(text, defaultScheme: "https"),
              let scheme = components.scheme
        else { return nil }
        switch scheme {
        case "https", "wss": components.scheme = "https"
        default: return nil
        }
        return components.url
    }

    private static func parse(_ text: String, defaultScheme: String) -> URLComponents? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "\(defaultScheme)://\(trimmed)"
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        // A pasted URL may carry a path, credentials or a query; the base
        // is all that is wanted and credentials must not ride in the URL.
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components
    }
}

/// A hub found by Bonjour. `url` is nil until the service has been resolved
/// to an address; `hubID` comes from the TXT record and is what the
/// single-controller guard remembers an "ignore" against.
public struct DiscoveredHub: Sendable, Equatable, Hashable, Identifiable {
    public let name: String
    public let hubID: String?
    public let url: URL?

    public init(name: String, hubID: String?, url: URL?) {
        self.name = name
        self.hubID = hubID
        self.url = url
    }

    public var id: String { hubID ?? name }
}

/// What a client has been told about where its hub is.
public struct HubConnectionSettings: Sendable, Equatable {
    public var lanURL: URL?
    public var remoteURL: URL?
    /// The hub the person chose from the discovered list, so a neighbour's
    /// hub, or a second one, is never connected to by accident.
    public var preferredHubID: String?

    public init(lanURL: URL? = nil, remoteURL: URL? = nil, preferredHubID: String? = nil) {
        self.lanURL = lanURL
        self.remoteURL = remoteURL
        self.preferredHubID = preferredHubID
    }

    public var isEmpty: Bool { lanURL == nil && remoteURL == nil && preferredHubID == nil }
}

/// The order endpoints are tried in. Pure, so the rules are testable without
/// a network: the LAN first (a Bonjour result, then the typed LAN address),
/// then the remote URL, and nothing at all while the network is down.
public enum HubEndpointSelector {
    public static func candidates(
        settings: HubConnectionSettings,
        discovered: [DiscoveredHub],
        pathSatisfied: Bool = true
    ) -> [HubEndpoint] {
        guard pathSatisfied else { return [] }
        var result: [HubEndpoint] = []
        func add(_ endpoint: HubEndpoint) {
            if !result.contains(where: { $0.baseURL == endpoint.baseURL }) {
                result.append(endpoint)
            }
        }

        let eligible = discovered
            .filter { settings.preferredHubID == nil || $0.hubID == settings.preferredHubID }
            .sorted { $0.name < $1.name }
        for hub in eligible {
            if let url = hub.url {
                add(HubEndpoint(kind: .lan, baseURL: url))
            }
        }
        if let lan = settings.lanURL {
            add(HubEndpoint(kind: .lan, baseURL: lan))
        }
        if let remote = settings.remoteURL {
            add(HubEndpoint(kind: .remote, baseURL: remote))
        }
        return result
    }
}

/// Whether a change in the candidate list should move a live connection.
public enum HubReconnectPolicy {
    public static func shouldReconnect(current: HubEndpoint?, candidates: [HubEndpoint]) -> Bool {
        guard let current else { return !candidates.isEmpty }
        guard candidates.contains(current) else { return true }
        // Arriving home while connected through the tunnel: move to the LAN.
        return current.kind == .remote && candidates.first?.kind == .lan
    }
}
