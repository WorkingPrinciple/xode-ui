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
                Text("Add a game you've already installed with Xodus.")
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
                        InstalledEngineOverride(library: library, game: game)
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
                        await operations.prepareInstall(
                            PCGame(id: game.storeId, title: game.title, artwork: nil), repairing: game)
                    }
                }
                .disabled(!operations.canStartMutation || library.runningGameID == game.id)
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
        if let error = library.packageErrors[game.id] {
            Text(error).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("xodus.installed.packageError")
        }
        if let error = library.playErrors[game.id] {
            Text(error).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("xodus.installed.playError")
            if library.playLogs[game.id] != nil {
                Button("Show log") { library.showLog(for: game) }
                    .accessibilityLabel("Show \(game.title) log in Finder")
                    .accessibilityIdentifier("xodus.installed.showLog")
            }
        } else if let notice = library.playNotices[game.id] {
            Text(notice).font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("xodus.installed.playResult")
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
    let game: InstalledGame
    var usesGlass = false
    var prominent = true
    var heroStyle = false
    private var launching: Bool {
        library.runningGameID == game.id && library.playState == .launching
    }
    private var title: String {
        library.stoppingGameID == game.id ? "Stopping" : launching ? "Launching" : canStop ? "Stop"
            : library.playErrors[game.id] == nil ? "Play" : "Try again"
    }

    private var canStop: Bool {
        (library.runningGameID == game.id && library.launchStarted) || library.stoppingGameID == game.id
    }

    var body: some View {
        Button {
            if canStop { operations.stop(game) }
            else { Task { await library.play(game) } }
        } label: {
            if heroStyle {
                Label(title, systemImage: canStop ? "stop.fill" : "play.fill")
                    .font(.title3.weight(.semibold)).frame(minHeight: 28).padding(.horizontal, 12)
            } else { Text(title) }
        }
        .modifier(LibraryActionStyle(primary: prominent, usesGlass: usesGlass))
        .modifier(LibraryHeroControlSize(enabled: heroStyle))
        .disabled(canStop ? !library.canStop(game) || !operations.canStartMutation
                  : library.runningGameID != nil || library.stoppingGameID != nil || library.editing || library.choosing
                  || library.mutationGameID == game.id || library.serviceSignInActive || library.runtimeRepairActive)
        .accessibilityLabel(canStop ? "Stop \(game.title)" : launching ? "Launching \(game.title)" : "Play \(game.title)")
        .accessibilityValue(library.stoppingGameID == game.id ? "Stopping" : launching ? "Launching" : "")
        .accessibilityIdentifier(canStop ? "xodus.installed.stop" : "xodus.installed.play")
        if library.stoppingGameID == game.id || launching {
            ProgressView(library.stoppingGameID == game.id ? "Stopping" : "Launching").controlSize(.small)
        }
    }
}
