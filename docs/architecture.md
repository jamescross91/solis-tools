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
| Register map | `INVERTER_FAULTS`, `STATUS_LABELS`, the `*_SPANS` on `SolisClient` and the addresses inside `poll_slow` / `poll_fast` |
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
address. The polls do not call `_registers` directly: they pass raw address
spans to `_input_registers`, which reads them as one block through
`_input_block(first, last)` (itself `_registers(first + 1, last - first + 1)`)
and returns a mapping keyed by raw address, so `registers[33145]` is raw 33145.
The conversion is confined to that one helper.

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
`--slow-interval` (10 s) drives the rest.

Each poll is as few requests as the Modbus limit of 125 registers allows,
because a request through a Wi-Fi data logger is a round trip of tens of
milliseconds however few registers it carries. The fast poll reads raw
33073–33150 (33057–33150 with `--pv`), covering grid voltage, battery direction,
state of charge, BMS fault words, house load and battery power, then 33263–33264
(33251–33264 with meter voltage). Grid power cannot join the first block: 33073
to 33264 is 192 registers. The slow poll reads 33093–33120 (33035–33120 with
`--pv`) as one block. A device that answers a block read with a Modbus
exception is read span by span for that poll, and after two consecutive
refusals for the rest of the run; a transport failure propagates unchanged, so
a dead link is detected no later than before. The meter/PCC register is probed
once per run rather than on every fast poll, because firmware without it
answered the same read with illegal-address every half second.

After a connection failure the reconnect delay doubles from 1 s to 60 s. The
loop does not poll during that wait: PyModbus dials the host inside every read,
so polling through the backoff made a connect attempt every interval.

In stream mode the cadence adapts. `--idle-interval` names a slower interval
the poller uses while the consumer has written `attention off` to stdin and
`VoltageControlRuntime.needs_fast_telemetry()` is false, which is any state in
which nothing is being regulated or restored. The first sample showing
controllable flow puts the controller into a candidate state and the next wait
is already the fast one. `AttentionChannel` waits on stdin with `select` in
place of sleeping, so `attention on` ends the wait and the next poll happens
at once. Every sample carries the cadence it chose. Wakeups, not per-sample
CPU, decide the power draw of the poller, the Wi-Fi radio and the logger, so
this is the largest energy lever the app has.

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
owns telemetry, typed control and orderly restoration over one connection. The
only traffic in the other direction is the attention hint: the app writes
`attention on` or `attention off` to the poller's stdin as its popover opens
and closes, and passes `--idle-interval` from its settings. SIGPIPE is ignored
in the app so a hint written to a poller that has just exited is an error to
drop rather than a crash. A second poller would still open another connection
and must not be run against a logger limited to one session.

Stream framing and JSON decoding run outside the main actor. If several complete
frames arrive together, only the newest is delivered to the presentation layer;
the Python process has already evaluated every sample for control purposes.
The control section of a sample carries its configuration once per run and its
event log only when the log changes; `MonitorStore.receive` carries the last
event list forward so views never see the gap.

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

Chart preparation runs once per SwiftUI refresh. Lines are uniformly sampled to
at most 360 visible marks, while ranges and hover lookup retain the full history.
Hover dates snap to real samples and only publish state when that sample changes;
nearest-sample lookup is logarithmic because history remains time ordered.

History points are compact chart projections rather than full stream envelopes,
so repeated diagnostics and recent-event arrays are not retained per sample.
The buffers expire points with an advancing start index and compact only
occasionally, avoiding a full array shift on every steady-state insertion.

The menu label and dashboard use separate publication paths. While the popover
is closed, chart arrays continue accumulating privately but are not published to
SwiftUI; the label refreshes at most every five seconds unless connection state,
alarms, emergencies or control activity changes. Opening the popover publishes
one current dashboard snapshot and resumes live chart updates. Control polling
never depends on presentation visibility.

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
plus configured headroom. It follows genuine measured demand in both directions,
raising promptly but requiring a 500 W fall to persist for 30 seconds before
trimming; voltage safety reductions remain immediate. Import changes record
their settled grid response; that attributable response is removed from the
demand estimate so the controller cannot ratchet its own ceiling. Upward tracking
pauses while a command response is pending.

While regulation is active, the runtime checks the typed actuator every five
seconds and immediately before a normal write. A value changed by another Solis
client is adopted as the current limit and new journal baseline, and the demand
ceiling is re-anchored so optimisation continues from the manual value. This
adds at most one FC03 check per five seconds for the active actuator; it never
writes an arbitrary register. Suppressed command proposals become holding
samples and only real writes or operating-state transitions enter the event log.

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
