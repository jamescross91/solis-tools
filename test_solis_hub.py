"""Unit tests for solis_hub: protocol, authentication, cache, history, alerts.

The supervisor runs against a fake child process (see FakeProcess) so nothing
here starts a real poller. test_hub_end_to_end.py covers the real one.
"""

from __future__ import annotations

import asyncio
import base64
import gzip
import json
import os
import signal
import sqlite3
import struct
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import solis_hub
from solis_hub import (
    HealthMonitor,
    Hub,
    HubClient,
    HubConfigError,
    Notifier,
    NtfyConfig,
    RateLimiter,
    SampleHistory,
    StateCache,
    parse_config,
    read_token,
    source_address,
    websocket_accept,
    write_token,
)
from solis_poll import VoltageHistoryStore

GUID_SAMPLE_KEY = "dGhlIHNhbXBsZSBub25jZQ=="
GUID_SAMPLE_ACCEPT = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="


def envelope(timestamp: str = "2026-08-19T16:30:00.000+01:00", **control: object) -> dict:
    return {
        "schema_version": 2,
        "timestamp": timestamp,
        "device": {"model_code": 12695},
        "reading": {"grid_voltage_v": 242.7, "battery_soc_percent": 78, "alarms": [{"code": "1"}]},
        "health": {"consecutive_failures": 0},
        "voltage_control": {"state": "holding", "emergency": False, **control} if control else None,
        "cadence": {"interval_s": 2.0, "idle": False},
        "error": None,
    }


class FakeStdin:
    def __init__(self) -> None:
        self.writes: list[bytes] = []

    def write(self, data: bytes) -> None:
        self.writes.append(data)


class FakeProcess:
    """Just enough of asyncio.subprocess.Process for the supervisor."""

    def __init__(self) -> None:
        self.stdout = asyncio.StreamReader()
        self.stdin = FakeStdin()
        self.returncode: int | None = None
        self.signals: list[int] = []
        self._exited = asyncio.Event()

    async def wait(self) -> int:
        await self._exited.wait()
        assert self.returncode is not None
        return self.returncode

    def send_signal(self, number: int) -> None:
        self.signals.append(number)

    def feed(self, value: object) -> None:
        text = value if isinstance(value, str) else json.dumps(value)
        self.stdout.feed_data(text.encode() + b"\n")

    def finish(self, code: int = 0) -> None:
        self.returncode = code
        self.stdout.feed_eof()
        self._exited.set()


class Spawner:
    def __init__(self) -> None:
        self.processes: list[FakeProcess] = []

    async def __call__(self, command: object) -> FakeProcess:
        process = FakeProcess()
        self.processes.append(process)
        return process


def make_config(directory: str, **overrides: object):
    state = Path(directory)
    data = {
        "listen_host": "127.0.0.1",
        "listen_port": 0,
        "state_dir": str(state),
        "poller_args": ["--host", "127.0.0.1"],
        **overrides,
    }
    return parse_config(data)


