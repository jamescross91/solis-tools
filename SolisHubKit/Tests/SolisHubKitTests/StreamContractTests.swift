import XCTest

@testable import SolisHubKit

/// The Python poller owns the JSON stream. These tests pin the shape the app
/// expects so a change on either side fails here rather than in the menu bar.
final class StreamContractTests: XCTestCase {
    private func envelopeJSON(
        schemaVersion: Int = 2,
        voltageControl: String = "null",
        health: String = """
            {
              "last_sample_age_s": 0.0,
              "latency_ms": 12.3,
              "successful_polls": 1,
              "total_failures": 0,
              "consecutive_failures": 0,
              "reconnects": 0,
              "rejected_samples": 0
            }
            """
    ) -> Data {
        Data(
            """
            {
              "schema_version": \(schemaVersion),
              "timestamp": "2026-08-19T16:30:00.123+01:00",
              "device": {
                "model_code": 20,
                "dsp_version": 101,
                "hmi_version": 202,
                "protocol_version": 301,
                "type_definition": 2001,
                "profile_validated": true
              },
              "reading": {
                "grid_voltage_v": 250.0,
                "inverter_temperature_c": 30.0,
                "inverter_status_code": 3,
                "inverter_status": "Generating",
                "battery_soc_percent": 93,
                "house_load_kw": 1.58,
                "battery_kw": 1.72,
                "battery_flow_kw": 1.72,
                "battery_status": "Discharging",
                "grid_kw": -0.5,
                "grid_status": "Importing",
                "pv_kw": null,
                "pv_today_kwh": null,
                "alarms": []
              },
              "health": \(health),
              "voltage_control": \(voltageControl),
              "cadence": { "interval_s": 2.0, "idle": false },
              "error": null
            }
            """.utf8
        )
    }

    func testEnvelopeDecodesEveryFieldTheDashboardReads() throws {
        let envelope = try StreamDecoder.decode(envelopeJSON())

        XCTAssertEqual(envelope.schemaVersion, 2)
        XCTAssertEqual(envelope.cadence?.intervalS, 2.0)
        XCTAssertEqual(envelope.cadence?.idle, false)
        XCTAssertEqual(envelope.device.modelCode, 20)
        XCTAssertEqual(envelope.device.typeDefinition, 2001)
        XCTAssertTrue(envelope.device.profileValidated)
        XCTAssertEqual(envelope.reading.houseLoadKw, 1.58)
        XCTAssertEqual(envelope.reading.batterySocPercent, 93)
        XCTAssertNil(envelope.reading.pvKw)
        XCTAssertNil(envelope.reading.meterVoltageV)
        XCTAssertNil(envelope.voltageControl)
        XCTAssertEqual(envelope.health.rejectedSamples, 0)
        XCTAssertNil(envelope.error)
    }

    /// Imports read positive in the menu bar; the poller reports exports positive.
    func testGridSignIsInvertedForDisplay() throws {
        let envelope = try StreamDecoder.decode(envelopeJSON())
        XCTAssertEqual(envelope.reading.gridKw, -0.5)
        XCTAssertEqual(envelope.reading.gridImportPositiveKw, 0.5)
    }

    func testDynamicVoltageDiagnosticsDecode() throws {
        let control = """
            {
              "state": "Import regulating", "action": "Holding", "mode": "import",
              "desired_limit_w": 12000, "raw_voltage_v": 216.4,
              "filtered_voltage_v": 216.8, "reason": "inside deadband",
              "emergency": false,
              "configuration": {},
              "voltage_source": "meter/PCC input register, raw PDU 33251",
              "estimated_voltage_sensitivity_v_per_kw": 2.1,
              "import_actuator": {
                "pdu_address": 43488, "resolution_w": 100, "baseline_raw": 140,
                "last_commanded_raw": 120, "last_requested_raw": 120,
                "last_write_at": "2026-09-04T12:00:00+01:00",
                "writes_last_hour": 3, "last_error": null
              },
              "export_actuator": {
                "pdu_address": 43074, "resolution_w": 100, "baseline_raw": 50,
                "last_commanded_raw": 50, "last_requested_raw": null,
                "last_write_at": null, "writes_last_hour": 0, "last_error": null
              },
              "export_write_validated": false,
              "recent_events": [{
                "timestamp": "2026-09-04T12:00:00+01:00",
                "state": "Import regulating", "action": "Reducing", "mode": "import",
                "message": "inside deadband", "voltage_v": 216.4,
                "grid_kw": -11.8, "limit_w": 12000,
                "previous_limit_w": 12500, "limit_delta_w": -500
              }],
              "daily_summary": null,
              "recovery_note": null
            }
            """
        let details = try XCTUnwrap(
            StreamDecoder.decode(envelopeJSON(voltageControl: control)).voltageControl
        )
        XCTAssertEqual(details.state, "Import regulating")
        XCTAssertEqual(details.importActuator.pduAddress, 43488)
        XCTAssertEqual(details.importActuator.commandedW, 12_000)
        XCTAssertFalse(details.exportWriteValidated)
        XCTAssertEqual(details.recentEvents?.count, 1)
        XCTAssertEqual(
            details.recentEvents?[0].changeLabel,
            "Import limit 12.5 kW → 12.0 kW (-0.5 kW)"
        )
        XCTAssertNil(details.dailySummary)
        // Absent because this poller has no Hypervolt enabled; must decode as
        // nil, not fail, so an older poller's stream still works.
        XCTAssertNil(details.evPriority)
        XCTAssertNil(details.evCharging)
        XCTAssertNil(details.hypervoltActuator)
        XCTAssertNil(details.evVoltageLimitsActive)
        XCTAssertNil(details.octopusSchedule)
    }

