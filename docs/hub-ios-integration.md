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

Add `SolisHubKit` as a Swift Package Manager dependency by Git URL and tag
(`https://github.com/jamescross91/solis-tools`, product `SolisHubKit`; the
package is in the `SolisHubKit/` subdirectory, so pin to a release tag once one
includes it). It targets iOS 17 and macOS 13 and uses Foundation, Network and
Security only.

For plain `ws://` on the home network the app's Info.plist needs
`NSAppTransportSecurity` with `NSAllowsLocalNetworking` set to true, and
`NSLocalNetworkUsageDescription` plus `NSBonjourServices` containing
`_solis-hub._tcp` so discovery works. Remote connections are always `wss://`
through Cloudflare, so nothing else is relaxed.

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
        guard let auth = try HubCredentials().load() else { return }
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
        .task { try? feed.connect(lan: "solis-hub.local", remote: "https://energy.example.com") }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await feed.disconnect() } }
        }
    }
}
```

The example omits the Bonjour resolver and reconnect-on-foreground for brevity;
a real app starts `HubEndpointResolver`, feeds its `updates` into
`HubEndpointSelector` and calls `updateEndpoints(_:)` on the client when the
network path changes. Check the exact signatures in the package; the menu bar's
`HubSource.swift` is the reference consumer.

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
