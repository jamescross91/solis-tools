#!/usr/bin/env python3
"""Keep every copy of the version in step with solis_poll.VERSION.

The version was written out by hand in eight places across a Python module, a
setuptools manifest, an Info.plist, a Swift string, a release script and a
Homebrew formula. Missing one produced a release that installed but reported the
wrong version, and nothing checked.

    scripts/version.py            print the canonical version
    scripts/version.py --check    exit 1 listing anything out of step
    scripts/version.py --write    rewrite the derived copies
    scripts/version.py --set X.Y.Z  set the canonical version, then rewrite

pyproject.toml reads solis_poll.VERSION dynamically, so it is never edited here.
The Homebrew formula tracks the last *published* release rather than the working
tree, so it is reported but never rewritten.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "solis_poll.py"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


@dataclass(frozen=True)
class Copy:
    """One derived location, found and rewritten by a single-group pattern."""

    path: Path
    pattern: re.Pattern[str]
    description: str

    def read(self) -> str | None:
        if not self.path.exists():
            return None
        match = self.pattern.search(self.path.read_text(encoding="utf-8"))
        return match.group(1) if match else None

    def write(self, version: str) -> bool:
        text = self.path.read_text(encoding="utf-8")
        match = self.pattern.search(text)
        if match is None or match.group(1) == version:
            return False
        start, end = match.span(1)
        self.path.write_text(text[:start] + version + text[end:], encoding="utf-8")
        return True


def canonical_version() -> str:
    match = re.search(r'^VERSION = "([^"]+)"', MODULE.read_text(encoding="utf-8"), re.MULTILINE)
    if match is None:
        raise SystemExit(f"error: no VERSION found in {MODULE}")
    return match.group(1)


def derived_copies() -> list[Copy]:
    return [
        Copy(
            ROOT / "SolisMenuBar/Resources/Info.plist",
            re.compile(
                r"<key>CFBundleShortVersionString</key>\s*\n\s*<string>([^<]+)</string>",
            ),
            "menu-bar bundle short version",
        ),
        Copy(
            ROOT / "SolisMenuBar/Sources/SolisMenuBar/SolisMenuBarApp.swift",
            re.compile(r'print\("solis-menubar ([^"]+)"\)'),
            "menu-bar --version output",
        ),
    ]


def tracked_only() -> list[Copy]:
    """Locations reported for information but not rewritten."""
    return [
        Copy(
            ROOT / "Formula/solis-tools.rb",
            re.compile(r"solis-tools-(\d+\.\d+\.\d+)\.tar\.gz"),
            "Homebrew formula (tracks the published release)",
        ),
    ]


def check(version: str) -> int:
    problems = []
    for copy in derived_copies():
        found = copy.read()
        if found is None:
            problems.append(f"  {copy.path.relative_to(ROOT)}: no version found")
        elif found != version:
            problems.append(
                f"  {copy.path.relative_to(ROOT)}: {found} != {version} ({copy.description})"
            )
    for copy in tracked_only():
        found = copy.read()
        if found is not None and found != version:
            print(
                f"note: {copy.path.relative_to(ROOT)} is at {found}; {copy.description}",
                file=sys.stderr,
            )
    if problems:
        print(
            f"error: version copies disagree with solis_poll.VERSION ({version}):", file=sys.stderr
        )
        print("\n".join(problems), file=sys.stderr)
        print("run scripts/version.py --write", file=sys.stderr)
        return 1
    print(f"all version copies agree: {version}")
    return 0


def write(version: str) -> int:
    for copy in derived_copies():
        if copy.write(version):
            print(f"updated {copy.path.relative_to(ROOT)} -> {version}")
    return 0


BUILD_NUMBER = re.compile(r"<key>CFBundleVersion</key>\s*\n\s*<string>(\d+)</string>")
PLIST = ROOT / "SolisMenuBar/Resources/Info.plist"


def bump_build_number() -> int:
    """Increment CFBundleVersion, which is a build counter, not the version.

    macOS compares this when deciding whether a bundle has changed, so a release
    that reuses it can be treated as the same build.
    """
    text = PLIST.read_text(encoding="utf-8")
    match = BUILD_NUMBER.search(text)
    if match is None:
        raise SystemExit(f"error: no CFBundleVersion found in {PLIST}")
    build = str(int(match.group(1)) + 1)
    start, end = match.span(1)
    PLIST.write_text(text[:start] + build + text[end:], encoding="utf-8")
    print(f"updated {PLIST.relative_to(ROOT)} CFBundleVersion -> {build}")
    return 0


def set_version(version: str) -> int:
    if not SEMVER.match(version):
        raise SystemExit(f"error: {version!r} is not MAJOR.MINOR.PATCH")
    if version == canonical_version():
        raise SystemExit(f"error: already at {version}")
    text = MODULE.read_text(encoding="utf-8")
    MODULE.write_text(
        re.sub(r'^VERSION = "[^"]+"', f'VERSION = "{version}"', text, count=1, flags=re.MULTILINE),
        encoding="utf-8",
    )
    print(f"updated {MODULE.relative_to(ROOT)} -> {version}")
    bump_build_number()
    return write(version)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true", help="verify every copy agrees")
    group.add_argument("--write", action="store_true", help="rewrite the derived copies")
    group.add_argument("--set", metavar="VERSION", help="set the canonical version and rewrite")
    arguments = parser.parse_args()

    if arguments.set:
        return set_version(arguments.set)
    version = canonical_version()
    if arguments.check:
        return check(version)
    if arguments.write:
        return write(version)
    print(version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
