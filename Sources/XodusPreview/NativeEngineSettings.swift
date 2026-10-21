// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import XodusCore

struct NativeEngineSettings: View {
    let allowsFileReads: Bool
    @AppStorage("Xodus.lifecycle.registry") private var registryPath = ""
    @AppStorage("Xodus.lifecycle.runtime") private var runtimeData = Data()
    @AppStorage("Xodus.lifecycle.profileDirectory") private var profileDirectory = ""
    @AppStorage("Xodus.evidence.triedGames") private var evidencePath = ""
    @State private var entries: [NativeEngineRegistry.Entry] = []
    @State private var errorMessage: String?
    @ObservedObject private var localDiscovery = LocalNetworkDiscovery.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Engine registry")
                Spacer()
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
            ForEach(RuntimeProviderSettings.providerChoices, id: \.self) { provider in
                NativeEnginePicker(provider: provider, entries: entries)
            }
            Text("Only registry engines with a passed smoke test are listed. Each game and engine uses its own bottle; changing engines never reuses another engine's bottle.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if NativeRuntimePins.approved == nil {
                Button("Choose local game runtime…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose xgameruntime.dll. The sibling xgameruntime_legacy.dll is required."
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    Task {
                        do {
                            let reference = try await Task.detached { try NativeRuntimeReference.capture(url) }.value
                            runtimeData = try JSONEncoder().encode(NativeLocalRuntime(reference))
                            errorMessage = nil
                        } catch {
                            errorMessage = "The matching runtime DLL pair couldn't be read. Choose xgameruntime.dll beside xgameruntime_legacy.dll."
                        }
                    }
                }.disabled(!allowsFileReads)
                Text(runtimeData.isEmpty ? "No local game runtime selected."
                     : "Local experimental runtime selected. Its two DLL hashes are checked before each launch; gameplay and release qualification remain separate.")
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
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: registryPath) {
            entries = []
            errorMessage = nil
            guard allowsFileReads, !registryPath.isEmpty else { return }
            let path = registryPath
            do {
                let loaded = try await Task.detached {
                    try NativeEngineRegistry.read(URL(fileURLWithPath: path)).engines
                }.value
                guard path == registryPath, !Task.isCancelled else { return }
                entries = loaded.filter {
                    $0.isAvailable
                }
            } catch {
                guard path == registryPath, !Task.isCancelled else { return }
                errorMessage = "The engine registry couldn't be read. Choose the current registry file again."
            }
        }
    }
}

private struct NativeEnginePicker: View {
    let provider: RuntimeProviderKind
    let entries: [NativeEngineRegistry.Entry]
    @AppStorage private var selection: String

    init(provider: RuntimeProviderKind, entries: [NativeEngineRegistry.Entry]) {
        self.provider = provider
        self.entries = entries
        _selection = AppStorage(wrappedValue: "", "Xodus.lifecycle.engine.\(provider.rawValue)")
    }

    var body: some View {
        Picker(provider.label, selection: $selection) {
            Text("Choose an engine").tag("")
            if !selection.isEmpty, !entries.contains(where: { $0.name == selection }) {
                Text("\(selection) (unavailable)").tag(selection)
            }
            ForEach(entries) { entry in
                Text("\(entry.engine_label ?? (entry.kind.lowercased() == "free" ? "Free Wine" : "CrossOver")) - \(entry.name)")
                    .tag(entry.name)
            }
        }
        .disabled(entries.isEmpty)
    }
}
