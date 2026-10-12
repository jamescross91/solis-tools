import SolisHubKit
import SwiftUI

/// The hub's control settings and its Hypervolt and Octopus sign-ins, read
/// from and written to the hub's /v1/settings API.
///
/// Edits are made to a draft and sent only when the person applies them,
/// because applying restarts the hub's poller: it restores the inverter's
/// limits first, then starts again with the new settings.
@MainActor
final class HubControlModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum ActionState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    /// What the hub last reported, settings and sign-ins alike.
    @Published private(set) var state: HubSettingsState?
    @Published var draft: HubControlSettings = .placeholder
    @Published private(set) var applyState: ActionState = .idle
    @Published private(set) var hypervoltState: ActionState = .idle
    @Published private(set) var octopusState: ActionState = .idle

    @Published var hypervoltEmail = ""
    @Published var hypervoltPassword = ""
    @Published var octopusAPIKey = ""
    @Published var octopusAccount = ""
    @Published var octopusDevice = ""

    private var client: HubAdminClient?

    var hasChanges: Bool {
        guard let state else { return false }
        return draft != state.settings
    }

    var endpointLabel: String? {
        client.map { $0.endpoint.kind.label }
    }

    func load(from target: (candidates: [HubEndpoint], auth: HubAuth)?) {
        guard let target else {
            loadState = .failed("Enter the hub address and token above first.")
            return
        }
        loadState = .loading
        Task {
            do {
                let (client, state) = try await HubAdminClient.connect(
                    candidates: target.candidates, auth: target.auth
                )
                self.client = client
                self.state = state
                draft = state.settings
                applyState = .idle
                loadState = .loaded
            } catch {
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    func apply() {
        guard let client else { return }
        let settings = draft
        applyState = .running
        Task {
            do {
                let state = try await client.save(settings)
                self.state = state
                draft = state.settings
                applyState = .succeeded(
                    state.restarted == true
                        ? "Saved. The hub's poller is restoring the inverter's limits and restarting with these settings."
                        : "Saved. The hub was already running these settings."
                )
            } catch {
                applyState = .failed(error.localizedDescription)
            }
        }
    }

    func revert() {
        if let state {
            draft = state.settings
        }
        applyState = .idle
    }

    func signInToHypervolt() {
        guard let client else { return }
        let email = hypervoltEmail.trimmingCharacters(in: .whitespaces)
        let password = hypervoltPassword
        // Cleared at once, so the password is held only for the one request.
        hypervoltPassword = ""
        hypervoltState = .running
        Task {
            do {
                let state = try await client.signInToHypervolt(email: email, password: password)
                accountsChanged(state)
                hypervoltState = .succeeded(Self.confirmation(state, service: "Hypervolt"))
            } catch {
                hypervoltState = .failed(error.localizedDescription)
            }
        }
    }

    func signInToOctopus() {
        guard let client else { return }
        let key = octopusAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = octopusAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = octopusDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        octopusAPIKey = ""
        octopusState = .running
        Task {
            do {
                let state = try await client.signInToOctopus(
                    apiKey: key,
                    account: account.isEmpty ? nil : account,
                    device: device.isEmpty ? nil : device
                )
                accountsChanged(state)
                octopusState = .succeeded(Self.confirmation(state, service: "Octopus"))
            } catch {
                octopusState = .failed(error.localizedDescription)
            }
        }
    }

    /// A sign-in answers with the whole settings state; only the accounts are
    /// taken from it, so an unapplied edit in the form is kept.
    private func accountsChanged(_ updated: HubSettingsState) {
        let edited = hasChanges ? draft : nil
        state = updated
        draft = edited ?? updated.settings
    }

    private static func confirmation(_ state: HubSettingsState, service: String) -> String {
        let restart = state.restarted == true ? " The hub's poller is restarting to use it." : ""
        return "Signed in to \(service) on the hub.\(restart)"
    }
}

extension HubControlSettings {
    /// Only fills the form until the hub's own settings arrive; never sent,
    /// because nothing can be applied before a load succeeds.
    static let placeholder = HubControlSettings(
        dynamicVoltageEnabled: false,
        dynamicImportEnabled: true,
        dynamicExportEnabled: false,
        minimumVoltage: 215,
        maximumVoltage: 258,
        voltageSafetyMargin: 1.5,
        voltageDeadband: 0.75,
        maximumImportKw: 14,
        importHeadroomKw: 2,
        exportHeadroomKw: 1,
        maximumExportKw: 10,
        siteExportPermissionKw: 10,
        increaseStepW: 200,
        reductionStepW: 500,
        nearLimitReductionW: 1_000,
        emergencyReductionW: 2_000,
        controlSettleTime: 5,
        controlActivationDelay: 5,
        controlDeactivationDelay: 10,
        importActivationKw: 1,
        exportActivationKw: 0.5,
        minimumWriteInterval: 5,
        hypervoltEnabled: false,
        evPriority: "battery",
        octopusEnabled: false
    )
}

struct HubControlSettingsSection: View {
    @ObservedObject var model: HubControlModel
    @ObservedObject var hubSettings: HubSettingsModel
    @State private var confirmingApply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.loadState {
            case .idle, .loading:
                if model.loadState == .loading {
                    ProgressView("Reading the hub's settings")
                        .controlSize(.small)
                }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded:
                controlForm
                Divider()
                hypervoltSection
                Divider()
                octopusSection
            }
        }
        .task {
            if model.loadState == .idle, hubSettings.isComplete {
                model.load(from: hubSettings.target)
            }
        }
        .confirmationDialog(
            "Apply these settings to the hub?",
            isPresented: $confirmingApply,
            titleVisibility: .visible
        ) {
            Button("Apply and restart the hub's poller") {
                model.apply()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The hub's poller stops, restores the inverter's limits, then starts again with "
                    + "these settings. Voltage control pauses for a few seconds while it does."
            )
        }
    }

    private var header: some View {
        HStack {
            Text("Dynamic voltage control (on the hub)")
                .font(.headline)
            Spacer()
            Button("Reload") {
                model.load(from: hubSettings.target)
            }
            .disabled(model.loadState == .loading || model.applyState == .running)
        }
    }

    // MARK: Control

    @ViewBuilder
    private var controlForm: some View {
        let validated = model.state?.exportControlValidated ?? false
        if let state = model.state {
            Text(
                state.setFromApp
                    ? "Settings saved from an app. They replace the control flags in the hub's configuration file."
                    : "Settings from the hub's configuration file. Applying saves them on the hub, where they take over from that file."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Enable dynamic control", isOn: $model.draft.dynamicVoltageEnabled)
        Toggle("Enable import regulation", isOn: $model.draft.dynamicImportEnabled)
            .disabled(!model.draft.dynamicVoltageEnabled)
        // Turning export off is always allowed; turning it on needs the record.
        Toggle("Enable export regulation", isOn: $model.draft.dynamicExportEnabled)
            .disabled(
                !model.draft.dynamicVoltageEnabled || (!validated && !model.draft.dynamicExportEnabled)
            )
        Text(
            validated
                ? "Export register 43074 is validated for the hub's inverter."
                : "Export regulation needs this inverter's installation-validation record on the hub."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Group {
            number("Minimum voltage", $model.draft.minimumVoltage, unit: "V")
            number("Maximum voltage", $model.draft.maximumVoltage, unit: "V")
            number("Maximum import", $model.draft.maximumImportKw, unit: "kW")
            number("Import demand headroom", $model.draft.importHeadroomKw, unit: "kW")
            number("Maximum export (inverter rating)", $model.draft.maximumExportKw, unit: "kW")
            number("Export headroom above real export", $model.draft.exportHeadroomKw, unit: "kW")
            number("Site export permission", $model.draft.siteExportPermissionKw, unit: "kW")
        }
        .disabled(!model.draft.dynamicVoltageEnabled)
        DisclosureGroup("Advanced control behaviour") {
            VStack(spacing: 8) {
                number("Safety margin", $model.draft.voltageSafetyMargin, unit: "V")
                number("Deadband", $model.draft.voltageDeadband, unit: "V")
                integer("Increase step", $model.draft.increaseStepW, unit: "W")
                integer("Reduction step", $model.draft.reductionStepW, unit: "W")
                integer("Near-limit reduction", $model.draft.nearLimitReductionW, unit: "W")
                integer("Emergency reduction", $model.draft.emergencyReductionW, unit: "W")
                number("Settle time", $model.draft.controlSettleTime, unit: "s")
                number("Activation delay", $model.draft.controlActivationDelay, unit: "s")
                number("Deactivation delay", $model.draft.controlDeactivationDelay, unit: "s")
                number("Import activation", $model.draft.importActivationKw, unit: "kW")
                number("Export activation", $model.draft.exportActivationKw, unit: "kW")
                number("Minimum write interval", $model.draft.minimumWriteInterval, unit: "s")
            }
            .padding(.top, 6)
        }
        .disabled(!model.draft.dynamicVoltageEnabled)
        Toggle("Arbitrate priority with a Hypervolt charger", isOn: $model.draft.hypervoltEnabled)
            .disabled(!model.draft.dynamicVoltageEnabled)
        Picker("Protect", selection: $model.draft.evPriority) {
            Text("Battery charging").tag("battery")
            Text("EV charging").tag("ev")
            Text("Balanced").tag("balanced")
        }
        .disabled(!model.draft.dynamicVoltageEnabled || !model.draft.hypervoltEnabled)
        Toggle(
            "Hold the EV charger's voltage limits during Octopus charges",
            isOn: $model.draft.octopusEnabled
        )
        .disabled(!model.draft.dynamicVoltageEnabled)
        HStack(spacing: 8) {
            Button("Apply to hub") {
                confirmingApply = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !model.hasChanges || model.applyState == .running
                    || model.draft.minimumVoltage >= model.draft.maximumVoltage
            )
            Button("Revert") {
                model.revert()
            }
            .disabled(!model.hasChanges || model.applyState == .running)
            if model.applyState == .running {
                ProgressView()
                    .controlSize(.small)
            }
        }
        outcome(model.applyState)
        Text("The hub checks every value with solis-poll's own rules before it changes anything.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Sign-in

    @ViewBuilder
    private var hypervoltSection: some View {
        Text("Hypervolt on the hub")
            .font(.headline)
        if let account = model.state?.hypervolt, account.signedIn {
            Label(
                "Signed in\(account.chargerId.map { ": charger \($0)" } ?? "")",
                systemImage: "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.green)
        } else {
            Label("The hub is not signed in to Hypervolt", systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        TextField("Hypervolt account email", text: $model.hypervoltEmail)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
        SecureField("Hypervolt account password", text: $model.hypervoltPassword)
            .textFieldStyle(.roundedBorder)
        HStack(spacing: 8) {
            Button("Sign in on the hub") {
                model.signInToHypervolt()
            }
            .disabled(
                model.hypervoltEmail.trimmingCharacters(in: .whitespaces).isEmpty
                    || model.hypervoltPassword.isEmpty || model.hypervoltState == .running
            )
            if model.hypervoltState == .running {
                ProgressView()
                    .controlSize(.small)
            }
        }
        outcome(model.hypervoltState)
        Text(
            "The password goes to the hub once, which hands it to hypervolt-login there. Only the "
                + "refresh token it gets back is stored on the hub; the password is kept nowhere."
                + transportNote
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var octopusSection: some View {
        Text("Intelligent Octopus on the hub")
            .font(.headline)
        if let account = model.state?.octopus, account.signedIn {
            Label(
                "Signed in\(account.accountNumber.map { ": account \($0)" } ?? "")",
                systemImage: "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.green)
        } else {
            Label("The hub is not signed in to Octopus", systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        SecureField("Octopus API key (sk_live_…)", text: $model.octopusAPIKey)
            .textFieldStyle(.roundedBorder)
        HStack(spacing: 8) {
            TextField("Account number (optional)", text: $model.octopusAccount)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            TextField("Device ID (optional)", text: $model.octopusDevice)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
        }
        HStack(spacing: 8) {
            Button("Sign in on the hub") {
                model.signInToOctopus()
            }
            .disabled(
                model.octopusAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.octopusState == .running
            )
            if model.octopusState == .running {
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
        outcome(model.octopusState)
        Text(
            "The key goes to the hub once, which hands it to octopus-login there to check with "
                + "Octopus and save at owner-only permissions. This app never stores it."
                + transportNote
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Over the LAN address, as with the token, a secret travels unencrypted.
    private var transportNote: String {
        model.endpointLabel == HubEndpointKind.lan.label
            ? " On the LAN address it travels unencrypted, like the hub token."
            : ""
    }

    // MARK: Pieces

    @ViewBuilder
    private func outcome(_ state: HubControlModel.ActionState) -> some View {
        switch state {
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

    private func number(_ label: String, _ value: Binding<Double>, unit: String) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 75)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func integer(_ label: String, _ value: Binding<Int>, unit: String) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 75)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
