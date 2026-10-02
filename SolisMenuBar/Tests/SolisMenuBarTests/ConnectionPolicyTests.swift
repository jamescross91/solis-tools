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

    /// A value from a newer build, or a corrupted preference, must land on
    /// the mode that behaves exactly as the app always has.
    func testUnknownStoredModeFallsBackToDirect() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "solis-policy-\(UUID().uuidString)"))
        defaults.set("satellite", forKey: ConnectionMode.defaultsKey)
        XCTAssertEqual(ConnectionPolicy.stored(defaults).mode, .direct)
        defaults.set("", forKey: ConnectionMode.defaultsKey)
        XCTAssertEqual(ConnectionPolicy.stored(defaults).mode, .direct)
    }

    func testIgnoreSurvivesRoundTripToHubAndBack() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "solis-policy-\(UUID().uuidString)"))
        var policy = ConnectionPolicy.stored(defaults)
        policy.ignore(hubID: "hub-1")
        policy.persist(defaults)

        policy.chooseHub()
        policy.persist(defaults)
        var inHubMode = ConnectionPolicy.stored(defaults)
        XCTAssertEqual(inHubMode.mode, .hub)
        XCTAssertEqual(inHubMode.ignoredHubIDs, ["hub-1"])

        XCTAssertTrue(inHubMode.switchToDirect(hubServiceConfirmedStopped: true))
        inHubMode.persist(defaults)
        let backInDirect = ConnectionPolicy.stored(defaults)
        XCTAssertEqual(backInDirect.mode, .direct)
        XCTAssertEqual(backInDirect.ignoredHubIDs, ["hub-1"])

        var advertised = backInDirect
        advertised.updateDetectedHubs([hub])
        XCTAssertTrue(advertised.localPollerMayStart)
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
    private let problem: String?

    init(hubs: [DiscoveredHub], problem: String? = nil) {
        self.hubs = hubs
        self.problem = problem
        var captured: AsyncStream<HubNetworkState>.Continuation?
        updates = AsyncStream<HubNetworkState> { captured = $0 }
        continuation = captured!
    }

    func start() {
        continuation.yield(
            HubNetworkState(
                discovered: hubs, pathSatisfied: true, scanCompleted: problem == nil,
                discoveryProblem: problem
            )
        )
    }

    /// A later network state, as Bonjour reports when a hub comes or goes.
    func update(_ hubs: [DiscoveredHub]) {
        continuation.yield(HubNetworkState(discovered: hubs, pathSatisfied: true, scanCompleted: true))
    }

    func stop() {
        continuation.finish()
    }
}

/// Remembers each presence watcher the store asked for, so a test can change
/// what the network reports after the store has started watching it.
@MainActor
private final class PresenceLog {
    private(set) var created: [StubPresence] = []

    var latest: StubPresence? { created.last }

    func make(hubs: [DiscoveredHub], problem: String?) -> StubPresence {
        let presence = StubPresence(hubs: hubs, problem: problem)
        created.append(presence)
        return presence
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
        let presences: PresenceLog
    }

    /// `defaults` lets a second store be built over the same preferences, as a
    /// relaunch would.
    private func makeFixture(
        mode: ConnectionMode,
        advertising: [DiscoveredHub] = [],
        hubConfigured: Bool = true,
        preferredHubID: String? = nil,
        discoveryProblem: String? = nil,
        defaults existing: UserDefaults? = nil
    ) throws -> Fixture {
        let defaults: UserDefaults
        if let existing {
            defaults = existing
        } else {
            defaults = try XCTUnwrap(UserDefaults(suiteName: "solis-store-\(UUID().uuidString)"))
        }
        defaults.set("192.168.1.57", forKey: "host")
        defaults.set(mode.rawValue, forKey: ConnectionMode.defaultsKey)
        var configured = hubSettings
        configured.connection.preferredHubID = preferredHubID
        let settings: HubSourceSettings? = hubConfigured ? configured : nil
        let log = SourceLog()
        let presences = PresenceLog()
        let store = MonitorStore(
            defaults: defaults,
            factory: log.factory,
            makePresence: { presences.make(hubs: advertising, problem: discoveryProblem) },
            loadHubSettings: { settings }
        )
        return Fixture(store: store, defaults: defaults, log: log, presences: presences)
    }

