"""Planned smart-charge windows from Octopus Energy's Kraken GraphQL API.

Intelligent Octopus Go schedules a car's charging itself and publishes the
plan as "dispatches": absolute start/end times, usually a few hours ahead.
This module reads that plan and nothing else. It never asks Octopus to start,
stop or bump a charge; the only thing it feeds into voltage control is "a
charge is scheduled now", which can only narrow the operating band. See
docs/octopus-integration.md.

The wire protocol is the same one the Home Assistant Octopus Energy
integration (https://github.com/BottlecapDave/HomeAssistant-OctopusEnergy)
uses: `obtainKrakenToken` exchanges the account's API key for a JWT, and
`flexPlannedDispatches(deviceId)` returns the plan. `plannedDispatches`,
the older query, was withdrawn by Octopus in 2026.

The standard library's http.client is enough for a JSON POST, so this adds
no dependency. The HTTP call blocks, which the Modbus loop cannot afford, so
`OctopusScheduleMonitor` runs it on a background thread and the control loop
only ever reads an immutable snapshot.
"""

from __future__ import annotations

import base64
import http.client
import json
import os
import re
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

_API_HOST = "api.octopus.energy"
_GRAPHQL_PATH = "/v1/graphql/"
_USER_AGENT = "solis-tools-octopus-client/1"

# Octopus's JWTs last an hour. Renewing five minutes early means a slow
# request never carries a token that expires in flight.
_TOKEN_RENEWAL_MARGIN_S = 300.0
_DEFAULT_TOKEN_LIFETIME_S = 3600.0

# Every value this client puts into a query is checked against one of these
# first, then embedded with json.dumps. The Home Assistant integration's
# queries embed literals rather than declaring variables, and those are the
# queries known to work against the live schema; the checks are what make
# embedding safe.
_API_KEY_PATTERN = re.compile(r"^sk_live_[A-Za-z0-9]{8,128}$")
_ACCOUNT_PATTERN = re.compile(r"^A-[0-9A-Z]{4,16}$")
_DEVICE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


class OctopusError(ConnectionError):
    """Base class for anything that stops this client reading the schedule."""


class OctopusAuthError(OctopusError):
    """The API key was refused, or the account or device could not be found."""


class OctopusProtocolError(OctopusError):
    """Octopus answered with something this client cannot interpret."""


def _check(value: str, pattern: re.Pattern[str], what: str) -> str:
    if not pattern.match(value):
        raise OctopusAuthError(f"{what} is not in the expected format")
    return value


