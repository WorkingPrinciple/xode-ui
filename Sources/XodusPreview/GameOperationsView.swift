// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

struct GameServiceAccountView: View {
    @ObservedObject var operations: GameOperationsController
    @ObservedObject var library: PCGamesController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccountTierView(entitlements: operations.accountEntitlements(library: library))
            GroupBox("Microsoft PC games") {
                VStack(alignment: .leading, spacing: 10) {
                    if library.hasSavedSignIn {
                        HStack {
                            Label("PC Library sign-in saved", systemImage: "checkmark.circle")
                            Spacer()
                            Button("Sign out") { Task { await library.signOut() } }
                                .disabled(library.busy).accessibilityIdentifier("xodus.pcGames.signOut")
                        }
                    } else {
                        Text("Use the main Microsoft sign-in to load your PC game library.")
                            .foregroundStyle(.secondary)
                    }
                    Text("Library access and game-service access are checked separately.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            GroupBox("Game access") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(operations.serviceLabel, systemImage: operations.serviceAccountSymbol)
                        .accessibilityIdentifier("xodus.games.accountStatus")
                    Text("Required for package checks, downloads and gameplay.")
                        .font(.callout).foregroundStyle(.secondary)
                    if operations.serviceAccountNeedsVerification {
                        Text("Your game sign-in is saved, but its Xbox account hasn't been confirmed. Verify it to load Profile, Achievements and My Consoles.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("xodus.games.verifyExplanation")
                    }
                    HStack {
                        Button("Check status") { operations.refreshService() }
                            .disabled(operations.serviceBusy || operations.setupRepairing)
                            .accessibilityIdentifier("xodus.games.checkSignIn")
                        if let title = operations.serviceSignInActionTitle {
                            Button(title) { operations.signInForGames() }
                                .disabled(!operations.canSignIn)
                                .accessibilityIdentifier("xodus.games.signIn")
                        }
                        if operations.serviceBusy {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(operations.serviceSigningIn ? "Signing in for games" : "Checking game access")
                        }
                    }
                    if operations.serviceSigningIn {
                        Text("Finish signing in in the Microsoft window.").foregroundStyle(.secondary)
                    }
                    if let error = operations.serviceError {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("xodus.games.signInError")
                        if operations.serviceLog != nil {
                            Button("Show log") { operations.showServiceLog() }
                                .accessibilityIdentifier("xodus.games.signInLog")
                        }
                    }
                }
            }
            GroupBox("PC Game Pass") {
                GamePassAccountView(operations: operations, library: library)
                    .padding(.top, 2)
            }
            GroupBox("Xodus setup") {
                GameSetupView(operations: operations, showsTitle: false)
                    .padding(.top, 2)
            }
        }
    }
}

struct GamePassAccountView: View {
    @ObservedObject var operations: GameOperationsController
    @ObservedObject var library: PCGamesController
    @EnvironmentObject private var session: LiveSession

    private var probeID: String? {
        GameOperationsController.gamePassProbes(discoveryProducts: session.gamePassProducts,
                                                ownedGames: library.snapshot?.games,
                                                compatibility: operations.compatibility).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(operations.gamePassLabel)
                    .accessibilityIdentifier("xodus.gamePass.status")
                Spacer()
                Button("Check") {
                    operations.checkGamePass(discoveryProducts: session.gamePassProducts,
                                             ownedGames: library.snapshot?.games)
                }
                .disabled(!operations.canStartMutation || operations.installConsent != nil
                    || operations.uninstallConsent != nil || probeID == nil)
                .accessibilityLabel("Check PC Game Pass")
                .accessibilityIdentifier("xodus.gamePass.check")
                if operations.gamePassBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking PC Game Pass")
                }
            }
            if operations.gamePassFromCache {
                Text("Saved status on this Mac. Check to refresh.").font(.callout).foregroundStyle(.secondary)
            }
            if probeID == nil {
                Text("Load your PC library and browse Discover to check PC Game Pass.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = operations.gamePassError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if operations.gamePassFailureCode == 11 {
                    Button("Sign in for games") { operations.signInForGames() }
                        .disabled(!operations.canSignIn)
                }
                if operations.gamePassLog != nil {
                    Button("Show log") { operations.showGamePassLog() }
                        .accessibilityIdentifier("xodus.gamePass.showLog")
                }
            }
        }
    }
}

struct AccountTierView: View {
    let entitlements: AccountEntitlements

