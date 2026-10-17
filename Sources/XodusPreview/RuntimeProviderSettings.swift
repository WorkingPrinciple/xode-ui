// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusCore
import XodusManagement

@MainActor
final class RuntimeProviderSettings: ObservableObject {
    @Published private(set) var configuration: RuntimeProviderConfiguration?
    @Published private(set) var plan: RuntimeConfigurationPlan?
    @Published private(set) var planning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var applicationTerminating = false
    @Published private(set) var crossOverDependency: CrossOverDependencyState = .notChecked
    @Published private(set) var checkingDependency = false
    @Published private(set) var experimentalAcknowledged = false
    private var explicitSelection: Bool
    private let detectCrossOver: @Sendable () async -> CrossOverDependencyState
    private let client = RuntimePlanClient()
    private var task: Task<Void, Never>?
    private var revision = UUID()

    init(configuration: RuntimeProviderConfiguration? = nil,
         detectCrossOver: @escaping @Sendable () async -> CrossOverDependencyState = {
             await Task.detached(priority: .utility) { CrossOverDetector.detect() }.value
         }) {
        self.configuration = configuration
        explicitSelection = configuration != nil
        self.detectCrossOver = detectCrossOver
    }

    func refreshCrossOverDependency() async {
        guard !checkingDependency, !applicationTerminating, !planning else { return }
        let previous = crossOverDependency
        checkingDependency = true
        crossOverDependency = .checking
        let observed = await detectCrossOver()
        checkingDependency = false
        guard !applicationTerminating else {
            crossOverDependency = .notChecked
            return
        }
        if observed != previous { invalidate() }
        crossOverDependency = observed
        if configuration == nil, !explicitSelection, case .installed(let app) = observed {
            var value = RuntimeProviderConfiguration.preset(.crossover)
            value.providerVersion = app.version
            configuration = value
        }
    }

    static let providerChoices: [RuntimeProviderKind] = [.crossover, .gptk4, .gptk3, .standaloneWine]
    static func providerLabel(_ provider: RuntimeProviderKind) -> String {
        provider == .crossover ? "Official CrossOver (first release)" : "\(provider.label) (Experimental)"
    }

    var requiresExperimentalAcknowledgement: Bool {
        guard let configuration else { return false }
        return configuration.provider != .crossover || configuration.graphics.backend != nil
    }

    var planningBlocker: String? {
        guard let configuration else { return "Choose a runtime configuration first." }
        if checkingDependency { return "Wait for the CrossOver app check before requesting a plan." }
        if configuration.provider == .crossover && !crossOverDependency.isVerified {
            return "Verify a separately installed official CrossOver app before planning this first-release configuration."
        }
        if requiresExperimentalAcknowledgement && !experimentalAcknowledged {
            return "Confirm this Experimental configuration before requesting its pure plan. It is not first-release supported."
        }
        return nil
    }

    func acknowledgeExperimental(_ accepted: Bool) {
        guard !planning, !applicationTerminating else { return }
        experimentalAcknowledged = accepted && requiresExperimentalAcknowledgement
    }

    func select(_ provider: RuntimeProviderKind?) {
        guard !applicationTerminating else { return }
        invalidate()
        explicitSelection = true
        configuration = provider.map(RuntimeProviderConfiguration.preset)
    }

    func update(_ change: (inout RuntimeProviderConfiguration) -> Void) {
        guard !applicationTerminating else { return }
        guard var value = configuration else { return }
        invalidate()
        explicitSelection = true
        change(&value)
        configuration = value
    }

    func cancel() {
        guard planning else { return }
        task?.cancel()
        errorMessage = RuntimePlanningError.cancelled.localizedDescription
    }

    private func invalidate() {
        task?.cancel()
        revision = UUID()
        plan = nil
        errorMessage = nil
        experimentalAcknowledged = false
    }

    func makePlan(executable: URL) {
        guard let configuration, !planning, !applicationTerminating else { return }
        let engineIdentity: NativeAuthHostBinding?
#if XODUS_SHIPPING
        do {
            let pair = try ShippingPairAdmission.configuration(
                bundle: .main, stateDirectory: URL(fileURLWithPath: NSHomeDirectory()),
                pins: ShippingPairPins.approved)
            guard pair.executable == executable else { throw ManagementError.pairedEngineUnavailable }
            engineIdentity = pair.executableIdentity
        } catch {
            errorMessage = ManagementError.pairedEngineUnavailable.localizedDescription
            return
        }
#else
        engineIdentity = nil
#endif
        if let blocker = planningBlocker {
            errorMessage = blocker
            return
        }
        let acknowledged = experimentalAcknowledged
        invalidate()
        experimentalAcknowledged = acknowledged
        let captured = revision
        planning = true
        task = Task {
            do {
                let result = try await client.plan(executable: executable, configuration: configuration,
                                                  executableIdentity: engineIdentity)
                if captured == revision && !Task.isCancelled { plan = result }
            } catch {
                if captured == revision {
                    errorMessage = (error as? RuntimePlanningError)?.localizedDescription
                        ?? RuntimePlanningError.transportFailed.localizedDescription
                }
            }
            planning = false
            task = nil
        }
    }

    func text(_ path: WritableKeyPath<RuntimeProviderConfiguration, String?>) -> Binding<String> {
        Binding(get: { self.configuration?[keyPath: path] ?? "" },
                set: { text in self.update { $0[keyPath: path] = text.isEmpty ? nil : text } })
    }

    var hasOwnedPlanningProcess: Bool {
        get async { await client.hasOwnedProcess }
    }