@dataclass
class OctopusCredentials:
    """What is persisted between runs.

    Octopus issues no long-lived refresh token to a personal API key (its
    refresh token expires within days), so the key itself is the credential.
    It can read the account and change Intelligent Octopus preferences, so it
    is stored at 0600 in the private state directory, like the Hypervolt
    refresh token, and never logged or streamed.
    """

    api_key: str
    account_number: str | None = None
    device_id: str | None = None

    def validate(self) -> None:
        _check(self.api_key, _API_KEY_PATTERN, "Octopus API key")
        if self.account_number is not None:
            _check(self.account_number, _ACCOUNT_PATTERN, "Octopus account number")
        if self.device_id is not None:
            _check(self.device_id, _DEVICE_PATTERN, "Octopus device ID")

    @classmethod
    def load(cls, path: Path) -> OctopusCredentials:
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            raise OctopusAuthError(
                f"no Octopus credentials at {path}; run octopus-login first"
            ) from None
        except OSError as exc:
            raise OctopusAuthError(f"Octopus credentials file is unreadable: {exc}") from exc
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise OctopusAuthError(f"Octopus credentials file at {path} is corrupt: {exc}") from exc
        if not isinstance(value, dict) or not value.get("api_key"):
            raise OctopusAuthError(f"Octopus credentials file at {path} has no api_key")
        credentials = cls(
            api_key=str(value["api_key"]),
            account_number=str(value["account_number"]) if value.get("account_number") else None,
            device_id=str(value["device_id"]) if value.get("device_id") else None,
        )
        credentials.validate()
        return credentials

    def save(self, path: Path) -> None:
        self.validate()
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        payload = json.dumps(
            {
                "api_key": self.api_key,
                "account_number": self.account_number,
                "device_id": self.device_id,
            },
            indent=2,
        )
        temporary = path.with_suffix(path.suffix + ".tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            destination.write(payload)
        os.replace(temporary, path)


def _parse_time(value: object) -> datetime:
    if not isinstance(value, str):
        raise OctopusProtocolError("dispatch time is missing")
    # datetime.fromisoformat only accepts a trailing "Z" from Python 3.11.
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise OctopusProtocolError(f"dispatch time {value!r} is not ISO 8601") from exc
    if parsed.tzinfo is None:
        # A naive time could be read as UTC or as local time; an hour's error
        # around a clock change would put the tightened band in the wrong slot.
        raise OctopusProtocolError(f"dispatch time {value!r} has no UTC offset")
    return parsed.astimezone(timezone.utc)


@dataclass(frozen=True)
class ChargeWindow:
    """One planned charge, in UTC. `kind` is Octopus's dispatch type, such as
    SMART or BOOST; every kind means the car is expected to draw current."""

    start: datetime
    end: datetime
    kind: str = "SMART"

    def stream_dict(self) -> dict[str, Any]:
        return {
            "start": self.start.astimezone().isoformat(timespec="seconds"),
            "end": self.end.astimezone().isoformat(timespec="seconds"),
            "kind": self.kind,
        }


def merge_windows(windows: list[ChargeWindow]) -> tuple[ChargeWindow, ...]:
    """Sort and join windows that touch or overlap.

    Octopus returns a long charge as consecutive half-hour dispatches. Merged,
    the band is not relaxed for an instant at each half-hour boundary, and the
    dashboard shows one charge rather than six.
    """
    merged: list[ChargeWindow] = []
    for window in sorted(windows, key=lambda item: item.start):
        if merged and window.start <= merged[-1].end:
            last = merged[-1]
            merged[-1] = ChargeWindow(
                last.start,
                max(last.end, window.end),
                last.kind if last.kind == window.kind else "MIXED",
            )
        else:
            merged.append(window)
    return tuple(merged)


@dataclass(frozen=True)
class OctopusSchedule:
    """An immutable view of the plan, safe to hand across threads."""

    windows: tuple[ChargeWindow, ...] = ()
    fetched_at: datetime | None = None
    last_error: str | None = None

    def active_window(self, now: datetime, lead_time_s: float) -> ChargeWindow | None:
        """The window whose tightened band applies at `now`, starting
        `lead_time_s` early so voltage is already inside the charger's limits
        when it tries to start drawing current."""
        lead = timedelta(seconds=lead_time_s)
        for window in self.windows:
            if window.start - lead <= now < window.end:
                return window
        return None

    def next_window(self, now: datetime, lead_time_s: float) -> ChargeWindow | None:
        lead = timedelta(seconds=lead_time_s)
        for window in self.windows:
            if window.start - lead > now:
                return window
        return None

    def upcoming(self, now: datetime) -> tuple[ChargeWindow, ...]:
        return tuple(window for window in self.windows if window.end > now)

    def stream_dict(self, now: datetime, lead_time_s: float) -> dict[str, Any]:
        active = self.active_window(now, lead_time_s)
        following = self.next_window(now, lead_time_s)
        return {
            "charge_window_active": active is not None,
            "active_window": active.stream_dict() if active else None,
            "next_window": following.stream_dict() if following else None,
            "planned_windows": [window.stream_dict() for window in self.upcoming(now)],
            "lead_time_s": lead_time_s,
            "fetched_at": (
                self.fetched_at.astimezone().isoformat(timespec="seconds")
                if self.fetched_at
                else None
            ),
            "last_error": self.last_error,
        }


def _jwt_lifetime_s(token: str, now_wall: float) -> float:
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        remaining = float(claims["exp"]) - now_wall
    except (IndexError, KeyError, TypeError, ValueError):
        return _DEFAULT_TOKEN_LIFETIME_S
    return max(0.0, min(remaining, _DEFAULT_TOKEN_LIFETIME_S))


class OctopusClient:
    """Blocking GraphQL client. Call it from OctopusScheduleMonitor's thread
    or from a one-shot command, never from the Modbus poll loop."""

    def __init__(
        self,
        credentials: OctopusCredentials,
        *,
        timeout: float = 10.0,
        host: str = _API_HOST,
        port: int = 443,
        use_tls: bool = True,
    ):
        credentials.validate()
        self.credentials = credentials
        self.timeout = timeout
        self.host = host
        self.port = port
        self.use_tls = use_tls
        self._token: str | None = None
        self._token_renew_at = 0.0

    def _post(self, query: str, token: str | None) -> dict[str, Any]:
        connection_cls = http.client.HTTPSConnection if self.use_tls else http.client.HTTPConnection
        connection = connection_cls(self.host, self.port, timeout=self.timeout)
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": _USER_AGENT,
        }
        if token is not None:
            headers["Authorization"] = f"JWT {token}"
        try:
            connection.request(
                "POST", _GRAPHQL_PATH, body=json.dumps({"query": query}), headers=headers
            )
            response = connection.getresponse()
            body = response.read()
        except (OSError, http.client.HTTPException) as exc:
            raise OctopusError(f"Octopus API unreachable: {exc}") from exc
        finally:
            connection.close()
        if response.status in (401, 403):
            raise OctopusAuthError(f"Octopus refused the request (HTTP {response.status})")
        if response.status != 200:
            raise OctopusError(f"Octopus API answered HTTP {response.status}")
        try:
            value = json.loads(body)
        except json.JSONDecodeError as exc:
            raise OctopusProtocolError(f"Octopus API sent invalid JSON: {exc}") from exc
        if not isinstance(value, dict):
            raise OctopusProtocolError("Octopus API response is not a JSON object")
        return value

    @staticmethod
    def _errors(value: dict[str, Any]) -> str | None:
        errors = value.get("errors")
        if not errors:
            return None
        messages = []
        for error in errors if isinstance(errors, list) else [errors]:
            if isinstance(error, dict):
                code = (error.get("extensions") or {}).get("errorCode")
                message = str(error.get("message", "unknown error"))
                messages.append(f"{code}: {message}" if code else message)
            else:
                messages.append(str(error))
        return "; ".join(messages)

    def _obtain_token(self) -> str:
        query = (
            "mutation { obtainKrakenToken(input: { APIKey: "
            f"{json.dumps(self.credentials.api_key)} }}) {{ token }} }}"
        )
        value = self._post(query, None)
        errors = self._errors(value)
        token = ((value.get("data") or {}).get("obtainKrakenToken") or {}).get("token")
        if errors or not isinstance(token, str) or not token:
            raise OctopusAuthError(f"Octopus refused the API key: {errors or 'no token issued'}")
        self._token = token
        self._token_renew_at = (
            time.monotonic() + _jwt_lifetime_s(token, time.time()) - _TOKEN_RENEWAL_MARGIN_S
        )
        return token

    def _query(self, query: str) -> dict[str, Any]:
        """Run an authenticated query, renewing the token once if Octopus
        rejects it, since a token can be revoked before its stated expiry."""
        for attempt in range(2):
            token = (
                self._token
                if self._token and time.monotonic() < self._token_renew_at
                else self._obtain_token()
            )
            value = self._post(query, token)
            errors = self._errors(value)
            if not errors:
                data = value.get("data")
                if not isinstance(data, dict):
                    raise OctopusProtocolError("Octopus API response has no data")
                return data
            self._token = None
            if attempt == 1:
                raise OctopusError(f"Octopus API query failed: {errors}")
        raise AssertionError("unreachable")

    def discover_account_number(self) -> str:
        data = self._query("query { viewer { accounts { number } } }")
        accounts = (data.get("viewer") or {}).get("accounts") or []
        numbers = [
            account["number"]
            for account in accounts
            if isinstance(account, dict) and isinstance(account.get("number"), str)
        ]
        if not numbers:
            raise OctopusAuthError("this Octopus API key has no accounts")
        if len(numbers) > 1:
            raise OctopusAuthError(
                f"this API key has {len(numbers)} accounts ({', '.join(numbers)}); "
                "choose one with --account"
            )
        self.credentials.account_number = _check(numbers[0], _ACCOUNT_PATTERN, "account number")
        return self.credentials.account_number

    def discover_device_id(self) -> str:
        account = self.credentials.account_number or self.discover_account_number()
        data = self._query(
            f"query {{ devices(accountNumber: {json.dumps(account)}) "
            "{ id provider deviceType __typename } }"
        )
        devices = [
            device
            for device in data.get("devices") or []
            if isinstance(device, dict) and isinstance(device.get("id"), str)
        ]
        if not devices:
            raise OctopusAuthError(
                f"account {account} has no Intelligent Octopus device; "
                "is the car or charger enrolled?"
            )
        if len(devices) > 1:
            listed = ", ".join(
                f"{device['id']} ({device.get('provider') or device.get('__typename')})"
                for device in devices
            )
            raise OctopusAuthError(
                f"account {account} has {len(devices)} devices ({listed}); choose one with --device"
            )
        self.credentials.device_id = _check(devices[0]["id"], _DEVICE_PATTERN, "device ID")
        return self.credentials.device_id

    def planned_dispatches(self) -> list[ChargeWindow]:
        device = self.credentials.device_id or self.discover_device_id()
        data = self._query(
            f"query {{ flexPlannedDispatches(deviceId: {json.dumps(device)}) "
            "{ start end type } }"
        )
        dispatches = data.get("flexPlannedDispatches")
        if dispatches is None:
            return []
        if not isinstance(dispatches, list):
            raise OctopusProtocolError("flexPlannedDispatches is not a list")
        windows = []
        for item in dispatches:
            if not isinstance(item, dict):
                raise OctopusProtocolError("a planned dispatch is not an object")
            start, end = _parse_time(item.get("start")), _parse_time(item.get("end"))
            if end <= start:
                raise OctopusProtocolError("a planned dispatch ends before it starts")
            windows.append(ChargeWindow(start, end, str(item.get("type") or "SMART")))
        return windows


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


