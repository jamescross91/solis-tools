import XCTest

@testable import SolisMenuBar
import SolisHubKit

/// The stream contract tests moved to SolisHubKit with the models. What stays
/// here is the menu bar's own state: stored settings and the chart buffers.
final class StoredConfigurationTests: XCTestCase {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let suite = UserDefaults(suiteName: "solis-tests-\(UUID().uuidString)")!
        for (key, value) in values {
            suite.set(value, forKey: key)
        }
        return suite
    }

    func testNoHostMeansNothingToStart() {
        XCTAssertNil(MonitorConfiguration.stored(defaults([:])))
        XCTAssertNil(MonitorConfiguration.stored(defaults(["host": "   "])))
    }

    func testStoredSettingsAreReadWithTheDashboardDefaults() throws {
        let configuration = try XCTUnwrap(
            MonitorConfiguration.stored(defaults(["host": " 192.168.1.57 "]))
        )
        XCTAssertEqual(configuration.host, "192.168.1.57")
        XCTAssertEqual(configuration.port, 502)
        XCTAssertEqual(configuration.slave, 1)
        XCTAssertEqual(configuration.interval, 2)
        XCTAssertEqual(configuration.slowInterval, 10)
        XCTAssertEqual(configuration.idleInterval, 5)
        XCTAssertEqual(configuration.inverterMaxKw, 10)
        XCTAssertEqual(configuration.gridMaxKw, 23)
        XCTAssertFalse(configuration.pvEnabled)
        XCTAssertFalse(configuration.dynamicVoltageEnabled)
        XCTAssertTrue(configuration.dynamicImportEnabled)
        XCTAssertFalse(configuration.dynamicExportEnabled)
        XCTAssertEqual(configuration.minimumVoltage, 215)
        XCTAssertEqual(configuration.maximumVoltage, 258)
        XCTAssertEqual(configuration.importHeadroomKw, 2)
        XCTAssertEqual(configuration.minimumWriteInterval, 5)
        XCTAssertFalse(configuration.hypervoltEnabled)
        XCTAssertEqual(configuration.evPriority, "battery")
        XCTAssertEqual(configuration.hypervoltCredentialsPath, "")
        XCTAssertFalse(configuration.octopusEnabled)
        XCTAssertEqual(configuration.octopusCredentialsPath, "")
    }

    /// A too-short interval would make the poller hammer the inverter.
    func testUnreasonableStoredValuesAreClamped() throws {
        let configuration = try XCTUnwrap(
            MonitorConfiguration.stored(
                defaults([
                    "host": "inverter.local",
                    "pollInterval": 0.01,
                    "idlePollInterval": 0.1,
                    "slowInterval": 0.0,
                    "inverterMaxKw": 0.0,
                    "gridMaxKw": -5.0,
                    "importHeadroomKw": -1.0,
                    "pvEnabled": true,
                ])
            )
        )
        XCTAssertEqual(configuration.host, "inverter.local")
        XCTAssertEqual(configuration.interval, 0.5)
        // The idle interval can never undercut the fast one.
        XCTAssertEqual(configuration.idleInterval, 0.5)
        XCTAssertEqual(configuration.slowInterval, 1)
        XCTAssertEqual(configuration.inverterMaxKw, 0.1)
        XCTAssertEqual(configuration.gridMaxKw, 0.1)
        XCTAssertEqual(configuration.importHeadroomKw, 0)
        XCTAssertTrue(configuration.pvEnabled)
    }
}

final class HistoryBufferTests: XCTestCase {
    func testChartSamplingCapsMarksAndPreservesTheTimeBounds() {
        let values = Array(0..<1_000)
        let sampled = chartSamples(values, maximumCount: 360)
        XCTAssertEqual(sampled.count, 360)
        XCTAssertEqual(sampled.first, 0)
        XCTAssertEqual(sampled.last, 999)
    }

