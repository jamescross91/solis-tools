import XCTest

@testable import SolisHubKit

final class HubEndpointTests: XCTestCase {
    private func url(_ text: String) throws -> URL {
        try XCTUnwrap(URL(string: text))
    }

    // MARK: Input parsing

    func testLanAddressesGetTheDefaultPort() throws {
        XCTAssertEqual(HubURLInput.lan("192.168.1.20")?.absoluteString, "http://192.168.1.20:8765")
        XCTAssertEqual(HubURLInput.lan(" pi.local:9000 ")?.absoluteString, "http://pi.local:9000")
        XCTAssertEqual(HubURLInput.lan("ws://pi.local:8765/v1/stream")?.absoluteString, "http://pi.local:8765")
        XCTAssertNil(HubURLInput.lan(""))
        XCTAssertNil(HubURLInput.lan("ftp://pi.local"))
    }

    func testRemoteAddressesMustBeTLS() throws {
        XCTAssertEqual(HubURLInput.remote("energy.example.com")?.absoluteString, "https://energy.example.com")
        XCTAssertEqual(HubURLInput.remote("wss://energy.example.com/x")?.absoluteString, "https://energy.example.com")
        XCTAssertNil(HubURLInput.remote("http://energy.example.com"))
        XCTAssertNil(HubURLInput.remote("ws://energy.example.com"))
    }

    func testCredentialsInAPastedURLAreDropped() throws {
        let result = try XCTUnwrap(HubURLInput.remote("https://user:secret@energy.example.com"))
        XCTAssertFalse(result.absoluteString.contains("secret"))
    }

    func testWebSocketURLFollowsTheScheme() throws {
        let lan = HubEndpoint(kind: .lan, baseURL: try url("http://pi.local:8765"))
        XCTAssertEqual(lan.webSocketURL.absoluteString, "ws://pi.local:8765/v1/stream")
        let remote = HubEndpoint(kind: .remote, baseURL: try url("https://energy.example.com"))
        XCTAssertEqual(remote.webSocketURL.absoluteString, "wss://energy.example.com/v1/stream")
    }

    func testQueryValuesAreEncodedSoAPlusSurvives() throws {
        let endpoint = HubEndpoint(kind: .lan, baseURL: try url("http://pi.local:8765"))
        let result = endpoint.httpURL(
            path: "/v1/history/samples",
            query: [("since", "2026-10-02T10:00:00+01:00"), ("resolution", "compact")]
        )
        XCTAssertEqual(result.path, "/v1/history/samples")
        XCTAssertTrue(result.absoluteString.contains("since=2026-10-02T10:00:00%2B01:00"), result.absoluteString)
        XCTAssertTrue(result.absoluteString.contains("resolution=compact"))
    }

    // MARK: Selection

    private func discovered(_ name: String, id: String?, address: String?) throws -> DiscoveredHub {
        DiscoveredHub(name: name, hubID: id, url: try address.map { try url($0) })
    }

    func testTheLanIsTriedBeforeTheRemoteURL() throws {
        let settings = HubConnectionSettings(
            lanURL: try url("http://192.168.1.20:8765"),
            remoteURL: try url("https://energy.example.com"),
            preferredHubID: "hub-1"
        )
        let found = try discovered("solis-hub", id: "hub-1", address: "http://192.168.1.21:8765")
        let candidates = HubEndpointSelector.candidates(settings: settings, discovered: [found])
        XCTAssertEqual(
            candidates.map(\.kind), [.lan, .lan, .remote]
        )
        XCTAssertEqual(candidates[0].baseURL.host, "192.168.1.21")
        XCTAssertEqual(candidates[1].baseURL.host, "192.168.1.20")
        XCTAssertEqual(candidates[2].baseURL.host, "energy.example.com")
    }

    func testNothingIsTriedWhileTheNetworkIsDown() throws {
        let settings = HubConnectionSettings(lanURL: try url("http://192.168.1.20:8765"))
        XCTAssertTrue(HubEndpointSelector.candidates(settings: settings, discovered: [], pathSatisfied: false).isEmpty)
    }

    func testAChosenHubExcludesOtherDiscoveredOnes() throws {
        let settings = HubConnectionSettings(preferredHubID: "mine")
        let mine = try discovered("mine-hub", id: "mine", address: "http://10.0.0.5:8765")
        let other = try discovered("other-hub", id: "other", address: "http://10.0.0.6:8765")
        let candidates = HubEndpointSelector.candidates(settings: settings, discovered: [other, mine])
        XCTAssertEqual(candidates.map { $0.baseURL.host }, ["10.0.0.5"])
    }

