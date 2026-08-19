import Darwin
import SwiftUI

@main
struct SolisMenuBarApp: App {
    @StateObject private var monitor = MonitorStore()

    init() {
        if CommandLine.arguments.contains("--version") {
            print("solis-menubar 0.2.0")
            Darwin.exit(EXIT_SUCCESS)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: monitor)
        } label: {
            Label(monitor.menuTitle, systemImage: monitor.menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
