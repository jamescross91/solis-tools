"""Octopus client, credentials and schedule monitor against fake_octopus.py."""

from __future__ import annotations

import stat
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fake_octopus import FAKE_API_KEY, FakeOctopusApi
from octopus_client import (
    ChargeWindow,
    OctopusAuthError,
    OctopusClient,
    OctopusCredentials,
    OctopusError,
    OctopusSchedule,
    OctopusScheduleMonitor,
    merge_windows,
)

LOGIN = str(Path(__file__).with_name("octopus_login.py"))
NOW = datetime(2026, 9, 27, 22, 0, tzinfo=timezone.utc)


def client_for(fake: FakeOctopusApi, **credentials: str) -> OctopusClient:
    return OctopusClient(
        OctopusCredentials(credentials.pop("api_key", FAKE_API_KEY), **credentials),
        host="127.0.0.1",
        port=fake.port,
        use_tls=False,
    )


def window(start_min: float, end_min: float, kind: str = "SMART") -> ChargeWindow:
    return ChargeWindow(NOW + timedelta(minutes=start_min), NOW + timedelta(minutes=end_min), kind)


class CredentialsTests(unittest.TestCase):
    def test_saved_credentials_are_owner_only_and_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state" / "octopus.json"
            OctopusCredentials(FAKE_API_KEY, "A-1234ABCD", "device-1").save(path)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            loaded = OctopusCredentials.load(path)
        self.assertEqual(loaded, OctopusCredentials(FAKE_API_KEY, "A-1234ABCD", "device-1"))

    def test_a_missing_file_names_the_command_that_writes_it(self):
        with self.assertRaisesRegex(OctopusAuthError, "octopus-login"):
            OctopusCredentials.load(Path("/nonexistent/octopus.json"))

    def test_values_that_could_alter_a_query_are_refused(self):
        """Values are embedded in GraphQL text, so the format check is the
        injection guard, not a nicety."""
        for credentials in (
            OctopusCredentials('sk_live_abc" } evil'),
            OctopusCredentials(FAKE_API_KEY, account_number='A-1") { x'),
            OctopusCredentials(FAKE_API_KEY, device_id="dev ice"),
        ):
            with self.subTest(credentials=credentials), self.assertRaises(OctopusAuthError):
                credentials.validate()


class ClientTests(unittest.TestCase):
    def test_discovers_the_account_and_device_then_reads_the_plan(self):
        with FakeOctopusApi() as fake:
            fake.plan_charge(600, 3600, "BOOST")
            client = client_for(fake)
            windows = client.planned_dispatches()
        self.assertEqual(client.credentials.account_number, "A-1234ABCD")
        self.assertEqual(client.credentials.device_id, fake.devices[0])
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0].kind, "BOOST")
        self.assertEqual(windows[0].end - windows[0].start, timedelta(hours=1))
        self.assertEqual(windows[0].start.tzinfo, timezone.utc)

    def test_one_token_serves_repeated_refreshes(self):
        with FakeOctopusApi() as fake:
            client = client_for(fake, device_id=fake.devices[0])
            for _ in range(3):
                client.planned_dispatches()
            self.assertEqual(fake.token_requests, 1)

    def test_a_revoked_token_is_renewed_once_and_the_query_retried(self):
        with FakeOctopusApi() as fake:
            client = client_for(fake, device_id=fake.devices[0])
            client.planned_dispatches()
            fake.expire_tokens()
            client.planned_dispatches()
            self.assertEqual(fake.token_requests, 2)

    def test_a_refused_key_is_an_auth_error(self):
        with FakeOctopusApi() as fake:
            fake.refuse_key = True
            with self.assertRaisesRegex(OctopusAuthError, "KT-CT-1139"):
                client_for(fake).planned_dispatches()

    def test_several_devices_must_be_chosen_explicitly(self):
        with FakeOctopusApi(devices=("car-1", "car-2")) as fake:
            with self.assertRaisesRegex(OctopusAuthError, "--device"):
                client_for(fake).planned_dispatches()

    def test_a_dispatch_without_a_utc_offset_is_rejected(self):
        """A naive time could be read as UTC or local; around a clock change
        that puts the tightened band in the wrong hour."""
        with FakeOctopusApi() as fake:
            fake.dispatches = [
                {"start": "2026-09-27T23:30:00", "end": "2026-09-28T00:30:00", "type": "SMART"}
            ]
            with self.assertRaisesRegex(Exception, "no UTC offset"):
                client_for(fake).planned_dispatches()


class ScheduleTests(unittest.TestCase):
    def test_touching_half_hour_slots_merge_into_one_charge(self):
        merged = merge_windows([window(30, 60), window(0, 30), window(90, 120, "BOOST")])
        self.assertEqual(merged, (window(0, 60), window(90, 120, "BOOST")))

    def test_the_band_applies_from_the_lead_time_until_the_end(self):
        schedule = OctopusSchedule((window(10, 40),))
        self.assertIsNone(schedule.active_window(NOW, 300))
        self.assertEqual(schedule.next_window(NOW, 300), window(10, 40))
        self.assertIsNotNone(schedule.active_window(NOW + timedelta(minutes=5), 300))
        self.assertIsNotNone(schedule.active_window(NOW + timedelta(minutes=39), 300))
        self.assertIsNone(schedule.active_window(NOW + timedelta(minutes=40), 300))


