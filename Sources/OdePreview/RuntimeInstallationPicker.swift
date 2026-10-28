// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import OdeCore
import OdeManagement

struct RuntimeInstallationPicker: View {
    @ObservedObject var settings: RuntimeProviderSettings
    @ObservedObject private var installed: InstalledGamesController
    @ObservedObject private var operations: GameOperationsController
    @ObservedObject private var calimochoInstaller: CalimochoReleaseInstallController
    var backendPath = ""
    var embeddedInSettings = false
    var showsAdvanced = true
    var checkUpdatesOnOpen: Bool
    @ObservedObject var userEngineModel: UserEngineModel
    @AppStorage(NativeEngineDefaults.preferenceKey) private var savedAdmission = Data()
    @ObservedObject private var registryObservation: EngineRegistryObservation
    @State private var error: String?
    @State private var settingDefault = false
    @State private var releaseStatus: CalimochoAvailability?
    @State private var releaseCheck = 0

    init(settings: RuntimeProviderSettings, backendPath: String = "",
         installed: InstalledGamesController? = nil, embeddedInSettings: Bool = false,
         showsAdvanced: Bool = true, registryObservation: EngineRegistryObservation? = nil,
         userEngineModel: UserEngineModel = UserEngineModel(),
         operations: GameOperationsController? = nil,
         calimochoInstaller: CalimochoReleaseInstallController? = nil,
         checkUpdatesOnOpen: Bool = false) {
        self.settings = settings
        self.backendPath = backendPath
        let installedController = installed ?? InstalledGamesController()
        _installed = ObservedObject(wrappedValue: installedController)
        _operations = ObservedObject(wrappedValue:
            operations ?? GameOperationsController(installed: installedController))
        _calimochoInstaller = ObservedObject(wrappedValue:
            calimochoInstaller ?? CalimochoReleaseInstallController())
        self.embeddedInSettings = embeddedInSettings
        self.showsAdvanced = showsAdvanced
        self.checkUpdatesOnOpen = checkUpdatesOnOpen
        self.userEngineModel = userEngineModel
        _registryObservation = ObservedObject(wrappedValue:
            registryObservation ?? EngineRegistryObservation(inspector: settings.providerInspector))
    }

    private var allowsFileReads: Bool { !settings.applicationTerminating }

    /// Default Engine and Engines-list choices: global-default engines only. Title-scoped providers
    /// (CrossOver for No Man's Sky, Highball for Brotato) never appear here; CrossOver has its own row.
    static func defaultEngineChoices(available: [AdmittedEngineSelection], failed: Set<String>) -> [EngineChoice] {
        EngineChoice.disambiguated(rawEngineChoices(available: available, failed: failed))
    }

    private static func rawEngineChoices(available: [AdmittedEngineSelection], failed: Set<String>) -> [EngineChoice] {
        available.filter(NativeEngineDefaults.permitsGlobalDefault).compactMap { selection in
            selection.inspection.engineName.map {
                EngineChoice.named($0, ready: true,
                                   playable: EngineChoice.playsInBeta(admittedProvider: selection.inspection.admittedProvider))
            }
        } + failed.subtracting(NativeEngineDefaults.titleScopedEngineNames)
            .filter { $0 != NativeFH6Recipe.engineName }.sorted().map { EngineChoice.named($0, ready: false) }
    }

