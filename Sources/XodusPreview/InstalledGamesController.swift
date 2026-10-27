// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation
import OSLog
import XodusCore
import XodusManagement

enum InstalledGamePlayState: Equatable {
    case launching, playing
}

@MainActor
final class InstalledGamesController: ObservableObject {
    private static let launchLog = Logger(subsystem: "io.github.dragoshont.xodus", category: "GameLaunch")
    let productAccess = InstalledProductAccess()
    private var productAccessObservation: AnyCancellable?
    @Published private(set) var games: [InstalledGame] = []
    @Published private(set) var loading = false
    @Published private(set) var editing = false
    @Published private(set) var choosing = false
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    /// Set only when the installed-games registry itself couldn't be read, unlike `error`, which other work shares.
    @Published private(set) var loadError: String?
    @Published private(set) var discoveryError: String?
    @Published private(set) var runningGameID: UUID?
    @Published private(set) var playState: InstalledGamePlayState?
    @Published private(set) var playErrors: [UUID: String] = [:]
    @Published private(set) var engineIssueMessages: [UUID: String] = [:]
    @Published private(set) var historyError: String?
    @Published private(set) var packageErrors: [UUID: String] = [:]
    @Published private(set) var checkingInstallations = Set<UUID>()
    static let inFlightCheckWait: Duration = .seconds(120)

    /// 681 deep-link race: Play waits (bounded) for an installation check already running for this game
    /// rather than refusing as "not verified complete". True when no check is left running.
    @discardableResult
    func awaitInFlightCheck(_ game: InstalledGame, timeout: Duration = inFlightCheckWait) async -> Bool {
        guard checkingInstallations.contains(game.id) else { return true }
        return await Self.waitUntil(timeout: timeout) { !checkingInstallations.contains(game.id) }
    }
    @Published private(set) var installationStatuses: [UUID: NativeInstallationStatus] = [:]
    /// fc2f17d1 H1: a launch's installation verdict (Repair or Remove) until the next installation check.
    @Published private(set) var launchVerdicts: [UUID: NativeInstallationStatus.Action] = [:]
    @Published private(set) var installationErrors: [UUID: String] = [:]
    @Published private(set) var playLogs: [UUID: URL] = [:]
    @Published private(set) var playNotices: [UUID: String] = [:]
    @Published private(set) var stoppingGameID: UUID?
    @Published private(set) var launchStarted = false
    @Published private(set) var launchableIDs: Set<UUID> = []
    @Published private(set) var placeholderIDs: Set<UUID> = []
    @Published private(set) var unavailableDriveIDs: Set<UUID> = []
    @Published private(set) var availableEngineOverrides: [AdmittedEngineSelection] = []
    @Published private(set) var checkingEngineOverrides = false
    private var engineOverrideWaiters: [CheckedContinuation<Void, Never>] = []
    private var engineOverridesChecked = false
    @Published private(set) var failedEngineOverrides: Set<String> = []
    @Published private(set) var undiscoveredInstallations: [String: String] = [:]
    private var mountedDiscoveryProbes: [String: GameStorageProbe] = [:]
    @Published private(set) var pendingDiscoveryRoots: Set<String> = []
    @Published private(set) var discoveringMounts = false
    @Published private(set) var mutationGameID: UUID?
    @Published private(set) var mutationActive = false
    /// Per-game update availability, recomputed from installed versions vs. `availableVersions`.
    @Published private(set) var updateStatuses: [UUID: UpdateStatus] = [:]
    /// Available package versions keyed by store id. Integration point for the catalog /
    /// package-type + engine-routing workstream (M1/M3); set via `applyAvailableVersions`.
    @Published private(set) var availableVersions: [String: String] = [:]
    @Published var serviceSignInActive = false
    @Published var runtimeRepairActive = false
    @Published var accountDisconnecting = false {
        didSet {
            if accountDisconnecting {
                nativePreparationTask?.cancel()
                for task in discoveryTasks.values { task.cancel() }
                for task in automaticDiscoveryTasks.values { task.cancel() }
                for task in installationCheckTasks.values { task.cancel() }
            }
        }
    }
    @Published private(set) var accountAccessAllowed = false
    @Published private(set) var accountAccessMessage = "Reconnect Xbox services to play this game."
    var applicationTerminating = false {
        didSet {
            if applicationTerminating {
                nativePreparationTask?.cancel()
                productAccess.retire()
                foregroundHandoff?.cancel()
                for task in nativeInspectionTasks.values { task.cancel() }
                for task in discoveryTasks.values { task.cancel() }
                for task in automaticDiscoveryTasks.values { task.cancel() }
                for task in installationCheckTasks.values { task.cancel() }
            }
        }
    }
    private let store: InstalledGameStore
    private let launchingDuration: Duration
    private let defaultEngine: @Sendable () -> RuntimeProviderKind?
    private let detectAvailability: @Sendable () async -> RunnerAvailability
    private let inspectPackage: @Sendable (URL) throws -> PackageType
    private let mountedStorageRoots: @Sendable () -> [String]?
    /// Home whose `Mounts` folder holds network library mountpoints.
    private let mountHome: String
    private let discoveryProbe = GameStorageProbe()
    private var candidateVerificationProbes: [String: GameStorageProbe] = [:]
    private var installationVolumeProbes: [UUID: GameStorageProbe] = [:]
    private var gameReadinessProbes: [UUID: GameStorageProbe] = [:]
    @Published private(set) var discoveringInstallations = false
    @Published private(set) var verifyingDiscoveredProducts: Set<String> = []
    @Published private(set) var discoveredVerificationErrors: [String: String] = [:]
    private var discoveredCandidates: [String: GameInstallationDiscovery.Candidate] = [:]
    private var discoveryTasks: [String: Task<Void, Never>] = [:]
    @Published private(set) var automaticDiscoveryProducts: Set<String> = []
    private var automaticDiscoveryTasks: [String: Task<Void, Never>] = [:]
    private var automaticDiscoveryAttempts: [String: String] = [:]
    private let discoveryRoot: URL
    private let installLocation: @Sendable () throws -> GameInstallLocation?
    private let discoveryCompleteness: (@MainActor (String, URL) async throws -> Bool)?
    private let compatibilityCatalogue: OfflineGameCompatibility?
    private weak var unifiedSession: LiveSession?
    #if !XODUS_SHIPPING
    /// Checks only: a synthetic install-status CLI in place of the connected service.
    var installStatusConfigurationForChecks: BackendConfiguration?
    #endif
    private var installStatusConfiguration: BackendConfiguration? {
        #if !XODUS_SHIPPING
        if let installStatusConfigurationForChecks { return installStatusConfigurationForChecks }
        #endif
        return unifiedSession?.nativeInstallStatusConfiguration
    }
    private var usesUnifiedAccount = false
    private var launchSupportCache: [String: (NativeLaunchSupport, ContinuousClock.Instant)] = [:]
    private let nativeLauncher = NativeGameLifecycle()
    private var nativeLaunchTask: Task<Void, Never>?
    private var nativePreparationTask: Task<MicrosoftGameConfig, Error>?
    private var nativeForegroundTask: Task<Void, Never>?
    private var nativeInspectionTasks: [UUID: Task<NativeInstallationStatus, Error>] = [:]
    private var installationCheckTasks: [UUID: Task<Void, Never>] = [:]
    private var nativeInspectionDates: [UUID: ContinuousClock.Instant] = [:]
    private var automaticReadinessAttempts: [UUID: String] = [:]
    private var playingTask: Task<Void, Never>?
    private var runToken: UUID?
    private var stopToken: UUID?
    private var refreshingReadiness = false
    private var readinessRefreshRequested = false
    private var stopConfirmed = false
    private var process: Process?
    private var sessionPersistence: Task<Void, Never>?
    private var runIDs: [UUID: String] = [:]
    private let logDirectory: URL
    private var foregroundHandoff: LaunchAssociationHandoff?
    private var foregroundCleanup: Task<Bool, Never>?

