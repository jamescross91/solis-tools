# Hypervolt EV charger integration

How `solis_poll.py` reads from and controls a Hypervolt home charger, and how
dynamic voltage control chooses whether to back off home battery charging or
the car when the grid needs protecting.

## Why this looks different from the Solis integration

Every other integration point in this project is Modbus TCP to a device on
the local network. A Hypervolt charger has no local protocol at all: no
Modbus, no OCPP, nothing to connect to on the LAN. Telemetry and control both
go through Hypervolt's own cloud service, reachable only over the internet.

`hypervolt_client.py` is a from-scratch reimplementation of that cloud wire
protocol, reverse-engineered from the openly published Home Assistant
integration (<https://github.com/gndean/home-assistant-hypervolt-charger>),
which Hypervolt is aware of and has not objected to. Hypervolt does not
document or support this interface. A failure here should be read as "the
vendor changed something on their side", not "the network blipped" — treat
protocol errors from this module with more suspicion than a Modbus timeout.

The protocol itself is:

- **Auth**: Keycloak OAuth2. A one-time password grant produces a refresh
  token; every subsequent run exchanges that refresh token for an access
  token, and rotates the refresh token in the process.
- **Control**: a WebSocket at `/ws/charger/{id}/sync`, request/response
  shaped like JSON-RPC. It carries `max_current` in milliamps (6000–32000)
  and a `release` command to stop drawing current without disconnecting.
- **Telemetry**: a second, separate WebSocket at
  `/ws/charger/{id}/session/in-progress`. This one is push-only — the server
  sends state whenever it changes, there is nothing to request. It carries
  `charging`, `true_milli_amps` and `watt_hours`.

Because the standard library has no WebSocket client and PyModbus is the
project's only permitted runtime dependency, `hypervolt_client.py` hand-rolls
the RFC 6455 handshake and frame format itself, in the same spirit as
`fake_inverter.py`'s hand-rolled Modbus framing. It implements exactly what
this client needs — masked client-to-server text frames, single-frame
server-to-client text frames, ping/pong, a clean close — and nothing more.

## Module boundaries

| Module | Role |
| --- | --- |
| `hypervolt_client.py` | The cloud transport. Auth, the two WebSockets, `HypervoltState`, `HypervoltClient`. Knows nothing about voltage control. |
| `voltage_control.py` | Stays transport-independent. Holds the EV configuration fields, the tightened voltage bounds, and `allocate_import_step`, the pure function that decides how much of a change in import headroom falls on the battery versus the car. Knows nothing about WebSockets. |
| `solis_poll.py` | The integration layer: `HypervoltCurrentActuator` (mirrors the existing `ImportLimitActuator`/`ExportLimitActuator` pattern), the CLI flags, the independent Hypervolt poll/reconnect loop, and the wiring that calls `allocate_import_step` with live values and turns its output into a command. |
| `fake_hypervolt.py` | A stdlib test double serving the token endpoint, the discovery endpoint and both WebSockets on one port, in the same spirit as `fake_inverter.py`. |
| `hypervolt_login.py` | A one-time interactive script that performs the password grant and writes a refresh-token credentials file. Installed as the `hypervolt-login` command; not imported by anything else. |

This split exists so the delicate, already-tested Solis-only controller
state machine in `voltage_control.py` did not need to be rewritten. The EV
priority arbitration is a small post-processing step layered on top of its
existing decision, not a fork of it.

## Reading from the charger

`HypervoltClient.poll()` drains both sockets without blocking and updates
`HypervoltClient.state`, a `HypervoltState` with `charging`,
`true_milli_amps`, `watt_hours` and the monotonic time of the last update.

`HypervoltState.is_charging(now, stale_age_s)` is deliberately fail-closed:
if the last update is older than `stale_age_s` (`--ev-stale-age`, default
30 s) or no update has ever arrived, it reports "not charging". A stale or
absent cloud connection must never be interpreted as "the car is definitely
charging" — that would let a lost cloud link silently disable the tighter
voltage protection charging is supposed to get. It is safe for it to mean
"the car might be charging and we can't tell", which is what "not charging"
plus a visible `last_error` in the stream conveys.

## Controlling the charger

`HypervoltCurrentActuator.command_ma()` sends `set_max_current_ma` through
the sync socket, subject to the same `--minimum-write-interval` write-rate
guard the Solis actuators use (with an `emergency` bypass, also matching
the Solis actuators). It does not wait for and does not assume the command
took effect: the next read of `HypervoltClient.state` is the only source of
truth for whether the car is actually drawing less current, exactly as the
Solis import actuator treats its own commanded value as a request, not a
confirmed outcome, until the next readback.

If sending the command raises `HypervoltError` — the cloud link is down, the
socket dropped, auth failed — `VoltageControlRuntime._allocate_ev_priority`
catches it and falls back to the controller's original, unmodified decision.
Home battery charging is never left unregulated because the EV side of the
system is unreachable; voltage safety must not depend on the Hypervolt cloud
API being up.

## Priority arbitration

Import regulation already knows how to reduce or restore a single lever: the
Solis import limit. Adding a second, independent lever (car current) needs a
policy for which one moves first. That policy is `--ev-priority`, one of:

| Priority | Behaviour |
| --- | --- |
| `battery` (default) | The car is the flexible resource. It absorbs cuts first and is restored first; the battery only moves once the car is already at its floor or ceiling. |
| `ev` | The battery is the flexible resource, symmetrically. |
| `balanced` | The change is split 50/50, with any amount one side cannot absorb spilling over to the other. |

This is implemented as `voltage_control.allocate_import_step`, a pure
function taking the wattage change the existing controller already decided
on (`delta_w`, positive for a reduction, negative for a restore) plus each
side's current value and its min/max bounds, and returning
`(new_battery_w, new_ev_w)`. It is deliberately symmetric — the same
function handles both cuts and restores for both priorities — because a
scheme that cuts the EV first but restores the battery first would leave the
car starved of current it should have gotten back.

`VoltageControlRuntime._allocate_ev_priority` is the only place amps and
watts meet: it reads the controller's decision in watts, calls
`allocate_import_step`, converts the returned EV wattage back to milliamps
using the live meter voltage, and commands that. The reallocation only runs
when the car is confirmed charging, `--hypervolt-enable` is set, and the
controller's decision this cycle was an import mode reduction, restore or
emergency action — a holding decision is left alone.

## Tighter voltage limits while the car is charging

Hypervolt's own charger enforces tighter voltage protection than most
household loads need. `--ev-minimum-voltage` / `--ev-maximum-voltage`
(defaults 216.0 V / 253.0 V) express that. Whenever `ev_charging` is true,
`DynamicVoltageController._voltage_bounds()` intersects the general bounds
with the EV bounds — whichever is tighter always wins — and every emergency
check, target and deadband calculation in `_evaluate_import` and
`_evaluate_export` uses that intersected pair for the rest of the cycle. The
general bounds are never widened by the EV values; they can only be
narrowed.

Detecting that the car is charging is also, on its own, enough to activate
import regulation, alongside the pre-existing battery-charging signal — a
car plugged in and drawing current is exactly the situation the tighter
bounds exist for, even on a day when the home battery is already full. This
is gated on `--hypervolt-enable` for defense in depth: a `GridTelemetrySample`
manufactured with `ev_charging=True` by a test, or a future caller, cannot
activate EV-aware behaviour unless the feature was actually turned on.

## Configuration surface

| Flag | Default | Meaning |
| --- | --- | --- |
| `--hypervolt-enable` | Off | Master opt-in; requires `--dynamic-voltage-control` |
| `--hypervolt-credentials` | `<state dir>/hypervolt.json` | Refresh-token file written by `hypervolt-login` |
| `--ev-priority` | `battery` | `battery`, `ev` or `balanced` — see above |
| `--ev-minimum-voltage` / `--ev-maximum-voltage` | 216.0 / 253.0 V | Tightened bounds applied only while the car is charging |
| `--ev-minimum-current` / `--ev-maximum-current` | 6.0 / 32.0 A | Clamp for the commanded charging current |
| `--ev-stale-age` | 30 s | Telemetry older than this reads as "not charging" |
| `--hypervolt-timeout` | 10 s | HTTP/WebSocket connect timeout |

`--ev-minimum-current` / `--ev-maximum-current` should stay within Hypervolt's
own hardware range (`HYPERVOLT_MIN_CURRENT_A` / `HYPERVOLT_MAX_CURRENT_A`,
6–32 A) — validated by `DynamicVoltageConfiguration.validate()`. There is no
`--dynamic-export-control`-style validation gate for the Hypervolt side: the
existing export write-evidence gate is unrelated and unaffected. Hypervolt
writes are current-trim commands to a charger the user already owns and has
authenticated to, not the kind of arbitrary-register write CLAUDE.md's
closed-whitelist rule concerns itself with.

## Credentials

Only a refresh token is ever persisted, at 0600 permissions, never the
account password. `hypervolt_login.py` (installed as the `hypervolt-login`
command) is the one place the password is used: it performs the password
grant once, discovers the charger ID, and writes the resulting
`HypervoltCredentials` to the credentials file. `HypervoltClient` rotates and
re-saves the refresh token on every run after that; the password itself is
never stored or logged anywhere.

When run from a terminal with `--email` omitted, it prompts interactively
(`getpass`, never a CLI argument, so the password never lands in shell
history or a process listing). The menu-bar app's own "Sign in to Hypervolt"
form drives the same command as a subprocess instead of a terminal prompt: it
always passes `--email` as an argument (not a secret) and writes the password
followed by a newline to the subprocess's stdin pipe, which `getpass.getpass`
falls back to reading directly whenever stdin is not a terminal. Either way
the password exists only for the lifetime of that one short-lived process,
and `HypervoltLoginRunner.swift` never stores it — only the transient
`SecureField` state in `DashboardView`, cleared immediately after the
subprocess is launched.

## Testing without a real charger or cloud account

`fake_hypervolt.py` serves the token endpoint, the discovery endpoint and
both WebSockets on one local port, with a `set_charging()` test driver method
and a `refuse_tokens` flag for auth-failure scenarios. `HypervoltClient`
accepts host/port/TLS overrides specifically so tests can redirect it there
instead of `kc.prod.hypervolt.co.uk` / `api.hypervolt.co.uk`; `solis_poll.py`
exposes the same overrides as hidden CLI flags for the end-to-end tests.

`test_hypervolt_client.py` covers the client and credentials handling in
isolation. `test_voltage_control.py`'s `AllocateImportStepTests` and
`EvActivationAndBoundsTests` cover the arbitration function and the tightened
bounds as pure logic, with no network involved. `test_end_to_end.py`'s
`HypervoltPriorityTests` runs the real CLI as a subprocess against both a
`fake_inverter.py` and a `fake_hypervolt.py`, and proves both priorities end
to end: `battery` priority cuts the car and leaves the inverter's holding
register untouched; `ev` priority cuts the inverter and leaves the car's
commanded current untouched.

`hypervolt_login.py` carries the same hidden `--token-host`/`--token-port`/
`--api-host`/`--api-port`/`--insecure` overrides as `solis_poll.py`, so
`test_hypervolt_login.py` can run the real `hypervolt-login` command as a
subprocess against `fake_hypervolt.py`, piping a password to its stdin
exactly as `HypervoltLoginRunner.swift` does, and pin its exit codes and the
exact stdout/stderr text the Swift side parses.

## Menu-bar sign-in UI

The dashboard's Hypervolt settings section has its own "Sign in to
Hypervolt" form (email field, `SecureField` for the password, a status line
reading the credentials file's `charger_id` to show whether an account is
already signed in). `HypervoltLoginRunner` drives `hypervolt-login` as a
one-shot subprocess exactly as described in "Credentials" above, and reports
success or failure by parsing that process's stdout/stderr rather than
duplicating any auth logic in Swift. `ExecutableLocator` is shared with
`MonitorStore`'s own `solis-poll` lookup, since Homebrew installs both
commands into the same `bin` directory.

## Stream contract

`voltage_control.ev_priority`, `voltage_control.ev_charging` and
`voltage_control.hypervolt_actuator` are new, purely additive fields inside
the existing `voltage_control` object — see `docs/stream-contract.md` for the
full shape. No `schema_version` bump was needed: none of the changes rename,
remove or change the meaning of an existing field.
