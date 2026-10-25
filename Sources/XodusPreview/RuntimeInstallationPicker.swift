// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore
import XodusManagement

struct RuntimeInstallationPicker: View {
    @ObservedObject var settings: RuntimeProviderSettings
    @ObservedObject private var installed: InstalledGamesController
    var backendPath = ""
    var embeddedInSettings = false
    var showsAdvanced = true
    @ObservedObject var userEngineModel: UserEngineModel
    @AppStorage(NativeEngineDefaults.preferenceKey) private var savedAdmission = Data()
    @ObservedObject private var registryObservation: EngineRegistryObservation
    @State private var error: String?
    @State private var settingDefault = false

    init(settings: RuntimeProviderSettings, backendPath: String = "",
         installed: InstalledGamesController? = nil, embeddedInSettings: Bool = false,
         showsAdvanced: Bool = true, registryObservation: EngineRegistryObservation? = nil,
         userEngineModel: UserEngineModel = UserEngineModel()) {
        self.settings = settings
        self.backendPath = backendPath
        self.installed = installed ?? InstalledGamesController()
        self.embeddedInSettings = embeddedInSettings
        self.showsAdvanced = showsAdvanced
        self.userEngineModel = userEngineModel
        _registryObservation = ObservedObject(wrappedValue:
            registryObservation ?? EngineRegistryObservation(inspector: settings.providerInspector))
    }

    private var allowsFileReads: Bool { !settings.applicationTerminating }

    private var configurator: EngineConfiguratorForm<NativeEngineSettings> {
        let defaultID = try? NativeEngineSettings.defaultAdmissionName()
        return EngineConfiguratorForm(
            choices: installed.availableEngineOverrides.compactMap { selection in
                selection.inspection.engineName.map {
                    EngineChoice(id: $0, name: InstalledGamesController.readableEngineName($0), version: nil, ready: true)
                }
            } + installed.failedEngineOverrides.sorted().map {
                EngineChoice(id: $0, name: InstalledGamesController.readableEngineName($0), version: nil, ready: false)
            }, defaultID: defaultID, defaultName: defaultID.map { InstalledGamesController.readableEngineName($0) } ?? "Unavailable",
            checking: installed.checkingEngineOverrides || settingDefault,
            error: error ?? (defaultID == nil ? "The default engine selection couldn't be read. Refresh engines and try again." : nil),
            settings: settings, allowsFileReads: allowsFileReads, userEngineModel: userEngineModel,
            setDefault: { name in
                guard !settingDefault, allowsFileReads else { return }
                settingDefault = true
                Task {
                    defer { settingDefault = false }
                    await installed.refreshEngineOverrides(force: true)
                    guard allowsFileReads, !Task.isCancelled,
                          let selection = installed.availableEngineOverrides.first(where: {
                              $0.inspection.engineName == name
                          }) else {
                        error = "This engine couldn't be verified. Refresh engines and try again."
                        return
                    }
                    do {
                        try NativeEngineSettings.persistDefaultAdmission(selection)
                        error = nil
                    } catch {
                        self.error = "This engine couldn't be set as default. Refresh engines and try again."
                    }
                }
            }, refresh: { Task { await installed.refreshEngineOverrides(force: true) } },
            showsAdvanced: showsAdvanced) {
            NativeEngineSettings(allowsFileReads: allowsFileReads, backendPath: backendPath,
                                 observation: registryObservation, showsEntries: false)
        }
    }

    var body: some View {
        Group {
            if embeddedInSettings { configurator.sections }
            else { configurator }
        }
        .disabled(settings.planning || settings.applicationTerminating)
        .task {
            await installed.refreshEngineOverrides(force: false)
            await settings.refreshCrossOverDependency()
        }
        .onChange(of: savedAdmission) { _, _ in error = nil }
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
