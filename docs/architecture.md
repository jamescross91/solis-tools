# Architecture

Two programs, one repository, one interface between them.

```
             Modbus TCP: FC04 telemetry; typed FC03/FC06 control
   inverter  <───────────────────────────────────────  solis_poll.py
   / logger                                                 │
                                                            │ one JSON object
                                                            │ per sample, stdout
                                                            ▼
                                                     SolisMenuBar.app
```

## Python poller and controller

`solis_poll.py` retains the register decoder, persistent connection, recording,
terminal presentation and process lifecycle. `voltage_control.py` contains the
transport-independent configuration, filter, state detector, controller and
crash journal, so safety behaviour can be tested with deterministic samples.

| Layer | What it holds |
| --- | --- |
| Register map | `INVERTER_FAULTS`, `STATUS_LABELS`, and the addresses inside `poll_slow` / `poll_fast` |
| Client | `SolisClient` — connect, read, decode, range-check |
| Recording | `Recorder` — CSV/JSONL append, bounded history restore |
| Presentation | `render`, `sparkline`, `bar`, `fit`, `Palette` |
| Interfaces | `parse_args`, `print_once`, `stream_payload`, `main` |
| Voltage control | Typed actuators, baseline ownership, SQLite minute history and event log |

### Dynamic-voltage path

```text
raw 33251 PCC voltage + existing battery/grid telemetry
        -> state detector -> EWMA/filter and raw safety check
        -> adaptive controller -> dwell and write-rate guard
        -> typed import/export actuator -> raw holding PDU 43488/43074, FC06
```

All transactions use the same `SolisClient` connection. The import actuator
reads its live baseline with FC03, suppresses duplicate writes, clamps values to
1–14 kW by default, verifies each write, and restores only while the register
still equals its last command. Export register 43074 has the same typed boundary,
but both configuration and the write method refuse operation without evidence
scoped to the normalised host, port and Modbus unit. The record must describe a
reduced limit, observed physical response and successful restoration using the
expected address and 100 W scale. Missing, invalid or mismatched evidence fails
closed. No arbitrary address/value operation is exposed to controller or UI code.

### Register addressing

`SolisClient._registers(reference, count)` takes a **1-based reference** and
reads PDU address `reference - 1`. Everything else in the project — inline
comments, the README table, `fake_inverter.py` — uses the **raw** zero-based
address. `_registers(33136, 16)` therefore reads raw 33135–33150, and
`status[10]` is raw 33145.

The conversion exists because the original `mbpoll` shell prototype used 1-based
references, and preserving them made the Python port checkable line by line
against it.

Dynamic-control addresses were verified as raw zero-based PDU addresses.
Holding-register calls therefore use 43488/43074 exactly. PCC voltage raw 33251
still passes through `_registers`, so its call-site reference is 33252.

### Polling cadence

Power flows change continuously; temperature, inverter state, fault words and
daily energy do not. `--interval` (0.5 s) drives the fast read;
new menu-bar configurations explicitly select 2 s instead.
`--slow-interval` (10 s) drives the rest. Contiguous registers are read in one
request: the 16-register block at raw 33135 carries battery direction, state of
charge, BMS fault words, house load and battery power together.

A slow-metric failure sets `slow_metrics = None`, so the next iteration refetches
rather than carrying stale state forward.

### Plausibility and its two meanings

`checked(value, low, high, name)` raises `ImplausibleReadingError` when a decoded
value is physically impossible. The same signal means two different things:

- **before the first successful poll** — the register map is wrong. Stop, and say
  so. `--skip-profile-check` overrides.
- **after** — the map is proven, so this is a corrupt frame. Discard the sample,
  keep the connection, count it in `rejected_samples`.

Treating both as fatal is why one bad frame used to end a multi-week run.

### Recording and history

Both `--csv` and `--jsonl` are append-only, flushed per sample, and grow by
roughly 17 MB and 58 MB a day at the default interval. Only the last six hours
are ever restored, so `Recorder._tail_lines` walks backwards from the end of the
file in 1 MiB chunks until it passes the cut-off. Reading the whole file instead
made startup scale with uptime.

The restore path is lossy by design: `Recorder.CSV_FIELDS` is a fixed header that
`_validate_csv_header` enforces, so alarm severity is recovered by looking the
code back up in `severity_for_code` rather than by widening the header and
invalidating every existing recording.