async def eventually(condition, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() > deadline:
            raise AssertionError("condition never became true")
        await asyncio.sleep(0.01)


def client_frame(
    opcode: int, payload: bytes = b"", *, masked: bool = True, fin: bool = True, length: int = -1
) -> bytes:
    size = len(payload) if length < 0 else length
    first = (0x80 if fin else 0) | opcode
    mask_bit = 0x80 if masked else 0
    if size < 126:
        header = struct.pack(">BB", first, mask_bit | size)
    elif size < 1 << 16:
        header = struct.pack(">BBH", first, mask_bit | 126, size)
    else:
        header = struct.pack(">BBQ", first, mask_bit | 127, size)
    if not masked:
        return header + payload
    mask = b"\x01\x02\x03\x04"
    return header + mask + solis_hub.unmask(payload, mask)


class WsClient:
    """A bare-bones test client speaking the same RFC 6455 subset."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader = reader
        self.writer = writer

    @classmethod
    async def request(
        cls, port: int, path: str, headers: dict[str, str] | None = None
    ) -> tuple[WsClient, int, dict[str, str], bytes]:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        lines = [f"GET {path} HTTP/1.1", "Host: localhost"]
        lines += [f"{name}: {value}" for name, value in (headers or {}).items()]
        writer.write(("\r\n".join(lines) + "\r\n\r\n").encode())
        await writer.drain()
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 5)
        status_line, *header_lines = head.decode().split("\r\n")
        status = int(status_line.split()[1])
        parsed = {}
        for line in header_lines:
            if ":" in line:
                name, _, value = line.partition(":")
                parsed[name.lower()] = value.strip()
        body = b""
        if "content-length" in parsed and int(parsed["content-length"]):
            body = await asyncio.wait_for(reader.readexactly(int(parsed["content-length"])), 5)
        return cls(reader, writer), status, parsed, body

    @classmethod
    async def connect(cls, port: int, token: str, source: str = "10.0.0.1") -> WsClient:
        client, status, _, _ = await cls.request(
            port,
            "/v1/stream",
            {
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": GUID_SAMPLE_KEY,
                "Sec-WebSocket-Version": "13",
                "Authorization": f"Bearer {token}",
                "CF-Connecting-IP": source,
            },
        )
        assert status == 101, status
        return client

    async def send(self, data: bytes) -> None:
        self.writer.write(data)
        await self.writer.drain()

    async def send_json(self, value: object) -> None:
        await self.send(client_frame(solis_hub.OP_TEXT, json.dumps(value).encode()))

    async def receive(self, timeout: float = 5.0) -> tuple[int, bytes]:
        first, second = await asyncio.wait_for(self.reader.readexactly(2), timeout)
        length = second & 0x7F
        if length == 126:
            (length,) = struct.unpack(">H", await self.reader.readexactly(2))
        elif length == 127:
            (length,) = struct.unpack(">Q", await self.reader.readexactly(8))
        payload = await self.reader.readexactly(length)
        return first & 0x0F, payload

    async def receive_json(self, timeout: float = 5.0) -> dict:
        opcode, payload = await self.receive(timeout)
        assert opcode == solis_hub.OP_TEXT, opcode
        return json.loads(payload)

    async def receive_close(self) -> int:
        """Skip any error message and return the close code."""
        while True:
            opcode, payload = await self.receive()
            if opcode == solis_hub.OP_CLOSE:
                return struct.unpack(">H", payload[:2])[0]

    async def close(self) -> None:
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except (ConnectionError, OSError):
            pass


class HubTestCase(unittest.IsolatedAsyncioTestCase):
    """A real hub on an ephemeral port, supervising fake pollers."""

    async def asyncSetUp(self) -> None:
        self._directory = tempfile.TemporaryDirectory()
        self.directory = self._directory.name
        self.token = write_token(Path(self.directory) / "hub-token")
        self.spawner = Spawner()
        self.hub = Hub(
            make_config(self.directory),
            self.token,
            "hub-id-1",
            poller_command=["solis-poll"],
            spawn=self.spawner,
            ping_interval=3600,
        )
        self.hub.supervisor.backoff_first_s = 0.01
        await self.hub.start_server()
        self.port = self.hub.port
        self.supervisor_task = asyncio.ensure_future(self.hub.supervisor.run())
        await eventually(lambda: bool(self.spawner.processes))
        self.process = self.spawner.processes[0]

    async def asyncTearDown(self) -> None:
        self.hub.supervisor.request_stop()
        for process in self.spawner.processes:
            if process.returncode is None:
                process.finish(0)
        await asyncio.wait_for(self.supervisor_task, 5)
        for client in tuple(self.hub.clients):
            client.abort()
        assert self.hub.server is not None
        self.hub.server.close()
        self._directory.cleanup()

    async def connect(self, source: str = "10.0.0.1") -> WsClient:
        return await WsClient.connect(self.port, self.token, source)

    async def http(self, path: str, token: str | None = None, **headers: str):
        merged = dict(headers)
        if token:
            merged["Authorization"] = f"Bearer {token}"
        client, status, response_headers, body = await WsClient.request(self.port, path, merged)
        await client.close()
        return status, response_headers, body


class HandshakeTests(HubTestCase):
    def test_rfc_6455_sample_key_gives_the_documented_accept_value(self):
        self.assertEqual(websocket_accept(GUID_SAMPLE_KEY), GUID_SAMPLE_ACCEPT)

    async def test_upgrade_returns_the_accept_header_and_sends_hello_then_snapshot(self):
        client, status, headers, _ = await WsClient.request(
            self.port,
            "/v1/stream",
            {
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": GUID_SAMPLE_KEY,
                "Sec-WebSocket-Version": "13",
                "Authorization": f"Bearer {self.token}",
            },
        )
        self.assertEqual(status, 101)
        self.assertEqual(headers["sec-websocket-accept"], GUID_SAMPLE_ACCEPT)
        self.assertNotIn("sec-websocket-extensions", headers)
        self.assertNotIn("sec-websocket-protocol", headers)
        hello = await client.receive_json()
        self.assertEqual(hello["type"], "hello")
        self.assertEqual(hello["hub_protocol_version"], 1)
        self.assertEqual(hello["stream_schema_version"], 2)
        self.assertEqual(hello["hub_id"], "hub-id-1")
        self.assertIn("state", hello["poller"])
        snapshot = await client.receive_json()
        self.assertEqual(snapshot["type"], "snapshot")
        self.assertIsNone(snapshot["envelope"])
        await client.close()

    async def test_wrong_or_missing_version_gets_426(self):
        for version in (None, "8"):
            headers = {
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": GUID_SAMPLE_KEY,
                "Authorization": f"Bearer {self.token}",
            }
            if version:
                headers["Sec-WebSocket-Version"] = version
            client, status, response, _ = await WsClient.request(self.port, "/v1/stream", headers)
            await client.close()
            self.assertEqual(status, 426)
            self.assertEqual(response["sec-websocket-version"], "13")

    async def test_a_plain_request_to_the_stream_path_is_not_an_upgrade(self):
        status, _, _ = await self.http("/v1/stream", self.token)
        self.assertEqual(status, 426)


class FramingTests(HubTestCase):
    async def asyncSetUp(self) -> None:
        await super().asyncSetUp()
        self.client = await self.connect()
        await self.client.receive_json()
        await self.client.receive_json()

    async def asyncTearDown(self) -> None:
        await self.client.close()
        await super().asyncTearDown()

    async def test_masked_text_is_accepted(self):
        await self.client.send_json({"type": "ping", "nonce": "abc"})
        self.assertEqual(await self.client.receive_json(), {"type": "pong", "nonce": "abc"})

    async def test_unmasked_frame_closes_with_1002(self):
        await self.client.send(client_frame(solis_hub.OP_TEXT, b"{}", masked=False))
        self.assertEqual(await self.client.receive_close(), 1002)

    async def test_binary_frame_closes_with_1003(self):
        await self.client.send(client_frame(solis_hub.OP_BINARY, b"\x00"))
        self.assertEqual(await self.client.receive_close(), 1003)

    async def test_fragmented_message_closes_with_1009(self):
        await self.client.send(client_frame(solis_hub.OP_TEXT, b'{"type"', fin=False))
        self.assertEqual(await self.client.receive_close(), 1009)

    async def test_oversize_message_closes_with_1009_before_the_payload_is_read(self):
        size = solis_hub.MAX_CLIENT_MESSAGE_BYTES + 1
        await self.client.send(client_frame(solis_hub.OP_TEXT, b"", length=size))
        self.assertEqual(await self.client.receive_close(), 1009)

    async def test_message_at_the_limit_is_accepted(self):
        padding = "x" * (solis_hub.MAX_CLIENT_MESSAGE_BYTES - 40)
        payload = json.dumps({"type": "nothing", "pad": padding}).encode()
        self.assertLessEqual(len(payload), solis_hub.MAX_CLIENT_MESSAGE_BYTES)
        await self.client.send(client_frame(solis_hub.OP_TEXT, payload))
        await self.client.send_json({"type": "ping", "nonce": 1})
        self.assertEqual((await self.client.receive_json())["type"], "pong")

    async def test_ping_is_answered_with_a_pong_carrying_the_payload(self):
        await self.client.send(client_frame(solis_hub.OP_PING, b"hello"))
        self.assertEqual(await self.client.receive(), (solis_hub.OP_PONG, b"hello"))

    async def test_close_handshake_echoes_the_code(self):
        await self.client.send(client_frame(solis_hub.OP_CLOSE, struct.pack(">H", 1000)))
        self.assertEqual(await self.client.receive_close(), 1000)
        await eventually(lambda: not self.hub.clients)

    async def test_invalid_utf8_closes_with_1007(self):
        await self.client.send(client_frame(solis_hub.OP_TEXT, b"\xff\xfe"))
        self.assertEqual(await self.client.receive_close(), 1007)

    async def test_unknown_message_types_are_ignored_and_logged_once(self):
        with patch.object(solis_hub, "log") as log:
            for _ in range(3):
                await self.client.send_json({"type": "set_limit", "watts": 1})
            await self.client.send_json({"type": "ping", "nonce": 9})
            await self.client.receive_json()
        ignored = [call for call in log.call_args_list if "unknown message type" in call.args[0]]
        self.assertEqual(len(ignored), 1)

    async def test_repeated_invalid_messages_end_the_connection_with_1008(self):
        for _ in range(10):
            await self.client.send(client_frame(solis_hub.OP_TEXT, b"not json"))
        self.assertEqual(await self.client.receive_close(), 1008)

    async def test_a_silent_client_is_dropped_after_the_pong_timeout(self):
        hub = self.hub
        client = HubClient(hub, FakeWriter(), "10.9.9.9")
        client.last_pong = time.monotonic() - 100
        await client.ping_loop(0.01, 40.0)
        self.assertTrue(client.closed)


class FakeTransport:
    def __init__(self) -> None:
        self.aborted = False

    def abort(self) -> None:
        self.aborted = True


class FakeWriter:
    def __init__(self) -> None:
        self.transport = FakeTransport()
        self.frames: list[bytes] = []

    def write(self, data: bytes) -> None:
        self.frames.append(data)

    async def drain(self) -> None:
        return None

    def close(self) -> None:
        return None


class AuthenticationTests(HubTestCase):
    async def test_healthz_needs_no_token_and_returns_nothing_else(self):
        status, headers, body = await self.http("/v1/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"ok": True})
        self.assertEqual(headers["cache-control"], "no-store")

    async def test_everything_else_needs_the_token(self):
        for path in ("/v1/status", "/v1/history/samples", "/v1/history/control", "/v1/nope"):
            status, _, body = await self.http(path)
            self.assertEqual((status, body), (401, b""), path)

    async def test_missing_and_wrong_tokens_are_refused(self):
        status, _, _ = await self.http(
            "/v1/status", "wrong-token", **{"CF-Connecting-IP": "10.1.1.1"}
        )
        self.assertEqual(status, 401)
        status, _, body = await self.http(
            "/v1/status", self.token, **{"CF-Connecting-IP": "10.1.1.1"}
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["hub_id"], "hub-id-1")

    async def test_websocket_upgrade_without_the_token_is_refused(self):
        client, status, _, _ = await WsClient.request(
            self.port,
            "/v1/stream",
            {
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": GUID_SAMPLE_KEY,
                "Sec-WebSocket-Version": "13",
            },
        )
        await client.close()
        self.assertEqual(status, 401)

    async def test_the_comparison_is_constant_time(self):
        with patch.object(
            solis_hub.hmac, "compare_digest", wraps=solis_hub.hmac.compare_digest
        ) as spy:
            await self.http("/v1/status", self.token)
        self.assertTrue(spy.called)

    async def test_ten_failures_a_minute_then_429(self):
        headers = {"CF-Connecting-IP": "10.2.2.2"}
        for _ in range(10):
            status, _, _ = await self.http("/v1/status", "bad", **headers)
            self.assertEqual(status, 401)
        status, response, _ = await self.http("/v1/status", self.token, **headers)
        self.assertEqual(status, 429)
        self.assertEqual(response["retry-after"], "60")
        # Another source is unaffected.
        status, _, _ = await self.http("/v1/status", self.token, **{"CF-Connecting-IP": "10.3.3.3"})
        self.assertEqual(status, 200)

    async def test_unknown_paths_return_404_with_no_detail(self):
        status, _, body = await self.http("/v1/nothing", self.token)
        self.assertEqual((status, body), (404, b""))

    def test_rate_limiter_window_expires(self):
        now = [0.0]
        limiter = RateLimiter(limit=3, window_s=60, clock=lambda: now[0])
        for _ in range(3):
            limiter.record_failure("a")
        self.assertTrue(limiter.blocked("a"))
        now[0] = 61
        self.assertFalse(limiter.blocked("a"))

    def test_cloudflare_address_is_trusted_only_from_loopback(self):
        headers = {"cf-connecting-ip": "203.0.113.9"}
        self.assertEqual(source_address("127.0.0.1", headers), "203.0.113.9")
        self.assertEqual(source_address("::1", headers), "203.0.113.9")
        self.assertEqual(source_address("::ffff:127.0.0.1", headers), "203.0.113.9")
        self.assertEqual(source_address("192.168.1.20", headers), "192.168.1.20")
        self.assertEqual(source_address("127.0.0.1", {"cf-connecting-ip": "junk"}), "127.0.0.1")


class TokenTests(unittest.TestCase):
    def test_token_files_are_private_and_urlsafe(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state" / "hub-token"
            token = write_token(path)
            self.assertGreaterEqual(len(token), 43)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(read_token(path), token)
            self.assertNotEqual(write_token(path), token)

    def test_a_group_or_world_readable_token_refuses_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hub-token"
            write_token(path)
            for mode in (0o640, 0o604, 0o644):
                os.chmod(path, mode)
                with self.assertRaisesRegex(HubConfigError, "readable by other users"):
                    read_token(path)

    def test_missing_and_short_tokens_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hub-token"
            with self.assertRaises(HubConfigError):
                read_token(path)
            path.write_text("short\n")
            os.chmod(path, 0o600)
            with self.assertRaisesRegex(HubConfigError, "shorter"):
                read_token(path)


class ConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self._directory = tempfile.TemporaryDirectory()
        self.state = self._directory.name
        self.addCleanup(self._directory.cleanup)

    def config(self, **overrides: object):
        return parse_config(
            {"state_dir": self.state, "poller_args": ["--host", "192.168.1.57"], **overrides}
        )

    def test_defaults(self):
        config = self.config()
        self.assertEqual(config.listen_port, 8765)
        self.assertEqual(config.token_file, Path(self.state) / "hub-token")
        self.assertEqual(config.history_native_minutes, 30)
        self.assertEqual(config.history_compact_hours, 24)
        self.assertIsNone(config.ntfy)

    def test_unknown_keys_are_an_error(self):
        with self.assertRaisesRegex(HubConfigError, "unknown configuration key.*surprise"):
            self.config(surprise=True)
        with self.assertRaisesRegex(HubConfigError, "unknown ntfy key"):
            self.config(ntfy={"topic": "abc", "extra": 1})

    def test_bad_types_are_rejected(self):
        for overrides in (
            {"listen_port": "8765"},
            {"listen_port": True},
            {"listen_port": 70000},
            {"poller_args": "--host x"},
            {"poller_args": []},
            {"poller_args": ["--host", 5]},
            {"history_native_minutes": 0},
            {"history_compact_hours": 1.5},
            {"max_clients": 0},
            {"token_file": 7},
            {"ntfy": "https://ntfy.sh/topic"},
            {"ntfy": {"topic": "has space"}},
            {"ntfy": {"topic": "abc", "url": "ftp://x"}},
            {"ntfy": {"topic": "abc", "min_interval_s": -1}},
        ):
            with self.subTest(overrides), self.assertRaises(HubConfigError):
                self.config(**overrides)

    def test_not_an_object(self):
        with self.assertRaises(HubConfigError):
            parse_config([])

    def test_forbidden_poller_args(self):
        outside = "/etc/passwd"
        for args in (
            ["--host", "x", "--stream-json"],
            ["--host", "x", "--stream"],
            ["--host", "x", "--once"],
            ["--host", "x", "--on"],
            ["--host", "x", "--csv", outside],
            ["--host", "x", f"--jsonl={outside}"],
            ["--host", "x", "--csv", "../escape.csv"],
            ["--host", "x", "--csv"],
        ):
            with self.subTest(args), self.assertRaises(HubConfigError):
                self.config(poller_args=args)

    def test_recording_inside_the_state_directory_is_allowed(self):
        config = self.config(
            poller_args=["--host", "x", "--csv", "samples.csv", f"--jsonl={self.state}/a.jsonl"]
        )
        self.assertIn("--csv", config.poller_args)

    def test_null_paths_resolve_to_the_state_directory(self):
        config = self.config(token_file=None, ntfy={"topic": "abc", "token_file": None})
        self.assertEqual(config.token_file, Path(self.state) / "hub-token")
        assert config.ntfy is not None
        self.assertIsNone(config.ntfy.token_file)
        self.assertEqual(config.ntfy.min_interval_s, 300.0)

    def test_load_config_reports_unreadable_and_invalid_files(self):
        with self.assertRaisesRegex(HubConfigError, "cannot read"):
            solis_hub.load_config(Path(self.state) / "missing.json")
        path = Path(self.state) / "hub.json"
        path.write_text("{nope")
        with self.assertRaisesRegex(HubConfigError, "not valid JSON"):
            solis_hub.load_config(path)

    def test_history_database_follows_the_poller_arguments(self):
        config = self.config(poller_args=["--host", "x", "--voltage-history-db", "custom.sqlite3"])
        self.assertEqual(Hub._history_database(config), Path(self.state) / "custom.sqlite3")
        self.assertEqual(
            Hub._history_database(self.config()), Path(self.state) / "voltage-history.sqlite3"
        )


class StateCacheTests(HubTestCase):
    async def test_a_late_joiner_sees_values_carried_from_earlier_samples(self):
        first = envelope(
            configuration={"import_enabled": True},
            recent_events=[{"message": "armed"}],
            octopus_schedule={"windows": []},
        )
        self.process.feed(first)
        await eventually(lambda: self.hub.cache.latest is not None)
        self.process.feed(envelope("2026-08-19T16:30:02.000+01:00", state="reducing"))
        await eventually(lambda: self.hub.cache.latest["voltage_control"]["state"] == "reducing")

        client = await self.connect()
        await client.receive_json()
        snapshot = await client.receive_json()
        control = snapshot["envelope"]["voltage_control"]
        self.assertEqual(control["state"], "reducing")
        self.assertEqual(control["configuration"], {"import_enabled": True})
        self.assertEqual(control["recent_events"], [{"message": "armed"}])
        self.assertEqual(control["octopus_schedule"], {"windows": []})
        await client.close()

    async def test_newer_values_replace_carried_ones(self):
        self.process.feed(envelope(recent_events=[{"message": "old"}]))
        self.process.feed(envelope(recent_events=[{"message": "new"}]))
        await eventually(
            lambda: self.hub.cache.carried.get("recent_events") == [{"message": "new"}]
        )

    async def test_samples_are_forwarded_byte_for_byte(self):
        client = await self.connect()
        await client.receive_json()
        await client.receive_json()
        line = '{"schema_version":2,"timestamp":"2026-08-19T16:30:00.000+01:00","x":1.0}'
        self.process.feed(line)
        opcode, payload = await client.receive()
        self.assertEqual(opcode, solis_hub.OP_TEXT)
        self.assertEqual(payload.decode(), '{"type":"sample","envelope":' + line + "}")
        await client.close()

    async def test_undecodable_lines_are_dropped_not_forwarded(self):
        client = await self.connect()
        await client.receive_json()
        await client.receive_json()
        self.process.feed("{broken")
        self.process.feed("[1,2]")
        self.process.feed(envelope())
        # The first good line is the sample itself, then the move to running.
        first = await client.receive_json()
        second = await client.receive_json()
        self.assertEqual([first["type"], second["type"]], ["sample", "poller_status"])
        self.assertEqual(second["state"], "running")
        await client.close()

    async def test_cache_resets_and_clients_get_a_fresh_snapshot_when_the_poller_restarts(self):
        client = await self.connect()
        await client.receive_json()
        await client.receive_json()
        self.process.feed(envelope(configuration={"a": 1}))
        await eventually(lambda: self.hub.cache.latest is not None)
        self.process.finish(1)
        await eventually(lambda: len(self.spawner.processes) == 2)
        self.assertIsNone(self.hub.cache.latest)
        self.assertEqual(self.hub.cache.carried, {})

        seen = []
        while True:
            message = await client.receive_json()
            seen.append(message["type"])
            if message["type"] == "snapshot":
                self.assertIsNone(message["envelope"])
                break
        self.assertIn("poller_status", seen)
        self.assertEqual(self.hub.supervisor.status.restarts, 1)
        self.assertEqual(self.hub.supervisor.status.last_exit_code, 1)
        await client.close()

    async def test_supervisor_reports_backoff_then_running(self):
        states = []
        self.hub.supervisor.on_status = lambda status: states.append(status.state)
        self.process.finish(2)
        await eventually(lambda: len(self.spawner.processes) == 2)
        self.spawner.processes[1].feed(envelope())
        await eventually(lambda: states and states[-1] == "running")
        self.assertEqual(states[:2], ["backoff", "starting"])

    async def test_never_two_children_at_once(self):
        self.process.finish(1)
        await eventually(lambda: len(self.spawner.processes) == 2)
        self.assertEqual(self.process.returncode, 1)

    async def test_status_endpoint_reports_clients_and_envelope_age(self):
        status, _, body = await self.http("/v1/status", self.token)
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertIsNone(payload["envelope_age_s"])
        self.assertEqual(payload["clients"], 0)
        self.process.feed(envelope())
        await eventually(lambda: self.hub.cache.latest is not None)
        _, _, body = await self.http("/v1/status", self.token)
        self.assertGreaterEqual(json.loads(body)["envelope_age_s"], 0)
        self.assertEqual(json.loads(body)["poller"]["state"], "running")


class AttentionTests(HubTestCase):
    def writes(self) -> list[str]:
        return [data.decode().strip() for data in self.process.stdin.writes]

    async def test_a_fresh_poller_is_told_attention_is_off_until_someone_looks(self):
        self.assertEqual(self.writes(), ["attention off"])

    async def test_first_on_and_last_off_are_written_and_repeats_are_not(self):
        first, second = await self.connect("10.0.0.1"), await self.connect("10.0.0.2")
        for client in (first, second):
            await client.receive_json()
            await client.receive_json()
        await first.send_json({"type": "attention", "on": True})
        await eventually(lambda: self.writes() == ["attention off", "attention on"])
        await first.send_json({"type": "attention", "on": True})
        await second.send_json({"type": "attention", "on": True})
        await second.send_json({"type": "ping", "nonce": 1})
        await second.receive_json()
        await first.send_json({"type": "attention", "on": False})
        await first.send_json({"type": "ping", "nonce": 2})
        await first.receive_json()
        self.assertEqual(self.writes(), ["attention off", "attention on"])
        await second.send_json({"type": "attention", "on": False})
        await eventually(lambda: self.writes()[-1] == "attention off" and len(self.writes()) == 3)
        await first.close()
        await second.close()

    async def test_disconnecting_the_last_watcher_turns_attention_off(self):
        client = await self.connect()
        await client.send_json({"type": "attention", "on": True})
        await eventually(lambda: self.writes()[-1] == "attention on")
        await client.close()
        await eventually(lambda: self.writes()[-1] == "attention off")

    async def test_a_restarted_poller_is_brought_back_in_line(self):
        client = await self.connect()
        await client.send_json({"type": "attention", "on": True})
        await eventually(lambda: self.writes()[-1] == "attention on")
        self.process.finish(1)
        await eventually(lambda: len(self.spawner.processes) == 2)
        # A new child defaults to attention on, which is what is wanted: nothing to write.
        self.assertEqual(self.spawner.processes[1].stdin.writes, [])
        await client.send_json({"type": "attention", "on": False})
        await eventually(lambda: self.spawner.processes[1].stdin.writes == [b"attention off\n"])
        await client.close()

    async def test_invalid_attention_values_change_nothing(self):
        client = await self.connect()
        await client.send_json({"type": "attention", "on": "yes"})
        await client.send_json({"type": "attention"})
        await client.send_json({"type": "ping", "nonce": 1})
        await client.receive_json()
        await client.receive_json()
        self.assertEqual(self.writes(), ["attention off"])
        await client.close()

    async def test_only_the_two_fixed_strings_ever_reach_the_poller(self):
        client = await self.connect()
        await client.send_json({"type": "attention", "on": True, "extra": "rm -rf /"})
        await client.send_json({"type": "ping", "nonce": "attention on\nsomething"})
        await client.receive_json()
        await client.close()
        await eventually(lambda: not self.hub.clients)
        for line in self.writes():
            self.assertIn(line, ("attention on", "attention off"))


class SlowClientTests(HubTestCase):
    async def test_overflow_replaces_the_queue_with_one_snapshot(self):
        self.process.feed(envelope(configuration={"a": 1}))
        await eventually(lambda: self.hub.cache.latest is not None)
        slow = HubClient(self.hub, FakeWriter(), "slow")
        fast = HubClient(self.hub, FakeWriter(), "fast")
        for index in range(solis_hub.CLIENT_QUEUE_LIMIT):
            slow.enqueue(f"m{index}")
            fast.enqueue(f"m{index}")
        self.assertEqual(len(slow.queued), solis_hub.CLIENT_QUEUE_LIMIT)
        slow.enqueue("one too many")
        self.assertEqual(slow.overflows, 1)
        self.assertEqual(len(slow.queued), 1)
        snapshot = json.loads(slow.queued[0])
        self.assertEqual(snapshot["type"], "snapshot")
        self.assertEqual(snapshot["envelope"]["voltage_control"]["configuration"], {"a": 1})
        self.assertIn("poller", snapshot)
        # The other client is untouched.
        self.assertEqual(fast.queued, [f"m{index}" for index in range(16)])
        self.assertEqual(fast.overflows, 0)


class HistoryTests(unittest.TestCase):
    def sample(self, seconds: int, **control: object) -> dict:
        moment = datetime(2026, 8, 19, 16, 0, tzinfo=timezone.utc) + timedelta(seconds=seconds)
        return envelope(moment.isoformat(timespec="milliseconds"), **control)

    def test_entries_keep_only_the_numeric_and_control_fields(self):
        history = SampleHistory()
        history.add(
            self.sample(
                0,
                mode="import",
                raw_voltage_v=250.1,
                filtered_voltage_v=249.9,
                desired_limit_w=4000,
                effective_minimum_voltage_v=215.0,
                effective_maximum_voltage_v=252.0,
                ev_charging=False,
                recent_events=[{"x": 1}],
                configuration={"a": 1},
                diagnostics=["noise"],
                import_actuator={
                    "last_commanded_raw": 40,
                    "resolution_w": 100,
                    "pdu_address": 43488,
                },
            )
        )
        (entry,) = history.since("native", None)
        self.assertEqual(set(entry), {"timestamp", "reading", "cadence", "voltage_control"})
        self.assertNotIn("alarms", entry["reading"])
        control = entry["voltage_control"]
        self.assertEqual(
            control["import_actuator"], {"last_commanded_raw": 40, "resolution_w": 100}
        )
        for dropped in ("recent_events", "configuration", "diagnostics"):
            self.assertNotIn(dropped, control)
        self.assertEqual(control["desired_limit_w"], 4000)
        self.assertEqual(control["effective_maximum_voltage_v"], 252.0)

    def test_native_ring_keeps_only_its_window(self):
        history = SampleHistory(native_minutes=1, compact_hours=1)
        for second in range(0, 181, 2):
            history.add(self.sample(second))
        entries = history.since("native", None)
        self.assertEqual(len(entries), 31)  # 60 s window at 2 s spacing, both ends included
        self.assertTrue(entries[0]["timestamp"].startswith("2026-08-19T16:02:00"))

    def test_compact_ring_decimates_to_one_sample_per_thirty_seconds(self):
        history = SampleHistory(native_minutes=1, compact_hours=1)
        for second in range(0, 301, 2):
            history.add(self.sample(second))
        compact = history.since("compact", None)
        self.assertEqual(len(compact), 11)  # 0, 30, ... 300
        history = SampleHistory(native_minutes=1, compact_hours=1)
        for second in range(0, 3 * 3600, 30):
            history.add(self.sample(second))
        self.assertEqual(len(history.since("compact", None)), 121)  # one hour at 30 s, inclusive

    def test_since_filters_and_samples_without_readings_are_skipped(self):
        history = SampleHistory()
        for second in (0, 10, 20):
            history.add(self.sample(second))
        history.add({"timestamp": "2026-08-19T16:00:30.000+00:00", "reading": None})
        history.add({"timestamp": "garbage", "reading": {"a": 1}})
        cutoff = datetime(2026, 8, 19, 16, 0, 10, tzinfo=timezone.utc)
        self.assertEqual(len(history.since("native", cutoff)), 1)
        self.assertEqual(len(history.since("native", None)), 3)

    def test_state_cache_merges_without_mutating_the_latest_envelope(self):
        cache = StateCache()
        cache.update(envelope(configuration={"a": 1}), 1.0)
        cache.update(envelope(state="x"), 2.0)
        merged = cache.merged()
        assert merged is not None
        self.assertEqual(merged["voltage_control"]["configuration"], {"a": 1})
        assert cache.latest is not None
        self.assertNotIn("configuration", cache.latest["voltage_control"])
        self.assertEqual(cache.age_s(5.0), 3.0)
        cache.reset()
        self.assertIsNone(cache.merged())


class HistoryEndpointTests(HubTestCase):
    def database(self) -> Path:
        path = Path(self.directory) / "voltage-history.sqlite3"
        store = VoltageHistoryStore(path)
        store.connection.execute(
            "INSERT INTO voltage_minutes VALUES (?, 240, 250, 7440, -1, 1, 0, 1000, 4000, 0, 31, 1, 1, 1, 1, 1, 0)",
            (1_787_000_000,),
        )
        store.connection.executemany(
            "INSERT INTO voltage_events VALUES (?, 'holding', 'hold', ?, 250.1, -1.2, 4000)",
            [
                ("2026-08-19T10:00:00+01:00", "early"),
                ("2026-08-19T16:00:00+01:00", "late"),
            ],
        )
        store.connection.commit()
        store.connection.close()
        return path

    async def test_sample_history_endpoint_with_and_without_gzip(self):
        for second in (0, 40):
            self.process.feed(envelope(f"2026-08-19T16:00:{second:02d}.000+00:00", mode="import"))
        await eventually(lambda: len(self.hub.history.native) == 2)
        status, headers, body = await self.http(
            "/v1/history/samples?resolution=compact", self.token
        )
        self.assertEqual(status, 200)
        self.assertEqual(len(json.loads(body)), 2)
        self.assertNotIn("content-encoding", headers)
        status, headers, body = await self.http(
            "/v1/history/samples?resolution=native&since=2026-08-19T16:00:10%2B00:00",
            self.token,
            **{"Accept-Encoding": "gzip"},
        )
        self.assertEqual(headers["content-encoding"], "gzip")
        self.assertEqual(len(json.loads(gzip.decompress(body))), 1)

    async def test_bad_query_values_are_400(self):
        for path in (
            "/v1/history/samples?since=yesterday",
            "/v1/history/samples?resolution=fine",
            "/v1/history/control?kind=rows",
        ):
            status, _, _ = await self.http(path, self.token)
            self.assertEqual(status, 400, path)

    async def test_control_history_reads_the_pollers_database(self):
        self.database()
        _, _, body = await self.http("/v1/history/control?kind=minutes", self.token)
        (row,) = json.loads(body)
        self.assertEqual(row["minute"], 1_787_000_000)
        self.assertEqual(row["sample_count"], 31)
        _, _, body = await self.http("/v1/history/control?kind=events", self.token)
        self.assertEqual([event["message"] for event in json.loads(body)], ["early", "late"])
        _, _, body = await self.http(
            "/v1/history/control?kind=events&since=2026-08-19T12:00:00%2B01:00", self.token
        )
        self.assertEqual([event["message"] for event in json.loads(body)], ["late"])

    async def test_missing_database_is_an_empty_list(self):
        _, _, body = await self.http("/v1/history/control?kind=events", self.token)
        self.assertEqual(json.loads(body), [])

    async def test_the_connection_is_read_only(self):
        path = self.database()
        opened: list[str] = []
        real = sqlite3.connect

        def spy(target, *args, **kwargs):
            opened.append(target)
            return real(target, *args, **kwargs)

        with patch.object(solis_hub.sqlite3, "connect", spy):
            self.hub.history_control("minutes", None)
        self.assertEqual(len(opened), 1)
        self.assertIn("mode=ro", opened[0])
        connection = real(opened[0], uri=True)
        with self.assertRaisesRegex(sqlite3.OperationalError, "readonly"):
            connection.execute("DELETE FROM voltage_minutes")
        connection.close()
        self.assertTrue(path.exists())


class AlertTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = [0.0]
        self.sent: list[tuple[str, str, str, str]] = []
        self.monitor = HealthMonitor(lambda *args: self.sent.append(args), lambda: self.now[0])

    def keys(self) -> list[str]:
        return [item[0] for item in self.sent]

    def test_emergency_alerts_once_per_episode_and_recovers(self):
        for _ in range(3):
            self.monitor.on_sample(envelope(emergency=True))
        self.assertEqual(self.keys(), ["emergency"])
        self.assertEqual(self.sent[0][3], "high")
        self.monitor.on_sample(envelope(emergency=False))
        self.assertEqual(self.keys(), ["emergency", "recovered_emergency"])
        self.assertEqual(self.sent[1][3], "default")
        self.monitor.on_sample(envelope(emergency=True))
        self.assertEqual(self.keys()[-1], "emergency")

    def test_poller_down_needs_more_than_two_minutes(self):
        self.monitor.on_status("backoff")
        self.now[0] = 119
        self.monitor.tick()
        self.assertEqual(self.sent, [])
        self.now[0] = 121
        self.monitor.tick()
        self.monitor.tick()
        self.assertEqual(self.keys(), ["poller_down"])
        self.monitor.on_status("running")
        self.assertEqual(self.keys(), ["poller_down", "recovered_poller_down"])

    def test_a_poller_that_comes_back_in_time_never_alerts(self):
        self.monitor.on_status("starting")
        self.now[0] = 100
        self.monitor.on_status("running")
        self.now[0] = 500
        self.monitor.tick()
        self.assertEqual(self.sent, [])

    def test_inverter_unreachable_needs_sustained_failures(self):
        failing = envelope()
        failing["health"]["consecutive_failures"] = 4
        self.monitor.on_sample(failing)
        self.now[0] = 60
        self.monitor.tick()
        self.monitor.on_sample(envelope())
        self.now[0] = 200
        self.monitor.tick()
        self.assertEqual(self.sent, [])
        self.monitor.on_sample(failing)
        self.now[0] = 330
        self.monitor.tick()
        self.assertEqual(self.keys(), ["inverter_unreachable"])
        self.monitor.on_sample(envelope())
        self.assertEqual(self.keys()[-1], "recovered_inverter_unreachable")

    def test_restoration_pending_alerts_at_once(self):
        self.monitor.on_status("stopping")
        self.monitor.on_status("restoration_pending")
        self.assertEqual(self.keys(), ["restoration_pending"])

    def test_stopping_is_not_poller_down(self):
        self.monitor.on_status("stopping")
        self.now[0] = 1000
        self.monitor.tick()
        self.assertEqual(self.sent, [])

    def test_messages_hold_no_addresses_or_secrets(self):
        self.monitor.on_sample(envelope(emergency=True))
        self.monitor.on_status("restoration_pending")
        for _, title, message, _ in self.sent:
            self.assertNotRegex(title + message, r"\d+\.\d+\.\d+\.\d+|token|key|http")


class NotifierTests(unittest.TestCase):
    def config(self, interval: float = 300.0) -> NtfyConfig:
        return NtfyConfig("https://ntfy.example", "topic", None, interval)

    def test_rate_limited_per_event_type(self):
        now = [0.0]
        sent: list[tuple[str, str, str]] = []
        notifier = Notifier(
            self.config(), sender=lambda *args: sent.append(args), clock=lambda: now[0]
        )
        self.assertTrue(notifier.notify("emergency", "t", "m", "high"))
        self.assertFalse(notifier.notify("emergency", "t", "m", "high"))
        self.assertTrue(notifier.notify("poller_down", "t", "m", "high"))
        now[0] = 301
        self.assertTrue(notifier.notify("emergency", "t", "m", "high"))
        notifier.close()
        self.assertEqual(len(sent), 3)

    def test_a_blocked_or_failing_server_never_delays_the_caller(self):
        gate = threading.Event()
        calls = []

        def stuck(*args: str) -> None:
            calls.append(args)
            gate.wait(5)
            raise OSError("down")

        with patch.object(solis_hub, "log"):
            notifier = Notifier(self.config(0.0), sender=stuck)
            started = time.monotonic()
            for index in range(100):
                notifier.notify(f"k{index}", "t", "m", "high")
            self.assertLess(time.monotonic() - started, 1.0)
            gate.set()
            notifier.close()

    def test_delivery_failures_are_logged_without_the_url(self):
        def failing(*args: str) -> None:
            raise OSError("https://ntfy.example/topic refused")

        with patch.object(solis_hub, "log") as log:
            notifier = Notifier(self.config(0.0), sender=failing)
            notifier.notify("k", "t", "m", "high")
            notifier.close()
        text = " ".join(call.args[0] for call in log.call_args_list)
        self.assertIn("OSError", text)
        self.assertNotIn("topic", text)

    def test_post_builds_an_authenticated_request(self):
        captured = {}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        def fake_urlopen(request, timeout):
            captured["request"] = request
            return Response()

        notifier = Notifier(self.config(), token="secret", sender=lambda *a: None)
        with patch.object(solis_hub.urllib.request, "urlopen", fake_urlopen):
            notifier._post("Title", "Body", "high")
        notifier.close()
        request = captured["request"]
        self.assertEqual(request.full_url, "https://ntfy.example/topic")
        self.assertEqual(request.get_header("Authorization"), "Bearer secret")
        self.assertEqual(request.get_header("Priority"), "high")
        self.assertEqual(request.data, b"Body")


class ShutdownTests(HubTestCase):
    async def test_sigterm_is_forwarded_and_clients_are_closed_once_the_poller_exits(self):
        client = await self.connect()
        await client.receive_json()
        await client.receive_json()
        stop, force = asyncio.Event(), asyncio.Event()
        shutdown = asyncio.ensure_future(
            self.hub.shutdown(self.supervisor_task, asyncio.ensure_future(asyncio.sleep(60)), force)
        )
        await eventually(lambda: bool(self.process.signals))
        self.assertEqual(self.process.signals, [signal.SIGTERM])
        # Output keeps flowing to clients while the poller restores its baseline.
        self.process.feed(envelope())
        types = []
        while "sample" not in types:
            types.append((await client.receive_json())["type"])
        self.process.finish(0)
        self.assertEqual(await client.receive_close(), 1001)
        await asyncio.wait_for(shutdown, 5)
        self.assertEqual(len(self.spawner.processes), 1)
        stop.set()

    async def test_a_poller_that_will_not_exit_is_left_running_and_reported(self):
        with patch.object(solis_hub, "RESTORATION_WAIT_S", 0.05):
            force = asyncio.Event()
            shutdown = asyncio.ensure_future(
                self.hub.shutdown(
                    self.supervisor_task, asyncio.ensure_future(asyncio.sleep(60)), force
                )
            )
            await eventually(lambda: self.hub.supervisor.status.state == "restoration_pending")
            self.assertEqual(self.process.signals, [signal.SIGTERM])
            self.assertFalse(shutdown.done())
            force.set()
            await asyncio.wait_for(shutdown, 5)
        self.assertIsNone(self.process.returncode)  # never killed


class ProtocolMessageTests(unittest.TestCase):
    def test_frame_encoding_lengths(self):
        self.assertEqual(solis_hub.encode_frame(1, b"hi"), b"\x81\x02hi")
        self.assertEqual(solis_hub.encode_frame(1, b"x" * 200)[:4], b"\x81\x7e\x00\xc8")
        self.assertEqual(
            solis_hub.encode_frame(1, b"x" * 70000)[:10], b"\x81\x7f" + struct.pack(">Q", 70000)
        )

    def test_websocket_key_validation(self):
        self.assertTrue(solis_hub.valid_websocket_key(GUID_SAMPLE_KEY))
        self.assertFalse(solis_hub.valid_websocket_key("short"))
        self.assertFalse(solis_hub.valid_websocket_key(base64.b64encode(b"x" * 8).decode()))


if __name__ == "__main__":
    unittest.main()
