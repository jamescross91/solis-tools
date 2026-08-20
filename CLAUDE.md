# Working on solis-tools

Guidance for coding agents and for anyone making a first change here. The
project conventions below are not preferences; getting them wrong produces a
change that looks right and is not.

## What this is

Two deliverables from one repository:

- `solis_poll.py` — the terminal monitor. A single module: register map, Modbus
  client, decoders, recorder, ANSI renderer, JSON stream contract and CLI.
- `SolisMenuBar/` — a SwiftUI `MenuBarExtra` app that spawns
  `solis-poll --stream-json` as a subprocess and renders its stdout.

`Formula/solis-tools.rb` packages both; this repository is its own Homebrew tap.

## Run the checks

```sh
make          # everything CI runs: lint, format, types, version, tests
make demo     # the real dashboard against a fake inverter, no hardware
make swift    # macOS only
```

`make help` lists the rest. CI runs exactly these checks, so a green `make` is
the signal that a change is ready.

## You do not need an inverter

`fake_inverter.py` answers read-input-registers from a register bank and can
inject the faults that matter:

```sh
python3 fake_inverter.py --port 5020 --corrupt-after 8   # bad battery register
python3 fake_inverter.py --port 5020 --drop-after 10     # forces a reconnect
python3 fake_inverter.py --port 5020 --string-inverter   # wrong register family
```

Point either the CLI or the menu-bar app at `127.0.0.1:5020`. Anything you can
reproduce against it belongs in `test_end_to_end.py`.

## Rules that are not negotiable

**Read-only Modbus.** The monitor issues function code 4, read input registers,
and nothing else. Writing to an inverter is out of scope and `SECURITY.md`
treats a change that does so as a vulnerability. Do not add a write path, even
behind a flag.

**British spelling**, in prose and in identifiers: `--no-colour`, `Palette`,
`colour`, `analyse`. American spelling in a diff is a review comment.

**PyModbus is the only runtime dependency.** The tool is otherwise standard
library. A new runtime dependency needs an argument for why the standard library
cannot do the job; development-only tools belong in the `dev` extra.

**Comments explain why, not what.** The existing comments record decisions and
traps — register numbering, a fixed bug's failure mode. Match that. Do not
annotate obvious code.

## Traps that have caused real bugs

**Register numbering has two conventions.** `SolisClient._registers(reference,
count)` takes a 1-based reference and reads PDU address `reference - 1`. Inline
comments, the README table and `fake_inverter.py`'s bank all use the **raw**
zero-based address. So `_registers(33136, 16)` reads raw 33135–33150, and
`status[10]` is raw 33145. Check any register change against all four: the call,
its comment, the README table, and the offsets indexed out of the block.

**A new metric has to be added in five places** that must agree, or a reading
appears in one output and not another:

1. `Reading` (the dataclass)
2. `poll_fast` or `poll_slow` (decode it)
3. `render` and `print_once` (terminal output)
4. `stream_payload` (the JSON contract the Swift app decodes)
5. `Recorder.CSV_FIELDS`, `Recorder._record` and `reading_from_record`
   (recording, and the restore path back out)

Adding to `CSV_FIELDS` changes the CSV header, which `_validate_csv_header`
rejects on existing files. Prefer recovering a value, as `severity_for_code`
does, over widening the header.

**The version lives in one place.** `solis_poll.VERSION`. Everything else is
derived — `scripts/version.py --set X.Y.Z` bumps them, `--check` gates it in CI.
Never hand-edit a version anywhere else. The Homebrew formula is the exception:
it tracks the last *published* release, so a release change is its own commit.

**The Python/Swift boundary is a versioned contract.** `stream_payload` emits
snake_case; Swift decodes with `.convertFromSnakeCase`. Adding a field is safe.
Renaming or removing one breaks the app, and `schema_version` must be bumped on
both sides — the app refuses a version it does not know. Every field is pinned
in `SolisMenuBar/Tests/SolisMenuBarTests/StreamContractTests.swift`; make new
optional fields `Optional` in Swift so an older poller still decodes.

**A bad sample is not a bad register map.** `checked()` raises
`ImplausibleReadingError`, which is fatal only before the first successful poll.
After that it discards the sample and keeps the connection, because one corrupt
frame used to end an unattended run. Do not make range failures fatal again.

**Every dashboard row must fit the terminal.** `render` sizes rows from
`shutil.get_terminal_size().columns`; use `fit()` for anything variable-length.
An unclamped row wraps and breaks the fixed-height redraw. 60 columns is the
narrowest supported width.

## Documentation that has to keep up

- `README.md` — the register table, defaults and flags all appear there.
- `docs/architecture.md` — module layout and the subprocess boundary.
- `docs/releasing.md` — the release runbook.
- `CHANGELOG.md` — user-visible changes.

## Conventions for changes

Commit subjects are imperative and describe the outcome, not the mechanism.
Bodies explain what was wrong and how it was proven, and name a reproduction
where there is one. Keep pull requests focused; `CONTRIBUTING.md` has the rest.
