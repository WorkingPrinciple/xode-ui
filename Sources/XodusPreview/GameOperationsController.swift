// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation
import XodusManagement

struct GameInstallConsent: Identifiable, Sendable {
    let id = UUID()
    let game: PCGame
    var destination: URL
    var freeBytes: Int64
    let installedID: UUID?
    var compatibility: GameCompatibilityResult?
    var checkError: String?
    var nativeAccountHash: String?
    var resuming = false
    var storageVolume: GameStorageVolume?
}

@MainActor
final class GameOperationsController: ObservableObject {
    @Published private(set) var serviceStatus: GameServiceStatus?
    @Published private(set) var serviceBusy = false
    @Published private(set) var serviceSigningIn = false
    @Published private(set) var serviceSignOutConfirmed = false
    @Published private(set) var serviceError: String?
    @Published private(set) var serviceLog: URL?
    @Published private(set) var gamePassStatus: GamePassStatusResult?
    @Published private(set) var gamePassBusy = false
    @Published private(set) var gamePassError: String?
    @Published private(set) var gamePassFailureCode: Int?
    @Published private(set) var gamePassLog: URL?
    @Published private(set) var gamePassFromCache = false
    @Published private(set) var setupResult: GameSetupResult?
    @Published private(set) var setupBusy = false
    @Published private(set) var setupRepairing = false
    @Published private(set) var setupError: String?
    @Published private(set) var setupLog: URL?
    @Published var installConsent: GameInstallConsent?
    @Published var uninstallConsent: InstalledGame?
    @Published private(set) var preparingConsent = false
    @Published private(set) var preparingInstallProductID: String?
    @Published private(set) var choosingInstallLocation = false
    @Published private(set) var installLocationError: String?
    @Published private(set) var checkingCompatibility = false
    @Published private(set) var installingDirectly = false
    @Published private(set) var compatibility: [String: GameCompatibilityResult] = [:]
    @Published private(set) var compatibilityErrors: [String: String] = [:]
    @Published private(set) var operation: GameOperationRecord?
    @Published private(set) var queuedInstalls: [QueuedGameInstall] = []
    @Published private(set) var installQueuePaused = false
    @Published private(set) var installQueueError: String?
    @Published private(set) var progress: GameScriptProgress?
    @Published private(set) var cancelling = false
    @Published private(set) var checkingRecovery = false
    @Published private(set) var recoveryRequired = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var log: URL?
    @Published private(set) var failureCode: Int?
    @Published private(set) var feedbackProductID: String?
    @Published private(set) var directInstallProductID: String?
    @Published private(set) var downloadNeedsSignIn = false
    private var downloadRetry: PCGame?
    private let signInOwner = UUID()
    private let installed: InstalledGamesController
    private let paths: GameScriptPaths
    private let installLocationDefaults: UserDefaults?
    private let storageProbe = GameStorageProbe()
    private var preparationGeneration = UUID()
    private let mutationRunner: GameScriptRunner
    private let serviceRunner: GameScriptRunner
    private let setupRunner: GameScriptRunner
    private let journal: GameOperationJournal
    private let installQueueJournal: GameInstallQueueJournal
    private var installQueueTask: Task<Void, Never>?
    private var startingQueuedInstall: QueuedGameInstall?
    private let compatibilityCatalogue: OfflineGameCompatibility?
    private var mutationTask: Task<Void, Never>?
    private var serviceTask: Task<Void, Never>?
    private var compatibilityTask: Task<Void, Never>?
    private var compatibilityRunID: String?
    @Published private(set) var precheckingProductID: String?
    private let precheckRunner: GameScriptRunner
    private var precheckTask: Task<Void, Never>?
    private var precheckRunID: String?
    private var precheckAttempted = Set<String>()
    private var gamePassTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var gamePassGeneration = 0
    private var setupTask: Task<Void, Never>?
    private var setupCheckedOnce = false
    private var setupRefreshPending = false
    private var restored = false
    private var terminating = false
    @Published private(set) var directInstallCancelled = false
    private var queueProgressObserver: ((GameScriptProgress) -> Void)?
    // Queued runs whose stop/cancel arrived while they were still waiting for the
    // mutation slot (so `operation?.id` did not yet match the run). Recorded here
    // and honored by `runQueuedOperation` so a paused/cancelled job never installs.
    private var abandonedQueuedRuns: Set<String> = []
    private var installedObservation: AnyCancellable?
    private(set) var usesUnifiedAccount = false
    private weak var unifiedSession: LiveSession?
    private let nativeRunner = NativeGameLifecycle()

    func useUnifiedAccount(_ session: LiveSession? = nil) {
        usesUnifiedAccount = true
        unifiedSession = session
        serviceStatus = nil
        gamePassGeneration += 1
        gamePassStatus = nil
        gamePassFromCache = false
        serviceError = nil
    }

    private var nativeAccount: String? {
        guard installed.accountAccessAllowed, unifiedSession?.nativeLifecycleConfiguration != nil else { return nil }
        return unifiedSession?.accountHash
    }
    var isBusy: Bool {
        operation != nil || checkingCompatibility || gamePassBusy || setupBusy || installed.stoppingGameID != nil
    }
    var hasDownloadStatus: Bool {
        operation != nil || error != nil || notice != nil || installingDirectly
            || !queuedInstalls.isEmpty || installQueueError != nil
    }
    var presentedInstallConsent: GameInstallConsent? {
        installingDirectly || startingQueuedInstall != nil ? nil : installConsent
    }
    var canSignIn: Bool {
        !usesUnifiedAccount && !serviceBusy && !isBusy && !recoveryRequired && !installed.mutationActive
            && !preparingConsent && !installingDirectly && !installed.accountDisconnecting
            && installed.runningGameID == nil && queuedInstalls.isEmpty && !terminating
    }
    var canStartMutation: Bool {
        mutationSlotAvailable && (queuedInstalls.isEmpty || startingQueuedInstall != nil)
    }
    private var mutationSlotAvailable: Bool {
        (!usesUnifiedAccount || nativeAccount != nil) && !isBusy && !recoveryRequired && !installed.mutationActive && !serviceBusy && !preparingConsent && installed.loaded
            && !installed.editing && !installed.choosing && !installed.accountDisconnecting && !terminating
    }
    private var downloadOperationActive: Bool {
        operation != nil && operation?.kind != .uninstall && !recoveryRequired
    }
    var canPrepareInstall: Bool {
        installationAdmissionAvailable && !preparingConsent
    }
    private var installationAdmissionAvailable: Bool {
        (!usesUnifiedAccount || nativeAccount != nil) && !recoveryRequired
            && (!installed.mutationActive || downloadOperationActive)
            && (operation == nil || downloadOperationActive)
            && !checkingCompatibility && !gamePassBusy && !setupBusy && !serviceBusy
            && installed.loaded && !installed.editing && !installed.choosing
            && installed.stoppingGameID == nil && !installed.accountDisconnecting && !terminating
    }
    func canInstall(productID: String) -> Bool {
        !preparingConsent && canContinueInstall(productID: productID)
    }
    private func canContinueInstall(productID: String) -> Bool {
        installationAdmissionAvailable && operation?.productID != productID
            && !queuedInstalls.contains { $0.record.productID == productID && $0.id != startingQueuedInstall?.id }
    }
    var installUnavailableReason: String? {
        guard !canPrepareInstall else { return nil }
        if installed.accountDisconnecting || terminating { return "Account access is closing. Installation is unavailable." }
        if installAccountUnavailable {
            return "Installation access for this account hasn't been confirmed. Review Account settings."
        }
        if recoveryRequired { return "Check the last operation in Downloads before starting another installation." }
        if !installed.loaded { return "Wait for installed games to finish loading." }
        if installed.editing || installed.choosing { return "Finish choosing or editing the game location before installing." }
        if gamePassBusy { return "Wait for the Game Pass access check to finish." }
        if checkingCompatibility { return "Wait for the compatibility check to finish." }
        return "Wait for the current game operation to finish before installing."
    }
    var installAccountUnavailable: Bool { usesUnifiedAccount && nativeAccount == nil }
    var canQuit: Bool {
        !installingDirectly && !preparingConsent && !choosingInstallLocation
            && mutationTask == nil && compatibilityTask == nil && gamePassTask == nil && stopTask == nil
            && setupTask == nil && !serviceBusy
            && !installed.accountDisconnecting && installQueueTask == nil
    }
    var canDisconnectAccount: Bool {
        canQuit && !recoveryRequired && !installed.mutationActive && !installed.editing
            && !installed.choosing && installed.runningGameID == nil && installed.stoppingGameID == nil
            && installConsent == nil && uninstallConsent == nil && queuedInstalls.isEmpty && !terminating
    }