    func testOctopusScheduleDecodes() throws {
        let control = """
            {
              "state": "Emergency high voltage", "action": "Emergency", "mode": "export",
              "desired_limit_w": 3000, "raw_voltage_v": 254.0,
              "filtered_voltage_v": 254.0, "reason": "raw PCC voltage reached the absolute maximum",
              "emergency": true, "voltage_source": "meter/PCC input register, raw PDU 33251",
              "estimated_voltage_sensitivity_v_per_kw": null,
              "import_actuator": {
                "pdu_address": 43488, "resolution_w": 100, "baseline_raw": 140,
                "last_commanded_raw": 140, "last_requested_raw": null,
                "last_write_at": null, "writes_last_hour": 0, "last_error": null
              },
              "export_actuator": {
                "pdu_address": 43074, "resolution_w": 100, "baseline_raw": 50,
                "last_commanded_raw": 30, "last_requested_raw": null,
                "last_write_at": null, "writes_last_hour": 1, "last_error": null
              },
              "export_write_validated": true,
              "daily_summary": null, "recovery_note": null,
              "ev_priority": null, "ev_charging": null, "hypervolt_actuator": null,
              "ev_voltage_limits_active": true,
              "effective_minimum_voltage_v": 215.0, "effective_maximum_voltage_v": 253.0,
              "octopus_schedule": {
                "charge_window_active": true,
                "active_window": {
                  "start": "2026-09-27T23:30:00+01:00", "end": "2026-09-28T05:30:00+01:00",
                  "kind": "SMART"
                },
                "next_window": null,
                "planned_windows": [{
                  "start": "2026-09-27T23:30:00+01:00", "end": "2026-09-28T05:30:00+01:00",
                  "kind": "SMART"
                }],
                "lead_time_s": 300.0,
                "fetched_at": "2026-09-27T23:28:00+01:00",
                "last_error": null,
                "normal_minimum_voltage_v": 215.0, "normal_maximum_voltage_v": 258.0,
                "charge_minimum_voltage_v": 215.0, "charge_maximum_voltage_v": 253.0
              }
            }
            """
        let details = try XCTUnwrap(
            StreamDecoder.decode(envelopeJSON(voltageControl: control)).voltageControl
        )
        XCTAssertEqual(details.evVoltageLimitsActive, true)
        XCTAssertEqual(details.effectiveMaximumVoltageV, 253.0)
        let schedule = try XCTUnwrap(details.octopusSchedule)
        XCTAssertTrue(schedule.chargeWindowActive)
        XCTAssertEqual(schedule.activeWindow?.kind, "SMART")
        XCTAssertEqual(
            schedule.activeWindow?.endDate?.timeIntervalSince(try XCTUnwrap(schedule.activeWindow?.startDate)),
            6 * 3_600
        )
        XCTAssertNil(schedule.nextWindow)
        XCTAssertEqual(schedule.plannedWindows.count, 1)
        XCTAssertEqual(schedule.leadTimeS, 300)
        XCTAssertNil(schedule.lastError)
        XCTAssertEqual(schedule.normalMaximumVoltageV, 258.0)
        XCTAssertEqual(schedule.chargeMaximumVoltageV, 253.0)
        XCTAssertEqual(schedule.chargeMinimumVoltageV, 215.0)
    }

