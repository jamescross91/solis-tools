import Foundation
import SolisHubKit

/// Hub mode: the dashboard is fed by a solis-hub over its WebSocket, and this
/// Mac runs no poller at all. Nothing here can construct or start a
/// PollerProcessSource, and an unreachable hub is reported and retried, never
/// worked around.
@MainActor
final class HubSource: TelemetrySource {
    let events: AsyncStream<TelemetryEvent>

    private let continuation: AsyncStream<TelemetryEvent>.Continuation
    private let settings: HubSourceSettings
    private var client: HubClient?
    private var resolver: HubEndpointResolver?
    private var clientTask: Task<Void, Never>?
    private var resolverTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var attention = false
    private var link = HubLinkInfo()

    init(settings: HubSourceSettings) {
        let (stream, continuation) = makeTelemetryStream()
        events = stream
        self.continuation = continuation
        self.settings = settings
    }

    func start() {
        guard client == nil else { return }
        continuation.yield(.status(.connecting))
        let client = HubClient(auth: settings.auth)
        let resolver = HubEndpointResolver()
        self.client = client
        self.resolver = resolver
        client.setAttention(attention)

        let stream = client.events
        clientTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }

        let updates = resolver.updates
        let connection = settings.connection
        resolverTask = Task {
            var pathRevision = 0
            for await network in updates {
                let candidates = HubEndpointSelector.candidates(
                    settings: connection,
                    discovered: network.discovered,
                    pathSatisfied: network.pathSatisfied
                )
                await client.updateEndpoints(candidates)
                // Leaving or reaching home can change nothing in the candidate
                // list, so the client is told directly to start over.
                if network.pathRevision != pathRevision {
                    pathRevision = network.pathRevision
                    await client.networkPathChanged()
                }
            }
        }
        resolver.start()
        Task { await client.start() }
    }

    func stop() async -> Bool {
        resolver?.stop()
        resolverTask?.cancel()
        backfillTask?.cancel()
        if let client {
            await client.stop()
        }
        // Stopping the client finishes its stream, which ends this task.
        await clientTask?.value
        resolverTask = nil
        clientTask = nil
        backfillTask = nil
        client = nil
        resolver = nil
        continuation.yield(.status(.stopped))
        continuation.finish()
        return true
    }

    func setAttention(_ visible: Bool) {
        attention = visible
        client?.setAttention(visible)
    }

    private func handle(_ event: HubEvent) {
        switch event {
        case let .connected(endpoint):
            link.isConnected = true
            link.endpointKind = endpoint.kind
            link.disconnectReason = nil
            continuation.yield(.hubLink(link))
            startBackfill(from: endpoint)
        case let .hello(hello):
            link.hubVersion = hello.hubVersion
            link.hubID = hello.hubId
            continuation.yield(.hubLink(link))
            if let poller = hello.poller {
                apply(poller)
            }
        case let .snapshot(snapshot):
            if let poller = snapshot.poller {
                apply(poller)
            }
            if let envelope = snapshot.envelope {
                continuation.yield(.envelope(envelope))
            } else {
                continuation.yield(.carriedStateReset)
            }
        case let .sample(envelope):
            continuation.yield(.envelope(envelope))
        case let .pollerStatus(status):
            apply(status)
        case let .disconnected(reason):
            link.isConnected = false
            link.disconnectReason = reason.summary
            continuation.yield(.hubLink(link))
            switch reason {
            case .stopped:
                break
            case .endpointChanged:
                continuation.yield(.status(.connecting))
            case .incompatible(let detail):
                continuation.yield(.status(.failed(detail)))
            default:
                // The last data stays on screen with its age; the status is
                // all that changes, and the client keeps retrying.
                continuation.yield(.status(.failed(reason.summary)))
            }
        }
    }

    private func apply(_ poller: HubPollerStatus) {
        if let message = poller.summary() {
            continuation.yield(.status(.degraded(message)))
        } else {
            continuation.yield(.status(.live))
        }
    }

    /// Chart history comes from the hub, so a popover opened after a day of
    /// running shows a day of history rather than the time since this app
    /// launched. A failure is not worth a banner: the charts then simply
    /// start from now, as Direct mode's do.
    private func startBackfill(from endpoint: HubEndpoint) {
        backfillTask?.cancel()
        let history = HubHistoryClient(endpoint: endpoint, auth: settings.auth)
        let now = Date()
        let longSince = now.addingTimeInterval(-HistoryBuffer.retentionInterval)
        let controlSince = now.addingTimeInterval(-ControlHistoryBuffer.retentionInterval)
        backfillTask = Task { [weak self] in
            async let compact = history.samples(since: longSince, resolution: .compact)
            async let native = history.samples(since: controlSince, resolution: .native)
            guard let long = try? await compact, let control = try? await native,
                  !Task.isCancelled
            else { return }
            let longPoints = long.compactMap { HistoryPoint(entry: $0) }
            let controlPoints = control.compactMap { HistoryPoint(entry: $0) }
            self?.continuation.yield(.backfill(long: longPoints, control: controlPoints))
        }
    }
}
