// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

enum InstalledGameActionCopy {
    /// REQ-153: the backend refused a per-game engine without the title's recipe (TITLE_RECIPE_REQUIRED).
    static let titleRecipeRequired = "This game needs a newer X Ode to run on this engine. Choose its default engine from the … menu, or update X Ode. No other engine was substituted."
    static let removeKeepingFiles = "Remove from Library (Keep Files)…"
    /// REQ-135: keeping files is the default; deleting is limited to a verified game folder.
    static let deleteGameFiles = "Delete Game Files"
    /// Review 53f2edf1: the inventory compares layout (type and size), not contents, so the copy never claims
    /// "only unmodified files".
    static let uninstallExplanation = "Remove (Keep Files) takes the game out of your library and leaves every file, save and prefix in place. Delete Game Files deletes the files the game's own package installed, including package files you edited if their size didn't change, and keeps saves, Wine prefixes, package files whose size changed and anything else in the folder."
    static let removeKeepingFilesConfirm = "Remove (Keep Files)"
    static let removeKeepingFilesHelp = "Removes this game from the library. The game folder and saves aren't deleted."
    static func removeKeepingFilesTitle(_ title: String) -> String { "Remove \(title) from the library?" }
    static func removeKeepingFilesMessage(folder: String) -> String {
        "No files are deleted. The game folder stays at \(folder) with your saves, and the game can be added back later. To delete the files, use Uninstall."
    }
    static let launchUnavailable = "This game can't launch from \(AppBrand.displayName) yet. A supported launch setup isn't available."

    static func title(incomplete: Bool, installationIssue: Bool, launchIssue: Bool) -> String {
        incomplete ? "Install required" : installationIssue ? "Check installation"
            : launchIssue ? "Review launch issue" : "View details"
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
    var installationCheckInHeader = false
    let close: () -> Void
    @State private var confirmingRemoval = false
    @Environment(\.openSettings) private var openSettings

    private var incomplete: Bool { installed.placeholderIDs.contains(game.id) }
    private var damaged: String? { operations.damagedInstallations[game.id] }
    private var localIssue: Bool {
        driveUnavailable || incomplete || damaged != nil || installed.packageErrors[game.id] != nil
            || installed.installationErrors[game.id] != nil
            || installed.installationStatuses[game.id].map { !$0.success || $0.status != .complete } == true
    }
    var needsAttention: Bool { localIssue || !installed.accountAccessAllowed || installed.productAccessNotice(for: game) != nil }
    var attentionTitle: String {
        driveUnavailable ? "Drive unavailable" : localIssue ? "Installation needs attention"
            : "Game launching unavailable"
    }
    private var driveUnavailable: Bool { installed.unavailableDriveIDs.contains(game.id) }
    var offersRepair: Bool { localIssue && !driveUnavailable && repairGame != nil && operations.canRepair(game) }
    var offersInstallationCheck: Bool { localIssue && !installationCheckInHeader }

    /// After install the access check runs automatically; show it as one in-progress status, not a warning.
    var accessChecking: Bool {
        !localIssue && installed.accountAccessAllowed && installed.productAccess.checking
            && installed.productAccessNotice(for: game) != nil
    }

    var body: some View {
        if needsAttention {
            VStack(alignment: .leading, spacing: 12) {
                if accessChecking {
                    ProgressView("Checking game access…").controlSize(.small)
                        .accessibilityIdentifier("xodus.game.checkingAccess")
                } else {
                InstallationWarning(message: driveUnavailable ? InstalledGamesController.driveUnavailableMessage
                     : incomplete ? "This game isn't fully installed."
                     : damaged != nil ? damaged ?? ""
                     : localIssue ? installed.packageErrors[game.id] ?? installed.installationErrors[game.id]
                        ?? installed.installationStatuses[game.id]?.explanation ?? "Installation verification is incomplete. Retry to verify this game."
                     : installed.accountAccessAllowed ? "Couldn't confirm game access." : installed.accountAccessMessage,
                     showsMessage: true)
                }
                if !localIssue && !accessChecking {
                    if installed.accountAccessAllowed, let notice = installed.productAccessNotice(for: game) {
                        Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("xodus.game.accessReason")
                        if installed.canRetryProductAccess {
                            // f51e60fe m-b: during the pause, Retry says until when and stays disabled.
                            let pausedEnd = installed.productAccess.pausedEnd()
                            Button(pausedEnd.map { "Retry after \($0)" } ?? "Retry") {
                                Task { await installed.retryProductAccess(for: game) }
                            }
                                .disabled(pausedEnd != nil)
                                .help("Checks this exact game's account access without downloading or launching.")
                                .accessibilityIdentifier("xodus.game.retryAccess")
                        } else {
                            Button("Open settings", action: openSettings.callAsFunction)
                        }
                    } else {
                        Button("Open settings", action: openSettings.callAsFunction)
                    }
                }
                if offersInstallationCheck && installed.checkingInstallations.contains(game.id) {
                    ProgressView("Checking installation").controlSize(.small)
                    Button("Cancel") { installed.cancelInstallationCheck(game) }
                } else if localIssue {
                    HStack {
                        if offersInstallationCheck {
                            Button("Retry") {
                                Task { await installed.checkInstallation(game) }
                            }
                            .disabled(installed.editing || installed.mutationActive)
                            .help("Checks the game folder and launch files without downloading or starting the game.")
                        }
                        if offersRepair, let repairGame {
                            Button(incomplete ? "Install full game" : "Repair installation") {
                                close()
                                Task { await operations.prepareInstall(repairGame, repairing: game) }
                            }
                        }
                    }
                }
                LabeledContent("Installed location") {
                    Text(game.folder).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(InstalledGameActionCopy.removeKeepingFiles, role: .destructive) { confirmingRemoval = true }
                    .help(InstalledGameActionCopy.removeKeepingFilesHelp)
                    .disabled(installed.editing || installed.mutationActive || installed.runningGameID == game.id)
                if let error = installed.error {
                    InstallationWarning(message: error)
                }
                DisclosureGroup("Technical details") {
                    InstalledPackageTypeLabel(game: game)
                    InstalledPlayError(library: installed, game: game)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("xodus.game.needsAttention")
            .confirmationDialog(InstalledGameActionCopy.removeKeepingFilesTitle(game.title), isPresented: $confirmingRemoval) {
                Button(InstalledGameActionCopy.removeKeepingFilesConfirm, role: .destructive) {
                    Task {
                        await installed.remove(game)
                        if !installed.games.contains(where: { $0.id == game.id }) { close() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text(InstalledGameActionCopy.removeKeepingFilesMessage(folder: game.folder)) }
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
        .task { await installed.automaticallyCheckInstallation(game) }
    }
}
