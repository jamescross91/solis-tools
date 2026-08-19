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

The terminal monitor requires Python 3.10 or later and PyModbus 3.10–3.x:

```sh
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
```

Run the Python tests:

```sh
python3 -m unittest -v
```

On macOS 13 or later, build and validate the menu-bar application:

```sh
swift build --disable-sandbox --package-path SolisMenuBar
./scripts/build_menubar_app.sh release
```

Validate the Homebrew formula when Homebrew is available:

```sh
brew style Formula/solis-tools.rb
brew audit --strict --online jamescross91/solis-tools/solis-tools
```

Tests must not write to an inverter. Use the existing fake Modbus responses for
register-decoding tests.

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

Releases are prepared by a maintainer. Do not change version numbers, release
asset URLs or Homebrew checksums unless the pull request is specifically a
release change.
