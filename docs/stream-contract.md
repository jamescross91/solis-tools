# The JSON stream contract

When voltage control has no recorded samples, its optional `daily_summary` field
is JSON `null`, never an empty object. A populated summary retains all required
fields; older streams may omit it entirely.

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
    "protocol_version": 1, "type_definition": 8193, "profile_validated": true,
    "remote_dispatch_supported": true, "remote_dispatch_version": 1
  },
  "reading": {
    "grid_voltage_v": 242.7, "meter_voltage_v": 242.5,
    "inverter_temperature_c": 52.4,
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
  "voltage_control": null,
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
`meter_voltage_v` is null unless `--meter-voltage` or dynamic control is enabled.
`type_definition` is null on firmware that does not expose register 35000.
`last_sample_age_s` is null before the first success. `error` carries the last
failure while the previous good reading is still being served, so a non-null
`error` with a populated `reading` is normal and means degraded, not broken.

`voltage_control` is null unless dynamic control is enabled. When populated it
contains the state/action/reason, raw and filtered PCC voltage, desired limit,
typed import/export actuator diagnostics, validation gate, write count, recent
events and recovery note. The object is additive and Swift treats it as
optional, so an older read-only poller still decodes.

### Voltage-control fields

| Field | Meaning |
| --- | --- |
| `state`, `action`, `reason` | Human-readable decision and explanation; tolerate new values |
| `mode` | `import`, `export`, or null |
| `desired_limit_w` | Requested limit in watts, or null; not proof of an applied write |
| `raw_voltage_v`, `filtered_voltage_v` | PCC voltage in volts, nullable when unavailable |
| `emergency` | Whether the decision requests emergency intervention |
| `configuration` | Effective controller configuration in snake_case; see README control defaults |
| `voltage_source` | Description of the meter/PCC register source |
| `estimated_voltage_sensitivity_v_per_kw` | Recent measured response estimate, or null |
| `import_actuator`, `export_actuator` | Register diagnostics described below |
| `export_write_validated` | Whether matching endpoint evidence permits export writes; UI may use this gate but must not infer it |
| `import_demand_ceiling_w` | Current import-session demand ceiling; starts at the activation peak plus headroom and may only move down, or null outside a session |
| `recent_events` | Up to 20 recent events from the running process |
| `daily_summary` | Current local-day aggregates, refreshed approximately once a minute, or null |
| `recovery_note` | Startup recovery explanation, or null |

Actuator diagnostics contain `pdu_address`, `resolution_w`, `baseline_raw`,
`last_commanded_raw`, `last_requested_raw`, `last_write_at`, `writes_last_hour`,
`total_write_count` and `last_error`. Raw limits require multiplication by
`resolution_w`. Requested values may be suppressed by write guards; command
values reflect confirmed or reconciled readback. Write counts include attempted
transmissions with uncertain replies and reset when the process restarts.

Events contain `timestamp`, `state`, `action`, `mode`, `message`, `voltage_v`,
`grid_kw`, `limit_w`, `previous_limit_w` and `limit_delta_w`. The last three
fields make held, increased, reduced and restored limits explicit without
parsing prose. Populated daily summaries contain `lowest_voltage_v`,
`highest_voltage_v`, `import_regulating_s`, `export_regulating_s`,
`emergency_interventions`, `maximum_import_kw`, `maximum_export_kw` and
`average_grid_kw`. These are observed sample aggregates, not an energy meter.

The internal monotonic meter timestamp is not serialised. The envelope's health
age describes the last completed poll, not the controller's meter freshness
test. Consumers should show control state and errors rather than infer write
permission from envelope age alone. Additive decoding compatibility does not
imply executable compatibility: deploy the app and poller together so all CLI
flags passed by the app are recognised.

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