    var continuingGame: InstalledGame? {
        games.filter { $0.lastPlayedAt != nil && launchableIDs.contains($0.id) }
            .max {
                if $0.lastPlayedAt == $1.lastPlayedAt { return $0.id.uuidString < $1.id.uuidString }
                return ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast)
            }
    }
    init(store: InstalledGameStore = InstalledGameStore(), launchingDuration: Duration = .seconds(5),
         logDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/XodusRemote"),
         defaultEngine: @escaping @Sendable () -> RuntimeProviderKind? = { EngineDefaults.defaultEngine() },
         detectAvailability: @escaping @Sendable () async -> RunnerAvailability = {
             await Task.detached(priority: .utility) { RunnerAvailabilityDetector.detect() }.value
         },
         inspectPackage: @escaping @Sendable (URL) throws -> PackageType = { try PackageInspector.detect(folder: $0) },
         compatibilityCatalogue: OfflineGameCompatibility? = OfflineGameCompatibility.snapshot,
         mountedStorageRoots: @escaping @Sendable () -> [String]? = { GameStorageVolume.mountedRoots() },
         discoveryRoot: URL = GameScriptPaths.production.games,
         installLocation: @escaping @Sendable () throws -> GameInstallLocation? = {
             try GameInstallLocation.load(.standard)
         },
         discoveryCompleteness: (@MainActor (String, URL) async throws -> Bool)? = nil,
         mountHome: String = NSHomeDirectory()) {
        self.mountHome = mountHome
        self.store = store
        self.launchingDuration = launchingDuration
        self.logDirectory = logDirectory
        self.defaultEngine = defaultEngine
        self.detectAvailability = detectAvailability
        self.inspectPackage = inspectPackage
        self.compatibilityCatalogue = compatibilityCatalogue
        self.discoveryRoot = discoveryRoot
        self.installLocation = installLocation
        self.discoveryCompleteness = discoveryCompleteness
        self.mountedStorageRoots = mountedStorageRoots
    }

    func load() async {
        guard !loading, !editing, !choosing, !loaded, !applicationTerminating else { return }
        loading = true
        defer { loading = false }
        do {
            games = try await store.load()
            loaded = true
            error = nil
            loadError = nil
            await refreshLaunchableGames()
        } catch {
            self.error = InstalledGameError.invalidRegistry.localizedDescription
            loadError = self.error
        }
    }

    func importGame(folder: URL, launcher: URL) async {
        guard loaded, !editing, !mutationActive, !accountDisconnecting, !applicationTerminating else { return }
        editing = true
        defer { editing = false }
        do {
            try await saveValidatedGame(folder: folder, launcher: launcher, expectedStoreID: nil)
            error = nil
        } catch {
            self.error = (error as? InstalledGameError)?.localizedDescription
                ?? (error as? GameScriptError)?.localizedDescription
                ?? InstalledGameError.storage.localizedDescription
        }
    }

    func chooseGame() async {
        guard loaded, !editing, !choosing, !mutationActive, !accountDisconnecting, !applicationTerminating else { return }
        choosing = true
        defer { choosing = false }
        let folderPanel = NSOpenPanel()
        folderPanel.title = "Import installed Xbox game"
        folderPanel.prompt = "Choose game folder"
        folderPanel.message = PermissionPrompt.fileSelectionMessage
        folderPanel.canChooseDirectories = true
        folderPanel.canChooseFiles = false
        folderPanel.allowsMultipleSelection = false
        guard await folderPanel.begin() == .OK, let folder = folderPanel.url else { return }
        do {
            _ = try await Task.detached(priority: .userInitiated) { try MicrosoftGameConfig.read(folder: folder) }.value
        } catch {
            self.error = InstalledGameError.invalidConfig.localizedDescription
            return
        }
        if usesUnifiedAccount {
            editing = true
            defer { editing = false }
            do {
                try await saveValidatedGame(folder: folder, launcher: nil, expectedStoreID: nil)
                error = nil
            } catch {
                self.error = (error as? InstalledGameError)?.localizedDescription
                    ?? (error as? GameScriptError)?.localizedDescription
                    ?? InstalledGameError.storage.localizedDescription
            }
            return
        }
        let scriptPanel = NSOpenPanel()
        scriptPanel.title = "Choose the launch script for this game"
        scriptPanel.message = "Use the launch script you already use for this game."
        scriptPanel.prompt = "Choose launch script"
        scriptPanel.canChooseDirectories = false
        scriptPanel.canChooseFiles = true
        scriptPanel.allowsMultipleSelection = false
        guard await scriptPanel.begin() == .OK, let launcher = scriptPanel.url else { return }
        await importGame(folder: folder, launcher: launcher)
    }

    func discoverNativeInstallations(root: URL? = nil) async {
        guard (usesUnifiedAccount || discoveryCompleteness != nil), loaded, !discoveringInstallations, !editing, !choosing, !mutationActive,
              !accountDisconnecting, !applicationTerminating else { return }
        discoveringInstallations = true
        defer { discoveringInstallations = false }
        let entries = games
        let directory = root ?? discoveryRoot
        let installLocation = installLocation
        let mountedStorageRoots = mountedStorageRoots
        let inspectPackage: @Sendable (URL) throws -> PackageType
        if discoveryCompleteness == nil { inspectPackage = { @Sendable _ in .unknown } }
        else { inspectPackage = self.inspectPackage }
        let account = unifiedSession?.accountHash
        pendingDiscoveryRoots.formUnion(mountedDiscoveryProbes.keys)
        discoveringMounts = true
        do {
            let volumes = try await discoveryProbe.read(timeout: .seconds(3)) {
                mountedStorageRoots()
            }
            discoveringMounts = false
            if let volumes {
                let mounted = Set(Self.mountedDiscoveryRoots(volumes, home: mountHome).map(\.path))
                pendingDiscoveryRoots.formIntersection(mounted)
                if root == nil { pendingDiscoveryRoots.formUnion(mounted) }
                undiscoveredInstallations = Self.retainingMountedCandidates(undiscoveredInstallations, volumes: volumes,
                                                                            home: mountHome)
            }
            var observation = try await discoveryProbe.read {
                try GameInstallationDiscovery.scan(originalRoot: directory,
                    location: root == nil ? installLocation() : nil, entries: entries,
                    mountedRoots: volumes, inspectPackage: inspectPackage)
            }
            pendingDiscoveryRoots.subtract(observation.scannedRoots)
            if root == nil {
                for library in Self.mountedDiscoveryRoots(volumes, home: mountHome) {
                    try Task.checkCancellation()
                    guard loaded, !accountDisconnecting, !applicationTerminating,
                          unifiedSession?.accountHash == account else { return }
                    guard !observation.scannedRoots.contains(library.path) else { continue }
                    let remaining = 512 - observation.childrenRead
                    guard remaining > 0 else {
                        observation.errors.append(InstalledGameError.invalidRegistry.localizedDescription)
                        break
                    }
                    let probe: GameStorageProbe
                    if let existing = mountedDiscoveryProbes[library.path] { probe = existing }
                    else {
                        guard mountedDiscoveryProbes.count < 32 else {
                            pendingDiscoveryRoots.insert(library.path)
                            observation.errors.append(GameStorageProbeError.pending.localizedDescription)
                            continue
                        }
                        probe = GameStorageProbe()
                        mountedDiscoveryProbes[library.path] = probe
                    }
                    pendingDiscoveryRoots.insert(library.path)
                    do {
                        let mounted = try await probe.read(timeout: .seconds(3)) {
                            try GameInstallationDiscovery.scan(originalRoot: library, location: nil, entries: entries,
                                mountedRoots: volumes, includeRecordedRoots: false,
                                maximumChildren: remaining, inspectPackage: inspectPackage)
                        }
                        observation.candidates += mounted.candidates
                        observation.errors += mounted.errors
                        observation.scannedRoots.formUnion(mounted.scannedRoots)
                        observation.childrenRead += mounted.childrenRead
                        observation.identifiedInstallations.merge(mounted.identifiedInstallations) { _, current in current }
                        pendingDiscoveryRoots.remove(library.path)
                    } catch is CancellationError { throw CancellationError() }
                    catch { observation.errors.append("\(library.path): \(error.localizedDescription)") }
                }
            }
            try Task.checkCancellation()
            guard !accountDisconnecting, !applicationTerminating,
                  unifiedSession?.accountHash == account else { return }
            undiscoveredInstallations = undiscoveredInstallations.filter { folder, _ in
                !observation.scannedRoots.contains(URL(fileURLWithPath: folder).deletingLastPathComponent().path)
                    || observation.errors.contains(where: { $0.hasPrefix(folder + ": ") })
            }
            undiscoveredInstallations.merge(observation.identifiedInstallations) { _, current in current }
            for candidate in observation.candidates { discoveredCandidates[candidate.folder.path] = candidate }
            var failures = observation.errors
            var seenCandidates = Set<String>()
            for candidate in observation.candidates where seenCandidates.insert(candidate.folder.path).inserted {
                guard discoveryCompleteness != nil else { continue }
                try Task.checkCancellation()
                guard !choosing, !mutationActive, !accountDisconnecting, !applicationTerminating,
                      unifiedSession?.accountHash == account else { return }
                do {
                    let complete: Bool
                    if let discoveryCompleteness {
                        complete = try await discoveryCompleteness(candidate.config.storeId, candidate.folder)
                    } else {
                        guard let configuration = installStatusConfiguration else {
                            throw GameInstallationDiscoveryError.serviceUnavailable
                        }
                        let status = try await NativeInstallationQuery().run(configuration: configuration,
                            product: candidate.config.storeId, gameDirectory: candidate.folder,
                            storageProbe: discoveryProbe)
                        guard status.success else {
                            throw GameInstallationDiscoveryError.inspectionFailed(
                                status.explanation ?? "The installation couldn't be checked. Try again.")
                        }
                        complete = status.status == .complete
                    }
                    guard complete else {
                        failures.append("\(candidate.folder.path): Installation is incomplete. Finish or repair it before importing.")
                        continue
                    }
                    let confirmedConfig = try await discoveryProbe.read {
                        try GameScriptFiles.checkPath(candidate.folder)
                        return try MicrosoftGameConfig.read(folder: candidate.folder)
                    }
                    guard confirmedConfig == candidate.config else {
                        throw GameInstallationDiscoveryError.identityChanged
                    }
                    try Task.checkCancellation()
                    guard !accountDisconnecting, !applicationTerminating, unifiedSession?.accountHash == account,
                          !games.contains(where: { $0.folder == candidate.folder.path }) else { return }
                    let config = candidate.config
                    let game = InstalledGame(id: UUID(), title: config.title, identityName: config.identityName,
                        version: config.version, storeId: config.storeId, folder: candidate.folder.path,
                        launcher: "", importedAt: Date(), publisher: config.publisher, packageType: candidate.package,
                        usesNativeLifecycle: true, storageVolume: candidate.volume)
                    applySavedGames(try await store.upsert(game))
                    undiscoveredInstallations[candidate.folder.path] = nil
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("\(candidate.folder.path): \(error.localizedDescription)") }
            }
            for failure in failures {
                Self.launchLog.debug("Automatic discovery skipped: \(failure, privacy: .private)")
            }
            discoveryError = nil
        } catch is CancellationError {
            Self.launchLog.debug("Automatic discovery cancelled; existing entries retained.")
        } catch {
            Self.launchLog.error("Automatic discovery unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func discoveredReadinessKey(productID: String) -> String {
        let paths = undiscoveredInstallations.filter { $0.value == productID }.keys.sorted().joined(separator: "|")
        return "\(productID):\(paths):\(unifiedSession?.accountHash ?? ""):\(discoveryCompleteness != nil || installStatusConfiguration != nil)"
    }

    func automaticallyVerifyDiscoveredInstallation(productID: String) async {
        let key = discoveredReadinessKey(productID: productID)
        if let pending = automaticDiscoveryTasks[productID] { await pending.value }
        guard !Task.isCancelled else { return }
        guard automaticDiscoveryAttempts[productID] != key else { return }
        automaticDiscoveryAttempts[productID] = key
        automaticDiscoveryProducts.insert(productID)
        let task = Task { @MainActor in
            defer {
                automaticDiscoveryProducts.remove(productID)
                automaticDiscoveryTasks[productID] = nil
            }
            do {
                let deadline = ContinuousClock.now.advanced(by: NativeInstallationQuery.largeInstallTimeout)
                while Set(discoveryTasks.keys).union(candidateVerificationProbes.filter { $0.value.active }.keys).count >= 2 {
                    guard ContinuousClock.now < deadline else { throw GameScriptError.timeout }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard loaded, !applicationTerminating, !accountDisconnecting,
                      discoveredReadinessKey(productID: productID) == key else { return }
                await verifyDiscoveredInstallation(productID: productID)
            } catch is CancellationError {
                discoveredVerificationErrors[productID] = "Installation verification was cancelled. Retry when you're ready."
            } catch {
                discoveredVerificationErrors[productID] = error.localizedDescription
            }
        }
        automaticDiscoveryTasks[productID] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func verifyDiscoveredInstallation(productID: String) async {
        if let pending = discoveryTasks[productID] { await pending.value; return }
        discoveredVerificationErrors[productID] = nil
        let candidates = discoveredCandidates.values.filter {
            $0.config.storeId == productID && undiscoveredInstallations[$0.folder.path] == productID
        }
        guard candidates.count <= 1 else {
            discoveredVerificationErrors[productID] = "Multiple installation folders match this game. Import the exact folder you want to use."
            return
        }
        guard !verifyingDiscoveredProducts.contains(productID),
              Set(discoveryTasks.keys).union(candidateVerificationProbes.filter { $0.value.active }.keys).count < 2,
              !accountDisconnecting, !applicationTerminating,
              let candidate = candidates.first else {
            discoveredVerificationErrors[productID] = "The game location couldn't be verified. Check its location or drive access, then retry."
            return
        }
        let account = unifiedSession?.accountHash
        verifyingDiscoveredProducts.insert(productID)
        let task = Task { @MainActor in
            defer {
                verifyingDiscoveredProducts.remove(productID)
                discoveryTasks[productID] = nil
            }
            do {
                let probe = candidateVerificationProbes[productID] ?? GameStorageProbe()
                candidateVerificationProbes[productID] = probe
                let complete: Bool
                var verifiedStatus: NativeInstallationStatus?
                if let discoveryCompleteness {
                    complete = try await discoveryCompleteness(productID, candidate.folder)
                } else {
                    guard let configuration = installStatusConfiguration else {
                        throw GameInstallationDiscoveryError.serviceUnavailable
                    }
                    let status = try await NativeInstallationQuery().run(configuration: configuration,
                        product: productID, gameDirectory: candidate.folder, timeout: NativeInstallationQuery.largeInstallTimeout,
                        storageProbe: probe)
                    guard status.success else {
                        throw GameInstallationDiscoveryError.inspectionFailed(
                            status.explanation ?? "The installation couldn't be checked. Try again.")
                    }
                    complete = status.status == .complete
                    verifiedStatus = status
                }
                guard complete else {
                    throw GameInstallationDiscoveryError.inspectionFailed(
                        "Installation is incomplete. Finish or repair it before importing.")
                }
                let inspect = inspectPackage
                let facts = try await probe.read {
                    try GameScriptFiles.checkPath(candidate.folder)
                    return (try MicrosoftGameConfig.read(folder: candidate.folder),
                            try inspect(candidate.folder), GameStorageVolume.read(at: candidate.folder))
                }
                guard facts.0 == candidate.config, let volume = facts.2 else {
                    throw GameInstallationDiscoveryError.identityChanged
                }
                try Task.checkCancellation()
                guard loaded, !accountDisconnecting, !applicationTerminating, !mutationActive, !editing,
                      unifiedSession?.accountHash == account else { throw GameScriptError.busy }
                if games.contains(where: { $0.folder == candidate.folder.path }) {
                    undiscoveredInstallations[candidate.folder.path] = nil
                    return
                }
                let config = facts.0
                let game = InstalledGame(id: UUID(), title: config.title, identityName: config.identityName,
                    version: config.version, storeId: config.storeId, folder: candidate.folder.path,
                    launcher: "", importedAt: Date(), publisher: config.publisher, packageType: facts.1,
                    usesNativeLifecycle: true, storageVolume: volume)
                applySavedGames(try await store.upsert(game))
                if let verifiedStatus { try recordInstallationStatus(verifiedStatus, for: game) }
                undiscoveredInstallations[candidate.folder.path] = nil
                discoveredVerificationErrors[productID] = nil
            } catch is CancellationError {
                Self.launchLog.debug("Product installation check cancelled.")
                discoveredVerificationErrors[productID] = "Installation verification was cancelled. Retry when you're ready."
            } catch {
                Self.launchLog.error("Product installation check failed: \(error.localizedDescription, privacy: .private)")
                if let failure = error as? GameInstallationDiscoveryError {
                    discoveredVerificationErrors[productID] = failure.localizedDescription
                } else if let failure = error as? GameScriptError, case .timeout = failure {
                    discoveredVerificationErrors[productID] = NativeInstallationQuery.failureMessage(error)
                } else {
                    discoveredVerificationErrors[productID] = "The installation couldn't be checked. Try again."
                }
            }
        }
        discoveryTasks[productID] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelDiscoveredVerification(productID: String) {
        automaticDiscoveryTasks[productID]?.cancel()
        discoveryTasks[productID]?.cancel()
    }

    func hasUnverifiedInstallation(productID: String) -> Bool {
        undiscoveredInstallations.values.contains(productID)
    }

    func canCreateInstallation(productID: String, destination: String? = nil,
                               resumingManagedOperation: Bool = false) -> Bool {
        (!discoveringMounts || destination != nil)
            && Self.permitsInstallation(productID: productID, destination: destination,
                candidates: undiscoveredInstallations, pendingRoots: pendingDiscoveryRoots,
                resumingManagedOperation: resumingManagedOperation)
            && !games.contains { $0.storeId == productID }
    }

    static func permitsInstallation(productID: String, destination: String?, candidates: [String: String],
                                    pendingRoots: Set<String>, resumingManagedOperation: Bool = false) -> Bool {
        let pendingDestination = pendingRoots.contains { root in
            guard let destination else { return true }
            return destination == root || destination.hasPrefix(root + "/")
        }
        return !pendingDestination && !candidates.contains {
            $0.value == productID && (!resumingManagedOperation || $0.key != destination)
        }
    }

    static func retainingMountedCandidates(_ candidates: [String: String], volumes: [String],
                                          home: String = NSHomeDirectory()) -> [String: String] {
        let mounted = Set(mountedDiscoveryRoots(volumes, home: home).map(\.path))
        return candidates.filter { folder, _ in
            let parent = URL(fileURLWithPath: folder).deletingLastPathComponent()
            let possible = mountedDiscoveryRoots(
                [parent.deletingLastPathComponent().path], home: home).map(\.path)
            return !possible.contains(parent.path) || mounted.contains(parent.path)
        }
    }

    static func mountedDiscoveryRoots(_ volumes: [String]?, home: String = NSHomeDirectory()) -> [URL] {
        var roots = Set(GameInstallationDiscovery.mountedLibraryRoots(volumes, home: home).map(\.path))
        let mountDirectory = URL(fileURLWithPath: home).appendingPathComponent("Mounts").standardizedFileURL.path
        for path in volumes ?? [] {
            let volume = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard volume.path == path,
                  (path.hasPrefix(mountDirectory + "/") || path.hasPrefix("/Volumes/")),
                  ["Xode", "Xodus"].contains(volume.lastPathComponent) else { continue }
            roots.insert(path)
        }
        return roots.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func remove(_ game: InstalledGame) async {
        guard loaded, !editing, !choosing, !mutationActive, !accountDisconnecting, !applicationTerminating, runningGameID != game.id else { return }
        editing = true
        defer { editing = false }
        do {
            let updated = try await store.remove(id: game.id)
            applySavedGames(updated)
            launchableIDs.remove(game.id)
            placeholderIDs.remove(game.id)
            playErrors[game.id] = nil
            playLogs[game.id] = nil
            runIDs[game.id] = nil
            nativeInspectionTasks[game.id]?.cancel()
            launchVerdicts[game.id] = nil
            installationStatuses[game.id] = nil
            installationErrors[game.id] = nil
            nativeInspectionDates[game.id] = nil
            error = nil
        } catch { self.error = InstalledGameError.storage.localizedDescription }
    }

    nonisolated static func runID(date: Date = Date(), nonce: UUID = UUID()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let suffix = nonce.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "xodus-\(formatter.string(from: date))-\(suffix)"
    }

    nonisolated static func launchEnvironment(_ inherited: [String: String],
                                              engine: RuntimeProviderKind? = nil,
                                              interpreter: URL? = nil) -> [String: String] {
        var environment = inherited.filter { ["HOME", "USER", "LANG"].contains($0.key) }
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // The resolved runner is passed to the launch script as an explicit, neutral
        // selector so the launch path consumes the routing decision, not config only.
        if let engine { environment["XODUS_ENGINE"] = engine.rawValue }
        if let interpreter {
            environment.merge(LaunchAssociationAssets.interpreterEnvironment(interpreter)) { _, new in new }
        }
        return environment
    }

    static func engineUnavailableMessage(_ reason: EngineRoutingUnavailable) -> String {
        switch reason {
        case .overrideNotInstalled(let kind):
            "This game's selected engine (\(kind.label)) isn't installed or its runner isn't configured. Check its executable path in Engines, or clear the per-game override."
        case .defaultNotInstalled(let kind):
            "The default engine (\(kind.label)) isn't installed or its runner isn't configured. Check its executable path in Engines, or choose a different default."
        case .noRunnerInstalled:
            "No verified Calimocho configuration is selected. Choose one in Engines; no CrossOver or GPTK engine was substituted."
        }
    }

    nonisolated static func nativeLaunchFailureMessage(_ error: Error) -> String {
        if let failure = error as? EngineInspectionError { return failure.localizedDescription }
        if let failure = error as? NativeLaunchError { return failure.localizedDescription }
        return InstalledGameActionCopy.launchUnavailable
    }

    /// Launch failures the user resolves in Settings › Engines.
    nonisolated static func launchFailureOpensEngines(_ error: Error) -> Bool {
        if error is EngineInspectionError { return true }
        guard let failure = error as? NativeLaunchError else { return false }
        switch failure {
        case .installationNotReady, .candidateBlocked, .invalidProfile, .shimsUnavailable, .legacyLauncher: return false
        default: return true
        }
    }

    /// Play is offered only for titles with an admitted launch setup whose engine is usable here.
    func launchSupport(for game: InstalledGame) -> NativeLaunchSupport {
        guard usesUnifiedAccount else { return .supported }
        let key = "\(game.storeId):\(game.engineOverrideV2 != nil)"
        if let (value, at) = launchSupportCache[key], ContinuousClock.now < at.advanced(by: .seconds(15)) { return value }
        let value = NativeLaunchSupport.evaluate(productID: game.storeId,
            evidence: MacGameEvidenceStore.shared.games[game.storeId], hasEngineOverride: game.engineOverrideV2 != nil)
        launchSupportCache[key] = (value, .now)
        return value
    }

    func invalidateLaunchSupport() { launchSupportCache = [:] }

    /// Support for a title that isn't installed yet (install consent): no per-game override can exist.
    func launchSupport(productID: String) -> NativeLaunchSupport {
        guard usesUnifiedAccount else { return .supported }
        let key = "\(productID):false"
        if let (value, at) = launchSupportCache[key], ContinuousClock.now < at.advanced(by: .seconds(15)) { return value }
        let value = NativeLaunchSupport.evaluate(productID: productID,
            evidence: MacGameEvidenceStore.shared.games[productID], hasEngineOverride: false)
        launchSupportCache[key] = (value, .now)
        return value
    }

    func opensEngines(for game: InstalledGame) -> Bool {
        guard let message = playErrors[game.id] else { return false }
        return engineIssueMessages[game.id] == message
    }

    private func recordLaunchFailure(_ error: Error, for game: InstalledGame) {
        let message = Self.nativeLaunchFailureMessage(error)
        playErrors[game.id] = message
        engineIssueMessages[game.id] = Self.launchFailureOpensEngines(error) ? message : nil
    }

    nonisolated static func sessionLog(runID: String, directory: URL) -> URL? {
        guard runID.range(of: #"^xodus-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"#,
                          options: .regularExpression) == runID.startIndex..<runID.endIndex else { return nil }
        return directory.appendingPathComponent(runID + ".stderr.log")
    }

    func showLog(for game: InstalledGame) {
        if let url = playLogs[game.id] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func setAccountAccessAllowed(_ allowed: Bool, message: String? = nil) {
        accountAccessAllowed = allowed
        if let message { accountAccessMessage = message }
        if !allowed {
            for game in games where runningGameID != game.id {
                playErrors[game.id] = accountAccessMessage
            }

        } else {
            for game in games where playErrors[game.id] == accountAccessMessage
                || playErrors[game.id]?.contains("to play this game") == true {
                playErrors[game.id] = nil
            }
        }
    }

    func canRequestPlay(_ productID: String) -> Bool {
        guard accountAccessAllowed else { return false }
        return !usesUnifiedAccount || productAccess.permits(productID, account: unifiedSession?.accountHash)
    }

    /// REQ-159: Play stays offered until a current answer denies access; pressing it checks this product
    /// (and only this product) first.
    func canOfferPlay(_ productID: String) -> Bool {
        guard accountAccessAllowed else { return false }
        return !usesUnifiedAccount || canRequestPlay(productID)
            || !productAccess.deniedRecently(productID, account: unifiedSession?.accountHash)
    }

    /// Owner hardening 2: this copy's refusal reason when a newer build is installed, else nil.
    nonisolated static func newerBuildRefusal() -> String? {
        guard Bundle.main.bundleIdentifier.map({ ConcurrentAppGuard.peers[$0] != nil }) == true,
              let own = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
              let newer = ConcurrentAppGuard.newerInstalledBuild(selfBuild: own,
                  installed: ConcurrentAppGuard.installedCopies()) else { return nil }
        return ConcurrentAppGuard.newerBuildMessage(path: newer.path, build: newer.build)
    }

    func playRequested(_ game: InstalledGame) async {
        if let refusal = Self.newerBuildRefusal() { playErrors[game.id] = refusal; return }
        if !canRequestPlay(game.storeId), let paused = productAccess.pausedNotice() {
            playErrors[game.id] = paused
            return
        }
        if canRequestPlay(game.storeId) { await play(game); return }
        if let message = await playFromLaunchRequest(game, engine: nil, timeout: .seconds(30)) {
            playErrors[game.id] = message
        }
    }

    /// Whether the access check for this product has an answer (permitted, denied or failed) for the
    /// current account. Until then a deep-link Play waits instead of failing.
    func productAccessSettled(_ productID: String) -> Bool {
        guard accountAccessAllowed else { return false }
        if canRequestPlay(productID) { return true }
        guard !usesUnifiedAccount || unifiedSession?.accountHash != nil else { return false }
        return !productAccess.checking && !productAccess.pending(productID, account: unifiedSession?.accountHash)
            && productAccess.accountHash == unifiedSession?.accountHash
    }

    /// Bounded wait for a condition, polled on the main actor; false on timeout or cancellation.
    static func waitUntil(timeout: Duration, interval: Duration = .milliseconds(250),
                          clock: ContinuousClock = .init(), _ condition: () -> Bool) async -> Bool {
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: interval)
        }
        return true
    }

    /// Deep-link Play (`--play-game`): waits up to `timeout` for the access check, then plays or reports
    /// the actual reason. An explicit engine is applied exactly like the per-game Engine menu.
    func playFromLaunchRequest(_ game: InstalledGame, engine: String?,
                               timeout: Duration = .seconds(60)) async -> String? {
        let message = await launchRequestOutcome(game, engine: engine, timeout: timeout)
        if let message {
            Self.launchLog.error("Launch request not started: \(game.storeId, privacy: .public): \(message, privacy: .public)")
        }
        return message
    }

    private func launchRequestOutcome(_ game: InstalledGame, engine: String?, timeout: Duration) async -> String? {
        if let refusal = Self.newerBuildRefusal() { return refusal }
        if !canRequestPlay(game.storeId), let session = unifiedSession {
            // A just-registered game shouldn't wait behind the full background access sweep.
            Task { @MainActor in
                await productAccess.prioritize(game.storeId, session: session, installedIDs: games.map(\.storeId))
            }
        }
        let settled = await Self.waitUntil(timeout: timeout) { productAccessSettled(game.storeId) }
        guard canRequestPlay(game.storeId) else {
            return settled ? (productAccessNotice(for: game) ?? "Access to this game hasn't been confirmed for your Xbox account.")
                : "Access to this game wasn't confirmed within \(timeout.components.seconds) seconds. Open the game and try again."
        }
        if let engine {
            // Engine admission needs the backend lifecycle; a check already in flight is awaited, not skipped.
            _ = await Self.waitUntil(timeout: timeout) { unifiedSession?.nativeLifecycleConfiguration != nil }
            await refreshEngineOverrides(force: true)
            guard let selection = engineOverrides(for: game).first(where: { $0.inspection.engineName == engine }) else {
                return "\(Self.readableEngineName(engine)) isn't available for \(game.title) on this Mac. No other engine was used."
            }
            await setEngineOverrideV2(selection, for: game)
            guard let current = games.first(where: { $0.id == game.id }),
                  current.engineOverrideV2?.selection == selection else {
                return playErrors[game.id] ?? error ?? "\(Self.readableEngineName(engine)) couldn't be selected for \(game.title)."
            }
        }
        guard let current = games.first(where: { $0.id == game.id }) else {
            return "The requested game isn't registered as installed on this Mac."
        }
        await play(current)
        return runningGameID == current.id ? nil
            : playErrors[current.id] ?? "The requested game couldn't start. Check its installation and runtime settings."
    }

    /// Deep link for a game installed on disk but not yet registered: waits (bounded) for discovery, then runs
    /// the same existing-installation verification as opening its page. Never registers unverified files.
    func registeredGameForLaunchRequest(productID: String, timeout: Duration = .seconds(60)) async -> InstalledGame? {
        if let game = games.first(where: { $0.storeId == productID }) { return game }
        guard await Self.waitUntil(timeout: timeout, { hasUnverifiedInstallation(productID: productID)
                || games.contains(where: { $0.storeId == productID }) }) else { return nil }
        if let game = games.first(where: { $0.storeId == productID }) { return game }
        await automaticallyVerifyDiscoveredInstallation(productID: productID)
        if let game = games.first(where: { $0.storeId == productID }) { return game }
        Self.launchLog.error("Launch request not started: \(productID, privacy: .public): installation not verified: \(self.discoveredVerificationErrors[productID] ?? "unknown", privacy: .public)")
        return nil
    }

    func productAccessNotice(for game: InstalledGame) -> String? {
        guard !canRequestPlay(game.storeId) else { return nil }
        return productAccess.reviewNotice(for: game.storeId, account: unifiedSession?.accountHash)
    }

    var canRetryProductAccess: Bool {
        accountAccessAllowed && unifiedSession?.nativeLifecycleConfiguration != nil && !productAccess.checking
            && !accountDisconnecting && !applicationTerminating
    }

    func retryProductAccess(for game: InstalledGame) async {
        guard canRetryProductAccess, games.contains(where: { $0.id == game.id && $0.storeId == game.storeId }),
              let session = unifiedSession else { return }
        await productAccess.refresh(session: session, installedIDs: games.map(\.storeId),
            force: true, selectedProductID: game.storeId)
    }

    func suspendAccountView() {
        guard runningGameID == nil, stoppingGameID == nil, !mutationActive else { return }
        games = []
        launchableIDs = []
        placeholderIDs = []
        unavailableDriveIDs = []
        updateStatuses = [:]
        playErrors = [:]
        playLogs = [:]
        playNotices = [:]
        packageErrors = [:]
        for task in nativeInspectionTasks.values { task.cancel() }
        for task in discoveryTasks.values { task.cancel() }
        for task in automaticDiscoveryTasks.values { task.cancel() }
        for task in installationCheckTasks.values { task.cancel() }
        automaticDiscoveryAttempts = [:]
        automaticReadinessAttempts = [:]
        discoveredVerificationErrors = [:]
        installationStatuses = [:]
        launchVerdicts = [:]
        installationErrors = [:]
        nativeInspectionDates = [:]
        loaded = false
    }

    func play(_ game: InstalledGame) async {
        await play(game, historicalFixture: false)
    }

#if !XODUS_SHIPPING
    func playHistoricalFixture(_ game: InstalledGame) async {
        await play(game, historicalFixture: true)
    }
#endif

    private func play(_ game: InstalledGame, historicalFixture: Bool) async {
        Self.launchLog.notice("Play requested: \(game.storeId, privacy: .public)")
        guard loaded, !editing, !choosing, runningGameID == nil, stoppingGameID == nil, !applicationTerminating,
              mutationGameID != game.id, !serviceSignInActive, !runtimeRepairActive, !accountDisconnecting,
              canRequestPlay(game.storeId), games.contains(game) else {
            let message = !accountAccessAllowed ? accountAccessMessage
                : !canRequestPlay(game.storeId) ? "Access to this game hasn't been confirmed for your Xbox account."
                : runningGameID != nil ? "Quit the running game before starting another."
                : "Your library is busy. Wait for the current operation to finish and try again."
            if runningGameID == game.id {
                playNotices[game.id] = "This game is already running."
            } else { playErrors[game.id] = message }
            Self.launchLog.error("Play unavailable: \(game.storeId, privacy: .public): \(message, privacy: .public)")
            return
        }
        let issues = LibrarySupportVisibility.issues(productID: game.storeId, installed: true,
            packageFormat: game.packageType?.label, compatibility: nil, catalogue: compatibilityCatalogue)
        guard issues.isEmpty else {
            playErrors[game.id] = issues.map(\.detail).joined(separator: " ")
            return
        }
        if let issue = NativeCandidateLaunchCatalogue.issue(productID: game.storeId,
            evidence: MacGameEvidenceStore.shared.games[game.storeId]) {
            playErrors[game.id] = InstalledGameActionCopy.launchUnavailable
            Self.launchLog.error("Candidate launch unavailable: \(game.storeId, privacy: .public): \(issue, privacy: .public)")
            return
        }
        if usesUnifiedAccount {
            invalidateLaunchSupport()
            let support = launchSupport(for: game)
            guard support.canPlay else {
                playErrors[game.id] = support.reason
                engineIssueMessages[game.id] = support.offersEngines ? support.reason : nil
                Self.launchLog.error("Launch not supported: \(game.storeId, privacy: .public): \(support.reason ?? "", privacy: .public)")
                return
            }
            await playNative(game)
            return
        }
        guard historicalFixture || (game.engineOverride ?? defaultEngine()) == .calimocho else {
            recordLaunchFailure(NativeLaunchError.providerPolicy, for: game)
            return
        }
        guard game.usesNativeLifecycle != true else {
            playErrors[game.id] = "Reconnect your Xbox account before playing this installation."
            return
        }
        let interpreter: URL?
        do { interpreter = try LaunchAssociationAssets.bundledInterpreter() }
        catch {
            playErrors[game.id] = "The bundled game runtime could not be verified. Reinstall the approved app."
            return
        }

        let token = UUID()
        runToken = token
        stopConfirmed = false
        stopToken = nil
        runningGameID = game.id
        playState = .launching
        playErrors[game.id] = nil
        playLogs[game.id] = nil
        playNotices[game.id] = nil
        let runID = Self.runID()
        runIDs[game.id] = runID
        foregroundHandoff?.cancel()
        foregroundHandoff = nil
        do {
            if let assets = try LaunchAssociationAssets.bundled(), NSApp.isActive {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                    .appendingPathComponent("xodus-association-\(UUID().uuidString)")
                foregroundHandoff = try LaunchAssociationHandoff(assets: assets, runID: runID, root: root)
            }
        } catch { playNotices[game.id] = LaunchAssociationHandoff.diagnostic }
        let availability = await detectAvailability()
        guard runToken == token else { return }
        let outcome = EngineRouting.decide(.init(packageType: game.packageType ?? .unknown,
            override: game.engineOverride, defaultEngine: defaultEngine(), availability: availability))
        guard case .routed(let runner, _) = outcome else {
            finished(token: token, gameID: game.id, status: 0)
            if case .unavailable(let reason) = outcome {
                playErrors[game.id] = Self.engineUnavailableMessage(reason)
            }
            return
        }
        guard runner != .calimocho else {
            finished(token: token, gameID: game.id, status: 0)
            playErrors[game.id] = NativeLaunchError.legacyLauncher.localizedDescription
            return
        }
        do {
            var environment = Self.launchEnvironment(ProcessInfo.processInfo.environment, engine: runner,
                                                     interpreter: interpreter)
            if let handoff = foregroundHandoff { environment.merge(handoff.environment) { _, new in new } }
            let launcher = game.launcher
            let folder = game.folder
            let child = try await Task.detached(priority: .userInitiated) { [weak self] in
                try InstalledGameFiles.checkFolder(URL(fileURLWithPath: folder))
                try InstalledGameFiles.checkLauncher(URL(fileURLWithPath: launcher))
                try InstalledGameFiles.checkPlayableContent(URL(fileURLWithPath: folder))
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/bin/bash")
                child.arguments = [launcher, runID, runner.rawValue]
                child.environment = environment
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                let startedAt = Date()
                let startedClock = ContinuousClock.now
                child.terminationHandler = { [weak self] value in
                    let status = value.terminationStatus
                    let duration = startedClock.duration(to: .now).components
                    let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                    Task { @MainActor [weak self] in
                        guard let self, self.runToken == token else { return }
                        self.recordSession(gameID: game.id, startedAt: startedAt, seconds: max(0, seconds))
                        let unexpected = self.finished(token: token, gameID: game.id, status: status)
                        if unexpected { await self.findSessionLog(gameID: game.id, runID: runID) }
                    }
                }
                try child.run()
                return (child, startedAt)
            }.value
            // A short-lived script can exit before the off-main launch returns.
            guard runToken == token else { return }
            process = child.0
            launchStarted = true
            foregroundHandoff?.start(current: { [weak self] in
                guard let self else { return false }
                return self.runToken == token && self.runIDs[game.id] == runID
                    && self.runningGameID == game.id && self.process?.isRunning == true
                    && self.stoppingGameID == nil && !self.applicationTerminating
            }, diagnostic: { [weak self] in
                guard let self, self.runToken == token else { return }
                self.playNotices[game.id] = LaunchAssociationHandoff.diagnostic
            })
            recordSession(gameID: game.id, startedAt: child.1, seconds: nil)
            playingTask = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: self.launchingDuration) }
                catch { return }
                if self.runToken == token, child.0.isRunning { self.playState = .playing }
            }
        } catch {
            if runToken == token {
                finished(token: token, gameID: game.id, status: 0)
                playErrors[game.id] = (error as? InstalledGameError)?.localizedDescription
                    ?? InstalledGameError.launch.localizedDescription
                if error is InstalledGameError { launchableIDs.remove(game.id) }
            }
        }
    }

    func useUnifiedAccount(_ session: LiveSession) {
        if usesUnifiedAccount, unifiedSession === session { return }
        usesUnifiedAccount = true
        productAccessObservation = productAccess.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        unifiedSession = session
        launchableIDs = []
    }

    func requiresNativeInstallationStatus(_ game: InstalledGame) -> Bool {
        usesUnifiedAccount || game.usesNativeLifecycle == true
    }

    func automaticReadinessKey(for game: InstalledGame) -> String {
        "\(game.id):\(game.importedAt.timeIntervalSince1970):\(installStatusConfiguration != nil):\(loaded):\(mutationActive):\(editing)"
    }

    func automaticallyCheckInstallation(_ game: InstalledGame) async {
        let key = "\(game.id):\(game.importedAt.timeIntervalSince1970):\(installStatusConfiguration != nil)"
        let contextChanged = automaticReadinessAttempts[game.id].map { $0 != key } == true
        guard automaticReadinessAttempts[game.id] != key, requiresNativeInstallationStatus(game),
              installationStatuses[game.id] == nil, installationErrors[game.id] == nil || contextChanged,
              packageErrors[game.id] == nil, loaded, !mutationActive, !editing, !choosing,
              !accountDisconnecting, !applicationTerminating, runningGameID != game.id,
              NativeCandidateLaunchCatalogue.issue(productID: game.storeId,
                evidence: MacGameEvidenceStore.shared.games[game.storeId]) == nil else { return }
        automaticReadinessAttempts[game.id] = key
        defer {
            // An automatic check that a view cancelled or that couldn't run yet isn't a failure: it is
            // re-queued (the next appearance or status refresh checks again) and never shows Retry.
            if installationStatuses[game.id] == nil, installationErrors[game.id] == nil {
                automaticReadinessAttempts[game.id] = nil
            }
        }
        guard !Task.isCancelled else { return }
        await checkInstallation(game)
    }

    func refreshNativeInstallationStatuses() async {
        guard loaded, !editing, !choosing, !mutationActive, !accountDisconnecting,
              !applicationTerminating, runningGameID == nil, stoppingGameID == nil,
              installStatusConfiguration != nil else { return }
        let pending = games.filter { game in
            guard requiresNativeInstallationStatus(game), !Self.isMountedGame(game) else { return false }
            guard installationErrors[game.id] == nil, packageErrors[game.id] == nil,
                  installationStatuses[game.id] == nil || installationStatuses[game.id]?.status == .complete else { return false }
            return nativeInspectionDates[game.id].map { ContinuousClock.now >= $0.advanced(by: .seconds(120)) } ?? true
        }
        await withTaskGroup(of: Void.self) { group in
            var pending = pending.makeIterator()
            for _ in 0..<2 {
                if let game = pending.next() {
                    group.addTask { [self, game] in _ = await inspectNativeInstallation(game) }
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, !mutationActive, !editing, runningGameID == nil,
                      !applicationTerminating else { group.cancelAll(); return }
                if let game = pending.next() {
                    group.addTask { [self, game] in _ = await inspectNativeInstallation(game) }
                }
            }
        }
    }

    static func inspectionTimeout(for game: InstalledGame, explicitCheck: Bool = false) -> Duration {
        explicitCheck || isMountedGame(game) ? NativeInstallationQuery.largeInstallTimeout : NativeInstallationQuery.defaultTimeout
    }

    /// How long a queued check waits for one of the two check slots before saying so plainly.
    static let inspectionQueueLimit: Duration = .seconds(600)
    static let inspectionQueueTimeoutMessage = "Other games are still being checked. Try again in a moment."

    static func permitsNativeInspection(activeChecks: Int, preparingLaunch: Bool) -> Bool {
        activeChecks < 2 || preparingLaunch
    }

    func hasFreshCompleteInstallation(_ game: InstalledGame) -> Bool {
        guard let status = installationStatuses[game.id], status.success, status.status == .complete,
              status.product == game.storeId, status.gameDirectory == game.folder,
              let date = nativeInspectionDates[game.id] else { return false }
        return ContinuousClock.now < date.advanced(by: .seconds(120))
    }

    func recordInstallationStatus(_ status: NativeInstallationStatus, for game: InstalledGame) throws {
        guard loaded, !applicationTerminating, games.contains(game),
              status.version == 1, status.operation == "install-status",
              status.product == game.storeId, status.gameDirectory == game.folder else {
            throw GameScriptError.invalidReceipt
        }
        installationStatuses[game.id] = status
        launchVerdicts[game.id] = nil
        installationErrors[game.id] = status.success ? nil : status.explanation
        nativeInspectionDates[game.id] = ContinuousClock.now
        invalidateLaunchSupport()
        if status.success && status.status == .complete && NativeCandidateLaunchCatalogue.issue(productID: game.storeId,
            evidence: MacGameEvidenceStore.shared.games[game.storeId]) == nil && launchSupport(for: game).canPlay {
            launchableIDs.insert(game.id)
            packageErrors[game.id] = nil
        } else { launchableIDs.remove(game.id) }
    }

    private func inspectNativeInstallation(_ game: InstalledGame,
                                           timeout: Duration? = nil) async -> NativeInstallationStatus? {
        let mountedStorageRoots = mountedStorageRoots
        let probe: GameStorageProbe
        if let existing = installationVolumeProbes[game.id] { probe = existing }
        else {
            probe = GameStorageProbe()
            installationVolumeProbes[game.id] = probe
        }
        let unavailable: Bool
        do {
            unavailable = try await probe.read {
                game.storageVolume?.isUnavailable(mountedRoots:
                    game.storageVolume.map { $0.path != "/" } == true ? mountedStorageRoots() : nil) == true
            }
        } catch {
            guard loaded, !applicationTerminating, games.contains(game) else { return nil }
            installationStatuses[game.id] = nil
            nativeInspectionDates[game.id] = nil
            launchableIDs.remove(game.id)
            installationErrors[game.id] = "The game drive couldn't be checked. \(error.localizedDescription)"
            return nil
        }
        guard loaded, !applicationTerminating, games.contains(game) else { return nil }
        guard !unavailable else {
            unavailableDriveIDs.insert(game.id)
            installationStatuses[game.id] = nil
            nativeInspectionDates[game.id] = nil
            launchableIDs.remove(game.id)
            installationErrors[game.id] = Self.driveUnavailableMessage
            return nil
        }
        unavailableDriveIDs.remove(game.id)
        if let pending = nativeInspectionTasks[game.id] {
            do { return try await pending.value }
            catch is CancellationError { return nil }
            catch {
                guard !Task.isCancelled else { return nil }
                if loaded, !applicationTerminating, games.contains(game) {
                    installationErrors[game.id] = NativeInstallationQuery.failureMessage(error)
                }
                return nil
            }
        }
        guard let configuration = installStatusConfiguration else {
            installationErrors[game.id] = "The verified local service isn't connected. Reconnect \(AppBrand.displayName) and check again."
            return nil
        }
        // At most two read-only checks run at once; the rest wait their turn (showing Checking…)
        // instead of recording a Retry. Only a real CLI result or failure sets an error.
        let waitDeadline = ContinuousClock.now.advanced(by: Self.inspectionQueueLimit)
        while !Self.permitsNativeInspection(activeChecks: nativeInspectionTasks.count,
                                            preparingLaunch: runningGameID == game.id && playState == .launching) {
            guard !Task.isCancelled, loaded, !mutationActive, !applicationTerminating, games.contains(game) else { return nil }
            guard ContinuousClock.now < waitDeadline else {
                installationErrors[game.id] = Self.inspectionQueueTimeoutMessage
                return nil
            }
            try? await Task.sleep(for: .milliseconds(100))
            if nativeInspectionTasks[game.id] != nil { return await inspectNativeInstallation(game, timeout: timeout) }
        }
        guard !Task.isCancelled, loaded, !mutationActive, !applicationTerminating, games.contains(game) else { return nil }
        let query = NativeInstallationQuery()
        let task = Task {
            try await query.run(configuration: configuration, product: game.storeId,
                                gameDirectory: URL(fileURLWithPath: game.folder), timeout: timeout ?? Self.inspectionTimeout(for: game),
                                storageProbe: probe)
        }
        nativeInspectionTasks[game.id] = task
        installationErrors[game.id] = nil
        checkingInstallations.insert(game.id)
        defer {
            nativeInspectionTasks[game.id] = nil
            checkingInstallations.remove(game.id)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, !applicationTerminating, loaded, games.contains(game) else { return nil }
            try recordInstallationStatus(result, for: game)
            return result
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            guard !applicationTerminating, loaded, games.contains(game) else { return nil }
            installationStatuses[game.id] = nil
            installationErrors[game.id] = NativeInstallationQuery.failureMessage(error)
            nativeInspectionDates[game.id] = ContinuousClock.now
            launchableIDs.remove(game.id)
            return nil
        }
    }

    private func playNative(_ game: InstalledGame) async {
        guard let session = unifiedSession, let configuration = session.nativeLifecycleConfiguration,
              let account = session.accountHash else {
            playErrors[game.id] = "Reconnect your Xbox account before playing this installation."
            return
        }
        let token = UUID()
        runToken = token
        stopConfirmed = false
        stopToken = nil
        runningGameID = game.id
        playState = .launching
        launchStarted = false
        do {
            let preparation = Task { @MainActor in
                // A check already in flight (opening the app, or a deep-link Play) is awaited, not refused.
                if !hasFreshCompleteInstallation(game) { await awaitInFlightCheck(game) }
                if !hasFreshCompleteInstallation(game) {
                    let status = await inspectNativeInstallation(game)
                    try Task.checkCancellation()
                    guard status?.status == .complete else { throw NativeLaunchError.installationNotReady }
                }
                let probe = gameReadinessProbes[game.id] ?? GameStorageProbe()
                gameReadinessProbes[game.id] = probe
                return try await probe.read {
                    let folder = URL(fileURLWithPath: game.folder)
                    try GameScriptFiles.checkPath(folder)
                    let config = try MicrosoftGameConfig.read(folder: folder)
                    guard config.storeId == game.storeId, config.identityName == game.identityName,
                          config.version == game.version,
                          game.storageVolume.map { $0.identifies(GameStorageVolume.read(at: folder)) } ?? true else {
                        throw InstalledGameError.invalidConfig
                    }
                    return config
                }
            }
            nativePreparationTask = preparation
            defer { nativePreparationTask = nil }
            let config = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            let launch = try await NativeLaunchConfiguration.resolveDefault(game: game, configuration: configuration,
                provider: defaultEngine(),
                evidence: MacGameEvidenceStore.shared.games[game.storeId])
            Self.launchLog.notice("Effective launch: \(game.storeId, privacy: .public); engine=\(launch.engine, privacy: .public); registry=\(launch.registry.path, privacy: .public); prefix=\(launch.prefix.path, privacy: .public)")
            guard launch.admittedSelection != nil else { throw NativeLaunchError.providerPolicy }
            let arguments = try await launch.arguments(manifestExecutables: config.executables)
            let prefixNotice = try await launch.prefixNotice()
            let legacyPrefixIDs = try await store.prefixInstallationIDs(productID: game.storeId) + [game.id]
            if preparation.isCancelled { throw CancellationError() }
            let executables = config.executables
            let existingWindows = NativeGameForeground.windowIDs()
            guard canRequestPlay(game.storeId), session.accountHash == account,
                  session.nativeLifecycleConfiguration?.executable == configuration.executable,
                  runningGameID == game.id, runToken == token, !accountDisconnecting, !applicationTerminating,
                  games.contains(game) else { throw GameScriptError.busy }
            playErrors[game.id] = nil
            playLogs[game.id] = nil
            playNotices[game.id] = prefixNotice
            let runID = Self.runID()
            runIDs[game.id] = runID
            nativeLaunchTask = Task {
                let startedAt = Date(), clock = ContinuousClock.now
                do {
                    let result = try await nativeLauncher.run(configuration: configuration, accountHash: account,
                        operation: "launch", product: game.storeId,
                        gameDirectory: URL(fileURLWithPath: game.folder), runID: runID,
                        launchArguments: arguments, launchEnvironment: launch.profile?.launchEnvironment ?? [:],
                        unsetLaunchEnvironment: launch.profile?.unsetEnvironment ?? [],
                        engineSelection: launch.admittedSelection, prepareAdmittedPrefix: {
                            guard let selection = launch.admittedSelection else { throw NativeLaunchError.providerNotAdmitted }
                            try await Task.detached {
                                try CalimochoPrefixContinuity.prepare(prefix: launch.prefix, selection: selection,
                                    productID: game.storeId, legacyIDs: legacyPrefixIDs)
                            }.value
                        }, onStarted: {
                            Self.launchLog.notice("Launcher started: \(game.storeId, privacy: .public), engine \(launch.engine, privacy: .public)")
                            launchStarted = true
                            playState = .playing
                            recordSession(gameID: game.id, startedAt: startedAt, seconds: nil)
                            if let pid = nativeLauncher.processIdentifier {
                                nativeForegroundTask = Task {
                                    let activated = await NativeGameForeground.activate(launcherPID: pid, title: game.title,
                                        executables: executables, existingWindows: existingWindows) {
                                        self.runToken == token && self.nativeLauncher.isRunning
                                            && self.stoppingGameID == nil && !self.applicationTerminating
                                    }
                                    if !activated, runToken == token, nativeLauncher.isRunning {
                                        playNotices[game.id] = "Click the game window to bring it to the front."
                                    }
                                }
                            }
                        })
                    guard runToken == token else { return }
                    nativeForegroundTask?.cancel()
                    nativeForegroundTask = nil
                    let duration = clock.duration(to: .now).components
                    guard runToken == token else { return }
                    recordSession(gameID: game.id, startedAt: startedAt,
                        seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                    let stoppedByUser = stopToken == token
                    finished(token: token, gameID: game.id, status: result.exitCode)
                    playLogs[game.id] = URL(fileURLWithPath: result.logDirectory)
                    playErrors[game.id] = result.launchFailureMessage(stoppedByUser: stoppedByUser)
                    launchVerdicts[game.id] = result.installVerdict
                    if !result.success {
                        Self.launchLog.error("Launch terminal result: \(game.storeId, privacy: .public); code=\(result.errorCode ?? "unknown", privacy: .public); error=\(result.error ?? "none", privacy: .public)")
                    }
                    if session.accountHash != account { playErrors[game.id] = "Your Xbox account changed during play." }
                } catch NativeLifecycleCancellation.launchStopped {
                    let stoppedByUser = stopToken == token
                    finished(token: token, gameID: game.id, status: 0)
                    playErrors[game.id] = stoppedByUser ? nil : InstalledGameActionCopy.launchUnavailable
                    playLogs[game.id] = nativeLauncher.stateDirectory
                    if let result = nativeLauncher.completedResult, !result.success {
                        Self.launchLog.notice("Stopped launch: \(game.storeId, privacy: .public); code=\(result.errorCode ?? "unknown", privacy: .public); error=\(result.error ?? "none", privacy: .public)")
                    }
                } catch {
                    finished(token: token, gameID: game.id, status: 1)
                    recordLaunchFailure(error, for: game)
                    playLogs[game.id] = nativeLauncher.stateDirectory
                }
                nativeLaunchTask = nil
            }
        } catch is CancellationError {
            finished(token: token, gameID: game.id, status: 0)
            playErrors[game.id] = nil
        } catch {
            finished(token: token, gameID: game.id, status: 1)
            recordLaunchFailure(error, for: game)
            Self.launchLog.error("Play failed before launch: \(game.storeId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopNative(_ game: InstalledGame) async {
        guard usesUnifiedAccount, canStop(game) else { return }
        let token: UUID
        do { token = try reserveStop(game) }
        catch { playErrors[game.id] = GameScriptError.busy.localizedDescription; return }
        nativeLauncher.cancel()
        await nativeLaunchTask?.value
        completeStop(token: token, gameID: game.id, error: nil, log: playLogs[game.id])
        releaseMutation()
    }

    @discardableResult private func finished(token: UUID, gameID: UUID, status: Int32) -> Bool {
        guard runToken == token else { return false }
        if let handoff = foregroundHandoff {
            handoff.cancel()
            foregroundHandoff = nil
            let previous = foregroundCleanup
            foregroundCleanup = Task {
                let previousClosed = await previous?.value ?? true
                let closed = await handoff.cancelAndWait()
                handoff.releaseRootAfterLauncherExit()
                return previousClosed && closed
            }
        }
        playingTask?.cancel()
        playingTask = nil
        process = nil
        runToken = nil
        runningGameID = nil
        playState = nil
        launchStarted = false
        if stopToken == token {
            // The launcher can exit before the stop script publishes its final receipt.
            if stopConfirmed {
                playNotices[gameID] = "Stopped"
                stopToken = nil
                stoppingGameID = nil
            }
            return false
        }
        if status != 0 { playErrors[gameID] = "The game launcher reported an error (code \(status))." }
        return status != 0
    }

    /// L19-5: stopping the owned running game depends only on that game, not on an unrelated
    /// download, mutation or sign-in.
    func canStop(_ game: InstalledGame) -> Bool {
        loaded && !applicationTerminating && stoppingGameID == nil && runningGameID == game.id
            && launchStarted && (usesUnifiedAccount ? nativeLauncher.isRunning : process?.isRunning == true)
            && games.contains(where: {
                $0.id == game.id && $0.storeId == game.storeId && $0.launcher == game.launcher
            })
    }

    func reserveStop(_ game: InstalledGame) throws -> UUID {
        guard canStop(game), let token = runToken else { throw GameScriptError.busy }
        foregroundHandoff?.cancel()
        mutationActive = true
        mutationGameID = game.id
        stoppingGameID = game.id
        stopToken = token
        stopConfirmed = false
        playErrors[game.id] = nil
        playLogs[game.id] = nil
        playNotices[game.id] = nil
        return token
    }

    func completeStop(token: UUID, gameID: UUID, error: String?, log: URL?) {
        guard stopToken == token, stoppingGameID == gameID else { return }
        stopConfirmed = error == nil
        if let error {
            playErrors[gameID] = error
            playLogs[gameID] = log
        } else if runToken != token {
            playNotices[gameID] = "Stopped"
        }
        if error != nil || runToken != token {
            stopToken = nil
            stoppingGameID = nil
        }
    }

    private func recordSession(gameID: UUID, startedAt: Date, seconds: Double?) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].lastPlayedAt = startedAt
        games[index].lastSessionSeconds = seconds
        let previous = sessionPersistence
        let store = store
        sessionPersistence = Task { [weak self] in
            await previous?.value
            do {
                try await store.recordSession(id: gameID, startedAt: startedAt, seconds: seconds)
                self?.historyError = nil
            } catch {
                self?.historyError = "Your play history couldn't be saved. You can keep playing."
            }
        }
    }

    private func findSessionLog(gameID: UUID, runID: String) async {
        guard let url = Self.sessionLog(runID: runID, directory: logDirectory) else { return }
        let exists = await Task.detached(priority: .utility) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }.value
        if exists, runIDs[gameID] == runID, playErrors[gameID] != nil { playLogs[gameID] = url }
    }

    func waitForSessionPersistence() async { await sessionPersistence?.value }

    func shutdownForegroundHandoff() async -> Bool {
        let activeClosed = await foregroundHandoff?.cancelAndWait() ?? true
        let retiredClosed = await foregroundCleanup?.value ?? true
        return activeClosed && retiredClosed
    }

    func refreshAfterSetupRepair() async {
        guard mutationActive, runtimeRepairActive else { return }
        await refreshLaunchableGames()
    }

    func checkInstallation(_ game: InstalledGame) async {
        guard loaded, !checkingInstallations.contains(game.id), !editing, !choosing, !mutationActive, !accountDisconnecting,
              !applicationTerminating, runningGameID != game.id, games.contains(where: { $0.id == game.id }) else { return }
        checkingInstallations.insert(game.id)
        defer {
            checkingInstallations.remove(game.id)
            installationCheckTasks[game.id] = nil
        }
        let task = Task { @MainActor in
            await observeLaunchableGame(game)
            guard !Task.isCancelled, requiresNativeInstallationStatus(game), !unavailableDriveIDs.contains(game.id),
                  packageErrors[game.id] == nil,
                  let current = games.first(where: { $0.id == game.id && $0.folder == game.folder }) else { return }
            _ = await inspectNativeInstallation(current, timeout: Self.inspectionTimeout(for: current, explicitCheck: true))
        }
        installationCheckTasks[game.id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancelInstallationCheck(_ game: InstalledGame) {
        if checkingInstallations.contains(game.id) {
            installationErrors[game.id] = "Installation verification was cancelled. Retry when you're ready."
        }
        if runningGameID == game.id && !launchStarted {
            stopToken = runToken
            Self.cancelPrestartLaunch(preparation: nativePreparationTask, launch: nativeLaunchTask, launcher: nativeLauncher)
        }
        installationCheckTasks[game.id]?.cancel()
        nativeInspectionTasks[game.id]?.cancel()
    }

    static func cancelPrestartLaunch(preparation: Task<MicrosoftGameConfig, Error>?,
                                     launch: Task<Void, Never>?, launcher: NativeGameLifecycle) {
        preparation?.cancel()
        launch?.cancel()
        launcher.cancel()
    }

    func reserveMutation(gameID: UUID?) throws {
        guard loaded, !editing, !choosing, !mutationActive, !serviceSignInActive, !accountDisconnecting, !applicationTerminating,
              gameID.map({ nativeInspectionTasks[$0] == nil }) ?? true,
              gameID == nil || runningGameID != gameID else { throw GameScriptError.busy }
        mutationActive = true
        mutationGameID = gameID
        if let gameID {
            installationStatuses[gameID] = nil
            installationErrors[gameID] = nil
            nativeInspectionDates[gameID] = nil
            if games.first(where: { $0.id == gameID }).map(requiresNativeInstallationStatus) == true {
                launchableIDs.remove(gameID)
            }
        }
    }

    func releaseMutation() {
        mutationActive = false
        mutationGameID = nil
    }

    /// Persist (or clear with `nil`) a per-game engine override. Routing consumes
    /// this on the next launch; a selected-but-missing engine refuses launch.
    func setEngineOverride(_ override: RuntimeProviderKind?, for game: InstalledGame) async {
        guard loaded, !editing, !choosing, !mutationActive, !accountDisconnecting, !applicationTerminating,
              runningGameID != game.id, games.contains(where: { $0.id == game.id }) else { return }
        editing = true
        defer { editing = false }
        do {
            let selection = override == .calimocho ? try AdmittedEngineSelection.read(defaults: .standard) : nil
            applySavedGames(try await store.setEngineOverride(id: game.id, override: override, selection: selection))
            error = nil
        } catch let failure as NativeLaunchError { self.error = failure.localizedDescription }
        catch { self.error = InstalledGameError.storage.localizedDescription }
    }

    func refreshEngineOverrides(force: Bool = true, retryFailed: Bool = false) async {
        guard loaded, force || !checkingEngineOverrides, !applicationTerminating,
              force || !engineOverridesChecked || (retryFailed && !failedEngineOverrides.isEmpty),
              unifiedSession?.nativeLifecycleConfiguration != nil else { return }
        await withEngineOverrideCheck {
            guard !applicationTerminating, !accountDisconnecting, !Task.isCancelled,
                  let configuration = unifiedSession?.nativeLifecycleConfiguration else { return }
            await inspectEngineOverrides(configuration: configuration, force: force)
        }
    }

    func activateCalimochoUpdate(_ selection: AdmittedEngineSelection,
                                replacing oldEngine: String,
                                defaults: UserDefaults = .standard) async throws {
        guard loaded, mutationActive, !applicationTerminating, !accountDisconnecting,
              runningGameID == nil, let pin = CalimochoReleasePin.all.last,
              selection.inspection.engineName == pin.engineName,
              selection.inspection.wineSha256 == pin.wineSha256,
              selection.inspection.wineserverSha256 == pin.wineserverSha256 else {
            throw CalimochoUpdateError.admission
        }
        for product in ["9P9VNSQK1W3K", "9NMNMS626R59"] {
            guard let profile = try NativeTitleLaunchProfile.read(productID: product, defaults: defaults,
                                                                  provider: .calimocho),
                  profile.engine == pin.engineName, profile.wineSha256 == pin.wineSha256,
                  profile.wineserverSha256 == pin.wineserverSha256 else { throw NativeLaunchError.invalidProfile }
        }
        let previous = defaults.object(forKey: NativeEngineDefaults.preferenceKey)
        let previousProvider = defaults.object(forKey: EngineDefaults.defaultEngineKey)
        do {
            if EngineDefaults.defaultEngine(defaults).map({ $0 == .calimocho }) ?? true,
               let bytes = defaults.data(forKey: NativeEngineDefaults.preferenceKey) {
                let saved = try JSONDecoder().decode(AdmittedEngineSelection.self, from: bytes)
                if saved.inspection.admittedProvider == "calimocho", saved.inspection.engineName == oldEngine {
                    try NativeEngineSettings.persistDefaultAdmission(selection, defaults: defaults)
                }
            }
            applySavedGames(try await store.retargetCalimochoTitles(selection, replacing: oldEngine))
        } catch {
            if let previous { defaults.set(previous, forKey: NativeEngineDefaults.preferenceKey) }
            else { defaults.removeObject(forKey: NativeEngineDefaults.preferenceKey) }
            if let previousProvider { defaults.set(previousProvider, forKey: EngineDefaults.defaultEngineKey) }
            else { defaults.removeObject(forKey: EngineDefaults.defaultEngineKey) }
            throw error
        }
    }

    func withEngineOverrideCheck(_ inspection: @MainActor () async -> Void) async {
        while checkingEngineOverrides {
            await withCheckedContinuation { engineOverrideWaiters.append($0) }
        }
        checkingEngineOverrides = true
        defer {
            checkingEngineOverrides = false
            let waiters = engineOverrideWaiters
            engineOverrideWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        await inspection()
    }

    private func inspectEngineOverrides(configuration: BackendConfiguration, force: Bool) async {
        do {
            let catalog = try NativeEngineDefaults.read()
            let bindings = catalog.bindings.filter { !$0.isFH6Recipe || NativeFH6Recipe.enabled }
            let names = Self.engineInspectionNames(all: Set(bindings.map(\.engineName)),
                failed: failedEngineOverrides, checked: engineOverridesChecked, force: force)
            var choices = availableEngineOverrides.filter {
                !names.contains($0.inspection.engineName ?? "")
                    && (NativeFH6Recipe.enabled || $0.inspection.engineName != NativeFH6Recipe.engineName)
            }
            var failures = failedEngineOverrides.subtracting(names)
            for binding in bindings where names.contains(binding.engineName) {
                do { choices.append(try await binding.inspect(configuration: configuration)) }
                catch {
                    failures.insert(binding.engineName)
                    Self.launchLog.error("Override unavailable: \(binding.engineName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                guard !applicationTerminating, !Task.isCancelled else { return }
            }
            availableEngineOverrides = choices
            failedEngineOverrides = failures
            engineOverridesChecked = true
        } catch { self.error = Self.nativeLaunchFailureMessage(error) }
    }

    static func engineInspectionNames(all: Set<String>, failed: Set<String>, checked: Bool,
                                      force: Bool) -> Set<String> {
        force || !checked ? all : failed.intersection(all)
    }

    func engineOverrides(for game: InstalledGame) -> [AdmittedEngineSelection] {
        availableEngineOverrides.filter { selection in
            do {
                try NativeLaunchConfiguration.validateOverride(selection, game: game)
                return true
            } catch {
                Self.launchLog.debug("Override incompatible: \(game.storeId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }

        }
    }

    func defaultEngineLabel(for game: InstalledGame) -> String {
        let titleEngine = try? NativeTitleLaunchProfile.read(productID: game.storeId, defaults: .standard,
                                                              provider: .calimocho)?.engine
        let saved = UserDefaults.standard.data(forKey: NativeEngineDefaults.preferenceKey)
            .flatMap { try? JSONDecoder().decode(AdmittedEngineSelection.self, from: $0) }
        let name = titleEngine ?? saved?.inspection.engineName
            ?? (try? NativeEngineDefaults.read().defaultEngine)
        return Self.readableEngineName(name)
    }

    static func readableEngineName(_ name: String?) -> String {
        EngineDisplayName.name(name)
    }

    func setEngineOverrideV2(_ selection: AdmittedEngineSelection?, for game: InstalledGame) async {
        guard loaded, !editing, !choosing, !mutationActive, !accountDisconnecting, !applicationTerminating,
              runningGameID != game.id, games.contains(where: { $0.id == game.id }) else { return }
        editing = true
        defer { editing = false }
        do {
            if let selection {
                try NativeLaunchConfiguration.validateOverride(selection, game: game)
                guard let configuration = unifiedSession?.nativeLifecycleConfiguration,
                      let name = selection.inspection.engineName,
                      let digest = selection.inspection.registrySha256 else { throw NativeLaunchError.engineUnavailable }
                try await EngineInspectionClient().validateLaunch(configuration: configuration, arguments: [
                    "--registry", selection.registryPath, "--engine", name, "--expected-registry-sha256", digest
                ] + (name == NativeFH6Recipe.engineName ? NativeFH6Recipe.arguments : []),
                    selection: selection, product: game.storeId)
            }
            guard !applicationTerminating, !accountDisconnecting else { throw GameScriptError.busy }
            applySavedGames(try await store.setEngineOverrideV2(id: game.id, selection: selection))
            playErrors[game.id] = nil
            error = nil
        } catch {
            Self.launchLog.error("Override not saved: \(game.storeId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.error = Self.nativeLaunchFailureMessage(error)
        }
    }

    func registerInstallation(folder: URL, launcher: URL, expectedStoreID: String) async throws {
        guard loaded, mutationActive, !editing, !applicationTerminating else { throw GameScriptError.busy }
        editing = true
        defer { editing = false }
        try await saveValidatedGame(folder: folder, launcher: launcher, expectedStoreID: expectedStoreID, installedOn: Date())
    }

    func registerNativeInstallation(folder: URL, expectedStoreID: String) async throws {
        guard loaded, mutationActive, !editing, !applicationTerminating else { throw GameScriptError.busy }
        editing = true
        defer { editing = false }
        try await saveValidatedGame(folder: folder, launcher: nil, expectedStoreID: expectedStoreID, installedOn: Date())
    }

    func removeUninstalled(_ id: UUID) async throws {
        guard mutationActive, mutationGameID == id, runningGameID != id, !editing else { throw GameScriptError.busy }
        editing = true
        defer { editing = false }
        applySavedGames(try await store.remove(id: id))
        launchableIDs.remove(id)
        installationStatuses[id] = nil
        installationErrors[id] = nil
        nativeInspectionDates[id] = nil
        playErrors[id] = nil
        playLogs[id] = nil
        runIDs[id] = nil
    }

    private func saveValidatedGame(folder: URL, launcher: URL?, expectedStoreID: String?, installedOn: Date? = nil) async throws {
        let inspectPackage = inspectPackage
        let metadata = try await Task.detached(priority: .userInitiated) {
            try GameScriptFiles.checkPath(folder)
            let config = try MicrosoftGameConfig.read(folder: folder)
            if let launcher { try InstalledGameFiles.checkLauncher(launcher) }
            if let expectedStoreID, config.storeId != expectedStoreID { throw GameScriptError.invalidReceipt }
            return (config, try inspectPackage(folder), GameStorageVolume.read(at: folder))
        }.value
        let previous = games.first(where: { $0.folder == folder.path })
        guard previous?.id != runningGameID || runningGameID == nil else { throw GameScriptError.busy }
        let game = InstalledGame(id: previous?.id ?? UUID(),
            title: metadata.0.title, identityName: metadata.0.identityName, version: metadata.0.version,
            storeId: metadata.0.storeId, folder: folder.path, launcher: launcher?.path ?? "", importedAt: Date(),
            publisher: metadata.0.publisher, packageType: metadata.1,
            usesNativeLifecycle: launcher == nil ? true : nil, storageVolume: metadata.2,
            installedOn: previous == nil ? installedOn : previous?.installedOn)
        applySavedGames(try await store.upsert(game))
        await refreshLaunchableGames()
    }

    private func applySavedGames(_ saved: [InstalledGame]) {
        games = saved.map { entry in
            guard let current = games.first(where: { $0.id == entry.id }),
                  let date = current.lastPlayedAt, entry.lastPlayedAt.map({ date >= $0 }) ?? true else {
                return entry
            }
            var merged = entry
            merged.lastPlayedAt = date
            merged.lastSessionSeconds = current.lastSessionSeconds
            return merged
        }
        recomputeUpdateStatuses()
    }

    /// Records the latest known available versions (keyed by store id) and recomputes update
    /// availability for every installed game.
    func applyAvailableVersions(_ versions: [String: String]) {
        availableVersions = versions
        recomputeUpdateStatuses()
    }

    /// Update availability for a single installed game against the known available version.
    func updateStatus(for game: InstalledGame) -> UpdateStatus {
        UpdateDetector.status(installed: game.version, available: availableVersions[game.storeId])
    }

    private func recomputeUpdateStatuses() {
        var result: [UUID: UpdateStatus] = [:]
        for game in games {
            result[game.id] = UpdateDetector.status(installed: game.version,
                                                    available: availableVersions[game.storeId])
        }
        updateStatuses = result
    }

    private func refreshLaunchableGames() async {
        guard !refreshingReadiness else {
            readinessRefreshRequested = true
            return
        }
        refreshingReadiness = true
        defer { refreshingReadiness = false }
        repeat {
            readinessRefreshRequested = false
            await observeLaunchableGames()
        } while readinessRefreshRequested && loaded && !applicationTerminating
    }

    private func observeLaunchableGames() async {
        await withTaskGroup(of: Void.self) { group in
            var pending = games.filter { !Self.isMountedGame($0) }.makeIterator()
            for _ in 0..<2 {
                if let game = pending.next() {
                    group.addTask { [self, game] in await observeLaunchableGame(game) }
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, loaded, !applicationTerminating else { group.cancelAll(); return }
                if let game = pending.next() {
                    group.addTask { [self, game] in await observeLaunchableGame(game) }
                }
            }
        }
    }

    /// The registry file every X Ode process shares (L19-3).
    var registryFile: URL { store.file }

    static func isMountedGame(_ game: InstalledGame) -> Bool {
        game.folder.hasPrefix("/Volumes/") || game.folder.hasPrefix(NSHomeDirectory() + "/Mounts/")
    }

    /// True only when the folder's nearest existing ancestor, with symlinks resolved, is on the boot volume.
    /// A missing folder there means "not installed"; anywhere else it may be a disconnected drive.
    nonisolated static func isBootVolumeFolder(_ path: String, fileManager: FileManager = .default) -> Bool {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.path.hasPrefix("/Volumes/") else { return false }
        while !fileManager.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return false }
            url = parent
        }
        // Resolve symlinks first, so a link to an external drive is judged by where it really points.
        let resolved = url.resolvingSymlinksInPath()
        guard !resolved.path.hasPrefix("/Volumes/"),
              let volume = try? resolved.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        else { return false }
        // The sealed system volume ("/") and the Data volume that holds home folders are both the startup disk.
        let startup = ["/", NSHomeDirectory()].compactMap {
            try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        }
        return startup.contains { volume.isEqual($0) }
    }

    private func observeLaunchableGame(_ game: InstalledGame) async {
        let entries = [game]
        let probe: GameStorageProbe
        if let existing = gameReadinessProbes[game.id] { probe = existing }
        else {
            probe = GameStorageProbe()
            gameReadinessProbes[game.id] = probe
        }
        let inspectPackage = inspectPackage
        let mountedStorageRoots = mountedStorageRoots
        let nativeIDs = Set(entries.filter(requiresNativeInstallationStatus).map(\.id))
        // On an external drive a missing folder may only mean the drive isn't connected.
        let localNativeIDs = Set(entries.filter {
            nativeIDs.contains($0.id) && !Self.isMountedGame($0) && Self.isBootVolumeFolder($0.folder)
        }.map(\.id))
        let read = Task { try await probe.read(timeout: .seconds(3)) {
            var launchable: Set<UUID> = []
            var publishers: [UUID: String] = [:]
            var packageTypes: [UUID: PackageType] = [:]
            var failures: [UUID: String] = [:]
            var placeholders: Set<UUID> = []
            var unavailableDrives: Set<UUID> = []
            var volumes: [UUID: GameStorageVolume] = [:]
            var validNativeFolders: Set<UUID> = []
            let mounted = game.storageVolume.map { $0.path != "/" } == true ? mountedStorageRoots() : nil
            for game in entries {
                let folder = URL(fileURLWithPath: game.folder)
                if game.storageVolume?.isUnavailable(mountedRoots: mounted) == true {
                    unavailableDrives.insert(game.id)
                    failures[game.id] = Self.driveUnavailableMessage
                    continue
                }
                // A native game whose folder is gone is "not installed", which install-status reports
                // (DIRECTORY_MISSING → Download); it is not a package failure that shows Retry.
                if localNativeIDs.contains(game.id), !FileManager.default.fileExists(atPath: folder.path) { continue }
                if game.publisher == nil, let publisher = (try? MicrosoftGameConfig.read(folder: folder))?.publisher {
                    publishers[game.id] = publisher
                }
                do { packageTypes[game.id] = try inspectPackage(folder) }
                catch {
                    if !nativeIDs.contains(game.id) {
                        failures[game.id] = "Package format couldn't be inspected. Reconnect the game drive or reimport the game."
                    }
                }
                do {
                    try InstalledGameFiles.checkFolder(folder)
                    try GameScriptFiles.checkPath(folder)
                    if !nativeIDs.contains(game.id) {
                        try InstalledGameFiles.checkLauncher(URL(fileURLWithPath: game.launcher))
                    }
                    // L19-4: a native game with a missing or unreadable manifest goes to install-status, whose
                    // MANIFEST_INVALID result offers Repair; it is not a package failure that loops on Retry.
                    if nativeIDs.contains(game.id), (try? MicrosoftGameConfig.read(folder: folder)) == nil {
                        validNativeFolders.insert(game.id)
                        continue
                    }
                    let config = try MicrosoftGameConfig.read(folder: folder)
                    guard config.storeId == game.storeId else { throw InstalledGameError.invalidConfig }
                    if let volume = GameStorageVolume.read(at: folder),
                       game.storageVolume == nil
                        || (game.storageVolume?.uuid == nil && game.storageVolume?.path == volume.path && volume.uuid != nil) {
                        volumes[game.id] = volume
                    }
                    if nativeIDs.contains(game.id) { validNativeFolders.insert(game.id); continue }
                    if config.placeholderOnly {
                        placeholders.insert(game.id)
                        failures[game.id] = InstalledGameError.placeholderContent.localizedDescription
                        continue
                    }
                    launchable.insert(game.id)
                } catch {
                    failures[game.id] = (error as? InstalledGameError)?.localizedDescription
                        ?? "Game readiness couldn't be checked. Reconnect its drive or reimport the installed game."
                }
            }
            return (launchable, publishers, packageTypes, failures, placeholders,
                    unavailableDrives, volumes, validNativeFolders)
        } }
        let outcome = await withTaskCancellationHandler { await read.result } onCancel: { read.cancel() }
        guard loaded, !applicationTerminating, games.contains(where: {
            $0.id == game.id && $0.folder == game.folder && $0.importedAt == game.importedAt
        }) else { return }
        guard case .success(let result) = outcome else {
            if case .failure(let error) = outcome {
                guard !(error is CancellationError) else { return }
                Self.launchLog.error("Readiness refresh unavailable; retaining prior per-game evidence: \(error.localizedDescription, privacy: .public)")
                packageErrors[game.id] = "The installation couldn't be checked. Try again."
            }
            return
        }
        unavailableDriveIDs.subtract([game.id])
        unavailableDriveIDs.formUnion(result.5)
        for id in result.5 {
            installationStatuses[id] = nil
            installationErrors[id] = Self.driveUnavailableMessage
            nativeInspectionDates[id] = nil
        }
        let nativeComplete = Set(installationStatuses.filter { $0.value.status == .complete }.map(\.key))
            .intersection(result.7)
        let candidateBlocked = Set(games.filter {
            NativeCandidateLaunchCatalogue.issue(productID: $0.storeId,
                evidence: MacGameEvidenceStore.shared.games[$0.storeId]) != nil
        }.map(\.id))
        launchableIDs.remove(game.id)
        launchableIDs.formUnion(result.0.union(nativeComplete).intersection([game.id]).subtracting(candidateBlocked))
        packageErrors[game.id] = result.3[game.id]
        placeholderIDs.remove(game.id)
        placeholderIDs.formUnion(result.4)
        var latestSaved: [InstalledGame]?
        for (id, detected) in result.2 where games.contains(where: { $0.id == id && $0.packageType != detected }) {
            do {
                guard let observed = entries.first(where: { $0.id == id }) else { continue }
                latestSaved = try await store.recordPackageType(id: id, type: detected,
                                                                observedAtImport: observed.importedAt)
            }
            catch { packageErrors[id] = "The detected package format couldn't be saved. Check Application Support access." }
        }
        if let latestSaved { applySavedGames(latestSaved) }
        for (id, volume) in result.6 {
            guard let observed = entries.first(where: { $0.id == id }) else { return }
            do {
                applySavedGames(try await store.recordStorageVolume(id: id, volume: volume,
                                                                   observedAtImport: observed.importedAt))
            } catch { packageErrors[id] = "The game drive information couldn't be saved. Check Application Support access." }
        }
        for index in games.indices where games[index].publisher == nil {
            games[index].publisher = result.1[games[index].id]
        }
    }

    nonisolated static let driveUnavailableMessage =
        "This game's drive is unavailable. Reconnect the drive, then check again. Its library entry and recorded location are kept."
}
