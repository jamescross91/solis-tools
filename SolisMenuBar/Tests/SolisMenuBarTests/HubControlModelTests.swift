import Foundation
import SolisHubKit
import XCTest

@testable import SolisMenuBar

/// Answers every hub with the same settings and records where each request went.
private final class HubsTransport: HubHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var recorded: [URLRequest] {
        lock.withLock { requests }
    }

    func sent(_ method: String) -> [URLRequest] {
        recorded.filter { $0.httpMethod == method }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (Data(Self.state.utf8), response)
    }

    static let state = """
        {
          "settings": {
            "dynamic_voltage_enabled": true, "dynamic_import_enabled": true,
            "dynamic_export_enabled": false, "minimum_voltage": 212.0,
            "maximum_voltage": 259.0, "voltage_safety_margin": 1.5,
            "voltage_deadband": 1.0, "maximum_import_kw": 23.0,
            "import_headroom_kw": 1.5, "export_headroom_kw": 1.0,
            "maximum_export_kw": 10.0, "site_export_permission_kw": 10.0,
            "increase_step_w": 500, "reduction_step_w": 500,
            "near_limit_reduction_w": 1000, "emergency_reduction_w": 3000,
            "control_settle_time": 10.0, "control_activation_delay": 10.0,
            "control_deactivation_delay": 10.0, "import_activation_kw": 1.0,
            "export_activation_kw": 0.5, "minimum_write_interval": 60.0,
            "hypervolt_enabled": false, "ev_priority": "battery", "octopus_enabled": false
          },
          "source": "app",
          "export_control_validated": false,
          "hypervolt": {"signed_in": false, "charger_id": null},
          "octopus": {"signed_in": false, "account_number": null, "device_id": null}
        }
        """
}

@MainActor
final class HubControlModelTests: XCTestCase {
    private func target(_ host: String, token: String) -> HubAdminTarget {
        HubAdminTarget(
            connection: HubConnectionSettings(lanURL: URL(string: "http://\(host):8765")!),
            auth: HubAuth(token: token)
        )
    }

    func testNothingIsSentToANewHubUntilItsOwnSettingsHaveLoaded() async {
        let transport = HubsTransport()
        let model = HubControlModel(transport: transport)
        let hubA = target("hub-a.local", token: "token-a")
        let hubB = target("hub-b.local", token: "token-b")
        await model.load(from: hubA)
        model.draft.minimumVoltage = 210
        model.hypervoltEmail = "me@example.com"
        model.hypervoltPassword = "meant-for-b"
        model.octopusAPIKey = "sk_live_meant_for_b"

        // The form now names hub B, but what is on screen came from A.
        XCTAssertFalse(model.isCurrent(for: hubB))
        await model.apply(for: hubB)
        await model.signInToHypervolt(for: hubB)
        await model.signInToOctopus(for: hubB)
        XCTAssertEqual(transport.sent("PUT").count, 0)
        XCTAssertEqual(transport.sent("POST").count, 0)
        guard case .failed = model.applyState, case .failed = model.hypervoltState,
              case .failed = model.octopusState
        else {
            return XCTFail("acting on another hub's settings was not refused")
        }
    }

    func testChangingTheHubDropsTheOldSettingsAndActsOnTheNewHub() async throws {
        let transport = HubsTransport()
        let model = HubControlModel(transport: transport)
        let hubA = target("hub-a.local", token: "token-a")
        let hubB = target("hub-b.local", token: "token-b")
        await model.targetChanged(to: hubA)
        model.draft.minimumVoltage = 210

        await model.targetChanged(to: hubB)
        XCTAssertTrue(model.isCurrent(for: hubB))
        XCTAssertFalse(model.hasChanges, "an edit made for hub A survived the switch to B")
        model.draft.minimumVoltage = 211
        await model.apply(for: hubB)
        let put = try XCTUnwrap(transport.sent("PUT").first)
        XCTAssertEqual(put.url?.host, "hub-b.local")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Authorization"), "Bearer token-b")
    }

    func testANewTokenForTheSameAddressIsAnotherTarget() async {
        let transport = HubsTransport()
        let model = HubControlModel(transport: transport)
        await model.load(from: target("hub-a.local", token: "old"))
        XCTAssertFalse(model.isCurrent(for: target("hub-a.local", token: "new")))
    }

    func testABonjourResultForTheSameHubIsNotAChange() async {
        let model = HubControlModel(transport: HubsTransport())
        var hub = target("hub-a.local", token: "token")
        await model.load(from: hub)
        hub.discovered = [DiscoveredHub(name: "Hub", hubID: "id", url: URL(string: "http://10.0.0.5:8765"))]
        XCTAssertTrue(model.isCurrent(for: hub))
    }
}
