import Foundation

/// Where the app gets its telemetry. Direct runs solis-poll as a child
/// process, as the app always has; Hub watches a solis-hub over the network.
enum ConnectionMode: String, CaseIterable, Identifiable, Sendable {
    case direct
    case hub

    var id: Self { self }

    var label: String {
        switch self {
        case .direct: "Direct"
        case .hub: "Hub"
        }
    }

    static let defaultsKey = "connectionMode"

    static func stored(_ defaults: UserDefaults = .standard) -> ConnectionMode {
        defaults.string(forKey: defaultsKey).flatMap(ConnectionMode.init(rawValue:)) ?? .direct
    }
}

/// A hub the app has seen advertised on the local network.
struct DetectedHub: Equatable, Hashable, Identifiable, Sendable {
    /// The hub's own id from its Bonjour TXT record, or the service name when
    /// an old advertisement has none. "Ignore" is remembered against this.
    let id: String
    let name: String
}

/// What may be feeding the dashboard right now.
enum SourcePlan: Equatable, Sendable {
    /// Direct mode with no hub advertised (or every one ignored).
    case localPoller
    /// Hub mode. This is also the plan while the hub is unreachable: the app
    /// keeps retrying the hub and never substitutes a local poller.
    case hub
    /// Direct mode, but a hub is on the network and nobody has decided what
    /// to do about it. Nothing is started or restarted until they do.
    case heldForHubDecision([DetectedHub])
}

/// The single-controller rules, as a value with no I/O.
///
/// The logger supports one Modbus session, so at any moment exactly one
/// solis-poll may be running: the Mac's (Direct) or the hub's. Everything
/// here exists to make the second one impossible rather than unlikely. In
/// particular nothing in this type reacts to a hub failing: there is no
/// transition from Hub to Direct except an explicit, confirmed user action.
struct ConnectionPolicy: Equatable, Sendable {
    private(set) var mode: ConnectionMode
    private(set) var ignoredHubIDs: Set<String>
    private(set) var detectedHubs: [DetectedHub] = []

    init(mode: ConnectionMode = .direct, ignoredHubIDs: Set<String> = []) {
        self.mode = mode
        self.ignoredHubIDs = ignoredHubIDs
    }

    /// Hubs that hold back the local poller: advertised and not ignored.
    var blockingHubs: [DetectedHub] {
        detectedHubs.filter { !ignoredHubIDs.contains($0.id) }
    }

    var plan: SourcePlan {
        switch mode {
        case .hub:
            return .hub
        case .direct:
            let blocking = blockingHubs
            return blocking.isEmpty ? .localPoller : .heldForHubDecision(blocking)
        }
    }

    /// May a local solis-poll be started or restarted right now?
    var localPollerMayStart: Bool { plan == .localPoller }

    mutating func updateDetectedHubs(_ hubs: [DetectedHub]) {
        detectedHubs = hubs
    }

    /// "Switch to Hub".
    mutating func chooseHub() {
        mode = .hub
    }

    /// "Ignore for this hub ID". Persisted by the caller.
    mutating func ignore(hubID: String) {
        ignoredHubIDs.insert(hubID)
    }

    mutating func stopIgnoring(hubID: String) {
        ignoredHubIDs.remove(hubID)
    }

    /// Hub to Direct is only ever the person's decision, and only after they
    /// confirm the hub service is stopped; otherwise two controllers would
    /// compete for the logger. Returns whether the switch happened.
    ///
    /// Confirming also ignores the hubs currently advertised: Avahi keeps
    /// advertising a stopped hub's static service file, so without that the
    /// guard would hold Direct back forever.
    @discardableResult
    mutating func switchToDirect(hubServiceConfirmedStopped: Bool) -> Bool {
        guard hubServiceConfirmedStopped else { return false }
        for hub in detectedHubs {
            ignoredHubIDs.insert(hub.id)
        }
        mode = .direct
        return true
    }

    /// What follows a hub failure: the same plan. There is deliberately no
    /// fallback, so this exists only to make that testable and explicit.
    func planAfterHubFailure() -> SourcePlan {
        plan
    }
}

extension ConnectionPolicy {
    static let ignoredHubsKey = "ignoredHubIDs"

    static func stored(_ defaults: UserDefaults = .standard) -> ConnectionPolicy {
        ConnectionPolicy(
            mode: ConnectionMode.stored(defaults),
            ignoredHubIDs: Set(defaults.stringArray(forKey: ignoredHubsKey) ?? [])
        )
    }

    func persist(_ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: ConnectionMode.defaultsKey)
        defaults.set(ignoredHubIDs.sorted(), forKey: Self.ignoredHubsKey)
    }
}
