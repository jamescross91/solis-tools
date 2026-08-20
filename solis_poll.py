#!/usr/bin/env python3
"""Live terminal monitor for a Solis hybrid inverter over Modbus TCP."""

from __future__ import annotations

import argparse
import csv
import ipaddress
import json
import logging
import shutil
import sys
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import IO, Any, NoReturn


MIN_PYTHON = (3, 10)
VERSION = "0.3.1"
HISTORY_SECONDS = 6 * 60 * 60
SPARK_LEVELS = "▁▂▃▄▅▆▇█"

# ESINV fault registers 33116-33120. Bit numbers run from the least-significant
# bit of the first register through to the most-significant bit of the fifth.
# Cross-checked against the Solis hybrid protocol and the MIT-licensed map at
# https://github.com/szlaskidaniel/solar-inverter-modbus-registers
INVERTER_FAULTS = {
    0: ("1015", "NO-Grid", "fault"),
    1: ("1010", "OV-G-V", "fault"),
    2: ("1011", "UN-G-V", "fault"),
    3: ("1012", "OV-G-F", "fault"),
    4: ("1013", "UN-G-F", "fault"),
    5: ("1016", "G-PHASE", "fault"),
    6: ("1017", "G-F-FLU", "fault"),
    7: ("1014", "Reve-Grid", "fault"),
    8: ("1019", "IGFOL-F", "fault"),
    9: ("2011", "MET_Comm_FAIL", "warning"),
    10: ("2010", "Fail Safe", "warning"),
    16: ("1056", "OV-VBackup", "fault"),
    17: ("1057", "Over-Load", "fault"),
    32: ("1055", "NO-Battery", "warning"),
    33: ("1053", "OV-Vbatt", "fault"),
    34: ("1054", "UN-Vbatt", "fault"),
    48: ("1020", "OV-DC", "fault"),
    49: ("1021", "OV-BUS", "fault"),
    50: ("1022", "UNB-BUS", "fault"),
    51: ("1023", "UN-BUS", "fault"),
    52: ("1024", "UNB2-BUS", "fault"),
    53: ("1025", "OV-DCA-I", "fault"),
    54: ("1026", "OV-DCB-I", "fault"),
    55: ("1027", "DC-INTF.", "warning"),
    56: ("1018", "OV-G-I", "fault"),
    57: ("1048", "IGBT-OV-I", "fault"),
    58: ("1046", "GRID-INTF02", "warning"),
    59: ("1040", "AFCI-Check", "warning"),
    60: ("1041", "ARC-FAULT", "fault"),
    61: ("1047", "IG-AD", "warning"),
    62: ("1058", "DspSelfChk", "fault"),
    64: ("1030", "GRID-INTF.", "warning"),
    65: ("1037", "DCInj-FAULT", "warning"),
    66: ("1032", "OV-TEM", "fault"),
    67: ("1035", "Relay-FAULT", "fault"),
    68: ("103A", "UN-TEM", "warning"),
    69: ("1033", "PV ISO-PRO", "fault"),
    70: ("1038", "12Power-FAULT", "fault"),
    71: ("1034", "ILeak-FAULT", "fault"),
    72: ("1039", "ILeak-Check", "warning"),
    73: ("1031", "INI-FAULT", "fault"),
    74: ("1036", "DSP-B-FAULT", "fault"),
    75: ("1051", "OV-Vbatt-H", "fault"),
    76: ("1052", "OV-ILLC", "fault"),
    77: ("1050", "OV-IgTr", "fault"),
    78: ("2012", "CAN_Comm_FAIL", "warning"),
    79: ("2014", "DSP_Comm_FAIL", "warning"),
}

STATUS_LABELS = {
    0x0000: "Waiting",
    0x0001: "OpenRun",
    0x0002: "SoftRun",
    0x0003: "Generating",
    0x0004: "Standby",
    0x0005: "StandbySync",
    0x0006: "GridToLoad",
    0x000F: "Normal",
    0x1004: "Off-grid",
    0x1010: "OV-G-V",
    0x1011: "UN-G-V",
    0x1012: "OV-G-F",
    0x1013: "UN-G-F",
    0x1014: "G-IMP",
    0x1015: "NO-Grid",
    0x1016: "G-PHASE",
    0x1017: "G-F-FLU",
    0x1018: "OV-G-I",
    0x1019: "IGFOL-F",
    0x1020: "OV-DC",
    0x1021: "OV-BUS",
    0x1031: "INI-FAULT",
    0x1032: "OV-TEM",
    0x1033: "PV ISO-PRO",
    0x1041: "ARC-FAULT",
}


def fail(message: str, code: int = 2) -> NoReturn:
    """Print a concise, actionable error without starting the dashboard."""
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


