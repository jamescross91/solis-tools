"""A stand-in for Octopus Energy's Kraken GraphQL API, for testing without an
account.

It answers exactly the operations octopus_client.py sends, recognised by the
field they name rather than by parsing GraphQL: obtainKrakenToken, viewer
accounts, devices and flexPlannedDispatches. Run it standalone to exercise the
client by hand, with a charge planned from now for an hour:

    python3 fake_octopus.py --port 5022 --charge-now 60

Then point OctopusClient (or solis-poll --octopus-host/--octopus-port
--octopus-insecure) at 127.0.0.1:5022 with API key sk_live_fakefakefakefake.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

FAKE_API_KEY = "sk_live_fakefakefakefake"


def _jwt(lifetime_s: float) -> str:
    def part(value: dict[str, Any]) -> str:
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    claims = {"exp": int(time.time() + lifetime_s), "jti": secrets.token_hex(8)}
    return f"{part({'alg': 'none'})}.{part(claims)}.signature"


class FakeOctopusApi:
    def __init__(
        self,
        *,
        api_key: str = FAKE_API_KEY,
        accounts: tuple[str, ...] = ("A-1234ABCD",),
        devices: tuple[str, ...] = ("00000000-0009-4000-8020-000000000001",),
        port: int = 0,
    ):
        self.api_key = api_key
        self.accounts = accounts
        self.devices = devices
        self.dispatches: list[dict[str, str]] = []
        self.valid_tokens: set[str] = set()
        self.token_requests = 0
        self.queries: list[str] = []
        # Test drivers: answer every request with HTTP 503, or refuse the key.
        self.unavailable = False
        self.refuse_key = False
        self.lock = threading.Lock()
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                pass

            def do_POST(self) -> None:  # noqa: N802 - http.server's naming
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length)
                status, payload = fake.handle(self.path, self.headers.get("Authorization"), body)
                encoded = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

        self.server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.port = self.server.server_address[1]
        self.thread: threading.Thread | None = None

    def __enter__(self) -> FakeOctopusApi:
        # A short poll interval: shutdown() waits for one, and every test pays it.
        self.thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True
        )
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.server.shutdown()
        self.server.server_close()

    def set_dispatches(self, windows: list[tuple[datetime, datetime, str]]) -> None:
        with self.lock:
            self.dispatches = [
                {
                    "start": start.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                    "end": end.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                    "type": kind,
                }
                for start, end, kind in windows
            ]

    def plan_charge(self, start_in_s: float, duration_s: float, kind: str = "SMART") -> None:
        start = datetime.now(timezone.utc) + timedelta(seconds=start_in_s)
        self.set_dispatches([(start, start + timedelta(seconds=duration_s), kind)])

    def expire_tokens(self) -> None:
        with self.lock:
            self.valid_tokens.clear()

    @staticmethod
    def _error(code: str, message: str, field: str | None = None) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "errors": [{"message": message, "extensions": {"errorCode": code}}]
        }
        if field:
            payload["data"] = {field: None}
        return payload

    def handle(self, path: str, authorization: str | None, body: bytes) -> tuple[int, Any]:
        if path != "/v1/graphql/":
            return 404, {"detail": "not found"}
        if self.unavailable:
            return 503, {"detail": "unavailable"}
        query = str(json.loads(body).get("query", ""))
        with self.lock:
            self.queries.append(query)
            if "obtainKrakenToken" in query:
                self.token_requests += 1
                match = re.search(r'APIKey: "([^"]*)"', query)
                if self.refuse_key or not match or match.group(1) != self.api_key:
                    return 200, self._error(
                        "KT-CT-1139", "Authentication failed.", "obtainKrakenToken"
                    )
                token = _jwt(3600)
                self.valid_tokens.add(token)
                return 200, {"data": {"obtainKrakenToken": {"token": token}}}
            token = (authorization or "").removeprefix("JWT ")
            if token not in self.valid_tokens:
                return 200, self._error("KT-CT-1124", "JWT has expired.")
            if "viewer" in query:
                accounts = [{"number": number} for number in self.accounts]
                return 200, {"data": {"viewer": {"accounts": accounts}}}
            if "flexPlannedDispatches" in query:
                match = re.search(r'deviceId: "([^"]*)"', query)
                if not match or match.group(1) not in self.devices:
                    return 200, self._error("KT-CT-4340", "Device not found.")
                return 200, {"data": {"flexPlannedDispatches": list(self.dispatches)}}
            if "devices(" in query:
                devices = [
                    {
                        "id": device,
                        "provider": "HYPERVOLT",
                        "deviceType": "CHARGE_POINTS",
                        "__typename": "SmartFlexChargePoint",
                    }
                    for device in self.devices
                ]
                return 200, {"data": {"devices": devices}}
        return 200, self._error("GRAPHQL_VALIDATION_FAILED", "unknown operation")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=5022)
    parser.add_argument(
        "--charge-now", type=float, metavar="MINUTES", help="plan a charge starting now"
    )
    args = parser.parse_args()
    with FakeOctopusApi(port=args.port) as fake:
        if args.charge_now:
            fake.plan_charge(0, args.charge_now * 60)
        print(f"fake Octopus API on 127.0.0.1:{fake.port}, API key {fake.api_key}")
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    raise SystemExit(main())
