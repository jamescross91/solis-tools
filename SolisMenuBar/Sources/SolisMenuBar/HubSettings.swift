import Foundation
import SolisHubKit
import SwiftUI

/// Where the hub settings live. Addresses are ordinary preferences; the token
/// and the Cloudflare Access pair are secrets and live only in the Keychain.
enum HubSettingsStore {
    /// The one address the person gives: the hub's public https address, or a
    /// LAN address for a hub with none.
    static let addressKey = "hubAddress"
    /// An optional LAN address, for a network where Bonjour does not reach.
    static let lanKey = "hubLANURL"
    /// Before the single address: read only until settings are saved again.
    static let remoteKey = "hubRemoteURL"
    /// The hub's ID, chosen from the discovered list or learned from the hub.
    static let preferredKey = "hubPreferredID"
    /// The address the hub says to use away from home.
    static let learnedRemoteKey = "hubLearnedPublicURL"

    static func connectionSettings(_ defaults: UserDefaults = .standard) -> HubConnectionSettings {
        let stored = defaults.string(forKey: addressKey)
        return compose(
            address: stored ?? "",
            lan: defaults.string(forKey: lanKey) ?? "",
            // An app updated from the two-address settings keeps working, LAN
            // and remote both, until its settings are next saved.
            legacyRemote: stored == nil ? defaults.string(forKey: remoteKey) ?? "" : "",
            preferredHubID: defaults.string(forKey: preferredKey) ?? "",
            learnedRemote: defaults.string(forKey: learnedRemoteKey) ?? ""
        )
    }

    static func compose(
        address: String,
        lan: String,
        legacyRemote: String = "",
        preferredHubID: String,
        learnedRemote: String
    ) -> HubConnectionSettings {
        let given = HubURLInput.classify(address)
        let preferred = preferredHubID.trimmingCharacters(in: .whitespacesAndNewlines)
        return HubConnectionSettings(
            lanURL: HubURLInput.lan(lan) ?? (given?.kind == .lan ? given?.baseURL : nil),
            remoteURL: given?.kind == .remote ? given?.baseURL : HubURLInput.remote(legacyRemote),
            preferredHubID: preferred.isEmpty ? nil : preferred,
            learnedRemoteURL: HubURLInput.remote(learnedRemote)
        )
    }

    /// Records what a hub said about itself on an authenticated connection:
    /// its ID, so its Bonjour advertisement is used at home (after it proves
    /// itself), and its public address for when the Mac is away. Returns
    /// whether anything changed.
    @discardableResult
    static func learn(
        hubID: String, publicURL: String?, _ defaults: UserDefaults = .standard
    ) -> Bool {
        var changed = false
        if !hubID.isEmpty, defaults.string(forKey: preferredKey) != hubID {
            defaults.set(hubID, forKey: preferredKey)
            changed = true
        }
        if let url = publicURL.flatMap(HubURLInput.remote), defaults.string(forKey: learnedRemoteKey) != url.absoluteString {
            defaults.set(url.absoluteString, forKey: learnedRemoteKey)
            changed = true
        }
        return changed
    }

    static func learnedRemote(_ defaults: UserDefaults = .standard) -> URL? {
        HubURLInput.remote(defaults.string(forKey: learnedRemoteKey) ?? "")
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

    /// The one address: the hub's public https address, or a LAN address.
    @Published var addressText: String
    /// An optional LAN address, under Advanced.
    @Published var lanText: String
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
        let lan = defaults.string(forKey: HubSettingsStore.lanKey) ?? ""
        let legacyRemote = defaults.string(forKey: HubSettingsStore.remoteKey) ?? ""
        if let address = defaults.string(forKey: HubSettingsStore.addressKey) {
            addressText = address
            lanText = lan
        } else if !legacyRemote.isEmpty {
            // From the two-address settings: the remote one becomes the
            // address, and a LAN one is kept as the override it now is.
            addressText = legacyRemote
            lanText = lan
        } else {
            addressText = lan
            lanText = ""
        }
        preferredHubID = defaults.string(forKey: HubSettingsStore.preferredKey) ?? ""
        let stored = try? credentials.load()
        token = stored?.token ?? ""
        cloudflareID = stored?.cloudflareClientID ?? ""
        cloudflareSecret = stored?.cloudflareClientSecret ?? ""
    }

