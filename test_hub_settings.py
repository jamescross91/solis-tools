"""Control settings and service sign-in through solis-hub's HTTP API.

The hub runs against fake pollers (as in test_solis_hub.py), so nothing here
talks to an inverter. Sign-in runs stub login commands, except one test that
drives the real octopus_login.py against fake_octopus.py.
"""

from __future__ import annotations

import asyncio
import contextlib
import io
import json
import signal
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from fake_octopus import FAKE_API_KEY, FakeOctopusApi
from solis_hub import (
    CONTROL_SETTINGS,
    ControlSettingsStore,
    Hub,
    HubConfigError,
    SettingsError,
    check_poller_args,
    compose_poller_args,
    parse_config,
    parse_settings,
    settings_arguments,
    settings_from_namespace,
    strip_settings,
    write_token,
)
from test_solis_hub import FakeProcess, eventually

IDENTITY = "127.0.0.1:502/1"


def default_settings(**changes: object) -> dict:
    settings = settings_from_namespace(check_poller_args(["--host", "127.0.0.1"]))
    settings.update(changes)
    return settings


def validation_record() -> dict:
    return {
        "device_identity": IDENTITY,
        "validated_at": "2026-09-07T18:08:43+01:00",
        "baseline_raw": 50,
        "test_raw": 30,
        "restored_raw": 50,
        "observed_before_kw": 4.638,
        "observed_limited_kw": 2.938,
        "schema_version": 1,
        "register_address": 43074,
        "watts_per_raw_unit": 100,
    }


class RecordingSpawner:
    def __init__(self) -> None:
        self.processes: list[FakeProcess] = []
        self.commands: list[list[str]] = []

    async def __call__(self, command: object) -> FakeProcess:
        assert isinstance(command, list)
        process = FakeProcess()
        self.processes.append(process)
        self.commands.append(list(command))
        return process


# A stand-in for hypervolt-login and octopus-login: it records how it was run,
# reads the secret from stdin the way the real commands do, and writes the
# kind of file the real one would.
STUB_LOGIN = textwrap.dedent(
    """
    import json, sys
    kind, record = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    secret = sys.stdin.readline().rstrip("\\n")
    with open(record, "w") as handle:
        json.dump({"argv": args, "secret": secret}, handle)
    if secret == "refused":
        print("error: login was refused (HTTP 401)", file=sys.stderr)
        sys.exit(1)
    path = args[args.index("--credentials") + 1]
    if kind == "hypervolt":
        value = {"refresh_token": "rt-from-service", "charger_id": "HV-123"}
    else:
        value = {"api_key": secret, "account_number": "A-1234ABCD", "device_id": "dev-1"}
    with open(path, "w") as handle:
        json.dump(value, handle)
    print(f"Saved {kind} credentials to {path}")
    """
)


