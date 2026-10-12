#!/usr/bin/env python3
"""An always-on hub that fans the poller's stream out to any number of viewers.

Today the menu-bar app spawns ``solis-poll --stream-json`` itself, so voltage
control stops when the Mac sleeps. The hub is a second, optional consumer of
exactly that stdout contract: it supervises one ``solis-poll`` child on a
Raspberry Pi, caches the fields the stream only sends sometimes, and serves the
result to clients over an authenticated WebSocket and a small HTTP API on one
port. It never speaks Modbus. The only thing it writes to the poller is
``attention on`` or ``attention off``; a client holding the token can also
replace the poller's control settings or sign it in to Hypervolt and Octopus,
which the hub applies by restarting the poller with new arguments (see
``ControlSettingsStore``).

Standard library only. The WebSocket server is hand-rolled, following the
precedent of the client in ``hypervolt_client.py``, so PyModbus stays the only
runtime dependency. See docs/hub.md and docs/hub-protocol.md.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
import collections
import contextlib
import gzip
import hashlib
import hmac
import ipaddress
import json
import math
import os
import queue
import re
import secrets
import shutil
import signal
import sqlite3
import struct
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
from collections.abc import Awaitable, Callable, Iterable, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import solis_poll
import voltage_control

HUB_PROTOCOL_VERSION = 1
# The stream schema this hub was written against. Envelopes are forwarded
# unchanged whatever they say; this is advertised so a client can refuse early.
STREAM_SCHEMA_VERSION = 2
DEFAULT_PORT = 8765

# A phone on mobile data can fall behind; sixteen messages is a few seconds of
# a 0.5 s stream, after which a fresh snapshot is cheaper than the backlog.
CLIENT_QUEUE_LIMIT = 16
MAX_CLIENT_MESSAGE_BYTES = 64 * 1024
MAX_REQUEST_HEAD_BYTES = 16 * 1024
REQUEST_TIMEOUT_S = 5.0
# Connections that have not yet sent a complete request head. A LAN host is
# untrusted, and each such socket holds a file descriptor, so both the total and
# the number from one address are capped (cloudflared connects from loopback, so
# the per-address cap is generous).
MAX_PENDING_CONNECTIONS = 128
MAX_PENDING_PER_PEER = 32
# More messages than this in the window ends the connection; a real client sends
# an attention change and an occasional ping.
CLIENT_MESSAGE_LIMIT = 60
CLIENT_MESSAGE_WINDOW_S = 10.0
PING_INTERVAL_S = 20.0
PONG_TIMEOUT_S = 40.0
SEND_TIMEOUT_S = 15.0
# The poller's own stdin handler is the only reader of anything we write.
POLLER_LINE_LIMIT = 8 * 1024 * 1024
RESTORATION_WAIT_S = 20.0
BACKOFF_FIRST_S = 1.0
BACKOFF_MAX_S = 60.0
HEALTHY_RUN_S = 300.0
COMPACT_STEP_S = 30.0
DEFAULT_MAX_CLIENTS = 32
FAILED_AUTH_LIMIT = 10
FAILED_AUTH_WINDOW_S = 60.0
NOTIFY_AFTER_S = 120.0
HISTORY_ROW_LIMIT = 50_000
TOKEN_MINIMUM_LENGTH = 32

WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x1, 0x2, 0x8, 0x9, 0xA

# Poller states, in the order a healthy run visits them.
STARTING, RUNNING, BACKOFF = "starting", "running", "backoff"
STOPPING, RESTORATION_PENDING = "stopping", "restoration_pending"

# Voltage-control fields the stream sends once or only on change; the cache
# carries them forward so a client that joins late still sees a whole picture.
CARRIED_FIELDS = ("configuration", "recent_events", "octopus_schedule")

# Everything a history entry keeps of a sample. Arrays (alarms, events,
# diagnostics) are excluded: a day of them per sample is what made the menu
# bar's popover slow to open.
HISTORY_CONTROL_FIELDS = (
    "state",
    "action",
    "mode",
    "raw_voltage_v",
    "filtered_voltage_v",
    "desired_limit_w",
    "emergency",
    "effective_minimum_voltage_v",
    "effective_maximum_voltage_v",
    "ev_voltage_limits_active",
    "ev_charging",
)
HISTORY_ACTUATOR_FIELDS = ("last_commanded_raw", "resolution_w")
HISTORY_ACTUATORS = ("import_actuator", "export_actuator")

FORBIDDEN_OPTIONS = ("--stream-json", "--once")
PATH_OPTIONS = ("--csv", "--jsonl")
CONFIG_KEYS = {
    "listen_host",
    "listen_port",
    "state_dir",
    "token_file",
    "poller_args",
    "history_native_minutes",
    "history_compact_hours",
    "max_clients",
    "ntfy",
}
NTFY_KEYS = {"url", "topic", "token_file", "min_interval_s"}
NTFY_TOPIC = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SETTINGS_FILE = "control-settings.json"
MAX_REQUEST_BODY_BYTES = 16 * 1024
# hypervolt-login and octopus-login each make a few HTTPS calls with 10 s
# timeouts; anything slower is a hung process, not a slow service.
LOGIN_TIMEOUT_S = 60.0


def log(message: str) -> None:
    """One plain line on stderr, which journald captures.

    Callers never pass a token, an Authorization header or a credential file's
    contents; keep it that way.
    """
    print(f"solis-hub: {message}", file=sys.stderr, flush=True)


class HubConfigError(ValueError):
    """The configuration, token or state directory cannot be used."""


# --- Configuration -------------------------------------------------------


@dataclass(frozen=True)
class NtfyConfig:
    url: str
    topic: str
    token_file: Path | None
    min_interval_s: float


@dataclass(frozen=True)
class HubConfig:
    listen_host: str
    listen_port: int
    state_dir: Path
    token_file: Path
    poller_args: tuple[str, ...]
    history_native_minutes: int
    history_compact_hours: int
    max_clients: int
    ntfy: NtfyConfig | None


def default_state_dir() -> Path:
    return solis_poll.default_control_state_dir()


def ensure_state_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    # An existing directory may have been made with a looser mode. It holds the
    # token and the poller's journal, so tighten it when it is ours to change.
    status = path.stat()
    if status.st_mode & 0o077 and status.st_uid == os.getuid():
        os.chmod(path, 0o700)
        log(f"tightened {path} to mode 0700")


def _resolve_path(value: str, state_dir: Path) -> Path:
    path = Path(value).expanduser()
    return path if path.is_absolute() else state_dir / path


def _option_matches(argument: str, option: str) -> bool:
    """True when argparse would read `argument` as `option`.

    The poller's parser accepts unambiguous prefixes, so ``--stream`` is
    ``--stream-json``; matching only the full spelling would let a forbidden
    option through.
    """
    name = argument.split("=", 1)[0]
    return len(name) >= 3 and name.startswith("--") and option.startswith(name)


def validate_poller_args(args: Sequence[str], state_dir: Path) -> tuple[str, ...]:
    state_root = state_dir.resolve()
    index = 0
    while index < len(args):
        argument = args[index]
        for option in FORBIDDEN_OPTIONS:
            if _option_matches(argument, option):
                raise HubConfigError(
                    f"poller_args may not contain {option}; the hub adds --stream-json itself "
                    "and never runs a one-shot poll"
                )
        for option in PATH_OPTIONS:
            if _option_matches(argument, option):
                if "=" in argument:
                    value = argument.split("=", 1)[1]
                elif index + 1 < len(args):
                    value = args[index + 1]
                    index += 1
                else:
                    raise HubConfigError(f"poller_args: {option} needs a path")
                resolved = _resolve_path(value, state_dir).resolve()
                if not resolved.is_relative_to(state_root):
                    raise HubConfigError(
                        f"poller_args: {option} must be inside the state directory {state_root}"
                    )
        index += 1
    return tuple(args)


def _require_int(
    data: dict[str, Any], key: str, default: int, low: int, high: int | None = None
) -> int:
    value = data.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise HubConfigError(f"{key} must be an integer")
    if value < low or (high is not None and value > high):
        bound = f"between {low} and {high}" if high is not None else f"at least {low}"
        raise HubConfigError(f"{key} must be {bound}")
    return value


def _optional_path(
    data: dict[str, Any], key: str, state_dir: Path, default: Path | None
) -> Path | None:
    value = data.get(key)
    if value is None:
        return default
    if not isinstance(value, str) or not value:
        raise HubConfigError(f"{key} must be a path string or null")
    return _resolve_path(value, state_dir)


def parse_config(data: Any, state_dir_override: Path | None = None) -> HubConfig:
    if not isinstance(data, dict):
        raise HubConfigError("the configuration must be a JSON object")
    unknown = sorted(set(data) - CONFIG_KEYS)
    if unknown:
        raise HubConfigError(f"unknown configuration key(s): {', '.join(unknown)}")
    state_dir = _optional_path(data, "state_dir", Path.cwd(), state_dir_override)
    state_dir = state_dir or default_state_dir()
    host = data.get("listen_host", "0.0.0.0")
    if not isinstance(host, str) or not host:
        raise HubConfigError("listen_host must be a non-empty string")
    poller_args = data.get("poller_args")
    if (
        not isinstance(poller_args, list)
        or not poller_args
        or not all(isinstance(item, str) for item in poller_args)
    ):
        raise HubConfigError("poller_args must be a non-empty list of strings")
    token_file = _optional_path(data, "token_file", state_dir, state_dir / "hub-token")
    assert token_file is not None
    return HubConfig(
        listen_host=host,
        listen_port=_require_int(data, "listen_port", DEFAULT_PORT, 0, 65535),
        state_dir=state_dir,
        token_file=token_file,
        poller_args=validate_poller_args(poller_args, state_dir),
        history_native_minutes=_require_int(data, "history_native_minutes", 30, 1, 24 * 60),
        history_compact_hours=_require_int(data, "history_compact_hours", 24, 1, 24 * 14),
        max_clients=_require_int(data, "max_clients", DEFAULT_MAX_CLIENTS, 1, 1024),
        ntfy=_parse_ntfy(data.get("ntfy"), state_dir),
    )


def _parse_ntfy(data: Any, state_dir: Path) -> NtfyConfig | None:
    if data is None:
        return None
    if not isinstance(data, dict):
        raise HubConfigError("ntfy must be an object or null")
    unknown = sorted(set(data) - NTFY_KEYS)
    if unknown:
        raise HubConfigError(f"unknown ntfy key(s): {', '.join(unknown)}")
    url = data.get("url", "https://ntfy.sh")
    if not isinstance(url, str) or not url.startswith(("https://", "http://")):
        raise HubConfigError("ntfy.url must be an http(s) URL")
    topic = data.get("topic")
    if not isinstance(topic, str) or not NTFY_TOPIC.match(topic):
        raise HubConfigError("ntfy.topic must be 1-64 letters, digits, '_' or '-'")
    interval = data.get("min_interval_s", 300)
    if isinstance(interval, bool) or not isinstance(interval, (int, float)) or interval < 0:
        raise HubConfigError("ntfy.min_interval_s must be a non-negative number")
    return NtfyConfig(
        url=url.rstrip("/"),
        topic=topic,
        token_file=_optional_path(data, "token_file", state_dir, None),
        min_interval_s=float(interval),
    )


def load_config(path: Path, state_dir_override: Path | None = None) -> HubConfig:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise HubConfigError(f"cannot read {path}: {exc.strerror or exc}") from exc
    try:
        data = json.loads(text)
    except ValueError as exc:
        raise HubConfigError(f"{path} is not valid JSON: {exc}") from exc
    return parse_config(data, state_dir_override)


# --- Control settings set from clients ------------------------------------


@dataclass(frozen=True)
class SettingField:
    key: str
    option: str
    dest: str
    kind: type
    # The --no- spelling of a flag solis-poll defines as BooleanOptionalAction.
    negative: str | None = None


# Exactly the controller settings the menu bar edits in Direct mode, so a hub
# offers the same controls. Connection, polling and file paths stay in
# hub.json: a client can tune the controller, never point it somewhere else.
CONTROL_SETTINGS: tuple[SettingField, ...] = (
    SettingField(
        "dynamic_voltage_enabled", "--dynamic-voltage-control", "dynamic_voltage_control", bool
    ),
    SettingField(
        "dynamic_import_enabled",
        "--dynamic-import-control",
        "dynamic_import_control",
        bool,
        "--no-dynamic-import-control",
    ),
    SettingField(
        "dynamic_export_enabled", "--dynamic-export-control", "dynamic_export_control", bool
    ),
    SettingField("minimum_voltage", "--minimum-voltage", "minimum_voltage", float),
    SettingField("maximum_voltage", "--maximum-voltage", "maximum_voltage", float),
    SettingField(
        "voltage_safety_margin", "--voltage-safety-margin", "voltage_safety_margin", float
    ),
    SettingField("voltage_deadband", "--voltage-deadband", "voltage_deadband", float),
    SettingField("maximum_import_kw", "--maximum-import-kw", "maximum_import_kw", float),
    SettingField("import_headroom_kw", "--import-headroom-kw", "import_headroom_kw", float),
    SettingField("export_headroom_kw", "--export-headroom-kw", "export_headroom_kw", float),
    SettingField("maximum_export_kw", "--maximum-export-kw", "maximum_export_kw", float),
    SettingField(
        "site_export_permission_kw",
        "--site-export-permission-kw",
        "site_export_permission_kw",
        float,
    ),
    SettingField("increase_step_w", "--increase-step-w", "increase_step_w", int),
    SettingField("reduction_step_w", "--reduction-step-w", "reduction_step_w", int),
    SettingField(
        "near_limit_reduction_w", "--near-limit-reduction-w", "near_limit_reduction_w", int
    ),
    SettingField("emergency_reduction_w", "--emergency-reduction-w", "emergency_reduction_w", int),
    SettingField("control_settle_time", "--control-settle-time", "control_settle_time", float),
    SettingField(
        "control_activation_delay", "--control-activation-delay", "control_activation_delay", float
    ),
    SettingField(
        "control_deactivation_delay",
        "--control-deactivation-delay",
        "control_deactivation_delay",
        float,
    ),
    SettingField("import_activation_kw", "--import-activation-kw", "import_activation_kw", float),
    SettingField("export_activation_kw", "--export-activation-kw", "export_activation_kw", float),
    SettingField(
        "minimum_write_interval", "--minimum-write-interval", "minimum_write_interval", float
    ),
    SettingField("hypervolt_enabled", "--hypervolt-enable", "hypervolt_enable", bool),
    SettingField("ev_priority", "--ev-priority", "ev_priority", str),
    SettingField("octopus_enabled", "--octopus-enable", "octopus_enable", bool),
)
SETTING_KEYS = {field.key for field in CONTROL_SETTINGS}
# solis-poll refuses these without --dynamic-voltage-control. With control off
# they are left out of the arguments but kept in the saved settings, so turning
# control off never fails for them and turning it back on restores them, as the
# menu bar's own Direct-mode arguments do.
NEEDS_CONTROL = {"dynamic_export_enabled", "hypervolt_enabled", "octopus_enabled"}


class SettingsError(ValueError):
    """Settings from a client that cannot be applied; the message is shown to it."""


def parse_settings(data: Any) -> dict[str, Any]:
    """A complete settings document, strictly typed.

    Every key is required, so a client built against an older field list cannot
    silently leave a newer setting at whatever the file last held. Ranges are
    not checked here: the poller's own validation does that, once, for both.
    """
    if not isinstance(data, dict):
        raise SettingsError("settings must be a JSON object")
    unknown = sorted(set(data) - SETTING_KEYS)
    if unknown:
        raise SettingsError(f"unknown setting(s): {', '.join(unknown)}")
    missing = sorted(SETTING_KEYS - set(data))
    if missing:
        raise SettingsError(f"missing setting(s): {', '.join(missing)}")
    settings: dict[str, Any] = {}
    for field in CONTROL_SETTINGS:
        value = data[field.key]
        if field.kind is bool:
            if not isinstance(value, bool):
                raise SettingsError(f"{field.key} must be true or false")
        elif field.kind is int:
            if isinstance(value, bool) or not isinstance(value, int):
                raise SettingsError(f"{field.key} must be a whole number")
        elif field.kind is float:
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise SettingsError(f"{field.key} must be a number")
            value = float(value)
            if not math.isfinite(value):
                raise SettingsError(f"{field.key} must be finite")
        elif not isinstance(value, str) or not value or len(value) > 32:
            raise SettingsError(f"{field.key} must be a short string")
        settings[field.key] = value
    return settings


def settings_arguments(settings: dict[str, Any]) -> list[str]:
    arguments: list[str] = []
    control = settings["dynamic_voltage_enabled"]
    for field in CONTROL_SETTINGS:
        value = settings[field.key]
        if field.key in NEEDS_CONTROL and not control:
            continue
        if field.kind is bool:
            if value:
                arguments.append(field.option)
            elif field.negative is not None:
                arguments.append(field.negative)
        else:
            arguments += [field.option, str(value)]
    return arguments


def strip_settings(args: Sequence[str]) -> list[str]:
    """`args` without any flag a settings document sets, nor the flag's value."""
    kept: list[str] = []
    index = 0
    while index < len(args):
        argument = args[index]
        index += 1
        field = next(
            (
                field
                for field in CONTROL_SETTINGS
                if _option_matches(argument, field.option)
                or (field.negative is not None and _option_matches(argument, field.negative))
            ),
            None,
        )
        if field is None:
            kept.append(argument)
        elif field.kind is not bool and "=" not in argument:
            index += 1  # the value that follows the flag
    return kept


