import XCTest

import SolisHubKit

@testable import SolisMenuBar

/// The single-controller rules. The logger takes one Modbus session, so these
/// are the tests that matter most: at no point may a local poller and a hub
/// both be allowed to run.
final class ConnectionPolicyTests: XCTestCase {
    private let hub = DetectedHub(id: "hub-1", name: "solis-hub")

    func testDirectModeRunsTheLocalPollerWhenNoHubIsAdvertised() {
        let policy = ConnectionPolicy(mode: .direct)
        XCTAssertEqual(policy.plan, .localPoller)
        XCTAssertTrue(policy.localPollerMayStart)
    }

    func testHubModeNeverAllowsALocalPollerWhateverElseIsTrue() {
        let situations: [(detected: [DetectedHub], ignored: Set<String>)] = [
            ([], []),
            ([hub], []),
            ([hub], ["hub-1"]),
            ([], ["hub-1"]),
        ]
        for situation in situations {
            var policy = ConnectionPolicy(mode: .hub, ignoredHubIDs: situation.ignored)
            policy.updateDetectedHubs(situation.detected)
            XCTAssertEqual(policy.plan, .hub)
            XCTAssertFalse(policy.localPollerMayStart)
            // An unreachable hub changes nothing: there is no fallback.
            XCTAssertEqual(policy.planAfterHubFailure(), .hub)
            XCTAssertFalse(policy.localPollerMayStart)
        }
    }

    func testADetectedHubHoldsTheLocalPollerUntilTheUserDecides() {
        var policy = ConnectionPolicy(mode: .direct)
        policy.updateDetectedHubs([hub])
        XCTAssertEqual(policy.plan, .heldForHubDecision([hub]))
        XCTAssertFalse(policy.localPollerMayStart)

        policy.ignore(hubID: "some-other-hub")
        XCTAssertFalse(policy.localPollerMayStart)

        policy.ignore(hubID: "hub-1")
        XCTAssertTrue(policy.localPollerMayStart)
    }

    func testTheHubGoingAwayAlsoFreesTheGuard() {
        var policy = ConnectionPolicy(mode: .direct)
        policy.updateDetectedHubs([hub])
        XCTAssertFalse(policy.localPollerMayStart)
        policy.updateDetectedHubs([])
        XCTAssertTrue(policy.localPollerMayStart)
    }

    func testStoppingIgnoringRestoresTheGuard() {
        var policy = ConnectionPolicy(mode: .direct, ignoredHubIDs: ["hub-1"])
        policy.updateDetectedHubs([hub])
        XCTAssertTrue(policy.localPollerMayStart)
        policy.stopIgnoring(hubID: "hub-1")
        XCTAssertFalse(policy.localPollerMayStart)
    }

    func testSwitchToHubChangesTheModeAndNothingElse() {
        var policy = ConnectionPolicy(mode: .direct)
        policy.updateDetectedHubs([hub])
        policy.chooseHub()
        XCTAssertEqual(policy.mode, .hub)
        XCTAssertEqual(policy.plan, .hub)
    }

    func testHubToDirectNeedsAnExplicitConfirmation() {
        var policy = ConnectionPolicy(mode: .hub)
        policy.updateDetectedHubs([hub])
        XCTAssertFalse(policy.switchToDirect(hubServiceConfirmedStopped: false))
        XCTAssertEqual(policy.mode, .hub)
        XCTAssertEqual(policy.plan, .hub)

        XCTAssertTrue(policy.switchToDirect(hubServiceConfirmedStopped: true))
        XCTAssertEqual(policy.mode, .direct)
        // The confirmed hub is still advertised by Avahi, so it is ignored or
        // Direct mode could never start again.
        XCTAssertTrue(policy.localPollerMayStart)
        XCTAssertTrue(policy.ignoredHubIDs.contains("hub-1"))
    }

    func testModeAndIgnoredHubsPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "solis-policy-\(UUID().uuidString)"))
        XCTAssertEqual(ConnectionPolicy.stored(defaults).mode, .direct)

        var policy = ConnectionPolicy.stored(defaults)
        policy.chooseHub()
        policy.ignore(hubID: "hub-1")
        policy.persist(defaults)

        let restored = ConnectionPolicy.stored(defaults)
        XCTAssertEqual(restored.mode, .hub)
        XCTAssertEqual(restored.ignoredHubIDs, ["hub-1"])
    }
}

