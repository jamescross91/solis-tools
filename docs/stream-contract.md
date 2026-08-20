# The JSON stream contract

`solis-poll --stream-json` writes one JSON object per sample to stdout,
newline-delimited and flushed. It is the interface the macOS menu-bar app
consumes, and the only supported integration point.

```sh
solis-poll --host 192.168.1.57 --stream-json
```

Produced by `stream_payload` in `solis_poll.py`; consumed by `StreamDecoder` and
the types in `SolisMenuBar/Sources/SolisMenuBar/Models.swift`.

## Shape

```json
{
  "schema_version": 1,
  "timestamp": "2026-08-19T16:30:00.123+01:00",
  "device": {
    "model_code": 12695, "dsp_version": 26, "hmi_version": 46,
    "protocol_version": 1, "type_definition": 8193, "profile_validated": true
  },
  "reading": {
    "grid_voltage_v": 242.7, "inverter_temperature_c": 52.4,
    "inverter_status_code": 3, "inverter_status": "Generating",
    "battery_soc_percent": 78, "house_load_kw": 2.32,
    "battery_kw": 2.5, "battery_flow_kw": 2.5, "battery_status": "Discharging",
    "grid_kw": -0.5, "grid_status": "Importing",
    "pv_kw": null, "pv_today_kwh": null,
    "alarms": [{ "code": "1041", "message": "ARC-FAULT", "severity": "fault" }]
  },
  "health": {
    "last_sample_age_s": 0.0, "latency_ms": 12.3, "successful_polls": 1,
    "total_failures": 0, "consecutive_failures": 0, "reconnects": 0,
    "rejected_samples": 0
  },
  "error": null
}
```

## Conventions worth knowing

**Names.** Python emits snake_case; Swift decodes with `.convertFromSnakeCase`.
`grid_voltage_v` becomes `gridVoltageV`, `pv_today_kwh` becomes `pvTodayKwh`.

**Signs.** `grid_kw` is **positive when exporting**. `battery_kw` is always the
magnitude, with direction in `battery_status`; `battery_flow_kw` is signed,
positive when discharging. The menu bar displays imports as positive via
`gridImportPositiveKw`, which is `-gridKw` — a display choice, not a second
convention in the data.

**Nullable fields.** `pv_kw` and `pv_today_kwh` are null unless `--pv` is given.
`type_definition` is null on firmware that does not expose register 35000.
`last_sample_age_s` is null before the first success. `error` carries the last
failure while the previous good reading is still being served, so a non-null
`error` with a populated `reading` is normal and means degraded, not broken.

**Cadence.** One object per `--interval`, emitted whether or not the poll
succeeded — a failed poll re-emits the last good reading with `error` set. Fields
sourced from the slow poll only change every `--slow-interval`.

## Changing it

The version is `schema_version`, and the consumer enforces it:
`StreamDecoder.decode` throws `StreamError.unsupportedSchema` for anything it
does not recognise, so a newer poller with an older app fails with an upgrade
message rather than silently mis-rendering.

| Change | Version bump | Notes |
| --- | --- | --- |
| Add a field | No | Make it `Optional` in Swift so an older poller still decodes |
| Add an enum-like string value | No | Consumers must tolerate unknown values |
| Rename or remove a field | **Yes** | Breaks every existing consumer |
| Change a unit, scale or sign | **Yes** | Silently wrong is worse than broken |

When you bump it, change `VERSION`-adjacent constants in both places:
`schema_version` in `stream_payload`, and
`StreamDecoder.supportedSchemaVersion` in `Models.swift`.

Every field is pinned in
`SolisMenuBar/Tests/SolisMenuBarTests/StreamContractTests.swift`, including a
case asserting that an older poller without `rejected_samples` still decodes.
Add to those tests in the same change; `swift test` runs them, and CI runs
`swift test` on macOS.

## Consuming it from a script

```sh
solis-poll --host 192.168.1.57 --stream-json \
  | jq -r 'select(.error == null)
           | [.timestamp, .reading.house_load_kw, .reading.battery_soc_percent]
           | @tsv'
```

For a one-shot reading in a health check, `--once` prints `key=value` lines and
exits, which is cheaper to parse and does not need `jq`.