class SettingsDocumentTests(unittest.TestCase):
    def test_a_complete_document_round_trips_through_the_poller_parser(self):
        settings = default_settings(minimum_voltage=212.0, increase_step_w=500, ev_priority="ev")
        args = compose_poller_args(["--host", "127.0.0.1"], settings)
        self.assertEqual(settings_from_namespace(check_poller_args(args)), settings)

    def test_every_key_is_required_and_unknown_keys_are_refused(self):
        settings = default_settings()
        missing = dict(settings)
        del missing["minimum_voltage"]
        with self.assertRaisesRegex(SettingsError, "missing setting.*minimum_voltage"):
            parse_settings(missing)
        with self.assertRaisesRegex(SettingsError, "unknown setting.*host"):
            parse_settings({**settings, "host": "10.0.0.9"})

    def test_types_are_strict(self):
        for key, value in (
            ("dynamic_voltage_enabled", 1),
            ("increase_step_w", 200.5),
            ("increase_step_w", True),
            ("minimum_voltage", "215"),
            ("minimum_voltage", float("nan")),
            ("ev_priority", ""),
        ):
            with self.subTest(key=key, value=value), self.assertRaises(SettingsError):
                parse_settings({**default_settings(), key: value})

    def test_an_integer_is_accepted_where_a_number_is_expected(self):
        self.assertEqual(
            parse_settings(default_settings(minimum_voltage=212))["minimum_voltage"], 212.0
        )

    def test_hub_json_control_flags_are_replaced_and_everything_else_kept(self):
        base = [
            "--host",
            "192.168.1.57",
            "--interval",
            "1.0",
            "--minimum-voltage",
            "200",
            "--maximum-volt=250",  # an abbreviation in the = form
            "--no-dynamic-import-control",
            "--dynamic-voltage-control",
            "--hypervolt-enable",
            "--hypervolt-credentials",
            "creds.json",
            "--meter-voltage",
        ]
        self.assertEqual(
            strip_settings(base),
            [
                "--host",
                "192.168.1.57",
                "--interval",
                "1.0",
                "--hypervolt-credentials",
                "creds.json",
                "--meter-voltage",
            ],
        )
        settings = default_settings(dynamic_voltage_enabled=False, dynamic_import_enabled=False)
        args = compose_poller_args(base, settings)
        namespace = check_poller_args(args)
        self.assertFalse(namespace.dynamic_voltage_control)
        self.assertFalse(namespace.dynamic_import_control)
        self.assertFalse(namespace.hypervolt_enable)
        self.assertEqual(namespace.minimum_voltage, settings["minimum_voltage"])
        self.assertEqual(namespace.interval, 1.0)

    def test_without_saved_settings_hub_json_is_used_unchanged(self):
        base = ["--host", "192.168.1.57", "--minimum-voltage", "200"]
        self.assertEqual(compose_poller_args(base, None), tuple(base))

    def test_settings_never_include_connection_or_path_options(self):
        options = " ".join(field.option for field in CONTROL_SETTINGS)
        for forbidden in (
            "--host",
            "--port",
            "--slave",
            "--credentials",
            "--journal",
            "--csv",
            "--db",
        ):
            self.assertNotIn(forbidden, options)

    def test_the_poller_refuses_what_it_would_refuse_at_start(self):
        settings = default_settings(minimum_voltage=260.0, maximum_voltage=250.0)
        with self.assertRaisesRegex(SettingsError, "voltage limits"):
            check_poller_args(compose_poller_args(["--host", "127.0.0.1"], settings))

    def test_the_argument_list_for_every_boolean_spelling(self):
        on = settings_arguments(
            default_settings(dynamic_import_enabled=True, octopus_enabled=False)
        )
        off = settings_arguments(default_settings(dynamic_import_enabled=False))
        self.assertIn("--dynamic-import-control", on)
        self.assertNotIn("--octopus-enable", on)
        self.assertIn("--no-dynamic-import-control", off)


