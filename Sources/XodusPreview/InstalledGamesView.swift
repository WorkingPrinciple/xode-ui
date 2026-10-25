// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusCore

struct InstalledGamesView: View {
    @ObservedObject var library: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    var allowsArtworkLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let game = library.continuingGame {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Continue Playing").font(.title2.bold())
                    VStack(alignment: .leading, spacing: 0) {
                        InstalledArtworkView(game: game, splash: true, allowsLoading: allowsArtworkLoading)
                            .frame(height: 260)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(game.title).font(.largeTitle.bold())
                                .fixedSize(horizontal: false, vertical: true)
                            if let publisher = game.publisher {
                                Text(publisher).foregroundStyle(.secondary)
                            }
                            if let date = game.lastPlayedAt {
                                Text("Last played \(Text(date, style: .relative)) ago")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            InstalledPlayButton(library: library, operations: operations, game: game, showsDiagnostics: false)
                        }
                        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Continue Playing, \(game.title)")
                }
                .padding(.bottom, 10)
            }
            HStack {
                Text("Installed").font(.title.bold())
                Spacer()
                if !library.games.isEmpty { importButton }
            }
            if let error = library.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.installed.error")
                if !library.loaded {
                    Button("Try again") { Task { await library.load() } }
                        .disabled(library.loading)
                        .accessibilityIdentifier("xodus.installed.retryLoad")
                }
            }
            if let error = library.historyError {
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("xodus.installed.historyError")
            }
            if library.loading {
                ProgressView("Loading installed games").controlSize(.small)
            } else if library.loaded, library.games.isEmpty {
                Text("Add a game you've already installed with Ode to X.")
                    .foregroundStyle(.secondary)
                importButton
            }
            ForEach(library.games) { game in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        InstalledArtworkView(game: game, allowsLoading: allowsArtworkLoading)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                            if let format = game.packageType, format != .unknown {
                                Text(format.label).font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("xodus.installed.packageType")
                            }
                        }
                        Spacer()
                        InstalledGameActions(library: library, operations: operations, game: game)
                        InstalledPlayButton(library: library, operations: operations, game: game, showsDiagnostics: false)
                    }
                    InstalledUpdateBadge(library: library, operations: operations, game: game)
                }
                .accessibilityElement(children: .contain)
                Divider()
            }
        }
    }

    private var importButton: some View {
        Button("Import installed Xbox game") { Task { await library.chooseGame() } }
            .disabled(!library.loaded || library.editing || library.choosing || library.mutationActive)
            .accessibilityIdentifier("xodus.installed.import")
    }

}

struct InstalledUpdateBadge: View {
    @ObservedObject var library: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    let game: InstalledGame

