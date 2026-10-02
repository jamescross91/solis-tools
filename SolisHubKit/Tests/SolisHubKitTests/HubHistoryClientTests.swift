import XCTest

@testable import SolisHubKit

final class RecordingHTTPTransport: HubHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let status: Int
    private let body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requests.append(request)
        lock.unlock()
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

final class HubHistoryClientTests: XCTestCase {
    private let endpoint = HubEndpoint(kind: .remote, baseURL: URL(string: "https://energy.example.com")!)
    private let auth = HubAuth(token: "token", cloudflareClientID: "id", cloudflareClientSecret: "secret")

    private let samples = """
        [
          {
            "timestamp": "2026-10-02T10:00:00+01:00",
            "reading": {
              "grid_voltage_v": 250.0, "meter_voltage_v": 251.2, "inverter_temperature_c": 30.0,
              "inverter_status_code": 3, "inverter_status": "Generating",
              "battery_soc_percent": 93, "house_load_kw": 1.58, "battery_kw": 1.72,
              "battery_flow_kw": 1.72, "battery_status": "Discharging",
              "grid_kw": -0.5, "grid_status": "Importing", "pv_kw": null, "pv_today_kwh": null
            },
            "cadence": {"interval_s": 2.0, "idle": false},
            "voltage_control": {
              "state": "Import regulating", "action": "Reducing", "mode": "import",
              "raw_voltage_v": 252.0, "filtered_voltage_v": 251.5, "desired_limit_w": 12000,
              "emergency": false, "effective_minimum_voltage_v": 215.0,
              "effective_maximum_voltage_v": 258.0, "ev_voltage_limits_active": false,
              "ev_charging": null,
              "import_actuator": {"last_commanded_raw": 120, "resolution_w": 100},
              "export_actuator": {"last_commanded_raw": 50, "resolution_w": 100}
            }
          },
          {
            "timestamp": "2026-10-02T10:00:30+01:00",
            "reading": {
              "grid_voltage_v": 250.0, "inverter_temperature_c": 30.0, "house_load_kw": 1.0,
              "battery_flow_kw": 0.0, "grid_kw": 1.0
            },
            "cadence": null,
            "voltage_control": null
          }
        ]
        """

    func testSamplesDecodeTheHubsReducedEntries() async throws {
        let transport = RecordingHTTPTransport(body: samples)
        let client = HubHistoryClient(endpoint: endpoint, auth: auth, transport: transport)
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = try await client.samples(since: since, resolution: .compact)

        XCTAssertEqual(entries.count, 2)
        let first = entries[0]
        XCTAssertNotNil(first.date)
        XCTAssertEqual(first.reading.meterVoltageV, 251.2)
        XCTAssertEqual(first.reading.gridImportPositiveKw, 0.5)
        XCTAssertEqual(first.voltageControl?.importActuator?.commandedW, 12_000)
        XCTAssertEqual(first.voltageControl?.action, "Reducing")
        XCTAssertNil(entries[1].voltageControl)
        XCTAssertNil(entries[1].cadence)

        let request = try XCTUnwrap(transport.recorded.first)
        XCTAssertEqual(request.url?.path, "/v1/history/samples")
        let query = request.url?.query ?? ""
        XCTAssertTrue(query.contains("resolution=compact"), query)
        XCTAssertTrue(query.contains("since="), query)
        XCTAssertFalse(query.contains("+"), query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "secret")
    }

    func testControlMinutesDecodeEveryColumn() async throws {
        let body = """
            [{"minute": 1790000040, "voltage_min": 214.0, "voltage_max": 216.0, "voltage_sum": 3000.0,
              "grid_kw_min": -1.0, "grid_kw_max": 2.0, "grid_kw_sum": 5.0,
              "limit_w_min": null, "limit_w_max": 12000, "limit_w_sum": 120000,
              "sample_count": 10, "seconds_import": 20.0, "seconds_export": 0.0,
              "seconds_increasing": 5.0, "seconds_holding": 10.0, "seconds_reducing": 5.0,
              "emergency_count": 0}]
            """
        let transport = RecordingHTTPTransport(body: body)
        let client = HubHistoryClient(endpoint: endpoint, auth: auth, transport: transport)
        let rows = try await client.controlMinutes(since: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].minute, 1_790_000_040)
        XCTAssertNil(rows[0].limitWMin)
        XCTAssertEqual(rows[0].limitWMax, 12_000)
        XCTAssertEqual(rows[0].sampleCount, 10)
        XCTAssertEqual(rows[0].date, Date(timeIntervalSince1970: 1_790_000_040))
        let query = transport.recorded.first?.url?.query ?? ""
        XCTAssertTrue(query.contains("kind=minutes"), query)
        XCTAssertFalse(query.contains("since"), query)
    }

    func testControlEventsDecode() async throws {
        let body = """
            [{"timestamp": "2026-10-02T10:00:00+01:00", "state": "Import regulating",
              "action": "Reducing", "message": "near limit", "voltage_v": 252.0,
              "grid_kw": -1.5, "limit_w": 12000}]
            """
        let client = HubHistoryClient(
            endpoint: endpoint, auth: auth, transport: RecordingHTTPTransport(body: body)
        )
        let rows = try await client.controlEvents(since: nil)
        XCTAssertEqual(rows.first?.action, "Reducing")
        XCTAssertEqual(rows.first?.limitW, 12_000)
        XCTAssertNotNil(rows.first?.date)
    }

    func testAnErrorStatusIsSurfacedAsSuch() async {
        let client = HubHistoryClient(
            endpoint: endpoint, auth: auth, transport: RecordingHTTPTransport(status: 401, body: "")
        )
        do {
            _ = try await client.samples(since: nil, resolution: .native)
            XCTFail("expected a 401 to throw")
        } catch {
            XCTAssertEqual(error as? HubHTTPError, .status(401))
        }
    }

    func testStatusAndTheConnectionTestReportWhichEndpointAnswered() async throws {
        let body = """
            {"hub_version": "0.5.4", "hub_protocol_version": 1, "hub_id": "hub-1",
             "poller": \(Fixtures.poller), "clients": 2, "envelope_age_s": 1.5}
            """
        let lan = HubEndpoint(kind: .lan, baseURL: URL(string: "http://10.0.0.5:8765")!)
        let result = try await HubConnectionTester.test(
            candidates: [lan, endpoint], auth: auth, transport: RecordingHTTPTransport(body: body)
        )
        XCTAssertEqual(result.endpoint, lan)
        XCTAssertEqual(result.status.hubVersion, "0.5.4")
        XCTAssertEqual(result.status.poller.kind, .running)
        XCTAssertEqual(result.status.clients, 2)
    }

    func testTheConnectionTestExplainsEachFailure() async {
        do {
            _ = try await HubConnectionTester.test(
                candidates: [endpoint], auth: auth, transport: RecordingHTTPTransport(status: 401, body: "")
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rejected"), error.localizedDescription)
        }
    }
}
