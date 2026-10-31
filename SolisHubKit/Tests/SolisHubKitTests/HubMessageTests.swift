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
        XCTAssertNil(hello.sources, "an older hub sends no sources")
    }

    func testHelloCarriesTheSources() throws {
        guard case let .hello(hello) = try HubServerMessage.decode(Fixtures.hello(sources: Fixtures.sources)) else {
            return XCTFail("expected hello")
        }
        let sources = try XCTUnwrap(hello.sources)
        XCTAssertEqual(sources.octopus?.kind, .off)
        XCTAssertNil(sources.octopus?.detail)
        XCTAssertNotNil(sources.octopus?.lastOkDate)
        XCTAssertEqual(sources.hypervolt?.kind, .failing)
        XCTAssertEqual(sources.hypervolt?.detail, "Charger socket closed")
        XCTAssertNil(sources.hypervolt?.lastOk)
    }

    func testANullSourcesFieldIsTheSameAsNone() throws {
        guard case let .hello(hello) = try HubServerMessage.decode(Fixtures.hello(sources: "null")) else {
            return XCTFail("expected hello")
        }
        XCTAssertNil(hello.sources)
    }

    func testSnapshotCarriesTheSources() throws {
        let with = Fixtures.snapshot(envelope: nil, sources: Fixtures.sources)
        guard case let .snapshot(snapshot) = try HubServerMessage.decode(with) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertEqual(snapshot.sources?.octopus?.kind, .off)

        guard case let .snapshot(older) = try HubServerMessage.decode(Fixtures.snapshot(envelope: nil)) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertNil(older.sources)
    }

    func testSourcesMessageDecodes() throws {
        let text = """
            {"type":"sources","sources":{"octopus":{"state":"ok","detail":null,
             "last_ok":"2026-10-26T09:00:00Z"},"hypervolt":{"state":"not_signed_in","detail":null,"last_ok":null}}}
            """
        guard case let .sources(sources) = try HubServerMessage.decode(text) else {
            return XCTFail("expected sources")
        }
        XCTAssertEqual(sources.octopus?.kind, .ok)
        XCTAssertEqual(sources.hypervolt?.kind, .notSignedIn)
        XCTAssertEqual(sources.warnings, [])
    }

    /// A newer hub may add a state or a source; both must still decode, and
    /// a single entry this build cannot read must not cost it the message.
    func testUnknownStatesAndSourcesAreKept() throws {
        let text = """
            {"type":"sources","sources":{"octopus":{"state":"rate_limited","detail":"429","last_ok":null},
             "heat_pump":{"state":"off","detail":null,"last_ok":null},"broken":{"detail":"no state"}}}
            """
        guard case let .sources(sources) = try HubServerMessage.decode(text) else {
            return XCTFail("expected sources")
        }
        XCTAssertEqual(sources.octopus?.kind, .unknown("rate_limited"))
        XCTAssertEqual(sources.octopus?.state, "rate_limited")
        XCTAssertEqual(sources.all["heat_pump"]?.kind, .off)
        XCTAssertNil(sources.all["broken"])
        XCTAssertEqual(
            sources.warnings,
            [HubSourceWarning(source: "heat_pump", message: "Heat Pump is switched off in the hub's settings", detail: nil)]
        )
    }

    func testWarningsNameWhatIsMissingAndCarryTheDetail() throws {
        guard case let .hello(hello) = try HubServerMessage.decode(Fixtures.hello(sources: Fixtures.sources)) else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(
            hello.sources?.warnings,
            [
                HubSourceWarning(
                    source: "octopus",
                    message: "Octopus is switched off in the hub's settings: no prices or charge plan",
                    detail: nil
                ),
                HubSourceWarning(
                    source: "hypervolt",
                    message: "No car readings from Hypervolt for over 30 minutes",
                    detail: "Charger socket closed"
                ),
            ]
        )
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
