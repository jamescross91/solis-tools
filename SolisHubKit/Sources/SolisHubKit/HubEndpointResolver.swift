import Foundation
import Network

/// What the network glue knows right now. The pure selection logic turns this
/// plus the user's settings into the endpoints to try.
public struct HubNetworkState: Sendable, Equatable {
    public var discovered: [DiscoveredHub]
    public var pathSatisfied: Bool
    /// True once the first Bonjour scan has had time to report. A caller that
    /// must know whether a hub is on the network before acting (the menu bar's
    /// single-controller guard) waits for this, with its own timeout, because
    /// an empty network never produces a "scan finished" callback.
    public var scanCompleted: Bool
    /// Changes whenever the device's network path changes shape (an interface
    /// or gateway came or went) even if it stayed "satisfied", so a client
    /// can reconnect LAN-first after leaving or reaching home. Not meaningful
    /// as a number: only a change matters.
    public var pathRevision: Int
    /// Why Bonjour browsing is not running, in words, or nil when it is. The
    /// usual cause is Local Network access being denied, in which case no hub
    /// would ever be seen.
    public var discoveryProblem: String?

    public init(
        discovered: [DiscoveredHub] = [],
        pathSatisfied: Bool = true,
        scanCompleted: Bool = false,
        pathRevision: Int = 0,
        discoveryProblem: String? = nil
    ) {
        self.discovered = discovered
        self.pathSatisfied = pathSatisfied
        self.scanCompleted = scanCompleted
        self.pathRevision = pathRevision
        self.discoveryProblem = discoveryProblem
    }
}

/// Turns a stream of network path snapshots into a revision counter. Kept
/// apart from NWPathMonitor so the rule is testable: the first snapshot is
/// the starting point rather than a change, and a snapshot identical to the
/// last one is not a change either.
struct HubPathRevisionTracker: Equatable {
    private(set) var revision = 0
    private var last: Set<String>?

    /// Interface names and gateways, not just whether the path is satisfied:
    /// home and a cafe are both "Wi-Fi on en0", and only the gateway differs.
    static func signature(interfaces: [String], gateways: [String]) -> Set<String> {
        var result = Set<String>()
        for name in interfaces {
            result.insert("if:\(name)")
        }
        for gateway in gateways {
            result.insert("gw:\(gateway)")
        }
        return result
    }

    /// Returns whether this snapshot changed the revision.
    @discardableResult
    mutating func observe(_ signature: Set<String>) -> Bool {
        let previous = last
        last = signature
        guard let previous, previous != signature else { return false }
        revision += 1
        return true
    }
}

/// Bonjour browsing for `_solis-hub._tcp` plus an NWPathMonitor, published as
/// one stream of `HubNetworkState`. This is only glue to Network.framework:
/// choosing an endpoint is `HubEndpointSelector`, which has no dependency on
/// it. Single use and single consumer: `stop()` finishes the stream.
///
/// Every mutable property is touched only on `queue`, which is what makes the
/// `@unchecked Sendable` honest.
public final class HubEndpointResolver: @unchecked Sendable {
    public let updates: AsyncStream<HubNetworkState>

    private let continuation: AsyncStream<HubNetworkState>.Continuation
    private let queue = DispatchQueue(label: "solis-hub.endpoint-resolver")
    private let resolveAddresses: Bool

    private struct Service {
        var name: String
        var hubID: String?
        var endpoint: NWEndpoint
        var url: URL?
        /// The advertisement changed since `url` was resolved, so the address
        /// may have moved. The old URL stays in use until a new one arrives.
        var stale = false
    }

    private var browser: NWBrowser?
    private var monitor: NWPathMonitor?
    private var services: [String: Service] = [:]
    private var resolvers: [String: NWConnection] = [:]
    private var pathSatisfied = true
    private var pathTracker = HubPathRevisionTracker()
    private var discoveryProblem: String?
    private var scanCompleted = false
    private var started = false
    private var stopped = false
    private var lastPublished: HubNetworkState?

    /// `resolveAddresses` can be false by a caller that only needs to know a
    /// hub exists and which one (its hub id), not where it is.
    public init(resolveAddresses: Bool = true) {
        self.resolveAddresses = resolveAddresses
        var captured: AsyncStream<HubNetworkState>.Continuation?
        updates = AsyncStream<HubNetworkState> { captured = $0 }
        continuation = captured!
    }