    private var configurator: EngineConfiguratorForm<NativeEngineSettings> {
        let defaultID = try? NativeEngineSettings.defaultAdmissionName()
        let choices = Self.defaultEngineChoices(available: installed.availableEngineOverrides,
                                                failed: installed.failedEngineOverrides)
        return EngineConfiguratorForm(
            choices: choices,
            defaultID: defaultID, defaultName: defaultID.map { EngineDisplayName.name($0) } ?? "Unavailable",
            checking: installed.checkingEngineOverrides || settingDefault,
            error: error ?? (defaultID == nil ? "The default engine selection couldn't be read. Refresh engines and try again." : nil),
            settings: settings, allowsFileReads: allowsFileReads, userEngineModel: userEngineModel,
            setDefault: { name in
                guard !settingDefault, !calimochoInstaller.isWorking, allowsFileReads else { return }
                settingDefault = true
                Task {
                    defer { settingDefault = false }
                    await installed.refreshEngineOverrides(force: true)
                    guard allowsFileReads, !Task.isCancelled,
                          let selection = installed.availableEngineOverrides.first(where: {
                              $0.inspection.engineName == name && NativeEngineDefaults.permitsGlobalDefault($0)
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
            }, refresh: {
                releaseCheck += 1
                Task { await installed.refreshEngineOverrides(force: true) }
            },
            showsAdvanced: showsAdvanced,
            calimochoStatus: .status(results: installed, verification: releaseStatus, checking: settingDefault),
            calimochoInstaller: calimochoInstaller,
            engineRemovalBusy: { [installed, operations, settings] in
                settings.applicationTerminating || !installed.loaded
                    || installed.accountDisconnecting || installed.editing || installed.choosing
                    || installed.runningGameID != nil || installed.stoppingGameID != nil
                    || installed.mutationActive || operations.isBusy || operations.serviceBusy
                    || operations.setupRepairing || operations.orphanRunning
                    || operations.recoveryRequired || operations.checkingRecovery
            },
            refreshReleaseAdmission: {
                await installed.refreshEngineOverrides(force: true)
                releaseStatus = await CalimochoAvailability.verifyReleaseInBackground(
                    admission: CalimochoAvailability.admission(in: installed), root: calimochoInstaller.enginesRoot)
                return installed.availableEngineOverrides.contains {
                    $0.inspection.engineName == CalimochoRelease.engineID
                }
            },
            showsCalimochoUpdates: true,
            checkCalimochoUpdatesOnOpen: checkUpdatesOnOpen,
            beginCalimochoUpdate: { old in
                calimochoInstaller.update(from: old, isBusy: {
                    !allowsFileReads || installed.runningGameID != nil || installed.stoppingGameID != nil
                        || installed.mutationActive || operations.isBusy || operations.serviceBusy
                        || operations.setupRepairing || operations.orphanRunning || operations.recoveryRequired
                        || operations.checkingRecovery || settingDefault
                }, reserve: {
                    try installed.reserveMutation(gameID: nil)
                }, release: {
                    installed.releaseMutation()
                }, admit: {
                    await installed.refreshEngineOverrides(force: true)
                    releaseStatus = await CalimochoAvailability.verifyReleaseInBackground(
                        admission: CalimochoAvailability.admission(in: installed), root: calimochoInstaller.enginesRoot)
                    return installed.availableEngineOverrides.contains {
                        $0.inspection.engineName == CalimochoRelease.engineID
                    }
                }, activate: {
                    guard let selection = installed.availableEngineOverrides.first(where: {
                        $0.inspection.engineName == CalimochoRelease.engineID
                    }) else { throw CalimochoUpdateError.admission }
                    try await installed.activateCalimochoUpdate(selection, replacing: old.engineName)
                })
            }, removeOldCalimocho: {
                calimochoInstaller.removeOld(isBusy: {
                    !allowsFileReads || installed.runningGameID != nil || installed.stoppingGameID != nil
                        || installed.mutationActive || operations.isBusy || operations.serviceBusy
                        || operations.setupRepairing || operations.orphanRunning || operations.recoveryRequired
                        || operations.checkingRecovery || settingDefault
                }, reserve: { try installed.reserveMutation(gameID: nil) },
                   release: { installed.releaseMutation() })
            }, backendPath: backendPath) {
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
        .task(id: "\(allowsFileReads):\(releaseCheck):\(installed.availableEngineOverrides.count):\(CalimochoAvailability.rejected(in: installed))") {
            guard allowsFileReads else { return }
            releaseStatus = .checking
            let status = await CalimochoAvailability.verifyReleaseInBackground(
                admission: CalimochoAvailability.admission(in: installed), root: calimochoInstaller.enginesRoot)
            guard !Task.isCancelled else { return }
            releaseStatus = status
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