@MainActor
private final class StubSource: TelemetrySource {
    let events: AsyncStream<TelemetryEvent>
    private let continuation: AsyncStream<TelemetryEvent>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var restorationPending = false

    init() {
        let (stream, continuation) = makeTelemetryStream()
        events = stream
        self.continuation = continuation
    }

    func start() {
        startCount += 1
    }

    func stop() async -> Bool {
        stopCount += 1
        if restorationPending { return false }
        continuation.yield(.status(.stopped))
        continuation.finish()
        return true
    }

    func setAttention(_ visible: Bool) {}

    func emit(_ event: TelemetryEvent) {
        continuation.yield(event)
    }
}

@MainActor
private final class SourceLog {
    private(set) var locals: [StubSource] = []
    private(set) var hubs: [StubSource] = []

    var factory: TelemetrySourceFactory {
        TelemetrySourceFactory(
            makeLocalPoller: { _, _ in
                let source = StubSource()
                self.locals.append(source)
                return source
            },
            makeHub: { _ in
                let source = StubSource()
                self.hubs.append(source)
                return source
            }
        )
    }
}

private final class StubPresence: HubPresenceWatching, @unchecked Sendable {
    let updates: AsyncStream<HubNetworkState>
    private let continuation: AsyncStream<HubNetworkState>.Continuation
    private let hubs: [DiscoveredHub]

    init(hubs: [DiscoveredHub]) {
        self.hubs = hubs
        var captured: AsyncStream<HubNetworkState>.Continuation?
        updates = AsyncStream<HubNetworkState> { captured = $0 }
        continuation = captured!
    }

    func start() {
        continuation.yield(HubNetworkState(discovered: hubs, pathSatisfied: true, scanCompleted: true))
    }

    func stop() {
        continuation.finish()
    }
}

/// The store, with the sources replaced by counters: what matters is which
/// kinds of source it asks for.
@MainActor
final class MonitorStoreModeTests: XCTestCase {
    private let advertised = DiscoveredHub(name: "solis-hub", hubID: "hub-1", url: nil)
    private let hubSettings = HubSourceSettings(
        connection: HubConnectionSettings(remoteURL: URL(string: "https://energy.example.com")),
        auth: HubAuth(token: "token")
    )

    private struct Fixture {
        let store: MonitorStore
        let defaults: UserDefaults
        let log: SourceLog
    }