class StoreTests(unittest.TestCase):
    def test_saved_settings_are_private_and_read_back(self):
        with tempfile.TemporaryDirectory() as directory:
            store = ControlSettingsStore(Path(directory) / "control-settings.json")
            self.assertIsNone(store.load())
            store.save(default_settings(minimum_voltage=211.0))
            self.assertEqual(stat.S_IMODE(store.path.stat().st_mode), 0o600)
            self.assertEqual(store.load()["minimum_voltage"], 211.0)

    def test_a_damaged_file_stops_the_hub_with_its_name(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control-settings.json"
            path.write_text('{"minimum_voltage": 212}')
            with self.assertRaisesRegex(HubConfigError, "control-settings.json"):
                ControlSettingsStore(path).load()

    def test_saved_settings_the_poller_would_refuse_stop_the_hub(self):
        with tempfile.TemporaryDirectory() as directory:
            ControlSettingsStore(Path(directory) / "control-settings.json").save(
                default_settings(minimum_write_interval=1.0)
            )
            config = parse_config(
                {"state_dir": directory, "listen_port": 0, "poller_args": ["--host", "127.0.0.1"]}
            )
            with self.assertRaisesRegex(HubConfigError, "minimum-write-interval"):
                Hub(config, "t" * 40, "hub-id", poller_command=["solis-poll"])


class SettingsApiTestCase(unittest.IsolatedAsyncioTestCase):
    """A hub whose poller arguments point every file into a temporary directory."""

    base_args: tuple[str, ...] = ()

    async def asyncSetUp(self) -> None:
        self._directory = tempfile.TemporaryDirectory()
        self.state = Path(self._directory.name)
        self.token = write_token(self.state / "hub-token")
        self.hypervolt_file = self.state / "hypervolt.json"
        self.octopus_file = self.state / "octopus.json"
        self.validation_file = self.state / "export-validation.json"
        self.records = {
            name: self.state / f"{name}-record.json" for name in ("hypervolt", "octopus")
        }
        self.stub = self.state / "stub_login.py"
        self.stub.write_text(STUB_LOGIN)
        self.spawner = RecordingSpawner()
        self.hub = self.make_hub()
        self.hub.supervisor.backoff_first_s = 0.01
        await self.hub.start_server()
        self.supervisor_task = asyncio.ensure_future(self.hub.supervisor.run())
        await eventually(lambda: bool(self.spawner.processes))

    def make_hub(self) -> Hub:
        config = parse_config(
            {
                "listen_host": "127.0.0.1",
                "listen_port": 0,
                "state_dir": str(self.state),
                "poller_args": [
                    "--host",
                    "127.0.0.1",
                    "--interval",
                    "1",
                    "--hypervolt-credentials",
                    str(self.hypervolt_file),
                    "--octopus-credentials",
                    str(self.octopus_file),
                    "--export-control-validation",
                    str(self.validation_file),
                    *self.base_args,
                ],
            }
        )
        return Hub(
            config,
            self.token,
            "hub-id-1",
            poller_command=["solis-poll"],
            spawn=self.spawner,
            ping_interval=3600,
            locate=self.locate,
        )

    def locate(self, name: str, script: str, override: str) -> list[str]:
        kind = "hypervolt" if name == "hypervolt-login" else "octopus"
        return [sys.executable, str(self.stub), kind, str(self.records[kind])]

    async def asyncTearDown(self) -> None:
        self.hub.supervisor.request_stop()
        for process in self.spawner.processes:
            if process.returncode is None:
                process.finish(0)
        await asyncio.wait_for(self.supervisor_task, 5)
        assert self.hub.server is not None
        self.hub.server.close()
        self._directory.cleanup()

    async def request(
        self,
        method: str,
        path: str,
        body: object = None,
        *,
        token: str | None = "default",
        raw: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict]:
        reader, writer = await asyncio.open_connection("127.0.0.1", self.hub.port)
        data = raw if raw is not None else (b"" if body is None else json.dumps(body).encode())
        lines = [f"{method} {path} HTTP/1.1", "Host: localhost"]
        if token is not None:
            lines.append(f"Authorization: Bearer {self.token if token == 'default' else token}")
        if method != "GET" and not (headers and "Content-Length" in headers):
            lines.append(f"Content-Length: {len(data)}")
        lines += [f"{name}: {value}" for name, value in (headers or {}).items()]
        writer.write(("\r\n".join(lines) + "\r\n\r\n").encode() + data)
        await writer.drain()
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
        status = int(head.split()[1])
        length = 0
        for line in head.decode().split("\r\n")[1:]:
            name, _, value = line.partition(":")
            if name.lower() == "content-length":
                length = int(value)
        payload = await asyncio.wait_for(reader.readexactly(length), 10) if length else b""
        writer.close()
        return status, json.loads(payload) if payload else {}

    async def finish_current_poller(self) -> None:
        current = self.spawner.processes[-1]
        await eventually(lambda: signal.SIGTERM in current.signals)
        count = len(self.spawner.processes)
        current.finish(0)
        await eventually(lambda: len(self.spawner.processes) == count + 1)


class SettingsApiTests(SettingsApiTestCase):
    async def test_settings_need_the_token(self):
        for method, path in (
            ("GET", "/v1/settings"),
            ("PUT", "/v1/settings"),
            ("POST", "/v1/credentials/hypervolt"),
            ("POST", "/v1/credentials/octopus"),
        ):
            status, body = await self.request(method, path, {}, token=None)
            self.assertEqual((status, body), (401, {}), path)

    async def test_wrong_methods_are_refused_with_what_is_allowed(self):
        status, _ = await self.request("POST", "/v1/settings", {})
        self.assertEqual(status, 405)
        status, _ = await self.request("PUT", "/v1/status", {})
        self.assertEqual(status, 405)
        status, _ = await self.request("DELETE", "/v1/settings", token=None)
        self.assertEqual(status, 405)

    async def test_before_any_change_the_settings_come_from_hub_json(self):
        status, body = await self.request("GET", "/v1/settings")
        self.assertEqual(status, 200)
        self.assertEqual(body["source"], "hub_config")
        self.assertEqual(body["settings"], default_settings())
        self.assertFalse(body["export_control_validated"])
        self.assertEqual(body["hypervolt"], {"signed_in": False, "charger_id": None})
        self.assertFalse(body["octopus"]["signed_in"])

    async def test_saving_restarts_the_poller_with_the_new_arguments(self):
        settings = default_settings(
            dynamic_voltage_enabled=True, minimum_voltage=212.0, maximum_voltage=259.0
        )
        status, body = await self.request("PUT", "/v1/settings", settings)
        self.assertEqual(status, 200, body)
        self.assertTrue(body["restarted"])
        self.assertEqual(body["source"], "app")
        self.assertEqual(body["settings"], settings)
        first = self.spawner.processes[0]
        await eventually(lambda: signal.SIGTERM in first.signals)
        # The old poller is still restoring: no second one may start yet.
        await asyncio.sleep(0.05)
        self.assertEqual(len(self.spawner.processes), 1)
        first.finish(0)
        await eventually(lambda: len(self.spawner.processes) == 2)
        command = self.spawner.commands[1]
        self.assertIn("--dynamic-voltage-control", command)
        self.assertEqual(command[command.index("--minimum-voltage") + 1], "212.0")
        self.assertEqual(command[command.index("--interval") + 1], "1")
        self.assertEqual(self.hub.supervisor.status.restarts, 0)
        saved = self.state / "control-settings.json"
        self.assertEqual(stat.S_IMODE(saved.stat().st_mode), 0o600)
        self.assertEqual(json.loads(saved.read_text()), settings)

    async def test_a_poller_that_is_restoring_is_never_signalled_twice(self):
        first = self.spawner.processes[0]
        await self.request("PUT", "/v1/settings", default_settings(minimum_voltage=213.0))
        await self.request("PUT", "/v1/settings", default_settings(minimum_voltage=214.0))
        self.hub.supervisor.request_stop()
        await asyncio.sleep(0.05)
        self.assertEqual(first.signals, [signal.SIGTERM])
        self.assertEqual(len(self.spawner.processes), 1)

    async def test_the_latest_change_is_what_starts_after_a_restore(self):
        await self.request("PUT", "/v1/settings", default_settings(minimum_voltage=213.0))
        await self.request("PUT", "/v1/settings", default_settings(minimum_voltage=214.0))
        await self.finish_current_poller()
        command = self.spawner.commands[-1]
        self.assertEqual(command[command.index("--minimum-voltage") + 1], "214.0")

    async def test_saving_the_same_settings_again_does_not_restart(self):
        settings = default_settings(minimum_voltage=213.0)
        await self.request("PUT", "/v1/settings", settings)
        await self.finish_current_poller()
        status, body = await self.request("PUT", "/v1/settings", settings)
        self.assertEqual(status, 200)
        self.assertFalse(body["restarted"])
        await asyncio.sleep(0.05)
        self.assertEqual(len(self.spawner.processes), 2)

    async def test_settings_survive_a_hub_restart(self):
        await self.request("PUT", "/v1/settings", default_settings(minimum_voltage=214.0))
        hub = self.make_hub()
        command = hub.supervisor.command
        self.assertEqual(command[command.index("--minimum-voltage") + 1], "214.0")

    async def test_settings_the_poller_would_refuse_change_nothing(self):
        status, body = await self.request(
            "PUT", "/v1/settings", default_settings(minimum_voltage=260.0, maximum_voltage=250.0)
        )
        self.assertEqual(status, 400)
        self.assertIn("voltage limits", body["error"])
        self.assertFalse((self.state / "control-settings.json").exists())
        await asyncio.sleep(0.05)
        self.assertEqual(self.spawner.processes[0].signals, [])

    async def test_malformed_requests_are_refused(self):
        status, body = await self.request("PUT", "/v1/settings", {"minimum_voltage": 212})
        self.assertEqual(status, 400)
        self.assertIn("missing setting", body["error"])
        status, _ = await self.request("PUT", "/v1/settings", raw=b"{not json")
        self.assertEqual(status, 400)
        status, _ = await self.request(
            "PUT", "/v1/settings", raw=b"", headers={"Transfer-Encoding": "chunked"}
        )
        self.assertEqual(status, 411)
        status, _ = await self.request(
            "PUT", "/v1/settings", raw=b"", headers={"Content-Length": str(64 * 1024)}
        )
        self.assertEqual(status, 413)

    async def test_export_regulation_needs_the_validation_record(self):
        settings = default_settings(dynamic_voltage_enabled=True, dynamic_export_enabled=True)
        status, body = await self.request("PUT", "/v1/settings", settings)
        self.assertEqual(status, 400)
        self.assertIn("installation-validation", body["error"])
        self.validation_file.write_text(json.dumps(validation_record()))
        status, body = await self.request("GET", "/v1/settings")
        self.assertTrue(body["export_control_validated"])
        status, body = await self.request("PUT", "/v1/settings", settings)
        self.assertEqual(status, 200, body)

    async def test_a_record_for_another_inverter_does_not_validate_export(self):
        self.validation_file.write_text(
            json.dumps({**validation_record(), "device_identity": "10.0.0.9:502/1"})
        )
        _, body = await self.request("GET", "/v1/settings")
        self.assertFalse(body["export_control_validated"])

    async def test_one_change_at_a_time(self):
        await self.hub.admin_lock.acquire()
        try:
            status, body = await self.request("PUT", "/v1/settings", default_settings())
        finally:
            self.hub.admin_lock.release()
        self.assertEqual(status, 409)
        self.assertIn("another change", body["error"])


class SignInTests(SettingsApiTestCase):
    def recorded(self, kind: str) -> dict:
        return json.loads(self.records[kind].read_text())

    async def test_hypervolt_password_goes_to_the_login_command_on_stdin_only(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            status, body = await self.request(
                "POST",
                "/v1/credentials/hypervolt",
                {"email": "-me@example.com", "password": "pa55 word"},
            )
        self.assertEqual(status, 200, body)
        self.assertIn("Saved hypervolt credentials", body["message"])
        record = self.recorded("hypervolt")
        self.assertEqual(record["secret"], "pa55 word")
        self.assertFalse(any("pa55" in argument for argument in record["argv"]))
        self.assertIn("--email=-me@example.com", record["argv"])
        self.assertEqual(
            record["argv"][record["argv"].index("--credentials") + 1], str(self.hypervolt_file)
        )
        self.assertNotIn("pa55", json.dumps(body))
        self.assertNotIn("pa55", stderr.getvalue())
        self.assertEqual(body["hypervolt"], {"signed_in": True, "charger_id": "HV-123"})
        self.assertNotIn("rt-from-service", json.dumps(body))

    async def test_a_refused_sign_in_reports_the_service_error(self):
        status, body = await self.request(
            "POST", "/v1/credentials/hypervolt", {"email": "me@example.com", "password": "refused"}
        )
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "login was refused (HTTP 401)")
        self.assertFalse(self.hypervolt_file.exists())

    async def test_secrets_with_control_characters_are_refused(self):
        status, body = await self.request(
            "POST", "/v1/credentials/octopus", {"api_key": "sk_live_x\nsecond line"}
        )
        self.assertEqual(status, 400)
        self.assertIn("control characters", body["error"])
        self.assertFalse(self.records["octopus"].exists())

    async def test_missing_fields_are_refused(self):
        status, body = await self.request(
            "POST", "/v1/credentials/hypervolt", {"email": "me@example.com"}
        )
        self.assertEqual(status, 400)
        self.assertIn("password is required", body["error"])

    async def test_octopus_key_never_comes_back(self):
        status, body = await self.request(
            "POST",
            "/v1/credentials/octopus",
            {"api_key": "sk_live_abc123", "account": "A-1234ABCD"},
        )
        self.assertEqual(status, 200, body)
        self.assertIn("--account=A-1234ABCD", self.recorded("octopus")["argv"])
        self.assertEqual(
            body["octopus"],
            {"signed_in": True, "account_number": "A-1234ABCD", "device_id": "dev-1"},
        )
        self.assertNotIn("sk_live", json.dumps(body))
        _, settings = await self.request("GET", "/v1/settings")
        self.assertNotIn("sk_live", json.dumps(settings))

    async def test_signing_in_restarts_the_poller_only_when_the_feature_is_on(self):
        status, body = await self.request(
            "POST", "/v1/credentials/octopus", {"api_key": "sk_live_abc123"}
        )
        self.assertEqual(status, 200)
        self.assertFalse(body["restarted"])
        await asyncio.sleep(0.05)
        self.assertEqual(self.spawner.processes[0].signals, [])

        await self.request(
            "PUT",
            "/v1/settings",
            default_settings(dynamic_voltage_enabled=True, octopus_enabled=True),
        )
        await self.finish_current_poller()
        status, body = await self.request(
            "POST", "/v1/credentials/octopus", {"api_key": "sk_live_abc123"}
        )
        self.assertTrue(body["restarted"])
        await self.finish_current_poller()
        self.assertIn("--octopus-enable", self.spawner.commands[-1])


class RealOctopusLoginTests(SettingsApiTestCase):
    """The hub driving the real octopus_login.py against fake_octopus.py."""

    async def asyncSetUp(self) -> None:
        self.fake = FakeOctopusApi()
        self.fake.__enter__()
        self.base_args = (
            "--octopus-host",
            "127.0.0.1",
            "--octopus-port",
            str(self.fake.port),
            "--octopus-insecure",
        )
        await super().asyncSetUp()

    async def asyncTearDown(self) -> None:
        await super().asyncTearDown()
        self.fake.__exit__(None, None, None)

    def locate(self, name: str, script: str, override: str) -> list[str]:
        return [sys.executable, str(Path(__file__).with_name(script))]

    async def test_the_key_is_checked_with_octopus_and_saved_privately(self):
        status, body = await self.request(
            "POST", "/v1/credentials/octopus", {"api_key": FAKE_API_KEY}
        )
        self.assertEqual(status, 200, body)
        self.assertTrue(body["octopus"]["signed_in"])
        self.assertEqual(stat.S_IMODE(self.octopus_file.stat().st_mode), 0o600)

    async def test_a_wrong_key_is_refused_and_nothing_is_saved(self):
        status, body = await self.request(
            "POST", "/v1/credentials/octopus", {"api_key": "sk_live_wrong_key_entirely"}
        )
        self.assertEqual(status, 400)
        self.assertTrue(body["error"])
        self.assertFalse(self.octopus_file.exists())


if __name__ == "__main__":
    unittest.main()