def load_modbus_client():
    """Load the native Modbus dependency and provide an actionable failure."""
    if sys.version_info < MIN_PYTHON:
        required = ".".join(map(str, MIN_PYTHON))
        fail(f"Python {required} or newer is required (found {sys.version.split()[0]}).")
    try:
        from pymodbus.client import ModbusTcpClient
        from pymodbus.exceptions import ModbusException
    except ImportError:
        fail(
            "required Python package 'pymodbus' is not installed. "
            "Create/activate a virtual environment, then run: "
            "python3 -m pip install -r requirements.txt"
        )
    logging.getLogger("pymodbus").setLevel(logging.CRITICAL)
    return ModbusTcpClient, ModbusException


@dataclass(frozen=True)
class Alarm:
    code: str
    message: str
    severity: str

    def display(self) -> str:
        return f"{self.code} {self.message}"


@dataclass(frozen=True)
class DeviceInfo:
    model_code: int
    dsp_version: int
    hmi_version: int
    protocol_version: int
    type_definition: int | None
    profile_validated: bool

    def display(self) -> str:
        validation = "validated hybrid" if self.profile_validated else "hybrid register map"
        return (
            f"model {self.model_code} · DSP {self.dsp_version} · HMI {self.hmi_version} · "
            f"protocol {self.protocol_version} · {validation}"
        )


@dataclass(frozen=True)
class SlowMetrics:
    inverter_temperature_c: float
    inverter_status_code: int
    inverter_status: str
    inverter_alarms: tuple[Alarm, ...]
    pv_today_kwh: float | None


@dataclass(frozen=True)
class Reading:
    voltage: float
    inverter_temperature_c: float
    inverter_status_code: int
    inverter_status: str
    state_of_charge: int
    house_load_kw: float
    battery_kw: float
    battery_status: str
    grid_kw: float
    grid_status: str
    alarms: tuple[Alarm, ...] = ()
    pv_kw: float | None = None
    pv_today_kwh: float | None = None


@dataclass
class ConnectionHealth:
    last_success_at: float | None = None
    latency_ms: float = 0.0
    successful_polls: int = 0
    total_failures: int = 0
    consecutive_failures: int = 0
    reconnects: int = 0

    def succeeded(self, completed_at: float, latency_ms: float) -> None:
        self.last_success_at = completed_at
        self.latency_ms = latency_ms
        self.successful_polls += 1
        self.consecutive_failures = 0

    def failed(self) -> None:
        self.total_failures += 1
        self.consecutive_failures += 1


class UnsupportedProfileError(ConnectionError):
    """The responding device does not use the supported hybrid register map."""


class RecordingError(OSError):
    """A local recording file could not be opened, read or written."""


def decode_inverter_status(code: int) -> str:
    if code in STATUS_LABELS:
        return STATUS_LABELS[code]
    if code >= 0x1000:
        return f"Alarm 0x{code:04X}"
    return f"Status 0x{code:04X}"


def decode_inverter_faults(words: list[int]) -> tuple[Alarm, ...]:
    alarms: list[Alarm] = []
    for word_index, word in enumerate(words):
        for bit in range(16):
            if not word & (1 << bit):
                continue
            index = word_index * 16 + bit
            code, message, severity = INVERTER_FAULTS.get(
                index, (f"INV.{word_index + 1}.{bit}", "unknown fault bit", "warning")
            )
            alarms.append(Alarm(code, message, severity))
    return tuple(alarms)


def decode_bms_faults(words: list[int]) -> tuple[Alarm, ...]:
    """Surface active BMS bits without guessing the model-specific meaning."""
    alarms: list[Alarm] = []
    for word_index, word in enumerate(words):
        for bit in range(16):
            if word & (1 << bit):
                register = 33145 + word_index
                alarms.append(
                    Alarm(
                        f"BMS{word_index + 1}.{bit}",
                        f"active (register {register} bit {bit})",
                        "fault",
                    )
                )
    return tuple(alarms)


def checked(value: float, low: float, high: float, name: str) -> float:
    if not low <= value <= high:
        raise UnsupportedProfileError(
            f"{name} decoded as {value:g}, outside the expected {low:g}..{high:g} range; "
            "this inverter may use an unsupported register map"
        )
    return value


