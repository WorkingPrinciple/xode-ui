// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore

struct RuntimeInstallationPicker: View {
    @ObservedObject var settings: RuntimeProviderSettings
    var backendPath = ""
    @AppStorage(EngineDefaults.defaultEngineKey) private var defaultProvider = ""
    @AppStorage("Xodus.lifecycle.engine.standaloneWine") private var wineRecord = ""
    @AppStorage("Xodus.lifecycle.engine.crossover") private var crossOverRecord = ""
    @AppStorage("Xodus.lifecycle.engine.calimocho") private var calimochoRecord = ""
    @StateObject private var registryObservation: EngineRegistryObservation
    @State private var paths = EngineDefaults.runnerPaths()
    @State private var crossOver = EngineDefaults.crossOverApplication()
    @State private var prefixes: [RuntimeProviderKind: String] = [:]
    @State private var error: String?

    init(settings: RuntimeProviderSettings, backendPath: String = "") {
        self.settings = settings
        self.backendPath = backendPath
        _registryObservation = StateObject(wrappedValue: EngineRegistryObservation(inspector: settings.providerInspector))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EngineProviderOverview(settings: settings, inspections: registryObservation.inspections)
            Divider()
            Picker("Default game engine", selection: Binding(
                get: { RuntimeProviderKind(rawValue: defaultProvider) },
                set: { defaultProvider = $0?.rawValue ?? "" })) {
                Text("No default selected").tag(Optional<RuntimeProviderKind>.none)
                if let saved = RuntimeProviderKind(rawValue: defaultProvider), saved != .calimocho {
                    Text("\(saved.label) (historical, cannot launch)").tag(Optional(saved))
                }
                ForEach(RuntimeProviderSettings.providerChoices, id: \.self) { kind in
                    Text(RuntimeProviderSettings.providerLabel(kind)).tag(Optional(kind))
                }
            }
            if let kind = RuntimeProviderKind(rawValue: defaultProvider) {
                if kind == .calimocho {
                    let name = calimochoRecord
                    Text(name.isEmpty ? "No exact registry engine selected for this default."
                         : "Configured registry engine: \(name)")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("This historical default is retained for reference, but current launches require verified Calimocho. No old prefix is adopted or migrated.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(EngineManagementPolicy.selectionExplanation)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            NativeEngineSettings(allowsFileReads: !settings.applicationTerminating,
                                 backendPath: backendPath, observation: registryObservation)
            HStack {
                Text(crossOver.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "CrossOver: automatic detection")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose CrossOver app…") { chooseCrossOver() }
            }
            if crossOver != nil {
                Button("Use automatic CrossOver detection") {
                    EngineDefaults.setCrossOverApplication(nil)
                    crossOver = nil
                    Task { await settings.refreshCrossOverDependency() }
                }
            }
            DisclosureGroup("Wine, GPTK and existing bottles") {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(RuntimeProviderKind.allCases.filter { $0 != .calimocho }, id: \.self) { kind in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(kind.label).font(.headline)
                            if kind != .crossover {
                                Text(paths[kind] ?? "No executable selected")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                                HStack {
                                    Button("Choose installation…") { chooseRunner(kind) }
                                    if paths[kind] != nil {
                                        Button("Clear executable") {
                                            EngineDefaults.setRunnerPath("", for: kind)
                                            paths[kind] = nil
                                        }
                                    }
                                }
                            }
                            Text(prefixes[kind] ?? EngineDefaults.prefixPath(kind) ?? "No existing bottle selected")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle)
                            HStack {
                                Button("Choose bottle or prefix…") { choosePrefix(kind) }
                                if prefixes[kind] != nil || EngineDefaults.prefixPath(kind) != nil {
                                    Button("Clear bottle") {
                                        EngineDefaults.setPrefixPath(nil, for: kind)
                                        prefixes[kind] = nil
                                    }
                                }
                            }
                        }
                    }
                    Text("Historical engine and bottle locations are retained separately. They do not admit a Calimocho build or enable legacy execution. Nothing is created, migrated or deleted.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("About Apple's Game Porting Toolkit",
                         destination: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
                }.padding(.top, 10)
            }
            Text("Calimocho launches use the exact admitted registry configuration. A per-game selection keeps its own saved identity independently of the default. A conflicting title recipe refuses launch instead of substituting an engine or prefix.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
        }
        .disabled(settings.planning || settings.applicationTerminating)
    }

    private func chooseCrossOver() {
        let panel = NSOpenPanel()
        panel.message = "Choose your official CrossOver application."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let observed = await Task.detached(priority: .utility) { CrossOverDetector.inspect(url) }.value
            guard observed.isVerified else {
                error = "This app couldn't be verified as official CrossOver. Choose the CodeWeavers app or install its trial."
                return
            }
            EngineDefaults.setCrossOverApplication(url.path)
            crossOver = url.path
            error = nil
            await settings.refreshCrossOverDependency()
        }
    }

    private func chooseRunner(_ kind: RuntimeProviderKind) {
        let panel = NSOpenPanel()
        panel.message = "Choose the \(kind.label) executable, application or installation folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let executable = RunnerAvailabilityDetector.executable(in: url) else {
            error = "No Wine executable was found in that selection. Choose its wine or wine64 executable directly."
            return
        }
        EngineDefaults.setRunnerPath(executable.path, for: kind)
        paths[kind] = executable.path
        error = nil
    }

    private func choosePrefix(_ kind: RuntimeProviderKind) {
        let panel = NSOpenPanel()
        panel.message = "Choose an existing \(kind.label) bottle or Wine prefix. It will not be modified."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard RunnerAvailabilityDetector.isPrefix(url) else {
            error = "This folder isn't an identifiable Wine prefix or CrossOver bottle. Choose the folder containing drive_c and system.reg or cxbottle.conf."
            return
        }
        EngineDefaults.setPrefixPath(url.path, for: kind)
        prefixes[kind] = url.path
        error = nil
    }
}