    func beginAccountDisconnect() -> Bool {
        guard canDisconnectAccount else { return false }
        installed.accountDisconnecting = true
        resetFeedback(productID: nil)
        return true
    }

    func finishAccountDisconnect() { installed.accountDisconnecting = false }

    func signOutForApp() async -> Bool {
        guard installed.accountDisconnecting, !serviceBusy, !terminating else { return false }
        serviceBusy = true
        serviceSignOutConfirmed = false
        serviceError = nil
        serviceLog = nil
        serviceStatus = nil
        gamePassGeneration += 1
        gamePassStatus = nil
        gamePassError = nil
        gamePassFailureCode = nil
        gamePassFromCache = false
        LibraryXboxStats.shared.invalidateBinding()
        XboxCompanionController.shared.invalidateBinding()
        defer { serviceBusy = false }
        let runID = InstalledGamesController.runID()
        do {
            let outcome = try await serviceRunner.run(command: .serviceSignOut, runID: runID)
            guard outcome.code == 0, let data = outcome.result else { throw GameScriptError.failed(outcome.code) }
            _ = try GameServiceSignOutResult.parse(data)
            guard !terminating else { throw CancellationError() }
            serviceStatus = GameServiceStatus(serviceRunning: false, signedIn: false, accountHash: nil)
            serviceSignOutConfirmed = true
            return true
        } catch {
            serviceLog = await scriptLog(runID)
            serviceError = error as? GameScriptError == .unavailable
                ? "Ode to X couldn't use this runtime's game-service sign-out helper. A matching runtime with sign-out support is required. No PC-library or launcher sign-in was removed."
                : "Ode to X couldn't confirm game-service sign-out. That service may have stopped, but credential removal isn't confirmed. No PC-library or launcher sign-in was removed. Check the sign-out log before retrying."
            return false
        }
    }
    var canConfirmInstall: Bool {
        guard !choosingInstallLocation, let consent = installConsent, canInstall(productID: consent.game.id),
              consentCanQueue(consent) else { return false }
        let format = consent.installedID.flatMap { id in installed.games.first { $0.id == id }?.packageType?.label }
        return supportIssues(productID: consent.game.id, packageFormat: format, includeRuntime: false).isEmpty
    }
    var canCancel: Bool {
        operation != nil && operation?.kind != .uninstall && !recoveryRequired && !cancelling
    }
    var serviceLabel: String {
        if usesUnifiedAccount { return nativeAccount == nil ? "Check Xbox account connection" : "Using your Xbox account" }
        if serviceAccountNeedsVerification { return "Game sign-in saved; account not verified" }
        return serviceStatus?.signedIn == true ? "Signed in for games"
            : serviceStatus == nil ? "Game sign-in hasn't been checked" : "Sign in for games"
    }
    var serviceAccountNeedsVerification: Bool {
        serviceStatus?.signedIn == true && serviceStatus?.accountHash == nil
    }
    var serviceSignInActionTitle: String? {
        if usesUnifiedAccount { return nil }
        if serviceAccountNeedsVerification { return "Verify game account" }
        return serviceStatus?.signedIn == true ? nil : "Sign in for games"
    }
    var serviceAccountSymbol: String {
        serviceAccountNeedsVerification ? "person.crop.circle.badge.questionmark"
            : serviceStatus?.signedIn == true ? "checkmark.circle" : "person.crop.circle"
    }
    var gamePassActive: Bool {
        gamePassStatus?.active == true && !gamePassFromCache && !gamePassBusy && gamePassError == nil
    }

    // Only current PC-library evidence belongs to this account's tier.
    func accountEntitlements(library: PCGamesController) -> AccountEntitlements {
        AccountEntitlements.derive(
            signedIn: library.hasSavedSignIn,
            held: library.representedGames.map(\.acquisitionKind),
            // The service receipt has no identity to bind it to the PC-library account.
            gamePassActive: nil, accessIsCurrent: library.accessIsCurrent)
    }
    var setupNeedsAttention: Bool { setupResult?.ready == false || setupError != nil }
    var canRepairSetup: Bool {
        !usesUnifiedAccount && canStartMutation && !serviceBusy && installed.runningGameID == nil
            && installConsent == nil && uninstallConsent == nil
    }
    var gamePassLabel: String {
        if gamePassFromCache { return "PC Game Pass: Saved status - check required" }
        if gamePassBusy || gamePassError != nil { return "PC Game Pass: Unknown" }
        return gamePassStatus?.active == true ? "PC Game Pass: Active"
            : gamePassStatus?.active == false ? "PC Game Pass: Not active" : "PC Game Pass: Unknown"
    }