class SolisClient:
    """Persistent native Modbus TCP client and Solis ESINV register decoder."""

    def __init__(self, host: str, port: int, slave: int, timeout: float):
        ModbusTcpClient, self.modbus_exception = load_modbus_client()
        self.client = ModbusTcpClient(host=host, port=port, timeout=timeout)
        self.slave = slave

    def connect(self) -> None:
        if not self.client.connect():
            raise ConnectionError("could not connect to the inverter")

    def close(self) -> None:
        self.client.close()

    def _registers(self, reference: int, count: int) -> list[int]:
        # The original mbpoll script used 1-based references. PyModbus sends
        # zero-based PDU addresses, so subtract one to preserve those reads.
        response = self.client.read_input_registers(
            address=reference - 1,
            count=count,
            device_id=self.slave,
        )
        if response.isError():
            raise ConnectionError(f"Modbus error reading register {reference}: {response}")
        registers = response.registers
        if len(registers) != count:
            raise ConnectionError(
                f"incomplete response at register {reference} "
                f"(expected {count}, received {len(registers)})"
            )
        return registers

    @staticmethod
    def _unsigned_32(high: int, low: int) -> int:
        return (high << 16) | low

    @staticmethod
    def _signed_32(high: int, low: int) -> int:
        value = (high << 16) | low
        return value - 0x1_0000_0000 if value >= 0x8000_0000 else value

    @staticmethod
    def _signed_16(value: int) -> int:
        return value - 0x1_0000 if value >= 0x8000 else value

    def identify(self) -> DeviceInfo:
        """Read model metadata and reject a positively identified string map."""
        metadata = self._registers(33001, 4)  # Raw PDU addresses 33000-33003.
        type_definition: int | None = None
        try:
            type_definition = self._registers(35001, 1)[0]  # Raw address 35000.
        except ConnectionError as exc:
            # Older firmware may not expose the type-definition register. A
            # Modbus illegal-address response is safe to ignore; I/O failures are not.
            if "Modbus error reading register 35001" not in str(exc):
                raise

        profile_validated = False
        if type_definition is not None:
            high_byte = type_definition >> 8
            decimal_prefix = int(str(type_definition)[:2]) if type_definition >= 10 else 0
            if high_byte == 0x10 or decimal_prefix == 10:
                raise UnsupportedProfileError(
                    "the inverter reports the Solis string-inverter register family; "
                    "this monitor currently supports the hybrid ESINV-33000 map"
                )
            profile_validated = high_byte == 0x20 or decimal_prefix == 20

        if not any(metadata) and not profile_validated:
            raise UnsupportedProfileError(
                "the Solis hybrid identity block returned only zeroes; "
                "the ESINV-33000 register map could not be verified"
            )
        return DeviceInfo(*metadata, type_definition, profile_validated)

    def poll_slow(self, pv_enabled: bool) -> SlowMetrics:
        operational = self._registers(33094, 3)  # Raw 33093-33095.
        temperature = self._signed_16(operational[0]) / 10
        checked(temperature, -50, 150, "inverter temperature")
        status_code = operational[2]
        fault_words = self._registers(33117, 5)  # Raw 33116-33120.
        pv_today = None
        if pv_enabled:
            pv_today = self._registers(33036, 1)[0] / 10  # Raw 33035.
            checked(pv_today, 0, 1000, "PV energy today")
        return SlowMetrics(
            inverter_temperature_c=temperature,
            inverter_status_code=status_code,
            inverter_status=decode_inverter_status(status_code),
            inverter_alarms=decode_inverter_faults(fault_words),
            pv_today_kwh=pv_today,
        )

    def poll_fast(self, slow: SlowMetrics, pv_enabled: bool) -> Reading:
        voltage = self._registers(33074, 1)[0] / 10
        status = self._registers(33136, 16)
        grid = self._registers(33264, 2)

        state_of_charge = status[4]
        house_load_kw = status[12] / 1000
        battery_kw = self._unsigned_32(status[14], status[15]) / 1000
        grid_kw = self._signed_32(grid[0], grid[1]) / 1000
        checked(voltage, 0, 300, "grid voltage")
        checked(state_of_charge, 0, 100, "battery state of charge")
        checked(house_load_kw, 0, 250, "house load")
        checked(battery_kw, 0, 250, "battery power")
        checked(grid_kw, -500, 500, "grid power")

        battery_status = (
            "Idle" if battery_kw < 0.05 else "Discharging" if status[0] == 1 else "Charging"
        )
        grid_status = (
            "Exporting" if grid_kw > 0.05 else "Importing" if grid_kw < -0.05 else "Idle"
        )
        pv_kw = None
        if pv_enabled:
            pv_words = self._registers(33058, 2)  # Raw 33057-33058.
            pv_kw = self._unsigned_32(*pv_words) / 1000
            checked(pv_kw, 0, 250, "PV power")

        return Reading(
            voltage=voltage,
            inverter_temperature_c=slow.inverter_temperature_c,
            inverter_status_code=slow.inverter_status_code,
            inverter_status=slow.inverter_status,
            state_of_charge=state_of_charge,
            house_load_kw=house_load_kw,
            battery_kw=battery_kw,
            battery_status=battery_status,
            grid_kw=grid_kw,
            grid_status=grid_status,
            alarms=slow.inverter_alarms + decode_bms_faults(status[10:12]),
            pv_kw=pv_kw,
            pv_today_kwh=slow.pv_today_kwh,
        )