    func testHypervoltDiagnosticsDecode() throws {
        let control = """
            {
              "state": "Import regulating", "action": "Holding", "mode": "import",
              "desired_limit_w": 12000, "raw_voltage_v": 216.4,
              "filtered_voltage_v": 216.8, "reason": "inside deadband",
              "emergency": false, "voltage_source": "meter/PCC input register, raw PDU 33251",
              "estimated_voltage_sensitivity_v_per_kw": null,
              "import_actuator": {
                "pdu_address": 43488, "resolution_w": 100, "baseline_raw": 140,
                "last_commanded_raw": 140, "last_requested_raw": null,
                "last_write_at": null, "writes_last_hour": 0, "last_error": null
              },
              "export_actuator": {
                "pdu_address": 43074, "resolution_w": 100, "baseline_raw": 50,
                "last_commanded_raw": 50, "last_requested_raw": null,
                "last_write_at": null, "writes_last_hour": 0, "last_error": null
              },
              "export_write_validated": false,
              "daily_summary": null, "recovery_note": null,
              "ev_priority": "battery", "ev_charging": true,
              "hypervolt_actuator": {
                "connected": true, "commanded_current_a": 22.5,
                "minimum_current_a": 6.0, "maximum_current_a": 32.0,
                "total_write_count": 3, "last_error": null,
                "measured_current_a": 21.8, "charging_power_kw": 4.717,
                "session_energy_kwh": 6.4, "telemetry_age_s": 1.2
              }
            }
            """
        let details = try XCTUnwrap(
            StreamDecoder.decode(envelopeJSON(voltageControl: control)).voltageControl
        )
        XCTAssertEqual(details.evPriority, "battery")
        XCTAssertEqual(details.evCharging, true)
        let hypervolt = try XCTUnwrap(details.hypervoltActuator)
        XCTAssertTrue(hypervolt.connected)
        XCTAssertEqual(hypervolt.commandedCurrentA, 22.5)
        XCTAssertEqual(hypervolt.maximumCurrentA, 32.0)
        XCTAssertEqual(hypervolt.totalWriteCount, 3)
        XCTAssertNil(hypervolt.lastError)
        XCTAssertEqual(hypervolt.measuredCurrentA, 21.8)
        XCTAssertEqual(hypervolt.chargingPowerKw, 4.717)
        XCTAssertEqual(hypervolt.sessionEnergyKwh, 6.4)
        XCTAssertEqual(hypervolt.telemetryAgeS, 1.2)
    }

