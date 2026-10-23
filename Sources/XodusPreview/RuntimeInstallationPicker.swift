// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore

struct RuntimeInstallationPicker: View {
    @ObservedObject var settings: RuntimeProviderSettings
    @State private var provider: RuntimeProviderKind? = EngineDefaults.defaultEngine()
    @State private var paths = EngineDefaults.runnerPaths()
    @State private var crossOver = EngineDefaults.crossOverApplication()
    @State private var prefixes: [RuntimeProviderKind: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Default game engine", selection: Binding(
                get: { provider }, set: { provider = $0; EngineDefaults.setDefaultEngine($0) })) {
                Text("Automatic").tag(Optional<RuntimeProviderKind>.none)
                ForEach(RuntimeProviderSettings.providerChoices, id: \.self) { kind in
                    Text(RuntimeProviderSettings.providerLabel(kind)).tag(Optional(kind))
                }
            }
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
                    ForEach(RuntimeProviderSettings.providerChoices, id: \.self) { kind in
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
                    Text("Select your installed Wine/GPTK executable or its containing folder. Bottles are identified by their existing layout; nothing is created, migrated or deleted. Versions and licenses of custom engines are not inferred from their filename.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("About Apple's Game Porting Toolkit",
                         destination: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
                }.padding(.top, 10)
            }
            Text("Selections are saved for launch routing. This development build's game-launch integration is still unavailable; selecting a runtime or bottle does not enable Play.")
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