    init(installed: InstalledGamesController, paths: GameScriptPaths = .production,
         compatibilityCatalogue: OfflineGameCompatibility? = OfflineGameCompatibility.snapshot,
         installLocationDefaults: UserDefaults? = nil) {
        self.installed = installed
        self.paths = paths
        self.installLocationDefaults = installLocationDefaults
        self.compatibilityCatalogue = compatibilityCatalogue
        mutationRunner = GameScriptRunner(paths: paths)
        serviceRunner = GameScriptRunner(paths: paths)
        setupRunner = GameScriptRunner(paths: paths)
        precheckRunner = GameScriptRunner(paths: paths)
        journal = GameOperationJournal(file: paths.journal)
        installQueueJournal = GameInstallQueueJournal(file: paths.journal.appendingPathExtension("queue.json"))
        installedObservation = installed.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func supportIssues(productID: String, packageFormat: String? = nil,
                       includeRuntime: Bool = true) -> [LibraryCompatibilityIssue] {
        LibrarySupportVisibility.issues(productID: productID, installed: false,
            packageFormat: packageFormat, compatibility: includeRuntime ? compatibility[productID] : nil,
            catalogue: compatibilityCatalogue)
    }

    func canRepair(_ game: InstalledGame) -> Bool {
        canInstall(productID: game.storeId) && !installed.unavailableDriveIDs.contains(game.id) && installed.runningGameID != game.id
            && supportIssues(productID: game.storeId, packageFormat: game.packageType?.label,
                             includeRuntime: false).isEmpty
    }

    private func installPreparationFailed(_ message: String, productID: String) {
        if operation != nil { installQueueError = message }
        else {
            resetFeedback(productID: productID)
            error = message
        }
    }

    private func admitInstall(productID: String, installedID: UUID? = nil, destination: String? = nil) -> Bool {
        // The executing request is already in the durable queue until its operation journal
        // has been saved. Exclude only that request, never another title or path reservation.
        if (operation?.productID != productID && operation?.conflicts(productID: productID, destination: destination) == true)
            || queuedInstalls.contains(where: {
                $0.id != startingQueuedInstall?.id
                    && $0.record.conflicts(productID: productID, destination: destination)
            }) {
            installQueueError = "This game or installation folder is already in the download queue."
            return false
        }
        guard installedID != nil || installed.canCreateInstallation(productID: productID, destination: destination) else {
            let message = installed.hasUnverifiedInstallation(productID: productID)
                ? "The installation couldn't be checked. Try again."
                : GameScriptError.invalidDestination.localizedDescription
            installPreparationFailed(message, productID: productID)
            return false
        }
        let format = installedID.flatMap { id in installed.games.first { $0.id == id }?.packageType?.label }
        let issues = supportIssues(productID: productID, packageFormat: format, includeRuntime: false)
        guard issues.isEmpty else {
            if !checkingCompatibility {
                installPreparationFailed(issues.map(\.detail).joined(separator: " "), productID: productID)
            }
            return false
        }
        return true
    }

    private func consentAdmitted(_ consent: GameInstallConsent) -> Bool {
        if usesUnifiedAccount {
            return consent.nativeAccountHash != nil && consent.nativeAccountHash == nativeAccount
        }
        return consent.nativeAccountHash == nil && consent.compatibility?.supported == true
    }

    private func consentCanQueue(_ consent: GameInstallConsent) -> Bool {
        consentAdmitted(consent) || (!usesUnifiedAccount && consent.nativeAccountHash == nil
            && consent.compatibility == nil && consent.checkError == nil && !checkingCompatibility)
    }

    func restore() async {
        guard !restored, !isBusy, !terminating else { return }
        restored = true
        do {
            queuedInstalls = try installQueueJournal.load()
            installQueuePaused = !queuedInstalls.isEmpty
            guard let record = try await journal.load() else { return }
            queuedInstalls.removeAll { $0.id == record.id }
            try installQueueJournal.save(queuedInstalls)
            resetFeedback(productID: record.productID)
            try installed.reserveMutation(gameID: record.installedID)
            operation = record
            recoveryRequired = true
            error = "The last game operation needs checking. No operation will be repeated automatically."
            log = await Task.detached { GameScriptFiles.log(runID: record.id, paths: self.paths) }.value
        } catch {
            recoveryRequired = true
            self.error = GameScriptError.storage.localizedDescription
            // Keep mutations fenced when a saved operation cannot be understood.
            if !installed.mutationActive { try? installed.reserveMutation(gameID: nil) }
        }
    }

    func refreshService() {
        guard !usesUnifiedAccount else { return }
        guard !serviceBusy, !gamePassBusy, !setupRepairing, !installed.accountDisconnecting, !terminating else { return }
        serviceBusy = true
        gamePassStatus = nil
        gamePassFromCache = false
        gamePassGeneration += 1
        serviceError = nil
        let runID = InstalledGamesController.runID()
        serviceTask = Task {
            defer { serviceBusy = false; serviceTask = nil }
            do {
                let outcome = try await serviceRunner.run(command: .serviceStatus, runID: runID)
                guard !terminating else { return }
                guard outcome.code == 0, let data = outcome.result else { throw GameScriptError.failed(outcome.code) }
                serviceStatus = try GameServiceStatus.parse(data)
                clearRecoveredDownloadSignIn()
                serviceLog = nil
                if serviceStatus?.signedIn == true, setupCheckedOnce { refreshSetup() }
            } catch {
                guard !terminating else { return }
                serviceStatus = nil
                serviceError = Self.message(error)
                serviceLog = await scriptLog(runID)
            }
        }
    }

    func signInForGames(resuming game: PCGame? = nil) {
        guard canSignIn else { return }
        guard MicrosoftSignInGate.shared.acquire(signInOwner) else {
            serviceError = "Finish or cancel the current Microsoft sign-in before starting another."
            if game != nil { error = serviceError }
            return
        }
        LibraryXboxStats.shared.invalidateBinding()
        gamePassGeneration += 1
        gamePassStatus = nil
        gamePassFromCache = false
        serviceBusy = true
        serviceSigningIn = true
        installed.serviceSignInActive = true
        serviceError = nil
        serviceLog = nil
        let runID = InstalledGamesController.runID()
        serviceTask = Task {
            var resume = false
            var evidenceRunID = runID
            do {
                let signedIn = try await serviceRunner.run(command: .serviceSignIn, runID: runID)
                guard signedIn.code == 0 else { throw GameScriptError.failed(signedIn.code) }
                evidenceRunID = InstalledGamesController.runID()
                let status = try await serviceRunner.run(command: .serviceStatus, runID: evidenceRunID)
                guard status.code == 0, let data = status.result else { throw GameScriptError.invalidReceipt }
                let value = try GameServiceStatus.parse(data)
                guard value.signedIn, value.accountHash != nil else { throw GameScriptError.failed(11) }
                serviceStatus = value
                if game != nil {
                    resume = true
                } else { clearRecoveredDownloadSignIn() }
                if setupCheckedOnce, !resume { refreshSetup() }
            } catch {
                serviceStatus = nil
                serviceError = error as? GameScriptError == .failed(14)
                    ? "Microsoft sign-in was cancelled. No installation was resumed."
                    : "Microsoft game authorization wasn't confirmed. Check game access status before trying again."
                serviceLog = await scriptLog(evidenceRunID)
                if let game, feedbackProductID == game.id {
                    self.error = "Microsoft game authorization wasn't confirmed. The installation has not resumed. Check download access to try again."
                    log = serviceLog
                    downloadNeedsSignIn = false
                }
            }
            serviceBusy = false
            serviceSigningIn = false
            installed.serviceSignInActive = false
            serviceTask = nil
            MicrosoftSignInGate.shared.release(signInOwner)
            if resume, let game, !terminating, feedbackProductID == game.id {
                installConsent = nil
                await install(game)
            }
        }
    }

    var canRecoverDownload: Bool {
        failureCode == 11 && downloadRetry != nil && canSignIn
    }
    var hasDownloadRecovery: Bool { failureCode == 11 && downloadRetry != nil }

    private func clearRecoveredDownloadSignIn() {
        guard failureCode == 11, serviceStatus?.signedIn == true,
              serviceStatus?.accountHash != nil else { return }
        downloadNeedsSignIn = false
        error = "Saved Microsoft game access was confirmed. Check download access to retry this game's package; the earlier download did not complete."
        installConsent?.checkError = error
    }

    /// A failed acquisition is not evidence that interactive consent is required.
    func recoverDownload(productID: String?) {
        guard canRecoverDownload, let game = downloadRetry,
              productID == nil || productID == game.id, feedbackProductID == game.id else { return }
        if downloadNeedsSignIn {
            signInForGames(resuming: game)
            return
        }
        serviceBusy = true
        serviceError = nil
        serviceLog = nil
        let runID = InstalledGamesController.runID()
        serviceTask = Task {
            var resume = false
            do {
                let outcome = try await serviceRunner.run(command: .serviceStatus, runID: runID)
                guard outcome.code == 0, let data = outcome.result else { throw GameScriptError.failed(outcome.code) }
                let status = try GameServiceStatus.parse(data)
                guard !terminating, feedbackProductID == game.id else { throw CancellationError() }
                serviceStatus = status
                if status.signedIn, status.accountHash != nil {
                    resume = true
                } else {
                    downloadNeedsSignIn = true
                    error = status.signedIn
                        ? "Your saved game sign-in needs account verification before retrying this download. Continue with Microsoft; installation resumes only after confirmation."
                        : "Ode to X couldn't confirm saved game access. This can also happen when the service is unavailable. Continue with Microsoft to check authorization; installation resumes only after confirmation."
                    installConsent?.checkError = error
                }
            } catch {
                serviceStatus = nil
                serviceError = Self.message(error)
                serviceLog = await scriptLog(runID)
                if !terminating, feedbackProductID == game.id {
                    self.error = "Ode to X couldn't check download access. No new sign-in was started. Check download access to retry, or show the log."
                    installConsent?.checkError = self.error
                    log = serviceLog
                }
            }
            serviceBusy = false
            serviceTask = nil
            if resume, !terminating, feedbackProductID == game.id {
                installConsent = nil
                await install(game)
            }
        }
    }

    nonisolated static func gamePassProbes(discoveryProducts: [CatalogProduct], ownedGames: [PCGame]?,
                                           compatibility: [String: GameCompatibilityResult]) -> [String] {
        guard let ownedGames else { return [] }
        let ownedIDs = Set(ownedGames.map(\.id))
        var seen = Set<String>()
        let candidates = discoveryProducts.filter { product in
            guard PCGamesClient.validProductID(product.id), !ownedIDs.contains(product.id),
                  seen.insert(product.id).inserted else { return false }
            if let cached = compatibility[product.id], !cached.supported, let reason = cached.reason {
                let reason = reason.lowercased()
                if reason.contains("no pc game package") || reason.contains("package type") { return false }
            }
            return true
        }
        return candidates.filter(\.pcCatalogCandidate).map(\.id)
            + candidates.filter { !$0.pcCatalogCandidate }.map(\.id)
    }

    func loadGamePassCache() async {
        guard !usesUnifiedAccount else { return }
        guard !gamePassBusy, !terminating else { return }
        gamePassGeneration += 1
        let generation = gamePassGeneration
        let paths = paths
        do {
            let result = try await Task.detached {
                guard let data = try GameScriptFiles.read(paths.gamePassStatus, missingAllowed: true) else {
                    return Optional<GamePassStatusResult>.none
                }
                return try GamePassStatusResult.parse(data)
            }.value
            guard generation == gamePassGeneration, !terminating else { return }
            gamePassStatus = result
            gamePassFromCache = result != nil
            gamePassError = nil
        } catch {
            guard generation == gamePassGeneration, !terminating else { return }
            gamePassStatus = nil
            gamePassFromCache = false
            gamePassError = "PC Game Pass status couldn't be read. Check it again."
        }
    }

    func checkGamePass(discoveryProducts: [CatalogProduct], ownedGames: [PCGame]?) {
        guard canStartMutation, !serviceBusy, installConsent == nil, uninstallConsent == nil else { return }
        let candidates = Self.gamePassProbes(discoveryProducts: discoveryProducts, ownedGames: ownedGames,
                                            compatibility: [:])
        guard !candidates.isEmpty else {
            gamePassError = "Load Discover and your PC library to check PC Game Pass."
            return
        }
        do { try installed.reserveMutation(gameID: nil) }
        catch { gamePassError = Self.message(error); return }
        gamePassGeneration += 1
        gamePassBusy = true
        gamePassError = nil
        gamePassLog = nil
        gamePassFailureCode = nil
        var runID = InstalledGamesController.runID()
        gamePassTask = Task {
            defer {
                gamePassBusy = false
                gamePassTask = nil
                installed.releaseMutation()
            }
            do {
                await cancelPrecheck()
                for productID in candidates { await loadCompatibility(productID: productID) }
                guard !terminating else { return }
                let probes = Self.gamePassProbes(discoveryProducts: discoveryProducts, ownedGames: ownedGames,
                                                compatibility: compatibility)
                guard !probes.isEmpty else {
                    gamePassStatus = nil
                    gamePassFromCache = false
                    gamePassError = "No suitable PC game is loaded to check PC Game Pass. Browse more games in Discover."
                    return
                }
                for productID in probes.prefix(3) {
                    runID = InstalledGamesController.runID()
                    let outcome = try await mutationRunner.run(command: .gamePassStatus, runID: runID, arguments: [productID])
                    gamePassLog = outcome.log
                    guard outcome.code == 0, let data = outcome.result else {
                        gamePassFailureCode = outcome.code
                        throw GameScriptError.failed(outcome.code)
                    }
                    let result = try GamePassStatusResult.parse(data, productID: productID)
                    gamePassStatus = result
                    gamePassFromCache = false
                    if result.active != nil || terminating { break }
                }
            } catch {
                gamePassStatus = nil
                gamePassFromCache = false
                gamePassError = gamePassFailureCode == 11
                    ? "Ode to X couldn't verify PC Game Pass download access. Check game access status or try the check again. This result doesn't establish that your subscription or sign-in expired."
                    : Self.message(error)
                gamePassLog = await scriptLog(runID)
            }
        }
    }

    func stop(_ game: InstalledGame) {
        guard canStartMutation, installConsent == nil, uninstallConsent == nil else { return }
        if usesUnifiedAccount {
            stopTask = Task {
                await installed.stopNative(game)
                stopTask = nil
            }
            return
        }
        let token: UUID
        do { token = try installed.reserveStop(game) }
        catch {
            resetFeedback(productID: game.storeId)
            self.error = Self.message(error)
            return
        }
        let runID = InstalledGamesController.runID()
        stopTask = Task {
            defer {
                stopTask = nil
                installed.releaseMutation()
            }
            do {
                let outcome = try await mutationRunner.run(command: .stop, runID: runID, arguments: [game.storeId])
                guard outcome.code == 0, let data = outcome.result else { throw GameScriptError.failed(outcome.code) }
                _ = try GameStopResult.parse(data, productID: game.storeId)
                installed.completeStop(token: token, gameID: game.id, error: nil, log: nil)
            } catch {
                installed.completeStop(token: token, gameID: game.id, error: Self.message(error),
                                       log: await scriptLog(runID))
            }
        }
    }

    func checkSetupOnce() {
        guard !usesUnifiedAccount else { return }
        guard !setupCheckedOnce, !terminating else { return }
        setupCheckedOnce = true
        refreshSetup()
    }

    private func refreshSetup() {
        guard !terminating, !installed.accountDisconnecting else { return }
        if setupBusy {
            if !setupRepairing { setupRefreshPending = true }
            return
        }
        setupBusy = true
        setupError = nil
        setupLog = nil
        let runID = InstalledGamesController.runID()
        setupTask = Task {
            defer {
                setupBusy = false
                setupTask = nil
                if setupRefreshPending {
                    setupRefreshPending = false
                    refreshSetup()
                }
            }
            do {
                let outcome = try await setupRunner.run(command: .setup, runID: runID, arguments: ["check"])
                setupLog = outcome.log
                setupResult = try GameSetupResult.parse(outcome)
                setupError = outcome.code == 0 ? nil : GameScriptError.failed(outcome.code).localizedDescription
            } catch {
                setupResult = nil
                setupError = Self.message(error)
                setupLog = await scriptLog(runID)
            }
        }
    }

    func repairSetup() {
        guard canRepairSetup else { return }
        do { try installed.reserveMutation(gameID: nil) }
        catch { setupError = Self.message(error); return }
        installed.runtimeRepairActive = true
        setupBusy = true
        setupRepairing = true
        setupError = nil
        setupLog = nil
        serviceStatus = nil
        gamePassGeneration += 1
        gamePassStatus = nil
        gamePassFromCache = false
        let runID = InstalledGamesController.runID()
        setupTask = Task {
            defer {
                setupBusy = false
                setupRepairing = false
                setupTask = nil
                installed.runtimeRepairActive = false
                installed.releaseMutation()
            }
            do {
                await cancelPrecheck()
                let outcome = try await mutationRunner.run(command: .setup, runID: runID, arguments: ["repair"])
                setupLog = outcome.log
                setupResult = try GameSetupResult.parse(outcome)
                setupError = outcome.code == 0 ? nil : GameScriptError.failed(outcome.code).localizedDescription
                if outcome.code == 0 { await installed.refreshAfterSetupRepair() }
            } catch {
                setupResult = nil
                setupError = Self.message(error)
                setupLog = await scriptLog(runID)
            }
        }
    }

    func install(_ game: PCGame) async {
        guard canInstall(productID: game.id), !installingDirectly else { return }
        directInstallProductID = game.id
        installingDirectly = true
        directInstallCancelled = false
        defer { installingDirectly = false; directInstallProductID = nil }
        await prepareInstall(game)
        guard !directInstallCancelled else { installConsent = nil; return }
        guard let consent = installConsent else { return }
        if consentCanQueue(consent) {
            confirmInstall(consent)
        } else {
            error = consent.checkError ?? consent.compatibility?.explanation
                ?? "This game couldn't be installed. Try again."
            installConsent = nil
        }
    }

    func resume(_ game: PCGame, installed installedGame: InstalledGame) async {
        await repair(game, installed: installedGame, resuming: true)
    }

    func repair(_ game: PCGame, installed installedGame: InstalledGame, resuming: Bool = false) async {
        guard canInstall(productID: game.id), !installingDirectly, installed.games.contains(installedGame),
              installedGame.storeId == game.id, !resuming || usesUnifiedAccount,
              !installed.checkingInstallations.contains(installedGame.id) else { return }
        directInstallProductID = game.id
        installingDirectly = true
        directInstallCancelled = false
        defer { installingDirectly = false; directInstallProductID = nil }
        await prepareInstall(game, repairing: installedGame)
        installConsent?.resuming = resuming
        guard !directInstallCancelled else { installConsent = nil; return }
        guard let consent = installConsent else { return }
        if consentCanQueue(consent) {
            confirmInstall(consent)
        } else {
            error = consent.checkError ?? consent.compatibility?.explanation
                ?? "The full game couldn't be downloaded. Try again."
            installConsent = nil
        }
    }

    /// Answers "can this play on Mac?" before the user presses Install. Reads cached verdicts, then
    /// checks uncached games one at a time while idle. Any user action cancels it first.
    func precheck(_ productIDs: [String]) {
        guard precheckTask == nil, !terminating else { return }
        let ids = productIDs.filter { PCGamesClient.validProductID($0) && !precheckAttempted.contains($0) }
        guard !ids.isEmpty else { return }
        precheckTask = Task {
            defer { precheckTask = nil; precheckRunID = nil; precheckingProductID = nil }
            for id in ids {
                if compatibility[id] == nil { await loadCompatibility(productID: id) }
                guard compatibility[id] == nil, compatibilityErrors[id] == nil else { continue }
                // Reading saved evidence is safe even when unified-account gameplay is gated.
                // The legacy checker authenticates independently and must not run in that mode.
                if usesUnifiedAccount { continue }
                guard !Task.isCancelled, canStartMutation, installConsent == nil, uninstallConsent == nil,
                      installed.runningGameID == nil, serviceStatus?.signedIn != false else { return }
                precheckAttempted.insert(id)
                let runID = InstalledGamesController.runID()
                precheckRunID = runID
                precheckingProductID = id
                guard let outcome = try? await precheckRunner.run(command: .check, runID: runID, arguments: [id]),
                      !Task.isCancelled else { return }
                // Sign-in or network failures stop the pass; Install still runs the full check.
                guard outcome.code == 0, let data = outcome.result,
                      let result = try? GameCompatibilityResult.parse(data, productID: id) else { return }
                if compatibility[id] == nil { compatibility[id] = result }
            }
        }
    }

    func cancelPrecheck() async {
        guard let task = precheckTask else { return }
        task.cancel()
        if let runID = precheckRunID {
            precheckAttempted.remove(precheckingProductID ?? "")
            await precheckRunner.cancel(runID: runID)
        }
        await task.value
    }

    func prepareInstall(_ game: PCGame, repairing: InstalledGame? = nil, expectedAccountHash: String? = nil,
                        destination: URL? = nil) async {
        await cancelPrecheck()
        guard canInstall(productID: game.id), PCGamesClient.validProductID(game.id) else { return }
        let reviewAccount = usesUnifiedAccount ? nativeAccount : nil
        guard !usesUnifiedAccount || expectedAccountHash == nil || expectedAccountHash == reviewAccount else {
            installPreparationFailed("Your Xbox account changed. Choose the game again before reviewing installation.",
                                     productID: game.id)
            return
        }
        preparingConsent = true
        preparingInstallProductID = game.id
        let generation = UUID()
        preparationGeneration = generation
        defer {
            if preparationGeneration == generation {
                preparingConsent = false
                preparingInstallProductID = nil
            }
        }
        if usesUnifiedAccount, repairing == nil { await installed.discoverNativeInstallations() }
        guard !Task.isCancelled, preparationGeneration == generation, canContinueInstall(productID: game.id),
              reviewAccount == (usesUnifiedAccount ? nativeAccount : nil) else { return }
        if let repairing {
            guard repairing.storeId == game.id, installed.games.contains(repairing),
                  installed.runningGameID != repairing.id else { return }
        }
        let proposedDestination: URL
        do {
            if let destination { proposedDestination = destination }
            else if let repairing { proposedDestination = URL(fileURLWithPath: repairing.folder) }
            else { proposedDestination = try await installDestination(for: game) }
        } catch { installPreparationFailed(Self.message(error), productID: game.id); return }
        guard preparationGeneration == generation, canContinueInstall(productID: game.id) else { return }
        guard admitInstall(productID: game.id, installedID: repairing?.id,
                           destination: proposedDestination.path) else { return }
        if operation == nil {
            resetFeedback(productID: game.id)
            if repairing == nil { downloadRetry = game }
        }
        do {
            let destination: URL
            destination = proposedDestination
            guard preparationGeneration == generation else { return }
            let storage = try await storageProbe.read {
                if repairing?.storageVolume?.isUnavailable(mountedRoots: GameStorageVolume.mountedRoots()) == true {
                    throw GameInstallLocationError.driveUnavailable
                }
                return (try GameScriptFiles.availableSpace(for: destination),
                        repairing?.storageVolume ?? GameStorageVolume.read(at: destination.deletingLastPathComponent()))
            }
            guard preparationGeneration == generation, canContinueInstall(productID: game.id),
                  !(installingDirectly && directInstallCancelled) else { return }
            guard reviewAccount == (usesUnifiedAccount ? nativeAccount : nil) else {
                installPreparationFailed("Your Xbox account changed. Choose the game again before reviewing installation.",
                                         productID: game.id)
                return
            }
            if repairing == nil, installed.games.contains(where: { $0.folder == destination.path }) {
                throw GameScriptError.invalidDestination
            }
            installConsent = GameInstallConsent(game: game, destination: destination,
                                                freeBytes: storage.0, installedID: repairing?.id,
                                                nativeAccountHash: usesUnifiedAccount ? nativeAccount : nil,
                                                storageVolume: storage.1)
            installLocationError = nil
            if operation == nil { error = nil }
            preparingConsent = false
            // The serial runner cannot perform a legacy package check during another
            // download. Keep it explicitly pending, and run it before queued execution.
            if usesUnifiedAccount || downloadOperationActive { return }
            try installed.reserveMutation(gameID: repairing?.id)
            checkingCompatibility = true
            let runID = InstalledGamesController.runID()
            compatibilityRunID = runID
            log = nil
            failureCode = nil
            compatibilityTask = Task {
                defer {
                    checkingCompatibility = false
                    compatibilityRunID = nil
                    compatibilityTask = nil
                    installed.releaseMutation()
                }
                do {
                    let outcome = try await mutationRunner.run(command: .check, runID: runID, arguments: [game.id])
                    guard compatibilityRunID == runID, installConsent?.game.id == game.id else { return }
                    log = outcome.log
                    guard outcome.code == 0, let data = outcome.result else {
                        failureCode = outcome.code
                        throw GameScriptError.failed(outcome.code)
                    }
                    let result = try GameCompatibilityResult.parse(data, productID: game.id)
                    compatibility[game.id] = result
                    compatibilityErrors[game.id] = nil
                    installConsent?.compatibility = result
                } catch {
                    guard installConsent?.game.id == game.id else { return }
                    installConsent?.checkError = Self.message(error)
                    log = await scriptLog(runID)
                }
            }
            await compatibilityTask?.value
        } catch {
            guard preparationGeneration == generation else { return }
            installPreparationFailed(Self.message(error), productID: game.id)
        }
    }

    func installationCheckRequired(for game: PCGame) -> Bool {
        guard !installed.discoveringMounts else { return true }
        do {
            let location = try installLocationDefaults.flatMap { try GameInstallLocation.load($0) }
            let destination = try paths.destination(title: game.title, productID: game.id,
                root: location.map { URL(fileURLWithPath: $0.folder) })
            return !InstalledGamesController.permitsInstallation(productID: game.id, destination: destination.path,
                candidates: installed.undiscoveredInstallations, pendingRoots: installed.pendingDiscoveryRoots)
        } catch {
            return true
        }
    }

    func checkExistingInstallations() async {
        await installed.discoverNativeInstallations()
        error = installed.discoveryError
    }

    func installDestination(for game: PCGame, root: URL? = nil) async throws -> URL {
        let saved = try root == nil ? installLocationDefaults.flatMap { try GameInstallLocation.load($0) } : nil
        let paths = paths
        return try await storageProbe.read {
            if let root {
                return try GameInstallLocation(folder: root).destination(title: game.title, productID: game.id, paths: paths)
            }
            if let saved { return try saved.destination(title: game.title, productID: game.id, paths: paths) }
            return try paths.destination(title: game.title, productID: game.id)
        }
    }

    func chooseInstallLocation(_ consent: GameInstallConsent) async {
        guard installConsent?.id == consent.id, consent.installedID == nil, !consent.resuming,
              !choosingInstallLocation, !checkingCompatibility, canInstall(productID: consent.game.id) else { return }
        choosingInstallLocation = true
        defer { choosingInstallLocation = false }
        let panel = NSOpenPanel()
        panel.title = "Choose where to install this game"
        panel.prompt = "Choose folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = consent.destination.deletingLastPathComponent()
        guard await panel.begin() == .OK, let root = panel.url else { return }
        await updateInstallLocation(consent, root: root)
    }

    func updateInstallLocation(_ consent: GameInstallConsent, root: URL) async {
        guard installConsent?.id == consent.id, consent.installedID == nil, !consent.resuming,
              !checkingCompatibility, canInstall(productID: consent.game.id) else { return }
        do {
            let destination = try await installDestination(for: consent.game, root: root)
            guard !installed.games.contains(where: { $0.folder == destination.path }) else {
                throw GameScriptError.invalidDestination
            }
            let storage = try await storageProbe.read {
                (try GameScriptFiles.availableSpace(for: destination), GameStorageVolume.read(at: root))
            }
            guard installConsent?.id == consent.id, canInstall(productID: consent.game.id) else { return }
            guard admitInstall(productID: consent.game.id, destination: destination.path) else { return }
            installConsent?.destination = destination
            installConsent?.freeBytes = storage.0
            installConsent?.storageVolume = storage.1
            installLocationError = nil
        } catch {
            guard installConsent?.id == consent.id else { return }
            installLocationError = error.localizedDescription
        }
    }

    func confirmInstall(_ consent: GameInstallConsent) {
        guard installConsent?.id == consent.id, installConsent?.destination == consent.destination,
              !choosingInstallLocation, canInstall(productID: consent.game.id), !recoveryRequired,
              consentCanQueue(consent) else { return }
        guard admitInstall(productID: consent.game.id, installedID: consent.installedID,
                           destination: consent.destination.path) else {
            installConsent = nil
            return
        }
        if operation == nil { resetFeedback(productID: consent.game.id) }
        installConsent = nil
        let record = GameOperationRecord(id: startingQueuedInstall?.id ?? InstalledGamesController.runID(),
            kind: consent.resuming ? .resume : consent.installedID == nil ? .install : .repair, productID: consent.game.id,
            title: consent.game.title, destination: consent.destination.path, installedID: consent.installedID,
            nativeAccountHash: consent.nativeAccountHash)
        if let id = consent.installedID,
           !installed.games.contains(where: { $0.id == id && $0.storeId == record.productID && $0.folder == record.destination }) {
            installPreparationFailed("This game's installed entry changed. Choose it again.", productID: consent.game.id)
            return
        }
        if consent.installedID == nil, installed.games.contains(where: { $0.folder == record.destination }) {
            installPreparationFailed(GameScriptError.invalidDestination.localizedDescription, productID: consent.game.id)
            return
        }
        if operation != nil || (!queuedInstalls.isEmpty && startingQueuedInstall == nil)
            || (!usesUnifiedAccount && consent.compatibility == nil) {
            let entry = QueuedGameInstall(record: record, storageVolume: consent.storageVolume)
            do {
                try installQueueJournal.save(queuedInstalls + [entry])
                queuedInstalls.append(entry)
                installQueueError = nil
                scheduleInstallQueue()
            } catch {
                installQueueError = "The installation wasn't queued. \(Self.message(error))"
            }
        } else {
            begin(record, storageVolume: startingQueuedInstall?.storageVolume ?? consent.storageVolume)
        }
    }

    func cancelQueuedInstall(_ id: String) async {
        guard queuedInstalls.contains(where: { $0.id == id }), operation?.id != id else { return }
        do {
            let remaining = queuedInstalls.filter { $0.id != id }
            try installQueueJournal.save(remaining)
            queuedInstalls = remaining
            if startingQueuedInstall?.id == id { await cancelInstallConsent() }
            if remaining.isEmpty { installQueuePaused = false }
            installQueueError = nil
        } catch { installQueueError = "The queued installation couldn't be cancelled. \(Self.message(error))" }
    }

    func resumeInstallQueue() {
        guard !recoveryRequired else { return }
        installQueuePaused = false
        installQueueError = nil
        scheduleInstallQueue()
    }

    private func scheduleInstallQueue() {
        guard installQueueTask == nil, !queuedInstalls.isEmpty, !installQueuePaused, !terminating else { return }
        let currentMutation = mutationTask
        installQueueTask = Task {
            await currentMutation?.value
            defer { installQueueTask = nil }
            while let next = queuedInstalls.first, !installQueuePaused, !terminating {
                guard !recoveryRequired, operation == nil, mutationSlotAvailable,
                      installConsent == nil, !installingDirectly else {
                    installQueuePaused = true
                    return
                }
                startingQueuedInstall = next
                installQueueError = nil
                let record = next.record
                guard record.nativeAccountHash == (usesUnifiedAccount ? nativeAccount : nil) else {
                    installQueueError = "The account changed. Cancel this queued request and choose the game again."
                    installQueuePaused = true
                    startingQueuedInstall = nil
                    return
                }
                let repaired: InstalledGame?
                if let id = record.installedID {
                    guard let game = installed.games.first(where: {
                        $0.id == id && $0.storeId == record.productID && $0.folder == record.destination
                    }) else {
                        installQueueError = "The installed entry changed. Cancel this queued request and choose the game again."
                        installQueuePaused = true
                        startingQueuedInstall = nil
                        return
                    }
                    repaired = game
                } else { repaired = nil }
                await prepareInstall(PCGame(id: record.productID, title: record.title, artwork: nil),
                    repairing: repaired, expectedAccountHash: record.nativeAccountHash,
                    destination: URL(fileURLWithPath: record.destination))
                installConsent?.resuming = record.kind == .resume
                if queuedInstalls.contains(where: { $0.id == next.id }),
                   let consent = installConsent, consentAdmitted(consent) {
                    confirmInstall(consent)
                    await mutationTask?.value
                }
                startingQueuedInstall = nil
                if queuedInstalls.contains(where: { $0.id == next.id }) {
                    installQueuePaused = true
                    installQueueError = error ?? installConsent?.checkError
                        ?? installConsent?.compatibility?.explanation
                        ?? "The queued installation needs checking before it can start."
                    installConsent = nil
                    return
                }
                if recoveryRequired || error != nil {
                    installQueuePaused = !queuedInstalls.isEmpty
                    return
                }
            }
        }
    }

    func cancelInstallConsent() async {
        if installingDirectly { directInstallCancelled = true }
        preparationGeneration = UUID()
        preparingConsent = false
        preparingInstallProductID = nil
        installConsent = nil
        guard let runID = compatibilityRunID else { return }
        await mutationRunner.cancel(runID: runID)
        await compatibilityTask?.value
    }

    func loadCompatibility(productID: String) async {
        guard PCGamesClient.validProductID(productID) else { return }
        let paths = paths
        do {
            let result = try await Task.detached {
                guard let data = try GameScriptFiles.read(paths.compatibilityFile(productID: productID),
                                                          missingAllowed: true) else { return Optional<GameCompatibilityResult>.none }
                return try GameCompatibilityResult.parse(data, productID: productID)
            }.value
            if let result {
                if let previous = compatibility[productID]?.checkedDate, let date = result.checkedDate, date < previous { return }
            }
            compatibility[productID] = result
            compatibilityErrors[productID] = nil
        } catch {
            compatibility[productID] = nil
            compatibilityErrors[productID] = "Mac support details couldn't be read. Choose Install to check again."
        }
    }

    func prepareUninstall(_ game: InstalledGame) {
        guard canStartMutation, queuedInstalls.isEmpty, !recoveryRequired, installed.games.contains(game),
              installed.runningGameID != game.id else { return }
        uninstallConsent = game
    }

    func confirmUninstall(_ game: InstalledGame) {
        guard uninstallConsent?.id == game.id, canStartMutation, !recoveryRequired,
              installed.games.contains(game), installed.runningGameID != game.id else { return }
        uninstallConsent = nil
        begin(GameOperationRecord(id: InstalledGamesController.runID(), kind: .uninstall,
            productID: game.storeId, title: game.title, destination: game.folder, installedID: game.id,
            nativeAccountHash: usesUnifiedAccount ? nativeAccount : nil))
    }

    private func begin(_ record: GameOperationRecord, storageVolume: GameStorageVolume? = nil) {
        guard !usesUnifiedAccount || (record.nativeAccountHash != nil && record.nativeAccountHash == nativeAccount) else {
            resetFeedback(productID: record.productID)
            error = "Your Xbox account connection changed. Refresh your library before trying again."
            return
        }
        guard record.kind == .uninstall || admitInstall(productID: record.productID, installedID: record.installedID,
                                                       destination: record.destination) else {
            return
        }
        resetFeedback(productID: record.productID)
        do { try installed.reserveMutation(gameID: record.installedID) }
        catch { self.error = Self.message(error); return }
        operation = record
        progress = nil
        notice = nil
        error = nil
        log = nil
        failureCode = nil
        mutationTask = Task { [self] in
            if let storageVolume {
                do {
                    try await storageProbe.read {
                        if storageVolume.isUnavailable(mountedRoots: GameStorageVolume.mountedRoots()) {
                            throw GameInstallLocationError.driveUnavailable
                        }
                    }
                } catch {
                    self.error = Self.message(error)
                    operation = nil
                    installed.releaseMutation()
                    mutationTask = nil
                    return
                }
            }
            do {
                try await journal.save(record)
                if queuedInstalls.contains(where: { $0.id == record.id }) {
                    let remaining = queuedInstalls.filter { $0.id != record.id }
                    try installQueueJournal.save(remaining)
                    queuedInstalls = remaining
                }
                await cancelPrecheck()
                if record.nativeAccountHash != nil {
                    try await runNative(record)
                    mutationTask = nil
                    cancelling = false
                    return
                }
                if cancelling {
                    try await complete(record, outcome: GameScriptOutcome(code: 14, result: nil, log: nil))
                    mutationTask = nil
                    cancelling = false
                    return
                }
                let args = [record.productID, record.destination]
                let outcome = try await mutationRunner.run(
                    command: record.kind == .uninstall ? .uninstall : .install,
                    runID: record.id, arguments: args, progress: { [weak self] value in
                        await self?.publishProgress(value, runID: record.id)
                    })
                log = outcome.log
                try await complete(record, outcome: outcome)
            } catch {
                self.error = Self.message(error)
                log = record.nativeAccountHash == nil ? await scriptLog(record.id) : nativeRunner.stateDirectory
                if record.nativeAccountHash == nil, let scriptError = error as? GameScriptError,
                   [.missingStatus, .statusMismatch, .unavailable, .invalidDestination, .invalidProgress].contains(scriptError) {
                    do {
                        try await journal.clear()
                        operation = nil
                        installed.releaseMutation()
                    } catch { self.error = GameScriptError.storage.localizedDescription; recoveryRequired = true }
                } else { recoveryRequired = true }
            }
            mutationTask = nil
            cancelling = false
        }
    }

    private func runNative(_ record: GameOperationRecord) async throws {
        guard let configuration = unifiedSession?.nativeLifecycleConfiguration,
              let account = record.nativeAccountHash, account == nativeAccount else {
            throw GameScriptError.runtimeUnavailable
        }
        if cancelling {
            try await completeNative(record, result: nil)
            return
        }
        do {
            let value = try await nativeRunner.run(configuration: configuration, accountHash: account,
                operation: record.kind.nativeOperation, product: record.productID,
                gameDirectory: URL(fileURLWithPath: record.destination), runID: record.id,
                onProgress: { [weak self] value in self?.publishProgress(value, runID: record.id) })
            log = URL(fileURLWithPath: value.logDirectory)
            guard nativeAccount == account else { throw GameScriptError.invalidReceipt }
            try await completeNative(record, result: value)
        } catch {
            log = nativeRunner.stateDirectory
            if cancelling, !nativeRunner.started {
                try await completeNative(record, result: nil)
                return
            }
            if cancelling, error as? GameScriptError == .failed(14), let result = nativeRunner.completedResult {
                guard nativeAccount == account, result.errorCode == "CANCELLED", !result.success else {
                    throw GameScriptError.statusMismatch
                }
                try await completeNative(record, result: result)
                return
            }
            throw error
        }
    }

    private func completeNative(_ record: GameOperationRecord, result: NativeGameResult?) async throws {
        guard operation?.id == record.id else { throw GameScriptError.invalidReceipt }
        if let result, result.success {
            if record.kind == .uninstall {
                guard let id = record.installedID else { throw GameScriptError.invalidReceipt }
                try await installed.removeUninstalled(id)
                notice = "\(record.title) was uninstalled."
            } else {
                guard admitInstall(productID: record.productID, installedID: record.installedID,
                                   destination: record.destination) else {
                    throw GameScriptError.invalidReceipt
                }
                try await installed.registerNativeInstallation(folder: URL(fileURLWithPath: record.destination),
                                                               expectedStoreID: record.productID)
                notice = record.kind == .repair ? "\(record.title) was repaired." : "\(record.title) was installed."
            }
        } else {
            let cancelled = result?.errorCode == "CANCELLED" || result == nil
            failureCode = cancelled ? 14 : (result?.exitCode == 14 ? 1 : Int(result?.exitCode ?? 1))
            if cancelled {
                error = nil
                notice = record.kind == .uninstall
                    ? "Uninstall cancelled. Check the installation before trying again."
                    : "\(record.kind == .repair ? "Repair" : "Installation") cancelled. Partial files are kept; you can resume when ready."
            } else {
                error = result?.failureMessage
            }
        }
        try await journal.clear()
        operation = nil
        recoveryRequired = false
        installed.releaseMutation()
    }

    private func resetFeedback(productID: String?) {
        feedbackProductID = productID
        error = nil
        notice = nil
        log = nil
        failureCode = nil
        downloadNeedsSignIn = false
        downloadRetry = nil
    }

    private func complete(_ record: GameOperationRecord, outcome: GameScriptOutcome) async throws {
        guard operation?.id == record.id else { throw GameScriptError.invalidReceipt }
        if outcome.code == 0 {
            if record.kind == .uninstall {
                guard let id = record.installedID else { throw GameScriptError.invalidReceipt }
                try await installed.removeUninstalled(id)
                notice = "\(record.title) was uninstalled. Your saves are kept."
            } else {
                guard let data = outcome.result else { throw GameScriptError.invalidReceipt }
                let result = try JSONDecoder().decode(GameInstallResult.self, from: data)
                guard result.storeId == record.productID, result.folder == record.destination,
                      result.launcher.hasPrefix("/"), !result.launcher.split(separator: "/").contains(".."),
                      !result.launcher.split(separator: "/").contains(".") else {
                    throw GameScriptError.invalidReceipt
                }
                let folder = URL(fileURLWithPath: result.folder), launcher = URL(fileURLWithPath: result.launcher)
                try await Task.detached {
                    try GameScriptFiles.checkPath(folder)
                    try GameScriptFiles.checkPath(launcher)
                }.value
                try await installed.registerInstallation(folder: folder, launcher: launcher, expectedStoreID: record.productID)
                notice = record.kind == .repair ? "\(record.title) is ready to play." : "\(record.title) was installed."
            }
        } else {
            if record.kind != .uninstall, let data = outcome.result {
                let result = try JSONDecoder().decode(GameInstallResult.self, from: data)
                guard result.storeId == record.productID, result.folder == record.destination else {
                    throw GameScriptError.invalidReceipt
                }
            }
            failureCode = outcome.code
            if outcome.code == 11, record.kind == .install {
                downloadRetry = PCGame(id: record.productID, title: record.title, artwork: nil)
            }
            if outcome.code == 12 { await loadCompatibility(productID: record.productID) }
            let unsupportedReason = compatibility[record.productID].flatMap { $0.supported ? nil : $0.reason }
                ?? (progress?.phase == .failed ? progress?.message : nil)
            let specificFailure = progress?.phase == .failed ? progress?.message : nil
            error = outcome.code == 20 && record.kind == .uninstall
                ? "Your saves couldn't be preserved. The game wasn't uninstalled."
                : outcome.code == 12 ? unsupportedReason
                    ?? GameScriptError.failed(outcome.code).localizedDescription
                : outcome.code == 11 ? GameScriptError.failed(11).localizedDescription
                : specificFailure ?? GameScriptError.failed(outcome.code).localizedDescription
            if outcome.code == 14 {
                error = nil
                notice = GameScriptError.failed(14).localizedDescription
            }
        }
        try await journal.clear()
        operation = nil
        recoveryRequired = false
        installed.releaseMutation()
    }

    private func publishProgress(_ value: GameScriptProgress, runID: String) {
        guard operation?.id == runID else { return }
        progress = value
        queueProgressObserver?(value)
    }

    /// Queue bridge. Runs a single prepared `install` record to its terminal using the
    /// standard `begin()`/`complete()` machinery (reserve → run → register → release) and
    /// streams engine progress to `onProgress`. Additive: the interactive consent-driven path
    /// is untouched; the download queue is the only caller. Waits for any in-flight mutation
    /// to release so sequential queued jobs never collide on the single mutation slot.
    func runQueuedOperation(_ record: GameOperationRecord,
                            onProgress: @escaping (GameScriptProgress) -> Void) async -> InstallEvent {
        var record = record
        if usesUnifiedAccount { record.nativeAccountHash = nativeAccount }
        guard record.kind == .install, (try? record.validate()) != nil else { return .fail(code: -1) }
        guard admitInstall(productID: record.productID, destination: record.destination) else { return .fail(code: 12) }
        while !canStartMutation || operation != nil || mutationTask != nil {
            if terminating { return .fail(code: -1) }
            if abandonedQueuedRuns.remove(record.id) != nil { return .cancel }
            try? await Task.sleep(for: .milliseconds(30))
        }
        // A stop/cancel may have landed during the final wait iteration.
        if abandonedQueuedRuns.remove(record.id) != nil { return .cancel }
        if usesUnifiedAccount { await installed.discoverNativeInstallations() }
        if Task.isCancelled || abandonedQueuedRuns.remove(record.id) != nil { return .cancel }
        guard !terminating, canStartMutation,
              admitInstall(productID: record.productID, destination: record.destination) else { return .fail(code: 12) }
        queueProgressObserver = onProgress
        defer { queueProgressObserver = nil }
        begin(record)
        guard operation?.id == record.id else { return .fail(code: -1) }
        await mutationTask?.value
        if let code = failureCode {
            guard code != 14 else {
                // A queue-originated pause/cancel stops the engine with code 14 (partial files
                // kept). That is the user's intent, not a failure, and the per-job queue UI
                // already reflects it — so clear the shared operation banner that `complete()`
                // populated instead of surfacing a spurious "download stopped / failed" notice.
                failureCode = nil
                error = nil
                log = nil
                notice = nil
                return .cancel
            }
            return .fail(code: code)
        }
        // `begin` resets `error` to nil for each run, so a non-nil value here means
        // the async install task threw (journal/mutation failure) without setting a
        // numeric failure code. Report it as a failure instead of a false `.complete`.
        if error != nil { return .fail(code: -1) }
        return .complete
    }

    /// Queue bridge. Stops the active queued run identified by `runID`; the engine keeps
    /// partial files (exit code 14) so a later resume can continue. If the run has not yet
    /// reached the mutation slot (`operation?.id` does not match), the request is recorded
    /// so `runQueuedOperation` abandons it before starting the real install.
    func cancelQueuedRun(runID: String) async {
        guard let operation, operation.id == runID else {
            abandonedQueuedRuns.insert(runID)
            return
        }
        guard operation.kind != .uninstall, !cancelling else { return }
        cancelling = true
        if operation.nativeAccountHash != nil { nativeRunner.cancel(); return }
        await mutationRunner.cancel(runID: runID)
    }

    func cancelInstall() async {
        guard canCancel, let operation else { return }
        cancelling = true
        if operation.nativeAccountHash != nil { nativeRunner.cancel(); return }
        await mutationRunner.cancel(runID: operation.id)
    }

    func reconcile() async {
        guard recoveryRequired, let record = operation, !checkingRecovery, mutationTask == nil else { return }
        checkingRecovery = true
        defer { checkingRecovery = false }
        do {
            if let account = record.nativeAccountHash {
                guard account == nativeAccount else { throw GameScriptError.runtimeUnavailable }
                let result = try NativeGameLifecycle.readResult(state: NativeGameLifecycle.directory(runID: record.id),
                    operation: record.kind.nativeOperation, product: record.productID,
                    gameDirectory: URL(fileURLWithPath: record.destination))
                log = URL(fileURLWithPath: result.logDirectory)
                try await completeNative(record, result: result)
                return
            }
            let outcome = try await Task.detached {
                guard let data = try GameScriptFiles.read(self.paths.receipt(record.id, suffix: "status"),
                                                          maximumBytes: 32) else { throw GameScriptError.invalidReceipt }
                let code = try GameScriptFiles.status(data)
                let result = code == 0 && record.kind != .uninstall
                    ? try GameScriptFiles.read(self.paths.receipt(record.id, suffix: "result.json")) : nil
                return GameScriptOutcome(code: code, result: result, log: GameScriptFiles.log(runID: record.id, paths: self.paths))
            }.value
            log = outcome.log
            try await complete(record, outcome: outcome)
        } catch { self.error = Self.message(error) }
    }

    func showLog() { if let log { NSWorkspace.shared.activateFileViewerSelecting([log]) } }
    func showServiceLog() { if let serviceLog { NSWorkspace.shared.activateFileViewerSelecting([serviceLog]) } }
    func showGamePassLog() { if let gamePassLog { NSWorkspace.shared.activateFileViewerSelecting([gamePassLog]) } }
    func showSetupLog() { if let setupLog { NSWorkspace.shared.activateFileViewerSelecting([setupLog]) } }
    func waitForMutation() async {
        await compatibilityTask?.value
        await mutationTask?.value
        await gamePassTask?.value
        await stopTask?.value
        await setupTask?.value
        await installQueueTask?.value
    }
    func waitForService() async { await serviceTask?.value }
    func waitForSetup() async {
        while let task = setupTask { await task.value }
    }
    func beginTermination() {
        terminating = true
        Task { await cancelPrecheck() }
    }
    func resumeAfterTerminationRefusal() { terminating = false }

    private func scriptLog(_ runID: String) async -> URL? {
        let paths = paths
        return await Task.detached { GameScriptFiles.log(runID: runID, paths: paths) }.value
    }

    private static func message(_ error: Error) -> String {
        if let typed = error as? GameStorageProbeError { return typed.localizedDescription }
        if let typed = error as? GameInstallLocationError { return typed.localizedDescription }
        if let typed = error as? GameScriptError { return typed.localizedDescription }
        if let typed = error as? InstalledGameError { return typed.localizedDescription }
        return GameScriptError.invalidReceipt.localizedDescription
    }
}
