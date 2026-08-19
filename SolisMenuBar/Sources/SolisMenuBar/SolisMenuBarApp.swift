import Darwin
import SwiftUI

@main
struct SolisMenuBarApp: App {
    @StateObject private var monitor = MonitorStore()

    init() {
        if CommandLine.arguments.contains("--version") {
            print("solis-menubar 0.3.0")
            Darwin.exit(EXIT_SUCCESS)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: monitor)
        } label: {
            MenuBarMetricsView(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarMetricsView: View {
    @ObservedObject var monitor: MonitorStore

    @AppStorage("menuBarHouseLoad") private var showHouseLoad = true
    @AppStorage("menuBarBattery") private var showBattery = true
    @AppStorage("menuBarGrid") private var showGrid = true
    @AppStorage("menuBarTemperature") private var showTemperature = false
    @AppStorage("menuBarPV") private var showPV = false

    var body: some View {
        if let reading = monitor.latest?.reading {
            metricsLabel(for: reading)
                .font(.caption.weight(.medium).monospacedDigit())
                .accessibilityLabel("Solis live metrics")
        } else {
            Label("Solis", systemImage: monitor.menuSymbol)
        }
    }

    private func metricsLabel(for reading: InverterReading) -> Text {
        var label = Text("")
        var hasMetric = false

        if monitor.hasMenuAlert {
            label = append(
                metric(value: "", symbol: monitor.menuSymbol),
                to: label,
                hasMetric: &hasMetric
            )
        }
        if showHouseLoad {
            label = append(
                metric(value: String(format: "%.2f kW", reading.houseLoadKw), symbol: "house.fill"),
                to: label,
                hasMetric: &hasMetric
            )
        }
        if showBattery {
            label = append(
                metric(value: "\(reading.batterySocPercent)%", symbol: batterySymbol(reading.batterySocPercent)),
                to: label,
                hasMetric: &hasMetric
            )
        }
        if showGrid {
            label = append(
                metric(value: String(format: "%+.2f kW", reading.gridImportPositiveKw), symbol: gridSymbol(reading.gridStatus)),
                to: label,
                hasMetric: &hasMetric
            )
        }
        if showTemperature {
            label = append(
                metric(value: String(format: "%.1f °C", reading.inverterTemperatureC), symbol: "thermometer.medium"),
                to: label,
                hasMetric: &hasMetric
            )
        }
        if showPV, let pv = reading.pvKw {
            label = append(
                metric(value: String(format: "%.2f kW", pv), symbol: "sun.max.fill"),
                to: label,
                hasMetric: &hasMetric
            )
        }

        return hasMetric ? label : Text(Image(systemName: monitor.menuSymbol))
    }

    private func append(_ metric: Text, to label: Text, hasMetric: inout Bool) -> Text {
        defer { hasMetric = true }
        return hasMetric ? label + Text("  ") + metric : metric
    }

    private func metric(value: String, symbol: String) -> Text {
        Text(Image(systemName: symbol)) + Text(value.isEmpty ? "" : " \(value)")
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

    private func gridSymbol(_ status: String) -> String {
        status == "Exporting" ? "arrow.up.right" : "arrow.down.left"
    }
}
