"""A stand-in for Hypervolt's cloud API, for testing without a real account.

Real Hypervolt splits authentication (kc.prod.hypervolt.co.uk) from the API
(api.hypervolt.co.uk); this serves both roles on one port, since
HypervoltClient already treats the two hosts as configurable and the split is
a deployment detail rather than something worth a second fake server for.

Run it standalone to exercise hypervolt_client.py by hand:

    python3 fake_hypervolt.py --port 5021

Then point HypervoltClient at 127.0.0.1:5021 with token_host=api_host set to
that address and use_tls=False.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import secrets
import socket
import struct
import threading
from urllib.parse import parse_qs

_WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class _BufferedSocket:
    """Buffers partial reads the way a real TCP stream delivers them."""

    def __init__(self, connection: socket.socket):
        self.connection = connection
        self.buffer = b""

    def read_exact(self, count: int) -> bytes | None:
        while len(self.buffer) < count:
            chunk = self.connection.recv(4096)
            if not chunk:
                return None
            self.buffer += chunk
        result, self.buffer = self.buffer[:count], self.buffer[count:]
        return result


def _read_ws_frame(reader: _BufferedSocket) -> tuple[int, bytes] | None:
    """Read one client-to-server (masked) frame: (opcode, unmasked payload)."""
    header = reader.read_exact(2)
    if header is None:
        return None
    opcode = header[0] & 0x0F
    masked = bool(header[1] & 0x80)
    length = header[1] & 0x7F
    if length == 126:
        extended = reader.read_exact(2)
        if extended is None:
            return None
        length = struct.unpack(">H", extended)[0]
    elif length == 127:
        extended = reader.read_exact(8)
        if extended is None:
            return None
        length = struct.unpack(">Q", extended)[0]
    mask = reader.read_exact(4) if masked else b""
    if mask is None:
        return None
    payload = reader.read_exact(length) if length else b""
    if payload is None:
        return None
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload


def _send_ws_frame(connection: socket.socket, text: str) -> None:
    """Send one unmasked server-to-client text frame."""
    payload = text.encode("utf-8")
    header = bytearray([0x81])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 1 << 16:
        header.append(126)
        header += struct.pack(">H", length)
    else:
        header.append(127)
        header += struct.pack(">Q", length)
    connection.sendall(bytes(header) + payload)


class FakeHypervoltCloud:
    """Serves the token endpoint, charger discovery, and the two websockets."""

    def __init__(self, charger_id: str = "deadbeefcafebabe", port: int = 0):
        self.charger_id = charger_id
        self.refresh_token = secrets.token_hex(8)
        self.access_token = secrets.token_hex(8)
        self.max_current_ma = 32000
        self.charging = False
        self.true_milli_amps = 0
        self.watt_hours = 0
        self.refuse_tokens = False
        self.token_requests: list[dict[str, str]] = []
        self.applied: list[dict[str, object]] = []
        self._lock = threading.Lock()
        self._sync_conns: list[socket.socket] = []
        self._session_conns: list[socket.socket] = []
        self.stopped = False
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._socket.bind(("127.0.0.1", port))
        self._socket.listen(8)
        self.port: int = self._socket.getsockname()[1]

    def __enter__(self) -> FakeHypervoltCloud:
        self.serve()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def serve(self) -> threading.Thread:
        thread = threading.Thread(target=self._accept_loop, daemon=True)
        thread.start()
        return thread

    def close(self) -> None:
        self.stopped = True
        try:
            self._socket.close()
        except OSError:
            pass
        self.drop_all_connections()

    def drop_all_connections(self) -> None:
        """Simulate a network blip: close every open websocket."""
        with self._lock:
            connections = self._sync_conns + self._session_conns
            self._sync_conns = []
            self._session_conns = []
        for connection in connections:
            try:
                connection.close()
            except OSError:
                pass

    def set_charging(
        self, charging: bool, *, true_milli_amps: int = 0, watt_hours: int = 0
    ) -> None:
        """Drive the session socket, as if a car started or stopped charging."""
        with self._lock:
            self.charging = charging
            self.true_milli_amps = true_milli_amps
            self.watt_hours = watt_hours
        self._broadcast_session_state()

    def _accept_loop(self) -> None:
        while not self.stopped:
            try:
                connection, _ = self._socket.accept()
            except OSError:
                return
            threading.Thread(target=self._serve_client, args=(connection,), daemon=True).start()

    def _serve_client(self, connection: socket.socket) -> None:
        request = self._read_http_request(connection)
        if request is None:
            connection.close()
            return
        method, path, headers, body = request
        if headers.get("Upgrade", "").lower() == "websocket":
            self._serve_websocket(connection, path, headers)
            return
        try:
            self._serve_http(connection, method, path, body)
        finally:
            connection.close()

    @staticmethod
    def _read_http_request(
        connection: socket.socket,
    ) -> tuple[str, str, dict[str, str], bytes] | None:
        buffer = b""
        while b"\r\n\r\n" not in buffer:
            chunk = connection.recv(4096)
            if not chunk:
                return None
            buffer += chunk
        head, _, rest = buffer.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        try:
            method, path, _ = lines[0].decode("ascii").split(" ", 2)
        except ValueError:
            return None
        headers: dict[str, str] = {}
        for line in lines[1:]:
            if b":" not in line:
                continue
            name, _, value = line.partition(b":")
            headers[name.decode("ascii").strip()] = value.decode("ascii").strip()
        content_length = int(headers.get("Content-Length", "0") or "0")
        body = rest
        while len(body) < content_length:
            chunk = connection.recv(4096)
            if not chunk:
                break
            body += chunk
        return method, path, headers, body[:content_length]

    @staticmethod
    def _send_http(connection: socket.socket, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode("utf-8")
        reason = {200: "OK", 401: "Unauthorized", 404: "Not Found"}.get(status, "Error")
        response = (
            f"HTTP/1.1 {status} {reason}\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii")
        connection.sendall(response + body)

    def _serve_http(self, connection: socket.socket, method: str, path: str, body: bytes) -> None:
        if method == "POST" and path.startswith("/realms/"):
            self._handle_token(connection, body)
        elif method == "GET" and path.startswith("/users/me"):
            chargers = [{"id": self.charger_id, "model": "Home 3 Pro"}] if self.charger_id else []
            self._send_http(connection, 200, {"chargers": chargers})
        else:
            self._send_http(connection, 404, {"error": "not found"})

    def _handle_token(self, connection: socket.socket, body: bytes) -> None:
        fields = {key: values[0] for key, values in parse_qs(body.decode("utf-8")).items()}
        with self._lock:
            self.token_requests.append(fields)
            refused = self.refuse_tokens or fields.get("refresh_token") not in (
                None,
                self.refresh_token,
            )
            if fields.get("grant_type") == "password":
                refused = self.refuse_tokens
            if not refused:
                self.access_token = secrets.token_hex(8)
                self.refresh_token = secrets.token_hex(8)
        if refused:
            self._send_http(connection, 401, {"error": "invalid_grant"})
            return
        self._send_http(
            connection,
            200,
            {
                "access_token": self.access_token,
                "refresh_token": self.refresh_token,
                "expires_in": 3600,
                "token_type": "Bearer",
            },
        )

    def _serve_websocket(
        self, connection: socket.socket, path: str, headers: dict[str, str]
    ) -> None:
        key = headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(
            hashlib.sha1((key + _WEBSOCKET_GUID).encode("ascii")).digest()
        ).decode("ascii")
        connection.sendall(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode("ascii")
        )
        is_sync = path.endswith("/sync")
        pool = self._sync_conns if is_sync else self._session_conns
        with self._lock:
            pool.append(connection)
            initial_session_state = (
                None
                if is_sync
                else {
                    "charging": self.charging,
                    "true_milli_amps": self.true_milli_amps,
                    "watt_hours": self.watt_hours,
                }
            )
        if initial_session_state is not None:
            # A newly connected session socket must see the current state
            # without waiting for the next change, the same way the sync
            # socket answers sync.snapshot; unlike the sync socket, the
            # session socket is push-only, so this is sent unprompted.
            try:
                _send_ws_frame(
                    connection,
                    json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": "initial",
                            "result": [
                                {"charging": initial_session_state["charging"]},
                                {"true_milli_amps": initial_session_state["true_milli_amps"]},
                                {"watt_hours": initial_session_state["watt_hours"]},
                            ],
                        }
                    ),
                )
            except OSError:
                pass
        try:
            reader = _BufferedSocket(connection)
            while not self.stopped:
                frame = _read_ws_frame(reader)
                if frame is None:
                    return
                opcode, payload = frame
                if opcode == 0x8:
                    return
                if opcode == 0x1:
                    self._handle_ws_message(connection, is_sync, payload.decode("utf-8", "replace"))
        except OSError:
            pass
        finally:
            with self._lock:
                if connection in pool:
                    pool.remove(connection)
            try:
                connection.close()
            except OSError:
                pass

    def _handle_ws_message(self, connection: socket.socket, is_sync: bool, text: str) -> None:
        try:
            message = json.loads(text)
        except json.JSONDecodeError:
            return
        method = message.get("method")
        if method == "login" or not is_sync:
            return
        if method == "sync.snapshot":
            _send_ws_frame(
                connection,
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": message.get("id", "0"),
                        "result": [{"max_current": self.max_current_ma}],
                    }
                ),
            )
            return
        if method == "sync.apply":
            params = message.get("params", {})
            paused = False
            with self._lock:
                self.applied.append(dict(params))
                if "max_current" in params:
                    self.max_current_ma = int(params["max_current"])
                if params.get("release"):
                    self.charging = False
                    self.true_milli_amps = 0
                    paused = True
            self._broadcast_sync_state()
            if paused:
                self._broadcast_session_state()

    def _broadcast_sync_state(self) -> None:
        with self._lock:
            connections = list(self._sync_conns)
            message = json.dumps(
                {"jsonrpc": "2.0", "id": "push", "result": [{"max_current": self.max_current_ma}]}
            )
        for connection in connections:
            try:
                _send_ws_frame(connection, message)
            except OSError:
                pass

    def _broadcast_session_state(self) -> None:
        with self._lock:
            connections = list(self._session_conns)
            message = json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": "push",
                    "result": [
                        {"charging": self.charging},
                        {"true_milli_amps": self.true_milli_amps},
                        {"watt_hours": self.watt_hours},
                    ],
                }
            )
        for connection in connections:
            try:
                _send_ws_frame(connection, message)
            except OSError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=5021, help="listen port (default: 5021)")
    arguments = parser.parse_args()
    cloud = FakeHypervoltCloud(port=arguments.port)
    cloud.serve()
    print(f"fake Hypervolt cloud listening on 127.0.0.1:{cloud.port}", flush=True)
    print(f"refresh_token={cloud.refresh_token}", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        cloud.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