def compose_poller_args(base: Sequence[str], settings: dict[str, Any] | None) -> tuple[str, ...]:
    """hub.json's arguments, with the settings set from clients in place of its
    own control flags. With no settings saved, hub.json is used unchanged."""
    if settings is None:
        return tuple(base)
    return (*strip_settings(base), *settings_arguments(settings))


def check_poller_args(args: Sequence[str]) -> argparse.Namespace:
    """What solis-poll would make of `args`, or SettingsError saying why it
    would refuse them. --stream-json is the one flag the hub always adds."""
    try:
        return solis_poll.check_arguments([*args, "--stream-json"])
    except solis_poll.PollerArgumentError as exc:
        raise SettingsError(str(exc)) from exc
    except SystemExit as exc:  # --help or --version in hub.json's arguments
        raise SettingsError("the poller arguments ask for help or a version") from exc


def settings_from_namespace(namespace: argparse.Namespace) -> dict[str, Any]:
    return {field.key: getattr(namespace, field.dest) for field in CONTROL_SETTINGS}


class ControlSettingsStore:
    """The settings clients have set, in the state directory.

    The state directory, not hub.json, because it is the only place the
    systemd unit lets the hub write (/etc is read-only to it). The file is
    absent until a client saves settings; until then hub.json's poller_args
    are the whole story, as they always were.
    """

    def __init__(self, path: Path):
        self.path = path

    def load(self) -> dict[str, Any] | None:
        try:
            text = self.path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise HubConfigError(f"cannot read {self.path}: {exc.strerror or exc}") from exc
        try:
            return parse_settings(strict_json_loads(text))
        except (ValueError, SettingsError) as exc:
            raise HubConfigError(
                f"{self.path} is not valid ({exc}); fix or delete it to use hub.json's poller_args"
            ) from exc

    def save(self, settings: dict[str, Any]) -> None:
        temporary = self.path.with_name(self.path.name + ".tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(settings, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, self.path)


# --- Token and hub identity ---------------------------------------------


def write_token(path: Path) -> str:
    """Replace the token with a fresh one. The file is never world-readable."""
    ensure_state_dir(path.parent)
    token = secrets.token_urlsafe(32)
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(token + "\n")
    os.replace(temporary, path)
    return token


def read_token(path: Path) -> str:
    try:
        mode = path.stat().st_mode
    except OSError as exc:
        raise HubConfigError(f"no token at {path}; create one with 'solis-hub token new'") from exc
    if mode & 0o077:
        raise HubConfigError(
            f"{path} is readable by other users (mode {mode & 0o777:03o}); "
            f"run 'chmod 600 {path}' or create a new token"
        )
    token = path.read_text(encoding="utf-8").strip()
    if len(token) < TOKEN_MINIMUM_LENGTH:
        raise HubConfigError(f"{path} holds a token shorter than {TOKEN_MINIMUM_LENGTH} characters")
    return token


def load_hub_id(state_dir: Path) -> str:
    """A stable identity for this hub, so clients can tell hubs apart."""
    path = state_dir / "hub-id"
    with contextlib.suppress(OSError, ValueError):
        return str(uuid.UUID(path.read_text(encoding="utf-8").strip()))
    ensure_state_dir(state_dir)
    hub_id = str(uuid.uuid4())
    path.write_text(hub_id + "\n", encoding="utf-8")
    return hub_id


# --- Authentication ------------------------------------------------------


class RateLimiter:
    """Cap failed authentication per source address.

    Ten failures inside a minute block the source with 429 until the window
    passes. The count is of failures only, so a correct client is never slowed
    by its own traffic.
    """

    def __init__(
        self,
        limit: int = FAILED_AUTH_LIMIT,
        window_s: float = FAILED_AUTH_WINDOW_S,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.limit = limit
        self.window_s = window_s
        self.clock = clock
        self._failures: dict[str, collections.deque[float]] = {}

    def _prune(self, source: str) -> collections.deque[float]:
        failures = self._failures.setdefault(source, collections.deque())
        cutoff = self.clock() - self.window_s
        while failures and failures[0] <= cutoff:
            failures.popleft()
        return failures

    def blocked(self, source: str) -> bool:
        failures = self._prune(source)
        if not failures:
            self._failures.pop(source, None)
        return len(failures) >= self.limit

    def record_failure(self, source: str) -> None:
        if len(self._failures) > 4096:
            # A scan from many addresses must not grow this without bound.
            for stale in [name for name in self._failures if not self._prune(name)]:
                del self._failures[stale]
        self._prune(source).append(self.clock())


def bearer_token(headers: dict[str, str]) -> str | None:
    value = headers.get("authorization", "")
    scheme, _, token = value.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    return token.strip()


def token_matches(presented: str | None, expected: str) -> bool:
    # Compared even when absent, so a missing header costs the same as a wrong one.
    return hmac.compare_digest((presented or "").encode(), expected.encode()) and bool(presented)


def source_address(peer: str, headers: dict[str, str]) -> str:
    """The address to rate-limit.

    Behind Tailscale Funnel or Cloudflare Tunnel every request arrives from
    loopback (tailscaled or cloudflared), so the peer is useless and a header
    names the visitor; it is believed only from loopback, because anyone else
    could forge it to dodge the limiter. The last X-Forwarded-For entry is the
    one to believe: Tailscale's proxy replaces whatever the visitor sent with
    the visitor's address, and Cloudflare appends the visitor's address after
    anything sent. CF-Connecting-IP is a fallback only: Funnel passes it through
    untouched, so preferring it would let a Funnel visitor choose its own bucket.
    """
    try:
        address = ipaddress.ip_address(peer)
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
    except ValueError:
        return peer
    if address.is_loopback:
        forwarded_for = headers.get("x-forwarded-for", "")
        candidates = (
            [forwarded_for.rsplit(",", 1)[-1].strip()]
            if forwarded_for
            else [headers.get("cf-connecting-ip", "")]
        )
        for candidate in candidates:
            with contextlib.suppress(ValueError):
                return str(ipaddress.ip_address(candidate))
    return str(address)


# --- HTTP and WebSocket framing -----------------------------------------


@dataclass
class Request:
    method: str
    target: str
    path: str
    query: dict[str, list[str]]
    headers: dict[str, str]


class BadRequest(Exception):
    pass


async def read_request(reader: asyncio.StreamReader) -> Request:
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), REQUEST_TIMEOUT_S)
    except asyncio.LimitOverrunError as exc:
        raise BadRequest("request head too large") from exc
    if len(head) > MAX_REQUEST_HEAD_BYTES:
        raise BadRequest("request head too large")
    try:
        text = head.decode("latin-1")
    except UnicodeDecodeError as exc:  # pragma: no cover - latin-1 decodes anything
        raise BadRequest("undecodable request") from exc
    lines = text.split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) != 3 or not parts[2].startswith("HTTP/1."):
        raise BadRequest("malformed request line")
    method, target, _ = parts
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line:
            continue
        name, separator, value = line.partition(":")
        if not separator or not name or name != name.strip():
            raise BadRequest("malformed header")
        key = name.lower()
        headers[key] = f"{headers[key]}, {value.strip()}" if key in headers else value.strip()
    split = urllib.parse.urlsplit(target)
    return Request(
        method=method,
        target=target,
        path=split.path,
        query=urllib.parse.parse_qs(split.query),
        headers=headers,
    )


