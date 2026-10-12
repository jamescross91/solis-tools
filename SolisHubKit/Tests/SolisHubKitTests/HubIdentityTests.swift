import XCTest

@testable import SolisHubKit

/// Answers /v1/identity the way a hub does, or the way an impostor would.
private final class IdentityTransport: HubHTTPTransport, @unchecked Sendable {
    enum Behaviour {
        case hub(token: String)
        case impostor
        case old
    }

    private let behaviour: Behaviour
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    init(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    var recorded: [URLRequest] {
        lock.withLock { requests }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let nonce = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "nonce" }?.value ?? ""
        let (status, body): (Int, String)
        switch behaviour {
        case let .hub(token):
            (status, body) = (200, #"{"hub_id":"hub-1","proof":"\#(HubIdentity.proof(token: token, nonce: nonce))"}"#)
        case .impostor:
            (status, body) = (200, #"{"hub_id":"hub-1","proof":"\#(String(repeating: "0", count: 64))"}"#)
        case .old:
            (status, body) = (404, "")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

final class HubIdentityTests: XCTestCase {
    private let discovered = HubEndpoint(
        kind: .lan, baseURL: URL(string: "http://10.0.0.5:8765")!, requiresProof: true
    )
    private let remote = HubEndpoint(kind: .remote, baseURL: URL(string: "https://pi.tail1.ts.net")!)
    private let auth = HubAuth(token: "test-token-0123456789abcdef0123456789")

    func testTheProofMatchesTheHubsPython() {
        // hmac.new(token, b"solis-hub-identity:" + nonce, hashlib.sha256).hexdigest()
        XCTAssertEqual(
            HubIdentity.proof(token: auth.token, nonce: "00112233445566778899aabbccddeeff"),
            "43ee03ed7292768998491ff1ba8d7b5c1de85ad945da92eec90089ef5866c8b3"
        )
    }

    func testTheRealHubPassesAndTheTokenIsNeverSent() async throws {
        let transport = IdentityTransport(.hub(token: auth.token))
        try await HubIdentity.verify(discovered, auth: auth, transport: transport)
        let request = try XCTUnwrap(transport.recorded.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.url!.absoluteString.contains(auth.token))
    }

    func testAnImpostorAndAnOldHubAreBothRefused() async {
        for behaviour in [IdentityTransport.Behaviour.impostor, .old, .hub(token: "someone-elses-token-0000000000")] {
            do {
                try await HubIdentity.verify(discovered, auth: auth, transport: IdentityTransport(behaviour))
                XCTFail("an unproven hub was accepted")
            } catch {
                XCTAssertEqual(error as? HubIdentityError, .notProven)
            }
        }
    }

    func testEachCheckUsesAFreshNonce() async throws {
        let transport = IdentityTransport(.hub(token: auth.token))
        try await HubIdentity.verify(discovered, auth: auth, transport: transport)
        try await HubIdentity.verify(discovered, auth: auth, transport: transport)
        let nonces = transport.recorded.map { $0.url!.query! }
        XCTAssertNotEqual(nonces[0], nonces[1])
    }

    func testOnlyBonjourResultsNeedTheProofAndTheLearnedAddressComesLast() {
        let settings = HubConnectionSettings(
            lanURL: URL(string: "http://192.168.1.20:8765"),
            remoteURL: URL(string: "https://energy.example.com"),
            preferredHubID: "hub-1",
            learnedRemoteURL: URL(string: "https://pi.tail1.ts.net")
        )
        let candidates = HubEndpointSelector.candidates(
            settings: settings,
            discovered: [DiscoveredHub(name: "Hub", hubID: "hub-1", url: URL(string: "http://10.0.0.5:8765"))]
        )
        XCTAssertEqual(candidates.map(\.baseURL.absoluteString), [
            "http://10.0.0.5:8765", "http://192.168.1.20:8765",
            "https://energy.example.com", "https://pi.tail1.ts.net",
        ])
        XCTAssertEqual(candidates.map(\.requiresProof), [true, false, false, false])
    }

    func testOneAddressIsEnoughWhenItIsTheLearnedOne() {
        let settings = HubConnectionSettings(
            remoteURL: URL(string: "https://pi.tail1.ts.net"),
            learnedRemoteURL: URL(string: "https://pi.tail1.ts.net")
        )
        XCTAssertEqual(HubEndpointSelector.candidates(settings: settings, discovered: []).count, 1)
    }

    func testTheStreamClientNeverOpensAnUnprovenBonjourHub() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let transport = ScriptedTransport([.socket(socket)])
        let client = HubClient(
            endpoints: [discovered, remote],
            auth: auth,
            transport: transport,
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) },
            jitter: { 0 },
            verifyIdentity: { _, _, _ in throw HubIdentityError.notProven }
        )
        let log = EventLog(client)
        await client.start()
        let seen = await log.wait(for: { if case .hello = $0 { return true } else { return false } })
        await client.stop()
        XCTAssertTrue(seen)
        // The token went only to the remote address; the impostor was never opened.
        XCTAssertEqual(transport.attempts, [remote])
    }

    func testAProvenBonjourHubIsUsedFirst() async throws {
        let socket = FakeSocket(frames: [Fixtures.hello()], endsAfterFrames: false)
        let transport = ScriptedTransport([.socket(socket)])
        let client = HubClient(
            endpoints: [discovered, remote],
            auth: auth,
            transport: transport,
            jitter: { 0 },
            verifyIdentity: { _, _, _ in }
        )
        let log = EventLog(client)
        await client.start()
        _ = await log.wait(for: { if case .hello = $0 { return true } else { return false } })
        await client.stop()
        XCTAssertEqual(transport.attempts, [discovered])
    }

    func testTheHelloCarriesThePublicAddress() throws {
        let text = #"{"type":"hello","hub_protocol_version":1,"hub_version":"0.9.0","stream_schema_version":2,"hub_id":"hub-1","public_url":"https://pi.tail1.ts.net","poller":null}"#
        guard case let .hello(hello) = try HubServerMessage.decode(text) else {
            return XCTFail("not a hello")
        }
        XCTAssertEqual(hello.publicUrl, "https://pi.tail1.ts.net")
        let older = #"{"type":"hello","hub_protocol_version":1,"hub_version":"0.8.0","stream_schema_version":2,"hub_id":"hub-1"}"#
        guard case let .hello(old) = try HubServerMessage.decode(older) else { return XCTFail("not a hello") }
        XCTAssertNil(old.publicUrl)
    }
}
