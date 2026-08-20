# Changelog

Notable user-visible changes. This project follows [semantic
versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

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
