import Foundation

@testable import SolisHubKit

enum Fixtures {
    static let control = """
        {
          "state": "Import regulating", "action": "Holding", "mode": "import",
          "desired_limit_w": 12000, "raw_voltage_v": 216.4,
          "filtered_voltage_v": 216.8, "reason": "inside deadband",
          "emergency": false,
          "voltage_source": "meter/PCC input register, raw PDU 33251",
          "estimated_voltage_sensitivity_v_per_kw": 2.1,
          "import_actuator": {
            "pdu_address": 43488, "resolution_w": 100, "baseline_raw": 140,
            "last_commanded_raw": 120, "last_requested_raw": 120,
            "last_write_at": null, "writes_last_hour": 3, "last_error": null
          },
          "export_actuator": {
            "pdu_address": 43074, "resolution_w": 100, "baseline_raw": 50,
            "last_commanded_raw": 50, "last_requested_raw": null,
            "last_write_at": null, "writes_last_hour": 0, "last_error": null
          },
          "export_write_validated": false,
          "daily_summary": null,
          "recovery_note": null
          EXTRA
        }
        """

    static let event = """
        {
          "timestamp": "2026-09-04T12:00:00+01:00",
          "state": "Import regulating", "action": "Reducing", "mode": "import",
          "message": "inside deadband", "voltage_v": 216.4,
          "grid_kw": -11.8, "limit_w": 12000,
          "previous_limit_w": 12500, "limit_delta_w": -500
        }
        """

    static let configuration = """
        {
          "enabled": true, "import_enabled": true, "export_enabled": false,
          "export_control_validated": false,
          "minimum_voltage_v": 215.0, "maximum_voltage_v": 258.0,
          "safety_margin_v": 1.5, "deadband_v": 0.75,
          "maximum_import_w": 14000, "maximum_export_w": 10000,
          "site_export_permission_w": 10000, "hypervolt_enabled": false,
          "ev_priority": "battery", "octopus_enabled": false, "recovery_samples": 3
        }
        """

    static let schedule = """
        {
          "charge_window_active": false, "active_window": null, "next_window": null,
          "planned_windows": [], "lead_time_s": 300.0,
          "fetched_at": null, "last_error": null
        }
        """

    /// `extra` is appended inside voltage_control, so a test can include the
    /// fields the stream sends only sometimes.
    static func controlJSON(extra: String = "") -> String {
        control.replacingOccurrences(of: "EXTRA", with: extra)
    }

    static func envelope(
        schemaVersion: Int = 2,
        successfulPolls: Int = 1,
        timestamp: String = "2026-08-19T16:30:00.123+01:00",
        voltageControl: String = "null"
    ) -> String {
        """
        {
          "schema_version": \(schemaVersion),
          "timestamp": "\(timestamp)",
          "device": {
            "model_code": 20, "dsp_version": 101, "hmi_version": 202,
            "protocol_version": 301, "type_definition": 2001, "profile_validated": true
          },
          "reading": {
            "grid_voltage_v": 250.0, "inverter_temperature_c": 30.0,
            "inverter_status_code": 3, "inverter_status": "Generating",
            "battery_soc_percent": 93, "house_load_kw": 1.58, "battery_kw": 1.72,
            "battery_flow_kw": 1.72, "battery_status": "Discharging",
            "grid_kw": -0.5, "grid_status": "Importing",
            "pv_kw": null, "pv_today_kwh": null, "alarms": []
          },
          "health": {
            "last_sample_age_s": 0.0, "latency_ms": 12.3,
            "successful_polls": \(successfulPolls), "total_failures": 0,
            "consecutive_failures": 0, "reconnects": 0, "rejected_samples": 0
          },
          "voltage_control": \(voltageControl),
          "cadence": { "interval_s": 2.0, "idle": false },
          "error": null
        }
        """
    }

    static func decodeEnvelope(_ json: String) throws -> StreamEnvelope {
        try StreamDecoder.decode(Data(json.utf8))
    }

    static let poller = """
        {"state":"running","since":"2026-10-02T10:00:00+01:00","restarts":0,
         "last_exit_code":null,"next_attempt_at":null}
        """

    static func hello(
        protocolVersion: Int = 1, schema: Int = 2, hubID: String = "hub-1"
    ) -> String {
        """
        {"type":"hello","hub_protocol_version":\(protocolVersion),"hub_version":"0.5.4",
         "stream_schema_version":\(schema),"hub_id":"\(hubID)","poller":\(poller)}
        """
    }

    static func snapshot(envelope: String?) -> String {
        """
        {"type":"snapshot","envelope":\(envelope ?? "null"),"poller":\(poller)}
        """
    }

    static func sample(envelope: String) -> String {
        "{\"type\":\"sample\",\"envelope\":\(envelope)}"
    }
}
