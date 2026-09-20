"""End-to-end tests that run the real hypervolt-login CLI against a fake
Hypervolt cloud.

The SolisMenuBar app's sign-in form drives this exact script as a
subprocess: its arguments, its stdin handling and the exact text of its
stdout/stderr are a contract the Swift side depends on, so that contract is
pinned here rather than only proven by running the app.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from fake_hypervolt import FakeHypervoltCloud

LOGIN = str(Path(__file__).with_name("hypervolt_login.py"))
TIMEOUT = 10


def run_login(
    fake: FakeHypervoltCloud,
    credentials_path: Path,
    *,
    password: str = "hunter2",
    email: str = "driver@example.com",
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            LOGIN,
            "--credentials",
            str(credentials_path),
            "--email",
            email,
            "--token-host",
            "127.0.0.1",
            "--token-port",
            str(fake.port),
            "--api-host",
            "127.0.0.1",
            "--api-port",
            str(fake.port),
            "--insecure",
        ],
        input=password + "\n",
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
        check=False,
    )


class HypervoltLoginTests(unittest.TestCase):
    def test_a_successful_sign_in_saves_owner_only_credentials(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            FakeHypervoltCloud(charger_id="abc123") as fake,
        ):
            credentials_path = Path(directory) / "hypervolt.json"
            process = run_login(fake, credentials_path)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertIn("Saved a Hypervolt refresh token for charger abc123", process.stdout)
            self.assertIn("password was not stored", process.stdout)
            self.assertEqual(oct(credentials_path.stat().st_mode)[-3:], "600")
            saved_text = credentials_path.read_text(encoding="utf-8")
            self.assertNotIn("password", saved_text)
            saved = json.loads(saved_text)
            self.assertEqual(saved["charger_id"], "abc123")
            self.assertEqual(saved["refresh_token"], fake.refresh_token)

    def test_a_refused_login_fails_closed_without_writing_a_file(self):
        with tempfile.TemporaryDirectory() as directory, FakeHypervoltCloud() as fake:
            fake.refuse_tokens = True
            credentials_path = Path(directory) / "hypervolt.json"
            process = run_login(fake, credentials_path)
            self.assertEqual(process.returncode, 1)
            self.assertIn("error: Hypervolt login was refused", process.stderr)
            self.assertFalse(credentials_path.exists())

    def test_missing_password_is_rejected_before_any_network_call(self):
        with tempfile.TemporaryDirectory() as directory, FakeHypervoltCloud() as fake:
            credentials_path = Path(directory) / "hypervolt.json"
            process = run_login(fake, credentials_path, password="")
            self.assertEqual(process.returncode, 2)
            self.assertIn("both an email and a password are required", process.stderr)
            self.assertEqual(fake.token_requests, [])
            self.assertFalse(credentials_path.exists())


if __name__ == "__main__":
    unittest.main()