class FakeClient:
    """Scripted planned_dispatches results, for driving the monitor's rules."""

    timeout = 1.0

    def __init__(self) -> None:
        self.results: list[list[ChargeWindow] | Exception] = []

    def planned_dispatches(self) -> list[ChargeWindow]:
        result = self.results.pop(0)
        if isinstance(result, Exception):
            raise result
        return list(result)


class MonitorTests(unittest.TestCase):
    def monitor(self, client: FakeClient, now: list[datetime]) -> OctopusScheduleMonitor:
        return OctopusScheduleMonitor(
            client,  # type: ignore[arg-type]
            lead_time_s=300,
            clock=lambda: now[0],
        )

    def test_a_failed_refresh_keeps_the_known_plan(self):
        client, now = FakeClient(), [NOW]
        monitor = self.monitor(client, now)
        client.results = [[window(30, 90)], OctopusError("Octopus API answered HTTP 503")]
        monitor.refresh()
        schedule = monitor.refresh()
        self.assertEqual(schedule.windows, (window(30, 90),))
        self.assertIn("503", schedule.last_error or "")
        self.assertEqual(monitor.consecutive_failures, 1)

    def test_a_running_charge_survives_being_dropped_from_the_plan(self):
        client, now = FakeClient(), [NOW]
        monitor = self.monitor(client, now)
        client.results = [[window(-10, 50)], []]
        monitor.refresh()
        now[0] = NOW + timedelta(minutes=5)
        schedule = monitor.refresh()
        self.assertEqual(schedule.windows, (window(-10, 50),))

    def test_a_cancellation_before_the_charge_starts_is_honoured(self):
        """Inside the lead-in the band is already tight, but the charge has
        not started, so Octopus withdrawing it must relax the band."""
        client, now = FakeClient(), [NOW]
        monitor = self.monitor(client, now)
        client.results = [[window(2, 60)], []]
        monitor.refresh()
        self.assertIsNotNone(monitor.snapshot().active_window(NOW, 300))
        schedule = monitor.refresh()
        self.assertEqual(schedule.windows, ())

    def test_finished_charges_are_pruned(self):
        client, now = FakeClient(), [NOW]
        monitor = self.monitor(client, now)
        client.results = [[window(-60, -1), window(60, 90)]]
        self.assertEqual(monitor.refresh().windows, (window(60, 90),))

    def test_the_background_thread_publishes_and_stops(self):
        with FakeOctopusApi() as fake:
            fake.plan_charge(0, 600)
            monitor = OctopusScheduleMonitor(client_for(fake), interval_s=60, lead_time_s=0)
            monitor.start()
            try:
                for _ in range(100):
                    if monitor.snapshot().fetched_at is not None:
                        break
                    time.sleep(0.02)
            finally:
                monitor.stop()
        schedule = monitor.snapshot()
        self.assertIsNotNone(schedule.active_window(datetime.now(timezone.utc), 0))


class LoginTests(unittest.TestCase):
    def run_login(self, fake: FakeOctopusApi, path: Path, key: str, *extra: str):
        return subprocess.run(
            [
                sys.executable,
                LOGIN,
                "--credentials",
                str(path),
                "--host",
                "127.0.0.1",
                "--port",
                str(fake.port),
                "--insecure",
                *extra,
            ],
            input=key + "\n",
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_a_valid_key_is_saved_with_the_discovered_account_and_device(self):
        with tempfile.TemporaryDirectory() as directory, FakeOctopusApi() as fake:
            path = Path(directory) / "octopus.json"
            result = self.run_login(fake, path, FAKE_API_KEY)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Saved Octopus credentials for account A-1234ABCD", result.stdout)
            self.assertNotIn(FAKE_API_KEY, result.stdout + result.stderr)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(OctopusCredentials.load(path).device_id, fake.devices[0])

    def test_a_refused_key_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory, FakeOctopusApi() as fake:
            fake.refuse_key = True
            path = Path(directory) / "octopus.json"
            result = self.run_login(fake, path, FAKE_API_KEY)
            self.assertEqual(result.returncode, 1)
            self.assertIn("error: Octopus refused the API key", result.stderr)
            self.assertFalse(path.exists())

    def test_a_malformed_key_is_rejected_before_any_request(self):
        with tempfile.TemporaryDirectory() as directory, FakeOctopusApi() as fake:
            result = self.run_login(fake, Path(directory) / "octopus.json", "not-a-key")
            self.assertEqual(result.returncode, 2)
            self.assertEqual(fake.queries, [])


if __name__ == "__main__":
    unittest.main()
