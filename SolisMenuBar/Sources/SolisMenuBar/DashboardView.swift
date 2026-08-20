import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var monitor: MonitorStore

    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = 502
    @AppStorage("slave") private var slave = 1
    @AppStorage("pollInterval") private var pollInterval = 1.0
    @AppStorage("slowInterval") private var slowInterval = 10.0
    @AppStorage("inverterMaxKw") private var inverterMaxKw = 10.0
    @AppStorage("gridMaxKw") private var gridMaxKw = 23.0
    @AppStorage("pvEnabled") private var pvEnabled = false
    @AppStorage("menuBarHouseLoad") private var showHouseLoad = true
    @AppStorage("menuBarBattery") private var showBattery = true
    @AppStorage("menuBarGrid") private var showGrid = true
    @AppStorage("menuBarTemperature") private var showTemperature = false
    @AppStorage("menuBarPV") private var showPV = false

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
        .frame(width: 410, height: 600)
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
                detail: String(format: "Grid %.1f V", reading.gridVoltageV),
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
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private var footer: some View {
        HStack {
            if let path = monitor.executablePath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") {
                // Otherwise the poller outlives the app until its next write fails.
                monitor.stop()
                NSApplication.shared.terminate(nil)
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
                Text("Since launch · 6h max · 30s samples")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Picker("Metric", selection: $selectedMetric) {
                ForEach(availableMetrics) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: pvEnabled) { _, enabled in
                if !enabled, selectedMetric == .pv {
                    selectedMetric = .house
                }
            }

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
                        y: .value(selectedMetric.unit, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(metricColour)
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(.secondary.opacity(0.25))
                }
                .chartYScale(domain: yDomain)
                .chartYAxisLabel(selectedMetric.unit)
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

    private struct ChartPoint: Identifiable {
        let id: UUID
        let date: Date
        let value: Double
    }

    private var chartPoints: [ChartPoint] {
        history.compactMap { point in
            guard let value = selectedMetric.value(from: point.reading) else { return nil }
            return ChartPoint(id: point.id, date: point.date, value: value)
        }
    }

    /// The configured full scale, widened when a reading exceeds it so a spike is
    /// never clipped out of view.
    private var yDomain: ClosedRange<Double> {
        let values = chartPoints.map(\.value)
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 1, low + 0.1)
        guard let configured = selectedMetric.configuredRange(
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
        switch selectedMetric {
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