    private func makeFixture(
        mode: ConnectionMode,
        advertising: [DiscoveredHub] = [],
        hubConfigured: Bool = true
    ) throws -> Fixture {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "solis-store-\(UUID().uuidString)"))
        defaults.set("192.168.1.57", forKey: "host")
        defaults.set(mode.rawValue, forKey: ConnectionMode.defaultsKey)
        let settings: HubSourceSettings? = hubConfigured ? hubSettings : nil
        let log = SourceLog()
        let store = MonitorStore(
            defaults: defaults,
            factory: log.factory,
            makePresence: { StubPresence(hubs: advertising) },
            loadHubSettings: { settings }
        )
        return Fixture(store: store, defaults: defaults, log: log)
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testHubModeNeverConstructsALocalPoller() async throws {
        let fixture = try makeFixture(mode: .hub)
        let configuration = try XCTUnwrap(MonitorConfiguration.stored(fixture.defaults))

        // Every way a caller could try to bring up a local poller.
        fixture.store.startIfConfigured()
        fixture.store.start(configuration: configuration)
        fixture.store.startHub()
        await fixture.store.waitUntilIdle()
        try await settle()

        XCTAssertEqual(fixture.log.locals.count, 0)
        XCTAssertEqual(fixture.log.hubs.count, 1)
        XCTAssertEqual(fixture.log.hubs.first?.startCount, 1)
    }

    func testAnUnreachableHubIsRetriedByTheHubSourceAndNeverReplacedByALocalPoller() async throws {
        let fixture = try makeFixture(mode: .hub)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        let hub = try XCTUnwrap(fixture.log.hubs.first)

        hub.emit(.status(.failed("Hub unreachable (timed out)")))
        try await settle()

        XCTAssertEqual(fixture.store.state, .failed("Hub unreachable (timed out)"))
        XCTAssertEqual(fixture.store.policy.mode, .hub)
        XCTAssertEqual(fixture.log.locals.count, 0)

        // Starting again, as the dashboard's Retry does, still asks for a hub.
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(fixture.log.locals.count, 0)
        XCTAssertEqual(fixture.store.policy.mode, .hub)
    }

    func testHubModeWithoutSettingsShowsSetupInsteadOfStartingAnything() async throws {
        let fixture = try makeFixture(mode: .hub, hubConfigured: false)
        fixture.store.startIfConfigured()
        fixture.store.startHub()
        await fixture.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(fixture.log.locals.count, 0)
        XCTAssertEqual(fixture.log.hubs.count, 0)
    }

    func testDirectModeHoldsBackWhileAHubIsAdvertised() async throws {
        let fixture = try makeFixture(mode: .direct, advertising: [advertised])
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()

        XCTAssertEqual(fixture.log.locals.count, 0, "no local poller until the user decides")
        XCTAssertEqual(fixture.store.state, .degraded)
        XCTAssertFalse(fixture.store.policy.localPollerMayStart)

        fixture.store.ignoreHub(id: "hub-1")
        try await settle()
        XCTAssertEqual(fixture.log.locals.count, 1)
        XCTAssertEqual(fixture.log.locals.first?.startCount, 1)
        XCTAssertEqual(fixture.defaults.stringArray(forKey: ConnectionPolicy.ignoredHubsKey), ["hub-1"])
    }

    func testDirectModeStartsAsBeforeWhenNoHubIsAdvertised() async throws {
        let fixture = try makeFixture(mode: .direct)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(fixture.log.locals.count, 1)
        XCTAssertEqual(fixture.log.hubs.count, 0)
    }

    func testSwitchToHubStopsTheLocalPollerBeforeTheHubSourceExists() async throws {
        let fixture = try makeFixture(mode: .direct)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        let local = try XCTUnwrap(fixture.log.locals.first)

        XCTAssertTrue(fixture.store.switchToHub())
        await fixture.store.waitUntilIdle()
        try await settle()

        XCTAssertEqual(local.stopCount, 1)
        XCTAssertEqual(fixture.log.hubs.count, 1)
        XCTAssertEqual(fixture.store.policy.mode, .hub)
        XCTAssertEqual(fixture.defaults.string(forKey: ConnectionMode.defaultsKey), "hub")
    }

    /// A poller still restoring the inverter's limits is the controller until
    /// it has finished; the hub must not be connected on top of it.
    func testSwitchToHubWaitsWhileRestorationIsPending() async throws {
        let fixture = try makeFixture(mode: .direct)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        let local = try XCTUnwrap(fixture.log.locals.first)
        local.restorationPending = true

        fixture.store.switchToHub()
        await fixture.store.waitUntilIdle()
        try await settle()

        XCTAssertEqual(fixture.log.hubs.count, 0)
        XCTAssertEqual(fixture.store.policy.mode, .direct)
    }

    func testSwitchToHubRefusesWhenNoHubIsConfigured() async throws {
        let fixture = try makeFixture(mode: .direct, hubConfigured: false)
        XCTAssertFalse(fixture.store.switchToHub())
        XCTAssertEqual(fixture.store.policy.mode, .direct)
    }

    func testHubToDirectNeedsConfirmationAndStopsTheHubFirst() async throws {
        let fixture = try makeFixture(mode: .hub)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        let hub = try XCTUnwrap(fixture.log.hubs.first)

        XCTAssertFalse(fixture.store.switchToDirect(hubServiceConfirmedStopped: false))
        await fixture.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(fixture.log.locals.count, 0)
        XCTAssertEqual(fixture.store.policy.mode, .hub)

        XCTAssertTrue(fixture.store.switchToDirect(hubServiceConfirmedStopped: true))
        await fixture.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(hub.stopCount, 1)
        XCTAssertEqual(fixture.store.policy.mode, .direct)
        XCTAssertEqual(fixture.log.locals.count, 1)
    }
}
