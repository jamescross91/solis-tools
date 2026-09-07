# solis-tools

[![CI](https://github.com/jamescross91/solis-tools/actions/workflows/ci.yml/badge.svg)](https://github.com/jamescross91/solis-tools/actions/workflows/ci.yml)
[![CodeQL](https://github.com/jamescross91/solis-tools/actions/workflows/codeql.yml/badge.svg)](https://github.com/jamescross91/solis-tools/actions/workflows/codeql.yml)
[![GitHub release](https://img.shields.io/github/v/release/jamescross91/solis-tools)](https://github.com/jamescross91/solis-tools/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

`solis-poll` is a lightweight, nmon-inspired terminal monitor for a Solis hybrid inverter exposed over Modbus TCP. Telemetry is read-only by default. The macOS app also provides optional Dynamic Grid Voltage Control through one narrowly whitelisted import-limit actuator.

It provides:

- a native macOS menu-bar dashboard with live metrics and selectable charts
- live voltage, temperature, battery, house-load and grid-flow gauges
- inverter state plus decoded inverter and BMS fault indicators
- connection latency, last-sample age, failure and reconnect counters
- rolling line graphs, with up to 24 hours in the menu-bar app
- optional CSV and JSONL recording
- optional PV power, daily generation and history
- fast power polling with slower status, temperature and energy polling
- disabled-by-default adaptive import control around configurable PCC voltage limits

PV monitoring is **off by default**, so installations without panels do not read or display PV registers.

## Screenshots

### Terminal dashboard

![Solis Live terminal dashboard](docs/images/solis-live-terminal.png)

### macOS menu-bar app

<img src="docs/images/solis-menubar.png" alt="Solis Live macOS menu-bar dashboard" width="418">

## Install with Homebrew

On macOS or Linux, add this repository as a Homebrew tap, then install the
latest stable release:

```sh
brew tap jamescross91/solis-tools https://github.com/jamescross91/solis-tools
brew trust --formula jamescross91/solis-tools/solis-tools
brew install solis-tools
```

The tap/trust commands are one-time setup (older Homebrew versions without
`brew trust` can omit that step). Afterwards use `brew install solis-tools` or
`brew upgrade solis-tools`. Homebrew does not accept the two-part
`brew install jamescross91/solis-tools` spelling: qualified formula names require
`owner/tap/formula`, whereas a tap itself uses `owner/tap`.

Then run:

```sh
solis-poll --host 192.168.1.57
```

On macOS 13 or later, the same package also installs the native menu-bar app:

```sh
solis-menubar
```

Open its menu-bar item, enter the inverter data-logger IP, and select **Save and
connect**. Select which compact house-load, battery state-of-charge, grid-flow,
temperature and PV metrics appear in the menu bar from Settings; PV generation
is available when PV is enabled. The popover provides battery, grid,
temperature, voltage, alarms, connection health and selectable charts.
Its connection settings are stored in the current macOS user's preferences. PV
remains disabled unless enabled in the app settings.

Dynamic Grid Voltage Control is also off by default. Enabling it authorises the
poller to adjust only raw holding-register PDU address `43488`. The controller
captures the live limit, verifies each FC06 write with FC03, suppresses duplicate
writes and ownership-checks before restoring the baseline when regulation ends,
on disable, or on orderly quit, provided telemetry is fresh and recovered.
Control-setting changes, including disabling control, take effect when **Save
and connect** is selected; changing a toggle alone does not stop the running
poller. Export control is visible but locked until this installation's
`43074` response is validated live.

The menu-bar app retains up to 24 hours of chart history at a 30-second display
resolution, plus the last 30 minutes of voltage-control data at native polling
resolution. This keeps its popover responsive during long-running sessions.
Chart history is memory-only and is cleared whenever the app is quit and
restarted, including after an update.

Releases prepared with the prebuilt-package workflow install a checksum-verified
universal macOS app archive (Apple Silicon and Intel), without compiling Swift
on your Mac. Python and PyModbus are still installed separately by Homebrew.
Historical source-only releases, including 0.5.0, and `--HEAD` still build the
app locally. Linux installations install the terminal monitor only. The app is
ad-hoc signed, not Apple-notarised.

Homebrew installs Python and PyModbus in an isolated environment. Upgrade or remove it with:

```sh
brew upgrade solis-tools
brew uninstall solis-tools
```

## Install from source

- Python 3.10 or later
- PyModbus 3.10–3.x
- network access to the inverter/logger's Modbus TCP service
- a Solis hybrid inverter using the ESINV-33000 input-register layout

Install the required package in a virtual environment:

```sh
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
```

The monitor checks the Python version and imports PyModbus before connecting. If either requirement is missing, it exits with an actionable error rather than attempting to start the dashboard.

## Run

The inverter data logger's address is deliberately mandatory. It may be an IP
address or a hostname, including an mDNS name such as `inverter.local`. When
running from a source checkout:

```sh
./solis_poll.py --host 192.168.1.57
```

Defaults are port `502`, slave ID `1`, a 0.5-second power refresh, a 10-second temperature/status refresh, a three-second timeout, 10 kW inverter capacity and 23 kW grid capacity:

```sh
./solis_poll.py \
  --host 192.168.1.57 \
  --port 502 \
  --slave 1 \
  --interval 0.5 \
  --slow-interval 10 \
  --inverter-max-kw 10 \
  --grid-max-kw 23
```

Use `--once` for a plain-text, script-friendly health check:

```sh
./solis_poll.py --host 192.168.1.57 --once --timeout 5
```

Use `--no-colour` to disable ANSI colours. Press `Ctrl-C` to stop the live
dashboard. The dashboard sizes itself to the terminal and needs at least 60
columns.

Use `--stream-json` to emit a versioned JSON object after every poll. This is
the integration interface used by the menu-bar app:

```sh
./solis_poll.py --host 192.168.1.57 --stream-json
```

## Optional PV monitoring

PV registers are not read unless `--pv` is supplied:

```sh
./solis_poll.py --host 192.168.1.57 --pv
```

This adds current PV generation, today's generated energy and a PV history graph. The PV bar uses `--inverter-max-kw` as its full-scale value.

## Dynamic Grid Voltage Control

The feature maximises grid charging power while meter/PCC voltage remains above
the configured lower boundary. It is a closed loop, not a voltage-to-power
lookup table. Import regulation activates only after both sustained grid import
and the existing battery-direction signal report grid charging. Ordinary house
import remains in standby.

The default working floor is `215.0 V + 1.5 V`, with a `0.75 V` deadband.
Increases are cautious (200 W), reductions are faster (500 W or 1 kW near the
boundary), and raw voltage at or below 215 V immediately requests a 2 kW
reduction. The limit is clamped to 1–14 kW. A five-second dwell blocks further
increases after a command while raw-voltage emergency intervention remains
available. Telemetry older than four seconds cannot cause an increase; after
communications loss, three fresh samples are required before optimisation
resumes.

The menu-bar settings are the supported way to enable control. For development,
the equivalent CLI entry point is:

```sh
solis-poll --host 192.168.1.57 --interval 2 \
  --dynamic-voltage-control --dynamic-import-control \
  --minimum-voltage 215 --maximum-voltage 258 \
  --maximum-import-kw 14
```

Do not run a second poller or Modbus client concurrently: the tested logger
supports only one active Modbus TCP session. The controller journal, minute
aggregates and sparse events are private files under the platform state or
Application Support directory. Export writes remain compile-time gated even if
`--dynamic-export-control` is supplied.

Control journals are scoped to the configured host, port and Modbus unit. Use a
consistent endpoint spelling: aliases for the same logger are not recognised as
the same device. An operating-system lock prevents two controllers using the
same endpoint, including with different journal files. Other Modbus applications
do not honour this lock. A legacy unscoped journal blocks automatic startup until
its inverter and baseline have been checked and the file migrated or archived;
never discard an unresolved recovery record merely to enable control.

Every write first durably records a pending command. Lost replies are reconciled
against the old and intended values before another write is allowed. After an
unclean restart during charging, the recovered baseline caps further increases.
Voltage age is measured from the start of the meter request using a monotonic
clock. Shutdown with stale or recovering telemetry leaves the current limit and
unclean journal intact for later fresh recovery rather than raising power.

Stopping the menu-bar poller is asynchronous and keeps draining its output. If
it has not exited after 15 seconds, the app reports pending restoration and
retains the process instead of launching another one. Minute-history transactions
are committed once per minute in steady operation, on meaningful events, and on
close; an abrupt crash can lose the current uncommitted history, not the separately
flushed safety journal.

### Control options and defaults

The CLI still defaults to a 0.5-second poll; new menu-bar settings default to
2 seconds. The example above explicitly uses the latter. All power limits are
quantised to 100 W; ceilings round down and the 1 kW import floor cannot be
disabled. The export limit is distinct from site permission and neither is
changed by capturing its baseline.

| Option | Default | Meaning |
| --- | --- | --- |
| `--meter-voltage` | Off in CLI | Read PCC voltage without authorising writes |
| `--dynamic-voltage-control` | Off | Master control opt-in; also reads PCC voltage |
| `--dynamic-import-control` / `--no-dynamic-import-control` | On beneath master | Allow/block import regulation |
| `--dynamic-export-control` | Off, gated | Rejected while installation validation is locked |
| `--minimum-voltage` / `--maximum-voltage` | 215 / 258 V | Raw emergency boundaries |
| `--voltage-safety-margin` | 1.5 V | Working targets inside boundaries |
| `--voltage-deadband` | 0.75 V | Holding band around working targets |
| `--maximum-import-kw` | 14 kW | Normal import ceiling |
| `--maximum-export-kw` | 10 kW | Requested dynamic export ceiling, currently gated |
| `--site-export-permission-kw` | 10 kW | Site permission; effective export ceiling is the lower of this and the dynamic ceiling |
| `--increase-step-w` / `--reduction-step-w` | 200 / 500 W | Normal adjustment steps |
| `--near-limit-reduction-w` / `--emergency-reduction-w` | 1,000 / 2,000 W | Faster safety reductions |
| `--control-settle-time` | 5 s | Dwell after a changed command |
| `--control-activation-delay` / `--control-deactivation-delay` | 5 / 10 s | Operating-state debounce |
| `--import-activation-kw` / `--export-activation-kw` | 1 / 0.5 kW | Activation thresholds; import also requires battery charging |
| `--minimum-write-interval` | 5 s | Minimum normal-write spacing; emergency reductions bypass it |
| `--control-journal` | Endpoint-hashed JSON in state directory | Override recovery path, not device identity |
| `--voltage-history-db` | `voltage-history.sqlite3` in state directory | Override private SQLite history path |
| `--voltage-history-retention-days` | 30 days | Retention for minute aggregates and control events |

The state directory is `~/Library/Application Support/SolisTools` on macOS and
`$XDG_STATE_HOME/solis-tools` (or `~/.local/state/solis-tools`) on Linux. If using
multiple inverters, select a separate history database for each; the default
history database, unlike recovery journals, is not endpoint-scoped.

The existing CSV/JSONL recorder does not store PCC/control diagnostics. These
remain available through the JSON stream and the separate control database;
the app's charts are not reloaded from that database. The terminal dashboard is
not a control-status console: use the menu-bar diagnostics or JSON stream.

### Recovery and deployment precautions

If restoration is deferred, retain the journal and use the same endpoint and
journal path on a later control-enabled run with fresh telemetry. Starting a
read-only poller does not recover an unfinished control session. A pending write
is reconciled only if the live register matches its previous or intended value;
unexpected values or invalid journals require investigation rather than deletion.

Legacy unscoped journals cannot establish which inverter they belong to. Before
archiving one, independently verify that its recorded baseline is restored on
the correct inverter and no controller remains active. Do not manually assign an
identity to an unverified journal. Inverter flash-write endurance remains
unconfirmed: retain the write-rate guard and inspect write counts. Export control
must remain locked until its scaling and physical response are validated for
the installation. Local tests exercise simulated hardware only.

## Recording and restored history

Append every successful sample to CSV or JSONL:

```sh
./solis_poll.py --host 192.168.1.57 --csv readings.csv
./solis_poll.py --host 192.168.1.57 --jsonl readings.jsonl
```

Both flags may be used together. Files are appended and flushed after each successful sample. On startup, the monitor restores up to the last six hours from the CSV file, or from JSONL when CSV is not configured. This lets the line graphs survive restarts while keeping their six-hour limit. Only the tail of the file is read, so startup does not slow down as the recording grows.

Recordings are append-only and are never rotated or truncated. At the default
0.5-second interval a CSV grows by roughly 17 MB a day and a JSONL by roughly
58 MB. Raise `--interval`, or rotate the files yourself, for a long-running
capture.

New recording files are created readable only by their owner, because a
half-second power trace shows when a house is empty and what is running in it.
An existing file keeps whatever permissions it already has.

The parent directory must already exist. A missing or unwritable directory produces a clear error and the monitor exits.

## Status, alarms and connection health

The header shows the inverter's model and software/protocol codes. The monitor
checks the Solis type-definition register where available and rejects a
positively identified string-inverter layout. Pass `--skip-profile-check` to
continue anyway if your hybrid inverter is misidentified; decoded values may then
be meaningless, so check them against the inverter's own display.

Every decoded value is range-checked. Before the first successful poll a value
outside its physical range means the register map is wrong, and the monitor stops
and says so. Afterwards the map is proven, so an impossible value is a corrupt
response: that sample is discarded, the previous reading is retained, and the
count appears in the connection line as `rejected`.

The status area shows normal states such as `Waiting`, `Generating` and `Off-grid`. Active fault bits from inverter registers `33116–33120` are decoded to Solis alarm names and codes. BMS fault bit meanings vary between low- and high-voltage battery models, so active BMS bits are reported by exact register and bit rather than given a potentially incorrect description.

Connection health includes:

- age of the last successful sample
- round-trip poll latency
- total and consecutive failures
- successful reconnect count
- samples discarded as physically impossible

After a transient communication failure, the dashboard retains the last good reading and reconnects automatically.

## History graphs and polling

Successful readings are kept for a maximum of six hours. The graphs downsample retained readings to the terminal width and show the observed minimum and maximum.

The standard graphs are:

- grid voltage
- inverter temperature
- house load
- battery flow
- grid flow
- PV generation, only with `--pv`

Battery history is positive when discharging and negative when charging. Grid history is positive when exporting and negative when importing. Battery SoC remains a live gauge and is deliberately excluded from history.

Power-flow registers are read every `--interval` seconds. Temperature, inverter state, inverter faults and daily PV energy are refreshed every `--slow-interval` seconds. Contiguous slow registers are read together to reduce request count.

## Register assumptions

The monitor uses the Solis hybrid ESINV-33000 **input-register** map. The `mbpoll` references used by the original shell prototype were 1-based; raw Modbus PDU addresses are zero-based. The Python client preserves that conversion internally.

| Raw PDU address(es) | 1-based reference(s) | Value used |
| --- | --- | --- |
| `33000–33003` | `33001–33004` | Model, DSP, HMI and protocol codes |
| `33035` | `33036` | Today's PV generation, scaled by 10; only with `--pv` |
| `33057–33058` | `33058–33059` | Total PV power, scaled by 1000; only with `--pv` |
| `33073` | `33074` | Grid voltage, scaled by 10 |
| `33251` | `33252` | Meter/PCC voltage, scaled by 10; with `--meter-voltage` or dynamic control |
| `33093` | `33094` | Inverter temperature, signed and scaled by 10 |
| `33095` | `33096` | Inverter state |
| `33116–33120` | `33117–33121` | Inverter fault words |
| `33135` | `33136` | Battery operating direction |
| `33139` | `33140` | Battery state of charge (%) |
| `33145–33146` | `33146–33147` | BMS fault words |
| `33147` | `33148` | House load, scaled by 1000 |
| `33149–33150` | `33150–33151` | Battery power, scaled by 1000 |
| `33263–33264` | `33264–33265` | Grid power, signed and scaled by 1000 |
| `35000` | `35001` | Inverter register-family definition, where supported |

Control holding registers use raw PDU addresses directly; they do not use the
input-register helper's 1-based call convention.

| Raw holding PDU address | Read/write | Scale | Policy |
| --- | --- | --- | --- |
| `43488` | FC03 / FC06 | 100 W per unit | Typed import actuator; explicit opt-in |
| `43074` | FC03 / FC06 | 100 W per unit | Typed export actuator; writes blocked pending live validation |

No other holding-register write is permitted. In particular, Remote Dispatch,
Flexible Export and operating-mode registers are outside the whitelist.

Inverter firmware can change register availability. Check the map against the exact model before relying on the display operationally.

Register names, scales and alarms were cross-checked against the [Solis Modbus sensor documentation](https://solis-modbus.readthedocs.io/en/latest/sensors.html), the published [Solis hybrid protocol](https://www.scss.tcd.ie/Brian.Coghlan/Elios4you/RS485_MODBUS-Hybrid-BACoghlan-201811228-1854.pdf) and the MIT-licensed [community register map](https://github.com/szlaskidaniel/solar-inverter-modbus-registers).

## Development and tests

`make` creates a virtual environment and runs every check CI runs — lint,
formatting, types, version consistency and the test suite. `make help` lists the
individual targets.

```sh
make
make swift   # macOS: swift test for the menu-bar package
make app     # macOS: build the .app bundle
```

`test_solis_poll.py` covers status and fault decoding, BMS bit reporting,
recording and restoration, and chart generation against a fake client.
`test_end_to_end.py` runs the real CLI as a subprocess against
`fake_inverter.py`, covering the poll loop, reconnection, the corrupt-sample
path and recording.

### Running without an inverter

`fake_inverter.py` answers Modbus input reads and emulates FC03/FC06 for only the
two control whitelist addresses, so control and restoration tests run with no
hardware:

```sh
make demo                                                # dashboard against a fake inverter
python3 fake_inverter.py --port 5020 --drop-after 10      # forces a reconnect
python3 fake_inverter.py --port 5020 --corrupt-after 8    # a bad register mid-run
python3 fake_inverter.py --port 5020 --string-inverter    # the wrong register family
```

Point the menu-bar app at `127.0.0.1` port `5020` to exercise it the same way.

## Documentation

- [docs/architecture.md](docs/architecture.md) — module layout, register
  addressing, the subprocess boundary
- [docs/stream-contract.md](docs/stream-contract.md) — the `--stream-json`
  payload and how to change it
- [docs/releasing.md](docs/releasing.md) — the release runbook
- [CLAUDE.md](CLAUDE.md) — conventions and traps, for contributors and coding
  agents
- [CHANGELOG.md](CHANGELOG.md) — user-visible changes

## Contributing, support and security

Contributions are welcome through pull requests. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and required
checks, [SUPPORT.md](SUPPORT.md) for help, and [SECURITY.md](SECURITY.md) for
private vulnerability reporting. Project decisions and maintainer
responsibilities are documented in [GOVERNANCE.md](GOVERNANCE.md) and
[MAINTAINERS.md](MAINTAINERS.md).

## Troubleshooting

- **`pymodbus is not installed`** — activate the intended virtual environment and run `python3 -m pip install -r requirements.txt`.
- **Unsupported register map** — this tool supports Solis hybrid ESINV-33000 registers. Confirm the inverter model and firmware map.
- **No route from VS Code, but an external terminal works** — enable **Visual Studio Code** under **System Settings → Privacy & Security → Local Network**, then fully quit and reopen VS Code.
- **A poll fails** — check the logger address, port, slave ID and Modbus configuration. The dashboard will reconnect while retaining its last good reading.
- **`outside the expected ... range` on startup** — the register map does not match this inverter. Confirm the model, then try `--skip-profile-check` if you believe it is a supported hybrid.
- **A rising `rejected` count** — the inverter is returning occasional impossible values. Readings are still correct; the bad samples are discarded.
- **Recording fails** — create the parent directory and verify it is writable.
- **No colour or redraw** — use an interactive ANSI-capable terminal. Use `--once` for scripts and diagnostics.
