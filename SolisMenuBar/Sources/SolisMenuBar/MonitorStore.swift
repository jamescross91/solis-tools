import Combine
import Foundation
import SolisHubKit

struct MenuBarSnapshot: Sendable {
    let reading: InverterReading?
    let symbol: String
    let hasAlert: Bool
    let statusLabel: String
}

@MainActor
final class MenuBarPresentation: ObservableObject {
    @Published private(set) var snapshot = MenuBarSnapshot(
        reading: nil,
        symbol: "bolt.house",
        hasAlert: false,
        statusLabel: "Solis stopped"
    )

    func update(_ snapshot: MenuBarSnapshot) {
        self.snapshot = snapshot
    }
}

private struct DashboardPresentation {
    var latest: StreamEnvelope?
    var history: [HistoryPoint] = []
    var controlHistory: [HistoryPoint] = []
}


/// Something that reports which solis-hubs are on the local network. The
/// Bonjour-backed implementation is HubKit's resolver; tests substitute one.
protocol HubPresenceWatching: AnyObject, Sendable {
    var updates: AsyncStream<HubNetworkState> { get }
    func start()
    func stop()
}

extension HubEndpointResolver: HubPresenceWatching {}

@MainActor
final class MonitorStore: ObservableObject {
    enum State: Equatable {
        case stopped
        case connecting
        case connected
        case degraded
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private var presentation = DashboardPresentation()
    @Published private(set) var executablePath: String?
    @Published private(set) var shutdownMessage: String?
    /// Why the source is impaired, in words: a hub whose poller is
    /// restarting, or a local poller held back by a detected hub.
    @Published private(set) var statusDetail: String?
    @Published private(set) var policy: ConnectionPolicy
    @Published private(set) var hubLink: HubLinkInfo?
    /// Set while this Mac cannot look for a solis-hub (Local Network access
    /// denied, say). The hub-detected guard then cannot see a hub, so it fails
    /// open, and the person is told rather than left to assume it is working.
    @Published private(set) var discoveryWarning: String?

    let menuPresentation = MenuBarPresentation()

    var latest: StreamEnvelope? { presentation.latest }
    var history: [HistoryPoint] { presentation.history }
    var controlHistory: [HistoryPoint] { presentation.controlHistory }
    /// When the newest envelope arrived, so a stale display can say how stale.
    private(set) var lastEnvelopeAt: Date?

    private let defaults: UserDefaults
    private let factory: TelemetrySourceFactory
    private let makePresence: @MainActor () -> any HubPresenceWatching
    private let loadHubSettings: @MainActor () -> HubSourceSettings?

    private var source: (any TelemetrySource)?
    private var eventTask: Task<Void, Never>?
    private var presence: (any HubPresenceWatching)?
    private var presenceTask: Task<Void, Never>?
    private var scanCompleted = false
    private var activeConfiguration: MonitorConfiguration?
    private var wantsLocalRun = false
    private var lastSuccessfulPolls = 0
    private var historyBuffer = HistoryBuffer()
    private var controlHistoryBuffer = ControlHistoryBuffer()
    private var lastHistoryDate: Date?
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleRevision = 0
    private var latestReceived: StreamEnvelope?
    private var merger = StreamStateMerger()
    private var dashboardVisible = false
    private var lastMenuUpdate = Date.distantPast
    private var lastUrgentSignature: String?

    private static let closedMenuRefreshInterval: TimeInterval = 5
    /// Long enough for a slow first Bonjour answer: a hub missed here lets the
    /// local poller start beside it.
    private static let initialScanTimeout: TimeInterval = 3.0

    init(
        defaults: UserDefaults = .standard,
        factory: TelemetrySourceFactory = .live,
        makePresence: @escaping @MainActor () -> any HubPresenceWatching = {
            HubEndpointResolver(resolveAddresses: false)
        },
        loadHubSettings: @escaping @MainActor () -> HubSourceSettings? = {
            HubSettingsStore.sourceSettings()
        }
    ) {
        self.defaults = defaults
        self.factory = factory
        self.makePresence = makePresence
        self.loadHubSettings = loadHubSettings
        policy = ConnectionPolicy.stored(defaults)
    }

    var isRunning: Bool {
        switch state {
        case .stopped: false
        // A hub that is unreachable is still being retried by its source, so
        // it counts as running; otherwise every popover open would restart it.
        case .failed: policy.mode == .hub && source != nil
        default: true
        }
    }

    var menuSymbol: String {
        if latestReceived?.reading.alarms.contains(where: { $0.severity == "fault" }) == true {
            return "exclamationmark.triangle.fill"
        }
        switch state {
        case .connected: return "bolt.house.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .degraded, .failed: return "wifi.exclamationmark"
        case .stopped: return "bolt.house"
        }
    }

