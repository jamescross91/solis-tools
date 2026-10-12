import Foundation
import SolisHubKit

/// How a source describes itself to MonitorStore. Whether the data is healthy
/// (`.connected` versus `.degraded` on an envelope that reports an error) is
/// still decided by the store from the envelopes, as it always was.
enum TelemetryStatus: Equatable, Sendable {
    case connecting
    /// Running but impaired. The message is shown beside the connection label.
    case degraded(String?)
    case failed(String)
    /// Hub mode: the hub reports its poller running again.
    case live
    case stopped
}

/// What the dashboard shows about the link to a hub.
struct HubLinkInfo: Equatable, Sendable {
    var isConnected = false
    var endpointKind: HubEndpointKind?
    var hubVersion: String?
    var hubID: String?
    var disconnectReason: String?
}

enum TelemetryEvent: Sendable {
    case envelope(StreamEnvelope)
    case status(TelemetryStatus)
    /// The stream is a schema this build cannot read; retrying will not help.
    case unsupportedSchema(Int)
    case shutdownMessage(String?)
    case executablePath(String)
    /// A new poller run began, so a plan carried from the last one is stale.
    case runStarted
    /// The hub has no sample from its current run: nothing carried applies.
    case carriedStateReset
    case hubLink(HubLinkInfo)
    /// Chart history fetched from the hub on connect: the 24 h chart and the
    /// 30 minute control chart.
    case backfill(long: [HistoryPoint], control: [HistoryPoint])
}

/// Somewhere telemetry comes from. Exactly one source is ever active, and a
/// source that has not fully stopped is never replaced: `stop()` returns
/// false when the poller it owns is still restoring the inverter's limits.
@MainActor
protocol TelemetrySource: AnyObject {
    /// Single consumer; finishes once `stop()` has returned true.
    var events: AsyncStream<TelemetryEvent> { get }
    func start()
    func stop() async -> Bool
    /// Whether anyone is looking, so the poller can slow down when nobody is.
    func setAttention(_ visible: Bool)
}

struct HubSourceSettings: Sendable {
    var connection: HubConnectionSettings
    var auth: HubAuth
}

/// The only place a source is constructed, so a test can assert which kind
/// the store asked for. Hub mode must never reach `makeLocalPoller`.
struct TelemetrySourceFactory: Sendable {
    var makeLocalPoller: @MainActor @Sendable (MonitorConfiguration, @escaping @MainActor () -> Bool) -> any TelemetrySource
    var makeHub: @MainActor @Sendable (HubSourceSettings) -> any TelemetrySource

    static let live = TelemetrySourceFactory(
        makeLocalPoller: { configuration, canLaunch in
            PollerProcessSource(configuration: configuration, canLaunch: canLaunch)
        },
        makeHub: { settings in
            HubSource(settings: settings)
        }
    )
}

/// Builds an event stream whose continuation the owner keeps.
func makeTelemetryStream() -> (AsyncStream<TelemetryEvent>, AsyncStream<TelemetryEvent>.Continuation) {
    var captured: AsyncStream<TelemetryEvent>.Continuation?
    let stream = AsyncStream<TelemetryEvent> { captured = $0 }
    return (stream, captured!)
}