    var body: some View {
        GroupBox("Account tier") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(entitlements.summary).font(.headline)
                        .accessibilityIdentifier("xodus.account.tier")
                    Spacer()
                }
                if entitlements.signedIn {
                    HStack(spacing: 8) {
                        ForEach(entitlements.tiers, id: \.label) { tier in
                            Label(tier.label, systemImage: tier.symbol)
                                .font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                                .accessibilityIdentifier("xodus.account.tier.badge")
                        }
                    }
                }
                if entitlements.gamePassPlanUndetermined {
                    Text("Your PC library contains a current subscription grant. Its provider and plan aren't identified by the collection.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !entitlements.accessIsCurrent, entitlements.signedIn {
                    Text("Load or refresh your PC library to verify account access. Saved sign-in and stale library data don't establish a tier.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if entitlements.signedIn, entitlements.gamePass == .unknown {
                    Text("The PC-library account's subscription status isn't verified. The separate game-service probe doesn't identify the same account.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Owned games stay in your library. Game Pass access requires an active subscription and is checked separately.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GameOperationProgressView: View {
    @ObservedObject var operations: GameOperationsController
    var privacyRestricted = false
    var productID: String?

    private func includes(_ owner: String?) -> Bool {
        productID == nil || owner == nil || owner == productID
    }
    var showsPreparation: Bool {
        operations.installingDirectly && includes(operations.directInstallProductID)
    }
    var presentedOperation: GameOperationRecord? {
        operations.operation.flatMap { includes($0.productID) ? $0 : nil }
    }
    private var includesFeedback: Bool { includes(operations.feedbackProductID) }

    var preparationTitle: String {
        operations.directInstallCancelled ? "Stopping preparation" : "Preparing installation…"
    }
    var operationTitle: String? {
        presentedOperation.map { privacyRestricted ? "Game operation in progress" : $0.title }
    }
    var operationError: String? {
        (includesFeedback ? operations.error : nil).map {
            privacyRestricted ? "The game operation needs attention. Sign in to review its details." : $0
        }
    }
    var operationNotice: String? { privacyRestricted || !includesFeedback ? nil : operations.notice }
    var preparationCancelTitle: String? { showsPreparation ? "Cancel" : nil }
    var installCancelTitle: String? { presentedOperation != nil && operations.canCancel ? "Cancel installation" : nil }
    var showsGameSignIn: Bool { includesFeedback && !privacyRestricted && operations.failureCode == 11 }
    var showsLog: Bool { includesFeedback && !privacyRestricted && operations.log != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsPreparation {
                ProgressView(preparationTitle)
                    .accessibilityIdentifier("xodus.install.preparing")
                if let title = preparationCancelTitle {
                    Button(title) { Task { await operations.cancelInstallConsent() } }
                        .disabled(operations.directInstallCancelled)
                        .accessibilityIdentifier("xodus.install.cancelPreparation")
                }
            }
            if let operation = presentedOperation, let title = operationTitle {
                Text(title).font(.headline)
                if operations.recoveryRequired {
                    Button("Check last operation") { Task { await operations.reconcile() } }
                        .disabled(operations.checkingRecovery)
                        .accessibilityIdentifier("xodus.install.checkRecovery")
                } else {
                    Text(operations.cancelling ? "Stopping installation"
                         : operation.kind == .uninstall ? "Uninstalling"
                         : operations.progress?.phase.title ?? "Preparing download")
                        .foregroundStyle(.secondary)
                    if let value = operations.progress, let total = value.bytesTotal, total > 0 {
                        ProgressView(value: Double(value.bytesDone), total: Double(total))
                            .accessibilityLabel("Download progress")
                            .accessibilityIdentifier("xodus.install.progress")
                        Text("\(Self.bytes(value.bytesDone)) of \(Self.bytes(total)) (\(Int(Double(value.bytesDone) / Double(total) * 100))%)")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel("Download progress")
                        if let value = operations.progress {
                            Text("\(Self.bytes(value.bytesDone)) downloaded").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let title = installCancelTitle {
                        Button(title) { Task { await operations.cancelInstall() } }
                            .accessibilityIdentifier("xodus.install.cancel")
                    }
                }
            }
            if let error = operationError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("xodus.install.error")
                if showsGameSignIn {
                    Button("Sign in for games") { operations.signInForGames() }
                        .disabled(!operations.canSignIn)
                        .accessibilityIdentifier("xodus.install.signIn")
                }
                if showsLog {
                    Button("Show log") { operations.showLog() }
                        .accessibilityIdentifier("xodus.install.showLog")
                }
            }
            if let notice = operationNotice {
                Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    .accessibilityIdentifier("xodus.install.result")
            }
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

struct GameInstallConsentView: View {
    @ObservedObject var operations: GameOperationsController
    let consent: GameInstallConsent
    @ObservedObject private var catalog = LibraryCatalogArtwork.shared

    var body: some View {
        let consent = operations.installConsent ?? self.consent
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(consent.installedID == nil ? consent.game.title : "Check for update or repair")
                        .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    if consent.installedID != nil { Text(consent.game.title).font(.headline) }
                }
                Section("Storage") {
                    LabeledContent("Destination") {
                        Text(consent.destination.path).textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Free space now",
                                   value: GameOperationProgressView.bytes(consent.freeBytes))
                    if operations.checkingCompatibility,
                       let estimate = catalog.images[consent.game.id]?.facts.downloadBytes {
                        LabeledContent("Estimated download",
                                       value: "About \(GameOperationProgressView.bytes(estimate))")
                    }
                    if let bytes = consent.compatibility?.packageBytes {
                        LabeledContent("Verified package size",
                                       value: GameOperationProgressView.bytes(bytes))
                    }
                    LabeledContent("Staging and expansion", value: "Calculated during setup")
                }
                Section {
                    if operations.checkingCompatibility {
                        ProgressView("Preparing installation…").controlSize(.small)
                            .accessibilityIdentifier("xodus.install.checking")
                    } else if let result = consent.compatibility, !result.supported {
                        Label(result.explanation, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("xodus.install.compatibility")
                    } else if let error = consent.checkError {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if operations.failureCode == 11 {
                            Button("Sign in for games") {
                                operations.installConsent = nil
                                operations.signInForGames()
                            }.disabled(!operations.canSignIn)
                        }
                        if operations.log != nil { Button("Show log") { operations.showLog() } }
                    }
                }
                if consent.compatibility?.supported == true {
                    Section {
                        Text(consent.installedID == nil
                             ? "Xodus verifies free space again before download. Additional working space can be required while package files are staged and expanded."
                             : "Xodus checks changed or missing files in this folder. Your saves and installed entry are kept.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { Task { await operations.cancelInstallConsent() } }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("xodus.install.cancelConsent")
                Button(consent.installedID == nil ? "Install" : "Check and repair") { operations.confirmInstall(consent) }
                    .disabled(!operations.canConfirmInstall).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("xodus.install.confirm")
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640,
               minHeight: 440, idealHeight: 560, maxHeight: 680)
        .modifier(InstallFormPresentation())
    }
}

private struct InstallFormPresentation: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.presentationSizing(.form)
        } else {
            content
        }
    }
}

struct GameOperationPresentation: View {
    @ObservedObject var operations: GameOperationsController

    var body: some View {
        Color.clear
            .sheet(item: Binding(get: { operations.presentedInstallConsent },
                                set: { operations.installConsent = $0 })) { consent in
                GameInstallConsentView(operations: operations, consent: consent)
                    .interactiveDismissDisabled(operations.checkingCompatibility)
            }
            .sheet(item: $operations.uninstallConsent) { game in
                VStack(alignment: .leading, spacing: 18) {
                    Text("Uninstall \(game.title)?").font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Deletes the game files. Your saves are kept.").foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { operations.uninstallConsent = nil }.keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("xodus.installed.cancelUninstall")
                        Button("Uninstall", role: .destructive) { operations.confirmUninstall(game) }
                            .disabled(!operations.canStartMutation)
                            .accessibilityIdentifier("xodus.installed.confirmUninstall")
                    }
                }.padding(28).frame(width: 480)
            }
    }
}

struct InstalledGameActions: View {
    @ObservedObject var library: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    let game: InstalledGame
    var usesGlass = false
    var heroStyle = false

    var body: some View {
        Menu {
            InstalledGameManagement(library: library, operations: operations, game: game)
        } label: {
            if heroStyle {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold))
                    .frame(width: 28, height: 28).accessibilityHidden(true)
            } else { Image(systemName: "ellipsis").accessibilityHidden(true) }
        }
        .menuIndicator(usesGlass ? .hidden : .automatic)
        .modifier(LibraryActionStyle(primary: false, usesGlass: usesGlass))
        .modifier(LibraryHeroControlSize(enabled: heroStyle))
        .buttonBorderShape(heroStyle ? .circle : .automatic)
        .fixedSize()
        .accessibilityLabel("Actions for \(game.title)")
    }
}

struct InstalledGameManagement: View {
    @ObservedObject var library: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    let game: InstalledGame

    var body: some View {
        Group {
            Button("Check for update / Repair") {
                Task { await operations.prepareInstall(PCGame(id: game.storeId, title: game.title, artwork: nil),
                                                        repairing: game) }
            }
            .disabled(!operations.canStartMutation || library.runningGameID == game.id)
            .accessibilityIdentifier("xodus.installed.repair")
            Button("Remove from list") { Task { await library.remove(game) } }
                .disabled(library.editing || library.choosing || library.mutationActive || library.runningGameID == game.id)
                .accessibilityIdentifier("xodus.installed.remove")
            Divider()
            Button("Uninstall…", role: .destructive) { operations.prepareUninstall(game) }
                .disabled(!operations.canStartMutation || library.runningGameID == game.id)
                .accessibilityIdentifier("xodus.installed.uninstall")
        }
    }
}
