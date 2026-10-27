// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation
import XodusManagement

/// Downloads restart incomplete files from zero (backend `download_resume.mode == restart_incomplete_from_zero`).
enum GameDownloadCopy {
    static let downloadAgain = "Download Again"
    static let discard = "Discard Partial Download…"
    static let restartNote = "Download will restart. Incomplete files download again from the beginning; only fully downloaded files that still match are reused."
    static func stopped(repair: Bool) -> String {
        repair ? "Repair stopped. Repairing again downloads all files again."
            : "Download stopped. Downloading again will start over."
    }
    static func discardMessage(title: String, folder: String) -> String {
        "This deletes the partially downloaded files for \(title) in \(folder). Other games and downloads aren't affected."
    }
    static let stopDownload = "Stop Download"
    static let stopRepair = "Stop Repair"
    static let stopAndDelete = "Stop and Delete Downloaded Files…"
    static func stopAndDeleteMessage(title: String) -> String {
        "The download stops and its partially downloaded files for \(title) are deleted. Other games and downloads aren't affected."
    }
    static let continueDownloading = "Continue Downloading"
    static let stopAndQuit = "Stop and Quit"
    static func quitTitle(title: String, percent: Int?) -> String {
        percent.map { "\(title) is still downloading (\($0)%)." } ?? "\(title) is still downloading."
    }
    static let quitMessage = "If you quit, the download stops and will start over next time."
    static let stopNote = "If you stop, the download will start over next time."
    static func percent(_ progress: GameScriptProgress?) -> Int? {
        guard let progress, progress.phase == .downloading, let total = progress.bytesTotal, total > 0 else { return nil }
        return Int((Double(min(progress.bytesDone, total)) / Double(total) * 100).rounded(.down))
    }
}

/// UX-M2: what the toolbar indicator and the game's card show while a download runs.
struct GameDownloadIndicator: Equatable, Sendable {
    let productID: String
    let title: String
    let status: String
    let percent: Int?

    var fraction: Double? { percent.map { Double($0) / 100 } }
    var summary: String { percent.map { "\(status) \($0)%" } ?? status }
    var accessibilityLabel: String { "\(title): \(summary)" }

    init?(record: GameOperationRecord?, progress: GameScriptProgress?, preparing: Bool) {
        guard let record, record.kind != .uninstall else { return nil }
        productID = record.productID
        title = record.title
        percent = GameDownloadCopy.percent(progress)
        if let progress { status = progress.phase.title }
        else { status = preparing ? GameScriptProgress.Phase.preparing.title : "Starting" }
    }
}

/// UX-M2: announced once when an install or repair registers successfully.
struct GameReadyAnnouncement: Equatable, Sendable {
    let productID: String
    let title: String
    let folder: String
    /// L19 MED 3: only a title Play can start is announced as ready to play.
    var playable = true
    var body: String { playable ? "\(title) is ready to play." : "\(title) was installed. Play isn't offered for it in this build yet." }
}

/// M2: Repair, Update, Resume and Download Full Game each start a large download; the user confirms first.
enum GameLifecycleIntent: Equatable, Sendable {
    case repair, update, resume, downloadFullGame
}

struct GameLifecycleConfirmation: Equatable, Sendable {
    let intent: GameLifecycleIntent
    let title: String
    let downloadBytes: Int64?

    var messageText: String {
        switch intent {
        case .repair: "Repair \(title)?"
        case .update: "Update \(title)?"
        case .resume: "Download \(title) again?"
        case .downloadFullGame: "Download the full game for \(title)?"
        }
    }
    var actionTitle: String {
        switch intent {
        case .repair: "Repair"
        case .update: "Update"
        case .resume: GameDownloadCopy.downloadAgain
        case .downloadFullGame: "Download"
        }
    }
    var informativeText: String {
        let size = downloadBytes.map {
            " Download size: \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))."
        } ?? ""
        switch intent {
        case .repair: return "Repair downloads all of the game's files again and replaces damaged ones. Saved games aren't changed.\(size)"
        case .update: return "The new version is downloaded and installed. You can't play while it updates.\(size)"
        case .resume: return "\(GameDownloadCopy.restartNote)\(size)"
        case .downloadFullGame: return "The full game is downloaded into its install folder.\(size)"
        }
    }
}

struct GameInstallSpace: Equatable, Sendable {
    let download: Int64
    let needed: Int64
    let available: Int64
    var short: Bool { needed > available }

