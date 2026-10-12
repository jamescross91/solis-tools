# The hub build spec

This is the specification the always-on hub (`solis-hub`, Hub mode and `SolisHubKit`) was built against, reproduced as written on 2026-10-02 so the reasoning behind the design stays with the code. It is a record of intent, not the current reference: [hub.md](hub.md), [hub-protocol.md](hub-protocol.md) and [hub-remote-access.md](hub-remote-access.md) describe what shipped. Where the implementation deliberately differs, the differences are listed in [Where the implementation differs](#where-the-implementation-differs) at the end.

---

## Purpose

Add an optional, always-on hub to solis-tools: a new `solis-hub` daemon that runs on a Raspberry Pi, owns the single Modbus session and the voltage controller, and fans the existing stream out to any number of clients over an authenticated WebSocket. The menu-bar app gains a Hub mode alongside today's Direct mode, which must keep working exactly as it does now. A new shared Swift package, SolisHubKit, gives the iOS energy monitor app the same live feed, including every voltage control movement.

The outcome: voltage control keeps running with the Mac asleep or away, the Mac and iPhone see the same real-time data, and both work from outside the home through a Cloudflare Tunnel with no VPN.

**For Claude Code:** read `CLAUDE.md`, `docs/architecture.md` and `docs/stream-contract.md` before writing anything. This spec defers to them on every existing convention. Deliver everything below in one branch and one pull request, with `make` and `make swift` green.

## Scope

This PR lands in `jamescross91/solis-tools` only. The iOS app adopts SolisHubKit in its own repository afterwards, against the contract in this spec.

**In this PR**

- `solis_hub.py` daemon, installed as `solis-hub`, wrapping the existing `solis-poll --stream-json` subprocess unchanged
- Hand-rolled, standard-library WebSocket server (RFC 6455 subset) and small HTTP API on the same port
- Bearer-token authentication, token tooling, optional Cloudflare Access headers on clients
- In-memory sample history on the hub, plus read-only endpoints over the existing control SQLite history
- Optional ntfy push notifications for control and health events
- Menu-bar Direct / Hub connection modes, Bonjour discovery, Keychain secrets, hub-detected guard
- `SolisHubKit` Swift package (macOS 13, iOS 17) shared by the menu bar and the iOS app
- Pi deployment assets: systemd unit, Avahi service file, install script, Cloudflare Tunnel template
- Tests, CI wiring, docs, CHANGELOG entry, Homebrew formula installing `solis-hub`

**Out of scope**

- Changing controller behaviour, register whitelist, safety rules or the stream schema version
- Remote changes to control settings or enabling/disabling control from a client (settings stay in the hub's config file)
- MQTT and Home Assistant integration (design leaves room; see Deferred)
- APNs push to the iOS app, iOS app UI work, cutting a release

## Current architecture and rules that bind this work

Today the menu-bar app spawns `solis-poll --stream-json` as a child process. The poller owns telemetry, typed control, the crash journal and orderly restoration over one Modbus TCP connection. It emits one versioned JSON envelope per poll on stdout; the app writes `attention on` / `attention off` to its stdin. The hub reuses exactly this boundary: it becomes a second consumer of the same contract, not a new controller.

Repo rules that apply unchanged (from `CLAUDE.md`):

- **PyModbus is the only runtime dependency.** The hub uses the standard library only: `asyncio`, `hashlib`, `base64`, `hmac`, `secrets`, `json`, `sqlite3`, `urllib`. The WebSocket server is hand-rolled, following the precedent of the hand-rolled client in `hypervolt_client.py`.
- **The write whitelist does not change.** The hub never speaks Modbus and exposes no write path of any kind.
- **The stream contract does not change.** The hub forwards envelopes byte-for-byte inside its own message wrapper; `schema_version` stays 2.
- **One Modbus session per logger.** The tested logger supports one active session, so nothing in this PR may open a second one. This drives the guards in the menu-bar section.
- **British spelling** in prose and identifiers; comments explain why, not what; version only in `solis_poll.VERSION`.
- Python 3.10 minimum still applies, so no `tomllib`. Config files are JSON.

## Target architecture

With the Pi in place, exactly one process talks to the inverter: `solis-poll`, supervised by `solis-hub`. Every app becomes a viewer of the hub's feed. Without the Pi, nothing changes: the menu bar runs `solis-poll` itself, as today.

*(Diagram: Target architecture with the optional Pi hub. See the "The hub (optional)" section of [architecture.md](architecture.md) for the diagram as built.)*

The hub forwards the poller's JSON stream and passes attention hints back to it; Cloudflare Tunnel carries the same WebSocket and HTTP traffic when away from home.

**The single-controller rule:** at any moment exactly one `solis-poll` process holds the Modbus session and runs voltage control, either the Mac's (Direct mode) or the Pi's (hub). No client ever opens a second session, and no client falls back automatically from one to the other.

## solis-hub daemon

New module `solis_hub.py`, console script `solis-hub` in `pyproject.toml`. Single `asyncio` process with four parts: poller supervisor, state cache, client fan-out, HTTP/WebSocket server.

**Command line**

- `solis-hub serve --config PATH` runs the daemon (default config `hub.json` in the state directory)
- `solis-hub token new` writes a fresh 32-byte URL-safe token to `hub-token` (0600) and prints it once
- `solis-hub token show` prints the existing token; `solis-hub check --config PATH` validates config and exits

**Config file (JSON)**

```json
{
  "listen_host": "0.0.0.0",
  "listen_port": 8765,
  "token_file": null,
  "poller_args": ["--host", "192.168.1.57", "--interval", "2", "--idle-interval", "5",
                   "--dynamic-voltage-control", "--dynamic-import-control"],
  "history_native_minutes": 30,
  "history_compact_hours": 24,
  "ntfy": null
}
```

`poller_args` are passed to `solis-poll --stream-json` verbatim. The hub always adds `--stream-json` itself and refuses args containing it, `--once`, `--csv` or `--jsonl` paths outside the state directory. `null` paths resolve to the state directory. Unknown keys are an error, not ignored.

**Poller supervisor**

- Locates `solis-poll` beside its own executable first, then on `PATH`, mirroring `ExecutableLocator.swift`
- Reads stdout line by line; a line that fails JSON decoding is logged and dropped, never forwarded
- Restarts on exit with backoff 1 s doubling to 60 s, resetting after 5 minutes of healthy running
- Never runs two pollers: a new child starts only after the old one has exited and its pipes are drained
- On SIGTERM or SIGINT: stop accepting clients, forward SIGTERM to the child, keep draining its output, wait up to 20 s for exit. If the child has not exited, log that restoration is pending and leave it running rather than killing it, matching the menu bar's 15 s behaviour
- **Verify** that `solis_poll.py` performs orderly restoration on SIGTERM, not only on SIGINT/Ctrl-C. systemd stops services with SIGTERM. If it does not, add SIGTERM handling that follows the existing orderly-quit path exactly, with a test in `test_end_to_end.py`

**State cache**

The contract sends some fields only in the first sample of a run or when they change. The cache keeps the latest value of each so a client joining late sees a complete picture:

- `voltage_control.configuration` (reset when the poller restarts)
- `voltage_control.recent_events` (last list received)
- `voltage_control.octopus_schedule` (last plan received)
- `device` and the latest full envelope

The merged envelope is the latest envelope with these carried-forward fields filled in. It is what `snapshot` messages carry.

**Attention aggregation**

The hub writes `attention on` to the child when the first client with attention on connects or turns it on, and `attention off` when the last such client turns it off or disconnects. No clients means attention off. Only state changes are written. Clients default to attention off on connect until they say otherwise.

**Fan-out and slow clients**

Each client has a bounded queue of 16 outbound messages. On overflow, the hub clears that client's queue and enqueues one fresh `snapshot` instead. This is safe because snapshots carry the merged state, so a lagging phone on mobile data never loses an event list or blocks other clients.

**In-memory history**

Two ring buffers, cleared on hub restart (same behaviour as the menu bar today): native-resolution envelopes for `history_native_minutes`, and one envelope per 30 s for `history_compact_hours`. Store only the `timestamp`, `reading`, `cadence`, and the numeric/control fields of `voltage_control` (state, action, mode, raw and filtered voltage, desired limit, emergency, actuator `last_commanded_raw` and `resolution_w`, effective voltage band, `ev_charging`). Do not store `recent_events`, `configuration`, diagnostics or alarms arrays per sample.

**Logging**

Plain lines to stderr (journald captures them). Never log tokens, Authorization headers, Cloudflare secrets or credential file contents.

## Hub protocol

WebSocket at `/v1/stream`, HTTP endpoints under `/v1/`, all on one port. Every message is a JSON text frame with a `type` field. `hub_protocol_version` is 1 and is independent of the stream's `schema_version`; envelopes inside messages are the unmodified stream contract.

**Server to client**

| Type | When | Fields |
| --- | --- | --- |
| `hello` | Once, immediately after the upgrade | `hub_protocol_version`, `hub_version`, `stream_schema_version`, `hub_id` (stable UUID stored in the state directory), `poller` status object |
| `snapshot` | After `hello`, after a lag overflow, after a poller restart | `envelope`: the merged envelope, or null before the first sample |
| `sample` | Every envelope from the poller | `envelope`: forwarded unchanged |
| `poller_status` | On any supervisor state change | `state` (`starting`, `running`, `backoff`, `stopping`, `restoration_pending`), `since`, `restarts`, `last_exit_code`, `next_attempt_at` |
| `error` | Before a policy close | `code`, `message` |

**Client to server**

| Type | Fields | Effect |
| --- | --- | --- |
| `attention` | `on` (bool) | Feeds attention aggregation |
| `ping` | `nonce` | Answered with `pong` carrying the same nonce, for app-level liveness on mobile |

Any other type is ignored and logged once per connection. There are deliberately no control or settings commands.

**WebSocket implementation requirements**

- RFC 6455 server handshake with `Sec-WebSocket-Accept`; reject missing or wrong version with 426
- Accept only masked client frames; unmasked frames close with 1002
- Text, close, ping and pong opcodes only; binary frames close with 1003
- Reject fragmented messages and any message over 64 KiB with 1009; server frames are unfragmented
- Server sends a protocol ping every 20 s and drops a client with no pong within 40 s
- No extensions, no subprotocol negotiation, no compression

**HTTP endpoints (all require the token except ****`healthz`****)**

| Method and path | Returns |
| --- | --- |
| `GET /v1/healthz` | `{"ok": true}` only; no data, for Cloudflare and systemd checks |
| `GET /v1/status` | Hub version, poller status, connected client count, merged envelope age |
| `GET /v1/history/samples?since=ISO&resolution=native\|compact` | Array of stored history entries since the timestamp, gzip if the client accepts it |
| `GET /v1/history/control?since=ISO&kind=minutes\|events` | Rows from the poller's `voltage-history.sqlite3`, opened read-only with `mode=ro` URI; inspect the real schema and return rows as JSON objects keyed by column name |

Unknown paths return 404 with no body detail. Responses set `Cache-Control: no-store`.

## Security and authentication

The home network is not trusted. Every WebSocket upgrade and every HTTP request except `healthz` needs `Authorization: Bearer <token>`.

- Token comparison uses `hmac.compare_digest`; failures return 401 with no detail and are rate-limited to 10 per minute per source address, then 429
- Behind Cloudflare, the source address is `CF-Connecting-IP` only when the TCP peer is loopback (cloudflared); otherwise the peer address
- The token file is created 0600 and the state directory 0700; the hub refuses to start if the token file is group- or world-readable
- Clients store the token and any Cloudflare Access credentials in the Keychain, never in `UserDefaults` or logs
- The hub never reads, returns or relays Hypervolt or Octopus credentials; those stay in the Pi's state directory, written by the existing `hypervolt-login` and `octopus-login` run on the Pi
- Local connections are plain `ws://` on the LAN, protected by the token. The iOS app needs `NSAllowsLocalNetworking` for this; remote connections are always `wss://` through Cloudflare
- Treat every client message as untrusted input: validate type and fields, cap sizes, never pass client data to the poller other than the two fixed attention strings

## Remote access via Cloudflare Tunnel

Away from home, clients connect to a stable HTTPS hostname such as `energy.<domain>` served by Cloudflare Tunnel. `cloudflared` on the Pi makes an outbound connection, so no router ports are opened and no VPN client is needed on the phone.

- Ship `deploy/pi/cloudflared-config.yml.example` routing the hostname to `http://127.0.0.1:8765`, with WebSocket support (the default) and no response buffering
- Document Cloudflare Access in front of the hostname with a **service token**. Clients send `CF-Access-Client-Id` and `CF-Access-Client-Secret` on every request when configured; the hub's own bearer token is still required behind it, so either layer failing open is not enough
- The hub needs no Cloudflare-specific code beyond the `CF-Connecting-IP` handling above
- **Endpoint selection in clients:** try the LAN endpoint first (Bonjour result or manual LAN URL) with a 2 s connect timeout, then the remote URL. Re-evaluate on network path change via `NWPathMonitor`, so leaving the house moves the connection to the tunnel without user action
- `docs/hub-remote-access.md` must give the Cloudflare dashboard steps in prose (create tunnel, add public hostname, create Access application, create service token) and state that Cloudflare's free tier covers this use

## Menu-bar app changes

The menu bar gets a **Connection** setting with two modes. Direct is the default and is today's behaviour, unchanged for anyone who never touches the setting.

| Mode | Data source | Runs `solis-poll` locally | Settings editable |
| --- | --- | --- | --- |
| Direct | Child process, as today | Yes | All, as today |
| Hub | WebSocket to `solis-hub` | Never | Display preferences only; control settings shown read-only from the envelope's `configuration` |

**Refactor ****`MonitorStore`**** behind a source protocol**

- Introduce `TelemetrySource` with `start()`, `stop()`, `setAttention(_:)` and an async stream of envelopes plus source status
- `PollerProcessSource` holds the existing child-process code, moved not rewritten
- `HubSource` wraps the SolisHubKit client
- `MonitorStore` keeps its public state (`.connecting`, `.connected`, `.degraded`, `.failed`) and history buffers; both sources feed the same `receive` path so every view works unchanged
- Hub `poller_status` other than `running` maps to `.degraded` with the hub's message, for example "Hub is up, inverter poller restarting in 8 s"

**Single-controller guards**

One Modbus session and one controller, always. These guards are the core safety requirement of the client work:

1. **Hub mode never starts a local poller**, including when the hub is unreachable. Unreachable shows a clear state, last data with its age, and retries.
2. **No automatic fallback from Hub to Direct.** Switching to Direct is an explicit user action behind a confirmation that the hub service is stopped. Silent fallback would open a second session against a logger that supports one and could leave two controllers fighting.
3. **Hub-detected guard in Direct mode.** If Bonjour finds a `_solis-hub._tcp` service on the LAN, the app shows a banner and does not start or restart its local poller until the user chooses "Switch to Hub" or "Ignore for this hub ID".
4. **Changing mode stops the current source fully first.** Switching from Direct waits for the existing asynchronous stop and restoration path before connecting to the hub.

**Hub settings UI**

- Discovered hubs list (Bonjour via `NWBrowser`), plus manual LAN URL
- Remote URL, token, optional Cloudflare Access client ID and secret; secrets in the Keychain
- "Test connection" showing hub version, poller state and which endpoint answered (LAN or remote)
- Hypervolt and Octopus sign-in forms are hidden in Hub mode, replaced by a note to run `hypervolt-login` / `octopus-login` on the hub

**Behaviour in Hub mode**

- Attention hints go over the socket when the popover opens and closes
- On connect, backfill chart history from `/v1/history/samples` (compact for the 24 h charts, native for the 30-minute control chart), then apply live samples; de-duplicate by timestamp
- The voltage control activity list and charts behave exactly as in Direct mode, fed from hub envelopes
- Menu-bar label refresh rules stay as they are

## SolisHubKit and the iOS app

New Swift package `SolisHubKit/` at the repo root, platforms macOS 13 and iOS 17, Foundation and Network only. The menu bar depends on it locally; the iOS app adds it as a Swift Package Manager dependency by Git URL and tag.

**Contents**

- **Stream models.** Move the platform-neutral contract types and `StreamDecoder` out of `SolisMenuBar/.../Models.swift` into the package, unchanged in behaviour. `HistoryBuffer` and chart projections stay in the menu bar unless they have no AppKit/SwiftUI dependency. `StreamContractTests` move with the models and keep pinning every field
- **Hub message types** for every message in the protocol section, decoded with the same snake_case strategy
- **`HubClient`**: `URLSessionWebSocketTask` connection, auth and Cloudflare headers, ping/pong liveness, reconnect with jittered backoff (1 s to 30 s), attention API, and an `AsyncStream` of events (`connected(endpoint)`, `snapshot`, `sample`, `pollerStatus`, `disconnected(reason)`)
- **Merged state**: carries forward `configuration`, `recent_events` and `octopus_schedule` exactly as `MonitorStore` does today, so every consumer gets identical semantics
- **`HubEndpointResolver`**: Bonjour browse for `_solis-hub._tcp`, LAN-then-remote selection, `NWPathMonitor` re-evaluation
- **`HubHistoryClient`**: typed calls for the two history endpoints
- **`HubCredentials`**: Keychain storage with an access group parameter so the iOS app can share credentials with a widget later

**iOS integration contract (for the app repo, not this PR)**

- The app keeps working standalone with its existing data sources. Hub mode is an optional setting that adds the live inverter feed and voltage control activity
- Same single-controller principle: the iOS app never opens a Modbus session
- iOS suspends sockets in the background. The app disconnects on background and reconnects on foreground, sending `attention on` while visible; alerts while backgrounded come from notifications, not the socket
- `docs/hub-ios-integration.md` documents this contract with a minimal SwiftUI usage example

## Notifications

Optional ntfy integration so alerts reach the phone when no app is open. Off unless the `ntfy` config object is set: `{"url": "https://ntfy.sh", "topic": "<random>", "token_file": null, "min_interval_s": 300}`.

| Event | Trigger | Priority |
| --- | --- | --- |
| Emergency intervention | A sample with `voltage_control.emergency` true, once per episode | High |
| Poller down | Supervisor not `running` for more than 2 minutes | High |
| Inverter unreachable | Envelope `health.consecutive_failures` sustained for more than 2 minutes | High |
| Restoration pending | Supervisor enters `restoration_pending` | High |
| Recovered | Any of the above clears | Default |

- Posted with `urllib.request` on a background thread; a slow or failing ntfy server can never delay fan-out or supervision
- Rate-limited per event type by `min_interval_s`; messages contain no secrets and no addresses
- APNs is deferred to the iOS app work

## Raspberry Pi deployment

Target: Raspberry Pi 4 or 5 on Raspberry Pi OS Lite 64-bit (Bookworm or later), wired Ethernet, booting from SSD or NVMe rather than SD card. If the inverter has backup/EPS output, the Pi goes on a backed-up circuit.

New directory `deploy/pi/`:

- **`install.sh`**: idempotent; creates system user `solis`, a venv at `/opt/solis-tools` installed from the checked-out source, state directory `/var/lib/solis-tools` (0700), config at `/etc/solis-tools/hub.json`; generates the token if absent; installs and enables the units below. Safe to re-run for upgrades
- **`solis-hub.service`**: `User=solis`, `Environment=XDG_STATE_HOME=/var/lib` so the existing state-directory logic resolves to `/var/lib/solis-tools`, `Restart=on-failure`, `KillMode=mixed`, `TimeoutStopSec=30` (above the hub's 20 s restoration wait), `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `ReadWritePaths=/var/lib/solis-tools`
- **`solis-hub.avahi.service`**: advertises `_solis-hub._tcp` on port 8765 with TXT records `hub_id`, `proto=1`. Advertising via Avahi keeps mDNS out of the Python code
- **`cloudflared-config.yml.example`**: as in the remote access section
- **`hub.json.example`**: commented in the accompanying doc, since JSON has no comments

Also add `solis-hub` to `Formula/solis-tools.rb` so Homebrew installs it on macOS and Linux, and a `make hub-demo` target that runs `fake_inverter.py` plus `solis-hub` locally for testing the menu bar's Hub mode without hardware.

## Migrating control from the Mac to the Pi

The runbook goes in `docs/hub.md`. Control state is endpoint-scoped, so the order matters:

1. On the Mac, disable control and select Save and connect, then quit the menu bar normally. Confirm the baseline was restored and the journal is clean (no pending restoration message).
2. Copy the export-control validation record, if one exists, to the Pi's state directory. It is evidence about the logger endpoint, not the Mac, so it stays valid **only** if the Pi's `poller_args` use the identical host spelling, port and unit. Otherwise revalidate on the Pi.
3. Do not copy the control journal. A clean shutdown makes it unnecessary, and an unclean one must be recovered on the Mac first, following the existing README precautions.
4. Run `hypervolt-login` and `octopus-login` on the Pi if those features are used.
5. Start `solis-hub`, confirm `/v1/status` shows the poller running, then switch the menu bar to Hub mode.

Reverse migration is the same steps the other way. The hub-detected guard stops the Mac reconnecting directly while the hub is still advertising.

## Tests and CI

No hardware anywhere: everything runs against `fake_inverter.py`. New tests join the existing `make` and `make swift` targets so CI picks them up with no workflow rewrite beyond adding the SolisHubKit package to the macOS Swift job.

**`test_solis_hub.py`**** (unit)**

- Handshake: RFC 6455 section 1.3 sample key produces the documented accept value; bad version gets 426
- Framing: masked text accepted; unmasked, binary, fragmented and oversize frames close with the specified codes; ping/pong and close handshake
- Auth: missing, wrong and correct tokens; constant-time path used; rate limit reaches 429; `healthz` open; insecure token file permissions refuse startup
- Config: unknown keys, forbidden poller args and bad types are rejected
- State cache: a late joiner's snapshot contains `configuration`, `recent_events` and `octopus_schedule` from earlier samples; cache resets on poller restart
- Attention: first on writes `attention on`; last off or disconnect writes `attention off`; repeats write nothing
- Slow client: overflow replaces the queue with one snapshot and other clients are unaffected
- History: ring retention and decimation; SQLite endpoints open read-only (a write attempt through that connection fails)
- Notifications: triggers, recovery messages, rate limiting, ntfy failure never blocks the loop

**End-to-end (extend ****`test_end_to_end.py`**** or add ****`test_hub_end_to_end.py`****)**

- Real `solis-hub` subprocess supervising real `solis-poll` against `fake_inverter.py`; two WebSocket test clients receive `hello`, `snapshot` and live samples
- `--drop-after` on the fake inverter: clients see degraded envelopes then recovery, poller never duplicated
- Kill the poller child: hub reports backoff, restarts it, clients get a fresh snapshot
- SIGTERM the hub with control enabled on the fake inverter: baseline register restored before exit
- Assert at all times that the fake inverter sees at most one TCP session

**Swift (****`swift test`****)**

- Moved `StreamContractTests` still pass unchanged
- Hub message decoding and merged-state carry-forward
- `HubClient` reconnect and backoff against a local test WebSocket server
- Mode logic: Hub mode never constructs `PollerProcessSource`; no automatic Hub to Direct fallback; hub-detected guard blocks local poller start until the user decides

## Documentation updates

| File | Change |
| --- | --- |
| `docs/hub.md` (new) | What the hub is, config reference, Pi install, token management, migration runbook, troubleshooting |
| `docs/hub-protocol.md` (new) | Full message and endpoint reference, versioning rules mirroring `stream-contract.md` |
| `docs/hub-remote-access.md` (new) | Cloudflare Tunnel and Access setup steps |
| `docs/hub-ios-integration.md` (new) | SolisHubKit usage and the iOS contract |
| `docs/architecture.md` | New diagram and sections for the hub, SolisHubKit and the two menu-bar sources |
| `docs/stream-contract.md` | Note that the hub is a second consumer and forwards envelopes unchanged |
| `README.md` | Short "Always-on hub (optional)" section linking to `docs/hub.md`; update the "do not run a second poller" warning to cover the hub |
| `CLAUDE.md` | Add the single-controller guards and the hub's no-dependency, no-write rules to the non-negotiable list |
| `CHANGELOG.md` | Unreleased entry for the hub, Hub mode and SolisHubKit |

## Acceptance criteria

- [ ] `make` and `make swift` pass locally and in CI with no new runtime dependency in `pyproject.toml` or `requirements.txt`
- [ ] With the setting untouched, the menu bar behaves exactly as before, verified by the existing test suite passing unmodified apart from moved files
- [ ] `make hub-demo` plus the menu bar in Hub mode shows live data, charts backfilled on connect and voltage control activity from the fake inverter
- [ ] Two clients connected at once receive identical samples; the fake inverter sees one Modbus session throughout
- [ ] Unauthenticated requests to everything except `healthz` return 401; tokens never appear in logs
- [ ] Stopping the hub with control active restores the baseline before exit; `restoration_pending` is reported if it cannot
- [ ] Hub mode never starts a local poller, and Direct mode refuses to start while a hub is advertised until the user decides
- [ ] `deploy/pi/install.sh` runs cleanly twice on a fresh Raspberry Pi OS Lite image (document the manual check in the PR)
- [ ] Diff contains no American spellings in prose or identifiers and no change to the register whitelist, controller logic or `schema_version`

## Execution: one build, one PR

Work autonomously on branch `feature/solis-hub` and open one pull request against `main`. Do not stop to ask questions: where this spec is silent, follow `CLAUDE.md` and the existing code's patterns, and record the choice under "Decisions made during build" in the PR description.

Work in this order inside the single branch, running `make` (and `make swift` from step 3) after each step and fixing failures before moving on:

1. Read `CLAUDE.md`, `docs/architecture.md`, `docs/stream-contract.md`, `solis_poll.py` stream and signal handling, and `MonitorStore.swift`
2. Python hub: WebSocket and HTTP server, supervisor, cache, attention, history, auth, notifications, config, CLI, with unit tests
3. Hub end-to-end tests against `fake_inverter.py`, including the SIGTERM restoration check (and the SIGTERM fix if needed)
4. SolisHubKit package: move models and contract tests, add hub client, resolver, history client, credentials, with tests
5. Menu bar: `TelemetrySource` refactor with Direct unchanged, then Hub mode, guards and settings UI
6. `deploy/pi/`, Formula, `make hub-demo`
7. Documentation and CHANGELOG
8. Final full `make` and `make swift`, then open the PR

The PR description lists what was built, how each acceptance criterion was verified, decisions made during build, and anything left undone with the reason. Commit in logical, imperative-subject commits per `CONTRIBUTING.md`. Do not bump the version or run the release workflow; releasing follows `docs/releasing.md` separately.

## Decisions recorded and deferred

| Decision | Rationale |
| --- | --- |
| Hub wraps `solis-poll` as a subprocess rather than importing it | Reuses the proven lifecycle, journal and restoration paths with zero changes to safety code |
| WebSocket, not MQTT, as the client protocol | No broker to run, native in Swift, passes through Cloudflare Tunnel; MQTT only adds value for Home Assistant |
| Cloudflare Tunnel plus Access, no VPN | Outbound-only from the Pi, no open ports, nothing to toggle on the phone |
| Hand-rolled WebSocket server | Keeps PyModbus as the only runtime dependency, following the Hypervolt client precedent |
| No automatic Hub to Direct fallback | Replaces the earlier idea of falling back to read-only direct monitoring: the logger supports one session, so any direct fallback risks a second session and competing controllers |
| Control settings live in the hub config file | Avoids a remote path that can change safety settings; revisit with explicit design |
| Predbat Cloud writes need no new arbitration | The controller already adopts external limit changes as the new baseline |

**Deferred**

- Optional MQTT bridge with Home Assistant discovery, as a separate consumer of the same cache
- APNs notifications and iOS app UI, in the iOS repo
- Remote, authenticated control settings changes
- Hub history persisted across restarts

---

## Where the implementation differs

Decisions made during the build, where the spec was silent or a better option appeared. None changes the controller, the register whitelist or `schema_version`.

- **`snapshot` also carries a `poller` object**, so a lagging client that dropped a `poller_status` still learns the supervisor state. Additive; `hub_protocol_version` stays 1.
- **Extra config key `max_clients`** (default 32) and a `state_dir` key. The hub does not pass `state_dir` to the poller, which keeps its own state directory; the unit sets both to the same place. The poller runs with the state directory as its working directory so relative `--csv` and `--jsonl` paths stay inside it. `SOLIS_POLL_PATH` overrides the poller lookup.
- **Cloudflare Access credentials go only to the remote HTTPS endpoint**, not to plain-http LAN endpoints. This is narrower than "on every request" above, on purpose: the LAN path does not pass through Cloudflare and the secret should not cross plain http.
- **A Bonjour-found hub is used only after the person chooses it**, so the bearer token cannot be sent to whatever advertises `_solis-hub._tcp`. Clients also refuse HTTP redirects.
- **A root `Package.swift` exposes `SolisHubKit`**, because SwiftPM only reads a root manifest and the iOS app could not otherwise depend on it by Git URL and tag. `SolisHubKit` also imports Security for the Keychain, so it is "Apple system frameworks only" rather than "Foundation and Network only".
- **Leaving Hub mode for Direct also ignores the hub just left**, because Avahi keeps advertising a stopped hub and the guard would otherwise block the local poller indefinitely.
- **If the hub abandons a poller that will not finish restoring, it exits with `os._exit`**, because asyncio otherwise kills a still-running child as the loop closes. A second signal at any point cuts the wait short. The poller restores itself when its pipe closes; under systemd, `KillMode=mixed` still ends everything at `TimeoutStopSec`.
- **The SIGTERM check in `solis_poll.py` needed no change**: `_interrupt` already routes SIGTERM through the Ctrl-C exit path. A test now pins it.
- **The Swift `HubClient` is tested against a scripted transport**, not "a local test WebSocket server", and nothing exercises the real `URLSession` transport or the `NWBrowser` glue. `StreamContractTests` for the stream models moved to `SolisHubKit`; the menu bar keeps a file of that name for its remaining tests.
- **`hub.json.example`** adds `--meter-voltage` and `--pv` to the spec's sample `poller_args` and leaves dynamic control off; control flags belong in `poller_args` per the migration runbook.
- **Not verified here:** `deploy/pi/install.sh` running twice on a fresh Raspberry Pi OS Lite image, and Hub mode in the menu-bar app on a Mac. See the pull request for the full account.
