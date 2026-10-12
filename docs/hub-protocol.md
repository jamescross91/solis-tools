# The hub protocol

What `solis-hub` serves to clients. The hub is a second consumer of the stream
described in [stream-contract.md](stream-contract.md) and forwards its
envelopes unchanged inside a small wrapper (it parses each line only to cache
it, and forwards the poller's original bytes). This document covers the wrapper,
the HTTP API and how both change. Operating the hub is in [hub.md](hub.md).

Produced by `solis_hub.py`; consumed by `SolisHubKit`.

## Versioning

`hub_protocol_version` is `1` and is independent of the stream's
`schema_version` (which stays `2`). Envelopes inside messages are the stream
contract, byte for byte: the hub does not parse them into anything else, and a
`sample` message is built by placing the poller's own line inside the wrapper.

The rules mirror the stream contract:

- Adding a message type or a field is safe. Clients ignore message types and
  fields they do not know.
- Renaming or removing a field, changing a meaning, or removing a message type
  needs `hub_protocol_version` bumped, and `hello` lets a client refuse a
  version it does not know.
- Every message is one JSON text frame with a `type` field. Field names are
  snake_case, decoded in Swift with `.convertFromSnakeCase`.

## Connecting

One port serves everything: WebSocket at `/v1/stream` and HTTP under `/v1/`.
Every request except `GET /v1/healthz` needs `Authorization: Bearer <token>`.
Behind Cloudflare Access a client also sends `CF-Access-Client-Id` and
`CF-Access-Client-Secret` on every request to the remote (HTTPS) endpoint; the
hub ignores those headers, and the bearer token is still required, so neither
layer failing open is enough. SolisHubKit does not send the Cloudflare pair to a
LAN endpoint, which does not pass through Cloudflare and is plain `ws://`, and it
refuses HTTP redirects on both transports so no header follows a redirect.

| Status | Meaning |
| --- | --- |
| 401 | Missing or wrong token. No detail in the body |
| 429 | Ten failed attempts in a minute from this source address. `Retry-After: 60` |
| 426 | Not a WebSocket upgrade, or `Sec-WebSocket-Version` is missing or not 13 |
| 404 | Unknown path. No detail |
| 400 | Malformed request or WebSocket key, or a bad `since`, `resolution` or `kind` |
| 405 | Anything but GET (`Allow: GET`) |
| 431 | Request head over 16 KiB |
| 503 | `max_clients` reached, the hub is stopping, or the history database could not be read |

Authentication is checked before the path, so an unauthenticated request to any
path other than `/v1/healthz` gets 401 (or 429), never 404 or 426.

The source address for rate limiting is the TCP peer, except that
`CF-Connecting-IP` is used when the peer is loopback (that is `cloudflared`).
Responses carry `Cache-Control: no-store`.

## WebSocket subset

The server implements the part of RFC 6455 it needs and nothing else.

- Standard handshake with `Sec-WebSocket-Accept`. No extensions, no
  subprotocol negotiation, no compression.
- Client frames must be masked; an unmasked frame closes with 1002.
- Text, close, ping and pong only. A binary frame closes with 1003.
- Fragmented messages are refused, and so is any message over 64 KiB, both
  with 1009. Server frames are never fragmented.
- Invalid UTF-8 closes with 1007. Ten invalid messages close with 1008.
- The server pings every 20 s and drops a client with no pong within 40 s.
- Before a policy close the server sends an `error` message.

## Server to client

| Type | When | Fields |
| --- | --- | --- |
| `hello` | Once, straight after the upgrade | `hub_protocol_version`, `hub_version`, `stream_schema_version`, `hub_id` (stable UUID), `poller` |
| `snapshot` | After `hello`, after a lag overflow, after a poller restart | `envelope`: the merged envelope, or null before the first sample; `poller` |
| `sample` | Every envelope from the poller | `envelope`, forwarded unchanged |
| `poller_status` | On any supervisor state change | `state`, `since`, `restarts`, `last_exit_code`, `next_attempt_at` |
| `pong` | In answer to `ping` | `nonce`, echoed |
| `error` | Before a policy close | `code`, `message` |

`poller` (in `hello` and `snapshot`) has the same fields as `poller_status`
without `type`. `state` is one of `starting`, `running`, `backoff`, `stopping`
or `restoration_pending`. `since` and `next_attempt_at` are ISO 8601 strings or
null.

### The merged envelope

The stream sends some fields only in the first sample of a run or when they
change: `voltage_control.configuration`, `voltage_control.recent_events` and
`voltage_control.octopus_schedule`. The hub keeps the latest value of each (and
the latest `device`), and
a snapshot is the latest envelope with those filled in, so a client joining
late sees a complete picture. `sample` messages are not merged: they carry
exactly what the poller sent, and a client keeps the last list it received just
as the menu bar does in Direct mode.

The cache is emptied when the poller restarts, so a snapshot after a restart
has a null envelope until the first new sample.

### Slow clients

Each client has a queue of 16 outbound messages. If it fills, the hub clears
that client's queue and queues one fresh snapshot instead. Snapshots carry the
merged state, so a phone on mobile data never loses an event list, and it never
holds up another client.

## Client to server

| Type | Fields | Effect |
| --- | --- | --- |
| `attention` | `on` (bool) | Feeds attention aggregation |
| `ping` | `nonce` (string up to 128 characters, number, or absent) | Answered with `pong` |

Any other type is ignored and logged once per connection. There are
deliberately no control or settings commands. Clients default to attention off
on connect.

### Attention

The hub writes `attention on` to the poller when the first client with
attention on connects or turns it on, and `attention off` when the last such
client turns it off or disconnects. With no clients attention is off. Only
changes are written, and a freshly started poller (which starts with attention
on) is brought back in line at once. Nothing a client sends is passed to the
poller beyond those two fixed strings.

## HTTP endpoints

| Method and path | Returns |
| --- | --- |
| `GET /v1/healthz` | `{"ok": true}` and nothing else. No token. For Cloudflare and systemd checks |
| `GET /v1/status` | `hub_version`, `hub_protocol_version`, `hub_id`, `poller`, `clients`, `envelope_age_s` (null before the first sample) |
| `GET /v1/history/samples?since=ISO&resolution=native\|compact` | Array of stored history entries after `since`; gzip when the client accepts it |
| `GET /v1/history/control?since=ISO&kind=minutes\|events` | Rows from the poller's `voltage-history.sqlite3`, opened read-only, as objects keyed by column name |
| `GET /v1/settings` | The settings state, below |
| `PUT /v1/settings` | Replaces the controller settings with the body; answers with the settings state and `restarted` |
| `POST /v1/credentials/hypervolt` | Signs the hub in to Hypervolt with `{"email", "password"}`; answers with the settings state, `message` and `restarted` |
| `POST /v1/credentials/octopus` | Signs the hub in to Octopus with `{"api_key", "account"?, "device"?}`; answers likewise |

A history entry holds `timestamp`, `reading` (without `alarms`), `cadence` and a
`voltage_control` object with only: `state`, `action`, `mode`,
`raw_voltage_v`, `filtered_voltage_v`, `desired_limit_w`, `emergency`, the
effective voltage band (`effective_minimum_voltage_v`,
`effective_maximum_voltage_v`, `ev_voltage_limits_active`), `ev_charging`, and
for each of `import_actuator` and `export_actuator` its `last_commanded_raw`
and `resolution_w`. Events, configuration, diagnostics and alarm arrays are not
stored per sample.

`native` keeps every sample for `history_native_minutes`; `compact` keeps one
per 30 s for `history_compact_hours`. Both are emptied by a hub restart, like
the menu bar's own history. `kind=minutes` rows are the `voltage_minutes` table
(`minute` is epoch seconds), `kind=events` rows are `voltage_events`. A missing
database is an empty array. `since` is optional; an unparseable value is 400. Use `Z` or encode a `+` offset
as `%2B`; a bare `+` that arrives as a space is read as a plus. Control history
is capped at the newest 50,000 rows.

### Settings and sign-in

These change what the poller runs, so they take the same token as everything
else, and only one is applied at a time (a second gets 409). Bodies are JSON with
a `Content-Length` of at most 16 KiB; a chunked body gets 411. A refused request
answers 400 (or 409, 411, 413, 500) with `{"error": "..."}`, a short reason fit to
show to a person.

The settings state is:

```json
{
  "settings": {
    "dynamic_voltage_enabled": true, "dynamic_import_enabled": true,
    "dynamic_export_enabled": false, "minimum_voltage": 212.0,
    "maximum_voltage": 259.0, "voltage_safety_margin": 1.5,
    "voltage_deadband": 1.0, "maximum_import_kw": 23.0,
    "import_headroom_kw": 1.5, "export_headroom_kw": 1.0,
    "maximum_export_kw": 10.0, "site_export_permission_kw": 10.0,
    "increase_step_w": 500, "reduction_step_w": 500,
    "near_limit_reduction_w": 1000, "emergency_reduction_w": 3000,
    "control_settle_time": 10.0, "control_activation_delay": 10.0,
    "control_deactivation_delay": 10.0, "import_activation_kw": 1.0,
    "export_activation_kw": 0.5, "minimum_write_interval": 60.0,
    "hypervolt_enabled": true, "ev_priority": "ev", "octopus_enabled": true
  },
  "source": "app",
  "export_control_validated": true,
  "hypervolt": {"signed_in": true, "charger_id": "HV-123"},
  "octopus": {"signed_in": true, "account_number": "A-1234ABCD", "device_id": "..."}
}
```

`settings` is what the poller runs: from `control-settings.json` when `source`
is `"app"`, otherwise read from `hub.json`'s `poller_args`. A `PUT` body is a
complete `settings` object: every key is required and unknown keys are refused,
so a client written against an older list cannot leave a newer setting unset.
Values are checked by `solis-poll`'s own validation; export regulation also needs
the installation-validation record. `restarted` is true when the change differs
from what was running and the poller is being restarted with it.

`hypervolt` and `octopus` never carry a password, key or token. Secrets in a
sign-in body must not contain control characters, and are passed to the login
command on stdin only.

Adding a field to the settings is a protocol change in both directions: a
client sends every key, so a hub refuses a document from a client that lacks the
new one. Bump `hub_protocol_version`, or give the hub a default for the missing
key, when that happens.

## Not in the protocol

Any write to the inverter, Hypervolt or Octopus from a client, the logger
address, polling intervals, file paths and any poller option outside the
settings above. The hub changes control only by restarting its own poller.