    func testAnUnresolvedServiceIsSkippedAndDuplicatesCollapse() throws {
        let settings = HubConnectionSettings(
            lanURL: try url("http://10.0.0.5:8765"), preferredHubID: "mine"
        )
        let unresolved = try discovered("a", id: "mine", address: nil)
        let same = try discovered("b", id: "mine", address: "http://10.0.0.5:8765")
        let candidates = HubEndpointSelector.candidates(settings: settings, discovered: [unresolved, same])
        XCTAssertEqual(candidates.count, 1)
    }

    /// The token goes to a LAN hub in clear text, and any host can advertise
    /// the service, so a discovered hub is never used until it is chosen, not
    /// even when it is the only one.
    func testDiscoveredHubsAreIgnoredUntilOneIsChosen() throws {
        let lone = try discovered("solis-hub", id: "hub-1", address: "http://10.0.0.5:8765")
        let remote = try url("https://energy.example.com")

        let nothingChosen = HubConnectionSettings(remoteURL: remote)
        XCTAssertEqual(
            HubEndpointSelector.candidates(settings: nothingChosen, discovered: [lone]).map(\.kind),
            [.remote]
        )
        XCTAssertTrue(
            HubEndpointSelector.candidates(settings: HubConnectionSettings(), discovered: [lone]).isEmpty
        )

        let chosen = HubConnectionSettings(remoteURL: remote, preferredHubID: "hub-1")
        let candidates = HubEndpointSelector.candidates(settings: chosen, discovered: [lone])
        XCTAssertEqual(candidates.map(\.kind), [.lan, .remote])
        XCTAssertEqual(candidates[0].baseURL.host, "10.0.0.5")

        // A choice that matches nothing on the network adds nothing.
        let elsewhere = HubConnectionSettings(preferredHubID: "hub-2")
        XCTAssertTrue(HubEndpointSelector.candidates(settings: elsewhere, discovered: [lone]).isEmpty)
    }

    // MARK: Moving a live connection

    func testLeavingHomeIsNotAReasonToChangeButArrivingIs() throws {
        let lan = HubEndpoint(kind: .lan, baseURL: try url("http://10.0.0.5:8765"))
        let remote = HubEndpoint(kind: .remote, baseURL: try url("https://energy.example.com"))
        // On the LAN and still offered: stay.
        XCTAssertFalse(HubReconnectPolicy.shouldReconnect(current: lan, candidates: [lan, remote]))
        // On the tunnel, and the LAN has appeared: move.
        XCTAssertTrue(HubReconnectPolicy.shouldReconnect(current: remote, candidates: [lan, remote]))
        // On the tunnel and nothing better: stay.
        XCTAssertFalse(HubReconnectPolicy.shouldReconnect(current: remote, candidates: [remote]))
        // The endpoint in use is no longer offered: move.
        XCTAssertTrue(HubReconnectPolicy.shouldReconnect(current: lan, candidates: [remote]))
        // The network went away: drop.
        XCTAssertTrue(HubReconnectPolicy.shouldReconnect(current: lan, candidates: []))
        // Not connected and nothing to try: nothing to do.
        XCTAssertFalse(HubReconnectPolicy.shouldReconnect(current: nil, candidates: []))
        XCTAssertTrue(HubReconnectPolicy.shouldReconnect(current: nil, candidates: [lan]))
    }

    // MARK: Backoff

    func testBackoffDoublesFromOneSecondToThirty() {
        let backoff = HubBackoff()
        XCTAssertEqual(backoff.delay(attempt: 0, jitter: 0), 1)
        XCTAssertEqual(backoff.delay(attempt: 1, jitter: 0), 2)
        XCTAssertEqual(backoff.delay(attempt: 4, jitter: 0), 16)
        XCTAssertEqual(backoff.delay(attempt: 5, jitter: 0), 30)
        XCTAssertEqual(backoff.delay(attempt: 50, jitter: 0), 30)
    }