    func beginApplicationTermination() {
        applicationTerminating = true
        invalidate()
    }

    func shutdownForApplicationTermination() async -> Bool {
        beginApplicationTermination()
        if let pending = task {
            pending.cancel()
            await pending.value
        }
        do {
            try await client.closeOwnedProcess()
            guard !(await client.hasOwnedProcess) else { throw RuntimePlanningError.shutdownFailed }
            return true
        } catch {
            errorMessage = RuntimePlanningError.shutdownFailed.localizedDescription
            return false
        }
    }

    func resumeAfterTerminationRefusal() { applicationTerminating = false }
}

struct RuntimeProviderSection: View {
    @ObservedObject var settings: RuntimeProviderSettings
    let backendPath: String
    var allowsInstallationCheck = true

    var body: some View {
        Section("Runtime configuration") {
            RuntimeDependencyStatus(settings: settings, allowsCheck: allowsInstallationCheck)
            Picker("Runtime provider", selection: Binding(
                get: { settings.configuration?.provider }, set: { settings.select($0) })) {
                Text("Choose a provider").tag(Optional<RuntimeProviderKind>.none)
                ForEach(RuntimeProviderSettings.providerChoices, id: \.self) { provider in
                    Text(RuntimeProviderSettings.providerLabel(provider)).tag(Optional(provider))
                }
            }
            .disabled(settings.planning || settings.applicationTerminating)
            Text("Configuration only. This does not inspect, download or license a runtime, create a prefix, or enable Play.")
                .foregroundStyle(.secondary)
            if let configuration = settings.configuration {
                if configuration.provider == .crossover {
                    Text("Use your own legitimately installed and licensed CrossOver. Xodus does not include or copy CrossOver.")
                        .foregroundStyle(.secondary)
                }
                TextField("Provider version (unknown if blank)", text: settings.text(\.providerVersion))
                    .disabled(settings.planning || settings.applicationTerminating)
                DisclosureGroup("Declared engine and graphics components") {
                    if configuration.provider == .standaloneWine {
                        Picker("Wine source", selection: Binding(
                            get: { settings.configuration?.engine.provenance ?? .userSelectedWine },
                            set: { source in settings.update { $0.engine.provenance = source } })) {
                            Text("User-selected Wine").tag(RuntimeEngineProvenance.userSelectedWine)
                            Text("User-selected source build").tag(RuntimeEngineProvenance.userSelectedSourceBuild)
                        }
                    } else {
                        LabeledContent("Wine source", value: configuration.engine.provenance.label)
                    }
                    TextField("Wine version (unknown if blank)", text: settings.text(\.engine.version))
                    TextField("Wine SHA-256 (unknown if blank)", text: settings.text(\.engine.artifactSha256))
                    Picker("Graphics backend", selection: Binding(
                        get: { settings.configuration?.graphics.backend },
                        set: { backend in
                            settings.update { value in
                                value.graphics = backend.map {
                                    RuntimeGraphicsConfiguration(backend: $0, provenance: .userSelected)
                                } ?? .init()
                            }
                        })) {
                        Text("Not declared").tag(Optional<RuntimeGraphicsBackend>.none)
                        ForEach(RuntimeGraphicsBackend.allCases, id: \.self) { backend in
                            Text("\(backend.label) (Experimental override)").tag(Optional(backend))
                        }
                    }
                    if configuration.graphics.backend != nil {
                        Picker("Graphics source", selection: Binding(
                            get: { settings.configuration?.graphics.provenance ?? .userSelected },
                            set: { provenance in settings.update { $0.graphics.provenance = provenance } })) {
                            Text("Apple toolkit").tag(RuntimeGraphicsProvenance.appleToolkit)
                            Text("CrossOver bundled").tag(RuntimeGraphicsProvenance.crossOverBundled)
                            Text("Engine bundled").tag(RuntimeGraphicsProvenance.engineBundled)
                            Text("User selected").tag(RuntimeGraphicsProvenance.userSelected)
                        }
                        TextField("Graphics version (unknown if blank)", text: settings.text(\.graphics.version))
                        TextField("Graphics SHA-256 (unknown if blank)", text: settings.text(\.graphics.artifactSha256))
                    }
                }
                .disabled(settings.planning || settings.applicationTerminating)
                Text("Versions and hashes are your declarations, not installation or gameplay evidence. Engine and graphics identities are independent; changing either requires a fresh isolated plan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.requiresExperimentalAcknowledgement {
                Toggle("I understand this configuration is Experimental and not first-release supported",
                       isOn: Binding(get: { settings.experimentalAcknowledged },
                                     set: { settings.acknowledgeExperimental($0) }))
                    .disabled(settings.planning || settings.applicationTerminating)
            }
            if let blocker = settings.planningBlocker {
                Text(blocker).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Plan isolated configuration") {
                    settings.makePlan(executable: URL(fileURLWithPath: backendPath))
                }
                .disabled(settings.configuration == nil || backendPath.isEmpty || settings.planning
                          || settings.applicationTerminating || settings.planningBlocker != nil)
                if settings.planning {
                    ProgressView().controlSize(.small)
                    Button("Cancel planning") { settings.cancel() }
                }
            }
            if let plan = settings.plan {
                LabeledContent("Planned generation", value: plan.generationID)
                Text("This plan does not change the engine used by installed games. The separate CrossOver app check is not device preflight or game verification.")
                    .foregroundStyle(.secondary)
                Text("No existing bottle, prefix or saves were reused, migrated or deleted. This plan creates no files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = settings.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}
