import XCTest

@testable import SolisHubKit

final class HubAdminClientTests: XCTestCase {
    private let endpoint = HubEndpoint(kind: .lan, baseURL: URL(string: "http://pi.local:8765")!)
    private let auth = HubAuth(token: "token", cloudflareClientID: "id", cloudflareClientSecret: "secret")

    static let stateJSON = """
        {
          "settings": {
            "dynamic_voltage_enabled": true,
            "dynamic_import_enabled": true,
            "dynamic_export_enabled": false,
            "minimum_voltage": 212.0,
            "maximum_voltage": 259.0,
            "voltage_safety_margin": 1.5,
            "voltage_deadband": 1.0,
            "maximum_import_kw": 23.0,
            "import_headroom_kw": 1.5,
            "export_headroom_kw": 1.0,
            "maximum_export_kw": 10.0,
            "site_export_permission_kw": 10.0,
            "increase_step_w": 500,
            "reduction_step_w": 500,
            "near_limit_reduction_w": 1000,
            "emergency_reduction_w": 3000,
            "control_settle_time": 10.0,
            "control_activation_delay": 10.0,
            "control_deactivation_delay": 10.0,
            "import_activation_kw": 1.0,
            "export_activation_kw": 0.5,
            "minimum_write_interval": 60.0,
            "hypervolt_enabled": true,
            "ev_priority": "ev",
            "octopus_enabled": true
          },
          "source": "hub_config",
          "export_control_validated": true,
          "hypervolt": {"signed_in": true, "charger_id": "HV-123"},
          "octopus": {"signed_in": false, "account_number": null, "device_id": null}
        }
        """

    func testSettingsDecodeFromTheHubsSnakeCase() async throws {
        let transport = RecordingHTTPTransport(body: Self.stateJSON)
        let state = try await HubAdminClient(endpoint: endpoint, auth: auth, transport: transport).settings()
        XCTAssertEqual(state.settings.minimumVoltage, 212)
        XCTAssertEqual(state.settings.nearLimitReductionW, 1000)
        XCTAssertEqual(state.settings.evPriority, "ev")
        XCTAssertFalse(state.setFromApp)
        XCTAssertTrue(state.exportControlValidated)
        XCTAssertEqual(state.hypervolt, HubHypervoltAccount(signedIn: true, chargerId: "HV-123"))
        XCTAssertFalse(state.octopus.signedIn)
        XCTAssertNil(state.restarted)
        let request = try XCTUnwrap(transport.recorded.first)
        XCTAssertEqual(request.url?.absoluteString, "http://pi.local:8765/v1/settings")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        // The Cloudflare pair goes only to the remote endpoint.
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
    }

    func testSavingSendsEveryFieldInSnakeCase() async throws {
        let decoded = try StreamDecoder.makeJSONDecoder().decode(
            HubSettingsState.self, from: Data(Self.stateJSON.utf8)
        )
        var settings = decoded.settings
        settings.minimumVoltage = 210
        let transport = RecordingHTTPTransport(body: Self.stateJSON)
        _ = try await HubAdminClient(endpoint: endpoint, auth: auth, transport: transport).save(settings)
        let request = try XCTUnwrap(transport.recorded.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.stateJSON.utf8)) as? [String: Any]
        )["settings"] as? [String: Any]
        XCTAssertEqual(Set(body.keys), Set(try XCTUnwrap(sent).keys))
        XCTAssertEqual(body["minimum_voltage"] as? Double, 210)
        XCTAssertEqual(body["near_limit_reduction_w"] as? Int, 1000)
    }

    func testSignInPutsTheSecretInTheBodyOnly() async throws {
        let transport = RecordingHTTPTransport(body: Self.stateJSON)
        let client = HubAdminClient(endpoint: endpoint, auth: auth, transport: transport)
        _ = try await client.signInToOctopus(apiKey: "sk_live_abc", account: "A-1234ABCD")
        _ = try await client.signInToHypervolt(email: "me@example.com", password: "pa55")
        let octopus = transport.recorded[0]
        XCTAssertEqual(octopus.httpMethod, "POST")
        XCTAssertEqual(octopus.url?.path, "/v1/credentials/octopus")
        XCTAssertFalse(octopus.url?.absoluteString.contains("sk_live") ?? true)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(octopus.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["api_key"] as? String, "sk_live_abc")
        XCTAssertEqual(body["account"] as? String, "A-1234ABCD")
        let hypervolt = transport.recorded[1]
        XCTAssertEqual(hypervolt.url?.path, "/v1/credentials/hypervolt")
        // A sign-in waits for the hub's login command, which may take a while.
        XCTAssertGreaterThanOrEqual(hypervolt.timeoutInterval, 60)
    }

    func testTheHubsReasonForARefusalIsShown() async {
        let transport = RecordingHTTPTransport(
            status: 400, body: #"{"error": "voltage limits must satisfy 180 <= minimum < maximum <= 280"}"#
        )
        do {
            _ = try await HubAdminClient(endpoint: endpoint, auth: auth, transport: transport).settings()
            XCTFail("a refusal was accepted")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, "voltage limits must satisfy 180 <= minimum < maximum <= 280"
            )
        }
    }

    func testAnOldHubIsReportedAsNeedingAnUpgrade() async {
        let transport = RecordingHTTPTransport(status: 404, body: "")
        do {
            _ = try await HubAdminClient.connect(candidates: [endpoint], auth: auth, transport: transport)
            XCTFail("an old hub was accepted")
        } catch {
            XCTAssertTrue(error is HubAdminError)
        }
    }

    func testAWrongTokenKeepsItsGenericDescription() async {
        let transport = RecordingHTTPTransport(status: 401, body: "")
        do {
            _ = try await HubAdminClient(endpoint: endpoint, auth: auth, transport: transport).settings()
            XCTFail("a 401 was accepted")
        } catch {
            XCTAssertEqual(error as? HubHTTPError, .status(401))
        }
    }
}
