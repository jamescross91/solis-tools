# solis-tools

`solis_poll.py` is a lightweight, nmon-inspired terminal monitor for a Solis inverter exposed over Modbus TCP. It uses a persistent native Python Modbus connection, avoiding the process and connection overhead of the original `mbpoll` shell loop.

It only reads input registers; it never writes to the inverter.

## Requirements

- Python 3.9 or later
- PyModbus 3.10–3.x
- Network access to the inverter/logger's Modbus TCP service

Install the Python dependency in a virtual environment:

```sh
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
```

The monitor checks that PyModbus is importable before connecting and exits with the install command if it is missing.

## Run

The inverter data-logger IP is deliberately mandatory:

```sh
./solis_poll.py --host 192.168.1.57
```

The defaults are port `502`, slave ID `1`, a 0.5-second refresh, and a three-second Modbus timeout:

```sh
./solis_poll.py --host 192.168.1.57 --port 502 --slave 1 --interval 1
```

Use `--once` for a plain-text, script-friendly health check:

```sh
./solis_poll.py --host 192.168.1.57 --once --timeout 5
```

Other useful display options:

```sh
./solis_poll.py --host 192.168.1.57 --power-scale 5  # full power bar = 5 kW
./solis_poll.py --host 192.168.1.57 --no-colour      # disable ANSI colours
```

In an interactive terminal, the monitor redraws a compact coloured dashboard with voltage and state-of-charge gauges, plus power bars for house load, battery and grid flow. Press `Ctrl-C` to stop.

## Register assumptions

The monitor reads the same **input registers** as the working `mbpoll -t 3` shell script. Those references are 1-based, while PyModbus addresses are zero-based; the client performs that conversion before each read.

| Reference(s) | Value used |
| --- | --- |
| `33074` | Grid voltage, scaled by 10 |
| `33136` | Battery operating state |
| `33140` | Battery state of charge (%) |
| `33148` | House load, scaled by 1000 |
| `33150–33151` | Battery power, unsigned 32-bit value scaled by 1000 |
| `33264–33265` | Grid power, signed 32-bit value scaled by 1000 |

Check these references against the inverter model and firmware documentation before relying on the display operationally.

## Troubleshooting

- **`pymodbus is not installed`** — activate the intended virtual environment and run `python3 -m pip install -r requirements.txt`.
- **No route from VS Code, but an external terminal works** — enable **Visual Studio Code** under **System Settings → Privacy & Security → Local Network**, then fully quit and reopen VS Code.
- **A poll fails** — the dashboard retains the last good reading and reports the failure. Check the logger IP, port, slave ID and Modbus configuration.
- **No colour or redraw** — use an interactive ANSI-capable terminal. Use `--once` for integration with other scripts.
