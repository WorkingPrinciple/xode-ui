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
    @Published private(set) var discoveryError: String?
    @Published private(set) var runningGameID: UUID?
    @Published private(set) var playState: InstalledGamePlayState?
    @Published private(set) var playErrors: [UUID: String] = [:]
    @Published private(set) var historyError: String?
    @Published private(set) var packageErrors: [UUID: String] = [:]
    @Published private(set) var checkingInstallations = Set<UUID>()
    @Published private(set) var installationStatuses: [UUID: NativeInstallationStatus] = [:]
    @Published private(set) var installationErrors: [UUID: String] = [:]
    @Published private(set) var playLogs: [UUID: URL] = [:]
    @Published private(set) var playNotices: [UUID: String] = [:]
    @Published private(set) var stoppingGameID: UUID?
    @Published private(set) var launchStarted = false
    @Published private(set) var launchableIDs: Set<UUID> = []
    @Published private(set) var placeholderIDs: Set<UUID> = []
    @Published private(set) var mutationGameID: UUID?
    @Published private(set) var mutationActive = false
    /// Per-game update availability, recomputed from installed versions vs. `availableVersions`.
    @Published private(set) var updateStatuses: [UUID: UpdateStatus] = [:]
    /// Available package versions keyed by store id. Integration point for the catalog /
    /// package-type + engine-routing workstream (M1/M3); set via `applyAvailableVersions`.
    @Published private(set) var availableVersions: [String: String] = [:]
    @Published var serviceSignInActive = false
    @Published var runtimeRepairActive = false
    @Published var accountDisconnecting = false
    @Published private(set) var accountAccessAllowed = false
    @Published private(set) var accountAccessMessage = "Reconnect Xbox services to play this game."
    var applicationTerminating = false {
        didSet {
            if applicationTerminating {
                productAccess.retire()
                foregroundHandoff?.cancel()
                for task in nativeInspectionTasks.values { task.cancel() }
            }
        }
    }
    private let store: InstalledGameStore
    private let launchingDuration: Duration
    private let defaultEngine: @Sendable () -> RuntimeProviderKind?
    private let detectAvailability: @Sendable () async -> RunnerAvailability
    private let inspectPackage: @Sendable (URL) throws -> PackageType
    private let compatibilityCatalogue: OfflineGameCompatibility?
    private weak var unifiedSession: LiveSession?
    private var usesUnifiedAccount = false
    private let nativeLauncher = NativeGameLifecycle()
    private var nativeLaunchTask: Task<Void, Never>?
    private var nativeForegroundTask: Task<Void, Never>?
    private var nativeInspectionTasks: [UUID: Task<NativeInstallationStatus, Error>] = [:]
    private var nativeInspectionDates: [UUID: ContinuousClock.Instant] = [:]
    private var playingTask: Task<Void, Never>?
    private var runToken: UUID?
    private var stopToken: UUID?
    private var inspectionGeneration = UUID()
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
         compatibilityCatalogue: OfflineGameCompatibility? = OfflineGameCompatibility.snapshot) {
        self.store = store
        self.launchingDuration = launchingDuration
        self.logDirectory = logDirectory
        self.defaultEngine = defaultEngine
        self.detectAvailability = detectAvailability
        self.inspectPackage = inspectPackage
        self.compatibilityCatalogue = compatibilityCatalogue
    }

    func load() async {
        guard !loading, !editing, !choosing, !loaded, !applicationTerminating else { return }
        loading = true
        defer { loading = false }
        do {
            games = try await store.load()
            loaded = true
            error = nil
            await refreshLaunchableGames()
        } catch { self.error = InstalledGameError.invalidRegistry.localizedDescription }
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
        guard usesUnifiedAccount, loaded, !editing, !choosing, !mutationActive,
              !accountDisconnecting, !applicationTerminating else { return }
        let directory = root ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Games/Xodus")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            let folders = try await Task.detached {
                try GameScriptFiles.checkPath(directory)
                let children = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                guard children.count <= 512 else { throw InstalledGameError.invalidRegistry }
                return children.filter {
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("MicrosoftGame.config").path)
                }
            }.value
            guard !editing, !choosing, !mutationActive, !accountDisconnecting,
                  !applicationTerminating else { return }
            let pending = folders.filter { folder in !games.contains(where: { $0.folder == folder.path }) }
            guard !pending.isEmpty else { return }
            editing = true
            defer { editing = false }
            var failures: [String] = []
            for folder in pending {
                do { try await saveValidatedGame(folder: folder, launcher: nil, expectedStoreID: nil) }
                catch { failures.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
            }
            discoveryError = failures.isEmpty ? nil : "Some installed folders couldn't be imported. " + failures.joined(separator: " ")
        } catch {
            discoveryError = "Installed folders under \(directory.path) couldn't be read. \(error.localizedDescription)"
        }
    }

    func remove(_ game: InstalledGame) async {
        guard loaded, !editing, !choosing, !mutationActive, !accountDisconnecting, !applicationTerminating, runningGameID != game.id else { return }
        editing = true
        inspectionGeneration = UUID()
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

    func suspendAccountView() {
        guard runningGameID == nil, stoppingGameID == nil, !mutationActive else { return }
        games = []
        launchableIDs = []
        placeholderIDs = []
        updateStatuses = [:]
        playErrors = [:]
        playLogs = [:]
        playNotices = [:]
        packageErrors = [:]
        for task in nativeInspectionTasks.values { task.cancel() }
        installationStatuses = [:]
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
        guard historicalFixture || (game.engineOverride ?? defaultEngine()) == .calimocho else {
            playErrors[game.id] = NativeLaunchError.providerPolicy.localizedDescription
            return
        }
        if usesUnifiedAccount {
            await playNative(game)
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

    func refreshNativeInstallationStatuses() async {
        guard loaded, !editing, !choosing, !mutationActive, !accountDisconnecting,
              !applicationTerminating, runningGameID == nil, stoppingGameID == nil,
              unifiedSession?.nativeInstallStatusConfiguration != nil else { return }
        for game in games where requiresNativeInstallationStatus(game) {
            guard !Task.isCancelled, !mutationActive, !editing, runningGameID == nil,
                  !applicationTerminating else { return }
            let ttl: Duration = installationStatuses[game.id]?.status == .complete ? .seconds(120) : .seconds(15)
            if let last = nativeInspectionDates[game.id], ContinuousClock.now < last.advanced(by: ttl) { continue }
            _ = await inspectNativeInstallation(game)
        }
    }

    private func inspectNativeInstallation(_ game: InstalledGame) async -> NativeInstallationStatus? {
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
        guard let configuration = unifiedSession?.nativeInstallStatusConfiguration else {
            installationErrors[game.id] = "The verified local service isn't connected. Reconnect Ode to X and check again."
            return nil
        }
        guard nativeInspectionTasks.count < 2, loaded, !mutationActive, !applicationTerminating,
              games.contains(game) else {
            installationErrors[game.id] = "Wait for the current installation check or operation, then try again."
            return nil
        }
        let query = NativeInstallationQuery()
        let task = Task {
            try await query.run(configuration: configuration, product: game.storeId,
                                gameDirectory: URL(fileURLWithPath: game.folder))
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
            installationStatuses[game.id] = result
            installationErrors[game.id] = result.success ? nil : result.explanation
            nativeInspectionDates[game.id] = ContinuousClock.now
            if result.status == .complete && NativeCandidateLaunchCatalogue.issue(productID: game.storeId,
                evidence: MacGameEvidenceStore.shared.games[game.storeId]) == nil {
                launchableIDs.insert(game.id)
                packageErrors[game.id] = nil
            } else { launchableIDs.remove(game.id) }
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
        runningGameID = game.id
        playState = .launching
        launchStarted = false
        do {
            guard await inspectNativeInstallation(game)?.status == .complete else {
                throw NativeLaunchError.installationNotReady
            }
            let launch = try NativeLaunchConfiguration.resolve(game: game,
                provider: game.engineOverride ?? defaultEngine(),
                provenEngine: MacGameEvidenceStore.shared.games[game.storeId]?.provenEngine,
                evidence: MacGameEvidenceStore.shared.games[game.storeId])
            guard launch.admittedSelection != nil else { throw NativeLaunchError.providerPolicy }
            let arguments = try await launch.arguments()
            let prefixNotice = try await launch.prefixNotice()
            let executables = try MicrosoftGameConfig.read(folder: URL(fileURLWithPath: game.folder)).executables
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
                        engineSelection: launch.admittedSelection, onStarted: {
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
                    let playerMessage: String?
                    do {
                        playerMessage = try await result.playerMessage()
                    } catch {
                        playerMessage = "The launch log couldn't be read. Open its folder to review the error."
                        Self.launchLog.error("Player log read failed: \(error.localizedDescription, privacy: .public)")
                    }
                    guard runToken == token else { return }
                    recordSession(gameID: game.id, startedAt: startedAt,
                        seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                    finished(token: token, gameID: game.id, status: result.exitCode)
                    playLogs[game.id] = URL(fileURLWithPath: result.logDirectory)
                    if let playerMessage { playErrors[game.id] = playerMessage }
                    if !result.success && result.errorCode != "CANCELLED" {
                        playErrors[game.id] = playerMessage ?? result.failureMessage
                    }
                    if session.accountHash != account { playErrors[game.id] = "Your Xbox account changed during play." }
                } catch {
                    finished(token: token, gameID: game.id, status: 1)
                    playErrors[game.id] = (error as? GameScriptError)?.localizedDescription
                        ?? InstalledGameError.launch.localizedDescription
                    playLogs[game.id] = nativeLauncher.stateDirectory
                }
                nativeLaunchTask = nil
            }
        } catch {
            finished(token: token, gameID: game.id, status: 1)
            playErrors[game.id] = (error as? NativeLaunchError)?.localizedDescription
                ?? (error as? GameScriptError)?.localizedDescription ?? InstalledGameError.launch.localizedDescription
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

    func canStop(_ game: InstalledGame) -> Bool {
        loaded && !editing && !choosing && !mutationActive && !serviceSignInActive && !accountDisconnecting
            && !applicationTerminating && stoppingGameID == nil && runningGameID == game.id
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
        guard loaded, !editing, !choosing, !mutationActive, !accountDisconnecting,
              !applicationTerminating, runningGameID != game.id, games.contains(where: { $0.id == game.id }) else { return }
        if requiresNativeInstallationStatus(game) {
            _ = await inspectNativeInstallation(game)
            return
        }
        editing = true
        checkingInstallations.insert(game.id)
        defer { checkingInstallations.remove(game.id); editing = false }
        await refreshLaunchableGames()
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
        inspectionGeneration = UUID()
        defer { editing = false }
        do {
            let selection = override == .calimocho ? try AdmittedEngineSelection.read(defaults: .standard) : nil
            applySavedGames(try await store.setEngineOverride(id: game.id, override: override, selection: selection))
            error = nil
        } catch let failure as NativeLaunchError { self.error = failure.localizedDescription }
        catch { self.error = InstalledGameError.storage.localizedDescription }
    }

    func registerInstallation(folder: URL, launcher: URL, expectedStoreID: String) async throws {
        guard loaded, mutationActive, !editing, !applicationTerminating else { throw GameScriptError.busy }
        editing = true
        defer { editing = false }
        try await saveValidatedGame(folder: folder, launcher: launcher, expectedStoreID: expectedStoreID)
    }

    func registerNativeInstallation(folder: URL, expectedStoreID: String) async throws {
        guard loaded, mutationActive, !editing, !applicationTerminating else { throw GameScriptError.busy }
        editing = true
        defer { editing = false }
        try await saveValidatedGame(folder: folder, launcher: nil, expectedStoreID: expectedStoreID)
    }

    func removeUninstalled(_ id: UUID) async throws {
        guard mutationActive, mutationGameID == id, runningGameID != id, !editing else { throw GameScriptError.busy }
        editing = true
        inspectionGeneration = UUID()
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

    private func saveValidatedGame(folder: URL, launcher: URL?, expectedStoreID: String?) async throws {
        inspectionGeneration = UUID()
        let inspectPackage = inspectPackage
        let metadata = try await Task.detached(priority: .userInitiated) {
            let config = try MicrosoftGameConfig.read(folder: folder)
            if let launcher { try InstalledGameFiles.checkLauncher(launcher) }
            if let expectedStoreID, config.storeId != expectedStoreID { throw GameScriptError.invalidReceipt }
            return (config, try inspectPackage(folder))
        }.value
        let previous = games.first(where: { $0.folder == folder.path })
        guard previous?.id != runningGameID || runningGameID == nil else { throw GameScriptError.busy }
        let game = InstalledGame(id: previous?.id ?? UUID(),
            title: metadata.0.title, identityName: metadata.0.identityName, version: metadata.0.version,
            storeId: metadata.0.storeId, folder: folder.path, launcher: launcher?.path ?? "", importedAt: Date(),
            publisher: metadata.0.publisher, packageType: metadata.1,
            usesNativeLifecycle: launcher == nil ? true : nil)
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
        let generation = UUID()
        inspectionGeneration = generation
        let entries = games
        let inspectPackage = inspectPackage
        let nativeIDs = Set(entries.filter(requiresNativeInstallationStatus).map(\.id))
        let result = await Task.detached(priority: .utility) {
            var launchable: Set<UUID> = []
            var publishers: [UUID: String] = [:]
            var packageTypes: [UUID: PackageType] = [:]
            var failures: [UUID: String] = [:]
            var placeholders: Set<UUID> = []
            for game in entries {
                let folder = URL(fileURLWithPath: game.folder)
                if game.publisher == nil, let publisher = (try? MicrosoftGameConfig.read(folder: folder))?.publisher {
                    publishers[game.id] = publisher
                }
                do { packageTypes[game.id] = try inspectPackage(folder) }
                catch {
                    failures[game.id] = "Package format couldn't be inspected. Reconnect the game drive or reimport the game."
                }
                do {
                    try InstalledGameFiles.checkFolder(folder)
                    if game.usesNativeLifecycle != true {
                        try InstalledGameFiles.checkLauncher(URL(fileURLWithPath: game.launcher))
                    }
                    let config = try MicrosoftGameConfig.read(folder: folder)
                    guard config.storeId == game.storeId else { throw InstalledGameError.invalidConfig }
                    if nativeIDs.contains(game.id) { continue }
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
            return (launchable, publishers, packageTypes, failures, placeholders)
        }.value
        guard inspectionGeneration == generation, !applicationTerminating else { return }
        let nativeComplete = Set(installationStatuses.filter { $0.value.status == .complete }.map(\.key))
        let candidateBlocked = Set(games.filter {
            NativeCandidateLaunchCatalogue.issue(productID: $0.storeId,
                evidence: MacGameEvidenceStore.shared.games[$0.storeId]) != nil
        }.map(\.id))
        launchableIDs = result.0.union(nativeComplete).intersection(games.map(\.id)).subtracting(candidateBlocked)
        packageErrors = result.3
        placeholderIDs = result.4.intersection(games.map(\.id))
        var latestSaved: [InstalledGame]?
        for (id, detected) in result.2 where games.contains(where: { $0.id == id && $0.packageType != detected }) {
            guard inspectionGeneration == generation else { return }
            do {
                guard let observed = entries.first(where: { $0.id == id }) else { continue }
                latestSaved = try await store.recordPackageType(id: id, type: detected,
                                                                observedAtImport: observed.importedAt)
            }
            catch { packageErrors[id] = "The detected package format couldn't be saved. Check Application Support access." }
        }
        guard inspectionGeneration == generation else { return }
        if let latestSaved { applySavedGames(latestSaved) }
        for index in games.indices where games[index].publisher == nil {
            games[index].publisher = result.1[games[index].id]
        }
    }
}
