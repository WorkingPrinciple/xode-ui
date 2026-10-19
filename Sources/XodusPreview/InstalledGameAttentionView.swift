// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

struct InstalledGameDetailSelection: Identifiable {
    let game: InstalledGame
    let product: CatalogProduct?
    var id: UUID { game.id }
}

struct InstalledGameAttentionView: View {
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    let game: InstalledGame
    var repairGame: PCGame?
    let close: () -> Void
    @State private var confirmingRemoval = false

    private var incomplete: Bool { installed.placeholderIDs.contains(game.id) }
    private var localIssue: Bool { incomplete || installed.packageErrors[game.id] != nil || installed.playErrors[game.id] != nil }
    private var needsAttention: Bool { localIssue || !installed.accountAccessAllowed }

    var body: some View {
        if needsAttention {
            VStack(alignment: .leading, spacing: 12) {
                Label("Needs attention", systemImage: "exclamationmark.circle")
                    .font(.headline)
                Text(incomplete ? "This game isn't fully installed."
                     : localIssue ? "The installation or launch files need to be checked."
                     : "Game launching isn't available in this development build yet.")
                    .fixedSize(horizontal: false, vertical: true)
                if installed.checkingInstallations.contains(game.id) {
                    ProgressView("Checking installation").controlSize(.small)
                } else if localIssue {
                    HStack {
                        Button("Check installation") { Task { await installed.checkInstallation(game) } }
                            .disabled(installed.editing || installed.mutationActive)
                            .help("Checks the game folder and launch files without downloading or starting the game.")
                        if let repairGame, operations.canStartMutation {
                            Button(incomplete ? "Install full game" : "Repair installation") {
                                close()
                                Task { await operations.prepareInstall(repairGame, repairing: game) }
                            }
                        }
                    }
                }
                Button("Remove from library", role: .destructive) { confirmingRemoval = true }
                    .disabled(installed.editing || installed.mutationActive || installed.runningGameID == game.id)
                if let error = installed.error {
                    Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Technical details") {
                    InstalledPackageTypeLabel(game: game)
                    if let error = installed.packageErrors[game.id] {
                        Text(error).font(.callout).textSelection(.enabled)
                    }
                    InstalledPlayError(library: installed, game: game)
                    InstalledEngineOverride(library: installed, game: game)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("xodus.game.needsAttention")
            .confirmationDialog("Remove \(game.title) from your library?", isPresented: $confirmingRemoval) {
                Button("Remove from library", role: .destructive) {
                    Task {
                        await installed.remove(game)
                        if !installed.games.contains(where: { $0.id == game.id }) { close() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your game files and saves will stay on this Mac.") }
        }
    }
}

struct LocalInstalledGameView: View {
    let game: InstalledGame
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                InstalledArtworkView(game: game).frame(width: 72, height: 96).clipped()
                Text(game.title).font(.title2.bold())
            }
            InstalledGameAttentionView(installed: installed, operations: operations, game: game,
                close: dismiss.callAsFunction)
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Done", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction) }
        }
        .padding(28).frame(width: 560, height: 480)
        .task { await installed.checkInstallation(game) }
    }
}
