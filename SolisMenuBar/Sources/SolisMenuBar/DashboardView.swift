import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var monitor: MonitorStore

    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = 502
    @AppStorage("slave") private var slave = 1
    @AppStorage("pollInterval") private var pollInterval = 2.0
    @AppStorage("slowInterval") private var slowInterval = 10.0
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

    @State private var showingSettings = false
    @State private var selectedMetric: HistoryMetric = .house

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showingSettings || host.isEmpty {
                        settings
                    } else if let sample = monitor.latest {
                        status(sample)
                        metrics(sample.reading)
                        if let control = sample.voltageControl {
                            voltageControlStatus(control, reading: sample.reading)
                            VoltageControlChartView(
                                liveHistory: monitor.controlHistory,
                                longHistory: monitor.history,
                                minimumVoltage: minimumVoltage,
                                maximumVoltage: maximumVoltage,
                                safetyMargin: voltageSafetyMargin,
                                maximumImportKw: maximumImportKw,
                                maximumExportKw: min(maximumExportKw, siteExportPermissionKw)
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
            if !host.isEmpty, !monitor.isRunning {
                connect()
            }
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

    private func metrics(_ reading: InverterReading) -> some View {
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
        }
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
                    if !control.recentEvents.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text("Recent activity")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    ForEach(control.recentEvents.prefix(8)) { event in
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
        return "Waiting for the first inverter reading from \(host)."
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            HStack {
                Button("Save and connect") {
                    showingSettings = false
                    connect()
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
            if let path = monitor.executablePath {
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
        switch monitor.state {
        case .stopped: host.isEmpty ? "Setup required" : "Stopped"
        case .connecting: "Connecting to \(host)"
        case .connected: "Connected to \(host)"
        case .degraded: "Connection degraded"
        case .failed: "Connection failed"
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
        return source.filter { $0.date >= cutoff && $0.reading.meterVoltageV != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                if let point = nearestPoint(to: hoveredVoltageDate),
                   let voltage = point.reading.meterVoltageV {
                    RuleMark(x: .value("Selected time", point.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 4) {
                            ChartTooltip(
                                title: point.date.formatted(date: .omitted, time: .standard),
                                lines: [String(format: "PCC voltage %.2f V", voltage)]
                            )
                        }
                }
                ForEach(points) { point in
                    if let voltage = point.reading.meterVoltageV {
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("PCC voltage", voltage)
                        )
                        .foregroundStyle(.cyan)
                        .interpolationMethod(.linear)
                        if point.id == points.last?.id {
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
            .chartYScale(domain: voltageDomain)
            .chartYAxisLabel("V")
            .chartXAxis { timeAxis }
            .chartOverlay { proxy in
                hoverOverlay(proxy: proxy, selection: $hoveredVoltageDate)
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
                if let point = nearestPoint(to: hoveredPowerDate) {
                    RuleMark(x: .value("Selected time", point.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 4) {
                            ChartTooltip(
                                title: point.date.formatted(date: .omitted, time: .standard),
                                lines: powerTooltipLines(point)
                            )
                        }
                }
                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Grid flow", point.reading.gridImportPositiveKw),
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
                    if point.voltageControl?.emergency == true {
                        PointMark(
                            x: .value("Emergency", point.date),
                            y: .value("Grid import", point.reading.gridImportPositiveKw)
                        )
                        .foregroundStyle(.red)
                        .symbolSize(36)
                    } else if point.voltageControl?.action == "Increasing" {
                        PointMark(
                            x: .value("Increasing", point.date),
                            y: .value("Grid import", point.reading.gridImportPositiveKw)
                        )
                        .foregroundStyle(.green)
                        .symbolSize(12)
                    } else if point.voltageControl?.action == "Reducing" {
                        PointMark(
                            x: .value("Reducing", point.date),
                            y: .value("Grid import", point.reading.gridImportPositiveKw)
                        )
                        .foregroundStyle(.orange)
                        .symbolSize(18)
                    }
                    if point.id == points.last?.id {
                        PointMark(
                            x: .value("Latest time", point.date),
                            y: .value("Latest grid flow", point.reading.gridImportPositiveKw)
                        )
                        .foregroundStyle(.orange)
                        .annotation(position: .topTrailing) {
                            Text(
                                String(
                                    format: "Now %+.2f kW",
                                    point.reading.gridImportPositiveKw
                                )
                            )
                            .font(.caption2.weight(.medium))
                        }
                    }
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.35))
            }
            .chartYScale(domain: powerDomain)
            .chartYAxisLabel("kW")
            .chartXAxis { timeAxis }
            .chartOverlay { proxy in
                hoverOverlay(proxy: proxy, selection: $hoveredPowerDate)
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

    private var voltageDomain: ClosedRange<Double> {
        let values = points.compactMap(\.reading.meterVoltageV)
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

    private var powerDomain: ClosedRange<Double> {
        var values = points.map { $0.reading.gridImportPositiveKw }
        values += points.compactMap(signedControlLimit)
        return paddedDomain(values, minimumPadding: 0.25, includeZero: true)
    }

    private func signedControlLimit(_ point: HistoryPoint) -> Double? {
        guard let control = point.voltageControl else { return nil }
        let mode = control.mode ?? {
            if control.state.contains("Export") { return "export" }
            if control.state.contains("Import") || control.state.contains("charging") {
                return "import"
            }
            return nil
        }()
        if mode == "export", let watts = control.exportActuator.commandedW {
            return -Double(watts) / 1_000
        }
        if mode == "import", let watts = control.importActuator.commandedW {
            return Double(watts) / 1_000
        }
        return nil
    }

    private func nearestPoint(to date: Date?) -> HistoryPoint? {
        guard let date else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    private func powerTooltipLines(_ point: HistoryPoint) -> [String] {
        var lines = [String(format: "Grid flow %+.2f kW", point.reading.gridImportPositiveKw)]
        if let limit = signedControlLimit(point) {
            lines.append(String(format: "Active limit %+.2f kW", limit))
        }
        if let control = point.voltageControl {
            lines.append("\(control.action) · \(control.reason)")
        }
        return lines
    }

    private func hoverOverlay(proxy: ChartProxy, selection: Binding<Date?>) -> some View {
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
                        selection.wrappedValue = proxy.value(atX: location.x - frame.origin.x)
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

private struct HistoryChartView: View {
    let history: [HistoryPoint]
    let pvEnabled: Bool
    @Binding var selectedMetric: HistoryMetric
    @State private var hoveredDate: Date?

    var body: some View {
        let latestID = chartPoints.last?.id
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

            if chartPoints.isEmpty {
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
                    Text(historyRangeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Chart {
                    if let point = nearestPoint(to: hoveredDate) {
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
                    ForEach(chartPoints) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value(metric.unit, point.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(metricColour)
                        if point.id == latestID {
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
                    }
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(.secondary.opacity(0.25))
                }
                .chartYScale(domain: yDomain)
                .chartYAxisLabel(metric.unit)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine()
                        AxisValueLabel(format: axisTimeFormat)
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
                                    hoveredDate = proxy.value(
                                        atX: location.x - frame.origin.x
                                    )
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
            guard let value = metric.value(from: point.reading) else { return nil }
            return ChartPoint(id: point.id, date: point.date, value: value)
        }
    }

    private func nearestPoint(to date: Date?) -> ChartPoint? {
        guard let date else { return nil }
        return chartPoints.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    /// Fit the observed values with useful headroom. Voltage and temperature
    /// must not be pulled down to zero, while power keeps zero visible so its
    /// direction remains obvious.
    private var yDomain: ClosedRange<Double> {
        let values = chartPoints.map(\.value)
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

    private var historyRangeLabel: String {
        let values = chartPoints.map(\.value)
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
    private var axisTimeFormat: Date.FormatStyle {
        guard let first = chartPoints.first?.date, let last = chartPoints.last?.date else {
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
