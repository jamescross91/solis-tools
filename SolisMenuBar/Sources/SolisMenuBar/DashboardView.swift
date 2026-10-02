import Charts
import SolisHubKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var monitor: MonitorStore

    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = 502
    @AppStorage("slave") private var slave = 1
    @AppStorage("pollInterval") private var pollInterval = 2.0
    @AppStorage("slowInterval") private var slowInterval = 10.0
    @AppStorage("idlePollInterval") private var idlePollInterval = 5.0
    @AppStorage("inverterMaxKw") private var inverterMaxKw = 10.0
    @AppStorage("gridMaxKw") private var gridMaxKw = 23.0
    @AppStorage("pvEnabled") private var pvEnabled = false
    @AppStorage("menuBarHouseLoad") private var showHouseLoad = true
    @AppStorage("menuBarBattery") private var showBattery = true
    @AppStorage("menuBarGrid") private var showGrid = true
    @AppStorage("menuBarTemperature") private var showTemperature = false
    @AppStorage("menuBarPV") private var showPV = false
    @AppStorage("dynamicVoltageEnabled") private var dynamicVoltageEnabled = false
    @AppStorage("dynamicImportEnabled") private var dynamicImportEnabled = true
    @AppStorage("dynamicExportEnabled") private var dynamicExportEnabled = false
    @AppStorage("minimumVoltage") private var minimumVoltage = 215.0
    @AppStorage("maximumVoltage") private var maximumVoltage = 258.0
    @AppStorage("voltageSafetyMargin") private var voltageSafetyMargin = 1.5
    @AppStorage("voltageDeadband") private var voltageDeadband = 0.75
    @AppStorage("maximumImportKw") private var maximumImportKw = 14.0
    @AppStorage("importHeadroomKw") private var importHeadroomKw = 2.0
    @AppStorage("maximumExportKw") private var maximumExportKw = 10.0
    @AppStorage("siteExportPermissionKw") private var siteExportPermissionKw = 10.0
    @AppStorage("increaseStepW") private var increaseStepW = 200
    @AppStorage("reductionStepW") private var reductionStepW = 500
    @AppStorage("nearLimitReductionW") private var nearLimitReductionW = 1000
    @AppStorage("emergencyReductionW") private var emergencyReductionW = 2000
    @AppStorage("controlSettleTime") private var controlSettleTime = 5.0
    @AppStorage("controlActivationDelay") private var controlActivationDelay = 5.0
    @AppStorage("controlDeactivationDelay") private var controlDeactivationDelay = 10.0
    @AppStorage("importActivationKw") private var importActivationKw = 1.0
    @AppStorage("exportActivationKw") private var exportActivationKw = 0.5
    @AppStorage("minimumWriteInterval") private var minimumWriteInterval = 5.0
    @AppStorage("hypervoltEnabled") private var hypervoltEnabled = false
    @AppStorage("evPriority") private var evPriority = "battery"
    @AppStorage("hypervoltCredentialsPath") private var hypervoltCredentialsPath = ""
    @AppStorage("octopusEnabled") private var octopusEnabled = false
    @AppStorage("octopusCredentialsPath") private var octopusCredentialsPath = ""

    @StateObject private var hypervoltLogin = HypervoltLoginRunner()
    @StateObject private var octopusLogin = OctopusLoginRunner()
    @StateObject private var hubSettings = HubSettingsModel()

    @State private var showingSettings = false
    /// The mode chosen in the settings form. The active mode only changes when
    /// the person applies it, because changing it stops the current source.
    @State private var pendingMode: ConnectionMode = .direct
    @State private var confirmingDirectSwitch = false
    @State private var selectedMetric: HistoryMetric = .house
    @State private var hypervoltEmail = ""
    @State private var hypervoltPassword = ""
    @State private var octopusAccountNumber: String?
    @State private var octopusAPIKey = ""
    @State private var octopusAccountField = ""
    @State private var octopusDeviceField = ""

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hubDetectedBanners
                    hubStatusBanner
                    if showingSettings || needsSetup {
                        settings
                    } else if let sample = monitor.latest {
                        status(sample)
                        metrics(sample.reading, control: sample.voltageControl)
                        if let schedule = sample.voltageControl?.octopusSchedule {
                            octopusPlan(schedule)
                        }
                        if let control = sample.voltageControl {
                            voltageControlStatus(control, reading: sample.reading)
                            let bounds = chartBounds(for: control)
                            VoltageControlChartView(
                                liveHistory: monitor.controlHistory,
                                longHistory: monitor.history,
                                minimumVoltage: bounds.minimumVoltage,
                                maximumVoltage: bounds.maximumVoltage,
                                safetyMargin: bounds.safetyMargin,
                                maximumImportKw: bounds.maximumImportKw,
                                maximumExportKw: bounds.maximumExportKw
                            )
                        } else {
                            Label("Dynamic voltage control disabled", systemImage: "pause.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        history
                        alarms(sample.reading.alarms)
                        connection(sample)
                    } else {
                        waiting
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 450, height: 680)
        .onAppear {
            pendingMode = monitor.policy.mode
            monitor.setDashboardVisible(true)
            if !needsSetup, !monitor.isRunning {
                connect()
            }
        }
        .onDisappear {
            monitor.setDashboardVisible(false)
        }
        // "Switch to Hub" from a banner changes the mode while the settings
        // form may be open on the other one.
        .onChange(of: activeMode) { newMode in
            pendingMode = newMode
        }
    }

    /// The mode the app is actually running in, as opposed to the one chosen
    /// in the settings form.
    private var activeMode: ConnectionMode {
        let mode: ConnectionMode = monitor.policy.mode
        return mode
    }

    private var isHubMode: Bool {
        activeMode == .hub
    }

    private var needsSetup: Bool {
        if isHubMode {
            let complete: Bool = hubSettings.isComplete
            return !complete
        }
        return host.isEmpty
    }

    private struct ChartBounds {
        let minimumVoltage: Double
        let maximumVoltage: Double
        let safetyMargin: Double
        let maximumImportKw: Double
        let maximumExportKw: Double
    }

    /// Direct mode charts against the settings this Mac passed to its poller.
    /// In Hub mode those settings are the hub's, so the chart follows what the
    /// hub reports; a field it did not send falls back to the stored value.
    private func chartBounds(for control: VoltageControlDetails) -> ChartBounds {
        guard isHubMode, let configuration = control.configuration else {
            return ChartBounds(
                minimumVoltage: minimumVoltage,
                maximumVoltage: maximumVoltage,
                safetyMargin: voltageSafetyMargin,
                maximumImportKw: maximumImportKw,
                maximumExportKw: min(maximumExportKw, siteExportPermissionKw)
            )
        }
        let exportKw = (configuration.maximumExportW ?? maximumExportKw * 1_000) / 1_000
        let permissionKw = (configuration.siteExportPermissionW ?? siteExportPermissionKw * 1_000) / 1_000
        return ChartBounds(
            minimumVoltage: configuration.minimumVoltageV ?? minimumVoltage,
            maximumVoltage: configuration.maximumVoltageV ?? maximumVoltage,
            safetyMargin: configuration.safetyMarginV ?? voltageSafetyMargin,
            maximumImportKw: (configuration.maximumImportW ?? maximumImportKw * 1_000) / 1_000,
            maximumExportKw: min(exportKw, permissionKw)
        )
    }

    /// Direct mode, a hub is on the network and nobody has decided yet: the
    /// local poller is held back until they do.
    @ViewBuilder
    private var hubDetectedBanners: some View {
        let mode: ConnectionMode = monitor.policy.mode
        let warning: String? = monitor.discoveryWarning
        if mode == .direct {
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(monitor.policy.blockingHubs) { hub in
                VStack(alignment: .leading, spacing: 6) {
                    Label("A solis-hub (\(hub.name)) is on this network", systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "Only one controller may talk to the inverter. This Mac will not start or "
                            + "restart its own poller until you choose."
                    )
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Switch to Hub") {
                            if !monitor.switchToHub() {
                                pendingMode = .hub
                                showingSettings = true
                            }
                        }
                        Button("Ignore for this hub ID") {
                            monitor.ignoreHub(id: hub.id)
                        }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    /// Hub mode: unreachable, or reachable with its poller restarting. The
    /// last data stays below with its age; this app never starts its own
    /// poller to fill the gap.
    @ViewBuilder
    private var hubStatusBanner: some View {
        if isHubMode, let message = hubBannerMessage, !showingSettings {
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let received = monitor.lastEnvelopeAt {
                    HStack(spacing: 4) {
                        Text("Showing data from")
                        Text(received, style: .relative)
                        Text("ago")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var hubBannerMessage: String? {
        if let detail = monitor.statusDetail {
            return detail
        }
        if case let .failed(message) = monitor.state {
            return message
        }
        return nil
    }

    @ViewBuilder
    private var ignoredHubsList: some View {
        let ignored: [String] = monitor.policy.ignoredHubIDs.sorted()
        if !ignored.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ignored hubs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ignored, id: \.self) { id in
                    HStack {
                        Text(id)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Stop ignoring") {
                            monitor.stopIgnoringHub(id: id)
                        }
                        .font(.caption)
                    }
                }
            }
            Divider()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: monitor.menuSymbol)
                .foregroundStyle(statusColour)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Solis Live")
                    .font(.headline)
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "xmark" : "gearshape")
            }
            .buttonStyle(.plain)
            .help(showingSettings ? "Close settings" : "Settings")
        }
        .padding(14)
    }

    @ViewBuilder
    private func status(_ sample: StreamEnvelope) -> some View {
        HStack {
            Label(sample.reading.inverterStatus, systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(verbatim: "Model \(sample.device.modelCode)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let error = sample.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metrics(_ reading: InverterReading, control: VoltageControlDetails?) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            MetricCard(
                title: "House load",
                value: String(format: "%.2f kW", reading.houseLoadKw),
                detail: "Current demand",
                symbol: "house.fill",
                colour: .purple
            )
            MetricCard(
                title: "Battery",
                value: "\(reading.batterySocPercent)%",
                detail: String(format: "%@ %.2f kW", reading.batteryStatus, reading.batteryKw),
                symbol: batterySymbol(reading.batterySocPercent),
                colour: reading.batteryStatus == "Charging" ? .blue : .green
            )
            MetricCard(
                title: "Grid",
                value: String(format: "%+.2f kW", reading.gridImportPositiveKw),
                detail: reading.gridStatus,
                symbol: "bolt.horizontal.fill",
                colour: reading.gridStatus == "Exporting" ? .cyan : .orange
            )
            MetricCard(
                title: "Inverter",
                value: String(format: "%.1f °C", reading.inverterTemperatureC),
                detail: String(
                    format: "PCC %.1f V",
                    reading.meterVoltageV ?? reading.gridVoltageV
                ),
                symbol: "thermometer.medium",
                colour: .yellow
            )
            if pvEnabled, let pv = reading.pvKw {
                MetricCard(
                    title: "PV",
                    value: String(format: "%.2f kW", pv),
                    detail: String(format: "Today %.1f kWh", reading.pvTodayKwh ?? 0),
                    symbol: "sun.max.fill",
                    colour: .green
                )
            }
            if let control, let charger = control.hypervoltActuator {
                MetricCard(
                    title: "EV charger",
                    value: Self.evValue(charger, charging: control.evCharging == true),
                    detail: Self.evDetail(charger, charging: control.evCharging == true),
                    symbol: "bolt.car.fill",
                    colour: control.evCharging == true ? .blue : .gray
                )
            }
        }
    }

    /// The charging rate the car is actually drawing. The commanded current
    /// is only a cap, so it belongs in the detail line, not the headline.
    private static func evValue(_ charger: HypervoltActuatorDetails, charging: Bool) -> String {
        guard charger.connected else { return "Offline" }
        guard charging else { return "Not charging" }
        if let power = charger.chargingPowerKw {
            return String(format: "%.2f kW", power)
        }
        if let current = charger.measuredCurrentA {
            return String(format: "%.1f A", current)
        }
        return "Charging"
    }

    private static func evDetail(_ charger: HypervoltActuatorDetails, charging: Bool) -> String {
        let limit = String(format: "limit %.0f A", charger.commandedCurrentA)
        if let age = charger.telemetryAgeS, age > 30 {
            return String(format: "No update for %.0f s · %@", age, limit)
        }
        guard charging else { return String(format: "Limit %.0f A", charger.commandedCurrentA) }
        var parts: [String] = []
        if let current = charger.measuredCurrentA {
            parts.append(String(format: "%.1f A", current))
        }
        parts.append(limit)
        if let energy = charger.sessionEnergyKwh {
            parts.append(String(format: "%.1f kWh", energy))
        }
        return parts.joined(separator: " · ")
    }

    /// When the next Octopus slot is, what it does to the voltage band, and
    /// when the band goes back, outside the collapsed diagnostics.
    private func octopusPlan(_ schedule: OctopusScheduleDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Intelligent Octopus", systemImage: "calendar.badge.clock")
                    .font(.headline)
                Spacer()
                Text(schedule.chargeWindowActive ? "Charge slot active" : "Waiting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(schedule.chargeWindowActive ? .green : .secondary)
            }
            ForEach(schedule.summaryLines(now: Date()), id: \.self) { line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            if let error = schedule.lastError {
                Text("Octopus: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func voltageControlStatus(
        _ control: VoltageControlDetails,
        reading: InverterReading
    ) -> some View {
        let activeActuator = control.mode == "export"
            ? control.exportActuator : control.importActuator
        let limitLabel = control.mode.map { "\($0.capitalized) limit" } ?? "Limit"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Dynamic voltage control", systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
                Spacer()
                Text(control.state)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(control.emergency ? .red : .secondary)
            }
            HStack {
                controlValue(
                    "PCC voltage",
                    control.rawVoltageV.map { String(format: "%.1f V", $0) } ?? "—"
                )
                controlValue(
                    "Filtered",
                    control.filteredVoltageV.map { String(format: "%.1f V", $0) } ?? "—"
                )
                controlValue("Grid", String(format: "%+.2f kW", reading.gridImportPositiveKw))
                controlValue(
                    limitLabel,
                    activeActuator.commandedW.map {
                        String(format: "%.1f kW", Double($0) / 1000)
                    } ?? "—"
                )
            }
            Text("\(control.action) · \(control.reason)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = control.recoveryNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            DisclosureGroup("Diagnostics and activity") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(control.voltageSource)
                    if let device = monitor.latest?.device,
                       let supported = device.remoteDispatchSupported {
                        Text(
                            "Remote Dispatch: \(supported ? "supported" : "not reported")"
                                + (device.remoteDispatchVersion.map { " · v\($0)" } ?? "")
                                + " · not used"
                        )
                    }
                    Text("Import actuator PDU \(control.importActuator.pduAddress) · FC03/FC06")
                    Text("Writes in last hour: \(control.importActuator.writesLastHour)")
                    if let total = control.importActuator.totalWriteCount {
                        Text("Writes this process: \(total)")
                    }
                    if let sensitivity = control.estimatedVoltageSensitivityVPerKw {
                        Text(String(format: "Recent sensitivity: %.2f V/kW", sensitivity))
                    }
                    if let ceiling = control.importDemandCeilingW {
                        Text(
                            String(
                                format: "Import session ceiling: %.1f kW",
                                Double(ceiling) / 1_000
                            )
                        )
                    }
                    if let summary = control.dailySummary {
                        Text(
                            String(
                                format: "Today: %.0f min import regulation · %.1f–%.1f V · %d emergencies",
                                summary.importRegulatingS / 60,
                                summary.lowestVoltageV,
                                summary.highestVoltageV,
                                summary.emergencyInterventions
                            )
                        )
                    }
                    if let hypervolt = control.hypervoltActuator {
                        Text(evDiagnosticsLine(control, hypervolt))
                        if let error = hypervolt.lastError {
                            Text(error).foregroundStyle(.orange)
                        }
                    }
                    if control.evVoltageLimitsActive == true,
                        let minimum = control.effectiveMinimumVoltageV,
                        let maximum = control.effectiveMaximumVoltageV
                    {
                        Text(String(format: "Holding %.0f–%.0f V for the EV charger", minimum, maximum))
                            .foregroundStyle(.green)
                    }
                    let events = control.recentEvents ?? []
                    if !events.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text("Recent activity")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    ForEach(events.prefix(8)) { event in
                        VoltageControlEventRow(event: event)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(
            (control.emergency ? Color.red : Color.cyan).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func controlValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func evDiagnosticsLine(
        _ control: VoltageControlDetails,
        _ hypervolt: HypervoltActuatorDetails
    ) -> String {
        // Built in steps: one concatenated expression was too slow for the
        // Swift type checker and failed the build.
        var parts: [String] = []
        parts.append("EV charging: " + (control.evCharging == true ? "yes" : "no"))
        parts.append("protecting " + evPriorityLabel(control.evPriority))
        if let drawn = hypervolt.measuredCurrentA {
            parts.append(String(format: "%.1f A drawn", drawn))
        }
        parts.append(String(format: "%.1f A limit", hypervolt.commandedCurrentA))
        return parts.joined(separator: " · ")
    }

    private func evPriorityLabel(_ priority: String?) -> String {
        switch priority {
        case "battery": "battery charging"
        case "ev": "EV charging"
        case "balanced": "both, balanced"
        default: "unknown"
        }
    }

    private var history: some View {
        HistoryChartView(
            history: monitor.history,
            pvEnabled: pvEnabled,
            selectedMetric: $selectedMetric
        )
    }

    @ViewBuilder
    private func alarms(_ alarms: [InverterAlarm]) -> some View {
        if !alarms.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Active alarms", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                ForEach(alarms) { alarm in
                    Text("\(alarm.code) · \(alarm.message)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func connection(_ sample: StreamEnvelope) -> some View {
        HStack {
            Label(String(format: "%.0f ms", sample.health.latencyMs), systemImage: "network")
            Spacer()
            Text(verbatim: connectionSummary(sample.health))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func connectionSummary(_ health: ConnectionDetails) -> String {
        var summary = "Failures \(health.totalFailures) · reconnects \(health.reconnects)"
        if let rejected = health.rejectedSamples, rejected > 0 {
            summary += " · rejected \(rejected)"
        }
        return summary
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            PlaceholderView(
                title: "Connecting",
                message: waitingMessage,
                symbol: "network"
            )
            Button("Retry") {
                connect()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 410)
    }

    private var waitingMessage: String {
        if case let .failed(message) = monitor.state {
            return message
        }
        if isHubMode {
            return "Waiting for the first reading from the hub."
        }
        return "Waiting for the first inverter reading from \(host)."
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectionModePicker
            if pendingMode == .hub {
                hubSettingsForm
            } else {
                directSettings
            }
        }
        .confirmationDialog(
            "Switch to Direct mode?",
            isPresented: $confirmingDirectSwitch,
            titleVisibility: .visible
        ) {
            Button("The hub service is stopped. Switch to Direct", role: .destructive) {
                monitor.switchToDirect(hubServiceConfirmedStopped: true)
                showingSettings = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The logger accepts one connection, so this Mac and the hub must never both control "
                    + "it. Stop solis-hub on the hub first and wait for it to finish. This Mac will "
                    + "then stop watching for that hub's advertisement."
            )
        }
    }

    private var connectionModePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection mode")
                .font(.headline)
            Picker("Mode", selection: $pendingMode) {
                ForEach(ConnectionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(
                "Direct runs the poller on this Mac. Hub watches a solis-hub that runs it for you; "
                    + "this Mac then never talks to the inverter."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Hub mode: where the hub is, and the controller settings it is running,
    /// shown read-only. Display preferences stay editable.
    private var hubSettingsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HubSettingsSection(model: hubSettings)
            Divider()
            HubControlSummary(configuration: monitor.latest?.voltageControl?.configuration)
            Divider()
            Text("Hypervolt and Octopus")
                .font(.headline)
            Text(
                "Sign in on the hub: run hypervolt-login and octopus-login there. The hub keeps "
                    + "those credentials; this app never sees them."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            Text("Display")
                .font(.headline)
            Toggle("Show PV figures", isOn: $pvEnabled)
            Divider()
            menuBarMetricsSettings
            HStack {
                Button("Save and connect") {
                    saveAndConnectToHub()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hubSettings.isComplete)
                if monitor.isRunning {
                    Button("Disconnect") {
                        monitor.stop()
                    }
                }
            }
            if !isHubMode {
                Text("Switching to Hub stops this Mac's own poller first and waits for it to restore the inverter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveAndConnectToHub() {
        guard hubSettings.save() else { return }
        if isHubMode {
            monitor.startHub()
        } else {
            monitor.switchToHub()
        }
        showingSettings = false
    }

    @ViewBuilder
    private var menuBarMetricsSettings: some View {
        Text("Menu bar metrics")
            .font(.headline)
        Toggle("House load", isOn: $showHouseLoad)
        Toggle("Battery state of charge", isOn: $showBattery)
        Toggle("Grid flow", isOn: $showGrid)
        Toggle("Inverter temperature", isOn: $showTemperature)
        Toggle("PV generation", isOn: $showPV)
            .disabled(!pvEnabled)
        Text("Choose the live values shown without opening the dashboard.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var directSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            ignoredHubsList
            Text("Connection")
                .font(.headline)
            LabeledContent("Logger IP") {
                TextField("192.168.1.57", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
            }
            HStack {
                LabeledContent("Port") {
                    TextField("502", value: $port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                Spacer()
                LabeledContent("Slave") {
                    TextField("1", value: $slave, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                }
            }

            Divider()
            Text("Polling and scale")
                .font(.headline)
            LabeledContent("Refresh") {
                TextField("1.0", value: $pollInterval, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("seconds").foregroundStyle(.secondary)
            }
            LabeledContent("Status refresh") {
                TextField("10", value: $slowInterval, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("seconds").foregroundStyle(.secondary)
            }
            LabeledContent("Idle refresh") {
                TextField("5", value: $idlePollInterval, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("seconds, while closed and idle").foregroundStyle(.secondary)
            }
            LabeledContent("Inverter maximum") {
                TextField("10", value: $inverterMaxKw, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("kW").foregroundStyle(.secondary)
            }
            LabeledContent("Grid maximum") {
                TextField("23", value: $gridMaxKw, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("kW").foregroundStyle(.secondary)
            }
            Toggle("Enable PV registers", isOn: $pvEnabled)

            Divider()
            Text("Dynamic grid voltage control")
                .font(.headline)
            Toggle("Enable dynamic control", isOn: $dynamicVoltageEnabled)
            Toggle("Enable import regulation", isOn: $dynamicImportEnabled)
                .disabled(!dynamicVoltageEnabled)
            Toggle("Enable export regulation", isOn: $dynamicExportEnabled)
                .disabled(
                    !dynamicVoltageEnabled
                        || !monitor.exportControlValidated(host: host, port: port, slave: slave)
                )
            Text(exportValidationMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                numericSetting("Minimum voltage", value: $minimumVoltage, unit: "V")
                numericSetting("Maximum voltage", value: $maximumVoltage, unit: "V")
                numericSetting("Maximum import", value: $maximumImportKw, unit: "kW")
                numericSetting("Import demand headroom", value: $importHeadroomKw, unit: "kW")
                numericSetting("Maximum export", value: $maximumExportKw, unit: "kW")
                numericSetting("Site export permission", value: $siteExportPermissionKw, unit: "kW")
            }
            .disabled(!dynamicVoltageEnabled)
            DisclosureGroup("Advanced control behaviour") {
                VStack(spacing: 8) {
                    numericSetting("Safety margin", value: $voltageSafetyMargin, unit: "V")
                    numericSetting("Deadband", value: $voltageDeadband, unit: "V")
                    integerSetting("Increase step", value: $increaseStepW, unit: "W")
                    integerSetting("Reduction step", value: $reductionStepW, unit: "W")
                    integerSetting("Near-limit reduction", value: $nearLimitReductionW, unit: "W")
                    integerSetting("Emergency reduction", value: $emergencyReductionW, unit: "W")
                    numericSetting("Settle time", value: $controlSettleTime, unit: "s")
                    numericSetting("Activation delay", value: $controlActivationDelay, unit: "s")
                    numericSetting("Deactivation delay", value: $controlDeactivationDelay, unit: "s")
                    numericSetting("Import activation", value: $importActivationKw, unit: "kW")
                    numericSetting("Export activation", value: $exportActivationKw, unit: "kW")
                    numericSetting("Minimum write interval", value: $minimumWriteInterval, unit: "s")
                }
                .padding(.top, 6)
            }
            .disabled(!dynamicVoltageEnabled)

            Divider()
            Text("Hypervolt EV charger priority")
                .font(.headline)
            Toggle("Arbitrate priority with a Hypervolt charger", isOn: $hypervoltEnabled)
                .disabled(!dynamicVoltageEnabled)
            Picker("Protect", selection: $evPriority) {
                Text("Battery charging").tag("battery")
                Text("EV charging").tag("ev")
                Text("Balanced").tag("balanced")
            }
            .disabled(!dynamicVoltageEnabled || !hypervoltEnabled)
            LabeledContent("Credentials file") {
                TextField("default: state directory/hypervolt.json", text: $hypervoltCredentialsPath)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(!dynamicVoltageEnabled || !hypervoltEnabled)
            if isHubMode {
                Text("While a hub is the controller, sign in to Hypervolt on the hub with hypervolt-login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                hypervoltSignIn
                    .disabled(!dynamicVoltageEnabled || !hypervoltEnabled)
            }
            Text(
                "Whichever side is not protected is trimmed first to hold voltage, then "
                    + "restored first once headroom returns."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
            Text("Intelligent Octopus charge windows")
                .font(.headline)
            Toggle("Hold the EV charger's voltage limits during planned charges", isOn: $octopusEnabled)
                .disabled(!dynamicVoltageEnabled)
            LabeledContent("Credentials file") {
                TextField("default: state directory/octopus.json", text: $octopusCredentialsPath)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(!dynamicVoltageEnabled || !octopusEnabled)
            if isHubMode {
                Text("While a hub is the controller, sign in to Octopus on the hub with octopus-login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                octopusSignIn
                    .disabled(!dynamicVoltageEnabled || !octopusEnabled)
            }
            Text(
                "From five minutes before each planned charge until it ends, voltage is held inside "
                    + "Hypervolt's 207–253 V trip limits; the normal limits return afterwards."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
            menuBarMetricsSettings

            HStack {
                Button("Save and connect") {
                    if isHubMode {
                        // Leaving Hub mode is never automatic.
                        confirmingDirectSwitch = true
                    } else {
                        showingSettings = false
                        connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    host.trimmingCharacters(in: .whitespaces).isEmpty
                        || minimumVoltage >= maximumVoltage
                        || minimumWriteInterval < 5
                )
                if monitor.isRunning {
                    Button("Disconnect") {
                        monitor.stop()
                    }
                }
            }
            Text("The IP address is stored only in your macOS user preferences.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var octopusCredentialsResolvedPath: String {
        octopusCredentialsPath.isEmpty
            ? MonitorConfiguration.defaultOctopusCredentialsPath : octopusCredentialsPath
    }

    @ViewBuilder
    private var octopusSignIn: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let account = octopusAccountNumber {
                Label("Signed in to Octopus account \(account)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("Not signed in to Octopus yet", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SecureField("Octopus API key (sk_live_…)", text: $octopusAPIKey)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Account number (optional)", text: $octopusAccountField)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                TextField("Device ID (optional)", text: $octopusDeviceField)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
            HStack(spacing: 8) {
                Button("Sign in to Octopus") {
                    signInToOctopus()
                }
                .disabled(
                    octopusAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || octopusLogin.outcome == .running
                )
                if octopusLogin.outcome == .running {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if let apiAccess = URL(
                    string: "https://octopus.energy/dashboard/new/accounts/personal-details/api-access"
                ) {
                    Link("Find your API key", destination: apiAccess)
                        .font(.caption)
                }
            }
            if case let .succeeded(message) = octopusLogin.outcome {
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if case let .failed(message) = octopusLogin.outcome {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(
                "The account and your car or charger are found automatically; fill in the account "
                    + "number or device ID only if Octopus reports more than one. The key is checked "
                    + "with Octopus and saved only to the credentials file above, at owner-only "
                    + "permissions; this app never stores it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // Read the file when settings open, the path changes or a sign-in
        // completes, not on every redraw of the settings form.
        .task(id: "\(octopusCredentialsResolvedPath)#\(octopusLogin.completedSignIns)") {
            octopusAccountNumber = Self.octopusAccount(at: octopusCredentialsResolvedPath)
        }
    }

    private func signInToOctopus() {
        octopusLogin.signIn(
            apiKey: octopusAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            accountNumber: octopusAccountField.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceID: octopusDeviceField.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialsPath: octopusCredentialsResolvedPath
        )
        octopusAPIKey = ""
    }

    private static func octopusAccount(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = json["account_number"] as? String, !account.isEmpty
        else { return nil }
        return account
    }

    private var hypervoltCredentialsResolvedPath: String {
        hypervoltCredentialsPath.isEmpty
            ? MonitorConfiguration.defaultHypervoltCredentialsPath : hypervoltCredentialsPath
    }

    private var hypervoltAccountChargerID: String? {
        guard let data = FileManager.default.contents(atPath: hypervoltCredentialsResolvedPath),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let chargerID = json["charger_id"] as? String, !chargerID.isEmpty
        else { return nil }
        return chargerID
    }

    @ViewBuilder
    private var hypervoltSignIn: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let chargerID = hypervoltAccountChargerID {
                Label("Signed in — charger \(chargerID)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("Not signed in to Hypervolt yet", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Hypervolt account email", text: $hypervoltEmail)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            SecureField("Hypervolt account password", text: $hypervoltPassword)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Sign in to Hypervolt") {
                    signInToHypervolt()
                }
                .disabled(
                    hypervoltEmail.trimmingCharacters(in: .whitespaces).isEmpty
                        || hypervoltPassword.isEmpty
                        || hypervoltLogin.outcome == .running
                )
                if hypervoltLogin.outcome == .running {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if case let .succeeded(message) = hypervoltLogin.outcome {
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if case let .failed(message) = hypervoltLogin.outcome {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(
                "The password is sent once to Hypervolt to obtain a refresh token and is "
                    + "never stored; only that token is saved to the credentials file above, "
                    + "at owner-only permissions."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func signInToHypervolt() {
        hypervoltLogin.signIn(
            email: hypervoltEmail.trimmingCharacters(in: .whitespaces),
            password: hypervoltPassword,
            credentialsPath: hypervoltCredentialsResolvedPath
        )
        hypervoltPassword = ""
    }

    private func numericSetting(
        _ label: String,
        value: Binding<Double>,
        unit: String
    ) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 75)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func integerSetting(
        _ label: String,
        value: Binding<Int>,
        unit: String
    ) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 75)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if let message = monitor.shutdownMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            // The path is left over from the last Direct run; in Hub mode no
            // local poller exists to name.
            if !isHubMode, let path = monitor.executablePath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") {
                Task {
                    if await monitor.stopForApplicationTermination() {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    private var connectionLabel: String {
        if isHubMode {
            return hubConnectionLabel
        }
        switch monitor.state {
        case .stopped: return host.isEmpty ? "Setup required" : "Stopped"
        case .connecting: return "Connecting to \(host)"
        case .connected: return "Connected to \(host)"
        case .degraded: return "Connection degraded"
        case .failed: return "Connection failed"
        }
    }

    private var hubConnectionLabel: String {
        let link: HubLinkInfo? = monitor.hubLink
        let route: String = link?.endpointKind.map { " via \($0.label)" } ?? ""
        switch monitor.state {
        case .stopped: return needsSetup ? "Setup required" : "Stopped"
        case .connecting: return "Connecting to hub"
        case .connected: return "Connected to hub\(route)"
        case .degraded:
            let detail: String? = monitor.statusDetail
            return detail ?? "Connection degraded"
        case .failed: return "Hub unreachable, retrying"
        }
    }

    private var exportValidationMessage: String {
        if monitor.exportControlValidated(host: host, port: port, slave: slave) {
            return "Export register 43074 is validated for this inverter."
        }
        return "Enable dynamic control and connect to check this inverter's export validation."
    }

    private var statusColour: Color {
        switch monitor.state {
        case .connected: .green
        case .connecting: .yellow
        case .degraded, .failed: .orange
        case .stopped: .secondary
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case 76...: "battery.100percent"
        case 51...: "battery.75percent"
        case 26...: "battery.50percent"
        case 11...: "battery.25percent"
        default: "battery.0percent"
        }
    }

    private func connect() {
        if isHubMode {
            monitor.startHub()
            return
        }
        // @AppStorage has already written these, so read them back the same way
        // the launch path does rather than assembling a second copy here.
        guard let configuration = MonitorConfiguration.stored() else { return }
        monitor.start(configuration: configuration)
    }
}

private struct VoltageControlEventRow: View {
    let event: VoltageControlEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.timeLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(event.changeLabel)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            Text("\(event.action) · \(event.message)")
                .foregroundStyle(event.action == "Emergency" ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let voltage = event.voltageV {
                    Text(String(format: "PCC %.1f V", voltage))
                }
                if let grid = event.gridKw {
                    Text(String(format: "Grid %+.2f kW", -grid))
                }
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

private struct VoltageControlChartView: View {
    enum TimeRange: String, CaseIterable, Identifiable {
        case fifteenMinutes = "15m"
        case oneHour = "1h"
        case sixHours = "6h"
        case oneDay = "24h"

        var id: Self { self }

        var seconds: TimeInterval {
            switch self {
            case .fifteenMinutes: 15 * 60
            case .oneHour: 60 * 60
            case .sixHours: 6 * 60 * 60
            case .oneDay: 24 * 60 * 60
            }
        }
    }

    let liveHistory: [HistoryPoint]
    let longHistory: [HistoryPoint]
    let minimumVoltage: Double
    let maximumVoltage: Double
    let safetyMargin: Double
    let maximumImportKw: Double
    let maximumExportKw: Double
    @State private var timeRange: TimeRange = .fifteenMinutes
    @State private var hoveredVoltageDate: Date?
    @State private var hoveredPowerDate: Date?

    private var points: [HistoryPoint] {
        let source = timeRange == .fifteenMinutes ? liveHistory : longHistory
        guard let latest = source.last?.date else { return [] }
        let cutoff = latest.addingTimeInterval(-timeRange.seconds)
        return source.filter { $0.date >= cutoff && $0.meterVoltageV != nil }
    }

    var body: some View {
        let allPoints = points
        let renderedPoints = chartSamples(allPoints, maximumCount: 360)
        let latestPoint = allPoints.last
        let hoveredVoltagePoint = nearestPoint(in: allPoints, to: hoveredVoltageDate)
        let hoveredPowerPoint = nearestPoint(in: allPoints, to: hoveredPowerDate)
        let notablePoints = chartSamples(
            allPoints.filter {
                $0.controlEmergency
                    || $0.controlAction == "Increasing"
                    || $0.controlAction == "Reducing"
            },
            maximumCount: 120
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Voltage control").font(.headline)
                Spacer()
                Picker("Range", selection: $timeRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            HStack(spacing: 12) {
                ChartKey(colour: .cyan, label: "PCC voltage")
                ChartKey(colour: .orange, label: "Operating targets", dashed: true)
                ChartKey(colour: .red, label: "Hard limits", dashed: true)
            }
            Text(
                String(
                    format: "Target band %.1f–%.1f V · hard limits %.1f–%.1f V",
                    minimumVoltage + safetyMargin,
                    maximumVoltage - safetyMargin,
                    minimumVoltage,
                    maximumVoltage
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            Chart {
                if let point = hoveredVoltagePoint,
                   let voltage = point.meterVoltageV {
                    RuleMark(x: .value("Selected time", point.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 4) {
                            ChartTooltip(
                                title: point.date.formatted(date: .omitted, time: .standard),
                                lines: [String(format: "PCC voltage %.2f V", voltage)]
                            )
                        }
                }
                ForEach(renderedPoints) { point in
                    if let voltage = point.meterVoltageV {
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("PCC voltage", voltage)
                        )
                        .foregroundStyle(.cyan)
                        .interpolationMethod(.linear)
                    }
                }
                if let point = latestPoint, let voltage = point.meterVoltageV {
                    PointMark(
                        x: .value("Latest time", point.date),
                        y: .value("Latest PCC voltage", voltage)
                    )
                    .foregroundStyle(.cyan)
                    .annotation(position: .topTrailing) {
                        Text(String(format: "Now %.1f V", voltage))
                            .font(.caption2.weight(.medium))
                    }
                }
                RuleMark(y: .value("Minimum", minimumVoltage))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(y: .value("Import target", minimumVoltage + safetyMargin))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(y: .value("Export target", maximumVoltage - safetyMargin))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(y: .value("Maximum", maximumVoltage))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartYScale(domain: voltageDomain(allPoints))
            .chartYAxisLabel("V")
            .chartXAxis { timeAxis }
            .chartOverlay { proxy in
                hoverOverlay(proxy: proxy, points: allPoints, selection: $hoveredVoltageDate)
            }
            .frame(height: 145)

            HStack(spacing: 12) {
                ChartKey(colour: .orange, label: "Grid flow")
                ChartKey(colour: .blue, label: "Active limit")
                ChartKey(colour: .red, label: "Emergency", point: true)
            }
            Text(
                String(
                    format: "Positive = import · negative = export · configured bounds +%.1f/−%.1f kW",
                    maximumImportKw,
                    maximumExportKw
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            Chart {
                if let point = hoveredPowerPoint {
                    RuleMark(x: .value("Selected time", point.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 4) {
                            ChartTooltip(
                                title: point.date.formatted(date: .omitted, time: .standard),
                                lines: powerTooltipLines(point)
                            )
                        }
                }
                ForEach(renderedPoints) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Grid flow", point.gridImportPositiveKw),
                        series: .value("Series", "Grid flow")
                    )
                    .foregroundStyle(.orange)
                    if let limit = signedControlLimit(point) {
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Active limit", limit),
                            series: .value("Series", "Active limit")
                        )
                        .foregroundStyle(.blue)
                    }
                }
                ForEach(notablePoints) { point in
                    if point.controlEmergency {
                        PointMark(
                            x: .value("Emergency", point.date),
                            y: .value("Grid import", point.gridImportPositiveKw)
                        )
                        .foregroundStyle(.red)
                        .symbolSize(36)
                    } else if point.controlAction == "Increasing" {
                        PointMark(
                            x: .value("Increasing", point.date),
                            y: .value("Grid import", point.gridImportPositiveKw)
                        )
                        .foregroundStyle(.green)
                        .symbolSize(12)
                    } else if point.controlAction == "Reducing" {
                        PointMark(
                            x: .value("Reducing", point.date),
                            y: .value("Grid import", point.gridImportPositiveKw)
                        )
                        .foregroundStyle(.orange)
                        .symbolSize(18)
                    }
                }
                if let point = latestPoint {
                    PointMark(
                        x: .value("Latest time", point.date),
                        y: .value("Latest grid flow", point.gridImportPositiveKw)
                    )
                    .foregroundStyle(.orange)
                    .annotation(position: .topTrailing) {
                        Text(
                            String(
                                format: "Now %+.2f kW",
                                point.gridImportPositiveKw
                            )
                        )
                        .font(.caption2.weight(.medium))
                    }
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.35))
            }
            .chartYScale(domain: powerDomain(allPoints))
            .chartYAxisLabel("kW")
            .chartXAxis { timeAxis }
            .chartOverlay { proxy in
                hoverOverlay(proxy: proxy, points: allPoints, selection: $hoveredPowerDate)
            }
            .frame(height: 145)
        }
    }

    @AxisContentBuilder
    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) {
            AxisGridLine()
            AxisValueLabel(format: timeRange == .oneDay ? .dateTime.hour() : .dateTime.hour().minute())
        }
    }

    private func voltageDomain(_ points: [HistoryPoint]) -> ClosedRange<Double> {
        let values = points.compactMap(\.meterVoltageV)
        guard let low = values.min(), let high = values.max() else {
            return minimumVoltage...maximumVoltage
        }
        let middle = (minimumVoltage + maximumVoltage) / 2
        var anchors = values
        if low >= middle {
            anchors += [maximumVoltage - safetyMargin, maximumVoltage]
        } else if high <= middle {
            anchors += [minimumVoltage, minimumVoltage + safetyMargin]
        } else {
            anchors += [minimumVoltage, maximumVoltage]
        }
        return paddedDomain(anchors, minimumPadding: 0.4, includeZero: false)
    }

    private func powerDomain(_ points: [HistoryPoint]) -> ClosedRange<Double> {
        var values = points.map(\.gridImportPositiveKw)
        values += points.compactMap(signedControlLimit)
        return paddedDomain(values, minimumPadding: 0.25, includeZero: true)
    }

    private func signedControlLimit(_ point: HistoryPoint) -> Double? {
        let mode = point.controlMode ?? {
            if point.controlState?.contains("Export") == true { return "export" }
            if point.controlState?.contains("Import") == true
                || point.controlState?.contains("charging") == true {
                return "import"
            }
            return nil
        }()
        if mode == "export", let watts = point.exportLimitW {
            return -Double(watts) / 1_000
        }
        if mode == "import", let watts = point.importLimitW {
            return Double(watts) / 1_000
        }
        return nil
    }

    private func nearestPoint(in points: [HistoryPoint], to date: Date?) -> HistoryPoint? {
        guard let date else { return nil }
        return nearestSortedPoint(in: points, to: date, date: \.date)
    }

    private func powerTooltipLines(_ point: HistoryPoint) -> [String] {
        var lines = [String(format: "Grid flow %+.2f kW", point.gridImportPositiveKw)]
        if let limit = signedControlLimit(point) {
            lines.append(String(format: "Active limit %+.2f kW", limit))
        }
        if let action = point.controlAction, let reason = point.controlReason {
            lines.append("\(action) · \(reason)")
        }
        return lines
    }

    private func hoverOverlay(
        proxy: ChartProxy,
        points: [HistoryPoint],
        selection: Binding<Date?>
    ) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        let frame = geometry[proxy.plotAreaFrame]
                        guard frame.contains(location) else {
                            selection.wrappedValue = nil
                            return
                        }
                        let hovered: Date? = proxy.value(atX: location.x - frame.origin.x)
                        let snapped = nearestPoint(in: points, to: hovered)?.date
                        if selection.wrappedValue != snapped {
                            selection.wrappedValue = snapped
                        }
                    case .ended:
                        selection.wrappedValue = nil
                    }
                }
        }
    }

    private func paddedDomain(
        _ values: [Double], minimumPadding: Double, includeZero: Bool
    ) -> ClosedRange<Double> {
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        if includeZero {
            low = min(low, 0)
            high = max(high, 0)
        }
        let padding = max(minimumPadding, (high - low) * 0.12)
        return (low - padding)...(high + padding)
    }
}

private struct ChartKey: View {
    let colour: Color
    let label: String
    var dashed = false
    var point = false

    var body: some View {
        HStack(spacing: 4) {
            if point {
                Circle().fill(colour).frame(width: 7, height: 7)
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 4))
                    path.addLine(to: CGPoint(x: 14, y: 4))
                }
                .stroke(
                    colour,
                    style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : [])
                )
                .frame(width: 14, height: 8)
            }
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct ChartTooltip: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold).monospacedDigit()
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.caption2)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A chart only has a few hundred horizontal pixels. Keeping thousands of
/// marks makes every telemetry refresh expensive without adding visible detail.
func chartSamples<Element>(
    _ values: [Element], maximumCount: Int
) -> [Element] {
    guard maximumCount > 1, values.count > maximumCount else { return values }
    let scale = Double(values.count - 1) / Double(maximumCount - 1)
    return (0..<maximumCount).map { values[Int((Double($0) * scale).rounded())] }
}

private func nearestSortedPoint<Element>(
    in values: [Element],
    to target: Date,
    date dateKeyPath: KeyPath<Element, Date>
) -> Element? {
    guard !values.isEmpty else { return nil }
    var lower = 0
    var upper = values.count
    while lower < upper {
        let middle = (lower + upper) / 2
        if values[middle][keyPath: dateKeyPath] < target {
            lower = middle + 1
        } else {
            upper = middle
        }
    }
    if lower == 0 { return values[0] }
    if lower == values.count { return values[values.count - 1] }
    let before = values[lower - 1]
    let after = values[lower]
    return target.timeIntervalSince(before[keyPath: dateKeyPath])
            <= after[keyPath: dateKeyPath].timeIntervalSince(target)
        ? before : after
}

private struct HistoryChartView: View {
    let history: [HistoryPoint]
    let pvEnabled: Bool
    @Binding var selectedMetric: HistoryMetric
    @State private var hoveredDate: Date?

    var body: some View {
        let allPoints = chartPoints
        let renderedPoints = chartSamples(allPoints, maximumCount: 360)
        let latestPoint = allPoints.last
        let hoveredPoint = nearestPoint(in: allPoints, to: hoveredDate)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Text("Since launch · 24h max · 30s samples")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Picker("Metric", selection: metricSelection) {
                ForEach(availableMetrics) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if allPoints.isEmpty {
                PlaceholderView(
                    title: "Waiting for samples",
                    message: "History appears after the first successful polls.",
                    symbol: "chart.xyaxis.line"
                )
                .frame(height: 145)
            } else {
                HStack {
                    ChartKey(colour: metricColour, label: metric.rawValue)
                    Spacer()
                    Text(historyRangeLabel(allPoints))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Chart {
                    if let point = hoveredPoint {
                        RuleMark(x: .value("Selected time", point.date))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .annotation(position: .top, spacing: 4) {
                                ChartTooltip(
                                    title: point.date.formatted(
                                        date: .omitted, time: .standard
                                    ),
                                    lines: [
                                        String(format: "%.2f %@", point.value, metric.unit)
                                    ]
                                )
                            }
                    }
                    ForEach(renderedPoints) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value(metric.unit, point.value)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(metricColour)
                    }
                    if let point = latestPoint {
                        PointMark(
                            x: .value("Latest time", point.date),
                            y: .value("Latest value", point.value)
                        )
                        .foregroundStyle(metricColour)
                        .annotation(position: .topTrailing) {
                            Text(String(format: "%.1f %@", point.value, metric.unit))
                                .font(.caption2.weight(.medium))
                        }
                    }
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(.secondary.opacity(0.25))
                }
                .chartYScale(domain: yDomain(allPoints))
                .chartYAxisLabel(metric.unit)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine()
                        AxisValueLabel(format: axisTimeFormat(allPoints))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    let frame = geometry[proxy.plotAreaFrame]
                                    guard frame.contains(location) else {
                                        hoveredDate = nil
                                        return
                                    }
                                    let hovered: Date? = proxy.value(
                                        atX: location.x - frame.origin.x
                                    )
                                    let snapped = nearestPoint(
                                        in: allPoints, to: hovered
                                    )?.date
                                    if hoveredDate != snapped {
                                        hoveredDate = snapped
                                    }
                                case .ended:
                                    hoveredDate = nil
                                }
                            }
                    }
                }
                .frame(height: 155)
            }
        }
    }

    private var availableMetrics: [HistoryMetric] {
        pvEnabled ? HistoryMetric.allCases : HistoryMetric.allCases.filter { $0 != .pv }
    }

    /// The selection, falling back when it is no longer offered.
    ///
    /// Turning PV off left the stored selection on a metric the Picker no longer
    /// listed, which rendered it blank and emptied the chart.
    private var metric: HistoryMetric {
        availableMetrics.contains(selectedMetric) ? selectedMetric : .house
    }

    private var metricSelection: Binding<HistoryMetric> {
        Binding(get: { metric }, set: { selectedMetric = $0 })
    }

    private struct ChartPoint: Identifiable {
        let id: UUID
        let date: Date
        let value: Double
    }

    private var chartPoints: [ChartPoint] {
        history.compactMap { point in
            guard let value = metric.value(from: point) else { return nil }
            return ChartPoint(id: point.id, date: point.date, value: value)
        }
    }

    private func nearestPoint(in points: [ChartPoint], to date: Date?) -> ChartPoint? {
        guard let date else { return nil }
        return nearestSortedPoint(in: points, to: date, date: \.date)
    }

    /// Fit the observed values with useful headroom. Voltage and temperature
    /// must not be pulled down to zero, while power keeps zero visible so its
    /// direction remains obvious.
    private func yDomain(_ points: [ChartPoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        guard var low = values.min(), var high = values.max() else { return 0...1 }
        switch metric {
        case .house, .pv:
            low = 0
        case .battery, .grid:
            low = min(low, 0)
            high = max(high, 0)
        case .voltage, .temperature:
            break
        }
        let minimumPadding = metric == .voltage ? 0.5 : metric == .temperature ? 1 : 0.25
        let padding = max(minimumPadding, (high - low) * 0.12)
        let lower = metric == .house || metric == .pv ? 0 : low - padding
        return lower...max(high + padding, lower + minimumPadding * 2)
    }

    private func historyRangeLabel(_ points: [ChartPoint]) -> String {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max(), let latest = values.last else {
            return ""
        }
        return String(
            format: "%.1f–%.1f %@ · now %.1f %@",
            low, high, metric.unit, latest, metric.unit
        )
    }

    /// Hours and minutes repeat every tick until the window is minutes wide, so
    /// short spans need seconds to distinguish one tick from the next.
    private func axisTimeFormat(_ points: [ChartPoint]) -> Date.FormatStyle {
        guard let first = points.first?.date, let last = points.last?.date else {
            return .dateTime.hour().minute()
        }
        return last.timeIntervalSince(first) < 600
            ? .dateTime.hour().minute().second()
            : .dateTime.hour().minute()
    }

    private var metricColour: Color {
        switch metric {
        case .house: .purple
        case .battery: .blue
        case .grid: .orange
        case .voltage: .cyan
        case .temperature: .yellow
        case .pv: .green
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let colour: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(colour)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PlaceholderView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
