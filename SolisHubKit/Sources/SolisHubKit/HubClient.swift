import Foundation

public enum HubEvent: Sendable {
    /// The hub answered the handshake at this endpoint; `hello` follows.
    case connected(HubEndpoint)
    case hello(HubHello)
    /// The hub's merged state. Always follows a connect, and follows any
    /// poller restart or lag overflow on the hub.
    case snapshot(HubSnapshot)
    /// One envelope exactly as the poller sent it, so fields it sends only
    /// sometimes are still absent; see StreamStateMerger.
    case sample(StreamEnvelope)
    case pollerStatus(HubPollerStatus)
    case disconnected(HubDisconnectReason)
}

public enum HubDisconnectReason: Sendable, Equatable {
    case stopped
    /// Nothing to try: offline, or no address configured.
    case noEndpoint
    case unreachable(String)
    case unauthorised
    case rateLimited
    case closed(code: Int, reason: String?)
    /// Nothing arrived, not even a pong, for the liveness timeout.
    case timedOut
    case serverError(code: String, message: String)
    /// The hub speaks a protocol or stream schema this build does not.
    /// Retrying will not help until one side is upgraded.
    case incompatible(String)
    /// The network changed and a better endpoint is being tried.
    case endpointChanged

    /// A sentence for the UI. Never contains a credential.
    public var summary: String {
        switch self {
        case .stopped: "Stopped"
        case .noEndpoint: "No hub address to try; the network may be offline"
        case let .unreachable(detail): "Hub unreachable (\(detail))"
        case .unauthorised: "The hub rejected the access token or Cloudflare Access credentials"
        case .rateLimited: "The hub is rate limiting this client; retrying"
        case .closed: "The hub closed the connection"
        case .timedOut: "The hub stopped responding"
        case let .serverError(_, message): "The hub reported: \(message)"
        case let .incompatible(detail): detail
        case .endpointChanged: "Network changed; reconnecting"
        }
    }

    /// Reasons that will not clear by retrying, so a better reason from a
    /// later endpoint must not hide them.
    var isDefinitive: Bool {
        switch self {
        case .unauthorised, .incompatible: true
        default: false
        }
    }
}

public struct HubClientConfiguration: Sendable, Equatable {
    public var backoff: HubBackoff
    /// How long a LAN endpoint gets to produce a hello before the remote URL
    /// is tried. Short, because most of the time the LAN is simply not there.
    public var lanConnectTimeout: TimeInterval
    public var remoteConnectTimeout: TimeInterval
    public var pingInterval: TimeInterval
    /// Silence of this length drops the connection. The hub pings the
    /// protocol layer itself, but a phone's radio can stall without the
    /// socket noticing, so liveness is also checked at the application level.
    public var livenessTimeout: TimeInterval
    /// How long a connection must stay up before the backoff schedule starts
    /// again from the beginning. A handshake alone proves nothing: a hub that
    /// accepts and immediately drops would otherwise be retried every second.
    public var stableAfter: TimeInterval

    public init(
        backoff: HubBackoff = HubBackoff(),
        lanConnectTimeout: TimeInterval = 2,
        remoteConnectTimeout: TimeInterval = 10,
        pingInterval: TimeInterval = 15,
        livenessTimeout: TimeInterval = 40,
        stableAfter: TimeInterval = 10
    ) {
        self.backoff = backoff
        self.lanConnectTimeout = lanConnectTimeout
        self.remoteConnectTimeout = remoteConnectTimeout
        self.pingInterval = pingInterval
        self.livenessTimeout = livenessTimeout
        self.stableAfter = stableAfter
    }

    func connectTimeout(for kind: HubEndpointKind) -> TimeInterval {
        switch kind {
        case .lan: lanConnectTimeout
        case .remote: remoteConnectTimeout
        }
    }
}

/// Runs submitted work one after another, in submission order, from a
/// synchronous call site. Used so two quick attention changes cannot be
/// applied out of order.
final class SerialRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func submit(_ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }
}

