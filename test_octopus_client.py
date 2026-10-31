"""Octopus client, credentials and schedule monitor against fake_octopus.py."""

from __future__ import annotations

import json
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from fake_octopus import FAKE_API_KEY, FakeOctopusApi
from octopus_client import (
    ChargeWindow,
    HubPlanFile,
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


def client_for(fake: FakeOctopusApi, **credentials: Any) -> OctopusClient:
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
            OctopusCredentials(FAKE_API_KEY, "A-1234ABCD", ["device-1"]).save(path)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            loaded = OctopusCredentials.load(path)
        self.assertEqual(loaded, OctopusCredentials(FAKE_API_KEY, "A-1234ABCD", ["device-1"]))

    def test_a_file_from_before_the_device_list_is_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "octopus.json"
            OctopusCredentials(FAKE_API_KEY, "A-1234ABCD", ["car-1"]).save(path)
            # Rewritten in place, as 0.9.0 and earlier wrote it: no list.
            saved = json.loads(path.read_text())
            del saved["device_ids"]
            with path.open("w", encoding="utf-8") as destination:
                json.dump(saved, destination)
            self.assertEqual(OctopusCredentials.load(path).device_ids, ["car-1"])

    def test_the_first_device_is_saved_for_readers_of_the_older_file(self):
        """The Wattlark hub shows `device_id` from this file."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "octopus.json"
            OctopusCredentials(FAKE_API_KEY, "A-1234ABCD", ["car-1", "charger-2"]).save(path)
            saved = json.loads(path.read_text())
        self.assertEqual(saved["device_id"], "car-1")
        self.assertEqual(saved["device_ids"], ["car-1", "charger-2"])

    def test_a_missing_file_names_the_command_that_writes_it(self):
        with self.assertRaisesRegex(OctopusAuthError, "octopus-login"):
            OctopusCredentials.load(Path("/nonexistent/octopus.json"))

    def test_values_that_could_alter_a_query_are_refused(self):
        """Values are embedded in GraphQL text, so the format check is the
        injection guard, not a nicety."""
        for credentials in (
            OctopusCredentials('sk_live_abc" } evil'),
            OctopusCredentials(FAKE_API_KEY, account_number='A-1") { x'),
            OctopusCredentials(FAKE_API_KEY, device_ids=["dev ice"]),
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
            client = client_for(fake, device_ids=[fake.devices[0]])
            for _ in range(3):
                client.planned_dispatches()
            self.assertEqual(fake.token_requests, 1)

    def test_a_token_renewal_and_its_query_share_one_connection(self):
        with FakeOctopusApi() as fake:
            client = client_for(fake, device_ids=[fake.devices[0]])
            client.planned_dispatches()
            # The token, the account, its devices and the device's plan.
            self.assertEqual(len(fake.queries), 4)
            self.assertEqual(fake.connections, 1)
            client.planned_dispatches()
            # A new refresh opens afresh rather than reuse a connection the
            # server would long since have dropped.
            self.assertEqual(fake.connections, 2)

    def test_a_revoked_token_is_renewed_once_and_the_query_retried(self):
        with FakeOctopusApi() as fake:
            client = client_for(fake, device_ids=[fake.devices[0]])
            client.planned_dispatches()
            fake.expire_tokens()
            client.planned_dispatches()
            self.assertEqual(fake.token_requests, 2)

    def test_a_car_enrolled_again_is_followed_to_its_new_device(self):
        """Octopus answers the old ID with an empty plan, not an error, so the
        client must not keep asking about it."""
        changed: list[list[str]] = []
        with FakeOctopusApi(devices=("car-old",)) as fake:
            client = client_for(fake, account_number="A-1234ABCD", device_ids=["car-old"])
            client.on_devices_changed = lambda credentials: changed.append(
                list(credentials.device_ids)
            )
            fake.reenrol("car-old", "car-new")
            fake.plan_device_charge("car-new", 600, 3600)
            windows = client.planned_dispatches()
            self.assertEqual(len(windows), 1)
            self.assertEqual(client.credentials.device_ids, ["car-new"])
            self.assertEqual(changed, [["car-new"]])
            self.assertFalse(any('"car-old"' in query for query in fake.queries))
            # Unchanged devices are not reported again.
            client.planned_dispatches()
            self.assertEqual(changed, [["car-new"]])

    def test_a_device_added_to_the_account_is_read_too(self):
        with FakeOctopusApi(devices=("car-1",)) as fake:
            client = client_for(fake, device_ids=["car-1"])
            fake.plan_device_charge("car-1", 600, 1800)
            self.assertEqual(len(client.planned_dispatches()), 1)
            fake.devices = ("car-1", "charger-2")
            fake.plan_device_charge("charger-2", 7200, 1800, "BOOST")
            windows = client.planned_dispatches()
        self.assertEqual(client.credentials.device_ids, ["car-1", "charger-2"])
        self.assertEqual(sorted(window.kind for window in windows), ["BOOST", "SMART"])

    def test_a_failed_device_listing_falls_back_to_the_cached_devices(self):
        with FakeOctopusApi() as fake:
            fake.plan_charge(600, 1800)
            client = client_for(fake, device_ids=[fake.devices[0]])
            fake.refuse_devices = True
            self.assertEqual(len(client.planned_dispatches()), 1)
            self.assertEqual(client.credentials.device_ids, [fake.devices[0]])

    def test_a_failed_device_listing_with_nothing_cached_fails_the_refresh(self):
        with FakeOctopusApi() as fake:
            fake.refuse_devices = True
            with self.assertRaisesRegex(OctopusError, "Too many requests"):
                client_for(fake).planned_dispatches()

    def test_an_account_with_no_devices_is_a_transient_error_not_an_auth_one(self):
        """A car being enrolled again is briefly on no device; the monitor
        must keep the last plan rather than treat it as a configuration fault."""
        with FakeOctopusApi(devices=()) as fake:
            with self.assertRaises(OctopusError) as raised:
                client_for(fake, device_ids=["car-1"]).planned_dispatches()
        self.assertNotIsInstance(raised.exception, OctopusAuthError)
        self.assertIn("no Intelligent Octopus device", str(raised.exception))

    def test_a_refused_key_is_an_auth_error(self):
        with FakeOctopusApi() as fake:
            fake.refuse_key = True
            with self.assertRaisesRegex(OctopusAuthError, "KT-CT-1139"):
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

    def test_window_at_says_when_its_answer_next_changes(self):
        schedule = OctopusSchedule((window(10, 40), window(90, 120)))
        self.assertEqual(schedule.window_at(NOW, 300), (None, NOW + timedelta(minutes=5)))
        self.assertEqual(
            schedule.window_at(NOW + timedelta(minutes=6), 300),
            (window(10, 40), NOW + timedelta(minutes=40)),
        )
        self.assertEqual(
            schedule.window_at(NOW + timedelta(minutes=40), 300),
            (None, NOW + timedelta(minutes=85)),
        )
        self.assertEqual(schedule.window_at(NOW + timedelta(minutes=120), 300), (None, None))


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

    def test_dispatches_are_octopus_plan_as_sent_while_the_band_keeps_a_running_charge(self):
        """Octopus shortens a charge already under way and splits off a later
        one. The band keeps the running window to its old end; `dispatches`
        says what Octopus now plans, gap included."""
        client, now = FakeClient(), [NOW]
        monitor = self.monitor(client, now)
        client.results = [[window(-10, 120)], [window(-10, 40), window(60, 120)]]
        monitor.refresh()
        now[0] = NOW + timedelta(minutes=5)
        schedule = monitor.refresh()
        self.assertEqual(schedule.windows, (window(-10, 120),))
        self.assertEqual(schedule.dispatches, (window(-10, 40), window(60, 120)))
        sent = schedule.stream_dict(now[0], 300)["dispatches"]
        self.assertEqual(
            [(d["start"], d["end"]) for d in sent],
            [
                (window(-10, 40).stream_dict()["start"], window(-10, 40).stream_dict()["end"]),
                (window(60, 120).stream_dict()["start"], window(60, 120).stream_dict()["end"]),
            ],
        )

    def test_a_failed_refresh_keeps_the_known_dispatches(self):
        client, now = FakeClient(), [NOW]
        monitor = self.monitor(client, now)
        client.results = [[window(30, 90)], OctopusError("Octopus API answered HTTP 503")]
        monitor.refresh()
        self.assertEqual(monitor.refresh().dispatches, (window(30, 90),))

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


class HubPlanFileTests(unittest.TestCase):
    """Under the Wattlark hub the plan comes from a file the hub writes, and
    this side never talks to Octopus."""

    def setUp(self) -> None:
        self._directory = tempfile.TemporaryDirectory()
        self.path = Path(self._directory.name) / "octopus-plan.json"
        self.now = [NOW]
        self.source = HubPlanFile(self.path, clock=lambda: self.now[0])

    def tearDown(self) -> None:
        self._directory.cleanup()

    def write(self, fetched_min: float | None, planned: list[ChargeWindow], error=None) -> None:
        fetched = None if fetched_min is None else NOW + timedelta(minutes=fetched_min)
        self.path.write_text(
            json.dumps(
                {
                    "fetched_at": fetched.isoformat() if fetched else None,
                    "planned": [
                        {"start": w.start.isoformat(), "end": w.end.isoformat(), "kind": w.kind}
                        for w in planned
                    ],
                    "error": error,
                }
            )
        )

    def test_the_hubs_plan_is_read_as_sent(self):
        self.write(-2, [window(30, 60), window(60, 90, "BOOST")])
        self.assertEqual(
            self.source.planned_dispatches(), [window(30, 60), window(60, 90, "BOOST")]
        )

    def test_no_file_yet_is_a_transient_error(self):
        with self.assertRaisesRegex(OctopusError, "not written"):
            self.source.planned_dispatches()

    def test_a_stale_plan_fails_with_the_hubs_own_error(self):
        self.write(-16, [window(30, 60)], error="Octopus refused the request (HTTP 429)")
        with self.assertRaisesRegex(OctopusError, "16 minutes old: Octopus refused"):
            self.source.planned_dispatches()

    def test_a_hub_that_never_read_octopus_says_why(self):
        self.write(None, [], error="switched off")
        with self.assertRaisesRegex(OctopusError, "switched off"):
            self.source.planned_dispatches()

    def test_a_damaged_file_is_a_protocol_error(self):
        self.path.write_text("[1, 2]")
        with self.assertRaises(OctopusError):
            self.source.planned_dispatches()
        self.path.write_text("{not json")
        with self.assertRaisesRegex(OctopusError, "cannot read"):
            self.source.planned_dispatches()

    def test_the_monitor_keeps_the_last_plan_when_the_file_goes_stale(self):
        monitor = OctopusScheduleMonitor(self.source, lead_time_s=300, clock=lambda: self.now[0])
        self.write(-1, [window(30, 90)])
        monitor.refresh()
        self.now[0] = NOW + timedelta(minutes=20)
        schedule = monitor.refresh()
        self.assertEqual(schedule.windows, (window(30, 90),))
        self.assertIn("minutes old", schedule.last_error or "")


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

    def test_every_device_on_the_account_is_saved(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            FakeOctopusApi(devices=("car-1", "charger-2")) as fake,
        ):
            path = Path(directory) / "octopus.json"
            result = self.run_login(fake, path, FAKE_API_KEY)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("car-1, charger-2", result.stdout)
            self.assertEqual(OctopusCredentials.load(path).device_ids, ["car-1", "charger-2"])

    def test_a_device_that_is_not_on_the_account_is_refused(self):
        """The menu-bar form still offers a device field, which passes --device."""
        with (
            tempfile.TemporaryDirectory() as directory,
            FakeOctopusApi(devices=("car-1", "charger-2")) as fake,
        ):
            path = Path(directory) / "octopus.json"
            chosen = self.run_login(fake, path, FAKE_API_KEY, "--device", "charger-2")
            self.assertEqual(chosen.returncode, 0, chosen.stderr)
            missing = self.run_login(fake, path, FAKE_API_KEY, "--device", "car-9")
            self.assertEqual(missing.returncode, 1)
            self.assertIn("car-9 is not on account A-1234ABCD", missing.stderr)
            self.assertIn("car-1, charger-2", missing.stderr)

    def test_output_matches_what_the_menu_bar_parses(self):
        """OctopusLoginRunner.swift keys on these exact prefixes."""
        with tempfile.TemporaryDirectory() as directory, FakeOctopusApi() as fake:
            path = Path(directory) / "octopus.json"
            good = self.run_login(fake, path, FAKE_API_KEY)
            fake.refuse_key = True
            bad = self.run_login(fake, path, FAKE_API_KEY)
        self.assertTrue(good.stdout.splitlines()[0].startswith("Saved Octopus credentials"))
        self.assertTrue(
            any(line.startswith("error: ") for line in bad.stderr.splitlines()), bad.stderr
        )

    def test_an_api_key_given_as_the_credentials_path_is_rejected_unechoed(self):
        """Passing the key as --credentials leaks it into shell history, so the
        script refuses before prompting and must not repeat it in its output."""
        with tempfile.TemporaryDirectory() as directory, FakeOctopusApi() as fake:
            result = self.run_login(fake, Path(FAKE_API_KEY), FAKE_API_KEY)
            self.assertEqual(result.returncode, 2)
            self.assertIn("looks like an API key, not a file path", result.stderr)
            self.assertNotIn(FAKE_API_KEY, result.stdout + result.stderr)
            self.assertFalse((Path(directory) / FAKE_API_KEY).exists())
            self.assertFalse(Path(FAKE_API_KEY).exists())

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
