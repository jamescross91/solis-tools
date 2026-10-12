# Using the hub from the iOS app

The iOS energy monitor adopts `SolisHubKit` in its own repository, after this
one lands. This page is the contract it builds against. The wire format is in
[hub-protocol.md](hub-protocol.md); running the hub is in [hub.md](hub.md).

## Principles

- The app keeps working standalone with its existing data sources. Hub mode is
  an optional setting that adds the live inverter feed and voltage control
  activity.
- Same single-controller rule as the Mac: the iOS app never opens a Modbus
  session, and the hub has no write path to give it one.
- iOS suspends sockets in the background. Disconnect when the app goes to the
  background and reconnect on foreground, sending attention on while the app is
  visible. Alerts while backgrounded come from notifications (the hub's ntfy
  option today, APNs later), not from the socket.
- The hub's token and any Cloudflare Access credentials live in the Keychain.
  Never put them in `UserDefaults`, logs or analytics.

## Adding the package

Add `SolisHubKit` as a Swift Package Manager dependency by Git URL and tag:
`https://github.com/jamescross91/solis-tools`, product `SolisHubKit`. The
repository's root `Package.swift` exists for this (SwiftPM only reads a root
manifest) and builds the same sources as `SolisHubKit/Package.swift`, which the
menu bar uses by path. Pin to a release tag that includes it. The package
targets iOS 17 and macOS 13 and uses Apple system frameworks only (Foundation,
Network and Security), with no third-party dependencies.

For plain `ws://` on the home network the app's Info.plist needs
`NSAppTransportSecurity` with `NSAllowsLocalNetworking` set to true, and
`NSLocalNetworkUsageDescription` plus `NSBonjourServices` containing
`_solis-hub._tcp` so discovery works. Remote connections are always `wss://`
through Cloudflare, so nothing else is relaxed.

## Connection behaviour the app inherits

- A hub found by Bonjour is used only after the person chooses it (`preferredHubID`),
  so the token is never sent to whatever happens to advertise `_solis-hub._tcp`.
  A manually typed LAN URL or remote URL needs no choice.
- Endpoints are tried LAN first with a 2 s connect timeout, then the remote URL,
  and the client reconnects LAN-first when the network path changes
  (`HubClient.networkPathChanged()`, driven by `HubEndpointResolver`'s path
  revision).
- Reconnect backoff runs from 1 s to 30 s with the jitter taken downwards from
  the ceiling, and resets only after a connection stayed up for 10 s, so a hub
  that accepts and immediately closes is not retried in a tight loop.
- `stop()` finishes a client for good; make a new `HubClient` on foreground.

## What the package gives you

| Piece | Purpose |
| --- | --- |
| `StreamEnvelope`, `StreamDecoder` and the contract types | The same models the menu bar decodes |
| `HubServerMessage`, `HubHello`, `HubSnapshot`, `HubPollerStatus` | Every protocol message, decoded with the same snake_case strategy |
| `StreamStateMerger`, `HubFeedState` | Carry forward `configuration`, `recent_events` and `octopus_schedule` exactly as the menu bar does, so every consumer sees identical semantics |
| `HubClient` | Connection, bearer and Cloudflare headers, application-level ping and liveness, reconnect with jittered backoff from 1 s to 30 s, attention, and an `AsyncStream<HubEvent>` |
| `HubEndpointResolver`, `HubEndpointSelector` | Bonjour discovery, LAN first with a 2 s timeout then the remote URL, re-evaluated when the network path changes |
| `HubHistoryClient`, `HubStatusClient`, `HubConnectionTester` | Typed calls for the history endpoints and `/v1/status`, and a "Test connection" helper that reports which endpoint answered |
| `HubCredentials` | Keychain storage, with an `accessGroup` parameter so a widget can share the credentials later |

`HubEvent` is `connected(endpoint)`, `hello`, `snapshot`, `sample`,
`pollerStatus` or `disconnected(reason)`. The client reports `incompatible` and
backs off if the hub's protocol or stream schema is one it does not know.

## A minimal SwiftUI example

```swift
import SolisHubKit
import SwiftUI

@MainActor
final class InverterFeed: ObservableObject {
    @Published private(set) var state = HubFeedState()
    private var client: HubClient?
    private var task: Task<Void, Never>?

    func connect(lan: String, remote: String) throws {
        // A stopped client is finished for good, so every foreground makes a new one.
        guard client == nil, let auth = try HubCredentials().load() else { return }
        let settings = HubConnectionSettings(
            lanURL: HubURLInput.lan(lan),
            remoteURL: HubURLInput.remote(remote)
        )
        let endpoints = HubEndpointSelector.candidates(settings: settings, discovered: [])
        let client = HubClient(endpoints: endpoints, auth: auth)
        self.client = client
        task = Task { [weak self] in
            for await event in client.events {
                self?.state.apply(event)
            }
        }
        client.setAttention(true)   // the screen is visible
        Task { await client.start() }
    }

    func disconnect() async {
        await client?.stop()        // call when the app moves to the background
        task?.cancel()
        client = nil
    }
}

struct LiveView: View {
    @StateObject private var feed = InverterFeed()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack {
            if let reading = feed.state.envelope?.reading {
                Text("\(reading.batterySocPercent)%")
            }
            if let note = feed.state.poller?.summary(now: .now) {
                Text(note).font(.footnote)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                try? feed.connect(lan: "solis-hub.local", remote: "https://energy.example.com")
            } else {
                Task { await feed.disconnect() }
            }
        }
    }
}
```

The example leaves out the Bonjour resolver for brevity; a real app starts
`HubEndpointResolver`, feeds its `updates` into `HubEndpointSelector` and calls
`updateEndpoints(_:)` on the client when the network path changes. The menu
bar's `HubSource.swift` is the reference consumer. The example is not compiled
by CI, so check the signatures against the package when you adopt it.

## Backfilling charts

On connect, call `HubHistoryClient.samples(since:resolution:)` with `.compact`
for 24-hour charts and `.native` for the 30-minute control chart, then apply
live samples, de-duplicating by timestamp. The control history endpoints
(`controlMinutes`, `controlEvents`) expose the poller's own minute aggregates and
event log if the app wants more than the in-memory window.

## What the app must not do

- Open a Modbus connection of any kind.
- Offer to change control settings, enable or disable control, or write to the
  inverter, Hypervolt or Octopus. The hub has no such command, by design.
- Cache the token anywhere but the Keychain, or log an `Authorization` header or
  a Cloudflare secret. `HubAuth` prints as redacted for this reason.
