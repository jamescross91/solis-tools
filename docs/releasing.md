# Release runbook

## One release, one PR

A release PR may contain the feature itself: version, changelog and formula are
reviewed together. Do not open separate version or formula PRs. This workflow
does not push commits to protected main or bypass required reviews.

The formula SHA-256 is calculated before merge from a reproducible source
archive. Archive entries have fixed ordering, ownership, modes and timestamps;
commit IDs and commit dates do not affect it. Only `Formula/` is excluded to
avoid circular checksums. Everything else tracked by Git, including tests and
documentation, is retained.

## 1. Prepare the PR

Use Python 3.14 for release preparation, matching CI.

1. Finish the feature and add its `## X.Y.Z` changelog section, including upgrade
   precautions. Choose a version greater than the current main version.
2. Stage new source files so the packager includes them.
3. Run `python3.14 scripts/release.py prepare X.Y.Z`. This invokes the canonical
   version updater and calculates the source archive URL and checksum.
4. Commit everything and open **one** release PR. That is the whole preparation:
   there is no binary to build or attach, because Homebrew compiles the menu-bar
   app from the source archive on the user's Mac.

Any source or documentation change after `prepare` changes the archive checksum,
so run `prepare` again (it is idempotent at the same version). Formula-only edits
do not. Rebase onto current main before final approval so merge contents match
the reviewed checksum. Never reuse a published version.

## 2. Review and merge once

Run `make` (and `make swift` with full Xcode) before pushing. CI also:

- checks that version, changelog and source digest agree;
- installs the exact candidate source archive with Homebrew on macOS and Linux.

The Homebrew jobs build from source, so they run only when a pull request
changes `solis_poll.py` or `Formula/`. Ordinary feature PRs skip them and finish
with the fast Python, lint, type and Swift checks.

## 3. Automatic publication

After successful **main-branch CI**, Release rechecks the merged commit and
provenance, creates its version tag and a draft GitHub release, and uploads the source
archive. It downloads the asset and verifies its SHA-256 before making the
release public. No follow-up formula commit is needed.

The formula is already on main, so there is a brief publication window in which
its new URL may not yet exist. Do not announce availability until Release and
its Published Homebrew installation jobs pass. The pre-publication CI jobs use
local candidates, not missing public URLs.

Only publication has repository-content write permission. Post-publication jobs verify the
public formula on macOS and Linux. Published assets and tags are never
overwritten. The app is ad-hoc signed locally by Homebrew, not Apple-notarised.

## 4. Verify or retry

For an existing installation:

```sh
brew update
brew upgrade solis-tools
solis-poll --version
solis-menubar --version   # macOS only
```

Fresh installations use the one-time tap/trust instructions in README, then
`brew install solis-tools`. Homebrew requires three components for a qualified
formula name; `brew install jamescross91/solis-tools` is not supported.

A failed publication can be retried using Release's manual workflow input
`ref`, set to the exact merged release commit. Successful main CI and ancestry
are checked again. Retries accept matching assets, resume incomplete drafts and
reject mismatched tags/assets rather than overwriting them. If the source
changes, prepare a new version.
Draft lookup checks both the by-tag endpoint and the release list because GitHub
may hide drafts from the former. Creation continues from GitHub's returned
release object, so a new draft does not need to become visible through either
lookup endpoint before asset upload begins.

For a broken public release, use a new patch-version release PR. Do not delete,
retag or replace a release users may already have installed. `--HEAD` builds current main.

Keep dynamic control off during installation tests. No release check may write
to physical inverter hardware or create an installation-validation record.
Include import opt-in, endpoint-gated export control, legacy-journal migration
and stale-restoration precautions in applicable release notes.
