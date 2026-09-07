# Release runbook

## One release, one PR

A release PR may contain the feature itself: version, changelog, formula and
prebuilt-package metadata are reviewed together. Do not open separate version
or formula PRs. This workflow does not push commits to protected main or bypass
required reviews.

The formula SHA-256 is calculated before merge from a reproducible source
archive. Archive entries have fixed ordering, ownership, modes and timestamps;
commit IDs and commit dates do not affect it. Only `Formula/` and
`.release-assets.json` are excluded to avoid circular checksums. Everything
else tracked by Git, including tests and documentation, is retained.

## 1. Prepare the same PR

Use Python 3.14 for release preparation, matching the CI packager.

1. Finish the feature and add its `## X.Y.Z` changelog section, including upgrade
   precautions. Choose a version greater than the current main version.
2. Stage new source files so the packager includes them.
3. Run `python3.14 scripts/release.py prepare X.Y.Z`. This invokes the canonical
   version updater and calculates the source archive URL and checksum.
4. Commit all changes and open **one** release PR. Its Release candidate workflow
   builds both arm64 and x86_64 app binaries, combines them into a universal app,
   signs it ad hoc, checks both architectures and verifies its reported version.
   The initial release-integrity check intentionally fails until the binary
   checksum is attached.
5. Once that candidate workflow succeeds, attach its artifact to the same PR:

   ```sh
   python3.14 scripts/release.py prepare X.Y.Z --binary-run RUN_ID
   git add solis_poll.py SolisMenuBar/Resources/Info.plist \
     SolisMenuBar/Sources/SolisMenuBar/SolisMenuBarApp.swift \
     CHANGELOG.md Formula/solis-tools.rb .release-assets.json
   git commit -m "Attach verified release packages"
   git push
   ```

The command authenticates with `gh`, checks the workflow identity, source archive
digest, version, filename and binary checksum, then records the binary resource
and provenance. It downloads into `build/release`; binaries are not committed to
Git. Artifacts are retained for 90 days: rebuild and refresh the same PR if they
expire before publication.

Any source or documentation change after the candidate build requires another
candidate and another prepare invocation. Formula/metadata-only changes do not.
Rebase onto current main before final approval so merge contents match the
reviewed source checksum. Never reuse a published version.

## 2. Review and merge once

Run `make` and `make swift` with full Xcode. CI also:

- checks that version, changelog, source digest and prebuilt resource agree;
- installs the exact candidate source archive with Homebrew on macOS and Linux;
- installs the approved prebuilt macOS resource when its digest matches;
- verifies the app and poller versions through the formula tests.

Normal feature PRs without a release version change still build/test current
sources; they do not publish a release. Initial release PR pushes without binary
metadata are not ready to merge.

## 3. Automatic publication

After successful **main-branch CI**, Release rechecks the merged commit and
provenance, creates its version tag and a draft GitHub release, and uploads the
source archive plus the already-built universal macOS app archive. It downloads
both assets and verifies their SHA-256 values before making the release public.
Nothing is rebuilt after approval, and no follow-up formula commit is needed.

The formula is already on main, so there is a brief publication window in which
its new URL may not yet exist. Do not announce availability until Release and
its Published Homebrew installation jobs pass. The pre-publication CI jobs use
local candidates, not missing public URLs.

Only publication has repository-content write permission. Candidate builds are
read-only and have no publishing secrets. Post-publication jobs verify the
public formula on macOS and Linux. Published assets and tags are never
overwritten. Ad-hoc signing is not Apple notarisation.

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
reject mismatched tags/assets rather than overwriting them. Retry before
candidate artifacts expire; if the source changes, prepare a new version.
Draft lookup checks both the by-tag endpoint and the release list because GitHub
may briefly hide a newly created draft from the former.

For a broken public release, use a new patch-version release PR. Do not delete,
retag or replace a release users may already have installed. Homebrew still
installs Python/PyModbus; the prebuilt resource removes Swift compilation, not
all dependency installation. `--HEAD` and historical source-only versions remain
source builds.

Keep dynamic control off during installation tests. No release check may write
to physical inverter hardware or create an installation-validation record.
Include import opt-in, endpoint-gated export control, legacy-journal migration
and stale-restoration precautions in applicable release notes.
