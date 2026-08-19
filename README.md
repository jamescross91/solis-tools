# solis-tools

`solis_poll.py` is a lightweight, nmon-inspired, real-time terminal monitor for a Solis inverter exposed over Modbus TCP. It uses a persistent native Python Modbus connection, avoiding the process and connection overhead of the original `mbpoll` shell loop.

It only reads input registers; it never writes to the inverter.

I built this because I got fed up with the Solis Cloud 5 minute + lag when monitoring the inverter.

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

The defaults are port `502`, slave ID `1`, a 0.5-second refresh, a three-second Modbus timeout, 10 kW inverter capacity, and 23 kW grid capacity:

```sh
./solis_poll.py --host 192.168.1.57 --port 502 --slave 1 --interval 1
```

Use `--once` for a plain-text, script-friendly health check:

```sh
./solis_poll.py --host 192.168.1.57 --once --timeout 5
```

Set the bar-chart capacities to match the installation:

```sh
./solis_poll.py --host 192.168.1.57 --inverter-max-kw 10 --grid-max-kw 23
```

Other useful display options:

```sh
./solis_poll.py --host 192.168.1.57 --no-colour  # disable ANSI colours
```

In an interactive terminal, the monitor redraws a coloured dashboard with voltage and state-of-charge gauges, plus power bars for house load, battery and grid flow. Press `Ctrl-C` to stop.

## History graphs

The dashboard keeps successful readings in memory from launch and renders a rolling line graph for every metric:

- grid voltage
- inverter temperature
- house load
- battery flow
- grid flow

History is capped at six hours. Once the monitor has run longer than that, the oldest readings are discarded automatically. The graphs downsample the retained readings to the available terminal width, while the labels show the observed minimum and maximum.

Battery history is positive when discharging and negative when charging. Grid history is positive when exporting and negative when importing. History is not written to disk and starts afresh each time the tool launches. Battery SoC remains visible as a live gauge but is deliberately excluded from history.

## Register assumptions

The monitor reads the same **input registers** as the working `mbpoll -t 3` shell script. Those references are 1-based, while PyModbus addresses are zero-based; the client performs that conversion before each read.

| Reference(s) | Value used |
| --- | --- |
| `33074` | Grid voltage, scaled by 10 |
| `33094` | Inverter temperature, signed and scaled by 10 (raw PDU address `33093`) |
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
