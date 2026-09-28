# Intelligent Octopus charge windows

How `solis_poll.py` reads Intelligent Octopus's planned charges and holds the
supply voltage inside the EV charger's limits for each one.

## The failure this exists for

A Hypervolt's PEN-fault protection stops charging when line-neutral voltage
stays above 253 V or below 207 V for five seconds, and waits for 30 s back
inside that range before it resumes. With solar exporting, the supply at the
meter can sit well above 253 V for hours while the general controller band
(`--maximum-voltage`, 258 V) is still satisfied.

The Hypervolt integration already narrows the band to the charger's limits,
but only once the charger reports charging. A charger that trips before it
starts never reports charging, so the narrower band never arrives, and the car
misses the whole Intelligent Octopus slot. The charge plan is known in advance,
so the band can be narrowed before the car tries to draw current.

## What it does

`--octopus-enable` (requires `--dynamic-voltage-control`) reads the plan
Octopus publishes for the enrolled car or charger. From `--octopus-lead-time`
(300 s) before each planned charge until its end, every sample carries
`ev_charge_window=True`, and `DynamicVoltageController._voltage_bounds` narrows
the band to the intersection of the general limits and `--ev-minimum-voltage` /
`--ev-maximum-voltage` (207 / 253 V). Every emergency check, target and
deadband uses that band, exactly as for a confirmed charging car.

With the defaults this moves the export ceiling from 258 V to 253 V, so export
regulation works to 251.5 V and treats 253 V as an emergency. The floor stays
at 215 V, because the general floor is already tighter than the charger's.

Nothing is stored or written to change the limits. The band is recomputed for
every sample, so the first sample after a window is held to the general band
again, and export regulation raises its allowance back towards the maximum and
restores its baseline when export stops, as it always has. A crash inside a
window leaves nothing to undo.

Export regulation is the only lever that can lower a high supply voltage, so
the high side needs `--dynamic-export-control` and its installation
validation. Without them the window is still shown and the band still
narrows, but there is nothing to regulate with.

## The Octopus API

`octopus_client.py` speaks the Kraken GraphQL API at
`https://api.octopus.energy/v1/graphql/`, the same operations the Home Assistant
Octopus Energy integration uses:

- `obtainKrakenToken(input: {APIKey})` exchanges the account's API key for a JWT,
  reused until five minutes before its `exp` claim and renewed once if a query is
  rejected.
- `viewer { accounts { number } }` and `devices(accountNumber)` find the account
  and the enrolled device, once, in `octopus-login`.
- `flexPlannedDispatches(deviceId)` returns the plan: `start`, `end` and `type`
  for each dispatch. `plannedDispatches`, the older query, was withdrawn.

Octopus is read and never written. This client has no operation that starts,
stops, bumps or reschedules a charge.

The request blocks for up to `--octopus-timeout`. The Modbus loop cannot wait
that long (telemetry goes stale after 6 s), so `OctopusScheduleMonitor` makes
it on a daemon thread every `--octopus-interval` (180 s, at least 60 because
Octopus rate-limits per account) and publishes an immutable `OctopusSchedule`.
The control loop reads the latest snapshot and never touches the network.

The account number, device ID and API key are checked against strict patterns
before they are embedded in a query, which is what keeps a hostile credentials
file from changing the query.

## What it costs to run

The poller runs unattended for weeks, and wakeups rather than CPU decide its
power draw (see "Polling cadence" in `docs/architecture.md`), so this adds as
few as it can:

- **Network**: one HTTPS request per `--octopus-interval`, and a token renewal
  about once an hour that shares that request's connection. The TLS context is
  built once per run, not per connection. The connection is closed after each
  refresh rather than kept for the next one, which the server would have
  dropped by then, so a refresh never starts with a failed request.
- **Per sample**: the control loop compares the monitor's snapshot by
  identity and the clock against the next window boundary. The plan is
  rescanned only when a refresh publishes a new snapshot or a lead-in or end
  passes. The snapshot is replaced whole, so reading it takes no lock.
