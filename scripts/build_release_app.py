#!/usr/bin/env python3
"""Build a signed universal macOS app once; publication reuses these bytes."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from release import ROOT, build, version


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def main() -> None:
    release_version = version(ROOT)
    _, source_checksum = build(ROOT, "HEAD")
    output = ROOT / "build/macos-candidate"
    output.mkdir(parents=True, exist_ok=True)
    name = f"solis-menubar-{release_version}-macos-universal.tar.gz"
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        binaries = []
        for architecture in ("arm64", "x86_64"):
            arguments = [
                "swift",
                "build",
                "--disable-sandbox",
                "--configuration",
                "release",
                "--package-path",
                str(ROOT / "SolisMenuBar"),
                "--scratch-path",
                str(directory / architecture),
                "--triple",
                f"{architecture}-apple-macosx13.0",
            ]
            run(*arguments)
            binary_directory = subprocess.check_output(
                [*arguments, "--show-bin-path"], text=True
            ).strip()
            binaries.append(str(Path(binary_directory) / "SolisMenuBar"))
        app = directory / "SolisMenuBar.app"
        executable = app / "Contents/MacOS/SolisMenuBar"
        executable.parent.mkdir(parents=True)
        run("lipo", "-create", *binaries, "-output", str(executable))
        run("lipo", str(executable), "-verify_arch", "arm64", "x86_64")
        shutil.copy2(ROOT / "SolisMenuBar/Resources/Info.plist", app / "Contents/Info.plist")
        run("codesign", "--force", "--sign", "-", str(app))
        run("codesign", "--verify", "--strict", str(app))
        reported = subprocess.check_output([str(executable), "--version"], text=True).strip()
        if reported != f"solis-menubar {release_version}":
            raise ValueError(f"unexpected compiled version: {reported}")
        notice = directory / "INSTALL.txt"
        notice.write_text(
            "Install using Homebrew so the matching Python poller is also installed.\n"
        )
        with tarfile.open(output / name, "w:gz") as archive:
            archive.add(app, arcname=app.name)
            archive.add(notice, arcname=notice.name)
    metadata = {
        "version": release_version,
        "source_sha256": source_checksum,
        "name": name,
        "sha256": hashlib.sha256((output / name).read_bytes()).hexdigest(),
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