@dataclass
class OctopusScheduleMonitor:
    """Refresh the plan on a background thread and publish immutable snapshots.

    Two rules decide what a failed or surprising refresh does, and both only
    ever keep the band tight for longer, never relax it early:

    - a failed refresh keeps the last good windows. They are absolute times,
      so they stay true until Octopus replans, and a cloud outage must not
      quietly drop the protection for a charge that is already scheduled;
    - a window that has started is kept until its planned end even if the
      next refresh no longer lists it, because Octopus can drop or shorten a
      dispatch once it is running while the car is still charging.
    """

    client: OctopusClient
    interval_s: float = 180.0
    lead_time_s: float = 300.0
    clock: Callable[[], datetime] = _utc_now
    _schedule: OctopusSchedule = field(default_factory=OctopusSchedule)
    _lock: threading.Lock = field(default_factory=threading.Lock)
    _stop: threading.Event = field(default_factory=threading.Event)
    _thread: threading.Thread | None = None
    consecutive_failures: int = 0

    def snapshot(self) -> OctopusSchedule:
        with self._lock:
            return self._schedule

    def refresh(self) -> OctopusSchedule:
        """Fetch once, synchronously. Raises only OctopusAuthError, which is a
        configuration mistake rather than a transient failure."""
        now = self.clock()
        previous = self.snapshot()
        try:
            fetched = self.client.planned_dispatches()
        except OctopusAuthError:
            raise
        except OctopusError as exc:
            self.consecutive_failures += 1
            schedule = OctopusSchedule(previous.windows, previous.fetched_at, str(exc))
        else:
            self.consecutive_failures = 0
            # Lead time 0: a window still in its lead-in has not started, so
            # a cancellation Octopus sends before then is honoured.
            started = previous.active_window(now, 0.0)
            if started is not None:
                fetched.append(started)
            schedule = OctopusSchedule(
                tuple(window for window in merge_windows(fetched) if window.end > now),
                now,
                None,
            )
        with self._lock:
            self._schedule = schedule
        return schedule

    def _delay_s(self) -> float:
        if self.consecutive_failures:
            # Retry sooner after a failure, but never faster than once a
            # minute: Octopus rate-limits token requests per account.
            return min(self.interval_s, 60.0 * self.consecutive_failures)
        # main() fetches once before starting the thread; do not repeat it.
        return self.interval_s if self.snapshot().fetched_at else 0.0

    def _publish_error(self, message: str) -> None:
        previous = self.snapshot()
        with self._lock:
            self._schedule = OctopusSchedule(previous.windows, previous.fetched_at, message)
        self.consecutive_failures += 1

    def _run(self) -> None:
        while not self._stop.wait(self._delay_s()):
            try:
                self.refresh()
            except OctopusAuthError as exc:
                self._publish_error(str(exc))
            except Exception as exc:  # the thread must outlive a surprise
                self._publish_error(f"unexpected Octopus error: {exc}")

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="octopus-schedule", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            # Bounded by the HTTP timeout; the thread is a daemon, so a
            # request stuck past it cannot hold the process open.
            self._thread.join(self.client.timeout + 1)
            self._thread = None
