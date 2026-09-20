"""Cloud control surface for a Hypervolt EV charger.

Unlike the Solis inverter, a Hypervolt charger has no local protocol at all —
no Modbus, no OCPP, nothing on the LAN to connect to. Telemetry and control
both go through Hypervolt's own cloud API: a Keycloak-issued OAuth token for
auth, and a JSON-RPC-shaped WebSocket for everything else. This module is a
from-scratch reimplementation of that wire protocol, reverse-engineered from
the openly published Home Assistant integration
(https://github.com/gndean/home-assistant-hypervolt-charger), which Hypervolt
is aware of and has not objected to. Hypervolt does not document or support
this interface, so a failure here should be read as "the vendor changed
something", not "the network blipped" — see docs/hypervolt-integration.md.

The standard library has no WebSocket client, so `_WebSocket` hand-rolls the
RFC 6455 handshake and frame format rather than adding a dependency for it,
in the same spirit as this project's hand-rolled Modbus framing elsewhere. It
supports exactly what this client needs and nothing else: masked
client-to-server text frames, single-frame server-to-client text frames,
ping/pong keep-alive, and a clean close.
"""

from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import secrets
import select
import socket
import ssl
import struct
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Hardware limits Hypervolt itself enforces (its own protection kicks in
# outside this range regardless of what we ask for). A configured bound
# outside this range is a site-policy mistake, not a physical possibility.
HYPERVOLT_MIN_CURRENT_A = 6.0
HYPERVOLT_MAX_CURRENT_A = 32.0
_MIN_CURRENT_MA = round(HYPERVOLT_MIN_CURRENT_A * 1000)
_MAX_CURRENT_MA = round(HYPERVOLT_MAX_CURRENT_A * 1000)

_TOKEN_HOST = "kc.prod.hypervolt.co.uk"
_TOKEN_PATH = "/realms/retail-customers/protocol/openid-connect/token"
_API_HOST = "api.hypervolt.co.uk"
_USER_AGENT = "solis-tools-hypervolt-client/1"
_WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class HypervoltError(ConnectionError):
    """Base class for anything that stops this client talking to Hypervolt."""


class HypervoltAuthError(HypervoltError):
    """Login, token refresh or charger discovery failed."""


class HypervoltProtocolError(HypervoltError):
    """The websocket connection was refused, closed, or sent something this
    client cannot parse. Reconnecting is the only recovery; a corrupted frame
    stream cannot be resumed mid-message."""


@dataclass
class HypervoltCredentials:
    """What is persisted between runs: a refresh token only, never a password.

    A Hypervolt account password is exchanged for a refresh token exactly
    once, interactively, by scripts/hypervolt_login.py. Everything after that
    — including this client's own token refreshes — rotates the refresh token
    without ever touching the password again, so a leaked credentials file
    exposes charger control, not the account's email/password.
    """

    refresh_token: str
    charger_id: str | None = None

    @classmethod
    def load(cls, path: Path) -> HypervoltCredentials:
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            raise HypervoltAuthError(
                f"no Hypervolt credentials at {path}; run scripts/hypervolt_login.py first"
            ) from None
        except OSError as exc:
            raise HypervoltAuthError(f"Hypervolt credentials file is unreadable: {exc}") from exc
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise HypervoltAuthError(
                f"Hypervolt credentials file at {path} is corrupt: {exc}"
            ) from exc
        if not isinstance(value, dict) or not value.get("refresh_token"):
            raise HypervoltAuthError(f"Hypervolt credentials file at {path} has no refresh_token")
        charger_id = value.get("charger_id")
        return cls(
            refresh_token=str(value["refresh_token"]),
            charger_id=str(charger_id) if charger_id else None,
        )

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        payload = json.dumps(
            {"refresh_token": self.refresh_token, "charger_id": self.charger_id}, indent=2
        )
        temporary = path.with_suffix(path.suffix + ".tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            destination.write(payload)
        os.replace(temporary, path)


@dataclass
class HypervoltState:
    """The subset of Hypervolt's state this project acts on.

    `max_current_ma` and `charging` are the last CONFIRMED values from a state
    push, never an optimistically-assumed value from a command we just sent —
    a command over this websocket is fire-and-forget, and confirmation (if it
    comes at all) arrives later as an ordinary push. Reasoning from confirmed
    state only means a dropped confirmation shows up as "nothing changed"
    rather than as a false success feeding into voltage-safety decisions.
    """

    connected: bool = False
    charger_id: str | None = None
    max_current_ma: int | None = None
    charging: bool | None = None
    true_milli_amps: int | None = None
    watt_hours: int | None = None
    updated_monotonic: float | None = None

    def is_charging(self, now: float, stale_age_s: float) -> bool:
        """Fail closed: stale or absent telemetry reads as "not charging", so
        a degraded Hypervolt connection falls back to today's pre-Hypervolt
        behaviour instead of guessing."""
        if not self.connected or self.charging is not True or self.updated_monotonic is None:
            return False
        return now - self.updated_monotonic <= stale_age_s


class _WebSocket:
    """A minimal RFC 6455 client: masked text frames out, text frames in.

    Fragmented (multi-frame) messages are not supported. Hypervolt's JSON
    messages are small, and a real fragmentation would need this to raise
    rather than silently misdecode a partial message — which is exactly what
    happens, via HypervoltProtocolError.
    """

    frame_timeout_s = 3.0

    def __init__(self, host: str, port: int, connect_timeout_s: float, *, use_tls: bool = True):
        raw = socket.create_connection((host, port), timeout=connect_timeout_s)
        self.sock: socket.socket
        if use_tls:
            context = ssl.create_default_context()
            # create_default_context() already excludes SSLv2/SSLv3, but does
            # not raise its own minimum on older Python; TLS 1.0/1.1 are
            # broken protocols and the flow carries a Hypervolt account's
            # bearer token, so require 1.2+ explicitly rather than relying on
            # the interpreter's default.
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            self.sock = context.wrap_socket(raw, server_hostname=host)
        else:
            # Only ever False in tests, against a local fake server: production
            # always uses TLS to Hypervolt's real API.
            self.sock = raw
        self.sock.settimeout(connect_timeout_s)
        self.host = host
        self._buffer = b""

    def handshake(self, path: str, headers: dict[str, str]) -> None:
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        request_headers = {
            "Host": self.host,
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Key": key,
            "Sec-WebSocket-Version": "13",
            **headers,
        }
        request = "GET {} HTTP/1.1\r\n{}\r\n\r\n".format(
            path, "\r\n".join(f"{name}: {value}" for name, value in request_headers.items())
        )
        self.sock.sendall(request.encode("ascii"))
        response = self._read_until(b"\r\n\r\n")
        status_line = response.split(b"\r\n", 1)[0]
        if b" 101 " not in status_line:
            raise HypervoltProtocolError(f"Hypervolt websocket handshake refused: {status_line!r}")
        expected = base64.b64encode(hashlib.sha1((key + _WEBSOCKET_GUID).encode("ascii")).digest())
        if expected not in response:
            raise HypervoltProtocolError("Hypervolt websocket handshake accept key did not match")

    def _read_until(self, marker: bytes) -> bytes:
        while marker not in self._buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise HypervoltProtocolError("Hypervolt websocket closed during handshake")
            self._buffer += chunk
        index = self._buffer.index(marker) + len(marker)
        result, self._buffer = self._buffer[:index], self._buffer[index:]
        return result

    def _read_exact(self, count: int) -> bytes:
        while len(self._buffer) < count:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise HypervoltProtocolError("Hypervolt websocket closed unexpectedly")
            self._buffer += chunk
        result, self._buffer = self._buffer[:count], self._buffer[count:]
        return result

    @staticmethod
    def _masked(payload: bytes) -> bytes:
        mask = secrets.token_bytes(4)
        return mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))

    def send_text(self, text: str) -> None:
        self._send_frame(0x1, text.encode("utf-8"))

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 1 << 16:
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        self.sock.sendall(bytes(header) + self._masked(payload))

    def poll_recv(self, timeout: float) -> str | None:
        """Return the next text message if one is already available, else None.

        Only waits `timeout` seconds for the FIRST byte of a new frame — once
        any byte of one has arrived, the rest is read with a fixed short
        timeout instead, because a frame that starts arriving over a live TCP
        connection finishes in milliseconds; a stall partway through means
        something is wrong with the connection, not that the frame is merely
        slow, and is treated as a protocol error rather than silently
        resumed on the next call.
        """
        if not self._buffer:
            ready, _, _ = select.select([self.sock], [], [], timeout)
            if not ready:
                return None
        previous_timeout = self.sock.gettimeout()
        self.sock.settimeout(self.frame_timeout_s)
        try:
            return self._recv_frame()
        finally:
            self.sock.settimeout(previous_timeout)

    def _recv_frame(self) -> str | None:
        first_two = self._read_exact(2)
        fin = first_two[0] & 0x80
        opcode = first_two[0] & 0x0F
        length = first_two[1] & 0x7F
        # Per RFC 6455 the server must not mask its frames; a compliant
        # Hypervolt server never sets this bit, so it is not checked here.
        if length == 126:
            length = struct.unpack(">H", self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read_exact(8))[0]
        payload = self._read_exact(length) if length else b""
        if not fin:
            raise HypervoltProtocolError("a fragmented Hypervolt websocket message arrived")
        if opcode == 0x8:
            raise HypervoltProtocolError("Hypervolt websocket was closed by the server")
        if opcode == 0x9:  # ping
            self._send_frame(0xA, payload)
            return None
        if opcode != 0x1:  # pong or anything else this client does not act on
            return None
        return payload.decode("utf-8", "replace")

    def close(self) -> None:
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        self.sock.close()


