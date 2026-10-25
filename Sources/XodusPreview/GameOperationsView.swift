// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

struct GameServiceAccountView: View {
    @ObservedObject var operations: GameOperationsController
    @ObservedObject var library: PCGamesController

    var accountStatusText: String {
        if operations.serviceSignOutConfirmed, operations.serviceStatus?.signedIn == false {
            return "Signed out of Xbox in Ode to X"
        }
        if operations.serviceAccountNeedsVerification { return "Xbox account hasn't been confirmed" }
        if operations.serviceStatus?.signedIn == true { return "Xbox sign-in confirmed" }
        return operations.serviceStatus == nil ? "Xbox sign-in hasn't been checked" : "Xbox sign-in couldn't be confirmed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Your game library") {
                VStack(alignment: .leading, spacing: 10) {
                    if library.hasSavedSignIn {
                        HStack {
                            Label("Microsoft sign-in saved for your library", systemImage: "checkmark.circle")
                            Spacer()
                        }
                    } else {
                        Text("Open Library to check your games and saved sign-in.")
                            .foregroundStyle(.secondary)
                    }
                    Text("A game in your library may still need a download access check.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            GroupBox("Xbox access") {
                GameServiceSignInActions(operations: operations, statusText: accountStatusText,
                    statusIdentifier: "xodus.games.accountStatus",
                    checkIdentifier: "xodus.games.checkSignIn",
                    signInIdentifier: "xodus.games.signIn",
                    errorIdentifier: "xodus.games.signInError",
                    logIdentifier: "xodus.games.signInLog",
                    verifyIdentifier: "xodus.games.verifyExplanation",
                    setupRepairing: operations.setupRepairing)
            }
            GroupBox("PC Game Pass") {
                GamePassAccountView(operations: operations, library: library)
                    .padding(.top, 2)
            }
            DisclosureGroup("Library and subscription details") {
                AccountTierView(entitlements: operations.accountEntitlements(library: library))
            }
            DisclosureGroup("Troubleshoot game setup") {
                GameSetupView(operations: operations, showsTitle: false)
                    .padding(.top, 2)
            }
        }
    }
}