/// The live connection to one hub: it picks an endpoint, reconnects with
/// jittered backoff, checks liveness and reports everything as events.
///
/// It never talks to the inverter and has no way to change a setting; the
/// only thing it can say to the hub is whether anyone is looking.
public actor HubClient {
    /// Single consumer. The stream finishes when `stop()` is called.
    public nonisolated let events: AsyncStream<HubEvent>

    private let continuation: AsyncStream<HubEvent>.Continuation
    private let transport: any HubTransport
    private let auth: HubAuth
    private let configuration: HubClientConfiguration
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let attentionRelay = SerialRelay()

    private var endpoints: [HubEndpoint]
    private var endpointGeneration = 0
    private var attention = false
    private var runTask: Task<Void, Never>?
    private var isStopped = false
    private var pauseTask: Task<Void, Never>?
    private var socket: (any HubSocket)?
    private var connectedEndpoint: HubEndpoint?
    private var lastInbound = Date()
    private var lastServerError: HubErrorMessage?
    private var lastReported: HubDisconnectReason?
    private var endpointChangeRequested = false
    private var backoffResetRequested = false

    /// `sleep` and `jitter` exist so tests can run the backoff schedule
    /// without waiting for it.
    public init(
        endpoints: [HubEndpoint] = [],
        auth: HubAuth,
        transport: any HubTransport = URLSessionHubTransport(),
        configuration: HubClientConfiguration = HubClientConfiguration(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        var captured: AsyncStream<HubEvent>.Continuation?
        events = AsyncStream<HubEvent> { captured = $0 }
        // The build closure ran synchronously above.
        continuation = captured!
        self.endpoints = endpoints
        self.auth = auth
        self.transport = transport
        self.configuration = configuration
        self.sleep = sleep
        self.jitter = jitter
    }

    public func start() {
        // Without this a start after a stop would run a loop whose event
        // stream has already finished, and nothing could ever stop it.
        guard !isStopped, runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    /// Closes the socket and ends the event stream. Returns once the run loop
    /// has finished, so nothing is still connected afterwards. A stopped client
    /// is finished for good: make a new one to connect again.
    public func stop() async {
        // First, so a start() that lands while this awaits is refused.
        isStopped = true
        let task = runTask
        runTask = nil
        task?.cancel()
        pauseTask?.cancel()
        socket?.close()
        await task?.value
        continuation.finish()
    }

    /// Replaces the addresses to try. A connection that is still the best
    /// choice is left alone; otherwise it is dropped and the new list is used
    /// at once, without waiting out a backoff.
    public func updateEndpoints(_ new: [HubEndpoint]) {
        guard new != endpoints else { return }
        endpoints = new
        endpointGeneration += 1
        guard runTask != nil else { return }
        if HubReconnectPolicy.shouldReconnect(current: connectedEndpoint, candidates: new) {
            backoffResetRequested = true
            if connectedEndpoint != nil {
                endpointChangeRequested = true
            }
            // Also aborts a handshake that is still in flight to a stale endpoint.
            socket?.close()
            pauseTask?.cancel()
        }
    }

    /// The device's network changed (Wi-Fi swapped, an interface came or went)
    /// without any address list changing. The current connection is dropped
    /// and the backoff starts over, so the LAN is tried first again from
    /// wherever the Mac now is.
    public func networkPathChanged() {
        guard runTask != nil else { return }
        backoffResetRequested = true
        if connectedEndpoint != nil {
            endpointChangeRequested = true
        }
        socket?.close()
        pauseTask?.cancel()
    }

    /// Tell the hub whether anyone is looking, so the poller can slow down
    /// while nobody is. Callable from any context, and calls are applied in
    /// order. Sent again after every reconnect.
    public nonisolated func setAttention(_ on: Bool) {
        attentionRelay.submit { [self] in
            await self.applyAttention(on)
        }
    }

    // MARK: Run loop

    private struct Outcome {
        var reason: HubDisconnectReason
        var completedHandshake: Bool
        /// How long the connection stayed up after its hello; zero when it
        /// never got that far.
        var connectedFor: TimeInterval = 0
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let outcome = await connectOnce()
            if Task.isCancelled { return }
            if lastReported != outcome.reason {
                lastReported = outcome.reason
                continuation.yield(.disconnected(outcome.reason))
            }
            let wasStable = outcome.completedHandshake
                && outcome.connectedFor >= configuration.stableAfter
            if wasStable || backoffResetRequested {
                attempt = 0
                backoffResetRequested = false
            }
            let delay: TimeInterval
            switch outcome.reason {
            case .incompatible, .noEndpoint:
                // Nothing to retry until an upgrade or a new address, and
                // updateEndpoints wakes this pause for the latter.
                delay = configuration.backoff.maximum
            default:
                delay = configuration.backoff.delay(attempt: attempt, jitter: jitter())
            }
            attempt += 1
            await pause(delay)
        }
    }

    private func pause(_ delay: TimeInterval) async {
        let sleep = self.sleep
        let task = Task { () -> Void in
            _ = try? await sleep(delay)
        }
        pauseTask = task
        await task.value
        pauseTask = nil
    }

    private func connectOnce() async -> Outcome {
        let candidates = endpoints
        let generation = endpointGeneration
        guard !candidates.isEmpty else {
            return Outcome(reason: .noEndpoint, completedHandshake: false)
        }
        var failure = HubDisconnectReason.unreachable("no endpoint answered")
        for endpoint in candidates {
            if Task.isCancelled || generation != endpointGeneration { break }
            let result = await attempt(endpoint)
            if result.completedHandshake { return result }
            // A definitive failure (a bad token) is more useful to report
            // than a later endpoint merely being unreachable.
            if !failure.isDefinitive || result.reason.isDefinitive {
                failure = result.reason
            }
        }
        return Outcome(reason: failure, completedHandshake: false)
    }

    private func attempt(_ endpoint: HubEndpoint) async -> Outcome {
        let opened: any HubSocket
        do {
            opened = try await transport.open(endpoint, headers: auth.headers(for: endpoint.kind))
        } catch {
            return Outcome(reason: Self.reason(for: error), completedHandshake: false)
        }
        socket = opened
        defer {
            socket = nil
            opened.close()
        }
        if Task.isCancelled {
            return Outcome(reason: .stopped, completedHandshake: false)
        }

        let first: String
        do {
            first = try await Self.receive(
                from: opened, timeout: configuration.connectTimeout(for: endpoint.kind)
            )
        } catch {
            return Outcome(reason: Self.reason(for: error), completedHandshake: false)
        }
        guard case let .hello(hello)? = try? HubServerMessage.decode(first) else {
            return Outcome(
                reason: .incompatible("The hub did not start with a hello message"),
                completedHandshake: false
            )
        }
        guard hello.hubProtocolVersion == HubProtocol.version else {
            return Outcome(
                reason: .incompatible(
                    "The hub speaks protocol \(hello.hubProtocolVersion) but this app speaks "
                        + "\(HubProtocol.version). Upgrade the older side."
                ),
                completedHandshake: false
            )
        }
        guard hello.streamSchemaVersion == StreamDecoder.supportedSchemaVersion else {
            return Outcome(
                reason: .incompatible(
                    "The hub forwards stream schema \(hello.streamSchemaVersion) but this app reads "
                        + "schema \(StreamDecoder.supportedSchemaVersion). Upgrade the older side."
                ),
                completedHandshake: false
            )
        }

        connectedEndpoint = endpoint
        let connectedAt = Date()
        lastInbound = connectedAt
        lastServerError = nil
        lastReported = nil
        endpointChangeRequested = false
        continuation.yield(.connected(endpoint))
        continuation.yield(.hello(hello))
        // A new connection starts with attention off on the hub's side.
        if attention {
            try? await opened.send(HubClientMessage.attention(true).text)
        }
        var reason = await serve(opened)
        connectedEndpoint = nil
        if endpointChangeRequested {
            reason = .endpointChanged
        } else if let error = lastServerError {
            reason = .serverError(code: error.code, message: error.message)
        }
        return Outcome(
            reason: reason,
            completedHandshake: true,
            connectedFor: Date().timeIntervalSince(connectedAt)
        )
    }

    /// Reads until the socket ends, while checking that it is still alive.
    /// Whichever finishes first decides the reason; closing the socket is
    /// what unblocks the other.
    private func serve(_ socket: any HubSocket) async -> HubDisconnectReason {
        let settings = configuration
        return await withTaskGroup(of: HubDisconnectReason.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    let text: String
                    do {
                        text = try await socket.receive()
                    } catch {
                        return Self.reason(for: error)
                    }
                    let message: HubServerMessage
                    do {
                        message = try HubServerMessage.decode(text)
                    } catch HubMessageError.unsupportedStreamSchema(let version) {
                        return .incompatible(
                            "The hub forwarded stream schema \(version) but this app reads schema "
                                + "\(StreamDecoder.supportedSchemaVersion). Upgrade the older side."
                        )
                    } catch {
                        // One undecodable message is not a dead connection.
                        continue
                    }
                    await self.deliver(message)
                }
                return .stopped
            }
            group.addTask {
                var counter = 0
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(settings.pingInterval * 1_000_000_000))
                    } catch {
                        return .stopped
                    }
                    if await self.secondsSinceInbound() > settings.livenessTimeout {
                        return .timedOut
                    }
                    counter += 1
                    try? await socket.send(HubClientMessage.ping(nonce: counter).text)
                }
                return .stopped
            }
            let first = await group.next() ?? .stopped
            socket.close()
            group.cancelAll()
            while await group.next() != nil {}
            return first
        }
    }

    private func deliver(_ message: HubServerMessage) {
        lastInbound = Date()
        switch message {
        case .hello, .pong, .unknown:
            break
        case let .snapshot(snapshot):
            continuation.yield(.snapshot(snapshot))
        case let .sample(envelope):
            continuation.yield(.sample(envelope))
        case let .pollerStatus(status):
            continuation.yield(.pollerStatus(status))
        case let .error(error):
            // A policy close follows; the reason is reported with it.
            lastServerError = error
        }
    }

    private func secondsSinceInbound() -> TimeInterval {
        Date().timeIntervalSince(lastInbound)
    }

    private func applyAttention(_ on: Bool) async {
        attention = on
        guard connectedEndpoint != nil, let socket else { return }
        try? await socket.send(HubClientMessage.attention(on).text)
    }

    // MARK: Helpers

    /// The first message with a deadline. The socket is closed on timeout
    /// because a pending receive cannot be cancelled any other way.
    private static func receive(from socket: any HubSocket, timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                socket.close()
                throw HubTransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw HubTransportError.timedOut }
            return first
        }
    }

    private static func reason(for error: Error) -> HubDisconnectReason {
        if error is CancellationError { return .stopped }
        guard let transport = error as? HubTransportError else {
            return .unreachable(error.localizedDescription)
        }
        switch transport {
        case .httpStatus(401), .httpStatus(403):
            return .unauthorised
        case .httpStatus(429):
            return .rateLimited
        case let .httpStatus(code):
            return .unreachable("HTTP \(code)")
        case let .closed(code, reason):
            return .closed(code: code, reason: reason)
        case .timedOut:
            return .unreachable("timed out")
        case let .connectionFailed(detail):
            return .unreachable(detail)
        case .unexpectedFrame:
            return .incompatible("The hub sent a frame this app cannot read")
        }
    }
}
