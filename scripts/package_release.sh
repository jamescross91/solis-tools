#!/bin/bash
# Compatibility entry point; release.py owns the reproducible archive format.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-$("$project_root/scripts/version.py")}"
ref="${2:-HEAD}"
path="$(python3 "$project_root/scripts/release.py" build "$ref")"
if [[ "$(basename "$path")" != "solis-tools-$version.tar.gz" ]]; then
    echo "error: requested version does not match $ref" >&2
    exit 1
fi
echo "$path"