    var hasMenuAlert: Bool {
        if latestReceived?.reading.alarms.contains(where: { $0.severity == "fault" }) == true {
            return true
        }
        switch state {
        case .degraded, .failed: return true
        case .stopped, .connecting, .connected: return false
        }
    }

    var menuStatusLabel: String {
        if latestReceived?.reading.alarms.contains(where: { $0.severity == "fault" }) == true {
            return "Solis inverter fault"
        }
        switch state {
        case .degraded: return "Solis connection degraded"
        case .failed: return policy.mode == .hub ? "Solis hub unreachable" : "Solis connection failed"
        case .stopped: return "Solis stopped"
        case .connecting: return "Solis connecting"
        case .connected: return "Solis connected"
        }
    }

    func exportControlValidated(host: String, port: Int, slave: Int) -> Bool {
        guard let activeConfiguration else { return false }
        return activeConfiguration.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && activeConfiguration.port == port
            && activeConfiguration.slave == slave
            && latestReceived?.voltageControl?.exportWriteValidated == true
    }

    // MARK: Starting and stopping

    /// Start from stored settings if they are complete and nothing is running.
    ///
    /// Called when the menu-bar item itself appears, so a configured install
    /// begins polling at login rather than waiting for its first click.
    func startIfConfigured() {
        guard !isRunning else { return }
        switch policy.mode {
        case .hub:
            guard loadHubSettings() != nil else { return }
            startHub()
        case .direct:
            guard let configuration = MonitorConfiguration.stored(defaults) else { return }
            start(configuration: configuration)
        }
    }

    /// Direct mode only. Refused outright in Hub mode, so no caller can start
    /// a local poller while a hub is the controller.
    func start(configuration: MonitorConfiguration) {
        guard policy.mode == .direct else { return }
        lifecycleRevision += 1
        let revision = lifecycleRevision
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            guard revision == lifecycleRevision, await stopSource() else { return }
            guard revision == lifecycleRevision else { return }
            activeConfiguration = configuration
            shutdownMessage = nil
            wantsLocalRun = true
            startPresence()
            // A hub may already be advertising; the guard needs to know
            // before the first launch, not after it.
            await waitForInitialScan()
            guard revision == lifecycleRevision else { return }
            launchLocalPollerIfAllowed()
        }
    }