- **Cadence**: a charge window does not hold the fast poll. An overnight slot
  is hours of import with nothing to regulate, and the idle cadence applies
  exactly as it would without Octopus. Export during a window leaves the idle
  states on its first sample, and a sample at or over the ceiling is already
  an emergency.
- **Stream**: `octopus_schedule` is sent in the first sample and then only
  when it changes, as the event log is, rather than on every sample. The app
  carries it forward and parses the window times once, at decode. The settings
  form reads the credentials file when it opens or its path changes, not on
  every redraw.

## When the plan is wrong or unavailable

Every rule below can only keep the band narrow for longer, never relax it
early. A narrow band costs some export; a relaxed one can cost the charge.

| Situation | Behaviour |
| --- | --- |
| Refresh fails (network, HTTP 5xx, bad JSON) | Keep the last good windows, which are absolute times; report `last_error`; retry after 60 s, 120 s... up to the interval |
| A started charge disappears from the plan | Kept until its planned end. Octopus can drop or shorten a running dispatch while the car is still charging |
| A charge is withdrawn during its lead-in | Honoured: it had not started |
| Consecutive half-hour slots | Merged, so the band is not relaxed for an instant at each boundary |
| A dispatch time without a UTC offset | The whole response is rejected; a naive time is an hour out either side of a clock change |
| API key refused at startup | The run stops with `cannot read the Octopus charge schedule`, like any configuration mistake |
| API key refused later | Reported in `last_error`; the known plan is kept |

The Hypervolt signal still works alongside this. A car that charges outside a
planned slot, or runs past its end, gets the narrow band from Hypervolt's own
charging report when `--hypervolt-enable` is on.

## Credentials

A personal API key is the only long-lived credential Octopus issues; the
refresh token `obtainKrakenToken` can return expires within days. So the key is
what is stored, with the account number and device ID, at 0600 permissions in
`--octopus-credentials` (default `octopus.json` in the state directory). It is
never logged, streamed or passed on a command line.

`octopus_login.py` (installed as `octopus-login`) reads the key with
`getpass`, which also accepts it on a piped stdin, checks it against Octopus,
discovers the account and device, reads the plan once to prove the whole path
works, and only then writes the file. With more than one account or device it
lists them and asks for `--account` or `--device` (the optional fields in the
app's form). Re-running it replaces the file, which is how to recover from a
regenerated key.

## Stream and menu bar

`voltage_control.octopus_schedule` carries the plan, the active and next
window, the last successful refresh and the last error;
`ev_voltage_limits_active` and `effective_minimum_voltage_v` /
`effective_maximum_voltage_v` say which band the last sample was held to. Both
are additive, so `schema_version` is unchanged; see `docs/stream-contract.md`.
Window start and end produce events in the control log.

The menu-bar app shows an Intelligent Octopus card, outside the collapsed
diagnostics: when the next slot is, the band it narrows from and to, when the
lead-in starts, and when the band reverts. During a slot it shows the band
being held, what it replaces and when it returns. The band values come from
`octopus_schedule` itself, so the card can describe a charge before it starts. Its settings have an enable toggle, a credentials path and a
sign-in form: an API-key field, optional account-number and device-ID fields
for accounts with more than one, and a link to the Octopus API-access page.
`OctopusLoginRunner.swift` runs `octopus-login` as a subprocess with the key
on its stdin, exactly as `HypervoltLoginRunner.swift` does for Hypervolt, and
reports the command's own success or `error: ` line. The key field is cleared
as soon as the command starts; the app never stores the key.

## Testing without an Octopus account

`fake_octopus.py` answers the four operations above on a local port, with
drivers for planning a charge relative to now, refusing the key, expiring
tokens and failing with HTTP 503. `test_octopus_client.py` covers the client,
credentials, the monitor's retention rules and `octopus-login` as a subprocess.
`test_voltage_control.py`'s `OctopusChargeWindowTests` proves the band as pure
logic. `test_end_to_end.py`'s `OctopusChargeWindowTests` runs the real CLI
against `fake_inverter.py` and `fake_octopus.py` at 254 V with 4 kW of export:
with a charge planned, the first write is an emergency export cut; with the
charge two hours away, the band is unchanged and the charge is reported as next.