    var body: some View {
        if library.updateStatus(for: game).hasUpdate {
            HStack(spacing: 10) {
                Label("Update available", systemImage: "arrow.down.circle")
                    .font(.callout.weight(.medium)).foregroundStyle(.tint)
                    .accessibilityIdentifier("xodus.installed.updateAvailable")
                if let version = library.availableVersions[game.storeId] {
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update") {
                    Task {
                        await operations.repair(
                            PCGame(id: game.storeId, title: game.title, artwork: nil), installed: game)
                    }
                }
                .disabled(!operations.canRepair(game))
                .accessibilityIdentifier("xodus.installed.update")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct InstalledPlayError: View {
    @ObservedObject var library: InstalledGamesController
    let game: InstalledGame

    var body: some View {
        if let message = library.packageErrors[game.id] ?? library.playErrors[game.id] ?? library.playNotices[game.id] {
            InstallationWarning(message: message)
        }
    }
}

struct InstallationWarning: View {
    let message: String

    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .help(message)
            .focusable()
            .accessibilityLabel(message)
            .accessibilityIdentifier("xodus.installed.detailWarning")
    }
}

struct InstalledEngineOverride: View {
    @ObservedObject var library: InstalledGamesController
    let game: InstalledGame

    var body: some View {
        Menu {
            Picker("Engine", selection: Binding(
                get: { game.engineOverride },
                set: { value in Task { await library.setEngineOverride(value, for: game) } })) {
                Text("Use default engine").tag(Optional<RuntimeProviderKind>.none)
                ForEach(RuntimeProviderSettings.providerChoices, id: \.self) { provider in
                    Text(RuntimeProviderSettings.providerLabel(provider)).tag(Optional(provider))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(game.engineOverride.map(RuntimeProviderSettings.providerLabel) ?? "Default engine",
                  systemImage: "gearshape")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(library.runningGameID == game.id || library.editing || library.choosing
                  || library.mutationActive || library.applicationTerminating)
        .accessibilityLabel("Engine for \(game.title)")
        .accessibilityValue(game.engineOverride.map(RuntimeProviderSettings.providerLabel) ?? "Use default engine")
        .help(game.engineOverride.map { "Engine override: \(RuntimeProviderSettings.providerLabel($0))" }
              ?? "Launch with the default engine")
        .accessibilityIdentifier("xodus.installed.engineOverride")
    }

}

struct InstalledPackageTypeLabel: View {
    let game: InstalledGame

    var body: some View {
        if let type = game.packageType, type != .unknown {
            Text("Detected: \(type.label)")
                .font(.caption).foregroundStyle(.secondary)
                .help("Format detected from installed files, not a compatibility verdict.")
                .accessibilityIdentifier("xodus.installed.packageType")
        }
    }
}

struct InstalledPlayButton: View {
    @ObservedObject var library: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    @ObservedObject private var evidenceStore = MacGameEvidenceStore.shared
    let game: InstalledGame
    var usesGlass = false
    var prominent = true
    var heroStyle = false
    var showsDiagnostics = true
    var attention: (() -> Void)?
    private var needsAttention: Bool {
        !canStop && !launching && (library.placeholderIDs.contains(game.id)
            || library.packageErrors[game.id] != nil || library.playErrors[game.id] != nil
            || !library.accountAccessAllowed)
    }
    private var opensAttention: Bool { needsAttention && attention != nil }
    private var needsRepair: Bool {
        library.placeholderIDs.contains(game.id) || library.packageErrors[game.id] != nil
    }
    private var launching: Bool {
        library.runningGameID == game.id && library.playState == .launching
    }
    var loadingTitle: String? {
        guard library.stoppingGameID == game.id || launching else { return nil }
        return GameLaunchPresentation.title(game: game.title,
            stopping: library.stoppingGameID == game.id,
            checking: library.checkingInstallations.contains(game.id), started: library.launchStarted)
    }
    var title: String {
        library.stoppingGameID == game.id ? "Stopping" : launching ? "Launching" : canStop ? "Stop"
            : opensAttention ? InstalledGameActionCopy.title(
                incomplete: library.placeholderIDs.contains(game.id),
                installationIssue: library.packageErrors[game.id] != nil,
                launchIssue: library.accountAccessAllowed && library.playErrors[game.id] != nil)
            : needsRepair ? "Repair"
            : library.playErrors[game.id] == nil ? "Play" : "Try again"
    }

    private var canStop: Bool {
        (library.runningGameID == game.id && library.launchStarted) || library.stoppingGameID == game.id
    }

    var unsupportedIssues: [LibraryCompatibilityIssue] {
        operations.supportIssues(productID: game.storeId, packageFormat: game.packageType?.label)
    }

    private var nativeAction: NativeInstallationStatus.Action {
        if library.packageErrors[game.id] != nil || library.unavailableDriveIDs.contains(game.id) { return .check }
        return library.installationStatuses[game.id]?.action ?? .check
    }

    var nativeActionTitle: String {
        if library.checkingInstallations.contains(game.id) { return "Checking installation…" }
        switch nativeAction {
        case .play: return "Play"
        case .install: return "Install"
        case .resume: return "Resume"
        case .repair: return "Repair"
        case .check: return "Check installation"
        }
    }

    var ownsInstallationCheck: Bool {
        guard !canStop, !launching, operations.operation?.productID != game.storeId,
              !(operations.installingDirectly && operations.directInstallProductID == game.storeId) else { return false }
        if library.unavailableDriveIDs.contains(game.id) { return true }
        return NativeCandidateLaunchCatalogue.issue(productID: game.storeId,
            evidence: evidenceStore.games[game.storeId]) == nil && unsupportedIssues.isEmpty
            && library.requiresNativeInstallationStatus(game) && nativeAction == .check
    }

    @ViewBuilder private var nativeInstallationButton: some View {
        Button {
            let action = nativeAction
            Task {
                let product = PCGame(id: game.storeId, title: game.title, artwork: nil)
                switch action {
                case .check: await library.checkInstallation(game)
                case .install, .resume: await operations.resume(product, installed: game)
                case .repair: await operations.repair(product, installed: game)
                case .play: await library.play(game)
                }
            }
        } label: {
            if heroStyle {
                Label(nativeActionTitle, systemImage: nativeAction == .repair ? "wrench"
                      : nativeAction == .check ? "checkmark.shield" : "arrow.down.circle")
                    .font(.title3.weight(.semibold)).frame(minHeight: 28).padding(.horizontal, 12)
            } else { Text(nativeActionTitle) }
        }
        .modifier(LibraryActionStyle(primary: prominent, usesGlass: usesGlass))
        .modifier(LibraryHeroControlSize(enabled: heroStyle))
        .disabled(library.checkingInstallations.contains(game.id) || library.editing || library.choosing
                  || library.applicationTerminating
                  || (nativeAction != .check && (!operations.canStartMutation || library.runningGameID != nil)))
        .accessibilityLabel("\(nativeActionTitle) for \(game.title)")
        .accessibilityIdentifier("xodus.installed.readinessAction")
        if library.checkingInstallations.contains(game.id) {
            ProgressView().controlSize(.small).accessibilityLabel("Checking installation of \(game.title)")
            Button("Cancel") { library.cancelInstallationCheck(game) }
        }
        if showsDiagnostics, attention == nil, !library.checkingInstallations.contains(game.id),
           let reason = library.installationErrors[game.id] ?? library.installationStatuses[game.id]?.explanation {
            InstallationWarning(message: reason)
        }
    }

    @ViewBuilder var body: some View {
        if launching && !library.launchStarted {
            ProgressView(library.checkingInstallations.contains(game.id) ? "Checking installation" : "Preparing game")
                .controlSize(.small)
            Button("Cancel") { library.cancelInstallationCheck(game) }
        } else if operations.operation?.productID == game.storeId
            || (operations.installingDirectly && operations.directInstallProductID == game.storeId) {
            GameInstallAction(game: PCGame(id: game.storeId, title: game.title, artwork: nil),
                              operations: operations, enabled: false, primary: prominent, showsDiagnostics: showsDiagnostics)
        } else if !canStop, !launching, library.unavailableDriveIDs.contains(game.id) {
            VStack(alignment: .leading, spacing: 8) {
                if showsDiagnostics {
                    InstallationWarning(message: InstalledGamesController.driveUnavailableMessage)
                }
                Button("Check again") { Task { await library.checkInstallation(game) } }
                    .disabled(library.editing || library.mutationActive || library.accountDisconnecting
                              || library.applicationTerminating)
            }.accessibilityIdentifier("xodus.installed.driveUnavailable")
        } else if !canStop, !launching,
                  NativeCandidateLaunchCatalogue.issue(productID: game.storeId,
                    evidence: evidenceStore.games[game.storeId]) != nil {
            Label("Launch unavailable", systemImage: "exclamationmark.circle")
                .font(.caption).help(InstalledGameActionCopy.launchUnavailable)
                .accessibilityLabel("Launch unavailable for \(game.title). \(InstalledGameActionCopy.launchUnavailable)")
                .accessibilityIdentifier("xodus.installed.candidateBlocked")
        } else if !canStop, !launching, !unsupportedIssues.isEmpty {
            LibraryCompatibilityIndicators(issues: unsupportedIssues, heroStyle: heroStyle)
        } else if !canStop, !launching, library.requiresNativeInstallationStatus(game), nativeAction != .play {
            nativeInstallationButton
        } else {
            actionButton
            if library.updateStatus(for: game).hasUpdate {
                Label("Update available", systemImage: "arrow.down.circle").font(.caption)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        Button {
            if opensAttention { attention?() }
            else if canStop { operations.stop(game) }
            else if needsRepair {
                Task { await operations.repair(PCGame(id: game.storeId, title: game.title, artwork: nil),
                                              installed: game) }
            }
            else { Task { await library.play(game) } }
        } label: {
            if heroStyle {
                Label(title, systemImage: canStop ? "stop.fill" : needsRepair ? "wrench" : "play.fill")
                    .font(.title3.weight(.semibold)).frame(minHeight: 28).padding(.horizontal, 12)
            } else { Text(title) }
        }
        .modifier(LibraryActionStyle(primary: prominent, usesGlass: usesGlass))
        .modifier(LibraryHeroControlSize(enabled: heroStyle))
        .disabled(opensAttention ? library.editing || library.choosing || library.accountDisconnecting
                   || library.applicationTerminating
                   : canStop ? !library.canStop(game) || !operations.canStartMutation
                  : needsRepair ? !operations.canStartMutation || !library.accountAccessAllowed
                    || library.runningGameID != nil || library.stoppingGameID != nil
                  : library.runningGameID != nil || library.stoppingGameID != nil || library.editing || library.choosing
                  || library.mutationGameID == game.id || library.serviceSignInActive || library.runtimeRepairActive
                  || library.checkingInstallations.contains(game.id)
                  || library.accountDisconnecting || !library.canRequestPlay(game.storeId))
        .accessibilityLabel(opensAttention ? "\(title) for \(game.title)"
             : canStop ? "Stop \(game.title)" : launching ? "Launching \(game.title)"
            : !library.canRequestPlay(game.storeId) ? "Play \(game.title), game access hasn't been confirmed"
            : needsRepair ? "Repair \(game.title)" : "Play \(game.title)")
        .help(opensAttention ? "Open \(game.title) to see installation, compatibility and launch availability"
              : !canStop && !library.canRequestPlay(game.storeId)
                ? "This account's access to the game hasn't been confirmed." : "")
        .accessibilityValue(library.stoppingGameID == game.id ? "Stopping" : launching ? "Launching" : "")
        .accessibilityIdentifier(opensAttention ? "xodus.installed.attention"
                                : canStop ? "xodus.installed.stop" : "xodus.installed.play")
        if let loadingTitle {
            OdeLoadingStatus(title: loadingTitle,
                message: library.stoppingGameID == game.id ? nil : "Waiting for the game launcher.")
        }
    }
}