    /// Enough to try connecting: some address, and a token.
    var isComplete: Bool {
        !connection.isEmpty && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where the form, as it stands, says the hub is, with what the hub has
    /// told this Mac about itself.
    var connection: HubConnectionSettings {
        HubSettingsStore.compose(
            address: addressText,
            lan: lanText,
            preferredHubID: preferredHubID,
            learnedRemote: defaults.string(forKey: HubSettingsStore.learnedRemoteKey) ?? ""
        )
    }

    var learnedRemote: URL? {
        HubSettingsStore.learnedRemote(defaults)
    }

    var addressProblem: String? {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || HubURLInput.classify(trimmed) != nil { return nil }
        return "Enter the hub's https:// address, or its address on this network."
    }

    var lanProblem: String? {
        let trimmed = lanText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || HubURLInput.lan(trimmed) != nil { return nil }
        return "That does not look like a hub address."
    }

    func startDiscovery() {
        // The hub may have been learned since the form was built.
        preferredHubID = defaults.string(forKey: HubSettingsStore.preferredKey) ?? preferredHubID
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
        defaults.set(addressText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: HubSettingsStore.addressKey)
        defaults.set(lanText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: HubSettingsStore.lanKey)
        // Folded into the address now; leaving it would bring an old remote
        // URL back as a second address.
        defaults.removeObject(forKey: HubSettingsStore.remoteKey)
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

    /// The hub the form describes as it stands, saved or not, so its settings
    /// can be read before the connection is saved.
    var adminTarget: HubAdminTarget? {
        let auth = currentAuth()
        guard !auth.token.isEmpty else { return nil }
        let settings = connection
        guard !settings.isEmpty else { return nil }
        return HubAdminTarget(connection: settings, auth: auth, discovered: discovered)
    }

    /// The addresses to try, LAN first, and the token.
    var target: (candidates: [HubEndpoint], auth: HubAuth)? {
        adminTarget.map { ($0.candidates, $0.auth) }
    }

    /// Asks the hub's /v1/status over the same LAN-then-remote order a live
    /// connection uses, so the answer says which of the two would be used.
    func testConnection() {
        guard let (candidates, auth) = target else {
            testState = .failed("Enter the hub token first.")
            return
        }
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
            LabeledContent("Address") {
                TextField("https://raspberrypi.tailnet.ts.net", text: $model.addressText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
            if let problem = model.addressProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("Token") {
                SecureField("Hub token", text: $model.token)
                    .textFieldStyle(.roundedBorder)
            }
            routes
            DisclosureGroup("Advanced") {
                VStack(spacing: 8) {
                    LabeledContent("LAN address") {
                        TextField("only if Bonjour cannot find the hub", text: $model.lanText)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                    }
                    if let problem = model.lanProblem {
                        Text(problem).font(.caption).foregroundStyle(.orange)
                    }
                    LabeledContent("Cloudflare ID") {
                        TextField("Service token client ID", text: $model.cloudflareID)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                    }
                    LabeledContent("Cloudflare secret") {
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
                    + "preferences or logs. At home the hub is used directly over this network, once "
                    + "it has proved it holds the token; away, through its public address."
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

    /// Where this Mac will connect, at home and away, including what it has
    /// learned from the hub, so one address is visibly enough.
    @ViewBuilder
    private var routes: some View {
        let connection = model.connection
        let found = model.discovered.first { hub in
            !model.preferredHubID.isEmpty && hub.hubID == model.preferredHubID
        }
        VStack(alignment: .leading, spacing: 3) {
            if let found {
                Label("At home: \(found.name), found on this network", systemImage: "house")
            } else if let lan = connection.lanURL {
                Label("At home: \(lan.host ?? lan.absoluteString)", systemImage: "house")
            } else if connection.preferredHubID != nil {
                Label("At home: found automatically when this Mac is on the hub's network", systemImage: "house")
            } else {
                Label("At home: learned from the hub on the first connection", systemImage: "house")
            }
            if let remote = connection.remoteURL ?? connection.learnedRemoteURL {
                let learned = connection.remoteURL == nil
                Label(
                    "Away: \(remote.host ?? remote.absoluteString)\(learned ? ", from the hub" : "")",
                    systemImage: "globe"
                )
            } else {
                Label("Away: none yet. The hub tells this Mac once it has a public address", systemImage: "globe")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
                    // A hub on the network is used only once it is known to be
                    // this one, and only after it proves it holds the token.
                    Text("A hub found here is used once you choose it, or connect once with its address.")
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