## The subprocess boundary

The menu-bar app runs `solis-poll --stream-json` and parses its stdout. The app
holds no Modbus transport code: it supplies validated settings, while the poller
owns telemetry, typed control and orderly restoration over one connection. A
second poller would still open another connection and must not be run against a
logger limited to one session.

`MonitorStore` owns the child process: it locates the binary, streams
newline-delimited JSON, retries with backoff, and translates stream state into
`.connecting` / `.connected` / `.degraded` / `.failed`. See
[stream-contract.md](stream-contract.md) for the payload and how to change it.

## SolisMenuBar

| File | Responsibility |
| --- | --- |
| `Models.swift` | The stream contract, `HistoryBuffer`, `HistoryMetric`, decoding |
| `MonitorStore.swift` | Child-process lifecycle and observable state |
| `DashboardView.swift` | Popover: metric cards, chart, alarms, settings |
| `SolisMenuBarApp.swift` | `MenuBarExtra` scene and the compact menu-bar label |

General chart history is memory-only and downsampled to one point per 30 seconds
over a 24-hour window — about 2,880 points. Retaining every poll sample for that
long made the popover slow to open.

When dynamic control is enabled, a separate native-resolution ring retains the
last 30 minutes for the voltage/power control chart. The poller persists
one-minute aggregates and sparse state/change events in a private SQLite file,
with 30-day retention by default. A small private JSON journal records baseline
ownership and unclean-shutdown recovery state.

Chart axes fit observed values with meaningful headroom rather than forcing
voltage and temperature through zero. Voltage-control charts select the relevant
high- or low-voltage operating band, distinguish signed grid flow from the active
actuator limit, and expose exact samples on pointer hover. Activity events carry
the previous, current and delta limit so the UI can state what changed and why.

Export validation is a separate endpoint-hashed JSON record in the same private
state directory. It is installation evidence, not recovery state: changing the
endpoint selects a different record, while `--export-control-validation` may
override only its path, not the identity or register-semantic checks. The stream
reports the resulting gate so the menu-bar toggle is enabled only for the active
matching configuration.

Control acquisition carries a monotonic meter-request timestamp through the
reading; envelope emission time is not evidence of fresh voltage. The runtime
checks freshness again immediately before writes, including baseline restoration.
The endpoint-scoped journal uses write-ahead pending commands, file and directory
fsync, atomic replacement and a process-lifetime endpoint lock. Readback resolves
an interrupted write to either the prior or intended value; other values suspend
recovery. Recovered active-session baselines constrain the actuator maximum.
Import regulation starts a per-session ceiling at initial measured grid demand
plus configured headroom. It trims excessive allowance immediately and follows
measured demand downwards, but cannot ratchet upwards as released demand changes.

SQLite telemetry transactions are batched for 60 seconds, with event and close
flushes. Safety-journal writes are independent and durable before transmission.
Sensitivity observations use signed measured grid-power responses and expire
even if no later command occurs. The menu-bar lifecycle serialises asynchronous
stop/start requests, drains pipes until exit and refuses replacement on timeout.

## Release boundary

`scripts/release.py` prepares a reproducible source archive and formula in one
release PR. The Release candidate workflow builds a universal macOS app and
stores its source digest and binary checksum; preparation attaches that metadata
to the same PR. Formula and metadata are excluded from the source archive to
avoid checksum recursion. CI verifies candidate Homebrew installs before merge.
Successful main CI triggers publication of the approved bytes, followed by
public-URL Homebrew tests. Only publication has write permissions; there is no
bot commit to protected main. Draft creation uses GitHub's returned release
object directly because its lookup endpoints are briefly eventually consistent.
See [releasing.md](releasing.md).

## Test coverage

| Layer | Where |
| --- | --- |
| Decoders, recorder, sparkline | `test_solis_poll.py`, with a fake client |
| Control, freshness, write recovery, ownership and history | `test_voltage_control.py`, deterministic samples and fake clients |
| Poll loop, reconnect, CLI, recording | `test_end_to_end.py`, real subprocess against `fake_inverter.py` |
| Python/Swift contract | `SolisMenuBar/Tests/SolisMenuBarTests/` |

`fake_inverter.py` is the reason the middle row exists. Nothing in the main loop
was reachable in a test before it, because it all needed an inverter on the LAN.
