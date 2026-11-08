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
                            InstalledPlayButton(library: library, operations: operations, game: game)
                            playError(game)
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
                        InstalledPlayButton(library: library, operations: operations, game: game)
                    }
                    InstalledUpdateBadge(library: library, operations: operations, game: game)
                    playError(game)
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

    @ViewBuilder private func playError(_ game: InstalledGame) -> some View {
        InstalledPlayError(library: library, game: game)
    }
}

struct InstalledUpdateBadge: View {
    @ObservedObject var library: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    let game: InstalledGame

    var body: some View {
        EmptyView()
    }
}

struct InstalledPlayError: View {
    @ObservedObject var library: InstalledGamesController
    let game: InstalledGame
    @EnvironmentObject private var state: AppState

    var message: String? {
        if library.playErrors[game.id] != nil {
            return library.accountAccessAllowed ? "This game couldn't start." : "Sign in to play this game."
        }
        if library.unavailableDriveIDs.contains(game.id) {
            return "Connect the game's drive to play."
        }
        if library.packageErrors[game.id] != nil
            || library.installationErrors[game.id] != nil
                && library.installationStatuses[game.id]?.action != .play {
            return "This game can't play right now."
        }
        return nil
    }

    var body: some View {
        if let message {
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.installed.unavailable")
                if library.playErrors[game.id] != nil, !library.accountAccessAllowed {
                    Button("Sign in") { state.openAccount() }
                }
            }
        }
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
    var attention: (() -> Void)?
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
        canStop ? "Stop" : needsRepair || library.placeholderIDs.contains(game.id) ? "Download" : "Play"
    }

    private var canStop: Bool {
        (library.runningGameID == game.id && library.launchStarted) || library.stoppingGameID == game.id
    }

    var unsupportedIssues: [LibraryCompatibilityIssue] {
        operations.supportIssues(productID: game.storeId, packageFormat: game.packageType?.label)
    }

    private var nativeAction: NativeInstallationStatus.Action {
        library.installationStatuses[game.id]?.action ?? .check
    }

    var readinessDiagnostic: String? {
        nil
    }

    var unavailableMessage: String? {
        guard !canStop, !launching else { return nil }
        if library.unavailableDriveIDs.contains(game.id) {
            return "Connect the game's drive to play."
        }
        guard library.requiresNativeInstallationStatus(game), nativeAction == .check,
              library.installationErrors[game.id] != nil else { return nil }
        return "This game can't play right now."
    }

    var nativeActionTitle: String {
        switch nativeAction {
        case .play: return "Play"
        case .install, .resume, .repair: return "Download"
        case .check: return ""
        }
    }

    @ViewBuilder private var nativeInstallationButton: some View {
        Button {
            let action = nativeAction
            Task {
                let product = PCGame(id: game.storeId, title: game.title, artwork: nil)
                switch action {
                case .check: break
                case .install, .resume: await operations.resume(product, installed: game)
                case .repair: await operations.repair(product, installed: game)
                case .play: await library.play(game)
                }
            }
        } label: {
            if heroStyle {
                Label(nativeActionTitle, systemImage: "arrow.down.circle")
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
    }

    @ViewBuilder var body: some View {
        if operations.operation?.productID == game.storeId
            || (operations.installingDirectly && operations.directInstallProductID == game.storeId) {
            GameInstallAction(game: PCGame(id: game.storeId, title: game.title, artwork: nil),
                              operations: operations, enabled: false, primary: prominent)
        } else if let unavailableMessage {
            Text(unavailableMessage)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("xodus.installed.unavailable")
        } else if !canStop, !launching,
                  NativeCandidateLaunchCatalogue.issue(productID: game.storeId,
                    evidence: evidenceStore.games[game.storeId]) != nil {
            EmptyView()
        } else if !canStop, !launching, !unsupportedIssues.isEmpty {
            EmptyView()
        } else if !canStop, !launching, library.requiresNativeInstallationStatus(game), nativeAction != .play {
            if nativeAction != .check { nativeInstallationButton }
        } else {
            actionButton
        }
    }

    @ViewBuilder private var actionButton: some View {
        Button {
            if canStop { operations.stop(game) }
            else if needsRepair {
                Task { await operations.repair(PCGame(id: game.storeId, title: game.title, artwork: nil),
                                              installed: game) }
            }
            else { Task { await library.play(game) } }
        } label: {
            if heroStyle {
                Label(title, systemImage: canStop ? "stop.fill" : needsRepair ? "arrow.down.circle" : "play.fill")
                    .font(.title3.weight(.semibold)).frame(minHeight: 28).padding(.horizontal, 12)
            } else { Text(title) }
        }
        .modifier(LibraryActionStyle(primary: prominent, usesGlass: usesGlass))
        .modifier(LibraryHeroControlSize(enabled: heroStyle))
        .disabled(canStop ? !library.canStop(game) || !operations.canStartMutation
                  : needsRepair ? !operations.canStartMutation || !library.accountAccessAllowed
                    || library.runningGameID != nil || library.stoppingGameID != nil
                  : library.runningGameID != nil || library.stoppingGameID != nil || library.editingBlocksPlay || library.choosing
                  || library.mutationGameID == game.id || library.serviceSignInActive || library.runtimeRepairActive
                  || library.checkingInstallations.contains(game.id)
                  || library.accountDisconnecting || !library.canRequestPlay(game.storeId))
        .accessibilityLabel("\(title) \(game.title)")
        .accessibilityValue(library.stoppingGameID == game.id ? "Stopping"
                            : launching ? "Launching" : readinessDiagnostic ?? "")
        .accessibilityIdentifier(canStop ? "xodus.installed.stop" : "xodus.installed.play")
    }
}
