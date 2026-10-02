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
            remoteURL: try url("https://energy.example.com")
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
        let settings = HubConnectionSettings(lanURL: try url("http://10.0.0.5:8765"))
        let unresolved = try discovered("a", id: "a", address: nil)
        let same = try discovered("b", id: "b", address: "http://10.0.0.5:8765")
        let candidates = HubEndpointSelector.candidates(settings: settings, discovered: [unresolved, same])
        XCTAssertEqual(candidates.count, 1)
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
        XCTAssertEqual(backoff.delay(attempt: 50, jitter: 1), 30)
    }

    func testJitterOnlyAddsAndNeverExceedsTheCap() {
        let backoff = HubBackoff()
        XCTAssertEqual(backoff.delay(attempt: 0, jitter: 1), 1.25, accuracy: 0.0001)
        XCTAssertEqual(backoff.delay(attempt: 3, jitter: 0.5), 9, accuracy: 0.0001)
        for attempt in 0..<10 {
            for jitter in stride(from: 0.0, through: 1.0, by: 0.25) {
                let delay = backoff.delay(attempt: attempt, jitter: jitter)
                XCTAssertGreaterThanOrEqual(delay, 1)
                XCTAssertLessThanOrEqual(delay, 30)
            }
        }
    }

    // MARK: Credentials

    func testHeadersNeverIncludeHalfACloudflarePair() {
        XCTAssertEqual(HubAuth(token: "t").headers(), ["Authorization": "Bearer t"])
        XCTAssertEqual(
            HubAuth(token: "t", cloudflareClientID: "id", cloudflareClientSecret: nil).headers().count, 1
        )
        let both = HubAuth(token: "t", cloudflareClientID: "id", cloudflareClientSecret: "secret").headers()
        XCTAssertEqual(both["CF-Access-Client-Id"], "id")
        XCTAssertEqual(both["CF-Access-Client-Secret"], "secret")
    }

    func testPrintingAuthRevealsNothing() {
        let auth = HubAuth(token: "super-secret", cloudflareClientID: "id", cloudflareClientSecret: "csecret")
        XCTAssertFalse("\(auth)".contains("super-secret"))
        XCTAssertFalse(String(reflecting: auth).contains("csecret"))
    }
}