    private func envelope(timestamp: String, successfulPolls: Int = 1) throws -> StreamEnvelope {
        try StreamDecoder.decode(
            Data(
                """
                {
                  "schema_version": 2,
                  "timestamp": "\(timestamp)",
                  "device": {
                    "model_code": 20, "dsp_version": 1, "hmi_version": 1,
                    "protocol_version": 1, "type_definition": null,
                    "profile_validated": false
                  },
                  "reading": {
                    "grid_voltage_v": 250.0, "inverter_temperature_c": 30.0,
                    "inverter_status_code": 3, "inverter_status": "Generating",
                    "battery_soc_percent": 93, "house_load_kw": 1.58,
                    "battery_kw": 1.72, "battery_flow_kw": 1.72,
                    "battery_status": "Discharging", "grid_kw": -0.5,
                    "grid_status": "Importing", "pv_kw": null,
                    "pv_today_kwh": null, "alarms": []
                  },
                  "health": {
                    "last_sample_age_s": 0.0, "latency_ms": 1.0,
                    "successful_polls": \(successfulPolls), "total_failures": 0,
                    "consecutive_failures": 0, "reconnects": 0
                  },
                  "error": null
                }
                """.utf8
            )
        )
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

    // MARK: Stopping and switching

    /// With a hub holding the launch there is no source to emit .stopped, so
    /// the store has to report it itself or the dashboard stays "degraded".
    func testStopFromHeldDirectStateReportsStopped() async throws {
        let fixture = try makeFixture(mode: .direct, advertising: [advertised])
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(fixture.store.state, .degraded)
        XCTAssertNotNil(fixture.store.statusDetail)
        XCTAssertEqual(fixture.log.locals.count, 0)

        fixture.store.stop()
        await fixture.store.waitUntilIdle()

        XCTAssertEqual(fixture.store.state, .stopped)
        XCTAssertNil(fixture.store.statusDetail)
        XCTAssertFalse(fixture.store.isRunning)
        XCTAssertEqual(fixture.log.locals.count, 0)
    }

    /// Presence only runs in Direct mode, so after Hub mode the policy has
    /// seen no advertisements: the hub being left must be ignored by id, or
    /// the guard would hold the local poller back at once.
    func testSwitchToDirectIgnoresTheHubItWasConnectedTo() async throws {
        let fixture = try makeFixture(mode: .hub, advertising: [advertised])
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        let hub = try XCTUnwrap(fixture.log.hubs.first)
        hub.emit(.hubLink(HubLinkInfo(isConnected: true, hubID: "hub-1")))
        try await settle()

        XCTAssertTrue(fixture.store.switchToDirect(hubServiceConfirmedStopped: true))
        await fixture.store.waitUntilIdle()
        try await settle()

        XCTAssertEqual(fixture.store.policy.mode, .direct)
        XCTAssertTrue(fixture.store.policy.ignoredHubIDs.contains("hub-1"))
        XCTAssertEqual(fixture.defaults.stringArray(forKey: ConnectionPolicy.ignoredHubsKey), ["hub-1"])
        XCTAssertEqual(fixture.log.locals.count, 1)
        XCTAssertNotEqual(fixture.store.state, .degraded)
    }

    func testSwitchToDirectFallsBackToTheChosenHubWhenNoLinkWasSeen() async throws {
        let fixture = try makeFixture(mode: .hub, advertising: [advertised], preferredHubID: "hub-1")
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()

        XCTAssertTrue(fixture.store.switchToDirect(hubServiceConfirmedStopped: true))
        await fixture.store.waitUntilIdle()
        try await settle()

        XCTAssertTrue(fixture.store.policy.ignoredHubIDs.contains("hub-1"))
        XCTAssertEqual(fixture.log.locals.count, 1)
    }

    /// Whichever of the two calls the lifecycle queue meets first, no local
    /// poller may be left running once Hub mode has been chosen.
    func testStartThenSwitchToHubQuicklyNeverLeavesALocalPoller() async throws {
        let fixture = try makeFixture(mode: .direct)
        let configuration = try XCTUnwrap(MonitorConfiguration.stored(fixture.defaults))

        fixture.store.start(configuration: configuration)
        // Long enough for the start to be waiting on the first Bonjour scan.
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(fixture.store.switchToHub())
        await fixture.store.waitUntilIdle()
        try await settle()

        XCTAssertEqual(fixture.store.policy.mode, .hub)
        XCTAssertEqual(fixture.log.hubs.count, 1)
        XCTAssertTrue(fixture.log.locals.allSatisfy { $0.stopCount >= 1 })
    }

    /// A schema this build cannot read will not fix itself, but it is still
    /// the hub's problem: the answer is never to run the poller here.
    func testHubSourceUnsupportedSchemaNeverFallsBackToDirect() async throws {
        let fixture = try makeFixture(mode: .hub)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        let hub = try XCTUnwrap(fixture.log.hubs.first)

        hub.emit(.unsupportedSchema(3))
        try await settle()
        await fixture.store.waitUntilIdle()

        XCTAssertEqual(fixture.store.policy.mode, .hub)
        XCTAssertGreaterThanOrEqual(hub.stopCount, 1)
        XCTAssertEqual(fixture.log.locals.count, 0)

        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(fixture.log.locals.count, 0)
        XCTAssertEqual(fixture.store.policy.mode, .hub)
    }

    // MARK: Hub discovery in Direct mode

    func testHubDisappearingFreesTheHeldLaunch() async throws {
        let fixture = try makeFixture(mode: .direct, advertising: [advertised])
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(fixture.log.locals.count, 0)

        let presence = try XCTUnwrap(fixture.presences.latest)
        presence.update([])
        try await settle()

        XCTAssertEqual(fixture.log.locals.count, 1)
        XCTAssertEqual(fixture.log.locals.first?.startCount, 1)
        XCTAssertTrue(fixture.store.policy.localPollerMayStart)
    }

    /// A hub that appears after the poller launched only raises the banner:
    /// stopping the running controller on an advertisement could leave the
    /// inverter unregulated, and a second poller must never be started.
    func testDetectedHubWhileLocalPollerRunningNeitherKillsNorDuplicates() async throws {
        let fixture = try makeFixture(mode: .direct)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        let local = try XCTUnwrap(fixture.log.locals.first)

        let presence = try XCTUnwrap(fixture.presences.latest)
        presence.update([advertised])
        try await settle()

        XCTAssertEqual(fixture.log.locals.count, 1)
        XCTAssertEqual(local.startCount, 1)
        XCTAssertEqual(local.stopCount, 0)
        XCTAssertEqual(fixture.store.policy.blockingHubs.map(\.id), ["hub-1"])
    }

    func testIgnoredHubSurvivesANewStore() async throws {
        let first = try makeFixture(mode: .direct, advertising: [advertised])
        first.store.startIfConfigured()
        await first.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(first.log.locals.count, 0)
        first.store.ignoreHub(id: "hub-1")
        try await settle()
        XCTAssertEqual(first.log.locals.count, 1)

        // A relaunch over the same preferences, with the hub still advertised.
        let second = try makeFixture(mode: .direct, advertising: [advertised], defaults: first.defaults)
        XCTAssertEqual(second.store.policy.ignoredHubIDs, ["hub-1"])
        second.store.startIfConfigured()
        await second.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(second.log.locals.count, 1)
        XCTAssertNotEqual(second.store.state, .degraded)
    }

    /// With Local Network access refused no hub can ever be seen, so the guard
    /// fails open; the person is told, and the launch is not held for it.
    func testABlockedBrowserWarnsAndDoesNotDelayTheLaunch() async throws {
        let fixture = try makeFixture(
            mode: .direct, discoveryProblem: "Hub discovery is not running."
        )
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()

        XCTAssertEqual(fixture.store.discoveryWarning, "Hub discovery is not running.")
        XCTAssertEqual(fixture.log.locals.count, 1)

        XCTAssertTrue(fixture.store.switchToHub())
        await fixture.store.waitUntilIdle()
        XCTAssertNil(fixture.store.discoveryWarning)
    }

    // MARK: Freshness

    func testLastEnvelopeAtUsesTheEnvelopeTimestampInHubMode() async throws {
        let fixture = try makeFixture(mode: .hub)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        let hub = try XCTUnwrap(fixture.log.hubs.first)

        // A snapshot replayed after a reconnect is old data, whenever it arrives.
        let stamp = Date().addingTimeInterval(-3_600).formatted(.iso8601)
        hub.emit(.envelope(try envelope(timestamp: stamp)))
        try await settle()
        let expected = try XCTUnwrap(StreamDecoder.date(from: stamp))
        XCTAssertEqual(fixture.store.lastEnvelopeAt, expected)

        // A hub clock ahead of this Mac is clamped rather than shown as the future.
        hub.emit(.envelope(try envelope(timestamp: "2999-01-01T00:00:00+00:00", successfulPolls: 2)))
        try await settle()
        let clamped = try XCTUnwrap(fixture.store.lastEnvelopeAt)
        XCTAssertLessThanOrEqual(clamped, Date())
        XCTAssertGreaterThan(clamped, expected)
    }

    func testLastEnvelopeAtIsTheArrivalTimeInDirectMode() async throws {
        let fixture = try makeFixture(mode: .direct)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        let local = try XCTUnwrap(fixture.log.locals.first)

        let before = Date()
        local.emit(.envelope(try envelope(timestamp: "2026-08-19T16:30:00+01:00")))
        try await settle()
        let arrived = try XCTUnwrap(fixture.store.lastEnvelopeAt)
        XCTAssertGreaterThanOrEqual(arrived, before)
    }

    /// A hub that is down but still being retried counts as running, so
    /// reopening the popover does not tear its source down and rebuild it.
    func testAnUnreachableHubSourceCountsAsRunning() async throws {
        let fixture = try makeFixture(mode: .hub)
        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        let hub = try XCTUnwrap(fixture.log.hubs.first)

        hub.emit(.status(.failed("Hub unreachable (timed out)")))
        try await settle()
        XCTAssertTrue(fixture.store.isRunning)

        fixture.store.startIfConfigured()
        await fixture.store.waitUntilIdle()
        try await settle()
        XCTAssertEqual(fixture.log.hubs.count, 1)
        XCTAssertEqual(hub.stopCount, 0)
    }
}
