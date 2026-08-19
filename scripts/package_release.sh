#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-0.2.0}"
ref="${2:-v$version}"
output_root="$project_root/build/release"
output_path="$output_root/solis-tools-$version.tar.gz"

mkdir -p "$output_root"
git -C "$project_root" archive \
    --format=tar.gz \
    --prefix="solis-tools-$version/" \
    --output="$output_path" \
    "$ref" \
    LICENSE \
    README.md \
    pyproject.toml \
    requirements.txt \
    solis_poll.py \
    SolisMenuBar/Package.swift \
    SolisMenuBar/Resources \
    SolisMenuBar/Sources

echo "$output_path"
