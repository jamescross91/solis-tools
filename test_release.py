from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release@example.invalid")
        self.required = patch.object(release, "REQUIRED", {"solis_poll.py", "README.md"})
        self.required.start()
        self.addCleanup(self.required.stop)
        self.write("solis_poll.py", 'VERSION = "0.6.0"\n')
        self.write("README.md", "Release test\n")
        self.write("CHANGELOG.md", "# Changelog\n\n## 0.6.0\n")
        self.formula = (
            'class SolisTools < Formula\n  url "old"\n  sha256 "old"\n  def install\n  end\nend\n'
        )
        self.write("Formula/solis-tools.rb", self.formula)
        self.commit()

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL
        )

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture", "--allow-empty")

    def metadata(self, checksum):
        return {
            "version": "0.6.0",
            "source_sha256": checksum,
            "name": "solis-menubar-0.6.0-macos-universal.tar.gz",
            "sha256": hashlib.sha256(b"binary").hexdigest(),
            "run_id": "123",
        }

    def prepare_fixture(self):
        checksum = hashlib.sha256(release.archive(self.root, "0.6.0", "HEAD")).hexdigest()
        metadata = self.metadata(checksum)
        formula = release.update_formula(self.formula, release.url("0.6.0"), checksum)
        self.write("Formula/solis-tools.rb", release.binary_formula(formula, metadata))
        self.write(".release-assets.json", json.dumps(metadata))
        self.commit()
        return checksum

    def test_archive_is_identical_across_commits_formula_changes_and_file_times(self):
        before = release.archive(self.root, "0.6.0", "HEAD")
        self.write("Formula/solis-tools.rb", "different formula\n")
        self.write(".release-assets.json", "{}")
        self.commit()
        os.utime(self.root / "README.md", (1_700_000_000, 1_700_000_000))
        self.assertEqual(before, release.archive(self.root, "0.6.0", "HEAD"))
        self.assertEqual(before, release.archive(self.root, "0.6.0"))
        self.write("README.md", "Changed source\n")
        self.assertNotEqual(before, release.archive(self.root, "0.6.0"))

    def test_repeated_preparation_does_not_try_to_bump_the_same_version(self):
        with patch.object(release.subprocess, "run") as command:
            release.synchronise_version(self.root, "0.6.0")
            self.assertEqual(command.call_args.args[0][-1], "--write")
            release.synchronise_version(self.root, "0.6.1")
            self.assertEqual(command.call_args.args[0][-2:], ["--set", "0.6.1"])

    def test_archive_retains_executable_modes_and_symlinks(self):
        self.write("script.sh", "#!/bin/sh\n")
        os.chmod(self.root / "script.sh", 0o755)
        (self.root / "link").symlink_to("README.md")
        self.commit()
        data = release.archive(self.root, "0.6.0", "HEAD")
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            self.assertEqual(archive.getmember("solis-tools-0.6.0/script.sh").mode, 0o755)
            self.assertEqual(archive.getmember("solis-tools-0.6.0/link").linkname, "README.md")
            self.assertFalse(any("Formula/" in name for name in archive.getnames()))

    def test_missing_sources_and_unsafe_version_are_rejected(self):
        with self.assertRaises(ValueError):
            release.archive(self.root, "../../elsewhere")
        (self.root / "README.md").unlink()
        with self.assertRaisesRegex(ValueError, "missing required"):
            release.archive(self.root, "0.6.0")

    def test_prepared_release_matches_but_source_drift_fails(self):
        checksum = self.prepare_fixture()
        self.assertEqual(release.check(self.root)[1], checksum)
        self.write("README.md", "Changed after binary preparation\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "stale"):
            release.check(self.root)

    def test_binary_resource_is_idempotent_and_keeps_dependency_checksum(self):
        metadata = self.metadata("a" * 64)
        text = self.formula.replace(
            "  def install",
            '  resource "pymodbus" do\n    sha256 "dependency"\n  end\n  def install',
        )
        updated = release.binary_formula(text, metadata)
        self.assertEqual(release.binary_formula(updated, metadata), updated)
        self.assertEqual(updated.count('resource "solis-menubar"'), 1)
        self.assertIn('sha256 "dependency"', updated)
        self.assertIn('  resource "solis-menubar" do\n    on_macos do', updated)

    def test_source_preparation_removes_stale_prebuilt_resource(self):
        metadata = self.metadata("a" * 64)
        with_binary = release.binary_formula(self.formula, metadata)
        source_only = release.source_only_formula(with_binary)
        self.assertNotIn("BEGIN PREBUILT MACOS", source_only)
        self.assertEqual(source_only, self.formula)

    def test_binary_rejects_other_source_and_path_traversal(self):
        metadata = self.metadata("a" * 64)
        with self.assertRaisesRegex(ValueError, "does not match"):
            release.validate_binary(metadata, "0.6.0", "b" * 64)
        metadata["name"] = "../../binary"
        with self.assertRaisesRegex(ValueError, "archive name"):
            release.validate_binary(metadata, "0.6.0", "a" * 64)

    def test_download_checks_workflow_provenance_and_actual_bytes(self):
        metadata = self.metadata("a" * 64)

        def fake_gh(*args):
            if args[0] == "api":
                return json.dumps(
                    {"conclusion": "success", "path": ".github/workflows/release-candidate.yml"}
                )
            target = Path(args[args.index("--dir") + 1])
            (target / "metadata.json").write_text(json.dumps(metadata))
            (target / metadata["name"]).write_bytes(b"tampered")
            return ""

        with patch.object(release, "gh", side_effect=fake_gh):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                release.download_binary(self.root, "123", "a" * 64, "0.6.0")

    def test_api_network_error_is_not_treated_as_missing_release(self):
        failure = subprocess.CompletedProcess([], 1, "", "HTTP 403: forbidden")
        with patch.object(release.subprocess, "run", return_value=failure):
            with self.assertRaisesRegex(RuntimeError, "403"):
                release.api_optional("example")

    def test_publisher_refuses_to_move_existing_tag(self):
        self.prepare_fixture()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        metadata = json.loads((self.root / ".release-assets.json").read_text())
        binary = self.root / "binary.tar.gz"
        binary.write_bytes(b"binary")
        with (
            patch.object(release, "download_binary", return_value=(binary, metadata)),
            patch.object(
                release,
                "api_optional",
                return_value={"object": {"type": "commit", "sha": "different"}},
            ),
            patch.object(release, "gh") as remote,
        ):
            with self.assertRaisesRegex(ValueError, "never retag"):
                release.publish(self.root, "HEAD")
            remote.assert_not_called()

    def test_publisher_refuses_to_overwrite_mismatched_public_asset(self):
        self.prepare_fixture()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        metadata = json.loads((self.root / ".release-assets.json").read_text())
        source, _ = release.check(self.root)
        binary = self.root / metadata["name"]
        binary.write_bytes(b"binary")
        commit = self.git("rev-parse", "HEAD").decode().strip()
        responses = [
            {"object": {"type": "commit", "sha": commit}},
            {"draft": False, "assets": [{"name": source.name}, {"name": binary.name}]},
        ]

        def fake_gh(*args):
            self.assertEqual(args[:2], ("release", "download"))
            directory = Path(args[args.index("--dir") + 1])
            (directory / args[args.index("--pattern") + 1]).write_bytes(b"wrong bytes")
            return ""

        with (
            patch.object(release, "download_binary", return_value=(binary, metadata)),
            patch.object(release, "api_optional", side_effect=responses),
            patch.object(release, "gh", side_effect=fake_gh),
        ):
            with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
                release.publish(self.root, "HEAD")


if __name__ == "__main__":
    unittest.main()
