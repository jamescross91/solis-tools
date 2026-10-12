import XCTest

@testable import SolisHubKit

final class HubMessageTests: XCTestCase {
    func testHelloDecodes() throws {
        guard case let .hello(hello) = try HubServerMessage.decode(Fixtures.hello()) else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(hello.hubProtocolVersion, 1)
        XCTAssertEqual(hello.hubVersion, "0.5.4")
        XCTAssertEqual(hello.streamSchemaVersion, 2)
        XCTAssertEqual(hello.hubId, "hub-1")
        XCTAssertEqual(hello.poller?.kind, .running)
    }

    func testSnapshotBeforeTheFirstSampleHasNoEnvelope() throws {
        guard case let .snapshot(snapshot) = try HubServerMessage.decode(Fixtures.snapshot(envelope: nil)) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertNil(snapshot.envelope)
        XCTAssertEqual(snapshot.poller?.state, "running")
    }

    func testSnapshotCarriesTheMergedEnvelope() throws {
        let control = Fixtures.controlJSON(
            extra: ", \"recent_events\": [\(Fixtures.event)], \"configuration\": \(Fixtures.configuration)"
        )
        let text = Fixtures.snapshot(envelope: Fixtures.envelope(voltageControl: control))
        guard case let .snapshot(snapshot) = try HubServerMessage.decode(text) else {
            return XCTFail("expected snapshot")
        }
        let details = try XCTUnwrap(snapshot.envelope?.voltageControl)
        XCTAssertEqual(details.recentEvents?.count, 1)
        XCTAssertEqual(details.configuration?.minimumVoltageV, 215.0)
        XCTAssertEqual(details.configuration?.maximumImportW, 14000)
        XCTAssertEqual(details.configuration?.evPriority, "battery")
    }

    func testSampleForwardsTheEnvelopeUnchanged() throws {
        let text = Fixtures.sample(envelope: Fixtures.envelope(successfulPolls: 7))
        guard case let .sample(envelope) = try HubServerMessage.decode(text) else {
            return XCTFail("expected sample")
        }
        XCTAssertEqual(envelope.health.successfulPolls, 7)
        XCTAssertNil(envelope.voltageControl)
    }

    func testPollerStatusDecodes() throws {
        let text = """
            {"type":"poller_status","state":"backoff","since":"2026-10-02T10:00:00+01:00",
             "restarts":2,"last_exit_code":1,"next_attempt_at":"2026-10-02T10:00:08+01:00"}
            """
        guard case let .pollerStatus(status) = try HubServerMessage.decode(text) else {
            return XCTFail("expected poller_status")
        }
        XCTAssertEqual(status.kind, .backoff)
        XCTAssertEqual(status.restarts, 2)
        XCTAssertEqual(status.lastExitCode, 1)
        XCTAssertNotNil(status.nextAttemptDate)
    }

    func testPongEchoesTheNonce() throws {
        guard case let .pong(nonce) = try HubServerMessage.decode("{\"type\":\"pong\",\"nonce\":\"4\"}") else {
            return XCTFail("expected pong")
        }
        XCTAssertEqual(nonce, "4")
    }

    func testErrorDecodes() throws {
        let text = "{\"type\":\"error\",\"code\":\"protocol\",\"message\":\"unmasked frame\"}"
        guard case let .error(error) = try HubServerMessage.decode(text) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(error.code, "protocol")
        XCTAssertEqual(error.message, "unmasked frame")
    }

    /// A newer hub may add a message; an older client must carry on.
    func testUnknownTypeIsNotAnError() throws {
        guard case let .unknown(type) = try HubServerMessage.decode("{\"type\":\"weather\"}") else {
            return XCTFail("expected unknown")
        }
        XCTAssertEqual(type, "weather")
    }

    func testNewerStreamSchemaIsReportedAsSuchNotAsCorruption() {
        let text = Fixtures.sample(envelope: Fixtures.envelope(schemaVersion: 3))
        XCTAssertThrowsError(try HubServerMessage.decode(text)) { error in
            XCTAssertEqual(error as? HubMessageError, .unsupportedStreamSchema(3))
        }
    }

    func testMalformedMessagesThrow() {
        XCTAssertThrowsError(try HubServerMessage.decode("not json")) { error in
            XCTAssertEqual(error as? HubMessageError, .malformed)
        }
        XCTAssertThrowsError(try HubServerMessage.decode("{\"type\":\"sample\",\"envelope\":{}}")) { error in
            XCTAssertEqual(error as? HubMessageError, .malformed)
        }
    }

    func testClientMessagesAreOnlyAttentionAndPing() throws {
        XCTAssertEqual(HubClientMessage.attention(true).text, "{\"type\":\"attention\",\"on\":true}")
        XCTAssertEqual(HubClientMessage.attention(false).text, "{\"type\":\"attention\",\"on\":false}")
        let ping = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(HubClientMessage.ping(nonce: 3).text.utf8)) as? [String: String]
        )
        XCTAssertEqual(ping, ["type": "ping", "nonce": "3"])
    }

    func testPollerSummaryNamesTheRestartDelay() {
        let now = Date(timeIntervalSince1970: 1_000)
        let next = StreamDecoder.date(from: "2026-10-02T10:00:08+01:00") ?? now
        let status = HubPollerStatus(
            state: "backoff", since: nil, restarts: 1, lastExitCode: 1,
            nextAttemptAt: "2026-10-02T10:00:08+01:00"
        )
        XCTAssertEqual(
            status.summary(now: next.addingTimeInterval(-8)),
            "Hub is up, inverter poller restarting in 8 s"
        )
        XCTAssertNil(
            HubPollerStatus(state: "running", since: nil, restarts: 0, lastExitCode: nil, nextAttemptAt: nil)
                .summary()
        )
    }

    func testConfigurationToleratesAnEmptyObject() throws {
        let control = Fixtures.controlJSON(extra: ", \"configuration\": {}")
        let envelope = try Fixtures.decodeEnvelope(Fixtures.envelope(voltageControl: control))
        XCTAssertNotNil(envelope.voltageControl?.configuration)
        XCTAssertNil(envelope.voltageControl?.configuration?.minimumVoltageV)
    }
}