    public func start() {
        queue.async { [self] in
            guard !started, !stopped else { return }
            started = true
            startBrowser()
            startPathMonitor()
            publish()
        }
    }

    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            browser?.cancel()
            monitor?.cancel()
            browser = nil
            monitor = nil
            for connection in resolvers.values {
                connection.cancel()
            }
            resolvers.removeAll()
            continuation.finish()
        }
    }

    // MARK: Browsing (on queue)

    private func startBrowser() {
        guard !stopped else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: HubProtocol.bonjourServiceType, domain: nil),
            using: NWParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.browseResultsChanged(results, changes: changes)
        }
        browser.stateUpdateHandler = { [weak self] state in
            self?.browserStateChanged(state)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        switch state {
        case .waiting:
            // Local Network access denied lands here, and so does being
            // offline; the text covers both rather than guessing which.
            discoveryProblem = "Hub discovery is not running. Local Network access may be off for "
                + "this app in System Settings, or the network is offline."
            publish()
        case .ready:
            discoveryProblem = nil
            // Results follow the ready state within moments; an empty network
            // reports nothing at all, so the scan is called complete on a timer.
            queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, !self.stopped else { return }
                self.scanCompleted = true
                self.publish()
            }
        case .failed:
            discoveryProblem = "Hub discovery stopped; trying again."
            publish()
            browser?.cancel()
            browser = nil
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startBrowser()
            }
        default:
            break
        }
    }

    private func browseResultsChanged(
        _ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>
    ) {
        for change in changes {
            if case let .changed(_, new, _) = change, case let .service(name, _, _, _) = new.endpoint {
                services[name]?.stale = true
            }
        }
        var seen = Set<String>()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            seen.insert(name)
            var hubID: String?
            if case let .bonjour(record) = result.metadata {
                hubID = record["hub_id"]
            }
            if var existing = services[name] {
                if existing.hubID != hubID || existing.endpoint != result.endpoint {
                    existing.stale = true
                }
                existing.hubID = hubID
                existing.endpoint = result.endpoint
                services[name] = existing
            } else {
                services[name] = Service(name: name, hubID: hubID, endpoint: result.endpoint, url: nil)
            }
        }
        for name in services.keys where !seen.contains(name) {
            services[name] = nil
            resolvers[name]?.cancel()
            resolvers[name] = nil
        }
        if !results.isEmpty {
            scanCompleted = true
        }
        if resolveAddresses {
            for service in services.values
            where (service.url == nil || service.stale) && resolvers[service.name] == nil {
                resolve(service)
            }
        }
        publish()
    }

    /// A Bonjour service has a name, not an address. Opening a connection to
    /// it and reading back the path's remote endpoint is the supported way to
    /// get one; IPv4 is asked for because a link-local IPv6 address is no use
    /// in a URL without its zone.
    private func resolve(_ service: Service) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: service.endpoint, using: parameters)
        let name = service.name
        connection.stateUpdateHandler = { [weak self] state in
            self?.resolverStateChanged(name: name, state: state)
        }
        resolvers[name] = connection
        connection.start(queue: queue)
    }

    private func resolverStateChanged(name: String, state: NWConnection.State) {
        switch state {
        case .ready:
            let url = Self.url(for: resolvers[name]?.currentPath?.remoteEndpoint)
            resolvers[name]?.cancel()
            resolved(name: name, url: url)
        case .failed:
            resolvers[name]?.cancel()
            resolutionFailed(name: name)
        default:
            break
        }
    }

    private func resolved(name: String, url: URL?) {
        resolvers[name] = nil
        guard var service = services[name] else { return }
        // A failed re-resolution keeps the address that last worked.
        service.url = url ?? service.url
        service.stale = false
        services[name] = service
        publish()
    }

    private func resolutionFailed(name: String) {
        resolvers[name] = nil
        // Retry later; the service may simply not be answering yet.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.stopped, self.resolveAddresses,
                  let service = self.services[name], service.url == nil || service.stale,
                  self.resolvers[name] == nil
            else { return }
            self.resolve(service)
        }
    }

    private static func url(for endpoint: NWEndpoint?) -> URL? {
        guard case let .hostPort(host, port)? = endpoint else { return nil }
        let hostText: String
        switch host {
        case let .ipv4(address):
            hostText = address.rawValue.map { String($0) }.joined(separator: ".")
        case let .name(name, _):
            hostText = name
        default:
            // Link-local IPv6 is unusable without its zone, and a global one
            // is not what a LAN hub advertises.
            return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = hostText
        components.port = Int(port.rawValue)
        return components.url
    }

    // MARK: Path (on queue)

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let signature = HubPathRevisionTracker.signature(
                interfaces: path.availableInterfaces.map { "\($0.type)/\($0.name)" },
                gateways: path.gateways.map { String(reflecting: $0) }
            )
            self?.pathChanged(satisfied: satisfied, signature: signature)
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    private func pathChanged(satisfied: Bool, signature: Set<String>) {
        let moved = pathTracker.observe(signature)
        if moved {
            // The hub's address may differ on the new network.
            for name in services.keys {
                services[name]?.stale = true
            }
            if resolveAddresses {
                for service in services.values where resolvers[service.name] == nil {
                    resolve(service)
                }
            }
        }
        guard satisfied != pathSatisfied || moved else { return }
        pathSatisfied = satisfied
        publish()
    }

    // MARK: Publishing (on queue)

    private func publish() {
        guard !stopped else { return }
        let hubs = services.values
            .map { DiscoveredHub(name: $0.name, hubID: $0.hubID, url: $0.url) }
            .sorted { $0.name < $1.name }
        let state = HubNetworkState(
            discovered: hubs,
            pathSatisfied: pathSatisfied,
            scanCompleted: scanCompleted,
            pathRevision: pathTracker.revision,
            discoveryProblem: discoveryProblem
        )
        guard state != lastPublished else { return }
        lastPublished = state
        continuation.yield(state)
    }
}