struct GameServiceSignInActions: View {
    @ObservedObject var operations: GameOperationsController
    var statusText: String
    var statusIdentifier: String
    var checkIdentifier: String
    var signInIdentifier: String
    var errorIdentifier: String
    var logIdentifier: String
    var verifyIdentifier: String
    var setupRepairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if operations.usesUnifiedAccount {
                Label(operations.serviceLabel, systemImage: "exclamationmark.circle")
                    .accessibilityIdentifier(statusIdentifier)
                Text(operations.serviceError ?? "This runtime isn't connected to your Xbox Live account.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            Label(statusText, systemImage: operations.serviceAccountSymbol)
                .accessibilityIdentifier(statusIdentifier)
            Text("Ode to X sign-in and Xbox game-service sign-in are separate. Continue with Microsoft here only when a game download or Xbox feature needs it; Ode to X won't open this second sign-in automatically.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if operations.serviceAccountNeedsVerification {
                Text("Confirm your Xbox account to load your profile, achievements and consoles.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(verifyIdentifier)
            }
            HStack {
                Button("Check status") { operations.refreshService() }
                    .disabled(operations.serviceBusy || setupRepairing)
                    .accessibilityIdentifier(checkIdentifier)
                if operations.serviceSignInActionTitle != nil {
                    Button(operations.serviceAccountNeedsVerification ? "Verify Xbox account" : "Continue with Microsoft") {
                        operations.signInForGames()
                    }
                    .disabled(!operations.canSignIn)
                    .accessibilityIdentifier(signInIdentifier)
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
                Label("Xbox access couldn't be confirmed. Check status to try again, or open Technical details.", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(errorIdentifier)
                DisclosureGroup("Technical details") {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    if operations.serviceLog != nil {
                        Button("Show log") { operations.showServiceLog() }
                            .accessibilityIdentifier(logIdentifier)
                    }
                }
                }
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
                    Button("Check game access status") { operations.refreshService() }
                        .disabled(operations.serviceBusy || operations.setupRepairing)
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
        GroupBox("Library access") {
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
                    Text("Your library includes subscription games, but the subscription plan hasn't been confirmed.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !entitlements.accessIsCurrent, entitlements.signedIn {
                    Text("Refresh Library to check your current game access.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if entitlements.signedIn, entitlements.gamePass == .unknown {
                    Text("Your library's subscription status hasn't been confirmed. The Xbox access check may use a different account.")
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
    var showsGameSignIn: Bool {
        includesFeedback && !privacyRestricted && operations.failureCode == 11 && operations.downloadNeedsSignIn
    }
    var showsDownloadRecovery: Bool {
        includesFeedback && !privacyRestricted && operations.hasDownloadRecovery
    }
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
                if showsDownloadRecovery {
                    Button(showsGameSignIn ? "Continue with Microsoft" : "Check download access") {
                        operations.recoverDownload(productID: productID)
                    }
                    .disabled(!operations.canRecoverDownload)
                    .accessibilityIdentifier("xodus.install.checkAccess")
                    if operations.serviceBusy {
                        ProgressView(operations.serviceSigningIn ? "Waiting for Microsoft authorization" : "Checking download access")
                            .controlSize(.small)
                    }
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

struct InstallUnavailableNotice: View {
    let message: String
    var recoveryTitle: String? = nil
    var recover: (() -> Void)? = nil
    @Environment(\.libraryOnHeroMedia) private var onHero

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("xodus.pcGames.installUnavailableReason")
            if let recoveryTitle, let recover {
                Button(recoveryTitle, action: recover).buttonStyle(.bordered)
                    .accessibilityIdentifier("xodus.pcGames.installRecovery")
            }
        }
        .font(.callout)
        .foregroundStyle(onHero ? Color.white : Color.primary)
        .padding(onHero ? 12 : 0)
        .background(onHero ? Color.black.opacity(0.8) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 380, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct GameInstallAction: View {
    let game: PCGame
    @ObservedObject var operations: GameOperationsController
    var enabled = true
    var primary = true
    var disabledReason: String? = nil
    var recoveryTitle: String? = nil
    var recover: (() -> Void)? = nil
    var reviewInstall: ((PCGame) -> Void)? = nil
    var preparing: Bool {
        (operations.preparingConsent && operations.preparingInstallProductID == game.id)
            || (operations.installingDirectly && operations.directInstallProductID == game.id)
    }
    var active: Bool { operations.operation?.productID == game.id }
    var failed: Bool {
        operations.feedbackProductID == game.id && operations.error != nil
    }
    var statusTitle: String {
        operations.cancelling || operations.directInstallCancelled ? "Stopping"
            : preparing ? "Preparing installation"
            : operations.operation?.kind == .uninstall ? "Uninstalling"
            : operations.operation?.kind == .repair ? "Repairing" : "Installing"
    }
    var actionTitle: String { failed ? "Retry installation" : "Install" }
    var canInstall: Bool { enabled && operations.canStartMutation }
    var unavailableReason: String? {
        guard !canInstall else { return nil }
        return !enabled ? (disabledReason ?? "Installation is not available yet.")
            : (operations.installUnavailableReason ?? "Installation is not available yet.")
    }
    var showsCancel: Bool { preparing || (active && operations.canCancel) }

    func requestInstall() async {
        guard canInstall else { return }
        if let reviewInstall { reviewInstall(game) }
        else { await operations.prepareInstall(game) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if active, operations.recoveryRequired {
                Label("Installation needs attention", systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.semibold))
                Button("Check last operation") { Task { await operations.reconcile() } }
                    .disabled(operations.checkingRecovery)
            } else if preparing || active {
                Text(statusTitle)
                    .font(.callout.weight(.semibold))
                if active, let progress = operations.progress, let total = progress.bytesTotal, total > 0 {
                    ProgressView(value: Double(progress.bytesDone), total: Double(total))
                        .accessibilityLabel("Installation progress for \(game.title)")
                    Text("\(GameOperationProgressView.bytes(progress.bytesDone)) of \(GameOperationProgressView.bytes(total))")
                        .font(.caption)
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Preparing \(game.title)")
                }
                if showsCancel {
                    Button("Cancel") {
                        Task {
                            if preparing { await operations.cancelInstallConsent() }
                            else { await operations.cancelInstall() }
                        }
                    }
                    .disabled(operations.cancelling || operations.directInstallCancelled)
                    .accessibilityLabel("Cancel installation of \(game.title)")
                }
            } else {
                Button {
                    Task { await requestInstall() }
                } label: {
                    Label(actionTitle, systemImage: "icloud.and.arrow.down")
                }
                .modifier(LibraryActionStyle(primary: primary))
                .disabled(!canInstall)
                .help("Install \(game.title)")
                .accessibilityLabel("\(failed ? "Retry installation of" : "Install") \(game.title)")
                .accessibilityIdentifier("xodus.pcGames.download")
                if let unavailableReason {
                    InstallUnavailableNotice(message: unavailableReason,
                        recoveryTitle: recoveryTitle, recover: recover)
                }
                if failed {
                    Label("Installation needs attention", systemImage: "exclamationmark.circle")
                        .font(.caption)
                }
            }
        }
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
                    Text(consent.resuming ? "Resume installation"
                         : consent.installedID == nil ? consent.game.title : "Check for update or repair")
                        .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    if consent.installedID != nil { Text(consent.game.title).font(.headline) }
                }
                Section("Storage") {
                    LabeledContent("Destination") {
                        Text(consent.destination.path).textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    if consent.installedID == nil, !consent.resuming {
                        Button("Choose another folder…") {
                            Task { await operations.chooseInstallLocation(consent) }
                        }
                        .disabled(operations.checkingCompatibility || operations.choosingInstallLocation)
                        .accessibilityIdentifier("xodus.install.chooseLocation")
                        Text("Only this installation changes. Your default folder and existing games stay where they are.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = operations.installLocationError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .fixedSize(horizontal: false, vertical: true)
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
                        if operations.hasDownloadRecovery {
                            Button(operations.downloadNeedsSignIn ? "Continue with Microsoft" : "Check download access") {
                                operations.recoverDownload(productID: consent.game.id)
                            }.disabled(!operations.canRecoverDownload)
                        }
                        if operations.log != nil { Button("Show log") { operations.showLog() } }
                    }
                }
                if consent.compatibility?.supported == true || consent.nativeAccountHash != nil {
                    Section {
                        Text(consent.nativeAccountHash != nil
                             ? consent.resuming
                                ? "The account-bound service verifies package access and continues the interrupted download. Existing verified package data is reused."
                                : "The account-bound service verifies package access before downloading. Repair downloads all package files again. Keep a separate backup of saves stored inside the game folder."
                             : consent.installedID == nil
                             ? "Ode to X verifies free space again before download. Additional working space can be required while package files are staged and expanded."
                             : "Ode to X checks changed or missing files in this folder. Your saves and installed entry are kept.")
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
                Button(consent.resuming ? "Resume" : consent.installedID == nil ? "Install" : "Check and repair") {
                    operations.confirmInstall(consent)
                }
                    .disabled(!operations.canConfirmInstall || operations.choosingInstallLocation).keyboardShortcut(.defaultAction)
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

struct GameDetailInstallRequest: Sendable {
    let game: PCGame
    let accountHash: String?

    func resolve(accountHash: String?) -> PCGame? {
        self.accountHash == accountHash ? game : nil
    }
}

private struct GameDetailSheet<Item: Identifiable, Detail: View>: ViewModifier {
    @Binding var item: Item?
    @ObservedObject var operations: GameOperationsController
    let allowed: Bool
    let accountHash: String?
    let onDismiss: () -> Void
    let detail: (Item, @escaping (PCGame) -> Void) -> Detail
    @State private var pendingInstall: GameDetailInstallRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $item, onDismiss: {
            let request = pendingInstall
            pendingInstall = nil
            onDismiss()
            guard allowed, let request, let game = request.resolve(accountHash: accountHash) else { return }
            Task { await operations.prepareInstall(game, expectedAccountHash: request.accountHash) }
        }) { item in
            detail(item) { game in
                guard self.item?.id == item.id, allowed, pendingInstall == nil, operations.canStartMutation,
                      operations.installConsent == nil else { return }
                pendingInstall = GameDetailInstallRequest(game: game, accountHash: accountHash)
                self.item = nil
            }
        }
    }
}

extension View {
    func gameDetailSheet<Item: Identifiable, Detail: View>(
        item: Binding<Item?>, operations: GameOperationsController, allowed: Bool, accountHash: String? = nil,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder detail: @escaping (Item, @escaping (PCGame) -> Void) -> Detail
    ) -> some View {
        modifier(GameDetailSheet(item: item, operations: operations, allowed: allowed, accountHash: accountHash,
                                 onDismiss: onDismiss, detail: detail))
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
                    Text(operations.usesUnifiedAccount
                         ? "Deletes this game's installation folder. Back up any saves stored inside that folder first. Saves in separate bottles are not removed."
                         : "Deletes the game files. Your saves are kept.").foregroundStyle(.secondary)
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
    var details: (() -> Void)?

    var body: some View {
        Menu {
            if let details { Button("Details", action: details) }
            if library.playLogs[game.id] != nil {
                Button("Show launch log") { library.showLog(for: game) }
                    .accessibilityLabel("Show \(game.title) launch log in Finder")
                    .accessibilityIdentifier("xodus.installed.showLog")
            }
            Menu("Engine") {
                Button("Use default", systemImage: game.engineOverrideV2 == nil ? "checkmark" : "circle") {
                    Task { await library.setEngineOverrideV2(nil, for: game) }
                }
                ForEach(library.engineOverrides(for: game), id: \.inspection.engineName) { selection in
                    if let name = selection.inspection.engineName {
                        Button(name, systemImage: game.engineOverrideV2?.selection == selection ? "checkmark" : "circle") {
                            Task { await library.setEngineOverrideV2(selection, for: game) }
                        }
                    }
                }
                Divider()
                Button("Refresh engines") { Task { await library.refreshEngineOverrides() } }
                    .disabled(library.checkingEngineOverrides)
            }
            .disabled(library.editing || library.choosing || library.mutationActive
                      || library.accountDisconnecting || library.applicationTerminating || library.runningGameID == game.id)
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
        .task {
            await library.refreshEngineOverrides(force: false)
        }
    }
}

struct InstalledGameManagement: View {
    @ObservedObject var library: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    let game: InstalledGame

    var body: some View {
        Group {
            if library.updateStatus(for: game).hasUpdate {
                Button("Update") {
                    Task { await operations.repair(PCGame(id: game.storeId, title: game.title, artwork: nil),
                                                  installed: game) }
                }
                .disabled(!canRepair)
                .accessibilityIdentifier("xodus.installed.update")
            }
            Button("Repair") {
                Task { await operations.repair(PCGame(id: game.storeId, title: game.title, artwork: nil),
                                              installed: game) }
            }
            .disabled(!canRepair)
            .accessibilityIdentifier("xodus.installed.repair")
            Button("Remove from list") { Task { await library.remove(game) } }
                .disabled(library.editing || library.choosing || library.mutationActive
                          || library.accountDisconnecting || library.applicationTerminating
                          || library.runningGameID == game.id)
                .accessibilityIdentifier("xodus.installed.remove")
            Divider()
            Button("Uninstall…", role: .destructive) { operations.prepareUninstall(game) }
                .disabled(!operations.canStartMutation || library.runningGameID == game.id)
                .accessibilityIdentifier("xodus.installed.uninstall")
        }
    }

    private var canRepair: Bool {
        operations.canRepair(game)
    }
}
