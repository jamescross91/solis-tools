# The always-on hub (optional)

`solis-hub` is a small daemon for a Raspberry Pi. It owns the single Modbus
session and the voltage controller, and shares the poller's live stream with
any number of viewers: the Mac's menu-bar app, an iPhone, or both at once.

You gain three things:

- Voltage control keeps running with the Mac asleep or away.
- The Mac and the phone see the same real-time data, including every voltage
  control movement.
- Both work from outside the home through a Cloudflare Tunnel, with no VPN. See
  [hub-remote-access.md](hub-remote-access.md).

Without a Pi nothing changes. The menu-bar app's default is Direct mode, which
runs `solis-poll` itself exactly as before. The hub runs on Linux and macOS
(POSIX only; it uses signal handlers Windows does not have).

```text
   inverter / logger
          ▲  Modbus TCP, one session
          │
     solis-poll  <── attention on / off ──┐
          │ one JSON object per sample    │
          ▼                               │
     solis-hub  (supervisor, state cache, fan-out)
          │  ws:// on the LAN, wss:// through Cloudflare Tunnel
     ┌────┴─────┐
  menu bar     iPhone  ...
  (Hub mode)
```

## What the hub is not

The hub never speaks Modbus. It runs `solis-poll --stream-json` as a subprocess
and forwards what it prints, and the only thing it ever writes to the poller is
the line `attention on` or `attention off`. The register whitelist, the
controller and `schema_version` are unchanged. See
[hub-protocol.md](hub-protocol.md) for the wire format.

A client holding the token can change the controller settings and sign the hub
in to Hypervolt and Octopus (see "Changing settings from an app" below). The
hub applies those by restarting its poller with new arguments, never by talking
to the inverter itself. That makes the token an administrator credential: anyone
who has it can turn control off or change its limits, so keep it as you would a
password, and give a viewer you do not trust nothing at all.

## The single-controller rule

At any moment exactly one `solis-poll` process holds the logger's Modbus
session and runs voltage control: the Mac's (Direct mode) or the Pi's (the
hub). The logger supports one session, so a second poller would compete with
the first for it and two controllers could fight over the import limit.

- Hub mode in the menu bar never starts a local poller, even when the hub is
  unreachable. It shows the last data with its age and keeps retrying.
- There is no automatic fallback from Hub to Direct. Switching to Direct is an
  explicit action behind a confirmation that the hub service is stopped.
- In Direct mode, if the app finds a `_solis-hub._tcp` service on the local
  network it shows a banner and does not start or restart its poller until you
  choose "Switch to Hub" or "Ignore for this hub ID".

## Configuration

The hub reads one JSON file (JSON because Python 3.10 has no `tomllib`). The
default is `hub.json` in the state directory; `deploy/pi/install.sh` places it
at `/etc/solis-tools/hub.json`. Unknown keys are an error, not ignored.
`deploy/pi/hub.json.example` is a starting point:

```json
{
  "listen_host": "0.0.0.0",
  "listen_port": 8765,
  "state_dir": null,
  "token_file": null,
  "poller_args": ["--host", "192.168.1.57", "--interval", "2", "--idle-interval", "10", "--meter-voltage", "--pv"],
  "history_native_minutes": 30,
  "history_compact_hours": 24,
  "max_clients": 32,
  "ntfy": null
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `listen_host`, `listen_port` | `0.0.0.0`, `8765` | Where the hub listens (port 0 to 65535). After changing `listen_port`, re-run `deploy/pi/install.sh` (it renders the Bonjour advertisement from this file) and update the Cloudflare route |
| `state_dir` | platform state directory | Where the token and hub ID live, and where `/v1/history/control` looks for `voltage-history.sqlite3`. `null` resolves like `solis-poll` does. The hub does not pass it to the poller, which keeps its own state directory (`$XDG_STATE_HOME/solis-tools`; the unit sets these to the same place). If you set `state_dir` elsewhere, also pass `--control-journal` and `--voltage-history-db` in `poller_args`. On a Pi leave it `null`: `install.sh` and the unit assume `/var/lib/solis-tools`. Relative `token_file` paths resolve against it |
| `token_file` | `hub-token` in the state directory | Bearer token file. Must not be readable by group or others |
| `poller_args` | required | Passed to `solis-poll` verbatim. Control flags go here |
| `history_native_minutes` | `30` | Native-resolution in-memory history (1 to 1440) |
| `history_compact_hours` | `24` | One sample per 30 s kept for this long (1 to 336) |
| `max_clients` | `32` | WebSocket connection cap (1 to 1024) |
| `ntfy` | `null` | Push notifications, below |

`poller_args` rules: the hub adds `--stream-json` itself and refuses arguments
containing it or `--once` (including abbreviations argparse would accept), and
refuses `--csv` or `--jsonl` paths outside the state directory. Put the control
flags from the README ("Dynamic Grid Voltage Control") here, for example
`--dynamic-voltage-control`. Include `--idle-interval` so the poller slows
down while no viewer has the popover open; the hub tells it `attention off`
whenever no client is looking. Include `--meter-voltage` (the menu bar always
passes it) or the supply voltage readout and charts are empty. Hypervolt and
Octopus are enabled by `--hypervolt-enable`, `--octopus-enable` and
`--ev-priority` in `poller_args`; running `hypervolt-login` or `octopus-login`
only stores the credentials.

`solis-hub check --config PATH` validates the file, the token permissions and
that `solis-poll` can be found, then exits. The hub looks for `solis-poll` beside
its own executable, then on `PATH`; set `SOLIS_POLL_PATH` to use a specific
binary. It runs the poller with the state directory as its working directory, so
a relative `--csv` or `--jsonl` path lands inside it.

### Changing settings from an app

The menu bar's Hub settings show the controller settings the hub is running and
let you edit them, and sign the hub in to Hypervolt and Octopus. The settings are
exactly those the menu bar edits in Direct mode: control on or off, import and
export regulation, the voltage band, headroom and limits, steps and delays, the
Hypervolt priority and the Octopus charge windows. The logger address, polling
intervals and file paths are not among them; those stay in `hub.json`.

- **Where they are kept.** The first time an app applies settings, the hub writes
  them to `control-settings.json` in its state directory (0600; `/etc` is
  read-only to the service). From then on they replace the matching control
  flags in `poller_args`, and the rest of `poller_args` is used as before.
  `solis-hub check` says when that file is in use. Delete it and restart the hub
  to go back to `hub.json` alone.
- **How a change is applied.** The hub checks the whole set with `solis-poll`'s
  own validation and refuses anything the poller would refuse at start, with the
  poller's reason. Export regulation is refused unless the installation-validation
  record for the logger is in the state directory. An accepted change that differs
  from what is running restarts the poller: it gets SIGTERM, restores the
  inverter's limits and exits, and only then does the new one start. Control
  pauses for those few seconds. The app asks before it applies anything.
- **Signing in.** The Hypervolt password or Octopus API key goes to the hub once,
  in the request body, and the hub hands it on stdin to `hypervolt-login` or
  `octopus-login`, the same commands you would run on the Pi. Only what those
  commands save is kept: a Hypervolt refresh token, or the Octopus key with its
  account and device. The answer to the app says which account or charger is
  signed in, never the key or token. If that feature is on, the poller restarts
  to use the new credentials.
- **Over the LAN** the request is plain HTTP, like the token itself; through the
  Cloudflare Tunnel it is HTTPS.

### Push notifications (ntfy)

Off unless `ntfy` is set:

```json
"ntfy": {"url": "https://ntfy.sh", "topic": "k3x9q2m7v4r8w1z5", "token_file": null, "min_interval_s": 300}
```

`topic` is 1 to 64 letters, digits, `_` or `-`; generate a long random one. Use an
`https://` URL (with `http://` an access token would travel in clear text).
`token_file` is an optional file holding an ntfy access token, sent as a bearer
token and read once at start. `min_interval_s` limits each event type.

| Event | Trigger | Priority |
| --- | --- | --- |
| Voltage emergency | A sample with `voltage_control.emergency` true, once per episode | High |
| Poller down | The poller is not running for more than 2 minutes | High |
| Inverter unreachable | `health.consecutive_failures` above zero for more than 2 minutes | High |
| Restoration pending | The hub is stopping and the poller has not yet restored the baseline | High |
| Recovered | Any of the above clears | Default |

Messages are posted from a background thread, rate-limited per event type, and
carry no secrets or addresses. A slow or failing ntfy server can never delay
the stream. The topic is the only secret in the URL, so treat it like a
password. APNs push to the iOS app is deferred.

## Installing on a Raspberry Pi

Target: Raspberry Pi 4 or 5 on Raspberry Pi OS Lite 64-bit (Bookworm or later,
which ships Python 3.11; the hub needs Python 3.10 or newer), on wired Ethernet, booting from SSD or NVMe rather than an SD card. If the
inverter has a backup (EPS) output, put the Pi on a backed-up circuit so it
keeps running in an outage.

```sh
git clone https://github.com/jamescross91/solis-tools.git
cd solis-tools
sudo deploy/pi/install.sh
```

The script is idempotent and is also the upgrade path (`git pull`, then run it
again). It creates the `solis` system user, a virtualenv at `/opt/solis-tools`
installed from the checkout, the state directory `/var/lib/solis-tools` (0700),
`/etc/solis-tools/hub.json` (from the example, if absent), a token (if absent,
printed once), the systemd unit and the Avahi advertisement. On a first run it
stops before starting the service so you can set the logger's address in
`poller_args`; then `sudo systemctl start solis-hub`.