    /// Hub mode only.
    func startHub() {
        guard policy.mode == .hub else { return }
        lifecycleRevision += 1
        let revision = lifecycleRevision
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            guard revision == lifecycleRevision, await stopSource() else { return }
            guard revision == lifecycleRevision else { return }
            shutdownMessage = nil
            beginHubSource()
        }
    }

    func stop(clearReading: Bool = false) {
        lifecycleRevision += 1
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            wantsLocalRun = false
            if await stopSource() {
                // With no source (Direct mode held back by a hub) nothing
                // emits .stopped, so the state would never leave "degraded".
                statusDetail = nil
                setState(.stopped)
                if clearReading {
                    clearReadings()
                }
            }
        }
    }

    func stopForApplicationTermination() async -> Bool {
        lifecycleRevision += 1
        await lifecycleTask?.value
        wantsLocalRun = false
        stopPresence()
        return await stopSource()
    }

    /// Completes when every queued start or stop has finished.
    func waitUntilIdle() async {
        await lifecycleTask?.value
    }

    func setDashboardVisible(_ visible: Bool) {
        guard dashboardVisible != visible else { return }
        dashboardVisible = visible
        source?.setAttention(visible)
        if visible {
            publishDashboard()
        }
    }

    // MARK: Choosing a controller

    /// "Switch to Hub". The current source is stopped completely first, which
    /// for Direct means waiting for the poller to restore the inverter's
    /// limits, so the hub never meets a half-stopped local poller. Returns
    /// false, changing nothing, when no hub address and token are saved yet.
    @discardableResult
    func switchToHub() -> Bool {
        guard loadHubSettings() != nil else { return false }
        lifecycleRevision += 1
        let revision = lifecycleRevision
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            guard revision == lifecycleRevision else { return }
            wantsLocalRun = false
            // Only after a clean stop does the mode change; if restoration is
            // still pending the local poller stays the one controller.
            guard await stopSource() else { return }
            guard revision == lifecycleRevision else { return }
            stopPresence()
            policy.chooseHub()
            policy.persist(defaults)
            shutdownMessage = nil
            beginHubSource()
        }
        return true
    }

    /// Hub to Direct. Never automatic: the caller must have shown the person
    /// a confirmation that the hub service is stopped, and passes `true` only
    /// once they gave it.
    @discardableResult
    func switchToDirect(hubServiceConfirmedStopped: Bool) -> Bool {
        guard hubServiceConfirmedStopped else { return false }
        lifecycleRevision += 1
        let revision = lifecycleRevision
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            guard revision == lifecycleRevision, await stopSource() else { return }
            guard revision == lifecycleRevision else { return }
            // Presence only runs in Direct mode, so the policy has seen no
            // advertisements and cannot ignore the hub being left itself.
            let leftHubID = hubLink?.hubID ?? loadHubSettings()?.connection.preferredHubID
            policy.switchToDirect(hubServiceConfirmedStopped: true)
            if let leftHubID {
                policy.ignore(hubID: leftHubID)
            }
            policy.persist(defaults)
            hubLink = nil
            shutdownMessage = nil
            if let configuration = MonitorConfiguration.stored(defaults) {
                activeConfiguration = configuration
                wantsLocalRun = true
                startPresence()
                await waitForInitialScan()
                guard revision == lifecycleRevision else { return }
                launchLocalPollerIfAllowed()
            } else {
                setState(.stopped)
            }
        }
        return true
    }

    /// "Ignore for this hub ID": the person has seen the hub and wants this
    /// Mac to carry on as before.
    func ignoreHub(id: String) {
        policy.ignore(hubID: id)
        policy.persist(defaults)
        resumeAfterHubDecision()
    }

    func stopIgnoringHub(id: String) {
        policy.stopIgnoring(hubID: id)
        policy.persist(defaults)
    }

    // MARK: Sources

    private func launchLocalPollerIfAllowed() {
        guard policy.mode == .direct, wantsLocalRun, source == nil,
              let configuration = activeConfiguration
        else { return }
        guard policy.localPollerMayStart else {
            statusDetail = "A solis-hub is on this network. Choose Switch to Hub or Ignore before "
                + "this Mac starts its own poller."
            setState(.degraded)
            return
        }
        let newSource = factory.makeLocalPoller(configuration) { [weak self] in
            self?.policy.localPollerMayStart ?? false
        }
        attach(newSource)
        newSource.start()
    }

    private func beginHubSource() {
        guard policy.mode == .hub, source == nil else { return }
        guard let settings = loadHubSettings() else {
            statusDetail = nil
            setState(.failed("Enter the hub address and token in Settings."))
            return
        }
        let newSource = factory.makeHub(settings)
        attach(newSource)
        newSource.start()
    }

    private func attach(_ newSource: any TelemetrySource) {
        source = newSource
        newSource.setAttention(dashboardVisible)
        let stream = newSource.events
        eventTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    /// Stops the current source and waits until it has finished. False means
    /// it has not: a poller still restoring limits is kept, never replaced.
    private func stopSource() async -> Bool {
        guard let current = source else { return true }
        guard await current.stop() else { return false }
        await eventTask?.value
        eventTask = nil
        source = nil
        return true
    }

    private func resumeAfterHubDecision() {
        guard policy.mode == .direct, wantsLocalRun else { return }
        if let running = source as? PollerProcessSource {
            running.resumeAfterHubDecision()
        } else if scanCompleted {
            // Until the first scan has finished the start path is still waiting
            // for it. Launching here, on the empty state discovery publishes
            // first, would start a second controller beside a hub that has not
            // been seen yet.
            launchLocalPollerIfAllowed()
        }
    }

    // MARK: Hub discovery (Direct mode)

    private func startPresence() {
        guard presence == nil else { return }
        scanCompleted = false
        let watcher = makePresence()
        presence = watcher
        let updates = watcher.updates
        presenceTask = Task { [weak self] in
            for await network in updates {
                self?.presenceChanged(network)
            }
        }
        watcher.start()
    }

    private func stopPresence() {
        discoveryWarning = nil
        presence?.stop()
        presenceTask?.cancel()
        presence = nil
        presenceTask = nil
        policy.updateDetectedHubs([])
    }

    private func presenceChanged(_ network: HubNetworkState) {
        // A browser that cannot run will never report, so waiting on it would
        // only delay the launch; the warning below says what that costs.
        scanCompleted = network.scanCompleted || !network.discovered.isEmpty
            || network.discoveryProblem != nil
        discoveryWarning = network.discoveryProblem
        policy.updateDetectedHubs(
            network.discovered.map { DetectedHub(id: $0.id, name: $0.name) }
        )
        // A hub that has gone away, or a decision just made, may free a held
        // launch; this does nothing when nothing is held. A hub that appears
        // after the local poller launched only raises the banner: stopping a
        // running controller on the strength of an advertisement could leave
        // the inverter unregulated, so the person decides.
        resumeAfterHubDecision()
    }

    private func waitForInitialScan() async {
        let deadline = Date().addingTimeInterval(Self.initialScanTimeout)
        while !scanCompleted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Events

    private func handle(_ event: TelemetryEvent) {
        switch event {
        case let .envelope(envelope):
            receive(envelope)
        case let .status(status):
            apply(status)
        case let .unsupportedSchema(version):
            // A schema the app cannot read will not fix itself; say so rather than
            // sitting on "degraded" indefinitely.
            stop()
            let error = StreamError.unsupportedSchema(version)
            setState(.failed(error.localizedDescription))
        case let .shutdownMessage(message):
            shutdownMessage = message
        case let .executablePath(path):
            executablePath = path
        case .runStarted:
            merger.forgetOctopusSchedule()
        case .carriedStateReset:
            merger.reset()
        case let .hubLink(link):
            hubLink = link
        case let .backfill(long, control):
            historyBuffer.merge(backfill: long)
            controlHistoryBuffer.merge(backfill: control)
            lastHistoryDate = controlHistoryBuffer.points.last?.date
            if dashboardVisible {
                publishDashboard()
            }
        }
    }

    private func apply(_ status: TelemetryStatus) {
        switch status {
        case .connecting:
            statusDetail = nil
            setState(.connecting)
        case let .degraded(message):
            statusDetail = message
            setState(.degraded)
        case let .failed(message):
            statusDetail = nil
            setState(.failed(message))
        case .live:
            statusDetail = nil
            if let envelope = latestReceived {
                setState(envelope.error == nil ? .connected : .degraded)
            } else {
                setState(.connecting)
            }
        case .stopped:
            statusDetail = nil
            setState(.stopped)
        }
    }

    private func clearReadings() {
        latestReceived = nil
        lastEnvelopeAt = nil
        merger.reset()
        historyBuffer.removeAll()
        controlHistoryBuffer.removeAll()
        lastHistoryDate = nil
        presentation = DashboardPresentation()
        publishMenu(force: true)
        lastSuccessfulPolls = 0
    }

    private func receive(_ received: StreamEnvelope) {
        let envelope = merger.merge(received)
        latestReceived = envelope
        let now = Date()
        // A hub replays its latest sample on every reconnect, so arrival time
        // would call old data fresh. Clamped in case the hub's clock is ahead.
        if policy.mode == .hub, let stamped = StreamDecoder.date(from: envelope.timestamp) {
            lastEnvelopeAt = min(stamped, now)
        } else {
            lastEnvelopeAt = now
        }
        setState(envelope.error == nil && statusDetail == nil ? .connected : .degraded)

        if envelope.health.successfulPolls != lastSuccessfulPolls {
            lastSuccessfulPolls = envelope.health.successfulPolls
            let sampleDate = StreamDecoder.date(from: envelope.timestamp) ?? Date()
            // A hub replays its latest sample on every reconnect and fills
            // the charts from its own history, so a point already held is
            // skipped. Direct mode's samples only ever move forward.
            let isNew = policy.mode == .direct || lastHistoryDate.map { sampleDate > $0 } ?? true
            if isNew {
                let point = HistoryPoint(
                    date: sampleDate,
                    reading: envelope.reading,
                    voltageControl: envelope.voltageControl
                )
                controlHistoryBuffer.append(point)
                historyBuffer.append(point)
                lastHistoryDate = sampleDate
            }
        }

        let signature = urgentSignature(envelope)
        let urgent = signature != lastUrgentSignature
        lastUrgentSignature = signature
        if dashboardVisible {
            publishDashboard()
        }
        publishMenu(force: urgent)
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        publishMenu(force: true)
    }

    private func publishDashboard() {
        presentation = DashboardPresentation(
            latest: latestReceived,
            history: historyBuffer.points,
            controlHistory: controlHistoryBuffer.points
        )
    }

    private func publishMenu(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastMenuUpdate) >= Self.closedMenuRefreshInterval else {
            return
        }
        lastMenuUpdate = now
        menuPresentation.update(
            MenuBarSnapshot(
                reading: latestReceived?.reading,
                symbol: menuSymbol,
                hasAlert: hasMenuAlert,
                statusLabel: menuStatusLabel
            )
        )
    }

    private func urgentSignature(_ envelope: StreamEnvelope) -> String {
        let alarms = envelope.reading.alarms.map { "\($0.code):\($0.severity)" }.joined(separator: ",")
        let control = envelope.voltageControl
        let newestEvent = control?.recentEvents?.first?.id ?? ""
        return [
            envelope.error ?? "",
            alarms,
            control?.state ?? "",
            control?.action ?? "",
            control?.emergency == true ? "emergency" : "normal",
            newestEvent,
        ].joined(separator: "|")
    }
}
