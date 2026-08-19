#!/usr/bin/env python3
"""Live terminal monitor for a Solis inverter's Modbus TCP interface."""

from __future__ import annotations

import argparse
import ipaddress
import logging
import shutil
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from typing import NoReturn


MIN_PYTHON = (3, 9)


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
    # The monitor supplies its own concise connection errors.
    logging.getLogger("pymodbus").setLevel(logging.CRITICAL)
    return ModbusTcpClient, ModbusException


@dataclass(frozen=True)
class Reading:
    voltage: float
    state_of_charge: int
    house_load_kw: float
    battery_kw: float
    battery_status: str
    grid_kw: float
    grid_status: str


class SolisClient:
    """Persistent native Modbus TCP client and Solis register decoder."""

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
        # mbpoll uses 1-based references by default. PyModbus sends zero-based
        # PDU addresses, so subtract one to preserve the original script's reads.
        address = reference - 1
        response = self.client.read_input_registers(
            address=address,
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
    def _signed_32(high: int, low: int) -> int:
        value = (high << 16) | low
        return value - 0x1_0000_0000 if value >= 0x8000_0000 else value

    def poll(self) -> Reading:
        # These input-register references match the former mbpoll commands.
        voltage = self._registers(33074, 1)[0] / 10
        status = self._registers(33136, 16)
        grid = self._registers(33264, 2)

        state_of_charge = status[4]  # Register 33140.
        house_load_kw = status[12] / 1000  # Register 33148.
        battery_kw = ((status[14] << 16) | status[15]) / 1000  # 33150-33151.
        grid_kw = self._signed_32(grid[0], grid[1]) / 1000

        battery_status = (
            "Idle"
            if battery_kw < 0.05
            else "Discharging"
            if status[0] == 1
            else "Charging"
        )
        grid_status = (
            "Exporting" if grid_kw > 0.05 else "Importing" if grid_kw < -0.05 else "Idle"
        )

        return Reading(
            voltage=voltage,
            state_of_charge=state_of_charge,
            house_load_kw=house_load_kw,
            battery_kw=battery_kw,
            battery_status=battery_status,
            grid_kw=grid_kw,
            grid_status=grid_status,
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
    text = "█" * filled + "·" * (width - filled)
    return palette.apply(colour, text)


def render(reading: Reading, args: argparse.Namespace, palette: Palette, error: str | None) -> str:
    columns = shutil.get_terminal_size(fallback=(90, 24)).columns
    chart_width = max(12, min(42, columns - 47))
    scale = args.power_scale
    line = "─" * max(30, min(columns - 1, 88))
    timestamp = datetime.now().strftime("%H:%M:%S")

    battery_colour = "1;32" if reading.battery_status == "Discharging" else "1;34"
    grid_colour = "1;36" if reading.grid_status == "Exporting" else "1;33"
    grid_display = abs(reading.grid_kw)

    rows = [
        f"{palette.title('SOLIS LIVE')}  {palette.dim(f'{args.host}:{args.port}  slave {args.slave}')}  {palette.dim(timestamp)}",
        line,
        f" Grid voltage   {reading.voltage:6.1f} V   {bar(reading.voltage, 260, chart_width, palette, '1;36')}",
        f" Battery SoC    {reading.state_of_charge:6d} %   {bar(reading.state_of_charge, 100, chart_width, palette, '1;32')}",
        line,
        f" House load     {reading.house_load_kw:6.2f} kW  {bar(reading.house_load_kw, scale, chart_width, palette, '1;35')}",
        f" Battery        {reading.battery_kw:6.2f} kW  {bar(reading.battery_kw, scale, chart_width, palette, battery_colour)} {palette.good(reading.battery_status) if reading.battery_status != 'Idle' else palette.dim('Idle')}",
        f" Grid           {grid_display:6.2f} kW  {bar(grid_display, scale, chart_width, palette, grid_colour)} {palette.apply(grid_colour, reading.grid_status) if reading.grid_status != 'Idle' else palette.dim('Idle')}",
        line,
        palette.dim(f"Power bars are 0–{scale:g} kW.  Refresh: {args.interval:g}s.  Ctrl-C to quit."),
    ]
    if error:
        rows.append(palette.warn(f" Last poll failed: {error}"))
    return "\n".join(rows)


def print_once(reading: Reading) -> None:
    """Machine-friendly single snapshot for scripts and diagnostics."""
    print(f"grid_voltage_v={reading.voltage:.1f}")
    print(f"battery_soc_percent={reading.state_of_charge}")
    print(f"house_load_kw={reading.house_load_kw:.2f}")
    print(f"battery_status={reading.battery_status}")
    print(f"battery_kw={reading.battery_kw:.2f}")
    print(f"grid_status={reading.grid_status}")
    print(f"grid_kw={reading.grid_kw:.2f}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--host",
        required=True,
        help="inverter data-logger IP address (required)",
    )
    parser.add_argument("--port", type=int, default=502, help="Modbus TCP port (default: 502)")
    parser.add_argument("--slave", type=int, default=1, help="Modbus slave/unit ID (default: 1)")
    parser.add_argument("--interval", type=float, default=0.5, help="seconds between polls (default: 0.5)")
    parser.add_argument(
        "--timeout",
        type=float,
        default=3,
        help="Modbus request timeout in seconds (default: 3)",
    )
    parser.add_argument("--power-scale", type=float, default=10, help="full-scale kW value for power bars")
    parser.add_argument("--once", action="store_true", help="print one plain-text reading and exit")
    parser.add_argument("--no-colour", action="store_true", help="disable ANSI colours")
    args = parser.parse_args()
    try:
        ipaddress.ip_address(args.host)
    except ValueError:
        parser.error("--host must be a valid inverter data-logger IP address")
    if args.port < 1 or args.port > 65535:
        parser.error("--port must be between 1 and 65535")
    if args.slave < 0 or args.slave > 255:
        parser.error("--slave must be between 0 and 255")
    if args.interval <= 0 or args.power_scale <= 0:
        parser.error("--interval and --power-scale must be greater than zero")
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    return args


def main() -> int:
    args = parse_args()
    dashboard = sys.stdout.isatty() and not args.once
    palette = Palette(dashboard and not args.no_colour)
    client = SolisClient(args.host, args.port, args.slave, args.timeout)
    last_reading: Reading | None = None
    last_error: str | None = None

    try:
        client.connect()
        if dashboard:
            print("\033[?25l", end="")  # Hide cursor while the screen redraws.
        while True:
            try:
                last_reading = client.poll()
                last_error = None
            except (ConnectionError, OSError, client.modbus_exception) as exc:
                last_error = str(exc)
                # Reconnect after a router or inverter restart without stopping the monitor.
                client.close()
                try:
                    client.connect()
                except (ConnectionError, OSError, client.modbus_exception) as reconnect_error:
                    last_error = f"{last_error}; reconnect failed: {reconnect_error}"

            if last_reading is None:
                fail(f"unable to obtain an inverter reading: {last_error}", 1)
            if args.once:
                print_once(last_reading)
                return 0
            if dashboard:
                print("\033[H\033[2J" + render(last_reading, args, palette, last_error), flush=True)
            else:
                print(render(last_reading, args, palette, last_error), flush=True)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 130
    except (ConnectionError, OSError, client.modbus_exception) as exc:
        fail(f"cannot connect to {args.host}:{args.port}: {exc}", 1)
    finally:
        client.close()
        if dashboard:
            print("\033[?25h", end="", flush=True)  # Always restore the cursor.


if __name__ == "__main__":
    raise SystemExit(main())
