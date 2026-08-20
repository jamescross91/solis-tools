#!/usr/bin/env python3
"""A Modbus TCP stand-in for a Solis hybrid inverter.

Everything past ``SolisClient._registers`` — the poll cadence, the reconnect
path, recording, history restore, the JSON stream the menu-bar app consumes —
needed a real inverter on the LAN to exercise, so none of it was covered. This
answers read-input-registers (function code 4) from a register bank, which is
the only function the monitor ever sends.

Run it to drive the real monitor with no hardware:

    python3 fake_inverter.py --port 5020
    ./solis_poll.py --host 127.0.0.1 --port 5020 --pv

It can also inject the faults that are otherwise impossible to reproduce:
``--corrupt-after`` starts returning a nonsense battery-power register, and
``--drop-after`` closes the connection, so the reconnect path can be tested.
"""

from __future__ import annotations

import argparse
import socket
import struct
import threading

READ_INPUT_REGISTERS = 4
ILLEGAL_DATA_ADDRESS = 0x02
MBAP_HEADER = 7


def hybrid_bank() -> dict[int, int]:
    """A plausible ESINV-33000 bank, keyed by raw (zero-based) PDU address."""
    bank = {
        33000: 12695,  # model code
        33001: 26,  # DSP version
        33002: 46,  # HMI version
        33003: 1,  # protocol version
        35000: 0x2001,  # hybrid family in the high byte
        33035: 125,  # PV today, 12.5 kWh
        33057: 0,
        33058: 2500,  # PV power, 2.5 kW
        33073: 2427,  # grid voltage, 242.7 V
        33093: 524,  # inverter temperature, 52.4 C
        33095: 3,  # status: Generating
        33135: 1,  # battery discharging
        33139: 78,  # state of charge, 78 %
        33147: 2320,  # house load, 2.32 kW
        33149: 0,
        33150: 2500,  # battery power, 2.50 kW
        33263: 0xFFFF,
        33264: 0xFE0C,  # grid power, -0.5 kW (importing)
    }
    for address in range(33116, 33121):  # inverter fault words
        bank[address] = 0
    bank[33145] = bank[33146] = 0  # BMS fault words
    return bank


class FakeInverter:
    """Serves one register bank to any number of Modbus TCP clients."""

    def __init__(
        self,
        bank: dict[int, int] | None = None,
        port: int = 0,
        corrupt_after: int | None = None,
        corrupt_until: int | None = None,
        drop_after: int | None = None,
    ):
        self.bank = dict(hybrid_bank() if bank is None else bank)
        self.corrupt_after = corrupt_after
        self.corrupt_until = corrupt_until
        self.drop_after = drop_after
        self.reads = 0
        self.stopped = False
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._socket.bind(("127.0.0.1", port))
        self._socket.listen(8)
        self.port: int = self._socket.getsockname()[1]

    def __enter__(self) -> FakeInverter:
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
        self._socket.close()

    def _accept_loop(self) -> None:
        while not self.stopped:
            try:
                connection, _ = self._socket.accept()
            except OSError:
                return
            threading.Thread(target=self._serve_client, args=(connection,), daemon=True).start()

    def _serve_client(self, connection: socket.socket) -> None:
        with connection:
            while not self.stopped:
                header = self._receive(connection, MBAP_HEADER)
                if header is None:
                    return
                _transaction, _protocol, length, unit = struct.unpack(">HHHB", header)
                body = self._receive(connection, length - 1)
                if body is None:
                    return
                function = body[0]
                if function != READ_INPUT_REGISTERS:
                    connection.sendall(
                        header[:4]
                        + struct.pack(">HBBB", 3, unit, function | 0x80, ILLEGAL_DATA_ADDRESS)
                    )
                    continue
                address, quantity = struct.unpack(">HH", body[1:5])
                self.reads += 1
                if self.drop_after is not None and self.reads > self.drop_after:
                    return
                registers = [self._value(address + offset) for offset in range(quantity)]
                payload = struct.pack(">BB", READ_INPUT_REGISTERS, quantity * 2) + b"".join(
                    struct.pack(">H", register) for register in registers
                )
                connection.sendall(
                    header[:4] + struct.pack(">HB", len(payload) + 1, unit) + payload
                )

    def _value(self, address: int) -> int:
        # 33149 is the high word of battery power; 0xFFFF decodes to ~4.29e6 kW,
        # which is exactly the kind of frame that used to end the process.
        if address == 33149 and self._corrupting():
            return 0xFFFF
        return self.bank.get(address, 0) & 0xFFFF

    def _corrupting(self) -> bool:
        if self.corrupt_until is not None:
            return self.reads <= self.corrupt_until
        return self.corrupt_after is not None and self.reads > self.corrupt_after

    @staticmethod
    def _receive(connection: socket.socket, count: int) -> bytes | None:
        buffer = b""
        while len(buffer) < count:
            chunk = connection.recv(count - len(buffer))
            if not chunk:
                return None
            buffer += chunk
        return buffer


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=5020, help="listen port (default: 5020)")
    parser.add_argument(
        "--corrupt-after",
        type=int,
        help="return a nonsense battery-power register after this many reads",
    )
    parser.add_argument(
        "--corrupt-until",
        type=int,
        help="return a nonsense battery-power register for the first N reads only",
    )
    parser.add_argument("--drop-after", type=int, help="close the connection after this many reads")
    parser.add_argument(
        "--string-inverter",
        action="store_true",
        help="report the string-inverter family in register 35000",
    )
    arguments = parser.parse_args()

    bank = hybrid_bank()
    if arguments.string_inverter:
        bank[35000] = 0x1001
    inverter = FakeInverter(
        bank,
        port=arguments.port,
        corrupt_after=arguments.corrupt_after,
        corrupt_until=arguments.corrupt_until,
        drop_after=arguments.drop_after,
    )
    inverter.serve()
    print(f"fake Solis inverter listening on 127.0.0.1:{inverter.port}", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        inverter.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