    private func reading() throws -> InverterReading {
        try StreamDecoder.decode(
            Data(
                """
                {
                  "schema_version": 2,
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

    func testHistoryMetricsReadTheirOwnFields() throws {
        let sample = try reading()
        XCTAssertEqual(HistoryMetric.battery.value(from: sample), 1.72)
        XCTAssertEqual(HistoryMetric.house.value(from: sample), 1.58)
        XCTAssertEqual(HistoryMetric.voltage.value(from: sample), 250.0)
        XCTAssertNil(HistoryMetric.pv.value(from: sample))
    }

    /// The Grid card and the Grid chart plotted the same value with opposite
    /// signs, because the chart used the poller's export-positive convention.
    func testGridChartAndGridCardAgreeOnSign() throws {
        let sample = try reading()
        XCTAssertEqual(
            HistoryMetric.grid.value(from: sample),
            sample.gridImportPositiveKw
        )
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

    func testControlHistoryRetainsOnlyItsTimeWindowAfterCompaction() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sample = try reading()
        var buffer = ControlHistoryBuffer()

        for offset in 0...2_000 {
            buffer.append(
                HistoryPoint(
                    date: start.addingTimeInterval(TimeInterval(offset)),
                    reading: sample
                )
            )
        }

        XCTAssertEqual(buffer.points.count, 1_801)
        XCTAssertEqual(buffer.points.first?.date, start.addingTimeInterval(200))
        XCTAssertEqual(buffer.points.last?.date, start.addingTimeInterval(2_000))
    }

    // MARK: Merging hub history

    private let base = Date(timeIntervalSince1970: 1_000)

    private func point(_ offset: TimeInterval, _ sample: InverterReading) -> HistoryPoint {
        HistoryPoint(date: base.addingTimeInterval(offset), reading: sample)
    }

    private func offsets(_ points: [HistoryPoint]) -> [TimeInterval] {
        points.map { $0.date.timeIntervalSince(base) }
    }

    /// The hub's backfill overlaps the samples already received live, and a
    /// point shared by both must appear once.
    func testBackfillDeduplicatesByTimestamp() throws {
        let sample = try reading()
        var control = ControlHistoryBuffer()
        control.append(point(120, sample))
        control.append(point(150, sample))
        control.merge(backfill: [point(60, sample), point(120, sample), point(90, sample), point(90, sample)])
        XCTAssertEqual(offsets(control.points), [60, 90, 120, 150])

        var long = HistoryBuffer()
        long.append(point(120, sample))
        long.append(point(180, sample))
        long.merge(backfill: [point(60, sample), point(120, sample), point(0, sample)])
        XCTAssertEqual(offsets(long.points), [0, 60, 120, 180])
    }

    func testControlMergeOrdersBackfillBeforeLivePoints() throws {
        let sample = try reading()
        var buffer = ControlHistoryBuffer()
        buffer.append(point(300, sample))
        buffer.append(point(310, sample))
        buffer.merge(backfill: [point(200, sample), point(100, sample), point(250, sample)])
        XCTAssertEqual(offsets(buffer.points), [100, 200, 250, 300, 310])

        buffer.merge(backfill: [])
        XCTAssertEqual(offsets(buffer.points), [100, 200, 250, 300, 310])
    }

    /// Retention is measured back from the newest point, so a merge cannot
    /// resurrect history older than the window the live samples have reached.
    func testControlMergeKeepsOnlyTheRetentionWindow() throws {
        let sample = try reading()
        var buffer = ControlHistoryBuffer()
        buffer.append(point(3_000, sample))
        buffer.merge(backfill: [point(0, sample), point(1_000, sample), point(1_300, sample), point(1_700, sample)])
        XCTAssertEqual(offsets(buffer.points), [1_300, 1_700, 3_000])
    }

    func testHistoryMergeOrdersDedupesAndRetainsLikeTheControlBuffer() throws {
        let sample = try reading()
        let window = HistoryBuffer.retentionInterval
        var buffer = HistoryBuffer()
        buffer.append(point(window + 3_600, sample))
        buffer.merge(
            backfill: [
                point(3_700, sample), point(0, sample), point(60, sample), point(3_700, sample),
            ]
        )
        // 0 and 60 fall outside the window measured from the newest point.
        XCTAssertEqual(offsets(buffer.points), [3_700, window + 3_600])
    }

    func testHistoryMergeThinsBackfillToTheDisplayInterval() throws {
        let sample = try reading()
        var buffer = HistoryBuffer()
        buffer.append(point(500, sample))
        buffer.merge(backfill: [point(0, sample), point(10, sample), point(40, sample)])
        // 10 is within thirty seconds of 0, as a live sample would have been.
        XCTAssertEqual(offsets(buffer.points), [0, 40, 500])
    }

    func testHistoryPointProjectsOnlyChartValues() throws {
        let sample = try reading()
        let point = HistoryPoint(date: Date(timeIntervalSince1970: 1_000), reading: sample)

        XCTAssertEqual(point.houseLoadKw, 1.58)
        XCTAssertEqual(point.batteryFlowKw, 1.72)
        XCTAssertEqual(point.gridImportPositiveKw, 0.5)
        XCTAssertNil(point.controlReason)
    }
}