class HypervoltClient:
    """Authenticated, reconnectable control of one Hypervolt charger.

    `connect()` performs the (blocking) login and websocket handshakes; call
    it once at startup and again after any error from `poll()` or a command
    method, mirroring how SolisClient is reconnected in the main poll loop.
    `poll()` is non-blocking and safe to call every cycle: it drains whatever
    has arrived and returns immediately, never waiting for new data.
    """

    def __init__(
        self,
        credentials: HypervoltCredentials,
        *,
        timeout: float = 10.0,
        token_host: str = _TOKEN_HOST,
        token_port: int = 443,
        api_host: str = _API_HOST,
        api_port: int = 443,
        use_tls: bool = True,
    ):
        self.credentials = credentials
        self.timeout = timeout
        self.token_host = token_host
        self.token_port = token_port
        self.api_host = api_host
        self.api_port = api_port
        self.use_tls = use_tls
        self.charger_id = credentials.charger_id
        self.state = HypervoltState()
        self._access_token: str | None = None
        self._access_token_expires_at = 0.0
        self._sync_ws: _WebSocket | None = None
        self._session_ws: _WebSocket | None = None

    def _http_connection(self, host: str, port: int) -> http.client.HTTPConnection:
        if self.use_tls:
            return http.client.HTTPSConnection(host, port, timeout=self.timeout)
        return http.client.HTTPConnection(host, port, timeout=self.timeout)

    # --- authentication -------------------------------------------------

    def _ensure_access_token(self) -> None:
        if self._access_token and time.monotonic() < self._access_token_expires_at - 30:
            return
        body = urllib.parse.urlencode(
            {
                "client_id": "home-assistant",
                "grant_type": "refresh_token",
                "refresh_token": self.credentials.refresh_token,
            }
        ).encode("ascii")
        response = self._token_request(body)
        self._access_token = response["access_token"]
        self.credentials.refresh_token = response["refresh_token"]
        self._access_token_expires_at = time.monotonic() + float(response["expires_in"])

    def _token_request(self, body: bytes) -> dict[str, Any]:
        connection = self._http_connection(self.token_host, self.token_port)
        try:
            connection.request(
                "POST",
                _TOKEN_PATH,
                body=body,
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                    "User-Agent": _USER_AGENT,
                },
            )
            response = connection.getresponse()
            payload = response.read()
            if response.status != 200:
                raise HypervoltAuthError(
                    f"Hypervolt login was refused (HTTP {response.status}): {payload[:200]!r}"
                )
            return json.loads(payload)
        except OSError as exc:
            raise HypervoltAuthError(f"could not reach Hypervolt's login service: {exc}") from exc
        except json.JSONDecodeError as exc:
            raise HypervoltAuthError(
                f"Hypervolt's login service sent an unreadable reply: {exc}"
            ) from exc
        finally:
            connection.close()

    def _discover_charger_id(self) -> str:
        connection = self._http_connection(self.api_host, self.api_port)
        try:
            connection.request(
                "GET",
                "/users/me?includes=chargers",
                headers={
                    "Authorization": f"Bearer {self._access_token}",
                    "User-Agent": _USER_AGENT,
                },
            )
            response = connection.getresponse()
            payload = response.read()
            if response.status != 200:
                raise HypervoltAuthError(
                    f"could not list Hypervolt chargers (HTTP {response.status})"
                )
            chargers = json.loads(payload).get("chargers", [])
            if not chargers:
                raise HypervoltAuthError("this Hypervolt account has no chargers")
            return str(chargers[0]["id"])
        except OSError as exc:
            raise HypervoltAuthError(f"could not reach Hypervolt's API: {exc}") from exc
        except (json.JSONDecodeError, KeyError, IndexError, TypeError) as exc:
            raise HypervoltAuthError(f"could not read the Hypervolt charger list: {exc}") from exc
        finally:
            connection.close()

    # --- connection lifecycle --------------------------------------------

    def discover_charger_id(self) -> str:
        """Look up the account's charger id, without opening a websocket.

        Used both by `connect()` (when no charger id is already known) and by
        scripts/hypervolt_login.py, which needs one to write into a fresh
        credentials file but has no reason to open a live connection yet.
        """
        self._ensure_access_token()
        charger_id = self._discover_charger_id()
        self.charger_id = charger_id
        self.credentials.charger_id = charger_id
        return charger_id

    def connect(self) -> None:
        self._ensure_access_token()
        if self.charger_id is None:
            self.discover_charger_id()
        self.credentials.charger_id = self.charger_id
        self._sync_ws = self._open(f"/ws/charger/{self.charger_id}/sync")
        self._login(self._sync_ws)
        self._send(self._sync_ws, {"method": "sync.snapshot"})
        # Only the session socket reports live charging state and actual
        # current draw; the sync socket's snapshot never includes them.
        self._session_ws = self._open(f"/ws/charger/{self.charger_id}/session/in-progress")
        self._login(self._session_ws)
        self.state.connected = True
        self.state.charger_id = self.charger_id

    def _open(self, path: str) -> _WebSocket:
        ws = _WebSocket(self.api_host, self.api_port, self.timeout, use_tls=self.use_tls)
        try:
            ws.handshake(path, {"Origin": "https://hypervolt.co.uk", "User-Agent": _USER_AGENT})
        except Exception:
            ws.close()
            raise
        return ws

    def _login(self, ws: _WebSocket) -> None:
        self._send(ws, {"method": "login", "params": {"token": self._access_token, "version": 3}})

    def close(self) -> None:
        for ws in (self._sync_ws, self._session_ws):
            if ws is not None:
                ws.close()
        self._sync_ws = None
        self._session_ws = None
        self.state.connected = False

    # --- wire helpers -----------------------------------------------------

    @staticmethod
    def _send(ws: _WebSocket, message: dict[str, Any]) -> None:
        envelope = {"id": str(int(time.time() * 1_000_000)), **message}
        ws.send_text(json.dumps(envelope))

    def _apply_message(self, text: str) -> None:
        try:
            message = json.loads(text)
        except json.JSONDecodeError:
            return
        result = message.get("result") if isinstance(message, dict) else None
        if not isinstance(result, list):
            return
        applied = False
        for update in result:
            if not isinstance(update, dict):
                continue
            if "max_current" in update:
                self.state.max_current_ma = update["max_current"]
                applied = True
            if "charging" in update:
                self.state.charging = update["charging"]
                applied = True
            if "true_milli_amps" in update:
                self.state.true_milli_amps = update["true_milli_amps"]
                applied = True
            if "watt_hours" in update:
                self.state.watt_hours = update["watt_hours"]
                applied = True
        if applied:
            self.state.updated_monotonic = time.monotonic()

    def poll(self) -> HypervoltState:
        """Drain whatever has arrived on either socket and return the state.

        Never blocks: each call reads only frames that are already pending.
        """
        if self._sync_ws is None or self._session_ws is None:
            raise HypervoltError("poll() called before connect()")
        for ws in (self._sync_ws, self._session_ws):
            while True:
                try:
                    text = ws.poll_recv(0.0)
                except HypervoltProtocolError:
                    self.close()
                    raise
                if text is None:
                    break
                self._apply_message(text)
        return self.state

    # --- control ------------------------------------------------------------

    def set_max_current_ma(self, milliamps: int) -> None:
        """Request a new maximum charging current. Fire-and-forget: the
        confirmed value only appears in `state.max_current_ma` once the
        server pushes it back, which `poll()` picks up."""
        if self._sync_ws is None:
            raise HypervoltError("set_max_current_ma() called before connect()")
        clamped = min(_MAX_CURRENT_MA, max(_MIN_CURRENT_MA, round(milliamps)))
        try:
            self._send(self._sync_ws, {"method": "sync.apply", "params": {"max_current": clamped}})
        except OSError as exc:
            self.close()
            raise HypervoltError(f"could not send the Hypervolt current command: {exc}") from exc

    def set_charging_enabled(self, enabled: bool) -> None:
        """Pause (`enabled=False`) or resume a charging session.

        Not used by the automatic voltage-priority controller, which trims
        current down to its configured floor instead of stopping a session —
        see docs/hypervolt-integration.md for why. Exposed for manual/CLI use.
        """
        if self._sync_ws is None:
            raise HypervoltError("set_charging_enabled() called before connect()")
        try:
            self._send(self._sync_ws, {"method": "sync.apply", "params": {"release": not enabled}})
        except OSError as exc:
            self.close()
            raise HypervoltError(f"could not send the Hypervolt charging command: {exc}") from exc
