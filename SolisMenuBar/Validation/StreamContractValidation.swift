import Foundation

@main
struct StreamContractValidation {
    static func main() throws {
        let json = #"""
        {
          "schema_version": 1,
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
          "health": {
            "last_sample_age_s": 0.0,
            "latency_ms": 12.3,
            "successful_polls": 1,
            "total_failures": 0,
            "consecutive_failures": 0,
            "reconnects": 0
          },
          "error": null
        }
        """#

        let envelope = try StreamDecoder.decode(Data(json.utf8))
        precondition(envelope.schemaVersion == 1)
        precondition(envelope.reading.houseLoadKw == 1.58)
        precondition(envelope.reading.batterySocPercent == 93)
        precondition(envelope.reading.gridImportPositiveKw == 0.5)
        precondition(HistoryMetric.battery.value(from: envelope.reading) == 1.72)
        precondition(StreamDecoder.date(from: envelope.timestamp) != nil)
        print("Stream contract validated")
    }
}