_REASONS = {
    101: "Switching Protocols",
    200: "OK",
    400: "Bad Request",
    401: "Unauthorized",
    404: "Not Found",
    405: "Method Not Allowed",
    409: "Conflict",
    411: "Length Required",
    413: "Content Too Large",
    426: "Upgrade Required",
    429: "Too Many Requests",
    431: "Request Header Fields Too Large",
    500: "Internal Server Error",
    503: "Service Unavailable",
}

# Every path behind the token, and the methods each accepts.
ROUTES = {
    "/v1/stream": ("GET",),
    "/v1/status": ("GET",),
    "/v1/history/samples": ("GET",),
    "/v1/history/control": ("GET",),
    "/v1/settings": ("GET", "PUT"),
    "/v1/credentials/hypervolt": ("POST",),
    "/v1/credentials/octopus": ("POST",),
}


class HTTPProblem(Exception):
    """A request that is answered with `status` and a short reason for the client."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


async def read_json_body(reader: asyncio.StreamReader, headers: dict[str, str]) -> Any:
    """A small JSON body with a declared length. Chunked bodies are refused
    rather than parsed: nothing a client sends needs them."""
    if "transfer-encoding" in headers:
        raise HTTPProblem(411, "send the body with a Content-Length")
    declared = headers.get("content-length", "")
    if not declared.isdigit():
        raise HTTPProblem(411, "send the body with a Content-Length")
    length = int(declared)
    if length > MAX_REQUEST_BODY_BYTES:
        raise HTTPProblem(413, "the body is too large")
    data = await asyncio.wait_for(reader.readexactly(length), REQUEST_TIMEOUT_S)
    try:
        return strict_json_loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise HTTPProblem(400, "the body must be JSON") from exc


def _text_field(body: dict[str, Any], key: str, *, limit: int, required: bool = True) -> str | None:
    """A string from a request body that is safe to pass on as one line or one
    argument: no control characters, which would split a stdin line."""
    value = body.get(key)
    if value is None or value == "":
        if required:
            raise HTTPProblem(400, f"{key} is required")
        return None
    if not isinstance(value, str) or len(value) > limit:
        raise HTTPProblem(400, f"{key} must be a string of at most {limit} characters")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise HTTPProblem(400, f"{key} must not contain control characters")
    return value


def http_response(
    status: int,
    body: bytes = b"",
    *,
    content_type: str = "application/json",
    headers: Iterable[tuple[str, str]] = (),
) -> bytes:
    lines = [
        f"HTTP/1.1 {status} {_REASONS.get(status, 'Error')}",
        "Cache-Control: no-store",
        "Connection: close",
        f"Content-Length: {len(body)}",
    ]
    if body:
        lines.append(f"Content-Type: {content_type}")
    lines.extend(f"{name}: {value}" for name, value in headers)
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body


def _reject_constant(name: str) -> Any:
    raise ValueError(f"{name} is not valid JSON")


def strict_json_loads(text: str) -> Any:
    """json.loads that refuses NaN and Infinity, which strict decoders (Swift's)
    cannot read, and that treats pathological nesting as invalid rather than as
    an exception that would end a connection."""
    try:
        return json.loads(text, parse_constant=_reject_constant)
    except RecursionError as exc:
        raise ValueError("nested too deeply") from exc


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode()


def websocket_accept(key: str) -> str:
    digest = hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def valid_websocket_key(key: str) -> bool:
    try:
        return len(base64.b64decode(key, validate=True)) == 16
    except (binascii.Error, ValueError):
        return False


def encode_frame(opcode: int, payload: bytes = b"") -> bytes:
    """A single unfragmented, unmasked server frame."""
    length = len(payload)
    if length < 126:
        header = struct.pack(">BB", 0x80 | opcode, length)
    elif length < 1 << 16:
        header = struct.pack(">BBH", 0x80 | opcode, 126, length)
    else:
        header = struct.pack(">BBQ", 0x80 | opcode, 127, length)
    return header + payload


def encode_close(code: int, reason: str = "") -> bytes:
    return encode_frame(OP_CLOSE, struct.pack(">H", code) + reason.encode()[:123])


class FrameError(Exception):
    """A client frame the hub refuses; `code` is the close code to answer with."""

    def __init__(self, code: int, reason: str):
        super().__init__(reason)
        self.code = code
        self.reason = reason


def unmask(payload: bytes, mask: bytes) -> bytes:
    if not payload:
        return b""
    # One big-integer XOR is an order of magnitude faster than a byte loop, which
    # matters for a 64 KiB frame on a Raspberry Pi.
    length = len(payload)
    key = (mask * (length // 4 + 1))[:length]
    return (int.from_bytes(payload, "big") ^ int.from_bytes(key, "big")).to_bytes(length, "big")


async def read_client_frame(
    reader: asyncio.StreamReader, max_size: int = MAX_CLIENT_MESSAGE_BYTES
) -> tuple[int, bytes]:
    """One complete client message, or FrameError for anything outside the subset."""
    first, second = await reader.readexactly(2)
    final, reserved, opcode = bool(first & 0x80), first & 0x70, first & 0x0F
    masked, length = bool(second & 0x80), second & 0x7F
    if length == 126:
        (length,) = struct.unpack(">H", await reader.readexactly(2))
    elif length == 127:
        (length,) = struct.unpack(">Q", await reader.readexactly(8))
    if reserved:
        raise FrameError(1002, "reserved bits set")
    if not masked:
        raise FrameError(1002, "client frames must be masked")
    if opcode in (OP_CLOSE, OP_PING, OP_PONG):
        if not final or length > 125:
            raise FrameError(1002, "invalid control frame")
    elif opcode == 0 or not final:
        raise FrameError(1009, "fragmented messages are not accepted")
    elif opcode == OP_BINARY:
        raise FrameError(1003, "binary frames are not accepted")
    elif opcode != OP_TEXT:
        raise FrameError(1002, "unsupported opcode")
    if length > max_size:
        raise FrameError(1009, "message too large")
    mask = await reader.readexactly(4)
    payload = await reader.readexactly(length) if length else b""
    return opcode, unmask(payload, mask)


def valid_close_code(code: int) -> bool:
    return code in (1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011) or 3000 <= code <= 4999


# --- Poller state --------------------------------------------------------


def _iso(moment: datetime | None) -> str | None:
    return moment.astimezone().isoformat(timespec="seconds") if moment else None


@dataclass
class PollerStatus:
    state: str = STARTING
    since: datetime | None = None
    restarts: int = 0
    last_exit_code: int | None = None
    next_attempt_at: datetime | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "state": self.state,
            "since": _iso(self.since),
            "restarts": self.restarts,
            "last_exit_code": self.last_exit_code,
            "next_attempt_at": _iso(self.next_attempt_at),
        }


class StateCache:
    """The latest envelope plus the fields the stream sends only sometimes."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.latest: dict[str, Any] | None = None
        self.received_at: float | None = None
        self.device: Any = None
        self.carried: dict[str, Any] = {}

    def update(self, envelope: dict[str, Any], now: float) -> None:
        self.latest = envelope
        self.received_at = now
        if envelope.get("device") is not None:
            self.device = envelope["device"]
        control = envelope.get("voltage_control")
        if isinstance(control, dict):
            for key in CARRIED_FIELDS:
                if key in control:
                    self.carried[key] = control[key]

    def merged(self) -> dict[str, Any] | None:
        if self.latest is None:
            return None
        merged = dict(self.latest)
        if merged.get("device") is None and self.device is not None:
            merged["device"] = self.device
        control = merged.get("voltage_control")
        if isinstance(control, dict):
            control = dict(control)
            for key, value in self.carried.items():
                control.setdefault(key, value)
            merged["voltage_control"] = control
        return merged

    def age_s(self, now: float) -> float | None:
        return None if self.received_at is None else max(0.0, now - self.received_at)


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
        return parsed if parsed.tzinfo else parsed.astimezone()
    except (ValueError, OverflowError, OSError):
        # Year 1 or 9999 in a naive timestamp overflows the local-time
        # conversion; any such value is simply not a usable timestamp.
        return None


class SampleHistory:
    """Two in-memory rings, emptied by a restart like the menu bar's own.

    One keeps every sample for a short window (the 30-minute control chart);
    the other keeps one per thirty seconds for long enough to draw a day.
    """

    def __init__(self, native_minutes: int = 30, compact_hours: int = 24):
        self.native_s = native_minutes * 60.0
        self.compact_s = compact_hours * 3600.0
        self.native: collections.deque[tuple[float, dict[str, Any]]] = collections.deque()
        self.compact: collections.deque[tuple[float, dict[str, Any]]] = collections.deque()
        self._last_compact: float | None = None

    @staticmethod
    def entry(envelope: dict[str, Any]) -> dict[str, Any] | None:
        reading = envelope.get("reading")
        if not isinstance(reading, dict):
            return None
        entry: dict[str, Any] = {
            "timestamp": envelope.get("timestamp"),
            "reading": {key: value for key, value in reading.items() if key != "alarms"},
            "cadence": envelope.get("cadence"),
        }
        control = envelope.get("voltage_control")
        if isinstance(control, dict):
            kept: dict[str, Any] = {
                key: control[key] for key in HISTORY_CONTROL_FIELDS if key in control
            }
            for name in HISTORY_ACTUATORS:
                actuator = control.get(name)
                if isinstance(actuator, dict):
                    kept[name] = {
                        key: actuator[key] for key in HISTORY_ACTUATOR_FIELDS if key in actuator
                    }
            entry["voltage_control"] = kept
        else:
            entry["voltage_control"] = None
        return entry

    def add(self, envelope: dict[str, Any]) -> None:
        moment = parse_timestamp(envelope.get("timestamp"))
        entry = self.entry(envelope)
        if moment is None or entry is None:
            return
        epoch = moment.timestamp()
        self.native.append((epoch, entry))
        while self.native and self.native[0][0] < epoch - self.native_s:
            self.native.popleft()
        if self._last_compact is None or epoch >= self._last_compact + COMPACT_STEP_S:
            self._last_compact = epoch
            self.compact.append((epoch, entry))
        while self.compact and self.compact[0][0] < epoch - self.compact_s:
            self.compact.popleft()

    def since(self, resolution: str, moment: datetime | None) -> list[dict[str, Any]]:
        ring = self.native if resolution == "native" else self.compact
        floor = moment.timestamp() if moment else float("-inf")
        return [entry for epoch, entry in ring if epoch > floor]


# --- Poller supervision --------------------------------------------------


def locate_command(name: str, script: str, override: str) -> list[str]:
    """The command that starts one of the installed tools, mirroring
    ExecutableLocator.swift.

    The `override` environment variable wins (as in the menu bar). Otherwise
    beside the hub's own executable first (a virtualenv's bin, or Homebrew's),
    then PATH. A source checkout has neither, so it falls back to the script
    next to this file, which is also what the tests run.
    """
    forced = os.environ.get(override)
    if forced and os.access(forced, os.X_OK):
        return [str(Path(forced).absolute())]
    candidates = [
        Path(sys.argv[0]).parent,
        Path(sys.argv[0]).resolve().parent,
        Path(sys.executable).parent,
    ]
    for directory in candidates:
        found = directory.absolute() / name
        if found.is_file() and os.access(found, os.X_OK):
            return [str(found)]
    on_path = shutil.which(name)
    if on_path:
        return [on_path]
    source = Path(__file__).with_name(script)
    if source.is_file():
        return [sys.executable, str(source)]
    raise HubConfigError(f"cannot find {name} beside solis-hub or on PATH")


def locate_poller() -> list[str]:
    return locate_command("solis-poll", "solis_poll.py", "SOLIS_POLL_PATH")


@dataclass(frozen=True)
class LoginResult:
    ok: bool
    message: str


async def run_login(command: Sequence[str], secret: str, cwd: Path) -> LoginResult:
    """Runs hypervolt-login or octopus-login with the secret on stdin, as the
    menu bar's own sign-in forms do, so the secret is never an argument (and
    never in a process listing) and is handled only by that command.

    Its first "Saved ..." line, or its last "error: " line, is the answer; both
    commands keep those prefixes for exactly this. Nothing from stdin or the
    output is logged here.
    """
    process = await asyncio.create_subprocess_exec(
        *command,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=cwd,
        # Both commands read the secret with getpass, which prefers the
        # controlling terminal to stdin. A hub started from a terminal would
        # otherwise have the login prompt there and ignore the secret sent to
        # it; a new session has no controlling terminal, so stdin is used.
        start_new_session=True,
    )
    try:
        stdout, stderr = await asyncio.wait_for(
            process.communicate((secret + "\n").encode()), LOGIN_TIMEOUT_S
        )
    except asyncio.TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        await process.wait()
        return LoginResult(False, "the sign-in did not finish in time")
    lines_out = stdout.decode("utf-8", "replace").splitlines()
    lines_err = stderr.decode("utf-8", "replace").splitlines()
    if process.returncode == 0:
        saved = next((line for line in lines_out if line.startswith("Saved ")), None)
        return LoginResult(True, saved or "Signed in.")
    error = next((line for line in reversed(lines_err) if line.startswith("error: ")), None)
    return LoginResult(False, error[len("error: ") :] if error else "the sign-in failed")


SpawnFactory = Callable[[Sequence[str]], Awaitable[Any]]


async def spawn_process(
    command: Sequence[str], cwd: Path | None = None
) -> asyncio.subprocess.Process:
    # stderr is piped so the hub can see the poller's restoration result, and is
    # forwarded line by line to the hub's own stderr (and so to journald). The
    # working directory is the state directory because that is what relative
    # poller paths were validated against.
    return await asyncio.create_subprocess_exec(
        *command,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        limit=POLLER_LINE_LIMIT,
        cwd=cwd,
    )


def backoff_delay(first: float, attempt: int) -> float:
    """1 s doubling to the cap. The exponent is bounded before it is used:
    2**attempt overflows a float after about 17 hours of failed starts, which
    ended supervision for good."""
    return min(BACKOFF_MAX_S, first * 2 ** min(attempt, 16))


class PollerSupervisor:
    """Runs one solis-poll child at a time and restarts it when it dies.

    A new child starts only after the previous one has exited and its stdout
    has been drained to EOF, so two pollers can never hold the logger's single
    Modbus session at once.
    """

    def __init__(
        self,
        command: Sequence[str],
        *,
        on_line: Callable[[str], bool],
        on_status: Callable[[PollerStatus], None],
        on_spawn: Callable[[], None],
        on_stderr: Callable[[str], None] | None = None,
        spawn: SpawnFactory = spawn_process,
        monotonic: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], Awaitable[Any]] = asyncio.sleep,
    ):
        self.command = list(command)
        self.on_line = on_line
        self.on_status = on_status
        self.on_spawn = on_spawn
        self.on_stderr = on_stderr
        self._spawn = spawn
        self._monotonic = monotonic
        self._sleep = sleep
        self.status = PollerStatus(since=datetime.now(timezone.utc))
        self.process: Any = None
        self.stopping = False
        self._wanted_attention = False
        self._child_attention = True
        self._wake = asyncio.Event()
        self._restart_requested = False
        self._terminated: Any = None
        self.backoff_first_s = BACKOFF_FIRST_S

    def _set_state(self, state: str, **changes: Any) -> None:
        self.status.state = state
        self.status.since = datetime.now(timezone.utc)
        for key, value in changes.items():
            setattr(self.status, key, value)
        self.on_status(self.status)

    async def run(self) -> None:
        attempt = 0
        first = True
        while not self.stopping:
            started = self._monotonic()
            # A restart that was asked for is not a failure, so it is neither
            # counted nor made to wait out a backoff.
            if not first and not self._restart_requested:
                self.status.restarts += 1
            first = False
            self._restart_requested = False
            await self._run_child()
            if self.stopping:
                break
            if self._restart_requested:
                attempt = 0
                continue
            if self._monotonic() - started >= HEALTHY_RUN_S:
                attempt = 0
            delay = backoff_delay(self.backoff_first_s, attempt)
            attempt += 1
            deadline = datetime.now(timezone.utc).timestamp() + delay
            self._set_state(BACKOFF, next_attempt_at=datetime.fromtimestamp(deadline, timezone.utc))
            log(f"poller down; restarting in {delay:.0f} s")
            self._wake.clear()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self._wake.wait(), delay)
            self.status.next_attempt_at = None

    async def _run_child(self) -> None:
        self._set_state(STARTING, next_attempt_at=None)
        try:
            process = await self._spawn(self.command)
        except OSError as exc:
            log(f"cannot start solis-poll: {exc.strerror or exc}")
            self.status.last_exit_code = None
            return
        self.process = process
        self._child_attention = True
        if self.stopping or self._restart_requested:
            # A stop or restart that arrived mid-spawn found no child to signal.
            self._terminate()
        self.on_spawn()
        self._sync_attention()
        stderr = getattr(process, "stderr", None)
        stderr_task: asyncio.Future[None] | None = None
        if stderr is not None and self.on_stderr is not None:
            stderr_task = asyncio.ensure_future(self._forward_stderr(stderr))
        try:
            await self._drain(process)
        except asyncio.CancelledError:
            if stderr_task is not None:
                stderr_task.cancel()
            # The hub is exiting after a second signal. Waiting for a poller
            # that will not finish restoring would hang the exit, so leave it
            # (it restores itself when its pipe closes).
            self.process = None
            raise
        code = await process.wait()
        self.process = None
        if stderr_task is not None:
            # The pipe closes with the child, so this is prompt; the bound only
            # guards against a grandchild holding it open.
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(stderr_task, 5.0)
        self.status.last_exit_code = code
        if not self.stopping:
            log(f"solis-poll exited with status {code}")

    async def _forward_stderr(self, stderr: Any) -> None:
        while True:
            try:
                raw = await stderr.readline()
            except ValueError:
                continue
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if self.on_stderr is not None:
                try:
                    self.on_stderr(line)
                except Exception as exc:
                    log(f"dropped a poller log line ({type(exc).__name__})")

    async def _drain(self, process: Any) -> None:
        while True:
            try:
                raw = await process.stdout.readline()
            except ValueError:
                log("dropped an oversize line from solis-poll")
                continue
            if not raw:
                return
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                accepted = self.on_line(line)
            except Exception as exc:
                # One hostile line must not end supervision, or the child would
                # block on a full pipe and the hub would look alive but be deaf.
                log(f"dropped a line that could not be processed ({type(exc).__name__})")
                continue
            if accepted and self.status.state in (STARTING, BACKOFF):
                self._set_state(RUNNING)

    def set_attention(self, on: bool) -> None:
        self._wanted_attention = on
        self._sync_attention()

    def _sync_attention(self) -> None:
        """Write only a change. A fresh child starts with attention on."""
        process = self.process
        if process is None or self._child_attention == self._wanted_attention:
            return
        text = b"attention on\n" if self._wanted_attention else b"attention off\n"
        try:
            process.stdin.write(text)
        except (OSError, RuntimeError, ValueError):
            return  # the child is going away; the next one is synced when it starts
        self._child_attention = self._wanted_attention

    def _terminate(self) -> None:
        """SIGTERM the child, once. solis-poll turns SIGTERM into an interrupt,
        so a second one, from a stop after a restart or two quick changes,
        would land while it is restoring the inverter's limits and could cut
        that short."""
        process = self.process
        if process is None or process is self._terminated:
            return
        self._terminated = process
        with contextlib.suppress(ProcessLookupError):
            process.send_signal(signal.SIGTERM)

    def request_stop(self) -> None:
        """Forward SIGTERM; the poller restores the baseline on its way out."""
        self.stopping = True
        self._wake.set()
        self._set_state(STOPPING)
        self._terminate()

    def mark_restoration_pending(self) -> None:
        self._set_state(RESTORATION_PENDING)

    def restart(self, command: Sequence[str]) -> None:
        """Run `command` from now on, replacing the current child.

        The child is sent SIGTERM and restores the baseline on its way out, as
        when the hub stops. The new one starts only after it has exited and its
        output is drained, like any restart, so two pollers never overlap: a
        child that never exits is never replaced.
        """
        self.command = list(command)
        self._restart_requested = True
        self._wake.set()
        if self.process is not None:
            self._set_state(STOPPING)
            self._terminate()


