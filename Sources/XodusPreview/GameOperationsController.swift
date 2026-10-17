// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation
import XodusManagement

struct GameInstallConsent: Identifiable, Sendable {
    let id = UUID()
    let game: PCGame
    let destination: URL
    let freeBytes: Int64
    let installedID: UUID?
    var compatibility: GameCompatibilityResult?
    var checkError: String?
}

@MainActor
final class GameOperationsController: ObservableObject {
    @Published private(set) var serviceStatus: GameServiceStatus?
    @Published private(set) var serviceBusy = false
    @Published private(set) var serviceSigningIn = false
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
    @Published private(set) var checkingCompatibility = false
    @Published private(set) var installingDirectly = false
    @Published private(set) var compatibility: [String: GameCompatibilityResult] = [:]
    @Published private(set) var compatibilityErrors: [String: String] = [:]
    @Published private(set) var operation: GameOperationRecord?
    @Published private(set) var progress: GameScriptProgress?
    @Published private(set) var cancelling = false
    @Published private(set) var checkingRecovery = false
    @Published private(set) var recoveryRequired = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var log: URL?
    @Published private(set) var failureCode: Int?
    private let installed: InstalledGamesController
    private let paths: GameScriptPaths
    private let mutationRunner: GameScriptRunner
    private let serviceRunner: GameScriptRunner
    private let setupRunner: GameScriptRunner
    private let journal: GameOperationJournal
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
        !serviceBusy && !isBusy && !recoveryRequired && !installed.mutationActive
            && installed.runningGameID == nil && !terminating
    }
    var canStartMutation: Bool {
        !isBusy && !recoveryRequired && !installed.mutationActive && !serviceSigningIn && !preparingConsent && installed.loaded
            && !installed.editing && !installed.choosing && !terminating
    }
    var canQuit: Bool {
        !installingDirectly && !preparingConsent
            && mutationTask == nil && compatibilityTask == nil && gamePassTask == nil && stopTask == nil
            && setupTask == nil && !serviceSigningIn
    }
    var canConfirmInstall: Bool {
        canStartMutation && installConsent?.compatibility?.supported == true
    }
    var canCancel: Bool {
        operation != nil && operation?.kind != .uninstall && !recoveryRequired && !cancelling
    }
    var serviceLabel: String {
        if serviceAccountNeedsVerification { return "Game sign-in saved; account not verified" }
        return serviceStatus?.signedIn == true ? "Signed in for games"
            : serviceStatus == nil ? "Game sign-in hasn't been checked" : "Sign in for games"
    }
    var serviceAccountNeedsVerification: Bool {
        serviceStatus?.signedIn == true && serviceStatus?.accountHash == nil
    }
    var serviceSignInActionTitle: String? {
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
        canStartMutation && !serviceBusy && installed.runningGameID == nil
            && installConsent == nil && uninstallConsent == nil
    }
    var gamePassLabel: String {
        if gamePassFromCache { return "PC Game Pass: Saved status - check required" }
        if gamePassBusy || gamePassError != nil { return "PC Game Pass: Unknown" }
        return gamePassStatus?.active == true ? "PC Game Pass: Active"
            : gamePassStatus?.active == false ? "PC Game Pass: Not active" : "PC Game Pass: Unknown"
    }

    init(installed: InstalledGamesController, paths: GameScriptPaths = .production) {
        self.installed = installed
        self.paths = paths
        mutationRunner = GameScriptRunner(paths: paths)
        serviceRunner = GameScriptRunner(paths: paths)
        setupRunner = GameScriptRunner(paths: paths)
        precheckRunner = GameScriptRunner(paths: paths)
        journal = GameOperationJournal(file: paths.journal)
        installedObservation = installed.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func restore() async {
        guard !restored, !isBusy, !terminating else { return }
        restored = true
        do {
            guard let record = try await journal.load() else { return }
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
        guard !serviceBusy, !gamePassBusy, !setupRepairing, !terminating else { return }
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

    func signInForGames() {
        guard canSignIn else { return }
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
            defer {
                serviceBusy = false
                serviceSigningIn = false
                installed.serviceSignInActive = false
                serviceTask = nil
            }
            do {
                let signedIn = try await serviceRunner.run(command: .serviceSignIn, runID: runID)
                guard signedIn.code == 0 else { throw GameScriptError.failed(signedIn.code) }
                let status = try await serviceRunner.run(command: .serviceStatus, runID: InstalledGamesController.runID())
                guard status.code == 0, let data = status.result else { throw GameScriptError.invalidReceipt }
                let value = try GameServiceStatus.parse(data)
                guard value.signedIn else { throw GameScriptError.failed(11) }
                serviceStatus = value
                if setupCheckedOnce { refreshSetup() }
            } catch {
                serviceStatus = nil
                serviceError = Self.message(error)
                serviceLog = await scriptLog(runID)
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
                gamePassError = Self.message(error)
                gamePassLog = await scriptLog(runID)
            }
        }
    }

    func stop(_ game: InstalledGame) {
        guard canStartMutation, installConsent == nil, uninstallConsent == nil else { return }
        let token: UUID
        do { token = try installed.reserveStop(game) }
        catch { self.error = Self.message(error); return }
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
        guard !setupCheckedOnce, !terminating else { return }
        setupCheckedOnce = true
        refreshSetup()
    }

    private func refreshSetup() {
        guard !terminating else { return }
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
                guard outcome.code == 0, let data = outcome.result else { throw GameScriptError.failed(outcome.code) }
                setupResult = try GameSetupResult.parse(data)
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
                guard outcome.code == 0, let data = outcome.result else { throw GameScriptError.failed(outcome.code) }
                setupResult = try GameSetupResult.parse(data)
                await installed.refreshAfterSetupRepair()
            } catch {
                setupResult = nil
                setupError = Self.message(error)
                setupLog = await scriptLog(runID)
            }
        }
    }

    func install(_ game: PCGame) async {
        guard canStartMutation, !installingDirectly else { return }
        installingDirectly = true
        directInstallCancelled = false
        defer { installingDirectly = false }
        await prepareInstall(game)
        guard !directInstallCancelled else { installConsent = nil; return }
        guard let consent = installConsent else { return }
        if consent.compatibility?.supported == true {
            confirmInstall(consent)
        } else {
            error = consent.checkError ?? consent.compatibility?.explanation
                ?? "This game couldn't be installed. Try again."
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

    func prepareInstall(_ game: PCGame, repairing: InstalledGame? = nil) async {
        await cancelPrecheck()
        guard canStartMutation, PCGamesClient.validProductID(game.id) else { return }
        if let repairing {
            guard repairing.storeId == game.id, installed.games.contains(repairing),
                  installed.runningGameID != repairing.id else { return }
        }
        preparingConsent = true
        defer { preparingConsent = false }
        do {
            let destination = try repairing.map { URL(fileURLWithPath: $0.folder, isDirectory: true) }
                ?? paths.destination(title: game.title, productID: game.id)
            let free = try await Task.detached { try GameScriptFiles.availableSpace(for: destination) }.value
            guard !terminating, !isBusy, !(installingDirectly && directInstallCancelled) else { return }
            if repairing == nil, installed.games.contains(where: { $0.folder == destination.path }) {
                throw GameScriptError.invalidDestination
            }
            installConsent = GameInstallConsent(game: game, destination: destination,
                                                freeBytes: free, installedID: repairing?.id)
            error = nil
            preparingConsent = false
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
        } catch { self.error = Self.message(error) }
    }

    func confirmInstall(_ consent: GameInstallConsent) {
        guard installConsent?.id == consent.id, canConfirmInstall, !recoveryRequired,
              consent.compatibility?.supported == true else { return }
        installConsent = nil
        let record = GameOperationRecord(id: InstalledGamesController.runID(),
            kind: consent.installedID == nil ? .install : .repair, productID: consent.game.id,
            title: consent.game.title, destination: consent.destination.path, installedID: consent.installedID)
        if let id = consent.installedID,
           !installed.games.contains(where: { $0.id == id && $0.storeId == record.productID && $0.folder == record.destination }) {
            error = "This game's installed entry changed. Choose it again."
            return
        }
        if consent.installedID == nil, installed.games.contains(where: { $0.folder == record.destination }) {
            error = GameScriptError.invalidDestination.localizedDescription
            return
        }
        begin(record)
    }

    func cancelInstallConsent() async {
        if installingDirectly { directInstallCancelled = true }
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
        guard canStartMutation, !recoveryRequired, installed.games.contains(game),
              installed.runningGameID != game.id else { return }
        uninstallConsent = game
    }

    func confirmUninstall(_ game: InstalledGame) {
        guard uninstallConsent?.id == game.id, canStartMutation, !recoveryRequired,
              installed.games.contains(game), installed.runningGameID != game.id else { return }
        uninstallConsent = nil
        begin(GameOperationRecord(id: InstalledGamesController.runID(), kind: .uninstall,
            productID: game.storeId, title: game.title, destination: game.folder, installedID: game.id))
    }

    private func begin(_ record: GameOperationRecord) {
        do { try installed.reserveMutation(gameID: record.installedID) }
        catch { self.error = Self.message(error); return }
        operation = record
        progress = nil
        notice = nil
        error = nil
        log = nil
        failureCode = nil
        mutationTask = Task {
            do {
                try await journal.save(record)
                await cancelPrecheck()
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
                log = await scriptLog(record.id)
                if let scriptError = error as? GameScriptError,
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
            failureCode = outcome.code
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
        guard record.kind == .install, (try? record.validate()) != nil else { return .fail(code: -1) }
        while !canStartMutation || operation != nil || mutationTask != nil {
            if terminating { return .fail(code: -1) }
            if abandonedQueuedRuns.remove(record.id) != nil { return .cancel }
            try? await Task.sleep(for: .milliseconds(30))
        }
        // A stop/cancel may have landed during the final wait iteration.
        if abandonedQueuedRuns.remove(record.id) != nil { return .cancel }
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
        await mutationRunner.cancel(runID: runID)
    }

    func cancelInstall() async {
        guard canCancel, let operation else { return }
        cancelling = true
        await mutationRunner.cancel(runID: operation.id)
    }

    func reconcile() async {
        guard recoveryRequired, let record = operation, !checkingRecovery, mutationTask == nil else { return }
        checkingRecovery = true
        defer { checkingRecovery = false }
        do {
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
        if let typed = error as? GameScriptError { return typed.localizedDescription }
        if let typed = error as? InstalledGameError { return typed.localizedDescription }
        return GameScriptError.invalidReceipt.localizedDescription
    }
}
