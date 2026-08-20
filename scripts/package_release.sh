#!/bin/bash
# Build the release tarball that the Homebrew formula installs from.
#
# This used to archive a hand-written list of paths, so a new source file was
# silently left out and the omission only surfaced when Homebrew tried to build
# the published tarball. It now archives the whole tree at the given ref, and
# verifies the result contains what the formula's install step needs.

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-$("$project_root/scripts/version.py")}"
ref="${2:-v$version}"
output_root="$project_root/build/release"
output_path="$output_root/solis-tools-$version.tar.gz"
prefix="solis-tools-$version"

mkdir -p "$output_root"
git -C "$project_root" archive \
    --format=tar.gz \
    --prefix="$prefix/" \
    --output="$output_path" \
    "$ref"

# The formula runs `swift build --package-path SolisMenuBar`, which fails if any
# target declared in Package.swift has no sources in the archive.
required=(
    "$prefix/LICENSE"
    "$prefix/README.md"
    "$prefix/pyproject.toml"
    "$prefix/requirements.txt"
    "$prefix/solis_poll.py"
    "$prefix/SolisMenuBar/Package.swift"
    "$prefix/SolisMenuBar/Resources/Info.plist"
    "$prefix/SolisMenuBar/Sources/SolisMenuBar/SolisMenuBarApp.swift"
    "$prefix/SolisMenuBar/Tests/SolisMenuBarTests/StreamContractTests.swift"
)
contents="$(tar -tzf "$output_path")"
for entry in "${required[@]}"; do
    if ! grep -qxF "$entry" <<<"$contents"; then
        echo "error: $output_path is missing $entry" >&2
        exit 1
    fi
done

echo "$output_path"
echo "sha256: $(shasum -a 256 "$output_path" | cut -d' ' -f1)" >&2
