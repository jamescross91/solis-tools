# Changelog

Notable user-visible changes. This project follows [semantic
versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Optional Hypervolt EV charger integration for dynamic voltage control.
  `--hypervolt-enable` adds a second, cloud-connected lever alongside the
  existing Solis import limit; `--ev-priority` (`battery`, `ev` or
  `balanced`) decides which side is cut and restored first when grid voltage
  needs protecting. While the car is confirmed charging, `--ev-minimum-voltage`
  and `--ev-maximum-voltage` narrow the operating band to Hypervolt's own
  tighter protection limits, and the car charging is on its own enough to
  activate import regulation. Credentials are a Hypervolt refresh token only,
  saved at 0600 permissions and obtained once with the `hypervolt-login`
  command, either from a terminal or the menu-bar app's own sign-in form; a
  lost cloud connection is read as "not charging" and a failed command leaves
  battery regulation unaffected. See `docs/hypervolt-integration.md`. The
  menu-bar app gained matching settings, a sign-in form and a status line
  showing EV charging state and commanded current.

### Fixed

- Wait out the reconnect backoff instead of polling through it. PyModbus dials
  the host inside every read, so each interval of a backoff made another
  connect attempt and blocked for the connect timeout; the displayed wait was
  only a message.
- Probe the optional meter/PCC voltage register once per run. Firmware without
  it answered the same read with illegal-address on every fast poll.
- Treat a Hypervolt WebSocket connection reset by the peer the same as a
  clean close. A TCP reset (rather than a graceful FIN) surfaced as a bare
  `ConnectionResetError` that escaped the poller's `HypervoltError` handling
  instead of the intended fail-closed "not charging" state.

### Changed

- Slow the stream while nobody is watching. With `--idle-interval`, the poller
  idles at that interval while the consumer has written `attention off` to its
  stdin and dynamic control has nothing to regulate or restore; `attention on`
  is answered with a poll at once. The menu-bar app sends these as its popover
  closes and opens and gains an "Idle refresh" setting, 5 s by default, so a
  closed menu bar polls the inverter and wakes the app less than half as often.
  Control activity always uses the fast interval.
- Stream schema 2: every sample carries a `cadence` object, the control
  `configuration` is sent in the first sample of a run only, and
  `recent_events` only when the event log changes, which removes about two
  thirds of the bytes the app decoded per sample. Deploy the app and poller
  together; an older app refuses the new schema with an upgrade message.
- Read each poll as one block per register region: two requests for the fast
  poll and one for the slow poll, instead of up to five and three. Every request
  is a full round trip through the data logger, so poll latency and radio time
  fall with the request count. A logger that refuses a block is read span by
  span and decodes the same values.
- Keep the six-hour graph history only when the terminal dashboard is drawn.
  The JSON stream consumer keeps its own history, so the poller behind the
  menu-bar app no longer retains a copy.

## 0.5.4

### Fixed

- Start configured monitoring from the application lifecycle so a Homebrew or
  login launch resumes polling without waiting for the menu extra to be opened.
- Adopt manual import or export limit changes as the new live and recovery
  baseline, re-anchor import headroom and continue dynamic optimisation from the
  selected value instead of restoring or immediately overwriting it.
- Require a 500 W demand reduction to persist for 30 seconds before trimming the
  import ceiling, while still raising it promptly and preserving immediate
  voltage-safety action. Suppressed proposals now appear as holding state and no
  longer flood the activity log as increases and reductions that never occurred.

## 0.5.3

### Fixed

- Cap each import-regulation session at its initial measured grid demand plus a
  configurable 2 kW headroom, preventing unused grid peak-shaving allowance
  ratcheting towards the hard maximum. The ceiling tracks genuine demand down
  and back up, discounting settled demand caused by its own commands, and trims
  excess allowance without weakening voltage-triggered reductions.
- Plot the active export actuator with the correct sign instead of always
  showing the import actuator, and use data-driven scales that no longer flatten
  voltage and temperature against zero.
- Reduce menu-bar energy use by stopping closed-dashboard chart publications,
  refreshing the compact menu-bar display at most every five seconds unless an
  alert or control event changes, decoding telemetry away from the main actor,
  coalescing buffered frames, retaining compact chart-only samples in amortised
  constant-time buffers, publishing one dashboard snapshot per sample, and
  reusing timestamp parsers. Chart data is calculated once per refresh, visible
  marks are limited to display resolution, paths are linear, and hover state
  changes only when the nearest real measurement changes.
- Aggregate voltage-history samples in memory and write each minute to SQLite
  once, instead of updating the same database row on every control sample.
- Prevent automatic publication failing when GitHub briefly hides a newly
  created draft from both release lookup endpoints. The publisher now continues
  from the validated release object returned by the creation request.

### Changed

- Expand voltage-control activity with local times, previous and new limits,
  signed deltas, measurements and reasons.
- Add chart legends, operating-band annotations, latest-value labels and pointer
  hover tooltips with exact timestamps and measurements.

## 0.5.2

### Changed

- Enable export regulation only for an inverter endpoint with a matching live
  validation record. The 7 September hardware test confirmed raw holding PDU
  address 43074 at 100 W per unit, observed a 3 kW limit, and restored the
  original 5 kW baseline before normal monitoring resumed.
- Make the menu-bar export setting available after the connected endpoint's
  validation is reported by the poller; missing, malformed, mismatched or
  unrestored evidence remains fail-closed.
- Remove stale prebuilt metadata when a new release is first prepared, before
  attaching the matching candidate later in that same PR.
- Retrieve newly created draft releases from the release list when GitHub's
  by-tag endpoint temporarily reports them as missing, allowing asset upload and
  publication to complete.

## 0.5.1

### Changed

- Prepare releases in one PR containing version, changelog, source checksum and
  prebuilt macOS package metadata. Successful merged CI automatically publishes
  verified immutable assets without a follow-up formula PR.
- Add universal prebuilt macOS app candidates so future stable releases avoid
  Swift compilation during Homebrew installation; retain source builds for HEAD.
- Document the short `brew install solis-tools` command after tap/trust setup.

## 0.5.0

### Upgrade notes

- Dynamic voltage control remains off until explicitly enabled. Export writes
  remain locked pending installation validation; flash-write endurance has not
  been confirmed by local or CI tests.
- Upgrade the poller and menu-bar app together. Legacy recovery journals without
  inverter identity require verification before control can start. Stale-data
  shutdown defers restoration and retains the journal for later fresh recovery.

### Fixed

- Measure control freshness from meter acquisition and defer stale shutdown
  restoration while preserving recovery state.
- Persist pending writes before transmission, reconcile uncertain replies and
  scope recovery journals and exclusive controller ownership to the endpoint.
- Cap active crash recovery at the captured baseline and quantise actuator
  limits without exceeding configured bounds.
- Keep menu-bar shutdown responsive, drain subprocess output until exit and
  report a pending stop instead of replacing a running controller.
- Emit null empty-history summaries, batch telemetry commits and expire voltage
  sensitivity estimates based on measured rather than commanded power changes.

### Added

- Disabled-by-default Dynamic Grid Voltage Control for grid charging, using the
  meter/PCC voltage at raw input PDU address 33251, an EWMA, debounced operating
  states, asymmetric steps, dwell, stale-data recovery and recent adaptive
  voltage sensitivity.
- A typed import actuator for raw holding PDU address 43488 using FC03/FC06,
  verified 100 W scaling, read-back, write-rate limiting, ownership-safe baseline
  restoration and an unclean-shutdown journal. The export actuator is present
  but its writes remain blocked pending live validation of 43074.
- Menu-bar settings, live control status, diagnostics, recent events and a
  native-resolution 15-minute voltage/power chart.
- Private SQLite minute aggregates and sparse control events with bounded
  retention, plus fake-inverter FC03/FC06 coverage.

### Security

- Replaced the blanket read-only policy with a closed write whitelist. No
  arbitrary register writer is exposed; only typed 43488 import commands are
  enabled, and 43074 remains validation-gated.

## 0.4.0

### Fixed

- A single out-of-range register value no longer ends the process. Range
  failures are fatal only before the first successful poll, where they really do
  mean the register map is wrong; afterwards the sample is discarded, the
  connection is kept, and the count appears in the dashboard and the JSON
  stream. One corrupt Modbus frame previously terminated an unattended run.
- Register 35000 was tested both as a packed hex family byte and as leading
  decimal digits, and either match rejected the inverter. Those are
  incompatible readings of the same 16 bits, and 2368 values were rejected
  outright, including all of 1000–1099 and 10000–10999. Only the packed form
  rejects now, and `--skip-profile-check` overrides it.
- A failed first poll exited immediately, so a transient blip during startup was
  terminal. Startup now allows several attempts and reports that it could not
  obtain a reading rather than blaming the register map.
- Restoring history read the whole recording to recover six hours. A 30-day CSV
  took 16.7 s to parse and discarded 99.17% of it; it now reads backwards from
  the end of the file and takes 0.77 s on 580 MB. JSONL restore is bounded too.
- Restored alarms all came back as warnings, so a recovered fault did not raise
  the fault banner.
- The connection-health line was a fixed 90 characters and wrapped on an
  80-column terminal, breaking the fixed-height redraw. It and the footer now
  pick the widest variant that fits; 60 columns is the narrowest supported width.
- `--once` crashed formatting today's PV energy when only instantaneous PV power
  was available.
- The menu-bar app showed `Model 12,695` where the terminal showed `12695`,
  because locale grouping was applied to an identifier.
- The menu-bar app stayed dead until relaunch if `solis-poll` was missing when
  it started, for example during a Homebrew upgrade. It now retries, backing off
  to a minute rather than respawning every five seconds.
- The menu-bar app ignored `schema_version` and would have rendered a newer
  stream as though the fields still meant the same thing. It now reports that an
  upgrade is needed.
- Menu-bar chart ticks all showed the same hour and minute until the window was
  minutes wide.
- The menu-bar status-refresh interval was stored and passed to `solis-poll`
  with no control to set it.

### Security

- New recording files are created `0600` rather than `0644`. A half-second power
  trace shows when a house is empty and what is running in it.

### Added

- `--skip-profile-check` continues when the register map cannot be confirmed.
- `--host` accepts hostnames and mDNS names, not only IP literals.
- `rejected_samples` in the JSON stream and the dashboard's health line.
- `fake_inverter.py`, a Modbus TCP stand-in, so the monitor, the menu-bar app
  and the tests all run with no hardware. `make demo` starts it.
- `test_end_to_end.py` drives the real CLI against it, covering the poll loop,
  reconnect, recording and history restore for the first time.
- `swift test` works: the hand-compiled stream-contract check is a real test
  target.
- `Makefile` running every check CI runs, `CLAUDE.md` for contributors and
  coding agents, and `docs/architecture.md`, `docs/releasing.md`,
  `docs/stream-contract.md`.
- `scripts/version.py` makes `solis_poll.VERSION` the only place a version is
  written, and CI fails when a copy drifts.
- A release workflow builds and verifies the tarball on a tag.

### Changed

- Python is tested on 3.10 through 3.14, and the declared PyModbus 3.10 floor is
  exercised. Previously only the newest of each was.
- The Homebrew job installs from the published release tarball, so on a pull
  request it built the last release rather than the branch. It now runs after
  merge, weekly and on demand; a new job installs the working tree on every pull
  request instead.
- Swift CodeQL runs on pull requests.
- `ruff` and `mypy` gate every change.

## 0.3.1

See the [release notes](https://github.com/jamescross91/solis-tools/releases).
