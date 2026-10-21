// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import XodusCore

struct NativeEngineSettings: View {
    let allowsFileReads: Bool
    @AppStorage("Xodus.lifecycle.registry") private var registryPath = ""
    @State private var entries: [NativeEngineRegistry.Entry] = []
    @State private var errorMessage: String?

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
                Text("Play is waiting for the matching primary and legacy runtime pair to be qualified. No runtime is silently substituted.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
                entries = loaded.filter { $0.smoke_test.status == "pass" }
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
            ForEach(entries) { entry in Text(entry.name).tag(entry.name) }
        }
        .disabled(entries.isEmpty)
    }
}