    func testJitterOnlyShortensTheDelayAndNeverLeavesOneToThirty() {
        let backoff = HubBackoff()
        // The first delay has no room below it: one second is the floor.
        XCTAssertEqual(backoff.delay(attempt: 0, jitter: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(attempt: 3, jitter: 0.5), 7, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(attempt: 3, jitter: 1), 6, accuracy: 0.0001)
        for attempt in 0..<10 {
            for jitter in stride(from: 0.0, through: 1.0, by: 0.25) {
                let delay = backoff.delay(attempt: attempt, jitter: jitter)
                XCTAssertGreaterThanOrEqual(delay, 1)
                XCTAssertLessThanOrEqual(delay, 30)
                XCTAssertLessThanOrEqual(delay, backoff.delay(attempt: attempt, jitter: 0))
            }
        }
    }

    /// Jitter added on top of the cap was clamped away, so every client came
    /// back at exactly thirty seconds.
    func testJitterStillSpreadsAtTheCap() {
        let backoff = HubBackoff()
        XCTAssertEqual(backoff.delay(attempt: 10, jitter: 0), 30, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(attempt: 10, jitter: 0.5), 26.25, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(attempt: 10, jitter: 1), 22.5, accuracy: 0.0001)
        let delays = Set([0.0, 0.25, 0.5, 0.75, 1.0].map { backoff.delay(attempt: 20, jitter: $0) })
        XCTAssertEqual(delays.count, 5)
    }

    func testJitterNeverDropsBelowOneSecondOrAboveThirty() {
        let backoff = HubBackoff()
        for attempt in [-3, 0, 1, 2, 5, 16, 17, 1_000] {
            // Out-of-range jitter is clamped rather than trusted.
            for jitter in [-5.0, 0.0, 0.3, 1.0, 7.0] {
                let delay = backoff.delay(attempt: attempt, jitter: jitter)
                XCTAssertGreaterThanOrEqual(delay, 1, "attempt \(attempt), jitter \(jitter)")
                XCTAssertLessThanOrEqual(delay, 30, "attempt \(attempt), jitter \(jitter)")
            }
        }
    }

    // MARK: Network path

    func testThePathRevisionIgnoresTheFirstSnapshotAndRepeats() {
        var tracker = HubPathRevisionTracker()
        let home = HubPathRevisionTracker.signature(interfaces: ["wifi/en0"], gateways: ["192.168.1.1"])
        XCTAssertFalse(tracker.observe(home))
        XCTAssertEqual(tracker.revision, 0)
        XCTAssertFalse(tracker.observe(home))
        XCTAssertEqual(tracker.revision, 0)
    }

    func testThePathRevisionMovesWhenInterfacesOrGatewaysChange() {
        var tracker = HubPathRevisionTracker()
        let home = HubPathRevisionTracker.signature(interfaces: ["wifi/en0"], gateways: ["192.168.1.1"])
        // The same Wi-Fi interface, but a different network behind it.
        let cafe = HubPathRevisionTracker.signature(interfaces: ["wifi/en0"], gateways: ["10.20.0.1"])
        let docked = HubPathRevisionTracker.signature(
            interfaces: ["wifi/en0", "wiredEthernet/en5"], gateways: ["192.168.1.1"]
        )
        tracker.observe(home)
        XCTAssertTrue(tracker.observe(cafe))
        XCTAssertEqual(tracker.revision, 1)
        XCTAssertTrue(tracker.observe(docked))
        XCTAssertEqual(tracker.revision, 2)
        XCTAssertFalse(tracker.observe(docked))
        // Order within a snapshot is not a change.
        let reordered = HubPathRevisionTracker.signature(
            interfaces: ["wiredEthernet/en5", "wifi/en0"], gateways: ["192.168.1.1"]
        )
        XCTAssertFalse(tracker.observe(reordered))
        XCTAssertEqual(tracker.revision, 2)
    }

    // MARK: Credentials

    func testHeadersNeverIncludeHalfACloudflarePair() {
        XCTAssertEqual(HubAuth(token: "t").headers(for: .remote), ["Authorization": "Bearer t"])
        XCTAssertEqual(
            HubAuth(token: "t", cloudflareClientID: "id", cloudflareClientSecret: nil)
                .headers(for: .remote).count,
            1
        )
        let both = HubAuth(token: "t", cloudflareClientID: "id", cloudflareClientSecret: "secret")
            .headers(for: .remote)
        XCTAssertEqual(both["CF-Access-Client-Id"], "id")
        XCTAssertEqual(both["CF-Access-Client-Secret"], "secret")
    }

    func testTheCloudflarePairNeverCrossesPlainHttpToTheLan() {
        let auth = HubAuth(token: "t", cloudflareClientID: "id", cloudflareClientSecret: "secret")
        XCTAssertEqual(auth.headers(for: .lan), ["Authorization": "Bearer t"])
    }

    func testPrintingAuthRevealsNothing() {
        let auth = HubAuth(token: "super-secret", cloudflareClientID: "id", cloudflareClientSecret: "csecret")
        XCTAssertFalse("\(auth)".contains("super-secret"))
        XCTAssertFalse(String(reflecting: auth).contains("csecret"))
    }
}
