# Release runbook

For maintainers. `CONTRIBUTING.md` previously said only that "releases are
prepared by a maintainer", with the eight hand-edited version locations and the
checksum step undocumented.

`solis_poll.VERSION` is the single source of truth. Everything else is derived or
checked.

## 1. Prepare

On a branch, from a clean `main`:

```sh
./scripts/version.py --set 0.4.0    # rewrites the plist and the Swift string
make                                # lint, format, types, version check, tests
```

Move the `CHANGELOG.md` `## Unreleased` entries under `## 0.4.0`. Open a pull
request whose only content is the version bump and the changelog, and merge it.
`CONTRIBUTING.md` asks contributors not to touch version numbers precisely so
this stays one reviewable commit.

## 2. Tag

```sh
git checkout main && git pull
git tag -a v0.4.0 -m "solis-tools 0.4.0"
git push origin v0.4.0
```

The tag triggers `.github/workflows/release.yml`, which:

1. refuses the tag if it disagrees with `solis_poll.VERSION`;
2. builds the tarball with `scripts/package_release.sh` and asserts it contains
   everything the formula's install step needs;
3. extracts it and builds it exactly as Homebrew will — `pip install .` plus
   `swift build --configuration release`;
4. publishes a **draft** release with the tarball attached;
5. prints the `url` and `sha256` lines for the formula in the job summary.

If step 1 or 3 fails, delete the tag, fix the branch, and tag again. Nothing is
published until the draft exists.

## 3. Publish the release

Review the draft release on GitHub, paste the changelog section into its notes,
and publish it. The asset must be public before the formula can point at it.

## 4. Update the formula

The formula tracks the last *published* release, which is why
`scripts/version.py` reports it but never rewrites it. Take the two lines from
the release job's summary:

```ruby
  url "https://github.com/jamescross91/solis-tools/releases/download/v0.4.0/solis-tools-0.4.0.tar.gz"
  sha256 "..."
```

Check whether the pinned `pymodbus` resource needs bumping too — dependabot
watches `requirements.txt`, not the formula's pinned resource, so this is a
manual check at release time:

```sh
python3 -m pip download --no-binary :all: --no-deps pymodbus
shasum -a 256 pymodbus-*.tar.gz
```

Open a pull request with just the formula change. When it merges, the `Homebrew`
CI job runs on `main` and installs the published tarball on macOS and Linux —
this is the check that the release actually installs, which is why that job does
not run on pull requests.

## 5. Verify

```sh
brew update && brew upgrade solis-tools
solis-poll --version      # solis-poll 0.4.0
solis-menubar --version   # solis-menubar 0.4.0
```

## If a release is broken

Do not delete a published release that people may have installed. Bump the patch
version and go round again. A yanked release breaks `brew upgrade` for anyone
whose formula still points at it.