class Recorder:
    """Append successful samples to CSV and/or JSONL and restore recent history."""

    CSV_FIELDS = (
        "timestamp",
        "grid_voltage_v",
        "inverter_temperature_c",
        "inverter_status_code",
        "inverter_status",
        "battery_soc_percent",
        "house_load_kw",
        "battery_kw",
        "battery_status",
        "grid_kw",
        "grid_status",
        "pv_kw",
        "pv_today_kwh",
        "alarms",
        "latency_ms",
    )

    def __init__(self, csv_path: Path | None, jsonl_path: Path | None):
        self.csv_path = csv_path
        self.jsonl_path = jsonl_path
        self.csv_file: IO[str] | None = None
        self.csv_writer: csv.DictWriter | None = None
        self.jsonl_file: IO[str] | None = None
        try:
            if csv_path:
                self._check_parent(csv_path)
                new_file = not csv_path.exists() or csv_path.stat().st_size == 0
                if not new_file:
                    self._validate_csv_header(csv_path)
                self.csv_file = csv_path.open("a", encoding="utf-8", newline="")
                self.csv_writer = csv.DictWriter(self.csv_file, fieldnames=self.CSV_FIELDS)
                if new_file:
                    self.csv_writer.writeheader()
                    self.csv_file.flush()
            if jsonl_path:
                self._check_parent(jsonl_path)
                self.jsonl_file = jsonl_path.open("a", encoding="utf-8")
        except OSError as exc:
            self.close()
            raise RecordingError(f"cannot open recording file: {exc}") from exc

    @staticmethod
    def _check_parent(path: Path) -> None:
        if not path.parent.exists():
            raise OSError(f"parent directory does not exist: {path.parent}")

    @classmethod
    def _validate_csv_header(cls, path: Path) -> None:
        with path.open(encoding="utf-8", newline="") as source:
            header = next(csv.reader(source), [])
        if tuple(header) != cls.CSV_FIELDS:
            raise OSError(
                f"existing CSV has an incompatible header: {path}; "
                "choose a new recording file"
            )

    @staticmethod
    def _record(reading: Reading, health: ConnectionHealth, timestamp: datetime) -> dict[str, Any]:
        return {
            "timestamp": timestamp.isoformat(timespec="seconds"),
            "grid_voltage_v": reading.voltage,
            "inverter_temperature_c": reading.inverter_temperature_c,
            "inverter_status_code": reading.inverter_status_code,
            "inverter_status": reading.inverter_status,
            "battery_soc_percent": reading.state_of_charge,
            "house_load_kw": reading.house_load_kw,
            "battery_kw": reading.battery_kw,
            "battery_status": reading.battery_status,
            "grid_kw": reading.grid_kw,
            "grid_status": reading.grid_status,
            "pv_kw": reading.pv_kw,
            "pv_today_kwh": reading.pv_today_kwh,
            "alarms": "; ".join(alarm.display() for alarm in reading.alarms),
            "latency_ms": round(health.latency_ms, 1),
        }

    def write(self, reading: Reading, health: ConnectionHealth, timestamp: datetime) -> None:
        record = self._record(reading, health, timestamp)
        try:
            if self.csv_writer and self.csv_file:
                self.csv_writer.writerow(
                    {key: "" if value is None else value for key, value in record.items()}
                )
                self.csv_file.flush()
            if self.jsonl_file:
                self.jsonl_file.write(json.dumps(record, separators=(",", ":")) + "\n")
                self.jsonl_file.flush()
        except (OSError, csv.Error) as exc:
            raise RecordingError(f"cannot write recording: {exc}") from exc

    def load_history(self, now: float) -> deque[tuple[float, Reading]]:
        path = self.csv_path or self.jsonl_path
        if not path or not path.exists() or path.stat().st_size == 0:
            return deque()
        history: deque[tuple[float, Reading]] = deque()
        cutoff = now - HISTORY_SECONDS
        try:
            if path == self.csv_path:
                with path.open(encoding="utf-8", newline="") as source:
                    self._restore_records(csv.DictReader(source), history, cutoff)
            else:
                with path.open(encoding="utf-8") as source:
                    records = (json.loads(line) for line in source if line.strip())
                    self._restore_records(records, history, cutoff)
        except (OSError, csv.Error, json.JSONDecodeError) as exc:
            raise RecordingError(f"cannot restore history from {path}: {exc}") from exc
        return history

    @staticmethod
    def _restore_records(
        records: Any, history: deque[tuple[float, Reading]], cutoff: float
    ) -> None:
        for record in records:
            try:
                sampled_at = datetime.fromisoformat(str(record["timestamp"])).timestamp()
                if sampled_at < cutoff:
                    continue
                history.append((sampled_at, reading_from_record(record)))
            except (KeyError, TypeError, ValueError):
                continue

    def close(self) -> None:
        if self.csv_file:
            self.csv_file.close()
            self.csv_file = None
        if self.jsonl_file:
            self.jsonl_file.close()
            self.jsonl_file = None


