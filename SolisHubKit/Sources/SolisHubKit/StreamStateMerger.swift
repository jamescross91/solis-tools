import Foundation

/// Fills in what the stream sends only sometimes.
///
/// The poller sends the event log only when it changes, the Octopus plan only
/// when it changes, and the controller configuration in the first sample of a
/// run. Every consumer wants a complete picture on every sample, so this
/// carries the last value forward. The menu bar's direct mode and its hub mode
/// share this one implementation, which is what keeps their dashboards
/// identical.
public struct StreamStateMerger: Sendable {
    private var retainedEvents: [VoltageControlEvent] = []
    private var retainedOctopusSchedule: OctopusScheduleDetails?
    private var retainedConfiguration: VoltageControlConfiguration?

    public init() {}

    public mutating func merge(_ received: StreamEnvelope) -> StreamEnvelope {
        var envelope = received
        // The poller sends the event log only when it changes; carry the last
        // list forward so the dashboard never shows an empty activity section
        // between changes.
        if let control = envelope.voltageControl {
            if let events = control.recentEvents {
                retainedEvents = events
            } else {
                envelope.voltageControl?.recentEvents = retainedEvents
            }
            if let schedule = control.octopusSchedule {
                retainedOctopusSchedule = schedule
            } else {
                envelope.voltageControl?.octopusSchedule = retainedOctopusSchedule
            }
            if let configuration = control.configuration {
                retainedConfiguration = configuration
            } else {
                envelope.voltageControl?.configuration = retainedConfiguration
            }
        } else {
            reset()
        }
        return envelope
    }

    /// A new run of the poller: nothing carried from the last one still applies.
    public mutating func reset() {
        retainedEvents = []
        retainedOctopusSchedule = nil
        retainedConfiguration = nil
    }

    /// Each run sends its Octopus plan (or null when Octopus is off) first; a
    /// plan from an earlier run must not survive a settings change.
    public mutating func forgetOctopusSchedule() {
        retainedOctopusSchedule = nil
    }
}

/// The feed as a single value, for a consumer that only wants the latest
/// picture and not a sample-by-sample history (a widget, a status screen).
public struct HubFeedState: Sendable {
    public private(set) var envelope: StreamEnvelope?
    public private(set) var poller: HubPollerStatus?
    public private(set) var hello: HubHello?
    public private(set) var endpoint: HubEndpoint?
    public private(set) var isConnected = false
    public private(set) var lastDisconnect: HubDisconnectReason?
    private var merger = StreamStateMerger()

    public init() {}

    public mutating func apply(_ event: HubEvent) {
        switch event {
        case let .connected(endpoint):
            self.endpoint = endpoint
            isConnected = true
            lastDisconnect = nil
        case let .hello(hello):
            self.hello = hello
            poller = hello.poller ?? poller
        case let .snapshot(snapshot):
            poller = snapshot.poller ?? poller
            if let received = snapshot.envelope {
                // A snapshot is the hub's complete merged state, so what this
                // client carried from an earlier run must not fill its gaps: a
                // null plan in it means Octopus is off, not "unchanged".
                merger.reset()
                envelope = merger.merge(received)
            } else {
                // The hub has no sample from this run yet, so nothing carried
                // from the last run applies. The old envelope stays on show.
                merger.reset()
            }
        case let .sample(received):
            envelope = merger.merge(received)
        case let .pollerStatus(status):
            poller = status
        case let .disconnected(reason):
            isConnected = false
            lastDisconnect = reason
        }
    }
}
