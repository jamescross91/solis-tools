# Architecture

Two programs, one repository, one interface between them.

```
                  Modbus TCP, function code 4 only
   inverter  <───────────────────────────────────────  solis_poll.py
   / logger                                                 │
                                                            │ one JSON object
                                                            │ per sample, stdout
                                                            ▼
                                                     SolisMenuBar.app
```

## solis_poll.py

One module, roughly a thousand lines, in five layers. It is deliberately a
single file: the whole program is smaller than the register map it decodes, and
a reader can follow a value from the wire to the screen without changing file.

| Layer | What it holds |
| --- | --- |
| Register map | `INVERTER_FAULTS`, `STATUS_LABELS`, and the addresses inside `poll_slow` / `poll_fast` |
| Client | `SolisClient` — connect, read, decode, range-check |
| Recording | `Recorder` — CSV/JSONL append, bounded history restore |
| Presentation | `render`, `sparkline`, `bar`, `fit`, `Palette` |
| Interfaces | `parse_args`, `print_once`, `stream_payload`, `main` |

### Register addressing

`SolisClient._registers(reference, count)` takes a **1-based reference** and
reads PDU address `reference - 1`. Everything else in the project — inline
comments, the README table, `fake_inverter.py` — uses the **raw** zero-based
address. `_registers(33136, 16)` therefore reads raw 33135–33150, and
`status[10]` is raw 33145.

The conversion exists because the original `mbpoll` shell prototype used 1-based
references, and preserving them made the Python port checkable line by line
against it.

### Polling cadence

Power flows change continuously; temperature, inverter state, fault words and
daily energy do not. `--interval` (0.5 s) drives the fast read;
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

The menu-bar app runs `solis-poll --stream-json` and parses its stdout. This is
worth keeping: the app holds no Modbus code, cannot write to an inverter, and the
poller stays independently runnable and testable. The cost is one poller per
consumer — a second consumer opens a second Modbus connection — which no current
use needs.

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

Chart history is memory-only and downsampled to one point per 30 seconds over a
six-hour window — about 720 points. Retaining every 0.5 s sample made the popover
slow to open after a few hours.

## Testing

| Layer | Where |
| --- | --- |
| Decoders, recorder, sparkline | `test_solis_poll.py`, with a fake client |
| Poll loop, reconnect, CLI, recording | `test_end_to_end.py`, real subprocess against `fake_inverter.py` |
| Python/Swift contract | `SolisMenuBar/Tests/SolisMenuBarTests/` |

`fake_inverter.py` is the reason the middle row exists. Nothing in the main loop
was reachable in a test before it, because it all needed an inverter on the LAN.
