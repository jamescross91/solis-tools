import Foundation
import SolisHubKit
import SwiftUI

/// Where the hub settings live. Addresses are ordinary preferences; the token
/// and the Cloudflare Access pair are secrets and live only in the Keychain.
enum HubSettingsStore {
    static let lanKey = "hubLANURL"
    static let remoteKey = "hubRemoteURL"
    static let preferredKey = "hubPreferredID"

    static func connectionSettings(_ defaults: UserDefaults = .standard) -> HubConnectionSettings {
        let preferred = (defaults.string(forKey: preferredKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HubConnectionSettings(
            lanURL: HubURLInput.lan(defaults.string(forKey: lanKey) ?? ""),
            remoteURL: HubURLInput.remote(defaults.string(forKey: remoteKey) ?? ""),
            preferredHubID: preferred.isEmpty ? nil : preferred
        )
    }

    /// Everything a HubSource needs, or nil when an address or the token is
    /// missing, which is how the app knows Hub mode is not yet set up.
    static func sourceSettings(
        _ defaults: UserDefaults = .standard,
        credentials: HubCredentials = HubCredentials()
    ) -> HubSourceSettings? {
        let connection = connectionSettings(defaults)
        guard !connection.isEmpty, let auth = try? credentials.load() else { return nil }
        return HubSourceSettings(connection: connection, auth: auth)
    }
}

@MainActor
final class HubSettingsModel: ObservableObject {
    enum TestState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    @Published var lanText: String
    @Published var remoteText: String
    @Published var token: String
    @Published var cloudflareID: String
    @Published var cloudflareSecret: String
    @Published var preferredHubID: String
    @Published private(set) var discovered: [DiscoveredHub] = []
    @Published private(set) var discoveryProblem: String?
    @Published private(set) var testState: TestState = .idle
    @Published private(set) var saveError: String?

    private let defaults: UserDefaults
    private let credentials: HubCredentials
    private var resolver: HubEndpointResolver?
    private var discoveryTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, credentials: HubCredentials = HubCredentials()) {
        self.defaults = defaults
        self.credentials = credentials
        lanText = defaults.string(forKey: HubSettingsStore.lanKey) ?? ""
        remoteText = defaults.string(forKey: HubSettingsStore.remoteKey) ?? ""
        preferredHubID = defaults.string(forKey: HubSettingsStore.preferredKey) ?? ""
        let stored = try? credentials.load()
        token = stored?.token ?? ""
        cloudflareID = stored?.cloudflareClientID ?? ""
        cloudflareSecret = stored?.cloudflareClientSecret ?? ""
    }

    /// Enough to try connecting: some address, and a token.
    var isComplete: Bool {
        let hasAddress = HubURLInput.lan(lanText) != nil || HubURLInput.remote(remoteText) != nil
            || !preferredHubID.isEmpty
        return hasAddress && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A remote URL that was typed but refused, because plain http would send
    /// the token across the internet in the clear.
    var remoteProblem: String? {
        let trimmed = remoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || HubURLInput.remote(trimmed) != nil { return nil }
        return "The remote URL must be https:// (or wss://)."
    }

    var lanProblem: String? {
        let trimmed = lanText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || HubURLInput.lan(trimmed) != nil { return nil }
        return "That does not look like a hub address."
    }

    func startDiscovery() {
        guard resolver == nil else { return }
        let resolver = HubEndpointResolver()
        self.resolver = resolver
        let updates = resolver.updates
        discoveryTask = Task { [weak self] in
            for await network in updates {
                self?.discovered = network.discovered
                self?.discoveryProblem = network.discoveryProblem
            }
        }
        resolver.start()
    }

    func stopDiscovery() {
        resolver?.stop()
        discoveryTask?.cancel()
        resolver = nil
        discoveryTask = nil
    }

    func choose(_ hub: DiscoveredHub) {
        preferredHubID = hub.hubID ?? ""
    }

    func clearChoice() {
        preferredHubID = ""
    }

    /// Writes addresses to preferences and secrets to the Keychain. Returns
    /// whether it worked, so the caller does not connect on a failed save.
    @discardableResult
    func save() -> Bool {
        defaults.set(lanText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: HubSettingsStore.lanKey)
        defaults.set(
            remoteText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: HubSettingsStore.remoteKey
        )
        defaults.set(preferredHubID, forKey: HubSettingsStore.preferredKey)
        do {
            try credentials.save(currentAuth())
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func currentAuth() -> HubAuth {
        HubAuth(
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            cloudflareClientID: cloudflareID.trimmingCharacters(in: .whitespacesAndNewlines),
            cloudflareClientSecret: cloudflareSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Asks the hub's /v1/status over the same LAN-then-remote order a live
    /// connection uses, so the answer says which of the two would be used.
    func testConnection() {
        let auth = currentAuth()
        guard !auth.token.isEmpty else {
            testState = .failed("Enter the hub token first.")
            return
        }
        let settings = HubConnectionSettings(
            lanURL: HubURLInput.lan(lanText),
            remoteURL: HubURLInput.remote(remoteText),
            preferredHubID: preferredHubID.isEmpty ? nil : preferredHubID
        )
        let candidates = HubEndpointSelector.candidates(settings: settings, discovered: discovered)
        testState = .running
        Task {
            do {
                let result = try await HubConnectionTester.test(candidates: candidates, auth: auth)
                let status = result.status
                testState = .succeeded(
                    "Hub \(status.hubVersion) answered on the \(result.endpoint.kind.label) address. "
                        + "Poller: \(status.poller.state). \(status.clients) client(s) connected."
                )
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

struct HubSettingsSection: View {
    @ObservedObject var model: HubSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hub")
                .font(.headline)
            discoveredHubs
            LabeledContent("LAN address") {
                TextField("192.168.1.20:8765 (optional)", text: $model.lanText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
            if let problem = model.lanProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("Remote URL") {
                TextField("https://energy.example.com (optional)", text: $model.remoteText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
            if let problem = model.remoteProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("Token") {
                SecureField("Hub token", text: $model.token)
                    .textFieldStyle(.roundedBorder)
            }
            DisclosureGroup("Cloudflare Access (optional)") {
                VStack(spacing: 8) {
                    LabeledContent("Client ID") {
                        TextField("Service token client ID", text: $model.cloudflareID)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                    }
                    LabeledContent("Client secret") {
                        SecureField("Service token client secret", text: $model.cloudflareSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 6)
            }
            HStack(spacing: 8) {
                Button("Test connection") {
                    model.testConnection()
                }
                .disabled(model.testState == .running)
                if model.testState == .running {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            testResult
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(
                "The token and the Cloudflare Access pair are stored in the macOS Keychain, never in "
                    + "preferences or logs. The LAN address is tried first, then the remote URL."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task {
            model.startDiscovery()
        }
        .onDisappear {
            model.stopDiscovery()
        }
    }

    @ViewBuilder
    private var discoveredHubs: some View {
        let hubs = model.discovered
        let chosen: String = model.preferredHubID
        let problem: String? = model.discoveryProblem
        // A lone hub is offered plainly, but still needs the person's click.
        let useLabel: String = hubs.count == 1 ? "Use this hub" : "Use"
        if hubs.isEmpty {
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("No hub found on this network yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hubs on this network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(hubs) { hub in
                    HStack {
                        Image(systemName: "server.rack")
                        Text(hub.name)
                        Spacer()
                        if !chosen.isEmpty, hub.hubID == chosen {
                            Label("Selected", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Button("Clear") { model.clearChoice() }
                        } else {
                            Button(useLabel) { model.choose(hub) }
                        }
                    }
                    .font(.caption)
                }
                if chosen.isEmpty {
                    // A hub on the network is never connected to until chosen:
                    // the token would go to it in clear text.
                    Text("A hub found here is not used until you choose it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch model.testState {
        case .idle, .running:
            EmptyView()
        case let .succeeded(message):
            Label(message, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The controller settings as the hub's poller is actually running them.
/// Read-only on purpose: control settings live in the hub's config file, so
/// that no client can change the safety envelope remotely.
struct HubControlSummary: View {
    let configuration: VoltageControlConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dynamic voltage control (set on the hub)")
                .font(.headline)
            if let configuration {
                VStack(alignment: .leading, spacing: 3) {
                    row("Control", enabled: configuration.enabled)
                    row("Import regulation", enabled: configuration.importEnabled)
                    row("Export regulation", enabled: configuration.exportEnabled)
                    row("Voltage limits", range: configuration.minimumVoltageV, configuration.maximumVoltageV, unit: "V")
                    row("Safety margin", value: configuration.safetyMarginV, unit: "V")
                    row("Maximum import", watts: configuration.maximumImportW)
                    row("Maximum export", watts: configuration.maximumExportW)
                    row("Site export permission", watts: configuration.siteExportPermissionW)
                    row("Hypervolt priority", enabled: configuration.hypervoltEnabled)
                    row("Intelligent Octopus", enabled: configuration.octopusEnabled)
                }
                .font(.caption)
            } else {
                Text("The hub has not sent its settings yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(
                "To change these, edit the poller arguments in the hub's configuration file and "
                    + "restart solis-hub. Changes cannot be made from this app."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func row(_ title: String, enabled: Bool?) -> some View {
        line(title, enabled.map { $0 ? "On" : "Off" } ?? "Unknown")
    }

    private func row(_ title: String, value: Double?, unit: String) -> some View {
        line(title, value.map { String(format: "%.2f %@", $0, unit) } ?? "Unknown")
    }

    private func row(_ title: String, watts: Double?) -> some View {
        line(title, watts.map { String(format: "%.1f kW", $0 / 1_000) } ?? "Unknown")
    }

    private func row(_ title: String, range low: Double?, _ high: Double?, unit: String) -> some View {
        guard let low, let high else { return line(title, "Unknown") }
        return line(title, String(format: "%.0f to %.0f %@", low, high, unit))
    }
}
