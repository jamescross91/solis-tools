#!/usr/bin/env python3
"""Prepare, verify and publish a release without a second formula commit."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "jamescross91/solis-tools"
REQUIRED = {
    "LICENSE",
    "README.md",
    "pyproject.toml",
    "requirements.txt",
    "solis_poll.py",
    "voltage_control.py",
    "SolisMenuBar/Package.swift",
    "SolisMenuBar/Resources/Info.plist",
    "SolisMenuBar/Sources/SolisMenuBar/SolisMenuBarApp.swift",
    "SolisMenuBar/Tests/SolisMenuBarTests/StreamContractTests.swift",
}


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args])


def version(root: Path, ref: str | None = None) -> str:
    source = (
        git(root, "show", f"{ref}:solis_poll.py").decode()
        if ref
        else (root / "solis_poll.py").read_text()
    )
    match = re.search(r'^VERSION = "(\d+\.\d+\.\d+)"$', source, re.MULTILINE)
    if match is None:
        raise ValueError("missing canonical semantic version")
    return match[1]


def archive(root: Path, release_version: str, ref: str | None = None) -> bytes:
    if not re.fullmatch(r"\d+\.\d+\.\d+", release_version):
        raise ValueError("invalid release version")
    entries: dict[str, tuple[bytes, int, str | None]] = {}
    if ref:
        with tarfile.open(fileobj=io.BytesIO(git(root, "archive", "--format=tar", ref))) as source:
            for member in source:
                if member.isfile():
                    stream = source.extractfile(member)
                    assert stream is not None
                    entries[member.name] = (stream.read(), member.mode, None)
                elif member.issym():
                    entries[member.name] = (b"", member.mode, member.linkname)
    else:
        # New files must be staged so preparation and the eventual commit agree.
        for name in git(root, "ls-files", "-z").decode().split("\0"):
            if not name:
                continue
            path = root / name
            if path.is_symlink():
                entries[name] = (b"", 0o777, os.readlink(path))
            elif path.is_file():
                entries[name] = (path.read_bytes(), path.stat().st_mode, None)
    missing = REQUIRED - entries.keys()
    if missing:
        raise ValueError(f"archive is missing required files: {sorted(missing)}")
    result = io.BytesIO()
    with gzip.GzipFile(filename="", fileobj=result, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as target:
            for name, (data, mode, link) in sorted(entries.items()):
                # A formula containing this archive's checksum cannot be in the
                # archive. All other tracked sources, tests and docs are retained.
                if name.startswith("Formula/") or name == ".release-assets.json":
                    continue
                member = tarfile.TarInfo(f"solis-tools-{release_version}/{name}")
                member.mode = 0o755 if mode & 0o111 else 0o644
                if link is not None:
                    member.type = tarfile.SYMTYPE
                    member.linkname = link
                else:
                    member.size = len(data)
                target.addfile(member, io.BytesIO(data))
    return result.getvalue()


def url(release_version: str) -> str:
    return f"https://github.com/{REPOSITORY}/releases/download/v{release_version}/solis-tools-{release_version}.tar.gz"


def update_formula(formula: str, source_url: str, checksum: str) -> str:
    formula, urls = re.subn(
        r'^  url "[^"]+"$', f'  url "{source_url}"', formula, count=1, flags=re.MULTILINE
    )
    formula, hashes = re.subn(
        r'^  sha256 "[^"]+"$', f'  sha256 "{checksum}"', formula, count=1, flags=re.MULTILINE
    )
    if urls != 1 or hashes != 1:
        raise ValueError("cannot locate stable formula URL/checksum")
    return formula


def build(root: Path, ref: str | None = None) -> tuple[Path, str]:
    release_version = version(root, ref)
    data = archive(root, release_version, ref)
    path = root / "build" / "release" / f"solis-tools-{release_version}.tar.gz"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path, hashlib.sha256(data).hexdigest()


def check(root: Path, ref: str = "HEAD") -> tuple[Path, str]:
    path, checksum = build(root, ref)
    formula = git(root, "show", f"{ref}:Formula/solis-tools.rb").decode()
    if update_formula(formula, url(version(root, ref)), checksum) != formula:
        raise ValueError(
            "release formula is stale: rerun scripts/release.py prepare VERSION and commit the result"
        )
    changelog = git(root, "show", f"{ref}:CHANGELOG.md").decode()
    if f"\n## {version(root, ref)}\n" not in changelog:
        raise ValueError("release changelog section is missing")
    metadata = json.loads(git(root, "show", f"{ref}:.release-assets.json"))
    validate_binary(metadata, version(root, ref), checksum)
    if binary_formula(formula, metadata) != formula:
        raise ValueError("prebuilt macOS resource differs from release metadata")
    return path, checksum


def validate_binary(metadata: dict, release_version: str, checksum: str) -> None:
    if metadata.get("source_sha256") != checksum or metadata.get("version") != release_version:
        raise ValueError("prebuilt app does not match these sources; rebuild the candidate")
    if metadata.get("name") != f"solis-menubar-{release_version}-macos-universal.tar.gz":
        raise ValueError("invalid prebuilt archive name")
    if not re.fullmatch(r"[0-9a-f]{64}", metadata.get("sha256", "")):
        raise ValueError("invalid prebuilt checksum")


def binary_formula(formula: str, metadata: dict) -> str:
    block = (
        "  # BEGIN PREBUILT MACOS\n"
        '  resource "solis-menubar" do\n'
        "    on_macos do\n"
        f'      url "https://github.com/{REPOSITORY}/releases/download/v{metadata["version"]}/{metadata["name"]}"\n'
        f'      sha256 "{metadata["sha256"]}"\n'
        "    end\n"
        "  end\n"
        "  # END PREBUILT MACOS"
    )
    formula = source_only_formula(formula)
    # Resource-scoped platform blocks leave no empty resource on Linux and
    # follow Homebrew's required nesting for one-resource platform conditions.
    return formula.replace("  def install\n", block + "\n\n  def install\n", 1)


def source_only_formula(formula: str) -> str:
    pattern = r"  # BEGIN PREBUILT MACOS.*?  # END PREBUILT MACOS"
    return re.sub(pattern + r"\n\n?", "", formula, flags=re.DOTALL)


def download_binary(
    root: Path, run_id: str, checksum: str, release_version: str
) -> tuple[Path, dict]:
    if not run_id.isdigit():
        raise ValueError("binary run must be numeric")
    run = json.loads(gh("api", f"repos/{REPOSITORY}/actions/runs/{run_id}"))
    if run["conclusion"] != "success" or run["path"] != ".github/workflows/release-candidate.yml":
        raise ValueError("binary run must be a successful Release candidate workflow")
    with tempfile.TemporaryDirectory() as directory:
        gh(
            "run",
            "download",
            run_id,
            "--repo",
            REPOSITORY,
            "--name",
            "macos-release-candidate",
            "--dir",
            directory,
        )
        metadata = json.loads((Path(directory) / "metadata.json").read_text())
        validate_binary(metadata, release_version, checksum)
        data = (Path(directory) / metadata["name"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != metadata["sha256"]:
            raise ValueError("prebuilt checksum mismatch")
    metadata["run_id"] = run_id
    target = root / "build/release" / metadata["name"]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    return target, metadata


def gh(*args: str) -> str:
    return subprocess.check_output(["gh", *args], text=True).strip()


def synchronise_version(root: Path, requested: str) -> None:
    # Attaching a candidate repeats preparation at the same version. The
    # version helper deliberately rejects --set in that case, but --write
    # still repairs derived copies without incrementing the bundle build.
    arguments = ["--write"] if version(root) == requested else ["--set", requested]
    subprocess.run([sys.executable, str(root / "scripts/version.py"), *arguments], check=True)


def api_optional(endpoint: str) -> dict | None:
    response = subprocess.run(["gh", "api", endpoint], capture_output=True, text=True)
    if response.returncode:
        if "HTTP 404" in response.stderr:
            return None
        raise RuntimeError(response.stderr)
    return json.loads(response.stdout)


def publish(root: Path, ref: str) -> None:
    commit = git(root, "rev-parse", f"{ref}^{{commit}}").decode().strip()
    subprocess.run(
        ["git", "-C", str(root), "merge-base", "--is-ancestor", commit, "origin/main"], check=True
    )
    path, checksum = check(root, commit)
    release_version = version(root, commit)
    metadata = json.loads(git(root, "show", f"{commit}:.release-assets.json"))
    binary_path, downloaded_metadata = download_binary(
        root, metadata["run_id"], checksum, release_version
    )
    if downloaded_metadata != metadata:
        raise ValueError("binary provenance differs from approved metadata")
    tag = f"v{release_version}"
    endpoint = f"repos/{REPOSITORY}"
    existing_tag = api_optional(f"{endpoint}/git/ref/tags/{tag}")
    if existing_tag is None:
        gh("api", f"{endpoint}/git/refs", "-f", f"ref=refs/tags/{tag}", "-f", f"sha={commit}")
    elif existing_tag["object"]["type"] != "commit" or existing_tag["object"]["sha"] != commit:
        raise ValueError("release tag already exists at a different object; never retag a release")
    release = api_optional(f"{endpoint}/releases/tags/{tag}")
    if release is None:
        gh(
            "release",
            "create",
            tag,
            "--repo",
            REPOSITORY,
            "--verify-tag",
            "--draft",
            "--title",
            f"solis-tools {release_version}",
            "--notes",
            f"Install or upgrade with Homebrew after publication.\n\nSee https://github.com/{REPOSITORY}/blob/{tag}/CHANGELOG.md for changes and upgrade precautions.\n\nArchive SHA-256: {checksum}",
        )
        release = api_optional(f"{endpoint}/releases/tags/{tag}")
    assert release is not None
    for asset_path, expected in ((path, checksum), (binary_path, metadata["sha256"])):
        asset = next((item for item in release["assets"] if item["name"] == asset_path.name), None)
        if asset is None:
            if not release["draft"]:
                raise ValueError("published release is missing an archive; refusing to mutate it")
            gh("release", "upload", tag, str(asset_path), "--repo", REPOSITORY)
        with tempfile.TemporaryDirectory() as directory:
            gh(
                "release",
                "download",
                tag,
                "--repo",
                REPOSITORY,
                "--pattern",
                asset_path.name,
                "--dir",
                directory,
            )
            downloaded = hashlib.sha256(
                (Path(directory) / asset_path.name).read_bytes()
            ).hexdigest()
            if downloaded != expected:
                raise ValueError("existing release asset differs; refusing to overwrite it")
    if release["draft"]:
        latest = api_optional(f"{endpoint}/releases/latest")
        latest_version = latest["tag_name"].removeprefix("v") if latest else "0.0.0"
        is_latest = tuple(map(int, release_version.split("."))) >= tuple(
            map(int, latest_version.split("."))
        )
        gh(
            "release",
            "edit",
            tag,
            "--repo",
            REPOSITORY,
            "--draft=false",
            f"--latest={str(is_latest).lower()}",
        )
    print(f"Verified published {tag}: {checksum}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=["prepare", "check", "build", "candidate", "publish", "changed"]
    )
    parser.add_argument("value", nargs="?")
    parser.add_argument("--binary-run", help="successful Release candidate run ID")
    args = parser.parse_args()
    if args.command == "prepare":
        if args.value is None or not re.fullmatch(r"\d+\.\d+\.\d+", args.value):
            parser.error("prepare requires X.Y.Z")
        synchronise_version(ROOT, args.value)
        if f"\n## {args.value}\n" not in (ROOT / "CHANGELOG.md").read_text():
            raise ValueError("add the release changelog section before preparation")
        path, checksum = build(ROOT)
        formula = ROOT / "Formula/solis-tools.rb"
        formula.write_text(
            update_formula(source_only_formula(formula.read_text()), url(args.value), checksum)
        )
        if args.binary_run:
            _, metadata = download_binary(ROOT, args.binary_run, checksum, args.value)
            (ROOT / ".release-assets.json").write_text(json.dumps(metadata, indent=2) + "\n")
            formula.write_text(binary_formula(formula.read_text(), metadata))
        else:
            (ROOT / ".release-assets.json").unlink(missing_ok=True)
        print(
            f"Prepared {path}: {checksum}; commit all version, changelog and formula changes together"
        )
    elif args.command == "changed":
        current = version(ROOT, "HEAD")
        previous = version(ROOT, args.value or "HEAD^")
        if current != previous:
            if tuple(map(int, current.split("."))) <= tuple(map(int, previous.split("."))):
                raise ValueError("release version must increase")
            check(ROOT)
            print("true")
        else:
            print("false")
    elif args.command == "publish":
        publish(ROOT, args.value or "HEAD")
    elif args.command == "check":
        print(check(ROOT, args.value or "HEAD")[0])
    else:
        path, checksum = build(ROOT, args.value or "HEAD")
        if args.command == "candidate":
            formula = ROOT / "Formula/solis-tools.rb"
            text = update_formula(formula.read_text(), path.as_uri(), checksum)
            metadata_path = ROOT / ".release-assets.json"
            candidate_metadata = (
                json.loads(metadata_path.read_text()) if metadata_path.exists() else None
            )
            if candidate_metadata and candidate_metadata.get("source_sha256") == checksum:
                metadata = candidate_metadata
                binary_path, downloaded = download_binary(
                    ROOT, metadata["run_id"], checksum, version(ROOT)
                )
                if downloaded != metadata:
                    raise ValueError("candidate binary differs from approved metadata")
                text = binary_formula(text, metadata).replace(
                    f"https://github.com/{REPOSITORY}/releases/download/v{metadata['version']}/{metadata['name']}",
                    binary_path.as_uri(),
                )
            else:
                text = source_only_formula(text)
            formula.write_text(text)
        print(path)


if __name__ == "__main__":
    main()
