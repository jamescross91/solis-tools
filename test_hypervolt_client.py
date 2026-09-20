"""Exercises hypervolt_client.py against fake_hypervolt.py.

Hypervolt's API is undocumented and reverse-engineered (see
docs/hypervolt-integration.md); these tests pin the wire behaviour this
project depends on so a change on either side fails here, the same role
test_end_to_end.py plays for fake_inverter.py.
"""

from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path

from fake_hypervolt import FakeHypervoltCloud
from hypervolt_client import (
    HypervoltAuthError,
    HypervoltClient,
    HypervoltCredentials,
    HypervoltError,
    HypervoltProtocolError,
)


def make_client(fake: FakeHypervoltCloud, **overrides) -> HypervoltClient:
    credentials = HypervoltCredentials(refresh_token=fake.refresh_token)
    kwargs = {
        "timeout": 5.0,
        "token_host": "127.0.0.1",
        "token_port": fake.port,
        "api_host": "127.0.0.1",
        "api_port": fake.port,
        "use_tls": False,
    }
    kwargs.update(overrides)
    return HypervoltClient(credentials, **kwargs)


class CredentialsTests(unittest.TestCase):
    def test_missing_file_fails_closed_with_a_setup_hint(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(HypervoltAuthError, "hypervolt_login.py"):
                HypervoltCredentials.load(Path(directory) / "missing.json")

    def test_round_trips_and_is_written_owner_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hypervolt.json"
            HypervoltCredentials(refresh_token="abc123", charger_id="deadbeef").save(path)
            self.assertEqual(oct(path.stat().st_mode)[-3:], "600")
            restored = HypervoltCredentials.load(path)
            self.assertEqual(restored.refresh_token, "abc123")
            self.assertEqual(restored.charger_id, "deadbeef")

    def test_a_credentials_file_never_contains_a_password(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hypervolt.json"
            HypervoltCredentials(refresh_token="abc123").save(path)
            self.assertNotIn("password", path.read_text(encoding="utf-8"))


class ClientLifecycleTests(unittest.TestCase):
    def test_connect_discovers_the_charger_and_reads_the_snapshot(self):
        with FakeHypervoltCloud() as fake:
            client = make_client(fake)
            client.connect()
            try:
                self.assertEqual(client.charger_id, fake.charger_id)
                self.assertTrue(client.state.connected)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and client.state.max_current_ma is None:
                    client.poll()
                    time.sleep(0.01)
                self.assertEqual(client.state.max_current_ma, 32000)
            finally:
                client.close()

    def test_a_stored_charger_id_skips_discovery(self):
        with FakeHypervoltCloud(charger_id="already-known") as fake:
            client = make_client(fake)
            client.credentials.charger_id = "already-known"
            client.charger_id = "already-known"
            client.connect()
            try:
                self.assertEqual(len(fake.token_requests), 1)
            finally:
                client.close()

    def test_refresh_token_is_rotated_and_persisted_by_the_caller(self):
        with FakeHypervoltCloud() as fake:
            original_refresh = fake.refresh_token
            client = make_client(fake)
            client.connect()
            try:
                self.assertNotEqual(client.credentials.refresh_token, original_refresh)
                self.assertEqual(fake.token_requests[0]["grant_type"], "refresh_token")
                self.assertEqual(fake.token_requests[0]["refresh_token"], original_refresh)
            finally:
                client.close()

    def test_an_invalid_refresh_token_fails_closed(self):
        with FakeHypervoltCloud() as fake:
            fake.refuse_tokens = True
            client = make_client(fake)
            with self.assertRaises(HypervoltAuthError):
                client.connect()

    def test_an_account_with_no_chargers_fails_closed(self):
        with FakeHypervoltCloud() as fake:
            fake.charger_id = ""
            client = make_client(fake)
            with self.assertRaises(HypervoltAuthError):
                client.connect()


class TelemetryAndControlTests(unittest.TestCase):
    def test_charging_state_arrives_on_poll_and_expires_when_stale(self):
        with FakeHypervoltCloud() as fake:
            client = make_client(fake)
            client.connect()
            try:
                self.assertFalse(client.state.is_charging(time.monotonic(), stale_age_s=30))
                fake.set_charging(True, true_milli_amps=32000, watt_hours=500)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and client.state.charging is not True:
                    client.poll()
                    time.sleep(0.01)
                state = client.state
                self.assertTrue(state.charging)
                self.assertEqual(state.true_milli_amps, 32000)
                self.assertEqual(state.watt_hours, 500)
                self.assertTrue(state.is_charging(time.monotonic(), stale_age_s=30))
                # Fail closed: telemetry older than the configured age is not
                # trusted, so a stalled connection reads as "not charging"
                # rather than as whatever it last confirmed.
                self.assertFalse(state.is_charging(time.monotonic() + 60, stale_age_s=30))
            finally:
                client.close()

    def test_set_max_current_round_trips_through_a_confirmed_push(self):
        with FakeHypervoltCloud() as fake:
            client = make_client(fake)
            client.connect()
            try:
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and client.state.max_current_ma is None:
                    client.poll()
                    time.sleep(0.01)
                self.assertEqual(client.state.max_current_ma, 32000)
                client.set_max_current_ma(6000)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and client.state.max_current_ma != 6000:
                    client.poll()
                    time.sleep(0.01)
                self.assertEqual(client.state.max_current_ma, 6000)
                self.assertEqual(fake.applied[-1], {"max_current": 6000})
            finally:
                client.close()

    def test_set_max_current_is_clamped_to_hardware_bounds(self):
        with FakeHypervoltCloud() as fake:
            client = make_client(fake)
            client.connect()
            try:
                client.set_max_current_ma(1)
                client.poll()
                client.set_max_current_ma(999_999)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and len(fake.applied) < 2:
                    client.poll()
                    time.sleep(0.01)
                self.assertEqual(fake.applied[0]["max_current"], 6000)
                self.assertEqual(fake.applied[1]["max_current"], 32000)
            finally:
                client.close()

    def test_set_charging_enabled_false_pauses_and_is_visible_on_the_session_socket(self):
        with FakeHypervoltCloud() as fake:
            client = make_client(fake)
            client.connect()
            try:
                fake.set_charging(True, true_milli_amps=16000)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and client.state.charging is not True:
                    client.poll()
                    time.sleep(0.01)
                client.set_charging_enabled(False)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and client.state.charging is not False:
                    client.poll()
                    time.sleep(0.01)
                self.assertFalse(client.state.charging)
                self.assertEqual(fake.applied[-1], {"release": True})
            finally:
                client.close()

    def test_a_dropped_connection_surfaces_as_a_protocol_error(self):
        with FakeHypervoltCloud() as fake:
            client = make_client(fake)
            client.connect()
            fake.drop_all_connections()
            with self.assertRaises(HypervoltProtocolError):
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    client.poll()
                    time.sleep(0.05)

    def test_poll_before_connect_fails_closed_rather_than_crashing_oddly(self):
        with FakeHypervoltCloud() as fake:
            client = make_client(fake)
            with self.assertRaises(HypervoltError):
                client.poll()


if __name__ == "__main__":
    unittest.main()
