// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore

struct RuntimeInstallationPicker: View {
    @ObservedObject var settings: RuntimeProviderSettings
    var backendPath = ""
    @AppStorage(EngineDefaults.defaultEngineKey) private var defaultProvider = ""
    @AppStorage("Xodus.lifecycle.engine.calimocho") private var calimochoRecord = ""
    @AppStorage("Xodus.lifecycle.registry") private var registryPath = ""
    @StateObject private var registryObservation: EngineRegistryObservation
    @State private var error: String?

    init(settings: RuntimeProviderSettings, backendPath: String = "") {
        self.settings = settings
        self.backendPath = backendPath
        _registryObservation = StateObject(wrappedValue: EngineRegistryObservation(inspector: settings.providerInspector))
    }

    private var allowsFileReads: Bool { !settings.applicationTerminating }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Default engine", value: RuntimeInstallationPicker.defaultEngineName(
                provider: defaultProvider, calimocho: calimochoRecord, entries: registryObservation.entries))
                .accessibilityIdentifier("xodus.engines.default")
            ForEach(RuntimeInstallationPicker.calimochoEntries(registryObservation.entries,
                                                               inspections: registryObservation.inspections)) { entry in
                let inspection = registryObservation.inspections[entry.name]
                let launchReady = inspection.map(RuntimeInstallationPicker.isLaunchReady) == true
                let isDefault = defaultProvider == RuntimeProviderKind.calimocho.rawValue && calimochoRecord == entry.name
                EngineRow(name: entry.engine_label ?? entry.name, version: entry.version, location: nil,
                          status: isDefault ? "Default" : launchReady ? "Ready" : "Not verified") {
                    if !isDefault {
                        Button("Set as Default") {
                            guard let inspection, NativeEngineSettings.persistAdmission(
                                inspection, registryPath: registryPath) else {
                                error = "This engine couldn't be set as default. Refresh the registry and try again."
                                return
                            }
                            EngineDefaults.setDefaultEngine(.calimocho)
                            error = nil
                        }
                        .disabled(!launchReady || !allowsFileReads || registryObservation.status == .loading)
                        .accessibilityLabel("Set \(entry.engine_label ?? entry.name) as default")
                    }
                }
            }
            UserEngineRows(settings: settings, allowsFileReads: allowsFileReads)
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            Divider()
            CrossOverLocationRow(settings: settings, allowsCheck: allowsFileReads)
            Divider()
            NativeEngineSettings(allowsFileReads: allowsFileReads, backendPath: backendPath,
                                 observation: registryObservation, showsEntries: false)
        }
        .disabled(settings.planning || settings.applicationTerminating)
        .task { await settings.refreshCrossOverDependency() }
    }

    static func defaultEngineName(provider: String, calimocho: String,
                                  entries: [NativeEngineRegistry.Entry]) -> String {
        guard provider == RuntimeProviderKind.calimocho.rawValue, !calimocho.isEmpty else { return "None" }
        return entries.first { $0.name == calimocho }?.engine_label ?? calimocho
    }

    static func isLaunchReady(_ inspection: EngineInspection) -> Bool {
        inspection.ready && inspection.admittedProvider == "calimocho"
    }

    /// Calimocho registry records: admitted builds and declared Calimocho records, in registry order.
    static func calimochoEntries(_ entries: [NativeEngineRegistry.Entry],
                                 inspections: [String: EngineInspection]) -> [NativeEngineRegistry.Entry] {
        entries.filter {
            inspections[$0.name].map(isLaunchReady) == true
                || EngineManagementPolicy.matches($0, provider: .calimocho)
        }
    }
}
