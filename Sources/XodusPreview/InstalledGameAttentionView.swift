// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

enum InstalledGameActionCopy {
    static let launchUnavailable = "This game can't launch from Ode to X yet. A supported launch setup isn't available."

    static func title(incomplete: Bool, installationIssue: Bool, launchIssue: Bool) -> String {
        incomplete || installationIssue ? "Download" : "Play"
    }
}

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

    private var incomplete: Bool { installed.placeholderIDs.contains(game.id) }
    private var localIssue: Bool {
        driveUnavailable || incomplete || installed.packageErrors[game.id] != nil
    }
    var needsAttention: Bool { localIssue || !installed.accountAccessAllowed }
    var attentionTitle: String {
        game.title
    }
    private var driveUnavailable: Bool { installed.unavailableDriveIDs.contains(game.id) }
    var offersRepair: Bool { localIssue && !driveUnavailable && repairGame != nil && operations.canRepair(game) }

    var body: some View {
        if offersRepair, let repairGame {
            Button("Download") {
                close()
                Task { await operations.prepareInstall(repairGame, repairing: game) }
            }
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
            ScrollView {
            VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                InstalledArtworkView(game: game).frame(width: 72, height: 96).clipped()
                Text(game.title).font(.title2.bold())
            }
            InstalledGameAttentionView(installed: installed, operations: operations, game: game,
                close: dismiss.callAsFunction)
            GameCompatibilityFacts(productID: game.storeId, packageFormat: game.packageType?.label,
                compatibility: operations.compatibility[game.storeId])
            GameSaveLocationView(productID: game.storeId)
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction) }
        }
        .padding(28).frame(width: 560, height: 480)
    }
}