# --- Notifications -------------------------------------------------------


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: urllib would forward the Authorization header to
    wherever it points, including another origin or plain http."""

    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str):
        return None


_NO_REDIRECTS = urllib.request.build_opener(_RefuseRedirects)


class Notifier:
    """Post alerts to ntfy from a background thread.

    Nothing here may wait on the network from the event loop: a slow or dead
    ntfy server only ever stalls this thread's queue.
    """

    def __init__(
        self,
        config: NtfyConfig,
        token: str | None = None,
        sender: Callable[[str, str, str], None] | None = None,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.config = config
        self.token = token
        self._sender = sender or self._post
        self._clock = clock
        self._last_sent: dict[str, float] = {}
        self._queue: queue.Queue[tuple[str, str, str] | None] = queue.Queue(maxsize=32)
        self._thread = threading.Thread(target=self._work, name="ntfy", daemon=True)
        self._thread.start()

    def notify(self, key: str, title: str, message: str, priority: str) -> bool:
        now = self._clock()
        last = self._last_sent.get(key)
        if last is not None and now - last < self.config.min_interval_s:
            return False
        try:
            self._queue.put_nowait((title, message, priority))
        except queue.Full:
            return False
        self._last_sent[key] = now
        return True

    def close(self, timeout: float = 3.0) -> None:
        with contextlib.suppress(queue.Full):
            self._queue.put_nowait(None)
        self._thread.join(timeout)

    def _work(self) -> None:
        while True:
            item = self._queue.get()
            if item is None:
                return
            try:
                self._sender(*item)
            except Exception as exc:
                # The topic is the only secret in the URL, so the error is
                # reduced to its type rather than echoed.
                log(f"ntfy delivery failed ({type(exc).__name__})")

    def _post(self, title: str, message: str, priority: str) -> None:
        headers = {"Title": title, "Priority": priority, "Tags": "zap"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(  # noqa: S310 - scheme validated in the config
            f"{self.config.url}/{self.config.topic}",
            data=message.encode(),
            headers=headers,
            method="POST",
        )
        with _NO_REDIRECTS.open(request, timeout=10):
            pass


EMERGENCY, POLLER_DOWN = "emergency", "poller_down"
INVERTER_UNREACHABLE, RESTORATION = "inverter_unreachable", "restoration_pending"
_ALERTS = {
    EMERGENCY: ("Voltage emergency", "Voltage control has stepped in on an emergency reading."),
    POLLER_DOWN: ("Poller down", "The inverter poller has not been running for over 2 minutes."),
    INVERTER_UNREACHABLE: (
        "Inverter unreachable",
        "The inverter has not answered for over 2 minutes.",
    ),
    RESTORATION: (
        "Restoration pending",
        "The poller stopped without restoring the inverter's baseline; check it.",
    ),
}
_RECOVERIES = {
    EMERGENCY: "The emergency intervention has ended.",
    POLLER_DOWN: "The inverter poller is running again.",
    INVERTER_UNREACHABLE: "The inverter is answering again.",
    RESTORATION: "The baseline has been restored.",
}


class HealthMonitor:
    """Turn samples and supervisor changes into alerts and their recoveries."""

    def __init__(
        self,
        emit: Callable[[str, str, str, str], None],
        clock: Callable[[], float] = time.monotonic,
        delay_s: float = NOTIFY_AFTER_S,
    ):
        self.emit = emit
        self.clock = clock
        self.delay_s = delay_s
        self._since: dict[str, float | None] = {POLLER_DOWN: None, INVERTER_UNREACHABLE: None}
        self._active: set[str] = set()
        self._emergency = False

    def _raise(self, key: str) -> None:
        if key not in self._active:
            self._active.add(key)
            title, message = _ALERTS[key]
            self.emit(key, title, message, "high")

    def _clear(self, key: str) -> None:
        if key in self._active:
            self._active.discard(key)
            self.emit(f"recovered_{key}", "Recovered", _RECOVERIES[key], "default")

    def on_sample(self, envelope: dict[str, Any]) -> None:
        control = envelope.get("voltage_control")
        emergency = isinstance(control, dict) and control.get("emergency") is True
        if emergency and not self._emergency:
            self._raise(EMERGENCY)
        elif not emergency and self._emergency:
            self._clear(EMERGENCY)
        self._emergency = emergency
        health = envelope.get("health")
        failures = health.get("consecutive_failures") if isinstance(health, dict) else None
        if isinstance(failures, int) and failures > 0:
            if self._since[INVERTER_UNREACHABLE] is None:
                self._since[INVERTER_UNREACHABLE] = self.clock()
        else:
            self._since[INVERTER_UNREACHABLE] = None
            self._clear(INVERTER_UNREACHABLE)

    def on_status(self, state: str) -> None:
        if state == RESTORATION_PENDING:
            self._raise(RESTORATION)
        if state in (RUNNING, STOPPING, RESTORATION_PENDING):
            self._since[POLLER_DOWN] = None
            if state == RUNNING:
                self._clear(POLLER_DOWN)
        elif self._since[POLLER_DOWN] is None:
            self._since[POLLER_DOWN] = self.clock()

    def tick(self) -> None:
        now = self.clock()
        for key, since in self._since.items():
            if since is not None and now - since > self.delay_s:
                self._raise(key)


# --- The hub -------------------------------------------------------------


class HubClient:
    """One connected viewer: a bounded outbound queue and its attention flag."""

    def __init__(self, hub: Hub, writer: asyncio.StreamWriter, source: str):
        self.hub = hub
        self.writer = writer
        self.source = source
        self.attention = False
        self.closed = False
        self.overflows = 0
        self.last_pong = time.monotonic()
        self.bad_messages = 0
        self.warned_unknown = False
        self.message_times: collections.deque[float] = collections.deque()
        self._queue: collections.deque[str] = collections.deque()
        self._wake = asyncio.Event()
        self._send_lock = asyncio.Lock()

    def enqueue(self, message: str) -> None:
        if self.closed:
            return
        if len(self._queue) >= CLIENT_QUEUE_LIMIT:
            # A lagging client gets the merged state instead of the backlog, so
            # it never misses an event list and never holds anyone else up.
            self._queue.clear()
            self.overflows += 1
            self._queue.append(self.hub.snapshot_message())
        else:
            self._queue.append(message)
        self._wake.set()

    @property
    def queued(self) -> list[str]:
        return list(self._queue)

    async def send_frame(self, opcode: int, payload: bytes) -> None:
        async with self._send_lock:
            self.writer.write(encode_frame(opcode, payload))
            await asyncio.wait_for(self.writer.drain(), SEND_TIMEOUT_S)

    async def writer_loop(self) -> None:
        try:
            while not self.closed:
                if not self._queue:
                    self._wake.clear()
                    await self._wake.wait()
                    continue
                await self.send_frame(OP_TEXT, self._queue.popleft().encode())
        except (ConnectionError, OSError, asyncio.TimeoutError):
            self.abort()

    async def ping_loop(self, interval: float, timeout: float) -> None:
        try:
            while not self.closed:
                await asyncio.sleep(interval)
                if time.monotonic() - self.last_pong > timeout:
                    log(f"dropping {self.source}: no pong within {timeout:.0f} s")
                    self.abort()
                    return
                await self.send_frame(OP_PING, b"")
        except (ConnectionError, OSError, asyncio.TimeoutError):
            self.abort()

    async def close(self, code: int, reason: str = "", flush: bool = False) -> None:
        """Send a close frame, then end the connection.

        With `flush`, messages already queued go first, so a hub that is stopping
        delivers its last status (such as restoration_pending) before saying
        goodbye. A protocol error skips this: that peer is not to be trusted.
        """
        if self.closed:
            return
        self.closed = True
        self._wake.set()
        try:
            async with self._send_lock:
                while flush and self._queue:
                    self.writer.write(encode_frame(OP_TEXT, self._queue.popleft().encode()))
                    await asyncio.wait_for(self.writer.drain(), 5.0)
                self.writer.write(encode_close(code, reason))
                await asyncio.wait_for(self.writer.drain(), 5.0)
        except (ConnectionError, OSError, asyncio.TimeoutError):
            pass
        self.writer.close()

    async def refuse(self, code: int, error_code: str, message: str) -> None:
        """A policy close, preceded by an error message saying why."""
        if not self.closed:
            with contextlib.suppress(ConnectionError, OSError, asyncio.TimeoutError):
                await self.send_frame(
                    OP_TEXT,
                    json_bytes({"type": "error", "code": error_code, "message": message}),
                )
        await self.close(code, message)

    def abort(self) -> None:
        self.closed = True
        self._wake.set()
        transport = self.writer.transport
        if transport is not None:
            transport.abort()


class Hub:
    """The poller supervisor, state cache and client fan-out behind one port."""

    def __init__(
        self,
        config: HubConfig,
        token: str,
        hub_id: str,
        *,
        poller_command: Sequence[str] | None = None,
        spawn: SpawnFactory = spawn_process,
        notifier: Notifier | None = None,
        ping_interval: float = PING_INTERVAL_S,
        pong_timeout: float = PONG_TIMEOUT_S,
        locate: Callable[[str, str, str], list[str]] = locate_command,
    ):
        self.config = config
        self.locate = locate
        self.token = token
        self.hub_id = hub_id
        self.notifier = notifier
        self.ping_interval = ping_interval
        self.pong_timeout = pong_timeout
        self.cache = StateCache()
        self.history = SampleHistory(config.history_native_minutes, config.history_compact_hours)
        self.limiter = RateLimiter()
        self.abandoned_poller = False
        self.restoration_incomplete = False
        self._last_successful_polls: int | None = None
        self.reserved_upgrades = 0
        self.pending = 0
        self.pending_by_peer: dict[str, int] = {}
        self.clients: set[HubClient] = set()
        self.health = HealthMonitor(self._alert)
        # One change at a time: two sign-ins or saves racing would restart the
        # poller twice and leave it unclear which settings it ended up with.
        self.admin_lock = asyncio.Lock()
        self.settings_store = ControlSettingsStore(config.state_dir / SETTINGS_FILE)
        self.saved_settings = self.settings_store.load()
        self.poller_args = compose_poller_args(config.poller_args, self.saved_settings)
        if self.saved_settings is not None:
            try:
                check_poller_args(self.poller_args)
            except SettingsError as exc:
                raise HubConfigError(
                    f"the saved control settings in {self.settings_store.path} are refused "
                    f"by solis-poll ({exc}); fix or delete that file"
                ) from exc
        command = list(poller_command or locate_poller())
        self.poller_command = command
        if spawn is spawn_process:
            state_dir = config.state_dir

            async def spawn(command: Sequence[str]) -> Any:  # noqa: F811
                return await spawn_process(command, state_dir)

        self.supervisor = PollerSupervisor(
            [*command, "--stream-json", *self.poller_args],
            on_line=self._on_line,
            on_status=self._on_status,
            on_spawn=self._on_spawn,
            on_stderr=self._on_poller_log,
            spawn=spawn,
        )
        self.server: asyncio.Server | None = None
        self.accepting = True
        self._warned_schema = False
        self.history_database = self._history_database(config)

    @staticmethod
    def _history_database(config: HubConfig) -> Path:
        args = config.poller_args
        for index, argument in enumerate(args):
            if _option_matches(argument, "--voltage-history-db"):
                value = argument.split("=", 1)[1] if "=" in argument else None
                if value is None and index + 1 < len(args):
                    value = args[index + 1]
                if value:
                    return _resolve_path(value, config.state_dir)
        return config.state_dir / "voltage-history.sqlite3"

    # Messages ------------------------------------------------------------

    def snapshot_message(self) -> str:
        return json.dumps(
            {
                "type": "snapshot",
                "envelope": self.cache.merged(),
                "poller": self.supervisor.status.to_dict(),
            },
            separators=(",", ":"),
        )

    def hello_message(self) -> str:
        return json.dumps(
            {
                "type": "hello",
                "hub_protocol_version": HUB_PROTOCOL_VERSION,
                "hub_version": solis_poll.VERSION,
                "stream_schema_version": STREAM_SCHEMA_VERSION,
                "hub_id": self.hub_id,
                "poller": self.supervisor.status.to_dict(),
            },
            separators=(",", ":"),
        )

    def _broadcast(self, message: str) -> None:
        for client in tuple(self.clients):
            client.enqueue(message)

    # Supervisor callbacks --------------------------------------------------

    def _on_line(self, line: str) -> bool:
        try:
            envelope = strict_json_loads(line)
        except ValueError:
            log(f"dropped an undecodable line from solis-poll ({len(line)} bytes)")
            return False
        if not isinstance(envelope, dict):
            log("dropped a non-object line from solis-poll")
            return False
        version = envelope.get("schema_version")
        if version != STREAM_SCHEMA_VERSION and not self._warned_schema:
            self._warned_schema = True
            log(f"poller reports stream schema {version!r}; forwarding unchanged")
        self.cache.update(envelope, time.monotonic())
        if self._is_new_measurement(envelope):
            self.history.add(envelope)
        self.health.on_sample(envelope)
        # The poller's own bytes go out untouched inside the wrapper.
        self._broadcast('{"type":"sample","envelope":' + line + "}")
        return True

    def _on_status(self, status: PollerStatus) -> None:
        self.health.on_status(status.state)
        message = {"type": "poller_status", **status.to_dict()}
        self._broadcast(json.dumps(message, separators=(",", ":")))

    def _is_new_measurement(self, envelope: dict[str, Any]) -> bool:
        """False for an envelope that only repeats the last good reading.

        During an outage or a rejected sample the poller keeps emitting its last
        successful reading under a fresh timestamp, with the successful-poll
        counter unchanged. Recording those would chart stale values as new.
        """
        health = envelope.get("health")
        polls = health.get("successful_polls") if isinstance(health, dict) else None
        if not isinstance(polls, int) or isinstance(polls, bool):
            return True
        if polls == self._last_successful_polls:
            return False
        self._last_successful_polls = polls
        return True

    def _on_poller_log(self, line: str) -> None:
        """Pass the poller's own diagnostics through, noting a failed restore.

        The poller reports restoration only as text on stderr, and exits just as
        promptly when restoration failed or was deferred as when it succeeded, so
        the exit alone cannot be taken as proof the baseline is back.
        """
        print(line, file=sys.stderr, flush=True)
        if "voltage control shutdown:" in line and (
            "restoration failed" in line or "restoration deferred" in line
        ):
            self.restoration_incomplete = True

    def _on_spawn(self) -> None:
        """A new poller run: nothing cached from the last one still applies."""
        self.restoration_incomplete = False
        self._last_successful_polls = None
        self.cache.reset()
        self._broadcast(self.snapshot_message())

    def _alert(self, key: str, title: str, message: str, priority: str) -> None:
        log(f"alert: {title}")
        if self.notifier is not None:
            self.notifier.notify(key, title, message, priority)

    # Attention -------------------------------------------------------------

    def attention_changed(self) -> None:
        """No client looking means attention off; any one looking turns it on."""
        self.supervisor.set_attention(any(client.attention for client in self.clients))

    def handle_message(self, client: HubClient, text: str) -> None:
        try:
            message = strict_json_loads(text)
        except ValueError:
            message = None
        if not isinstance(message, dict) or not isinstance(message.get("type"), str):
            client.bad_messages += 1
            return
        kind = message["type"]
        if kind == "attention":
            on = message.get("on")
            if not isinstance(on, bool):
                client.bad_messages += 1
                return
            client.attention = on
            self.attention_changed()
        elif kind == "ping":
            nonce = message.get("nonce")
            if isinstance(nonce, str) and len(nonce) > 128:
                client.bad_messages += 1
                return
            if nonce is not None and (
                isinstance(nonce, bool) or not isinstance(nonce, (str, int, float))
            ):
                client.bad_messages += 1
                return
            client.enqueue(json.dumps({"type": "pong", "nonce": nonce}, separators=(",", ":")))
        elif not client.warned_unknown:
            client.warned_unknown = True
            log(f"ignored an unknown message type from {client.source}: {kind[:32]!r}")

    # HTTP API --------------------------------------------------------------

    def status_payload(self) -> dict[str, Any]:
        return {
            "hub_version": solis_poll.VERSION,
            "hub_protocol_version": HUB_PROTOCOL_VERSION,
            "hub_id": self.hub_id,
            "poller": self.supervisor.status.to_dict(),
            "clients": len(self.clients),
            "envelope_age_s": self.cache.age_s(time.monotonic()),
        }

    def history_samples(self, resolution: str, since: datetime | None) -> list[dict[str, Any]]:
        return self.history.since(resolution, since)

    def history_control(self, kind: str, since: datetime | None) -> list[dict[str, Any]]:
        path = self.history_database
        if not path.exists():
            return []
        uri = f"file:{urllib.parse.quote(str(path))}?mode=ro"
        connection = sqlite3.connect(uri, uri=True, timeout=2.0)
        try:
            connection.row_factory = sqlite3.Row
            if kind == "minutes":
                floor = int(since.timestamp()) if since else 0
                # The cap keeps the newest rows, returned oldest first, so a long
                # retention never hides the latest history.
                rows = connection.execute(
                    "SELECT * FROM (SELECT * FROM voltage_minutes WHERE minute >= ? "
                    "ORDER BY minute DESC LIMIT ?) ORDER BY minute",
                    (floor, HISTORY_ROW_LIMIT),
                ).fetchall()
                return [dict(row) for row in rows]
            # Timestamps are local-offset ISO text, which does not sort across
            # a clock change, so the cut-off is applied after parsing.
            rows = connection.execute(
                "SELECT * FROM voltage_events ORDER BY rowid DESC LIMIT ?", (HISTORY_ROW_LIMIT,)
            ).fetchall()
        finally:
            connection.close()
        events = [dict(row) for row in reversed(rows)]
        if since is None:
            return events
        return [
            event
            for event in events
            if (moment := parse_timestamp(event.get("timestamp"))) is not None and moment > since
        ]

    # Settings and sign-in --------------------------------------------------

    def _poller_path(self, value: Path | None, default_name: str) -> Path:
        """A path as the poller resolves it: its own state directory by default,
        and relative to the hub's state directory, its working directory."""
        path = value or solis_poll.default_control_state_dir() / default_name
        return path if path.is_absolute() else self.config.state_dir / path

    def _export_validated(self, namespace: argparse.Namespace) -> bool:
        identity = solis_poll.control_identity(namespace.host, namespace.port, namespace.slave)
        path = (
            self._poller_path(namespace.export_control_validation, "")
            if namespace.export_control_validation
            else voltage_control.export_validation_path(
                solis_poll.default_control_state_dir(), identity
            )
        )
        try:
            return voltage_control.ExportControlValidation.load(path, identity) is not None
        except ValueError:
            return False

    @staticmethod
    def _credentials_file(path: Path) -> dict[str, Any]:
        """The credentials file's non-secret fields only; the key and tokens in
        it never leave this method."""
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return value if isinstance(value, dict) else {}

    def settings_payload(self) -> dict[str, Any]:
        namespace = check_poller_args(self.poller_args)
        hypervolt = self._credentials_file(
            self._poller_path(namespace.hypervolt_credentials, "hypervolt.json")
        )
        octopus = self._credentials_file(
            self._poller_path(namespace.octopus_credentials, "octopus.json")
        )
        return {
            # Saved settings are returned as saved: with control off, the
            # features that need it are not in the arguments but still chosen.
            "settings": self.saved_settings or settings_from_namespace(namespace),
            "source": "app" if self.saved_settings is not None else "hub_config",
            "export_control_validated": self._export_validated(namespace),
            "hypervolt": {
                "signed_in": bool(hypervolt.get("refresh_token")),
                "charger_id": hypervolt.get("charger_id") or None,
            },
            "octopus": {
                "signed_in": bool(octopus.get("api_key")),
                "account_number": octopus.get("account_number") or None,
                "device_id": octopus.get("device_id") or None,
            },
        }

    async def apply_settings(self, body: Any, source: str) -> dict[str, Any]:
        try:
            settings = parse_settings(body)
            args = compose_poller_args(self.config.poller_args, settings)
            namespace = check_poller_args(args)
            if (
                settings["dynamic_voltage_enabled"]
                and settings["dynamic_export_enabled"]
                and not self._export_validated(namespace)
            ):
                raise SettingsError(
                    "export regulation needs this inverter's installation-validation record "
                    "in the hub's state directory"
                )
        except SettingsError as exc:
            raise HTTPProblem(400, str(exc)) from exc
        try:
            self.settings_store.save(settings)
        except OSError as exc:
            log(f"cannot save control settings: {exc.strerror or exc}")
            raise HTTPProblem(500, "the hub could not save the settings") from exc
        self.saved_settings = settings
        restarted = args != self.poller_args
        if restarted:
            self.poller_args = args
            log(f"control settings changed from {source}; restarting the poller")
            self.supervisor.restart([*self.poller_command, "--stream-json", *args])
        return {**self.settings_payload(), "restarted": restarted}

    async def sign_in(self, service: str, body: Any, source: str) -> dict[str, Any]:
        if not isinstance(body, dict):
            raise HTTPProblem(400, "the body must be a JSON object")
        try:
            namespace = check_poller_args(self.poller_args)
        except SettingsError as exc:
            raise HTTPProblem(500, str(exc)) from exc
        if service == "hypervolt":
            email = _text_field(body, "email", limit=254)
            secret = _text_field(body, "password", limit=1024)
            path = self._poller_path(namespace.hypervolt_credentials, "hypervolt.json")
            command = [
                *self.locate("hypervolt-login", "hypervolt_login.py", "HYPERVOLT_LOGIN_PATH"),
                "--credentials",
                str(path),
                # The = form, so an address that starts with "-" is still a value.
                f"--email={email}",
                f"--token-host={namespace.hypervolt_token_host}",
                f"--token-port={namespace.hypervolt_token_port}",
                f"--api-host={namespace.hypervolt_api_host}",
                f"--api-port={namespace.hypervolt_api_port}",
            ]
            if namespace.hypervolt_insecure:
                command.append("--insecure")
            enabled = namespace.hypervolt_enable
        else:
            secret = _text_field(body, "api_key", limit=256)
            account = _text_field(body, "account", limit=64, required=False)
            device = _text_field(body, "device", limit=128, required=False)
            path = self._poller_path(namespace.octopus_credentials, "octopus.json")
            command = [
                *self.locate("octopus-login", "octopus_login.py", "OCTOPUS_LOGIN_PATH"),
                "--credentials",
                str(path),
                f"--host={namespace.octopus_host}",
                f"--port={namespace.octopus_port}",
            ]
            if namespace.octopus_insecure:
                command.append("--insecure")
            if account:
                command.append(f"--account={account}")
            if device:
                command.append(f"--device={device}")
            enabled = namespace.octopus_enable
        assert secret is not None
        try:
            result = await run_login(command, secret, self.config.state_dir)
        except OSError as exc:
            log(f"cannot start the {service} sign-in: {exc.strerror or exc}")
            raise HTTPProblem(500, f"the hub could not run the {service} sign-in") from exc
        log(f"{service} sign-in from {source} {'succeeded' if result.ok else 'failed'}")
        if not result.ok:
            raise HTTPProblem(400, result.message)
        # The poller reads the file only when it starts.
        if enabled:
            log(f"restarting the poller to use the new {service} credentials")
            self.supervisor.restart(self.supervisor.command)
        return {"message": result.message, "restarted": enabled, **self.settings_payload()}

    # Connection handling ---------------------------------------------------

    async def handle_connection(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            await self._handle(reader, writer)
        except (ConnectionError, OSError, asyncio.IncompleteReadError, asyncio.TimeoutError):
            pass
        except Exception as exc:
            log(f"connection error ({type(exc).__name__})")
        finally:
            with contextlib.suppress(Exception):
                writer.close()

    async def _respond(self, writer: asyncio.StreamWriter, data: bytes) -> None:
        writer.write(data)
        await asyncio.wait_for(writer.drain(), SEND_TIMEOUT_S)

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        peer_host = peer[0] if peer else ""
        if (
            self.pending >= MAX_PENDING_CONNECTIONS
            or self.pending_by_peer.get(peer_host, 0) >= MAX_PENDING_PER_PEER
        ):
            return  # shed load before spending anything on the request
        self.pending += 1
        self.pending_by_peer[peer_host] = self.pending_by_peer.get(peer_host, 0) + 1
        try:
            request = await read_request(reader)
        except BadRequest as exc:
            status = 431 if "large" in str(exc) else 400
            await self._respond(writer, http_response(status))
            return
        finally:
            self.pending -= 1
            remaining = self.pending_by_peer.get(peer_host, 1) - 1
            if remaining > 0:
                self.pending_by_peer[peer_host] = remaining
            else:
                self.pending_by_peer.pop(peer_host, None)
        if request.method not in ("GET", "PUT", "POST"):
            await self._respond(writer, http_response(405, headers=[("Allow", "GET, PUT, POST")]))
            return
        if request.path == "/v1/healthz":
            if request.method != "GET":
                await self._respond(writer, http_response(405, headers=[("Allow", "GET")]))
                return
            await self._respond(writer, http_response(200, json_bytes({"ok": True})))
            return
        source = source_address(peer_host, request.headers)
        if self.limiter.blocked(source):
            await self._respond(writer, http_response(429, headers=[("Retry-After", "60")]))
            return
        if not token_matches(bearer_token(request.headers), self.token):
            self.limiter.record_failure(source)
            await self._respond(
                writer, http_response(401, headers=[("WWW-Authenticate", "Bearer")])
            )
            return
        methods = ROUTES.get(request.path)
        if methods is None:
            await self._respond(writer, http_response(404))
            return
        if request.method not in methods:
            await self._respond(writer, http_response(405, headers=[("Allow", ", ".join(methods))]))
            return
        if request.path == "/v1/stream":
            await self._websocket(reader, writer, request, source)
        elif request.path == "/v1/status":
            await self._respond(writer, http_response(200, json_bytes(self.status_payload())))
        elif request.path in ("/v1/history/samples", "/v1/history/control"):
            await self._history(writer, request)
        else:
            await self._admin(reader, writer, request, source)

    async def _admin(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        request: Request,
        source: str,
    ) -> None:
        """Settings and sign-in: everything that changes what the poller runs."""
        try:
            if request.method == "GET":
                try:
                    payload = self.settings_payload()
                except SettingsError as exc:
                    raise HTTPProblem(500, str(exc)) from exc
            else:
                body = await read_json_body(reader, request.headers)
                if self.admin_lock.locked():
                    raise HTTPProblem(409, "another change is still being applied")
                async with self.admin_lock:
                    if request.path == "/v1/settings":
                        payload = await self.apply_settings(body, source)
                    else:
                        service = request.path.rsplit("/", 1)[1]
                        payload = await self.sign_in(service, body, source)
        except HTTPProblem as problem:
            await self._respond(
                writer, http_response(problem.status, json_bytes({"error": problem.message}))
            )
            return
        await self._respond(writer, http_response(200, json_bytes(payload)))

    async def _history(self, writer: asyncio.StreamWriter, request: Request) -> None:
        raw_since = request.query.get("since", [None])[0]
        since = None
        if raw_since is not None:
            # An unencoded "+" in a UTC offset arrives as a space; an ISO
            # timestamp never contains one, so restoring it is unambiguous.
            since = parse_timestamp(raw_since.replace(" ", "+"))
            if since is None:
                await self._respond(writer, http_response(400, json_bytes({"error": "bad since"})))
                return
        loop = asyncio.get_running_loop()
        if request.path == "/v1/history/samples":
            resolution = request.query.get("resolution", ["native"])[0]
            if resolution not in ("native", "compact"):
                await self._respond(
                    writer, http_response(400, json_bytes({"error": "bad resolution"}))
                )
                return
            rows = self.history_samples(resolution, since)
        else:
            kind = request.query.get("kind", ["minutes"])[0]
            if kind not in ("minutes", "events"):
                await self._respond(writer, http_response(400, json_bytes({"error": "bad kind"})))
                return
            try:
                rows = await loop.run_in_executor(None, self.history_control, kind, since)
            except sqlite3.Error as exc:
                log(f"history database error ({type(exc).__name__})")
                await self._respond(writer, http_response(503))
                return
        extra = [("Vary", "Accept-Encoding")]
        if "gzip" in request.headers.get("accept-encoding", "").lower():
            body = await loop.run_in_executor(None, lambda: gzip.compress(json_bytes(rows), 5))
            extra.append(("Content-Encoding", "gzip"))
        else:
            body = json_bytes(rows)
        await self._respond(writer, http_response(200, body, headers=extra))

    async def _websocket(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        request: Request,
        source: str,
    ) -> None:
        headers = request.headers
        upgrade = "websocket" in headers.get("upgrade", "").lower()
        connection = "upgrade" in headers.get("connection", "").lower()
        if not (upgrade and connection) or headers.get("sec-websocket-version") != "13":
            await self._respond(
                writer, http_response(426, headers=[("Sec-WebSocket-Version", "13")])
            )
            return
        key = headers.get("sec-websocket-key", "")
        if not valid_websocket_key(key):
            await self._respond(writer, http_response(400))
            return
        if (
            not self.accepting
            or len(self.clients) + self.reserved_upgrades >= self.config.max_clients
        ):
            await self._respond(writer, http_response(503))
            return
        # The slot is taken before the first await: the upgrade response yields,
        # and several handlers could otherwise all see the same free slot.
        self.reserved_upgrades += 1
        try:
            await self._respond(
                writer,
                (
                    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                    f"Connection: Upgrade\r\nSec-WebSocket-Accept: {websocket_accept(key)}\r\n\r\n"
                ).encode("latin-1"),
            )
        finally:
            self.reserved_upgrades -= 1
        client = HubClient(self, writer, source)
        # Registered with no await after the snapshot is built, so no sample can
        # fall between the snapshot and the first live message.
        client.enqueue(self.hello_message())
        client.enqueue(self.snapshot_message())
        self.clients.add(client)
        log(f"client connected from {source} ({len(self.clients)} connected)")
        tasks = [
            asyncio.ensure_future(client.writer_loop()),
            asyncio.ensure_future(client.ping_loop(self.ping_interval, self.pong_timeout)),
        ]
        try:
            await self._read_loop(reader, client)
        finally:
            client.closed = True
            self.clients.discard(client)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            self.attention_changed()
            log(f"client {source} disconnected ({len(self.clients)} connected)")

    async def _read_loop(self, reader: asyncio.StreamReader, client: HubClient) -> None:
        while not client.closed:
            try:
                opcode, payload = await read_client_frame(reader)
            except FrameError as exc:
                await client.refuse(exc.code, "protocol", exc.reason)
                return
            except (asyncio.IncompleteReadError, ConnectionError, OSError):
                return
            if opcode == OP_CLOSE:
                code = 1000
                if len(payload) == 1:
                    code = 1002
                elif len(payload) >= 2:
                    (received,) = struct.unpack(">H", payload[:2])
                    code = received if valid_close_code(received) else 1002
                await client.close(code)
                return
            if opcode == OP_PING:
                with contextlib.suppress(ConnectionError, OSError, asyncio.TimeoutError):
                    await client.send_frame(OP_PONG, payload)
            elif opcode == OP_PONG:
                client.last_pong = time.monotonic()
            else:
                try:
                    text = payload.decode("utf-8")
                except UnicodeDecodeError:
                    await client.refuse(1007, "protocol", "text frames must be UTF-8")
                    return
                now = time.monotonic()
                client.message_times.append(now)
                while client.message_times[0] < now - CLIENT_MESSAGE_WINDOW_S:
                    client.message_times.popleft()
                if len(client.message_times) > CLIENT_MESSAGE_LIMIT:
                    await client.refuse(1008, "policy", "too many messages")
                    return
                self.handle_message(client, text)
                if client.bad_messages >= 10:
                    await client.refuse(1008, "policy", "too many invalid messages")
                    return

    # Lifecycle ---------------------------------------------------------------

    async def start_server(self) -> None:
        self.server = await asyncio.start_server(
            self.handle_connection,
            self.config.listen_host,
            self.config.listen_port,
            limit=MAX_REQUEST_HEAD_BYTES,
        )

    @property
    def port(self) -> int:
        assert self.server is not None and self.server.sockets
        return int(self.server.sockets[0].getsockname()[1])

    async def _health_ticks(self) -> None:
        while True:
            await asyncio.sleep(5.0)
            self.health.tick()

    async def run(self, stop: asyncio.Event, force: asyncio.Event) -> None:
        await self.start_server()
        log(f"listening on {self.config.listen_host}:{self.port}")
        supervisor_task = asyncio.ensure_future(self.supervisor.run())

        def supervisor_ended(task: asyncio.Future[None]) -> None:
            # A supervisor that died would leave the hub serving with no poller
            # and no way to start one. Failing loudly lets systemd restart it.
            if not task.cancelled() and task.exception() is not None and not stop.is_set():
                log(f"the poller supervisor failed ({type(task.exception()).__name__}); stopping")
                stop.set()

        supervisor_task.add_done_callback(supervisor_ended)
        ticker = asyncio.ensure_future(self._health_ticks())
        try:
            await stop.wait()
        finally:
            await self.shutdown(supervisor_task, ticker, force)

    async def shutdown(
        self,
        supervisor_task: asyncio.Future[None],
        ticker: asyncio.Future[None],
        force: asyncio.Event,
    ) -> None:
        ticker.cancel()
        self.accepting = False
        if self.server is not None:
            self.server.close()
        log("stopping: forwarding SIGTERM to the poller")
        self.supervisor.request_stop()
        # Clients stay connected while the poller winds down, so they see the
        # restoration it performs; only then are they sent away.
        # A second signal at any point abandons the wait, so an impatient
        # operator is never stuck behind a poller that will not finish.
        waiter: asyncio.Future[Any] = asyncio.ensure_future(force.wait())
        done, _ = await asyncio.wait(
            {supervisor_task, waiter},
            timeout=RESTORATION_WAIT_S,
            return_when=asyncio.FIRST_COMPLETED,
        )
        if supervisor_task not in done:
            log("poller has not exited; baseline restoration is pending, leaving it running")
            self.supervisor.mark_restoration_pending()
            if waiter not in done:
                await asyncio.wait({supervisor_task, waiter}, return_when=asyncio.FIRST_COMPLETED)
        waiter.cancel()
        # Recorded before clients are told, so the caller knows to skip the
        # interpreter's normal teardown (see serve_forever).
        self.abandoned_poller = self.supervisor.process is not None
        if self.restoration_incomplete and self.supervisor.status.state != RESTORATION_PENDING:
            log("the poller exited without restoring the baseline; reporting restoration pending")
            self.supervisor.mark_restoration_pending()
        for client in tuple(self.clients):
            await client.close(1001, "hub stopping", flush=True)
        if self.server is not None:
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.server.wait_closed(), 5.0)
        if self.notifier is not None:
            self.notifier.close()