def optional_float(value: Any) -> float | None:
    return None if value in (None, "") else float(value)


def reading_from_record(record: dict[str, Any]) -> Reading:
    alarm_text = str(record.get("alarms", ""))
    restored_alarms = tuple(
        Alarm(part.split(" ", 1)[0], part.split(" ", 1)[1] if " " in part else "", "warning")
        for part in alarm_text.split("; ")
        if part
    )
    return Reading(
        voltage=float(record["grid_voltage_v"]),
        inverter_temperature_c=float(record["inverter_temperature_c"]),
        inverter_status_code=int(record["inverter_status_code"]),
        inverter_status=str(record["inverter_status"]),
        state_of_charge=int(record["battery_soc_percent"]),
        house_load_kw=float(record["house_load_kw"]),
        battery_kw=float(record["battery_kw"]),
        battery_status=str(record["battery_status"]),
        grid_kw=float(record["grid_kw"]),
        grid_status=str(record["grid_status"]),
        alarms=restored_alarms,
        pv_kw=optional_float(record.get("pv_kw")),
        pv_today_kwh=optional_float(record.get("pv_today_kwh")),
    )


class Palette:
    """ANSI colours, disabled automatically for redirected output or --no-colour."""

    def __init__(self, enabled: bool):
        self.enabled = enabled

    def apply(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.enabled else text

    def title(self, text: str) -> str:
        return self.apply("1;36", text)

    def good(self, text: str) -> str:
        return self.apply("1;32", text)

    def warn(self, text: str) -> str:
        return self.apply("1;33", text)

    def bad(self, text: str) -> str:
        return self.apply("1;31", text)

    def dim(self, text: str) -> str:
        return self.apply("2", text)


def bar(value: float, maximum: float, width: int, palette: Palette, colour: str) -> str:
    filled = max(0, min(width, round((abs(value) / maximum) * width)))
    return palette.apply(colour, "█" * filled + "·" * (width - filled))


def battery_flow(reading: Reading) -> float:
    if reading.battery_status == "Discharging":
        return reading.battery_kw
    if reading.battery_status == "Charging":
        return -reading.battery_kw
    return 0.0


def sparkline(values: list[float], width: int) -> tuple[str, float, float]:
    """Downsample retained history into a fixed-width Unicode line graph."""
    if not values:
        return " " * width, 0.0, 0.0
    low, high = min(values), max(values)
    if len(values) == 1:
        sampled = values * width
    elif len(values) < width:
        sampled = []
        for column in range(width):
            position = column * (len(values) - 1) / (width - 1)
            left = int(position)
            right = min(left + 1, len(values) - 1)
            fraction = position - left
            sampled.append(values[left] + (values[right] - values[left]) * fraction)
    else:
        sampled = []
        for column in range(width):
            start = column * len(values) // width
            end = max(start + 1, (column + 1) * len(values) // width)
            bucket = values[start:end]
            sampled.append(sum(bucket) / len(bucket))
    if high == low:
        graph = SPARK_LEVELS[len(SPARK_LEVELS) // 2] * len(sampled)
    else:
        graph = "".join(
            SPARK_LEVELS[
                min(
                    len(SPARK_LEVELS) - 1,
                    round((value - low) / (high - low) * (len(SPARK_LEVELS) - 1)),
                )
            ]
            for value in sampled
        )
    return graph, low, high


def format_duration(seconds: float) -> str:
    elapsed = max(0, int(seconds))
    hours, remainder = divmod(elapsed, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:d}:{minutes:02d}:{seconds:02d}"


def history_window_label(
    history: deque[tuple[float, Reading]], started_at: float, now: float
) -> str:
    if history and history[0][0] < started_at - 1:
        return f"restored · last {format_duration(min(HISTORY_SECONDS, now - history[0][0]))}"
    return f"since launch {format_duration(now - started_at)}"


def history_row(
    label: str,
    values: list[float],
    width: int,
    unit: str,
    palette: Palette,
    colour: str,
    decimals: int = 1,
) -> str:
    if not values:
        return f" {label:<10} {' ' * width}  unavailable"
    graph, low, high = sparkline(values, width)
    return (
        f" {label:<10} {palette.apply(colour, graph)}  "
        f"{low:.{decimals}f}…{high:.{decimals}f} {unit}"
    )


def render(
    reading: Reading,
    device: DeviceInfo,
    health: ConnectionHealth,
    args: argparse.Namespace,
    palette: Palette,
    error: str | None,
    history: deque[tuple[float, Reading]],
    started_at: float,
) -> str:
    columns = shutil.get_terminal_size(fallback=(100, 30)).columns
    chart_width = max(12, min(42, columns - 47))
    history_width = max(12, min(48, columns - 37))
    line = "─" * max(30, min(columns - 1, 96))
    timestamp = datetime.now().strftime("%H:%M:%S")
    now = time.time()
    history_readings = [item for _, item in history]
    battery_colour = "1;32" if reading.battery_status == "Discharging" else "1;34"
    grid_colour = "1;36" if reading.grid_status == "Exporting" else "1;33"
    status_is_bad = reading.inverter_status_code >= 0x1000 and reading.inverter_status_code != 0x1004
    status_text = (
        palette.bad(reading.inverter_status)
        if status_is_bad
        else palette.good(reading.inverter_status)
    )
    rows = [
        f"{palette.title('SOLIS LIVE')}  {palette.dim(f'{args.host}:{args.port}  slave {args.slave}')}  {palette.dim(timestamp)}",
        f" {palette.dim(device.display())}",
        f" Status         {status_text}  {palette.dim(f'(0x{reading.inverter_status_code:04X})')}",
    ]
    if reading.alarms:
        alarm_text = " · ".join(alarm.display() for alarm in reading.alarms)
        has_fault = any(alarm.severity == "fault" for alarm in reading.alarms)
        banner = palette.bad if has_fault else palette.warn
        label = "ALARMS" if has_fault else "WARNINGS"
        rows.append(
            f" {banner(label)}{' ' * (14 - len(label))}"
            f"{banner(alarm_text[: max(20, columns - 18)])}"
        )
    rows.extend(
        [
            line,
            f" Grid voltage   {reading.voltage:6.1f} V   {bar(reading.voltage, 260, chart_width, palette, '1;36')}",
            f" Inverter temp  {reading.inverter_temperature_c:6.1f} °C  {bar(reading.inverter_temperature_c, 100, chart_width, palette, '1;33')}",
            f" Battery SoC    {reading.state_of_charge:6d} %   {bar(reading.state_of_charge, 100, chart_width, palette, '1;32')}",
            line,
        ]
    )
    if args.pv and reading.pv_kw is not None:
        rows.append(
            f" PV generation  {reading.pv_kw:6.2f} kW  {bar(reading.pv_kw, args.inverter_max_kw, chart_width, palette, '1;32')}  today {reading.pv_today_kwh or 0:.1f} kWh"
        )
    rows.extend(
        [
            f" House load     {reading.house_load_kw:6.2f} kW  {bar(reading.house_load_kw, args.inverter_max_kw, chart_width, palette, '1;35')}",
            f" Battery        {reading.battery_kw:6.2f} kW  {bar(reading.battery_kw, args.inverter_max_kw, chart_width, palette, battery_colour)} {palette.good(reading.battery_status) if reading.battery_status != 'Idle' else palette.dim('Idle')}",
            f" Grid           {abs(reading.grid_kw):6.2f} kW  {bar(reading.grid_kw, args.grid_max_kw, chart_width, palette, grid_colour)} {palette.apply(grid_colour, reading.grid_status) if reading.grid_status != 'Idle' else palette.dim('Idle')}",
            line,
            f" {palette.title('HISTORY')}  {palette.dim(f'{history_window_label(history, started_at, now)} · 6h maximum')}",
            history_row("Voltage", [item.voltage for item in history_readings], history_width, "V", palette, "1;36"),
            history_row("Inv temp", [item.inverter_temperature_c for item in history_readings], history_width, "°C", palette, "1;33"),
        ]
    )
    if args.pv:
        rows.append(
            history_row(
                "PV",
                [item.pv_kw for item in history_readings if item.pv_kw is not None],
                history_width,
                "kW",
                palette,
                "1;32",
                2,
            )
        )
    rows.extend(
        [
            history_row("House load", [item.house_load_kw for item in history_readings], history_width, "kW", palette, "1;35", 2),
            history_row("Battery", [battery_flow(item) for item in history_readings], history_width, "kW", palette, "1;34", 2),
            history_row("Grid", [item.grid_kw for item in history_readings], history_width, "kW", palette, "1;33", 2),
            line,
        ]
    )
    age = now - health.last_success_at if health.last_success_at is not None else 0
    health_text = (
        f"Connection OK · last sample {age:.1f}s ago · {health.latency_ms:.0f} ms · "
        f"failures {health.total_failures} ({health.consecutive_failures} consecutive) · "
        f"reconnects {health.reconnects}"
    )
    rows.append(palette.good(f" {health_text}") if not error else palette.warn(f" {health_text}"))
    recording = []
    if args.csv:
        recording.append(f"CSV {args.csv}")
    if args.jsonl:
        recording.append(f"JSONL {args.jsonl}")
    footer = (
        f"Bars: inverter {args.inverter_max_kw:g} kW · grid {args.grid_max_kw:g} kW · "
        f"fast {args.interval:g}s · slow {args.slow_interval:g}s"
    )
    if recording:
        footer += " · recording " + ", ".join(recording)
    rows.append(palette.dim(f" {footer}. Ctrl-C to quit."))
    if error:
        rows.append(palette.warn(f" Last poll failed: {error}"))
    return "\n".join(rows)


def print_once(reading: Reading, device: DeviceInfo, health: ConnectionHealth) -> None:
    print(f"model_code={device.model_code}")
    print(f"dsp_version={device.dsp_version}")
    print(f"hmi_version={device.hmi_version}")
    print(f"protocol_version={device.protocol_version}")
    print(f"inverter_status={reading.inverter_status}")
    print(f"inverter_status_code=0x{reading.inverter_status_code:04X}")
    print(f"alarms={'; '.join(alarm.display() for alarm in reading.alarms)}")
    print(f"grid_voltage_v={reading.voltage:.1f}")
    print(f"inverter_temperature_c={reading.inverter_temperature_c:.1f}")
    print(f"battery_soc_percent={reading.state_of_charge}")
    print(f"house_load_kw={reading.house_load_kw:.2f}")
    print(f"battery_status={reading.battery_status}")
    print(f"battery_kw={reading.battery_kw:.2f}")
    print(f"grid_status={reading.grid_status}")
    print(f"grid_kw={reading.grid_kw:.2f}")
    if reading.pv_kw is not None:
        print(f"pv_kw={reading.pv_kw:.2f}")
        print(f"pv_today_kwh={reading.pv_today_kwh:.1f}")
    print(f"poll_latency_ms={health.latency_ms:.1f}")


def stream_payload(
    reading: Reading,
    device: DeviceInfo,
    health: ConnectionHealth,
    error: str | None,
    timestamp: datetime,
) -> dict[str, Any]:
    """Return the versioned JSON contract consumed by the menu-bar app."""
    sampled_at = timestamp.isoformat(timespec="milliseconds")
    age = None
    if health.last_success_at is not None:
        age = max(0.0, timestamp.timestamp() - health.last_success_at)
    return {
        "schema_version": 1,
        "timestamp": sampled_at,
        "device": {
            "model_code": device.model_code,
            "dsp_version": device.dsp_version,
            "hmi_version": device.hmi_version,
            "protocol_version": device.protocol_version,
            "type_definition": device.type_definition,
            "profile_validated": device.profile_validated,
        },
        "reading": {
            "grid_voltage_v": reading.voltage,
            "inverter_temperature_c": reading.inverter_temperature_c,
            "inverter_status_code": reading.inverter_status_code,
            "inverter_status": reading.inverter_status,
            "battery_soc_percent": reading.state_of_charge,
            "house_load_kw": reading.house_load_kw,
            "battery_kw": reading.battery_kw,
            "battery_flow_kw": battery_flow(reading),
            "battery_status": reading.battery_status,
            "grid_kw": reading.grid_kw,
            "grid_status": reading.grid_status,
            "pv_kw": reading.pv_kw,
            "pv_today_kwh": reading.pv_today_kwh,
            "alarms": [
                {
                    "code": alarm.code,
                    "message": alarm.message,
                    "severity": alarm.severity,
                }
                for alarm in reading.alarms
            ],
        },
        "health": {
            "last_sample_age_s": round(age, 3) if age is not None else None,
            "latency_ms": round(health.latency_ms, 1),
            "successful_polls": health.successful_polls,
            "total_failures": health.total_failures,
            "consecutive_failures": health.consecutive_failures,
            "reconnects": health.reconnects,
        },
        "error": error,
    }


def print_stream_json(
    reading: Reading,
    device: DeviceInfo,
    health: ConnectionHealth,
    error: str | None,
) -> None:
    payload = stream_payload(
        reading,
        device,
        health,
        error,
        datetime.now().astimezone(),
    )
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    parser.add_argument("--host", required=True, help="inverter data-logger IP address (required)")
    parser.add_argument("--port", type=int, default=502, help="Modbus TCP port (default: 502)")
    parser.add_argument("--slave", type=int, default=1, help="Modbus slave/unit ID (default: 1)")
    parser.add_argument("--interval", type=float, default=0.5, help="fast poll interval in seconds (default: 0.5)")
    parser.add_argument("--slow-interval", type=float, default=10, help="temperature/status poll interval in seconds (default: 10)")
    parser.add_argument("--timeout", type=float, default=3, help="Modbus timeout in seconds (default: 3)")
    parser.add_argument("--inverter-max-kw", type=float, default=10, help="inverter/PV bar full scale (default: 10)")
    parser.add_argument("--grid-max-kw", type=float, default=23, help="grid bar full scale (default: 23)")
    parser.add_argument("--pv", action="store_true", help="enable PV power, daily energy and history (default: off)")
    parser.add_argument("--csv", type=Path, help="append readings to CSV and restore its last six hours")
    parser.add_argument("--jsonl", type=Path, help="append readings to JSONL and restore its last six hours")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--once", action="store_true", help="print one plain-text reading and exit")
    output.add_argument(
        "--stream-json",
        action="store_true",
        help="write one JSON object per sample for integrations",
    )
    parser.add_argument("--no-colour", action="store_true", help="disable ANSI colours")
    args = parser.parse_args()
    try:
        ipaddress.ip_address(args.host)
    except ValueError:
        parser.error("--host must be a valid inverter data-logger IP address")
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    if not 0 <= args.slave <= 255:
        parser.error("--slave must be between 0 and 255")
    positive = (args.interval, args.slow_interval, args.timeout, args.inverter_max_kw, args.grid_max_kw)
    if any(value <= 0 for value in positive):
        parser.error("poll intervals, timeout and bar maximums must be greater than zero")
    return args


def main() -> int:
    args = parse_args()
    dashboard = sys.stdout.isatty() and not args.once and not args.stream_json
    palette = Palette(dashboard and not args.no_colour)
    client = SolisClient(args.host, args.port, args.slave, args.timeout)
    recorder: Recorder | None = None
    last_reading: Reading | None = None
    slow_metrics: SlowMetrics | None = None
    last_slow_poll = 0.0
    last_error: str | None = None
    health = ConnectionHealth()
    started_at = time.time()
    history: deque[tuple[float, Reading]] = deque()

    try:
        recorder = Recorder(args.csv, args.jsonl)
        history = recorder.load_history(started_at)
        client.connect()
        device = client.identify()
        if dashboard:
            print("\033[?25l", end="")
        while True:
            poll_started = time.perf_counter()
            try:
                now_monotonic = time.monotonic()
                if slow_metrics is None or now_monotonic - last_slow_poll >= args.slow_interval:
                    slow_metrics = client.poll_slow(args.pv)
                    last_slow_poll = now_monotonic
                last_reading = client.poll_fast(slow_metrics, args.pv)
                sampled_at = time.time()
                health.succeeded(sampled_at, (time.perf_counter() - poll_started) * 1000)
                last_error = None
                history.append((sampled_at, last_reading))
                cutoff = sampled_at - HISTORY_SECONDS
                while history and history[0][0] < cutoff:
                    history.popleft()
                recorder.write(last_reading, health, datetime.now().astimezone())
            except (UnsupportedProfileError, RecordingError):
                raise
            except (ConnectionError, OSError, client.modbus_exception) as exc:
                last_error = str(exc)
                health.failed()
                slow_metrics = None
                client.close()
                try:
                    client.connect()
                    health.reconnects += 1
                except (ConnectionError, OSError, client.modbus_exception) as reconnect_error:
                    last_error = f"{last_error}; reconnect failed: {reconnect_error}"

            if last_reading is None:
                fail(f"unable to obtain an inverter reading: {last_error}", 1)
            if args.once:
                print_once(last_reading, device, health)
                return 0
            if args.stream_json:
                print_stream_json(last_reading, device, health, last_error)
                time.sleep(args.interval)
                continue
            output = render(
                last_reading, device, health, args, palette, last_error, history, started_at
            )
            print(("\033[H\033[2J" if dashboard else "") + output, flush=True)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 130
    except UnsupportedProfileError as exc:
        fail(str(exc), 1)
    except RecordingError as exc:
        fail(str(exc), 1)
    except (ConnectionError, OSError, client.modbus_exception) as exc:
        fail(f"cannot connect to {args.host}:{args.port}: {exc}", 1)
    finally:
        client.close()
        if recorder:
            recorder.close()
        if dashboard:
            print("\033[?25h", end="", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
