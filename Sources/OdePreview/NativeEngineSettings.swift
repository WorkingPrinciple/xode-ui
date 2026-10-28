// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import OdeCore
import OdeManagement

struct NativeEngineSettings: View {
    static func defaultAdmissionName(defaults: UserDefaults = .standard) throws -> String {
        guard defaults.object(forKey: NativeEngineDefaults.preferenceKey) != nil else {
            return try NativeEngineDefaults.read().defaultEngine
        }
        guard let data = defaults.data(forKey: NativeEngineDefaults.preferenceKey) else {
            throw NativeLaunchError.selectionChanged
        }
        if data.isEmpty { return try NativeEngineDefaults.read().defaultEngine }
        guard let saved = try NativeEngineDefaults.savedAdmission(defaults: defaults) else {
            return try NativeEngineDefaults.read().defaultEngine
        }
        guard let name = saved.inspection.engineName, let digest = saved.inspection.registrySha256 else {
            throw NativeLaunchError.selectionChanged
        }
        try saved.validate(registryPath: saved.registryPath, engineName: name, registryDigest: digest)
        return name
    }

    static func persistDefaultAdmission(_ selection: AdmittedEngineSelection,
                                         defaults: UserDefaults = .standard) throws {
        guard NativeEngineDefaults.permitsGlobalDefault(selection) else { throw NativeLaunchError.titleRecipeUnavailable }
        guard let name = selection.inspection.engineName, let digest = selection.inspection.registrySha256 else {
            throw NativeLaunchError.selectionChanged
        }
        try selection.validate(registryPath: selection.registryPath, engineName: name, registryDigest: digest)
        let data = try JSONEncoder().encode(selection)
        defaults.set(data, forKey: NativeEngineDefaults.preferenceKey)
        guard defaults.data(forKey: NativeEngineDefaults.preferenceKey) == data else {
            throw GameScriptError.storage
        }
        EngineDefaults.setDefaultEngine(.calimocho, defaults)
    }

    let allowsFileReads: Bool
    let backendPath: String
    @ObservedObject var observation: EngineRegistryObservation
    var showsEntries = true
    @AppStorage("Ode.lifecycle.registry") private var registryPath = ""
    @AppStorage("Ode.lifecycle.runtime") private var runtimeData = Data()
    @AppStorage("Ode.lifecycle.profileDirectory") private var profileDirectory = ""
    @AppStorage("Ode.evidence.triedGames") private var evidencePath = ""
    @State private var refreshID = UUID()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Engine registry") {
                HStack {
                    Button("Refresh") { refreshID = UUID() }
                        .disabled(!allowsFileReads || observation.status == .loading)
                        .accessibilityIdentifier("ode.engines.registry.refresh")
                    Button("Choose registry…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.allowsMultipleSelection = false
                        panel.allowedContentTypes = [.json]
                        if panel.runModal() == .OK, let url = panel.url { registryPath = url.path }
                    }
                    .disabled(!allowsFileReads)
                    .accessibilityIdentifier("ode.lifecycle.chooseRegistry")
                }
            }
            if !registryPath.isEmpty {
                Text(registryPath).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if observation.status == .loading {
                ProgressView("Reading engine registry").controlSize(.small)
            }
            if registryPath.isEmpty {
                Text(
                    "Choose the engine registry to detect installed engines."
                )
                .foregroundStyle(.secondary)
            } else if observation.entries.isEmpty, observation.status == .missing {
                Text(
                    "No engines are registered in this file. Choose another registry or ask the engine provider for its installation record."
                )
                .foregroundStyle(.secondary)
        }
        if showsEntries {
            ForEach(observation.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(entry.name, value: observation.inspections[entry.name]?.ready == true
                                   ? "Artifact verified" : EngineManagementPolicy.status(entry).rawValue)
                    LabeledContent("Declared version", value: entry.version ?? "Unknown")
                    Text(entry.wine).textSelection(.enabled)
                    if let source = entry.source_url {
                        Text("Declared source: \(source)").textSelection(.enabled)
                    }
                    if let inspection = observation.inspections[entry.name] {
                        Text(
                            inspection.ready
                                ? "Artifact verification passed; not game qualified."
                                : "Provider not admitted. This record cannot be selected as Calimocho.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let message = observation.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = observation.inspectionMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if NativeRuntimePins.approved == nil {
                LabeledContent("Local game runtime") {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.allowsMultipleSelection = false
                        panel.message =
                            "Choose xgameruntime.dll. The sibling xgameruntime_legacy.dll is required."
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        Task {
                            do {
                                let reference = try await Task.detached { try NativeRuntimeReference.capture(url) }
                                    .value
                                runtimeData = try JSONEncoder().encode(NativeLocalRuntime(reference))
                                errorMessage = nil
                            } catch {
                                errorMessage =
                                    "The matching runtime DLL pair couldn't be read. Choose xgameruntime.dll beside xgameruntime_legacy.dll."
                            }
                        }
                    }.disabled(!allowsFileReads)
                }
                Text(
                    runtimeData.isEmpty
                        ? "Not selected"
                        : "Selected · DLL hashes checked before launch"
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Title launch profiles") {
                Button("Choose folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { profileDirectory = url.path }
                }.disabled(!allowsFileReads)
            }
            if !profileDirectory.isEmpty {
                Text(profileDirectory).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Mac test evidence") {
                Button("Choose evidence JSON…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url { evidencePath = url.path }
                }.disabled(!allowsFileReads)
            }
            if !evidencePath.isEmpty {
                Text(evidencePath).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        }
        .task(id: "\(registryPath)|\(refreshID)|\(allowsFileReads)|\(backendPath)") {
            let executable = backendPath.isEmpty ? nil : URL(fileURLWithPath: backendPath)
            var identity: NativeAuthHostBinding?
            #if ODE_SHIPPING
                do {
                    let pair = try ShippingPairAdmission.configuration(
                        bundle: .main,
                        stateDirectory: URL(fileURLWithPath: NSHomeDirectory()), pins: ShippingPairPins.approved
                    )
                    guard pair.executable == executable else { throw EngineInspectionError.unsupported }
                    identity = pair.executableIdentity
                } catch {
                    errorMessage =
                        "The approved app engine is unavailable. Provider inspection was not started."
                    return
                }
            #endif
            await observation.refresh(
                path: registryPath, allowsFileReads: allowsFileReads,
                executable: executable, executableIdentity: identity)
        }
    }

}