def read_ntfy_token(config: NtfyConfig | None) -> str | None:
    if config is None or config.token_file is None:
        return None
    try:
        return config.token_file.read_text(encoding="utf-8").strip() or None
    except OSError as exc:
        raise HubConfigError(f"cannot read the ntfy token file: {exc.strerror or exc}") from exc


def build_hub(config: HubConfig) -> Hub:
    ensure_state_dir(config.state_dir)
    token = read_token(config.token_file)
    notifier = None
    if config.ntfy is not None:
        notifier = Notifier(config.ntfy, read_ntfy_token(config.ntfy))
    return Hub(config, token, load_hub_id(config.state_dir), notifier=notifier)


async def serve_forever(config: HubConfig) -> int:
    hub = build_hub(config)
    stop, force = asyncio.Event(), asyncio.Event()
    loop = asyncio.get_running_loop()

    def interrupted() -> None:
        # The first signal stops gracefully; a second abandons the wait for a
        # poller that will not finish restoring, without ever killing it.
        if stop.is_set():
            force.set()
        stop.set()

    for name in ("SIGTERM", "SIGINT"):
        loop.add_signal_handler(getattr(signal, name), interrupted)
    try:
        await hub.run(stop, force)
    except OSError as exc:
        raise HubConfigError(
            f"cannot listen on {config.listen_host}:{config.listen_port}: {exc.strerror or exc}"
        ) from exc
    if hub.abandoned_poller:
        # asyncio closes a subprocess transport by killing a child that is still
        # running, which would defeat leaving it to finish restoring. Leaving
        # without finalising the loop keeps the poller alive; its pipes close
        # with this process and it restores the baseline on its own.
        log("exiting with the poller still running")
        sys.stderr.flush()
        os._exit(0)
    return 0


