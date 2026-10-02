import XCTest

@testable import SolisHubKit

/// A socket whose inbound frames the test scripts, and which records what the
/// client sends. `close()` ends the stream the way a real socket would.
final class FakeSocket: HubSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sentFrames: [String] = []
    private var closed = false
    private let continuation: AsyncStream<String>.Continuation
    private var iterator: AsyncStream<String>.AsyncIterator

    init(frames: [String], endsAfterFrames: Bool) {
        var captured: AsyncStream<String>.Continuation?
        let stream = AsyncStream<String> { captured = $0 }
        continuation = captured!
        iterator = stream.makeAsyncIterator()
        for frame in frames {
            continuation.yield(frame)
        }
        if endsAfterFrames {
            continuation.finish()
        }
    }

    var sent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sentFrames
    }

    func push(_ frame: String) {
        continuation.yield(frame)
    }

    func send(_ text: String) async throws {
        lock.withLock { sentFrames.append(text) }
    }

    func receive() async throws -> String {
        if let frame = await iterator.next() {
            return frame
        }
        throw HubTransportError.closed(code: 1000, reason: nil)
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        continuation.finish()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

/// Each `open` takes the next scripted step; once the script runs out every
/// further attempt fails, so a test can never connect by accident.
final class ScriptedTransport: HubTransport, @unchecked Sendable {
    enum Step {
        case fail(HubTransportError)
        case socket(FakeSocket)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var opened: [HubEndpoint] = []
    private var openedHeaders: [[String: String]] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var attempts: [HubEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    var headers: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return openedHeaders
    }

    func open(_ endpoint: HubEndpoint, headers: [String: String]) async throws -> any HubSocket {
        let step: Step = lock.withLock {
            opened.append(endpoint)
            openedHeaders.append(headers)
            return steps.isEmpty ? .fail(.connectionFailed("script exhausted")) : steps.removeFirst()
        }
        switch step {
        case let .fail(error): throw error
        case let .socket(socket): return socket
        }
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []
    private let target: Int
    let reached: XCTestExpectation

    init(target: Int, expectation: XCTestExpectation) {
        self.target = target
        reached = expectation
    }

    var recorded: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }

    func record(_ delay: TimeInterval) async throws {
        let count: Int = lock.withLock {
            delays.append(delay)
            return delays.count
        }
        if count == target {
            reached.fulfill()
        }
        // Long enough for other tasks to run, short enough to be invisible.
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// Consumes a client's event stream for the whole test. A stream can be
/// iterated once: leaving a `for await` early ends it for good, so the tests
/// share one reader and poll what it has seen.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HubEvent] = []
    private var task: Task<Void, Never>?

    init(_ client: HubClient) {
        let stream = client.events
        task = Task { [self] in
            for await event in stream {
                append(event)
            }
        }
    }

    private func append(_ event: HubEvent) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var events: [HubEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    /// True once an event matching `predicate` has been seen.
    func wait(timeout: TimeInterval = 5, for predicate: (HubEvent) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events.contains(where: predicate) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

final class HubClientTests: XCTestCase {
    private let lan = HubEndpoint(kind: .lan, baseURL: URL(string: "http://10.0.0.5:8765")!)
    private let remote = HubEndpoint(kind: .remote, baseURL: URL(string: "https://energy.example.com")!)
    private let auth = HubAuth(token: "token", cloudflareClientID: "id", cloudflareClientSecret: "secret")

    private func isHello(_ event: HubEvent) -> Bool {
        if case .hello = event { return true }
        return false
    }

    private func isDisconnect(_ event: HubEvent) -> Bool {
        if case .disconnected = event { return true }
        return false
    }

    // MARK: Reconnect and backoff

    func testBackoffGrowsThenResetsAfterAHandshake() async throws {
        let expectation = expectation(description: "five backoff pauses")
        let recorder = SleepRecorder(target: 5, expectation: expectation)
        let healthy = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: true)
        let transport = ScriptedTransport([
            .fail(.connectionFailed("down")),
            .fail(.connectionFailed("down")),
            .fail(.connectionFailed("down")),
            .socket(healthy),
        ])
        let client = HubClient(
            endpoints: [lan],
            auth: auth,
            transport: transport,
            // A connection that drops at once would not normally count as
            // stable; zero makes the handshake alone enough to reset.
            configuration: HubClientConfiguration(stableAfter: 0),
            sleep: { try await recorder.record($0) },
            jitter: { 0 }
        )
        await client.start()
        await fulfillment(of: [expectation], timeout: 5)
        await client.stop()

        // Three failures climb 1, 2, 4. The handshake that follows resets the
        // schedule, so the next pause is 1 again, and the failure after it 2.
        XCTAssertEqual(Array(recorder.recorded.prefix(5)), [1, 2, 4, 1, 2])
        XCTAssertGreaterThanOrEqual(transport.attempts.count, 5)
    }

    func testRepeatedFailuresStopAtThirtySeconds() async throws {
        let expectation = expectation(description: "eight pauses")
        let recorder = SleepRecorder(target: 8, expectation: expectation)
        let client = HubClient(
            endpoints: [lan],
            auth: auth,
            transport: ScriptedTransport([]),
            sleep: { try await recorder.record($0) },
            jitter: { 0 }
        )
        await client.start()
        await fulfillment(of: [expectation], timeout: 5)
        await client.stop()
        XCTAssertEqual(Array(recorder.recorded.prefix(8)), [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testTheLanIsTriedFirstThenTheRemoteURL() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let transport = ScriptedTransport([.fail(.timedOut), .socket(socket)])
        let client = HubClient(
            endpoints: [lan, remote],
            auth: auth,
            transport: transport,
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        let seen = await log.wait(for: isHello)
        await client.stop()

        XCTAssertTrue(seen)
        XCTAssertEqual(transport.attempts, [lan, remote])
        let connected = log.events.compactMap { event -> HubEndpoint? in
            if case let .connected(endpoint) = event { return endpoint }
            return nil
        }
        XCTAssertEqual(connected, [remote])
    }

    /// The LAN is plain http and does not pass through Cloudflare, so only the
    /// remote attempt carries the Access pair; the bearer token goes to both.
    func testCloudflareHeadersGoToRemoteOnly() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let transport = ScriptedTransport([.fail(.timedOut), .socket(socket)])
        let client = HubClient(
            endpoints: [lan, remote],
            auth: auth,
            transport: transport,
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        let seen = await log.wait(for: isHello)
        await client.stop()
        XCTAssertTrue(seen)

        XCTAssertEqual(transport.attempts, [lan, remote])
        let lanHeaders = try XCTUnwrap(transport.headers.first)
        XCTAssertEqual(lanHeaders["Authorization"], "Bearer token")
        XCTAssertNil(lanHeaders["CF-Access-Client-Id"])
        XCTAssertNil(lanHeaders["CF-Access-Client-Secret"])
        let remoteHeaders = try XCTUnwrap(transport.headers.last)
        XCTAssertEqual(remoteHeaders["Authorization"], "Bearer token")
        XCTAssertEqual(remoteHeaders["CF-Access-Client-Id"], "id")
        XCTAssertEqual(remoteHeaders["CF-Access-Client-Secret"], "secret")
    }

    /// A handshake that is followed by an instant drop is not a healthy
    /// connection, so the schedule keeps climbing instead of retrying every
    /// second for ever.
    func testInstantlyClosingConnectionDoesNotResetBackoff() async throws {
        let expectation = expectation(description: "four backoff pauses")
        let recorder = SleepRecorder(target: 4, expectation: expectation)
        let sockets = (0..<6).map { _ in FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: true) }
        let transport = ScriptedTransport(sockets.map { ScriptedTransport.Step.socket($0) })
        let client = HubClient(
            endpoints: [lan],
            auth: auth,
            transport: transport,
            sleep: { try await recorder.record($0) },
            jitter: { 0 }
        )
        await client.start()
        await fulfillment(of: [expectation], timeout: 5)
        await client.stop()
        XCTAssertEqual(Array(recorder.recorded.prefix(4)), [1, 2, 4, 8])
    }

    func testUpdateEndpointsWakesABackoffPauseImmediately() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let client = HubClient(
            endpoints: [],
            auth: auth,
            transport: ScriptedTransport([.socket(socket)]),
            // Far longer than the test: only a wake-up can end this pause.
            sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        let paused = await log.wait { event in
            if case .disconnected(.noEndpoint) = event { return true }
            return false
        }
        XCTAssertTrue(paused)

        let started = Date()
        await client.updateEndpoints([lan])
        let connected = await log.wait(timeout: 4, for: isHello)
        await client.stop()
        XCTAssertTrue(connected)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testNetworkPathChangedReconnectsAndResetsBackoff() async throws {
        let expectation = expectation(description: "three backoff pauses")
        let recorder = SleepRecorder(target: 3, expectation: expectation)
        let first = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let second = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let transport = ScriptedTransport([
            .fail(.connectionFailed("down")),
            .fail(.connectionFailed("down")),
            .socket(first),
            .socket(second),
        ])
        let client = HubClient(
            endpoints: [lan],
            auth: auth,
            transport: transport,
            sleep: { try await recorder.record($0) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        let connected = await log.wait(for: isHello)
        XCTAssertTrue(connected)

        await client.networkPathChanged()
        await fulfillment(of: [expectation], timeout: 5)
        for _ in 0..<500 where log.events.filter(isHello).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await client.stop()

        // Two failures climb 1, 2. The path change drops the connection and
        // starts the schedule over, so the next pause is 1, not 4.
        XCTAssertEqual(Array(recorder.recorded.prefix(3)), [1, 2, 1])
        XCTAssertTrue(first.isClosed)
        XCTAssertEqual(log.events.filter(isHello).count, 2)
        XCTAssertTrue(
            log.events.contains { event in
                if case .disconnected(.endpointChanged) = event { return true }
                return false
            }
        )
    }

    func testStartAfterStopDoesNothing() async throws {
        // A second socket is scripted so a start that wrongly took effect
        // would connect to it.
        let first = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let second = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let transport = ScriptedTransport([.socket(first), .socket(second)])
        let client = HubClient(endpoints: [lan], auth: auth, transport: transport)
        let log = EventLog(client)
        await client.start()
        let seen = await log.wait(for: isHello)
        XCTAssertTrue(seen)
        await client.stop()
        XCTAssertEqual(transport.attempts.count, 1)

        // A stopped client is finished for good: this must not start a loop
        // that nothing could ever stop.
        await client.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.attempts.count, 1)
    }

    // MARK: Liveness and timeouts

    func testLanConnectTimeoutFallsThroughToTheRemote() async throws {
        let silentLan = FakeSocket(frames: [], endsAfterFrames: false)
        let remoteSocket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let transport = ScriptedTransport([.socket(silentLan), .socket(remoteSocket)])
        let client = HubClient(
            endpoints: [lan, remote],
            auth: auth,
            transport: transport,
            configuration: HubClientConfiguration(lanConnectTimeout: 0.05),
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        let seen = await log.wait(for: isHello)
        await client.stop()

        XCTAssertTrue(seen)
        XCTAssertEqual(transport.attempts, [lan, remote])
        XCTAssertTrue(silentLan.isClosed)
        let connected = log.events.compactMap { event -> HubEndpoint? in
            if case let .connected(endpoint) = event { return endpoint }
            return nil
        }
        XCTAssertEqual(connected, [remote])
    }

    private let fastLiveness = HubClientConfiguration(pingInterval: 0.05, livenessTimeout: 0.5)

    func testSilentConnectionTimesOut() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let client = HubClient(
            endpoints: [lan],
            auth: auth,
            transport: ScriptedTransport([.socket(socket)]),
            configuration: fastLiveness,
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        let timedOut = await log.wait { event in
            if case .disconnected(.timedOut) = event { return true }
            return false
        }
        await client.stop()

        XCTAssertTrue(timedOut)
        XCTAssertTrue(socket.isClosed)
        XCTAssertTrue(socket.sent.contains { $0.contains("ping") })
    }

    func testPongKeepsItAlive() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let client = HubClient(
            endpoints: [lan],
            auth: auth,
            transport: ScriptedTransport([.socket(socket)]),
            configuration: fastLiveness,
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        let connected = await log.wait(for: isHello)
        XCTAssertTrue(connected)

        // Three times the liveness timeout, with traffic throughout.
        for _ in 0..<30 {
            socket.push("{\"type\":\"pong\",\"nonce\":\"1\"}")
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let dropped = log.events.contains(where: isDisconnect)
        await client.stop()

        XCTAssertFalse(dropped)
    }

    // MARK: Events

    func testSnapshotsSamplesAndStatusesAreForwarded() async throws {
        let frames = [
            Fixtures.hello(),
            Fixtures.snapshot(envelope: nil),
            Fixtures.sample(envelope: Fixtures.envelope(successfulPolls: 4)),
            "{\"type\":\"poller_status\",\"state\":\"backoff\",\"since\":null,\"restarts\":1,"
                + "\"last_exit_code\":1,\"next_attempt_at\":null}",
            "this is not json",
            "{\"type\":\"pong\",\"nonce\":\"1\"}",
        ]
        let socket = FakeSocket(frames: frames, endsAfterFrames: false)
        let client = HubClient(endpoints: [lan], auth: auth, transport: ScriptedTransport([.socket(socket)]))
        let log = EventLog(client)
        await client.start()
        let seen = await log.wait { event in
            if case .pollerStatus = event { return true }
            return false
        }
        await client.stop()
        XCTAssertTrue(seen)

        var sawEmptySnapshot = false
        var polls: Int?
        var state: String?
        for event in log.events {
            switch event {
            case let .snapshot(snapshot): sawEmptySnapshot = snapshot.envelope == nil
            case let .sample(envelope): polls = envelope.health.successfulPolls
            case let .pollerStatus(status): state = status.state
            default: break
            }
        }
        XCTAssertTrue(sawEmptySnapshot)
        XCTAssertEqual(polls, 4)
        XCTAssertEqual(state, "backoff")
    }

    func testAnIncompatibleHubIsReportedAndNotHammered() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello(protocolVersion: 9)], endsAfterFrames: false)
        let expectation = expectation(description: "paused")
        let recorder = SleepRecorder(target: 1, expectation: expectation)
        let client = HubClient(
            endpoints: [lan],
            auth: auth,
            transport: ScriptedTransport([.socket(socket)]),
            sleep: { try await recorder.record($0) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        await fulfillment(of: [expectation], timeout: 5)
        await client.stop()

        let reasons = log.events.compactMap { event -> HubDisconnectReason? in
            if case let .disconnected(reason) = event { return reason }
            return nil
        }
        guard case .incompatible? = reasons.first else {
            return XCTFail("expected an incompatible disconnect, got \(reasons)")
        }
        XCTAssertEqual(recorder.recorded.first, 30)
        XCTAssertTrue(socket.isClosed)
    }

    func testABadTokenIsReportedAsUnauthorised() async throws {
        let client = HubClient(
            endpoints: [lan],
            auth: auth,
            transport: ScriptedTransport([.fail(.httpStatus(401))]),
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        let seen = await log.wait(for: isDisconnect)
        await client.stop()
        XCTAssertTrue(seen)
        let reasons = log.events.compactMap { event -> HubDisconnectReason? in
            if case let .disconnected(reason) = event { return reason }
            return nil
        }
        XCTAssertEqual(reasons.first, .unauthorised)
    }

    // MARK: Attention

    func testAttentionSetBeforeConnectingIsSentAfterTheHello() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let client = HubClient(endpoints: [lan], auth: auth, transport: ScriptedTransport([.socket(socket)]))
        let log = EventLog(client)
        client.setAttention(true)
        // Let the relayed call land before there is a connection to race it.
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.start()
        let seen = await log.wait(for: isHello)
        XCTAssertTrue(seen)
        for _ in 0..<100 where !socket.sent.contains("{\"type\":\"attention\",\"on\":true}") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await client.stop()
        XCTAssertEqual(socket.sent.filter { $0.contains("attention") }, ["{\"type\":\"attention\",\"on\":true}"])
    }

    func testAttentionChangesWhileConnectedArriveInOrder() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let client = HubClient(endpoints: [lan], auth: auth, transport: ScriptedTransport([.socket(socket)]))
        let log = EventLog(client)
        await client.start()
        let seen = await log.wait(for: isHello)
        XCTAssertTrue(seen)
        client.setAttention(true)
        client.setAttention(false)
        client.setAttention(true)
        for _ in 0..<100 where socket.sent.filter({ $0.contains("attention") }).count < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await client.stop()
        XCTAssertEqual(
            socket.sent.filter { $0.contains("attention") },
            [
                "{\"type\":\"attention\",\"on\":true}",
                "{\"type\":\"attention\",\"on\":false}",
                "{\"type\":\"attention\",\"on\":true}",
            ]
        )
    }

    func testAttentionResentAfterReconnect() async throws {
        // The first connection ends straight after its hello.
        let first = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: true)
        let second = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let client = HubClient(
            endpoints: [lan],
            auth: auth,
            transport: ScriptedTransport([.socket(first), .socket(second)]),
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        client.setAttention(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.start()
        let attention = "{\"type\":\"attention\",\"on\":true}"
        for _ in 0..<300 where !second.sent.contains(attention) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await client.stop()

        XCTAssertEqual(first.sent.filter { $0 == attention }.count, 1)
        XCTAssertEqual(second.sent.filter { $0 == attention }.count, 1)
        XCTAssertEqual(log.events.filter(isHello).count, 2)
    }

    // MARK: Moving between endpoints

    func testANewLanEndpointMovesAConnectionOffTheTunnel() async throws {
        let onTunnel = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let onLan = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let transport = ScriptedTransport([.socket(onTunnel), .socket(onLan)])
        let client = HubClient(
            endpoints: [remote],
            auth: auth,
            transport: transport,
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            jitter: { 0 }
        )
        let log = EventLog(client)
        await client.start()
        let first = await log.wait(for: isHello)
        XCTAssertTrue(first)
        await client.updateEndpoints([lan, remote])
        let moved = await log.wait { event in
            if case let .connected(endpoint) = event { return endpoint.kind == .lan }
            return false
        }
        await client.stop()

        XCTAssertTrue(moved)
        XCTAssertEqual(transport.attempts, [remote, lan])
        XCTAssertTrue(onTunnel.isClosed)
        XCTAssertTrue(
            log.events.contains { event in
                if case .disconnected(.endpointChanged) = event { return true }
                return false
            }
        )
    }
}