    private func schedule(_ json: String) throws -> OctopusScheduleDetails {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OctopusScheduleDetails.self, from: Data(json.utf8))
    }

    /// The dashboard says when the next slot is, what the band becomes and
    /// what it returns to, before the slot starts.
    func testOctopusSummaryDescribesTheNextSlotAndTheRevert() throws {
        let plan = try schedule(
            """
            {
              "charge_window_active": false, "active_window": null,
              "next_window": {
                "start": "2026-09-27T23:30:00+01:00", "end": "2026-09-28T05:30:00+01:00",
                "kind": "SMART"
              },
              "planned_windows": [
                {"start": "2026-09-27T23:30:00+01:00", "end": "2026-09-28T05:30:00+01:00", "kind": "SMART"},
                {"start": "2026-09-28T23:30:00+01:00", "end": "2026-09-29T01:00:00+01:00", "kind": "SMART"}
              ],
              "lead_time_s": 300.0, "fetched_at": null, "last_error": null,
              "normal_minimum_voltage_v": 215.0, "normal_maximum_voltage_v": 258.0,
              "charge_minimum_voltage_v": 215.0, "charge_maximum_voltage_v": 253.0
            }
            """
        )
        let start = try XCTUnwrap(plan.nextWindow?.startDate)
        XCTAssertEqual(plan.nextLeadInDate, start.addingTimeInterval(-300))
        let lines = plan.summaryLines(now: start.addingTimeInterval(-3_600))
        XCTAssertTrue(lines[0].hasPrefix("Next charging slot: "))
        XCTAssertTrue(lines[1].contains("narrows from 215–258 V to 215–253 V"), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("It reverts to 215–258 V at "), lines[2])
        XCTAssertEqual(lines.last, "1 more slot planned after that.")
    }

    func testOctopusSummaryWithoutBandsFromAnOlderPoller() throws {
        let plan = try schedule(
            """
            {
              "charge_window_active": false, "active_window": null, "next_window": null,
              "planned_windows": [], "lead_time_s": 300.0,
              "fetched_at": null, "last_error": null
            }
            """
        )
        XCTAssertNil(plan.normalMaximumVoltageV)
        XCTAssertEqual(plan.summaryLines(now: Date()), ["No charging slot planned."])
    }

    /// A poller from before the live charging figures still decodes.
    func testHypervoltDiagnosticsWithoutLiveFiguresDecode() throws {
        let json = """
            {
              "connected": true, "commanded_current_a": 32.0,
              "minimum_current_a": 6.0, "maximum_current_a": 32.0,
              "total_write_count": 0, "last_error": null
            }
            """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let hypervolt = try decoder.decode(HypervoltActuatorDetails.self, from: Data(json.utf8))
        XCTAssertNil(hypervolt.measuredCurrentA)
        XCTAssertNil(hypervolt.chargingPowerKw)
    }

    /// Between changes the poller leaves out the event log and, after the
    /// first sample, the configuration; a delta sample must still decode.
    func testDeltaSampleDecodesWithoutEventsOrConfiguration() throws {
        let control = """
            {
              "state": "Import regulating", "action": "Holding", "mode": "import",
              "desired_limit_w": 12000, "raw_voltage_v": 216.4,
              "filtered_voltage_v": 216.8, "reason": "inside deadband",
              "emergency": false,
              "voltage_source": "meter/PCC input register, raw PDU 33251",
              "estimated_voltage_sensitivity_v_per_kw": null,
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
            }
            """
        let details = try XCTUnwrap(
            StreamDecoder.decode(envelopeJSON(voltageControl: control)).voltageControl
        )
        XCTAssertNil(details.recentEvents)
        // Also sent only on change; MonitorStore carries the last plan forward.
        XCTAssertNil(details.octopusSchedule)
        XCTAssertEqual(details.importActuator.commandedW, 12_000)
    }

    func testActivityDescriptionExplainsHeldLimit() throws {
        let control = """
            {
              "state": "Export regulating", "action": "Holding", "mode": "export",
              "desired_limit_w": 4300, "raw_voltage_v": 259.4,
              "filtered_voltage_v": 259.2, "reason": "inside deadband",
              "emergency": false, "voltage_source": "meter/PCC",
              "estimated_voltage_sensitivity_v_per_kw": null,
              "import_actuator": {
                "pdu_address": 43488, "resolution_w": 100, "baseline_raw": 140,
                "last_commanded_raw": 140, "last_requested_raw": null,
                "last_write_at": null, "writes_last_hour": 0, "last_error": null
              },
              "export_actuator": {
                "pdu_address": 43074, "resolution_w": 100, "baseline_raw": 50,
                "last_commanded_raw": 43, "last_requested_raw": 43,
                "last_write_at": null, "writes_last_hour": 1, "last_error": null
              },
              "export_write_validated": true,
              "recent_events": [{
                "timestamp": "2026-09-04T12:00:00+01:00",
                "state": "Export regulating", "action": "Holding", "mode": "export",
                "message": "voltage is inside the export deadband", "voltage_v": 259.4,
                "grid_kw": 4.15, "limit_w": 4300,
                "previous_limit_w": 4300, "limit_delta_w": 0
              }],
              "daily_summary": null, "recovery_note": null
            }
            """
        let event = try XCTUnwrap(
            StreamDecoder.decode(envelopeJSON(voltageControl: control))
                .voltageControl?.recentEvents?.first
        )
        XCTAssertEqual(event.changeLabel, "Export limit held at 4.3 kW")
        XCTAssertFalse(event.timeLabel.isEmpty)
    }

    func testTimestampsParseWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(StreamDecoder.date(from: "2026-08-19T16:30:00.123+01:00"))
        XCTAssertNotNil(StreamDecoder.date(from: "2026-08-19T16:30:00+01:00"))
        XCTAssertNil(StreamDecoder.date(from: "not a timestamp"))
    }

    /// An older poller predates rejected_samples, so its absence must not fail
    /// the whole decode.
    func testHealthDecodesWithoutRejectedSamples() throws {
        let legacyHealth = """
            {
              "last_sample_age_s": 0.0,
              "latency_ms": 12.3,
              "successful_polls": 1,
              "total_failures": 0,
              "consecutive_failures": 0,
              "reconnects": 0
            }
            """
        let envelope = try StreamDecoder.decode(envelopeJSON(health: legacyHealth))
        XCTAssertNil(envelope.health.rejectedSamples)
    }

    /// A newer poller means this app is out of date. Failing loudly beats
    /// rendering fields that no longer mean what they used to.
    func testUnsupportedSchemaVersionIsRejected() {
        XCTAssertThrowsError(try StreamDecoder.decode(envelopeJSON(schemaVersion: 3))) { error in
            guard case StreamError.unsupportedSchema(let version) = error else {
                return XCTFail("expected StreamError.unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(version, 3)
        }
    }
}
