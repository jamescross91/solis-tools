import XCTest

@testable import SolisMenuBar

/// The Python poller owns the JSON stream. These tests pin the shape the app
/// expects so a change on either side fails here rather than in the menu bar.
final class StreamContractTests: XCTestCase {
    private func envelopeJSON(
        schemaVersion: Int = 1,
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
              "error": null
            }
            """.utf8
        )
    }

    func testEnvelopeDecodesEveryFieldTheDashboardReads() throws {
        let envelope = try StreamDecoder.decode(envelopeJSON())

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.device.modelCode, 20)
        XCTAssertEqual(envelope.device.typeDefinition, 2001)
        XCTAssertTrue(envelope.device.profileValidated)
        XCTAssertEqual(envelope.reading.houseLoadKw, 1.58)
        XCTAssertEqual(envelope.reading.batterySocPercent, 93)
        XCTAssertNil(envelope.reading.pvKw)
        XCTAssertEqual(envelope.health.rejectedSamples, 0)
        XCTAssertNil(envelope.error)
    }

    /// Imports read positive in the menu bar; the poller reports exports positive.
    func testGridSignIsInvertedForDisplay() throws {
        let envelope = try StreamDecoder.decode(envelopeJSON())
        XCTAssertEqual(envelope.reading.gridKw, -0.5)
        XCTAssertEqual(envelope.reading.gridImportPositiveKw, 0.5)
    }

    func testHistoryMetricsReadTheirOwnFields() throws {
        let reading = try StreamDecoder.decode(envelopeJSON()).reading
        XCTAssertEqual(HistoryMetric.battery.value(from: reading), 1.72)
        XCTAssertEqual(HistoryMetric.house.value(from: reading), 1.58)
        XCTAssertEqual(HistoryMetric.voltage.value(from: reading), 250.0)
        XCTAssertNil(HistoryMetric.pv.value(from: reading))
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
        XCTAssertThrowsError(try StreamDecoder.decode(envelopeJSON(schemaVersion: 2))) { error in
            guard case StreamError.unsupportedSchema(let version) = error else {
                return XCTFail("expected StreamError.unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(version, 2)
        }
    }
}

final class HistoryBufferTests: XCTestCase {
    private func reading() throws -> InverterReading {
        try StreamDecoder.decode(
            Data(
                """
                {
                  "schema_version": 1,
                  "timestamp": "2026-08-19T16:30:00.123+01:00",
                  "device": {
                    "model_code": 20, "dsp_version": 1, "hmi_version": 1,
                    "protocol_version": 1, "type_definition": null,
                    "profile_validated": false
                  },
                  "reading": {
                    "grid_voltage_v": 250.0, "inverter_temperature_c": 30.0,
                    "inverter_status_code": 3, "inverter_status": "Generating",
                    "battery_soc_percent": 93, "house_load_kw": 1.58,
                    "battery_kw": 1.72, "battery_flow_kw": 1.72,
                    "battery_status": "Discharging", "grid_kw": -0.5,
                    "grid_status": "Importing", "pv_kw": null,
                    "pv_today_kwh": null, "alarms": []
                  },
                  "health": {
                    "last_sample_age_s": 0.0, "latency_ms": 1.0,
                    "successful_polls": 1, "total_failures": 0,
                    "consecutive_failures": 0, "reconnects": 0
                  },
                  "error": null
                }
                """.utf8
            )
        ).reading
    }

    /// Polling at 0.5 s once filled the chart with tens of thousands of points.
    func testSamplesCloserThanTheDisplayIntervalAreDropped() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sample = try reading()
        var buffer = HistoryBuffer()

        XCTAssertTrue(buffer.append(HistoryPoint(date: start, reading: sample)))
        XCTAssertFalse(
            buffer.append(HistoryPoint(date: start.addingTimeInterval(10), reading: sample))
        )
        XCTAssertTrue(
            buffer.append(HistoryPoint(date: start.addingTimeInterval(30), reading: sample))
        )
        XCTAssertEqual(buffer.points.count, 2)
    }

    func testPointsOlderThanTheRetentionWindowAreTrimmed() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sample = try reading()
        var buffer = HistoryBuffer()

        XCTAssertTrue(buffer.append(HistoryPoint(date: start, reading: sample)))
        XCTAssertTrue(
            buffer.append(HistoryPoint(date: start.addingTimeInterval(30), reading: sample))
        )
        let beyondRetention = start.addingTimeInterval(HistoryBuffer.retentionInterval + 30)
        XCTAssertTrue(buffer.append(HistoryPoint(date: beyondRetention, reading: sample)))

        XCTAssertEqual(buffer.points.count, 2)
        XCTAssertEqual(buffer.points.last?.date, beyondRetention)
    }
}
