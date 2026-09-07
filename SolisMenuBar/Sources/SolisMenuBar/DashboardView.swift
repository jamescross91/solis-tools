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
                                maximumImportKw: maximumImportKw
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
        VStack(alignment: .leading, spacing: 8) {
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
                    "Limit",
                    control.importActuator.commandedW.map {
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
            DisclosureGroup("Diagnostics and recent events") {
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
                    ForEach(control.recentEvents.prefix(6)) { event in
                        Text("\(event.timestamp.suffix(8)) · \(event.message)")
                            .lineLimit(2)
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
            inverterMaxKw: inverterMaxKw,
            gridMaxKw: gridMaxKw,
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
    @State private var timeRange: TimeRange = .fifteenMinutes

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
            Chart {
                ForEach(points) { point in
                    if let voltage = point.reading.meterVoltageV {
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("PCC voltage", voltage)
                        )
                        .foregroundStyle(.cyan)
                        .interpolationMethod(.linear)
                    }
                }
                RuleMark(y: .value("Minimum", minimumVoltage)).foregroundStyle(.red)
                RuleMark(y: .value("Import target", minimumVoltage + safetyMargin))
                    .foregroundStyle(.orange.opacity(0.7))
                RuleMark(y: .value("Export target", maximumVoltage - safetyMargin))
                    .foregroundStyle(.orange.opacity(0.7))
                RuleMark(y: .value("Maximum", maximumVoltage)).foregroundStyle(.red)
            }
            .chartYAxisLabel("V")
            .frame(height: 120)

            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Grid import", point.reading.gridImportPositiveKw),
                        series: .value("Series", "Grid import")
                    )
                    .foregroundStyle(.orange)
                    if let watts = point.voltageControl?.importActuator.commandedW {
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Commanded limit", Double(watts) / 1000),
                            series: .value("Series", "Commanded limit")
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
                }
                RuleMark(y: .value("Maximum import", maximumImportKw))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .chartYAxisLabel("kW")
            .frame(height: 120)
        }
    }
}

private struct HistoryChartView: View {
    let history: [HistoryPoint]
    let pvEnabled: Bool
    let inverterMaxKw: Double
    let gridMaxKw: Double
    @Binding var selectedMetric: HistoryMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Chart(chartPoints) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(metric.unit, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(metricColour)
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

    /// The configured full scale, widened when a reading exceeds it so a spike is
    /// never clipped out of view.
    private var yDomain: ClosedRange<Double> {
        let values = chartPoints.map(\.value)
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 1, low + 0.1)
        guard let configured = metric.configuredRange(
            inverterMaxKw: inverterMaxKw,
            gridMaxKw: gridMaxKw
        ) else {
            return low...high
        }
        return min(configured.lowerBound, low)...max(configured.upperBound, high)
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