The installer checks the Python version first, before it changes anything. On an
image whose Python is older than 3.10 it stops with a message and leaves the
system untouched, and a virtualenv left by an earlier failed run is replaced
rather than reused. `sudo deploy/pi/install.sh --check-python` shows which
interpreter it would use without installing anything, and `--python PATH` (or
`SOLIS_PYTHON`) chooses one explicitly.

### Older images, such as Bullseye

Raspberry Pi OS 11 (Bullseye) ships Python 3.9, which cannot install pymodbus
3.10 (pip reports `No matching distribution found for pymodbus`). The simplest
fix is to flash Bookworm or later. To keep the image, build Python 3.11
alongside the system one; it does not replace `python3`. Expect 15 to 40
minutes on a Pi 4:

```sh
sudo apt-get update
sudo apt-get install -y build-essential libssl-dev zlib1g-dev libbz2-dev \
  libreadline-dev libsqlite3-dev libffi-dev liblzma-dev
cd /tmp
curl -fsSLO https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz
tar -xzf Python-3.11.9.tgz
cd Python-3.11.9
./configure --prefix=/opt/python-3.11
make -j"$(nproc)"
sudo make altinstall
/opt/python-3.11/bin/python3.11 -c 'import ssl, sqlite3, bz2, lzma, ctypes, venv; print("ok")'
```

The last line must print `ok`: a Python built without `libssl-dev` cannot
install anything from PyPI. Then run the installer from the checkout as usual.
It finds `/opt/python-3.11/bin/python3.11` by itself, because the system
`python3` is too old:

```sh
cd ~/solis-tools
sudo deploy/pi/install.sh
```