    /// Package size plus working room: 5% or 2 GB, whichever is larger.
    static func needed(for download: Int64) -> Int64 {
        download + max(2 * 1_073_741_824, download / 20)
    }
}

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

    /// A fresh install must fit before anything is written. Resume and repair rewrite files in place, so they only report.
    var blocksOnSpace: Bool { installedID == nil && !resuming }

    func space(estimate: Int64?) -> GameInstallSpace? {
        guard let download = compatibility?.packageBytes ?? estimate, download > 0 else { return nil }
        return GameInstallSpace(download: download, needed: GameInstallSpace.needed(for: download), available: freeBytes)
    }

    func destination(forRootPath path: String) throws -> URL {
        guard installedID == nil, !resuming else { return destination }
        return try GameInstallLocation.rootURL(path: path)
            .appendingPathComponent(destination.lastPathComponent, isDirectory: true)
    }
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
    /// REQ-41: Remove from Library (Keep Files) awaiting confirmation; presented by GameOperationPresentation
    /// because menu content cannot present dialogs.
    @Published var removalConsent: InstalledGame?
    @Published private(set) var preparingConsent = false
    @Published private(set) var preparingInstallProductID: String?
    @Published private(set) var choosingInstallLocation = false
    @Published private(set) var installLocationError: String?
    @Published private(set) var checkingCompatibility = false
    @Published private(set) var installingDirectly = false
    @Published private(set) var compatibility: [String: GameCompatibilityResult] = [:]
    @Published private(set) var compatibilityErrors: [String: String] = [:]
    @Published private(set) var operation: GameOperationRecord?
    @Published private(set) var resumableInstallations: [String: GameOperationRecord] = [:]
    @Published private(set) var progress: GameScriptProgress?
    @Published private(set) var cancelling = false
    @Published private(set) var checkingRecovery = false
    @Published private(set) var recoveryRequired = false
    // Set when the saved operation or its receipt can't be read; enables an explicit Dismiss.
    @Published private(set) var recoveryUnreadable = false
    /// A backend run from a previous app process is still working on the journaled operation.
    @Published private(set) var orphanRunning = false
    @Published private(set) var orphanStoppable = false
    private var orphanPID: Int32?
    private var orphanTask: Task<Void, Never>?
    /// Recovery that needs the user's attention; a still-running backend is shown as progress instead.
    var awaitingRecovery: Bool { recoveryRequired && !orphanRunning }
    private var nativeChildStarted = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var log: URL?
    @Published private(set) var failureCode: Int?
    /// Installed games whose uninstall was refused because the folder no longer proves the installation (D1).
    @Published private(set) var damagedInstallations: [UUID: String] = [:]
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
    private(set) var terminating = false
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
        if usesUnifiedAccount, unifiedSession === session { return }
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
    }
    var presentedInstallConsent: GameInstallConsent? {
        installingDirectly ? nil : installConsent
    }
    var canSignIn: Bool {
        !usesUnifiedAccount && !serviceBusy && !isBusy && !recoveryRequired && !installed.mutationActive
            && !preparingConsent && !installingDirectly && !installed.accountDisconnecting
            && installed.runningGameID == nil && !terminating
    }
    var canStartMutation: Bool {
        (!usesUnifiedAccount || nativeAccount != nil) && !isBusy && !recoveryRequired && !installed.mutationActive && !serviceBusy && !preparingConsent && installed.loaded
            && !installed.editing && !installed.choosing && !installed.accountDisconnecting && !terminating
    }
    var installUnavailableReason: String? {
        guard !canStartMutation else { return nil }
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
            && !installed.accountDisconnecting
    }
    var canDisconnectAccount: Bool {
        canQuit && !recoveryRequired && !installed.mutationActive && !installed.editing
            && !installed.choosing && installed.runningGameID == nil && installed.stoppingGameID == nil
            && installConsent == nil && uninstallConsent == nil && !terminating
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
                ? "\(AppBrand.displayName) couldn't use this runtime's game-service sign-out helper. A matching runtime with sign-out support is required. No PC-library or launcher sign-in was removed."
                : "\(AppBrand.displayName) couldn't confirm game-service sign-out. That service may have stopped, but credential removal isn't confirmed. No PC-library or launcher sign-in was removed. Check the sign-out log before retrying."
            return false
        }
    }
    var canConfirmInstall: Bool {
        guard !choosingInstallLocation, canStartMutation, let consent = installConsent,
              consentAdmitted(consent) else { return false }
        if consent.blocksOnSpace, installSpace(consent)?.short == true { return false }
        let format = consent.installedID.flatMap { id in installed.games.first { $0.id == id }?.packageType?.label }
        return supportIssues(productID: consent.game.id, packageFormat: format, includeRuntime: false).isEmpty
    }
    var canCancel: Bool {
        operation != nil && operation?.kind != .uninstall && (!recoveryRequired || orphanStoppable) && !cancelling
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
        if usesUnifiedAccount {
            return nativeAccount == nil ? "person.crop.circle.badge.exclamationmark" : "checkmark.circle"
        }
        return serviceAccountNeedsVerification ? "person.crop.circle.badge.questionmark"
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

    /// L19-6: Repair waits for a running installation check instead of silently doing nothing.
    func canRepair(_ game: InstalledGame) -> Bool {
        canStartMutation && !installed.unavailableDriveIDs.contains(game.id) && installed.runningGameID != game.id
            && !installed.checkingInstallations.contains(game.id)
            && supportIssues(productID: game.storeId, packageFormat: game.packageType?.label,
                             includeRuntime: false).isEmpty
    }

    private func admitInstall(productID: String, installedID: UUID? = nil, destination: String? = nil,
                              managedOperation: GameOperationRecord? = nil) -> Bool {
        let record = managedOperation ?? operation ?? resumableInstallations[productID]
        let resumingManagedOperation = record.map {
            $0.kind != .uninstall && $0.productID == productID && $0.destination == destination
                && (try? $0.validate()) != nil
        } == true
        guard installedID != nil || installed.canCreateInstallation(productID: productID, destination: destination,
            resumingManagedOperation: resumingManagedOperation) else {
            if operation == nil && !checkingCompatibility { resetFeedback(productID: productID) }
            error = installed.hasUnverifiedInstallation(productID: productID)
                ? "The installation couldn't be checked. Try again."
                : GameScriptError.invalidDestination.localizedDescription
            return false
        }
        let format = installedID.flatMap { id in installed.games.first { $0.id == id }?.packageType?.label }
        let issues = supportIssues(productID: productID, packageFormat: format, includeRuntime: false)
        guard issues.isEmpty else {
            if operation == nil && !checkingCompatibility {
                resetFeedback(productID: productID)
                error = issues.map(\.detail).joined(separator: " ")
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

    func restore() async {
        guard !restored, !isBusy, !terminating else { return }
        restored = true
        var resumableFailed = false
        do { resumableInstallations = try await journal.loadResumable() }
        catch { resumableFailed = true }
        let saved: GameOperationRecord?
        do { saved = try await journal.load() }
        catch {
            // Only an unreadable operation.json is unreadable recovery; keep mutations fenced meanwhile.
            recoveryRequired = true
            recoveryUnreadable = true
            self.error = GameScriptError.storage.localizedDescription
            claimRecoveryMutation(gameID: nil)
            return
        }
        guard let record = saved else {
            if resumableFailed { error = GameScriptError.storage.localizedDescription }
            return
        }
        resetFeedback(productID: record.productID)
        operation = record
        recoveryRequired = true
        error = "The last game operation needs checking. No operation will be repeated automatically."
        log = await Task.detached { GameScriptFiles.log(runID: record.id, paths: self.paths) }.value
        claimRecoveryMutation(gameID: record.installedID)
        if await followOrphanIfRunning(record) { error = nil }
    }

    /// True only while this controller holds the mutation fence for a restored recovery.
    private(set) var recoveryMutationOwned = false
    private var recoveryReservationTask: Task<Void, Never>?
    private var recoveryCheckRequested = false

    /// Reserves the mutation fence for a restored record; when other work holds it, retries
    /// instead of treating the saved operation as unreadable.
    private func claimRecoveryMutation(gameID: UUID?) {
        if (try? installed.reserveMutation(gameID: gameID)) != nil {
            recoveryMutationOwned = true
            return
        }
        recoveryCheckRequested = false
        recoveryReservationTask?.cancel()
        recoveryReservationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.recoveryRequired, !self.recoveryMutationOwned else { return }
                if (try? self.installed.reserveMutation(gameID: gameID)) != nil {
                    self.recoveryMutationOwned = true
                    self.recoveryReservationTask = nil
                    // The waiting check promised to run once other work ended.
                    if self.recoveryCheckRequested {
                        self.recoveryCheckRequested = false
                        await self.reconcile()
                    }
                    return
                }
            }
        }
    }

    /// Clears recovery ownership once the restored record has been completed or dismissed.
    private func settleRecoveryMutation() {
        recoveryReservationTask?.cancel()
        recoveryReservationTask = nil
        recoveryCheckRequested = false
        recoveryMutationOwned = false
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
                        : "\(AppBrand.displayName) couldn't confirm saved game access. This can also happen when the service is unavailable. Continue with Microsoft to check authorization; installation resumes only after confirmation."
                    installConsent?.checkError = error
                }
            } catch {
                serviceStatus = nil
                serviceError = Self.message(error)
                serviceLog = await scriptLog(runID)
                if !terminating, feedbackProductID == game.id {
                    self.error = "\(AppBrand.displayName) couldn't check download access. No new sign-in was started. Check download access to retry, or show the log."
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
                    ? "\(AppBrand.displayName) couldn't verify PC Game Pass download access. Check game access status or try the check again. This result doesn't establish that your subscription or sign-in expired."
                    : Self.message(error)
                gamePassLog = await scriptLog(runID)
            }
        }
    }

    /// L19-5: stopping the game this app started never waits on an unrelated download or account check.
    func stop(_ game: InstalledGame) {
        guard installed.canStop(game), !installed.applicationTerminating,
              installConsent == nil, uninstallConsent == nil else { return }
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
        guard canStartMutation, !installingDirectly else { return }
        directInstallProductID = game.id
        installingDirectly = true
        directInstallCancelled = false
        defer { installingDirectly = false; directInstallProductID = nil }
        await prepareInstall(game)
        guard !directInstallCancelled else { installConsent = nil; return }
        guard let consent = installConsent else { return }
        if consentAdmitted(consent) {
            confirmInstall(consent)
        } else {
            error = consent.checkError ?? consent.compatibility?.explanation
                ?? "This game couldn't be installed. Try again."
            installConsent = nil
        }
    }

    /// Set by the app to a native confirmation; checks leave it nil so synthetic runs proceed unattended.
    var confirmLifecycle: (@MainActor (GameLifecycleConfirmation) async -> Bool)?
    /// Set by the app to post a "ready to play" notification; nil in synthetic checks.
    var announceReady: (@MainActor (GameReadyAnnouncement) -> Void)?

    /// Live only while this app runs the operation or follows a verified backend run; a restored or failed
    /// record awaiting a check shows no download progress.
    var downloadIndicator: GameDownloadIndicator? {
        guard orphanRunning || (!recoveryRequired && mutationTask != nil) else { return nil }
        return GameDownloadIndicator(record: operation, progress: progress, preparing: preparingConsent)
    }

    func resume(_ game: PCGame, installed installedGame: InstalledGame) async {
        await repair(game, installed: installedGame, resuming: true, intent: .resume)
    }

    func repair(_ game: PCGame, installed installedGame: InstalledGame, resuming: Bool = false,
                intent: GameLifecycleIntent? = nil) async {
        guard canStartMutation, !installingDirectly, installed.games.contains(installedGame),
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
        if consentAdmitted(consent), let confirm = confirmLifecycle {
            let request = GameLifecycleConfirmation(intent: intent ?? (resuming ? .resume : .repair),
                title: game.title, downloadBytes: consent.compatibility?.packageBytes)
            let accepted = await confirm(request)
            guard accepted, !directInstallCancelled, installConsent?.id == consent.id else {
                installConsent = nil
                return
            }
        }
        if consentAdmitted(consent) {
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

    func prepareInstall(_ game: PCGame, repairing: InstalledGame? = nil, expectedAccountHash: String? = nil) async {
        await cancelPrecheck()
        guard canStartMutation, PCGamesClient.validProductID(game.id) else { return }
        let reviewAccount = usesUnifiedAccount ? nativeAccount : nil
        guard !usesUnifiedAccount || expectedAccountHash == nil || expectedAccountHash == reviewAccount else {
            error = "Your Xbox account changed. Choose the game again before reviewing installation."
            return
        }
        do { resumableInstallations = try await journal.loadResumable() }
        catch { self.error = Self.message(error); return }
        let resume = repairing == nil ? resumableInstallations[game.id] : nil
        guard resume == nil || resume?.nativeAccountHash == reviewAccount else {
            error = "Reconnect the Xbox account used for this installation before resuming."
            return
        }
        if usesUnifiedAccount, repairing == nil { await installed.discoverNativeInstallations() }
        guard !Task.isCancelled, canStartMutation,
              reviewAccount == (usesUnifiedAccount ? nativeAccount : nil) else { return }
        if let repairing {
            guard repairing.storeId == game.id, installed.games.contains(repairing),
                  installed.runningGameID != repairing.id else { return }
        }
        resetFeedback(productID: game.id)
        let proposedDestination: URL
        do {
            if let repairing { proposedDestination = URL(fileURLWithPath: repairing.folder) }
            else if let resume { proposedDestination = URL(fileURLWithPath: resume.destination) }
            else { proposedDestination = try await installDestination(for: game) }
            if repairing == nil {
                let destination = proposedDestination
                try await storageProbe.read {
                    try GameInstallLocation.validateDestination(destination, productID: game.id, managedRecord: resume)
                }
            }
        } catch { self.error = Self.message(error); return }
        guard admitInstall(productID: game.id, installedID: repairing?.id,
                           destination: proposedDestination.path) else { return }
        if repairing == nil { downloadRetry = game }
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
            guard preparationGeneration == generation, !terminating, !isBusy,
                  !(installingDirectly && directInstallCancelled) else { return }
            guard reviewAccount == (usesUnifiedAccount ? nativeAccount : nil) else {
                error = "Your Xbox account changed. Choose the game again before reviewing installation."
                return
            }
            if repairing == nil, installed.games.contains(where: { $0.folder == destination.path }) {
                throw GameScriptError.invalidDestination
            }
            installConsent = GameInstallConsent(game: game, destination: destination,
                                                freeBytes: storage.0, installedID: repairing?.id,
                                                nativeAccountHash: usesUnifiedAccount ? nativeAccount : nil,
                                                storageVolume: storage.1)
            installConsent?.resuming = resume != nil
            installLocationError = nil
            error = nil
            preparingConsent = false
            if usesUnifiedAccount { return }
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
            self.error = Self.message(error)
        }
    }

    func installationCheckRequired(for game: PCGame) -> Bool {
        if resumableInstallations[game.id] != nil { return false }
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

    func checkExistingInstallations(productID: String) async {
        if !installed.hasUnverifiedInstallation(productID: productID) {
            await installed.discoverNativeInstallations()
        }
        await installed.verifyDiscoveredInstallation(productID: productID)
    }

    func existingInstallationError(productID: String) -> String? {
        installed.discoveredVerificationErrors[productID]
    }

    func checkingExistingInstallation(productID: String) -> Bool {
        installed.verifyingDiscoveredProducts.contains(productID) || installed.automaticDiscoveryProducts.contains(productID)
    }

    func automaticInstallationKey(for game: PCGame) -> String {
        "\(installationCheckRequired(for: game)):\(installed.discoveredReadinessKey(productID: game.id)):\(canCheckExistingInstallation):\(operation == nil):\(preparingConsent)"
    }

    func automaticallyCheckExistingInstallation(_ game: PCGame) async {
        guard canCheckExistingInstallation, installationCheckRequired(for: game),
              !installed.games.contains(where: { $0.storeId == game.id }),
              operation == nil, !installingDirectly, !preparingConsent,
              !installed.mutationActive, !installed.accountDisconnecting, !terminating else { return }
        await installed.automaticallyVerifyDiscoveredInstallation(productID: game.id)
    }

    var canCheckExistingInstallation: Bool {
        installed.loaded && !installed.accountDisconnecting && !installed.mutationActive
            && !installed.editing && !installed.choosing && !terminating
    }

    func cancelExistingInstallationCheck(productID: String) {
        installed.cancelDiscoveredVerification(productID: productID)
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
              !choosingInstallLocation, !checkingCompatibility, canStartMutation else { return }
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

    func updateTypedInstallLocation(_ consent: GameInstallConsent, path: String) async {
        guard !choosingInstallLocation, !checkingCompatibility, canStartMutation,
              installConsent?.id == consent.id, consent.installedID == nil, !consent.resuming else { return }
        choosingInstallLocation = true
        defer { choosingInstallLocation = false }
        do {
            let root = try GameInstallLocation.rootURL(path: path)
            await updateInstallLocation(consent, root: root)
        } catch {
            installLocationError = "Choose an existing writable folder using an absolute path or Browse."
        }
    }

    func confirmInstallLocation(_ consent: GameInstallConsent, path: String) async {
        guard !choosingInstallLocation, !checkingCompatibility else { return }
        if consent.installedID == nil, !consent.resuming {
            await updateTypedInstallLocation(consent, path: path)
        }
        guard let current = installConsent, current.id == consent.id, installLocationError == nil else { return }
        do {
            guard try current.destination(forRootPath: path).path == current.destination.path else {
                throw GameScriptError.invalidDestination
            }
        } catch {
            installLocationError = Self.message(error)
            return
        }
        if current.installedID == nil {
            do {
                let resume = resumableInstallations[current.game.id]
                try await storageProbe.read {
                    try GameInstallLocation.validateDestination(current.destination, productID: current.game.id,
                        managedRecord: resume)
                }
            } catch {
                guard installConsent?.id == current.id else { return }
                installLocationError = Self.message(error)
                return
            }
        }
        confirmInstall(current)
    }

    func updateInstallLocation(_ consent: GameInstallConsent, root: URL) async {
        guard installConsent?.id == consent.id, consent.installedID == nil, !consent.resuming,
              !checkingCompatibility, canStartMutation else { return }
        do {
            let destination = try await installDestination(for: consent.game, root: root)
            try await storageProbe.read {
                try GameInstallLocation.validateDestination(destination, productID: consent.game.id, managedRecord: nil)
            }
            guard !installed.games.contains(where: { $0.folder == destination.path }) else {
                throw GameScriptError.invalidDestination
            }
            let storage = try await storageProbe.read {
                (try GameScriptFiles.availableSpace(for: destination), GameStorageVolume.read(at: root))
            }
            guard installConsent?.id == consent.id, canStartMutation else { return }
            installConsent?.destination = destination
            installConsent?.freeBytes = storage.0
            installConsent?.storageVolume = storage.1
            installLocationError = nil
        } catch {
            guard installConsent?.id == consent.id else { return }
            installLocationError = error.localizedDescription
        }
    }

    func launchSupport(productID: String) -> NativeLaunchSupport { installed.launchSupport(productID: productID) }

    func installSpace(_ consent: GameInstallConsent) -> GameInstallSpace? {
        consent.space(estimate: LibraryCatalogArtwork.shared.images[consent.game.id]?.facts.downloadBytes)
    }

    func confirmInstall(_ consent: GameInstallConsent) {
        guard installConsent?.id == consent.id, installConsent?.destination == consent.destination,
              installLocationError == nil, !(consent.blocksOnSpace && installSpace(consent)?.short == true),
              !choosingInstallLocation, canStartMutation, !recoveryRequired,
              consentAdmitted(consent) else { return }
        guard admitInstall(productID: consent.game.id, installedID: consent.installedID,
                           destination: consent.destination.path) else {
            installConsent = nil
            return
        }
        resetFeedback(productID: consent.game.id)
        installConsent = nil
        let record = GameOperationRecord(id: InstalledGamesController.runID(),
            kind: consent.resuming && consent.installedID != nil ? .resume
                : consent.installedID == nil ? .install : .repair, productID: consent.game.id,
            title: consent.game.title, destination: consent.destination.path, installedID: consent.installedID,
            nativeAccountHash: consent.nativeAccountHash)
        if let id = consent.installedID,
           !installed.games.contains(where: { $0.id == id && $0.storeId == record.productID && $0.folder == record.destination }) {
            error = "This game's installed entry changed. Choose it again."
            return
        }
        if consent.installedID == nil, installed.games.contains(where: { $0.folder == record.destination }) {
            error = GameScriptError.invalidDestination.localizedDescription
            return
        }
        begin(record, storageVolume: consent.storageVolume)
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

    func prepareRemoval(_ game: InstalledGame) {
        guard installed.games.contains(game), installed.runningGameID != game.id, !installed.mutationActive else { return }
        removalConsent = game
    }

    /// The Uninstall sheet's default: remove from the library and keep every file (REQ-135).
    func uninstallKeepingFiles(_ game: InstalledGame) async {
        guard uninstallConsent?.id == game.id else { return }
        uninstallConsent = nil
        await installed.remove(game)
    }

    func confirmRemoval(_ game: InstalledGame) async {
        guard removalConsent?.id == game.id else { return }
        removalConsent = nil
        await installed.remove(game)
    }

    /// REQ-135/L19-1: whether deleting a game's folder can only remove validated package content.
    enum UninstallSafety: Equatable {
        case safe
        case unsafe(String)
    }

    nonisolated static let saveMarkers: Set<String> = ["saves", "save", "savegames", "saved games", "savedata", "userdata",
                                           "profiles", "xodusprivatelocalsaves", "wgs", "connectedstorage"]
    nonisolated static let prefixMarkers: Set<String> = ["drive_c", "dosdevices", "pfx", "prefix", "prefixes", "wineprefix",
                                             "system.reg", "user.reg", "userdef.reg"]
    nonisolated static let uninstallUnsafeMessage = "This folder may hold saves, a Wine prefix or files X Ode can't identify, so it won't be deleted. Use Remove from Library (Keep Files) instead."

    /// Fails closed: only a folder whose MicrosoftGame.config names this product, with no symlinks and no
    /// save or prefix layout within four levels, may be deleted.
    nonisolated static func uninstallSafety(folder: URL, productID: String, entryLimit: Int = 200_000) -> UninstallSafety {
        guard let config = try? MicrosoftGameConfig.read(folder: folder), config.storeId == productID else {
            return .unsafe(uninstallUnsafeMessage)
        }
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                          options: [], errorHandler: { _, _ in false }) else {
            return .unsafe(uninstallUnsafeMessage)
        }
        var count = 0
        for case let url as URL in walker {
            count += 1
            guard count <= entryLimit,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                return .unsafe(uninstallUnsafeMessage)
            }
            let name = url.lastPathComponent.lowercased()
            if walker.level <= 4, saveMarkers.contains(name) || prefixMarkers.contains(name) {
                return .unsafe(uninstallUnsafeMessage)
            }
        }
        return .safe
    }

    func prepareUninstall(_ game: InstalledGame) {
        guard canStartMutation, !recoveryRequired, installed.games.contains(game),
              installed.runningGameID != game.id else { return }
        uninstallConsent = game
    }

    func confirmUninstall(_ game: InstalledGame) {
        guard uninstallConsent?.id == game.id, canStartMutation, !recoveryRequired,
              installed.games.contains(game), installed.runningGameID != game.id else { return }
        uninstallConsent = nil
        if installed.unavailableDriveIDs.contains(game.id) {
            resetFeedback(productID: game.storeId)
            error = GameInstallLocationError.driveUnavailable.localizedDescription
            return
        }
        begin(GameOperationRecord(id: InstalledGamesController.runID(), kind: .uninstall,
            productID: game.storeId, title: game.title, destination: game.folder, installedID: game.id,
            nativeAccountHash: usesUnifiedAccount ? nativeAccount : nil),
            storageVolume: game.storageVolume)
    }

    private func begin(_ record: GameOperationRecord, storageVolume: GameStorageVolume? = nil) {
        guard !usesUnifiedAccount || (record.nativeAccountHash != nil && record.nativeAccountHash == nativeAccount) else {
            resetFeedback(productID: record.productID)
            error = "Your Xbox account connection changed. Refresh your library before trying again."
            return
        }
        guard record.kind == .uninstall || admitInstall(productID: record.productID, installedID: record.installedID,
                                                       destination: record.destination, managedOperation: record) else {
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
        mutationTask = Task {
            if record.kind == .install {
                do {
                    let resume = resumableInstallations[record.productID]
                    try await storageProbe.read {
                        try GameInstallLocation.validateDestination(URL(fileURLWithPath: record.destination),
                            productID: record.productID, managedRecord: resume)
                    }
                } catch {
                    self.error = Self.message(error)
                    operation = nil
                    installed.releaseMutation()
                    mutationTask = nil
                    return
                }
            }
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
            if record.kind == .uninstall {
                do {
                    try await storageProbe.read {
                        let folder = URL(fileURLWithPath: record.destination)
                        try InstalledGameFiles.checkFolder(folder)
                        if let storageVolume, !storageVolume.identifies(GameStorageVolume.read(at: folder)) {
                            throw GameInstallLocationError.driveChanged
                        }
                        if case .unsafe(let reason) = Self.uninstallSafety(folder: folder, productID: record.productID) {
                            throw UninstallRefused(message: reason)
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
                let childStarted = record.nativeAccountHash != nil && nativeChildStarted
                log = record.nativeAccountHash == nil ? await scriptLog(record.id)
                    : childStarted ? nativeRunner.stateDirectory : nil
                if Self.releasesWithoutRecovery(native: record.nativeAccountHash != nil,
                                                childStarted: childStarted, error: error) {
                    do {
                        try await updateResumableInstallation(record, completed: false)
                        try await journal.clear(expectedRunID: record.id)
                        operation = nil
                        installed.releaseMutation()
                    } catch {
                        self.error = GameScriptError.storage.localizedDescription
                        recoveryRequired = true
                        recoveryMutationOwned = true
                    }
                } else {
                    // The run's own reservation is still held and now fences recovery.
                    recoveryRequired = true
                    recoveryMutationOwned = true
                }
            }
            mutationTask = nil
            cancelling = false
        }
    }

    /// A failed operation needs recovery only if something may have changed on disk.
    static func releasesWithoutRecovery(native: Bool, childStarted: Bool, error: Error) -> Bool {
        // Nothing ran if the backend child never started, so there is nothing to recover.
        if native { return !childStarted }
        guard let scriptError = error as? GameScriptError else { return false }
        return [.missingStatus, .statusMismatch, .unavailable, .invalidDestination,
                .invalidProgress].contains(scriptError)
    }

    private func runNative(_ record: GameOperationRecord) async throws {
        nativeChildStarted = false
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
                onStarted: { [weak self] in self?.nativeChildStarted = true },
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

    func completeNative(_ record: GameOperationRecord, result: NativeGameResult?) async throws {
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
                announceReady?(GameReadyAnnouncement(productID: record.productID, title: record.title,
                                                     folder: record.destination,
                                                     playable: launchSupport(productID: record.productID).canPlay))
            }
        } else {
            let cancelled = result?.errorCode == "CANCELLED" || result == nil
            failureCode = cancelled ? 14 : (result?.exitCode == 14 ? 1 : Int(result?.exitCode ?? 1))
            if cancelled {
                error = nil
                notice = record.kind == .uninstall
                    ? "Uninstall cancelled. Check the installation before trying again."
                    : GameDownloadCopy.stopped(repair: record.kind == .repair)
            } else {
                error = await result?.installationFailureMessage()
                if record.kind == .uninstall, let id = record.installedID, result?.damagedInstallation == true {
                    damagedInstallations[id] = result?.failureMessage
                }
            }
        }
        if result?.success == true, let id = record.installedID { damagedInstallations[id] = nil }
        try await updateResumableInstallation(record, completed: result?.success == true)
        try await journal.clear(expectedRunID: record.id)
        operation = nil
        recoveryRequired = false
        recoveryUnreadable = false
        installed.releaseMutation()
        settleRecoveryMutation()
    }

    @Published private(set) var discardingPartialProductID: String?

    /// Deletes only the retained partial folder for this exact product and retires only its record.
    struct UninstallRefused: LocalizedError { let message: String; var errorDescription: String? { message } }

    static let discardChangedElsewhereMessage =
        "This download changed in another X Ode window or is in use, so nothing was deleted. Check again before discarding."

    func discardPartialDownload(productID: String) async {
        guard canStartMutation, operation == nil, !recoveryRequired, discardingPartialProductID == nil,
              let record = resumableInstallations[productID] else { return }
        let destination = URL(fileURLWithPath: record.destination, isDirectory: true)
        resetFeedback(productID: productID)
        guard !installed.games.contains(where: {
            let folder = $0.folder.lowercased(), target = record.destination.lowercased()
            return folder == target || folder.hasPrefix(target + "/") || target.hasPrefix(folder + "/")
        }) else {
            error = "This folder belongs to an installed game, so it wasn't deleted."
            return
        }
        do { try installed.reserveMutation(gameID: nil) }
        catch { self.error = Self.message(error); return }
        discardingPartialProductID = productID
        defer {
            discardingPartialProductID = nil
            installed.releaseMutation()
        }
        let registry = installed.registryFile
        do {
            // Read-only preflight; the delete itself happens under the shared journal lease.
            let present = try await storageProbe.read { () -> Bool in
                // L1: only an unmounted /Volumes drive keeps the record; otherwise a missing folder means no files.
                if GameStorageVolume.unmountedVolumeRoot(for: destination.path,
                                                         mountedRoots: GameStorageVolume.mountedRoots()) != nil {
                    throw GameInstallLocationError.driveUnavailable
                }
                var parent = stat()
                guard lstat(destination.deletingLastPathComponent().path, &parent) == 0 else {
                    // A denied removable volume (EACCES/EPERM) keeps the record and shows the permission message.
                    if errno == ENOENT || errno == ENOTDIR { return false }
                    throw InstalledGameFiles.folderReadError(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)),
                                                             path: destination.deletingLastPathComponent().path)
                }
                try GameInstallLocation.validateDestination(destination, productID: productID, managedRecord: record)
                return FileManager.default.fileExists(atPath: destination.path)
            }
            // L19-3/REQ-137: recheck the shared journal, stopped-download list and registry and delete under
            // one cross-process lease; anything changed elsewhere or unreadable deletes nothing.
            let found: Bool
            do {
                found = try await journal.discardStopped(record,
                    registeredFolders: { try InstalledGameStore.registeredFolders(file: registry) },
                    delete: {
                        guard present, FileManager.default.fileExists(atPath: destination.path) else { return false }
                        try GameInstallLocation.validateDestination(destination, productID: productID, managedRecord: record)
                        try FileManager.default.removeItem(at: destination)
                        return true
                    })
            } catch GameScriptError.busy {
                resumableInstallations = (try? await journal.loadResumable()) ?? resumableInstallations
                error = Self.discardChangedElsewhereMessage
                return
            }
            resumableInstallations = try await journal.loadResumable()
            notice = found ? "The partial download of \(record.title) was deleted."
                : "No downloaded files were found for \(record.title). Its stopped download was removed from the list."
        } catch {
            resumableInstallations = (try? await journal.loadResumable()) ?? resumableInstallations
            let cocoa = error as NSError
            if error as? GameInstallLocationError == .driveUnavailable {
                self.error = "The drive for \(record.title)'s partial download isn't connected, so nothing was deleted. Reconnect the drive, then try again."
            } else if case .folderPrivacy? = error as? InstalledGameError {
                self.error = "The partial download of \(record.title) wasn't deleted. \((error as? LocalizedError)?.errorDescription ?? "")"
            } else if error as? InstalledGameError == .folderPermission
                || [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(cocoa.code)
                || InstalledGameFiles.folderReadError(cocoa) == .folderPermission
                || (cocoa.userInfo[NSUnderlyingErrorKey] as? NSError).map({ InstalledGameFiles.folderReadError($0) == .folderPermission }) == true {
                self.error = "The partial download couldn't be deleted because \(record.destination) isn't writable. Check its permissions in Finder."
            } else {
                self.error = "The partial download couldn't be deleted. \((error as? LocalizedError)?.errorDescription ?? "The folder couldn't be checked.")"
            }
        }
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

    private func updateResumableInstallation(_ record: GameOperationRecord, completed: Bool) async throws {
        if completed {
            try await journal.removeResumable(record)
        } else if record.kind == .install {
            let exists = try await storageProbe.read {
                do {
                    try InstalledGameFiles.checkFolder(URL(fileURLWithPath: record.destination))
                    return true
                } catch InstalledGameError.missingFolder { return false }
            }
            if exists { try await journal.retainResumable(record) }
        }
        resumableInstallations = try await journal.loadResumable()
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
                notice = record.kind == .repair && launchSupport(productID: record.productID).canPlay
                    ? "\(record.title) is ready to play." : record.kind == .repair ? "\(record.title) was repaired."
                    : "\(record.title) was installed."
                announceReady?(GameReadyAnnouncement(productID: record.productID, title: record.title,
                                                     folder: result.folder))
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
        try await updateResumableInstallation(record, completed: outcome.code == 0)
        try await journal.clear(expectedRunID: record.id)
        operation = nil
        recoveryRequired = false
        recoveryUnreadable = false
        installed.releaseMutation()
        settleRecoveryMutation()
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
        guard admitInstall(productID: record.productID, destination: record.destination,
                           managedOperation: record) else { return .fail(code: 12) }
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
              admitInstall(productID: record.productID, destination: record.destination,
                           managedOperation: record) else { return .fail(code: 12) }
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
        if orphanRunning { await stopOrphanRun(operation); return }
        cancelling = true
        if operation.nativeAccountHash != nil { nativeRunner.cancel(); return }
        await mutationRunner.cancel(runID: operation.id)
    }

    func reconcile() async {
        guard recoveryRequired, let record = operation, !checkingRecovery, mutationTask == nil else { return }
        // Completing a record releases the mutation fence, so only check once this controller holds it.
        guard recoveryMutationOwned else {
            recoveryCheckRequested = true
            error = "Other game activity is still finishing. The last operation will be checked after it ends."
            return
        }
        checkingRecovery = true
        defer { checkingRecovery = false }
        do {
            if let account = record.nativeAccountHash {
                // A backend that outlived the previous app still owns this run; never read its receipt early.
                if await followOrphanIfRunning(record) {
                    error = nil
                    return
                }
                let state = NativeGameLifecycle.directory(runID: record.id)
                // The backend's state folder is created before the child starts; without it nothing ran.
                if try await storageProbe.read({ () -> Bool in
                    try GameScriptFiles.checkPath(state, allowMissing: true)
                    return !FileManager.default.fileExists(atPath: state.path)
                }) {
                    try await updateResumableInstallation(record, completed: false)
                    try await journal.clear(expectedRunID: record.id)
                    operation = nil
                    recoveryRequired = false
                    recoveryUnreadable = false
                    installed.releaseMutation()
                    settleRecoveryMutation()
                    error = nil
                    notice = "The last \(record.kind == .uninstall ? "uninstall" : record.kind == .repair ? "repair" : "installation") of \(record.title) didn't start. Nothing was changed."
                    return
                }
                guard account == nativeAccount else { throw GameScriptError.runtimeUnavailable }
                let result: NativeGameResult
                do {
                    result = try NativeGameLifecycle.readResult(state: state,
                        operation: record.kind.nativeOperation, product: record.productID,
                        gameDirectory: URL(fileURLWithPath: record.destination))
                } catch is InstalledGameError {
                    // The receipt, not the installed games list, couldn't be read.
                    log = state
                    throw GameScriptError.invalidReceipt
                }
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
        } catch {
            self.error = Self.message(error)
            if error as? GameScriptError != .runtimeUnavailable { recoveryUnreadable = true }
        }
    }

    var canDismissRecovery: Bool {
        recoveryRequired && recoveryUnreadable && recoveryMutationOwned && !orphanRunning && !checkingRecovery
            && mutationTask == nil && !terminating
    }

    private func orphanIdentity(_ record: GameOperationRecord) -> NativeOrphanRun.Identity {
        NativeOrphanRun.Identity(operation: record.kind.nativeOperation, product: record.productID,
                                 gameDirectory: record.destination,
                                 stateDirectory: NativeGameLifecycle.directory(runID: record.id).path,
                                 executable: unifiedSession?.nativeLifecycleConfiguration?.executable.path)
    }

    /// Re-attaches to a backend run that outlived a previous app process. Returns true while it runs;
    /// the operation is reconciled automatically once that exact run has finished.
    private func followOrphanIfRunning(_ record: GameOperationRecord) async -> Bool {
        guard record.nativeAccountHash != nil, recoveryRequired, operation?.id == record.id else { return false }
        if orphanRunning { return true }
        let identity = orphanIdentity(record)
        guard case .running(let pid) = await Task.detached(operation: { NativeOrphanRun.status(identity: identity) }).value
        else { return false }
        orphanRunning = true
        orphanPID = pid
        orphanStoppable = pid != nil && record.kind != .uninstall
        recoveryUnreadable = false
        notice = nil
        let state = URL(fileURLWithPath: identity.stateDirectory)
        orphanTask = Task { [weak self] in
            while !Task.isCancelled {
                // Keep following while a quit is pending: a refused quit must not leave the run locked.
                guard let self else { return }
                try? self.nativeRunner.follow(state: state) { [weak self] value in
                    self?.publishProgress(value, runID: record.id)
                }
                let current = await Task.detached { NativeOrphanRun.status(identity: identity) }.value
                if case .running(let pid) = current {
                    if self.orphanPID == nil, let pid {
                        self.orphanPID = pid
                        self.orphanStoppable = record.kind != .uninstall
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                // The lock is released just before the backend exits; let it finish writing its result.
                if let pid = self.orphanPID {
                    for _ in 0..<40 where kill(pid, 0) == 0 || errno == EPERM {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                self.nativeRunner.endFollow()
                self.orphanRunning = false
                self.orphanStoppable = false
                self.orphanPID = nil
                self.orphanTask = nil
                if self.terminating { self.orphanReconcilePending = true }
                else { await self.reconcile() }
                self.cancelling = false
                return
            }
        }
        return true
    }

    private func stopOrphanRun(_ record: GameOperationRecord) async {
        guard orphanRunning, orphanStoppable, let pid = orphanPID, !cancelling else { return }
        cancelling = true
        let identity = orphanIdentity(record)
        let stopped = await Task.detached { NativeOrphanRun.terminate(pid: pid, identity: identity) }.value
        guard !stopped else { return }
        cancelling = false
        orphanStoppable = false
        error = "\(AppBrand.displayName) couldn't confirm which process is running this download, so it wasn't stopped. It will be checked when it finishes."
    }

    /// Explicit user choice to stop waiting on a receipt that can't be read. Nothing is
    /// repeated or deleted; a partial installation folder stays resumable.
    func dismissRecovery() async {
        guard canDismissRecovery else { return }
        let record = operation
        do {
            if let record { try? await updateResumableInstallation(record, completed: false) }
            try await journal.clear(expectedRunID: record?.id)
        } catch {
            self.error = GameScriptError.storage.localizedDescription
            return
        }
        operation = nil
        recoveryRequired = false
        recoveryUnreadable = false
        if recoveryMutationOwned { installed.releaseMutation() }
        settleRecoveryMutation()
        resetFeedback(productID: record?.productID)
        notice = record.map { "The last operation for \($0.title) was dismissed. Check its game folder before trying again." }
            ?? "The last game operation was dismissed. Check your game folders before trying again."
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
    }
    func waitForService() async { await serviceTask?.value }
    func waitForSetup() async {
        while let task = setupTask { await task.value }
    }
    /// UX-B1: an active, stoppable download the user may stop to quit. Uninstalls and commits are never offered.
    var stoppableDownloadForQuit: (title: String, percent: Int?)? {
        guard let operation, operation.kind != .uninstall, canCancel, !recoveryRequired, mutationTask != nil else { return nil }
        return (operation.title, GameDownloadCopy.percent(progress))
    }
    /// Stops the active download and waits for the run to settle so quitting can continue.
    func stopDownloadForQuit() async {
        guard stoppableDownloadForQuit != nil else { return }
        await cancelInstall()
        await mutationTask?.value
    }
    /// UX-M9: only a new install (no Library entry) may delete its partial files after stopping.
    var canStopAndDiscard: Bool {
        guard let operation, canCancel, !orphanRunning, operation.installedID == nil else { return false }
        return operation.kind == .install || operation.kind == .resume
    }
    func stopAndDiscardDownload() async {
        guard canStopAndDiscard, let productID = operation?.productID else { return }
        await cancelInstall()
        await mutationTask?.value
        guard operation == nil, resumableInstallations[productID] != nil else { return }
        await discardPartialDownload(productID: productID)
    }
    func beginTermination() {
        terminating = true
        Task { await cancelPrecheck() }
    }
    func resumeAfterTerminationRefusal() {
        terminating = false
        guard orphanReconcilePending else { return }
        orphanReconcilePending = false
        Task { await reconcile() }
    }
    /// A followed backend run finished while quitting; it's checked if the quit is refused.
    private(set) var orphanReconcilePending = false

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
