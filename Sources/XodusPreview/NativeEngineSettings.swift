// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import XodusCore
import XodusManagement

struct NativeEngineSettings: View {
    let allowsFileReads: Bool
    let backendPath: String
    @ObservedObject var observation: EngineRegistryObservation
    @AppStorage("Xodus.lifecycle.registry") private var registryPath = ""
    @AppStorage("Xodus.lifecycle.runtime") private var runtimeData = Data()
    @AppStorage("Xodus.lifecycle.profileDirectory") private var profileDirectory = ""
    @AppStorage("Xodus.evidence.triedGames") private var evidencePath = ""
    @State private var refreshID = UUID()
    @State private var errorMessage: String?
    @AppStorage(AdmittedEngineSelection.preferenceKey) private var admittedSelection = Data()
    @ObservedObject private var localDiscovery = LocalNetworkDiscovery.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Registered engines").font(.headline)
                Spacer()
                Button("Refresh") { refreshID = UUID() }
                    .disabled(!allowsFileReads || observation.status == .loading)
                    .accessibilityIdentifier("xodus.engines.registry.refresh")
                Button("Choose registry…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url { registryPath = url.path }
                }
                .disabled(!allowsFileReads)
                .accessibilityIdentifier("xodus.lifecycle.chooseRegistry")
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
                    "Choose the local engine registry to detect registered versions and locations. Refresh reads it again without installing or changing engines."
                )
                .foregroundStyle(.secondary)
            } else if observation.entries.isEmpty, observation.status == .missing {
                Text(
                    "No engines are registered in this file. Choose another registry or ask the engine provider for its installation record."
                )
                .foregroundStyle(.secondary)
            }
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
                        if inspection.ready, inspection.admittedProvider == "calimocho" {
                            Button("Use this Calimocho build as default") {
                                if saveAdmission(inspection) { EngineDefaults.setDefaultEngine(.calimocho) }
                            }
                            .disabled(!allowsFileReads || observation.status == .loading)
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            NativeEnginePicker(
                provider: .calimocho, entries: observation.entries, allowsSelection: allowsFileReads,
                admittedNames: Set(
                    observation.inspections.values.filter {
                        $0.ready && $0.admittedProvider == "calimocho"
                    }.compactMap(\.engineName)),
                selectAdmission: { name in
                    guard let inspection = observation.inspections[name], inspection.admittedProvider == "calimocho"
                    else { return true }
                    return saveAdmission(inspection)
                })
            Text(EngineManagementPolicy.qualificationExplanation)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(
                "Apple toolkit and graphics payloads are not interchangeable with registered Wine providers. Generic Wine records keep their exact names; they are not identified as Calimocho."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            DisclosureGroup("Advanced game runtime and diagnostics") {
                if NativeRuntimePins.approved == nil {
                    Button("Choose local game runtime…") {
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
                    Text(
                        runtimeData.isEmpty
                            ? "No local game runtime selected."
                            : "Local experimental runtime selected. Its two DLL hashes are checked before each launch; gameplay and release qualification remain separate."
                    )
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Title launch profiles")
                    Spacer()
                    Button("Choose folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { profileDirectory = url.path }
                    }.disabled(!allowsFileReads)
                }
                if !profileDirectory.isEmpty {
                    Text(profileDirectory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Text("Mac test evidence")
                    Spacer()
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
                    Text(evidencePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Find consoles on local network") { localDiscovery.search() }
                    .disabled(!allowsFileReads)
                    .accessibilityIdentifier("xodus.localNetwork.discover")
                Text(localDiscovery.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .task(id: "\(registryPath)|\(refreshID)|\(allowsFileReads)|\(backendPath)") {
            let executable = backendPath.isEmpty ? nil : URL(fileURLWithPath: backendPath)
            var identity: NativeAuthHostBinding?
            #if XODUS_SHIPPING
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

    private func saveAdmission(_ inspection: EngineInspection) -> Bool {
        do {
            guard inspection.ready, let name = inspection.engineName else { throw EngineInspectionError.failed }
            admittedSelection = try JSONEncoder().encode(AdmittedEngineSelection(
                registryPath: registryPath, inspection: inspection))
            UserDefaults.standard.set(name, forKey: "Xodus.lifecycle.engine.calimocho")
            errorMessage = nil
            return true
        } catch {
            errorMessage = "The verified engine selection couldn't be saved. Retry Refresh."
            return false
        }
    }
}

private struct NativeEnginePicker: View {
    let provider: RuntimeProviderKind
    let entries: [NativeEngineRegistry.Entry]
    let allowsSelection: Bool
    let admittedNames: Set<String>
    let selectAdmission: (String) -> Bool
    @AppStorage private var selection: String

    init(
        provider: RuntimeProviderKind, entries: [NativeEngineRegistry.Entry], allowsSelection: Bool,
        admittedNames: Set<String> = [], selectAdmission: @escaping (String) -> Bool = { _ in true }
    ) {
        self.provider = provider
        self.entries = entries
        self.allowsSelection = allowsSelection
        self.admittedNames = admittedNames
        self.selectAdmission = selectAdmission
        _selection = AppStorage(wrappedValue: "", "Xodus.lifecycle.engine.\(provider.rawValue)")
    }

    var body: some View {
        Picker(provider.label, selection: Binding(get: { selection }, set: { name in
            if selectAdmission(name) { selection = name }
        })) {
            Text("Choose an engine").tag("")
            if !selection.isEmpty, !available.contains(where: { $0.name == selection }) {
                Text("\(selection) (unavailable)").tag(selection)
            }
            ForEach(available) { entry in
                Text(entry.name)
                    .tag(entry.name)
            }
        }
        .disabled(!allowsSelection)
    }

    private var available: [NativeEngineRegistry.Entry] {
        entries.filter {
            (EngineManagementPolicy.matches($0, provider: provider)
                || (provider == .calimocho && admittedNames.contains($0.name))) && $0.isAvailable
                && (provider != .calimocho || admittedNames.contains($0.name))
        }
    }
}