The unit runs as `solis`, sets `XDG_STATE_HOME=/var/lib` so the existing state
directory logic resolves to `/var/lib/solis-tools`, and hardens the process
(`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
write access to the state directory only). `KillMode=mixed` with
`TimeoutStopSec=30` means systemd signals only the hub, which forwards SIGTERM
to the poller and waits up to 20 s for it to restore the inverter's baseline.

Check it:

```sh
systemctl status solis-hub
curl -s http://localhost:8765/v1/healthz
curl -s -H "Authorization: Bearer $(sudo -u solis env XDG_STATE_HOME=/var/lib /opt/solis-tools/bin/solis-hub token show --config /etc/solis-tools/hub.json)" \
  http://localhost:8765/v1/status
```

Credentials for Hypervolt and Octopus stay on the Pi. Sign in from the menu
bar's Hub settings, or run the existing commands there as the `solis` user:

```sh
sudo -u solis env XDG_STATE_HOME=/var/lib /opt/solis-tools/bin/hypervolt-login \
  --credentials /var/lib/solis-tools/hypervolt.json
sudo -u solis env XDG_STATE_HOME=/var/lib /opt/solis-tools/bin/octopus-login \
  --credentials /var/lib/solis-tools/octopus.json
```

`--credentials` is the path of the file to write. The password or API key is
typed at the prompt that follows, never on the command line, where it would be
saved in your shell history. Both commands refuse an argument that looks like a
key or token. The hub reads only the non-secret account fields of those files,
to show who is signed in, and never returns or logs a key or token.

### Without a Pi: `make hub-demo`

```sh
make hub-demo
```

starts `fake_inverter.py`, writes a throwaway hub config with dynamic voltage
control enabled against a fake that is importing at 230 V, and prints the token.
In the menu bar choose Hub mode, LAN URL `ws://127.0.0.1:8765` and that token.
Nothing touches your real state directory. Press Ctrl-C once: the fake inverter
and the hub both receive it, so the poller may log a failed restoration
because the fake went away first. That is an artefact of the demo, not of the
hub.

### Manual check of `install.sh`

The installer cannot run in CI, so before a release run it twice on a fresh
Raspberry Pi OS Lite image. The second run must print no token, leave
`hub.json` and the token untouched, and restart the service. (Re-running before
you have edited `poller_args` starts the hub against the placeholder address
192.168.1.57, where it simply backs off.) Then confirm `systemctl is-active solis-hub`, `avahi-browse -rt
_solis-hub._tcp` from another machine, and `systemctl stop solis-hub` returning
within a few seconds, with the poller's `voltage control shutdown` lines in the
journal, when control is on.

### Local network prompt on the Mac

The menu-bar app now declares `_solis-hub._tcp` in its Info.plist so it can find
a hub by Bonjour, and allows local-network `ws://` connections (the LAN path is
plain WebSocket; remote is always `wss://`). A found hub is only used once you
choose it in the hub settings. macOS may ask once for local network access the first time the
upgraded app starts. In Hub mode the token and any Cloudflare Access credentials
are kept in the Keychain; after a Homebrew upgrade the ad-hoc-signed app can
trigger a Keychain "Always Allow" prompt again. In Direct mode nothing reads the
Keychain at launch.

## Tokens

```sh
solis-hub token new  --config /etc/solis-tools/hub.json   # replaces the token and prints it once
solis-hub token show --config /etc/solis-tools/hub.json   # prints the existing token
```

The token is 32 random bytes, URL-safe encoded, in a 0600 file inside a 0700
state directory. The hub refuses to start if the file is readable by group or
others. Creating a new token invalidates every client. The hub reads the file once at
start, so run `systemctl restart solis-hub` after rotating. Clients keep the token and any Cloudflare Access
credentials in the Keychain, never in preferences or logs. Failed
authentication is rate-limited to 10 per minute per source address, then 429.

The home network is not trusted. Local connections are plain `ws://` protected
by the token only; anyone who can read traffic on your LAN could read the token
on first use. Prefer the tunnel (`wss://`) for any network you do not control.

## Migrating control from the Mac to the Pi

Control state is scoped to the logger endpoint, so the order matters.

1. On the Mac, disable control and choose Save and connect, then quit the
   menu-bar app normally. Confirm the baseline was restored and the journal is
   clean (no pending restoration message).
2. Decide how the Pi gets the control settings the Mac app was using. Either
   write the flags (thresholds, margins, steps, `--dynamic-import-control`, the
   EV and Octopus flags) into `poller_args`, or leave control flags out of
   `poller_args`, so the hub starts with control off, and set them from the menu
   bar's Hub settings in step 6. The hub never reads the Mac's own settings.
3. Copy the export-control validation record, if one exists, to the Pi's state
   directory. It is `export-control-validation-<24 hex>.json` in the Mac's
   `~/Library/Application Support/SolisTools`; put it in `/var/lib/solis-tools`
   with `sudo install -m 0600 -o solis -g solis FILE /var/lib/solis-tools/`. It
   is evidence about the logger endpoint, not the Mac, so it stays valid only if
   the Pi's `poller_args` use the identical host spelling, port and unit.
   Otherwise revalidate on the Pi.
4. Do not copy the control journal. A clean shutdown makes it unnecessary, and
   an unclean one must be recovered on the Mac first, following the README
   precautions.
5. If you use Hypervolt or Octopus, sign the hub in: from the menu bar's Hub
   settings once it is connected, or with `hypervolt-login` and `octopus-login`
   on the Pi, using the commands and `--credentials` paths shown under
   "Installing on a Raspberry Pi". Do this before turning those features on, or
   the poller stops at start for want of credentials.
6. Start `solis-hub`, confirm `/v1/status` shows the poller `running`, then
   switch the menu bar to Hub mode and check, or set, the control settings in
   its Hub settings.

Reverse migration is the same steps the other way. The hub-detected guard stops
the Mac reconnecting directly while the hub is still advertising, so stop the
hub service first (`sudo systemctl stop solis-hub`) and let it finish
restoring.

## Stopping and restoration

On SIGTERM or SIGINT the hub stops accepting new clients, forwards SIGTERM to
the poller and keeps draining its output, so connected viewers see the
restoration. It waits up to 20 s. If the poller has not exited it reports
`restoration_pending` (and sends a notification if ntfy is set) and leaves the
poller running rather than killing it: a hard kill is exactly how a reduced
limit gets left behind. A second SIGTERM or SIGINT, at any point,
makes the hub exit without waiting further. Under systemd, `KillMode=mixed`
still sends SIGKILL to what remains when `TimeoutStopSec=30` ends, so "leaves it
running" holds for the hub's own behaviour and outside systemd; the 30 s is why
the unit allows 10 s above the hub's wait. Recover from an unclean stop on the Pi the way the README
describes for an unclean shutdown on a Mac. If the hub itself is killed or
crashes, the poller notices its closed pipe at its next write and restores the
inverter on its own, which is why the unit waits 5 s before restarting it.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Hub exits at start naming the token file | Token missing, too short or group/world readable. `chmod 600` it or run `token new` |
| `/v1/status` shows `backoff` repeatedly | The poller is failing to start. Read `journalctl -u solis-hub`; the poller's own message is there. Typically the logger address or another client holds the one Modbus session |
| 401 from every request | Wrong token. Look for trailing whitespace in what you pasted |
| 429 | Ten failed attempts in a minute from that address. Wait a minute |
| Menu bar shows "Hub is up, inverter poller restarting" | The supervisor is in backoff. Backoff doubles from 1 s to 60 s and resets after 5 healthy minutes |
| Mac app shows a hub-detected banner | A hub advertises on the LAN. Switch to Hub, or ignore that hub ID if it is not yours to use |
| Remote works, LAN does not (or the reverse) | Check which endpoint answered under "Test connection" in the app's hub settings |
