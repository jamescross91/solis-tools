"""End-to-end tests: a real solis-hub supervising a real solis-poll.

Everything talks to fake_inverter.py, so no hardware is involved. The property
checked throughout is the safety one: the fake logger never sees more than one
Modbus session, however many clients are connected or however often the hub
restarts its poller.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from fake_inverter import FakeInverter, hybrid_bank
from solis_hub import write_token
from test_solis_hub import WsClient

HUB = str(Path(__file__).with_name("solis_hub.py"))
TIMEOUT = 30


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


class HubProcess:
    """`solis-hub serve` as a subprocess with its own state directory."""

    def __init__(self, inverter_port: int, *poller_args: str):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.state = root / "solis-tools"
        self.state.mkdir(mode=0o700)
        self.token = write_token(self.state / "hub-token")
        self.port = free_port()
        self.config = root / "hub.json"
        self.config.write_text(
            json.dumps(
                {
                    "listen_host": "127.0.0.1",
                    "listen_port": self.port,
                    "state_dir": str(self.state),
                    "poller_args": [
                        "--host",
                        "127.0.0.1",
                        "--port",
                        str(inverter_port),
                        "--interval",
                        "0.1",
                        "--slow-interval",
                        "30",
                        *poller_args,
                    ],
                }
            )
        )
        self.log_path = root / "hub.log"
        self.process: subprocess.Popen[bytes] | None = None

    def start(self) -> None:
        environment = dict(os.environ, XDG_STATE_HOME=str(self.state.parent))
        with open(self.log_path, "wb") as log:
            self.process = subprocess.Popen(
                [sys.executable, HUB, "serve", "--config", str(self.config)],
                stdout=subprocess.DEVNULL,
                stderr=log,
                env=environment,
            )

    def log(self) -> str:
        return self.log_path.read_text(errors="replace")

    def stop(self) -> int | None:
        process = self.process
        if process is None:
            return None
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
        try:
            code = process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            process.kill()
            code = process.wait()
        self.process = None
        return code

    def child_pids(self) -> list[int]:
        assert self.process is not None
        result = subprocess.run(
            ["pgrep", "-P", str(self.process.pid)], capture_output=True, text=True, check=False
        )
        return [int(item) for item in result.stdout.split()]

    def cleanup(self) -> None:
        self.stop()
        self.directory.cleanup()


class HubEndToEndCase(unittest.IsolatedAsyncioTestCase):
    def start_hub(self, inverter: FakeInverter, *poller_args: str) -> HubProcess:
        hub = HubProcess(inverter.port, *poller_args)
        self.addCleanup(hub.cleanup)
        hub.start()
        return hub

    async def wait_ready(self, hub: HubProcess) -> None:
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            assert hub.process is not None
            self.assertIsNone(hub.process.poll(), hub.log())
            try:
                client, status, _, _ = await WsClient.request(hub.port, "/v1/healthz")
                await client.close()
                if status == 200:
                    return
            except OSError:
                pass
            await asyncio.sleep(0.1)
        self.fail("the hub never answered /v1/healthz\n" + hub.log())

    async def connect(self, hub: HubProcess, source: str = "10.0.0.1") -> WsClient:
        return await WsClient.connect(hub.port, hub.token, source)

    async def collect(self, client: WsClient, kind: str, wanted: int) -> list[dict]:
        found: list[dict] = []
        deadline = time.monotonic() + TIMEOUT
        while len(found) < wanted and time.monotonic() < deadline:
            message = await client.receive_json(timeout=TIMEOUT)
            if message["type"] == kind:
                found.append(message)
        self.assertEqual(len(found), wanted, f"only saw {len(found)} {kind} messages")
        return found

    async def status(self, hub: HubProcess) -> dict:
        client, status, _, body = await WsClient.request(
            hub.port, "/v1/status", {"Authorization": f"Bearer {hub.token}"}
        )
        await client.close()
        self.assertEqual(status, 200)
        return json.loads(body)


class HubStreamTests(HubEndToEndCase):
    async def test_two_clients_receive_identical_samples_over_one_modbus_session(self):
        with FakeInverter() as inverter:
            hub = self.start_hub(inverter)
            await self.wait_ready(hub)
            first, second = await self.connect(hub, "10.0.0.1"), await self.connect(hub, "10.0.0.2")
            for client in (first, second):
                hello = await client.receive_json(timeout=TIMEOUT)
                self.assertEqual(hello["type"], "hello")
                self.assertEqual(hello["stream_schema_version"], 2)
                self.assertEqual((await client.receive_json(timeout=TIMEOUT))["type"], "snapshot")
            await first.send_json({"type": "attention", "on": True})
            seen = await asyncio.gather(
                self.collect(first, "sample", 6), self.collect(second, "sample", 6)
            )
            by_time = [
                {m["envelope"]["timestamp"]: m["envelope"] for m in messages} for messages in seen
            ]
            shared = set(by_time[0]) & set(by_time[1])
            self.assertTrue(shared, "the two clients shared no sample")
            for stamp in shared:
                self.assertEqual(by_time[0][stamp], by_time[1][stamp])
            sample = next(iter(by_time[0].values()))
            self.assertEqual(sample["schema_version"], 2)
            self.assertEqual(sample["reading"]["grid_voltage_v"], 242.7)

            payload = await self.status(hub)
            self.assertEqual(payload["clients"], 2)
            self.assertEqual(payload["poller"]["state"], "running")
            await first.close()
            await second.close()
            maximum = inverter.maximum_active_connections
        self.assertEqual(maximum, 1)
        self.assertNotIn(hub.token, hub.log())

    async def test_unauthenticated_requests_are_refused_and_the_token_is_never_logged(self):
        with FakeInverter() as inverter:
            hub = self.start_hub(inverter)
            await self.wait_ready(hub)
            for path in ("/v1/status", "/v1/history/samples", "/v1/history/control"):
                client, status, _, _ = await WsClient.request(hub.port, path)
                await client.close()
                self.assertEqual(status, 401, path)
            client, status, _, _ = await WsClient.request(
                hub.port, "/v1/status", {"Authorization": "Bearer not-the-token"}
            )
            await client.close()
            self.assertEqual(status, 401)
        hub.stop()
        self.assertNotIn(hub.token, hub.log())
        self.assertNotIn("not-the-token", hub.log())

    async def test_history_backfills_a_late_client(self):
        with FakeInverter() as inverter:
            hub = self.start_hub(inverter)
            await self.wait_ready(hub)
            client = await self.connect(hub)
            await client.receive_json(timeout=TIMEOUT)
            await client.receive_json(timeout=TIMEOUT)
            await client.send_json({"type": "attention", "on": True})
            await self.collect(client, "sample", 4)
            history, status, _, body = await WsClient.request(
                hub.port,
                "/v1/history/samples?resolution=native",
                {"Authorization": f"Bearer {hub.token}"},
            )
            await history.close()
            self.assertEqual(status, 200)
            entries = json.loads(body)
            self.assertGreaterEqual(len(entries), 4)
            self.assertNotIn("alarms", entries[0]["reading"])
            await client.close()

    async def test_a_dropped_modbus_connection_degrades_then_recovers_without_a_second_session(
        self,
    ):
        with FakeInverter(drop_after=10) as inverter:
            hub = self.start_hub(inverter, "--interval", "0.05")
            await self.wait_ready(hub)
            client = await self.connect(hub)
            await client.send_json({"type": "attention", "on": True})
            degraded = None
            recovered = None
            deadline = time.monotonic() + TIMEOUT
            while recovered is None and time.monotonic() < deadline:
                message = await client.receive_json(timeout=TIMEOUT)
                if message["type"] != "sample":
                    continue
                sample = message["envelope"]
                if degraded is None and sample["error"]:
                    degraded = sample
                    # The logger stops dropping connections, so the poller's own
                    # reconnect can succeed.
                    inverter.drop_after = None
                elif degraded is not None and sample["error"] is None:
                    recovered = sample
            maximum = inverter.maximum_active_connections
            hub_status = await self.status(hub)
        assert degraded is not None, "no degraded sample was streamed"
        # A degraded envelope still carries the last good reading.
        self.assertEqual(degraded["reading"]["house_load_kw"], 2.32)
        assert recovered is not None, "the stream never recovered after the drop"
        self.assertGreater(recovered["health"]["reconnects"], 0)
        self.assertEqual(maximum, 1)
        # The poller handled the drop itself; the hub never needed to restart it.
        self.assertEqual(hub_status["poller"]["restarts"], 0)

    async def test_killing_the_poller_gives_backoff_a_restart_and_a_fresh_snapshot(self):
        if shutil.which("pgrep") is None:
            if os.environ.get("CI"):
                self.fail("pgrep is needed to find the poller child and CI must not skip this")
            self.skipTest("pgrep is needed to find the poller child")
        with FakeInverter() as inverter:
            hub = self.start_hub(inverter)
            await self.wait_ready(hub)
            client = await self.connect(hub)
            await client.send_json({"type": "attention", "on": True})
            await self.collect(client, "sample", 2)
            children = hub.child_pids()
            self.assertEqual(len(children), 1)
            os.kill(children[0], signal.SIGKILL)

            states: list[str] = []
            snapshot_after_restart = None
            deadline = time.monotonic() + TIMEOUT
            while time.monotonic() < deadline:
                message = await client.receive_json(timeout=TIMEOUT)
                if message["type"] == "poller_status":
                    states.append(message["state"])
                elif message["type"] == "snapshot" and "backoff" in states:
                    snapshot_after_restart = message
                if snapshot_after_restart and states and states[-1] == "running":
                    break
            self.assertIn("backoff", states)
            self.assertEqual(states[-1], "running")
            assert snapshot_after_restart is not None
            self.assertIsNone(snapshot_after_restart["envelope"])
            self.assertEqual((await self.status(hub))["poller"]["restarts"], 1)
            replacement = hub.child_pids()
            self.assertEqual(len(replacement), 1)
            self.assertNotEqual(replacement[0], children[0])
            maximum = inverter.maximum_active_connections
        self.assertEqual(maximum, 1)


class HubShutdownTests(HubEndToEndCase):
    async def terminate(self, hub: HubProcess) -> int | None:
        """SIGTERM the hub once and wait for it, as systemd does."""
        assert hub.process is not None
        hub.process.send_signal(signal.SIGTERM)
        return await asyncio.get_running_loop().run_in_executor(None, hub.process.wait)

    def control_inverter(self) -> FakeInverter:
        bank = hybrid_bank()
        bank[33135] = 0  # charging
        bank[33251] = 2300
        bank[33263] = 0xFFFF
        bank[33264] = 0xF830  # -2.0 kW import
        bank[43488] = 100
        return FakeInverter(bank)

    def control_arguments(self, hub_state: Path) -> list[str]:
        return [
            "--interval",
            "0.05",
            "--dynamic-voltage-control",
            "--control-activation-delay",
            "0.1",
            "--control-settle-time",
            "0.1",
            "--control-journal",
            str(hub_state / "journal.json"),
            "--voltage-history-db",
            str(hub_state / "voltage-history.sqlite3"),
        ]

    async def test_sigterm_restores_the_baseline_before_the_hub_exits(self):
        with self.control_inverter() as inverter:
            directory = tempfile.TemporaryDirectory()
            self.addCleanup(directory.cleanup)
            hub = HubProcess(inverter.port, *self.control_arguments(Path(directory.name)))
            self.addCleanup(hub.cleanup)
            hub.start()
            await self.wait_ready(hub)
            client = await self.connect(hub)
            await client.send_json({"type": "attention", "on": True})
            deadline = time.monotonic() + TIMEOUT
            while (43488, 40) not in inverter.writes and time.monotonic() < deadline:
                await self.collect(client, "sample", 1)
            self.assertIn((43488, 40), inverter.writes, hub.log())
            self.assertNotEqual(inverter.bank[43488], 100)

            code = await self.terminate(hub)
            self.assertEqual(code, 0, hub.log())
            self.assertEqual(inverter.bank[43488], 100)
            self.assertEqual(inverter.writes[-1], (43488, 100))
            self.assertEqual(inverter.maximum_active_connections, 1)
            self.assertEqual(inverter.active_connections, 0)

    async def test_clients_receive_a_going_away_close_when_the_hub_stops(self):
        with FakeInverter() as inverter:
            hub = self.start_hub(inverter)
            await self.wait_ready(hub)
            client = await self.connect(hub)
            await client.send_json({"type": "attention", "on": True})
            # Wait for a live sample so the poller is fully started when the
            # signal arrives, rather than part-way through importing PyModbus.
            await self.collect(client, "sample", 1)
            assert hub.process is not None
            hub.process.send_signal(signal.SIGTERM)
            self.assertEqual(await client.receive_close(), 1001)
            await client.close()
            code = await asyncio.get_running_loop().run_in_executor(None, hub.process.wait)
        self.assertEqual(code, 0, hub.log())


if __name__ == "__main__":
    unittest.main()