def default_config_path() -> Path:
    return default_state_dir() / "hub.json"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="solis-hub", description=__doc__)
    parser.add_argument("--version", action="version", version=f"%(prog)s {solis_poll.VERSION}")
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="run the hub")
    serve.add_argument("--config", type=Path, help="configuration file (default: hub.json)")
    check = commands.add_parser("check", help="validate the configuration and exit")
    check.add_argument("--config", type=Path, help="configuration file (default: hub.json)")
    token = commands.add_parser("token", help="manage the bearer token")
    token.add_argument("action", choices=("new", "show"))
    token.add_argument("--config", type=Path, help="configuration file naming the token path")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "token":
            return token_command(args)
        config = load_config(args.config or default_config_path())
        if args.command == "check":
            read_token(config.token_file)
            locate_poller()
            saved = ControlSettingsStore(config.state_dir / SETTINGS_FILE).load()
            if saved is not None:
                try:
                    check_poller_args(compose_poller_args(config.poller_args, saved))
                except SettingsError as exc:
                    raise HubConfigError(f"the saved control settings are refused: {exc}") from exc
                print(f"control settings: {config.state_dir / SETTINGS_FILE} (set from an app)")
            print("configuration ok")
            return 0
        return asyncio.run(serve_forever(config))
    except HubConfigError as exc:
        print(f"solis-hub: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


def token_command(args: argparse.Namespace) -> int:
    path = default_state_dir() / "hub-token"
    config_path = args.config
    if config_path is not None:
        path = load_config(config_path).token_file
    if args.action == "new":
        print(write_token(path))
        print(
            f"solis-hub: wrote {path}; restart solis-hub for the new token to take effect",
            file=sys.stderr,
        )
    else:
        print(read_token(path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
