# Contributing to Solis Tools

Thank you for helping improve Solis Tools. By participating, you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Before opening a change

- Use GitHub Discussions for usage questions.
- Search existing issues before opening a bug or feature request.
- Report security vulnerabilities privately as described in
  [SECURITY.md](SECURITY.md).
- Keep pull requests focused. Separate unrelated fixes or features.

## Development setup

The terminal monitor requires Python 3.10 or later and PyModbus 3.10–3.x. One
command creates the environment and runs every check that CI runs:

```sh
make
```

That covers `ruff check`, `ruff format --check`, `mypy`,
`./scripts/version.py --check` and `python -m unittest`. Individual targets are
listed by `make help`; `make fix` applies the formatter and safe lint fixes.

On macOS 13 or later, also build and test the menu-bar application:

```sh
make swift   # swift test --disable-sandbox --package-path SolisMenuBar
make app     # builds the .app bundle
```

Validate the Homebrew formula when Homebrew is available:

```sh
brew style Formula/solis-tools.rb
brew audit --strict jamescross91/solis-tools/solis-tools
```

### You do not need an inverter

`fake_inverter.py` answers Modbus read-input-register requests from a register
bank, so the monitor, the menu-bar app and the tests all run with no hardware:

```sh
make demo                                          # dashboard against a fake inverter
python3 fake_inverter.py --port 5020 --drop-after 10   # forces a reconnect
python3 fake_inverter.py --port 5020 --corrupt-after 8 # a bad register mid-run
```

Tests must not write to an inverter, and the monitor issues read-input-register
requests only. `test_solis_poll.py` holds decoder tests against a fake client;
`test_end_to_end.py` drives the real CLI against `fake_inverter.py`.

[CLAUDE.md](CLAUDE.md) records the conventions and the traps that have caused
real bugs — register numbering, the five places a new metric has to be added,
and the Python/Swift stream contract. Read it before a first change.
[docs/architecture.md](docs/architecture.md) covers the module layout.

## Pull requests

1. Fork the repository and create a descriptive branch.
2. Add or update tests for behaviour changes.
3. Update the README when commands, output or user-facing behaviour changes.
4. Run the relevant local checks.
5. Open a pull request and complete its checklist.
6. Address review comments and keep the branch current with `main`.

All required GitHub Actions checks and review conversations must be complete
before merge. Maintainers normally squash-merge accepted pull requests.

## Releases

Releases are prepared by a maintainer following
[docs/releasing.md](docs/releasing.md). `solis_poll.VERSION` is the only place a
version is written; everything else is derived by `scripts/version.py` and
checked in CI. Do not change version numbers, release asset URLs or Homebrew
checksums unless the pull request is specifically a release change.
