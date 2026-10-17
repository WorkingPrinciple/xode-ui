// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import XodusCore
import XodusManagement

enum InstalledGamePlayState: Equatable {
    case launching, playing
}

@MainActor
final class InstalledGamesController: ObservableObject {
    @Published private(set) var games: [InstalledGame] = []
    @Published private(set) var loading = false
    @Published private(set) var editing = false
    @Published private(set) var choosing = false
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var runningGameID: UUID?
    @Published private(set) var playState: InstalledGamePlayState?
    @Published private(set) var playErrors: [UUID: String] = [:]
    @Published private(set) var historyError: String?
    @Published private(set) var packageErrors: [UUID: String] = [:]
    @Published private(set) var playLogs: [UUID: URL] = [:]
    @Published private(set) var playNotices: [UUID: String] = [:]
    @Published private(set) var stoppingGameID: UUID?
    @Published private(set) var launchStarted = false
    @Published private(set) var launchableIDs: Set<UUID> = []
    @Published private(set) var mutationGameID: UUID?
    @Published private(set) var mutationActive = false
    /// Per-game update availability, recomputed from installed versions vs. `availableVersions`.
    @Published private(set) var updateStatuses: [UUID: UpdateStatus] = [:]
    /// Available package versions keyed by store id. Integration point for the catalog /
    /// package-type + engine-routing workstream (M1/M3); set via `applyAvailableVersions`.
    @Published private(set) var availableVersions: [String: String] = [:]
    @Published var serviceSignInActive = false
    @Published var runtimeRepairActive = false
    var applicationTerminating = false
    private let store: InstalledGameStore
    private let launchingDuration: Duration
    private let defaultEngine: @Sendable () -> RuntimeProviderKind?
    private let detectAvailability: @Sendable () async -> RunnerAvailability
    private let inspectPackage: @Sendable (URL) throws -> PackageType
    private var playingTask: Task<Void, Never>?
    private var runToken: UUID?
    private var stopToken: UUID?
    private var inspectionGeneration = UUID()
    private var stopConfirmed = false
    private var process: Process?
    private var sessionPersistence: Task<Void, Never>?
    private var runIDs: [UUID: String] = [:]
    private let logDirectory: URL

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
         inspectPackage: @escaping @Sendable (URL) throws -> PackageType = { try PackageInspector.detect(folder: $0) }) {
        self.store = store
        self.launchingDuration = launchingDuration
        self.logDirectory = logDirectory
        self.defaultEngine = defaultEngine
        self.detectAvailability = detectAvailability
        self.inspectPackage = inspectPackage
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
        guard loaded, !editing, !mutationActive, !applicationTerminating else { return }
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
        guard loaded, !editing, !choosing, !mutationActive, !applicationTerminating else { return }
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
        let scriptPanel = NSOpenPanel()
        scriptPanel.title = "Choose the launch script for this game"
        scriptPanel.message = "Use the Xodus launch script you already use for this game."
        scriptPanel.prompt = "Choose launch script"
        scriptPanel.canChooseDirectories = false
        scriptPanel.canChooseFiles = true
        scriptPanel.allowsMultipleSelection = false
        guard await scriptPanel.begin() == .OK, let launcher = scriptPanel.url else { return }
        await importGame(folder: folder, launcher: launcher)
    }

    func remove(_ game: InstalledGame) async {
        guard loaded, !editing, !choosing, !mutationActive, !applicationTerminating, runningGameID != game.id else { return }
        editing = true
        inspectionGeneration = UUID()
        defer { editing = false }
        do {
            let updated = try await store.remove(id: game.id)
            applySavedGames(updated)
            launchableIDs.remove(game.id)
            playErrors[game.id] = nil
            playLogs[game.id] = nil
            runIDs[game.id] = nil
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
                                              engine: RuntimeProviderKind? = nil) -> [String: String] {
        var environment = inherited.filter { ["HOME", "USER", "LANG"].contains($0.key) }
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // The resolved runner is passed to the launch script as an explicit, neutral
        // selector so the launch path consumes the routing decision, not config only.
        if let engine { environment["XODUS_ENGINE"] = engine.rawValue }
        return environment
    }

    static func engineUnavailableMessage(_ reason: EngineRoutingUnavailable) -> String {
        switch reason {
        case .overrideNotInstalled(let kind):
            "This game's selected engine (\(kind.label)) isn't installed or its runner isn't configured. Check its executable path in Engines, or clear the per-game override."
        case .defaultNotInstalled(let kind):
            "The default engine (\(kind.label)) isn't installed or its runner isn't configured. Check its executable path in Engines, or choose a different default."
        case .noRunnerInstalled:
            "No supported engine is installed. Set up CrossOver in Engines before launching."
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

    func play(_ game: InstalledGame) async {
        guard loaded, !editing, !choosing, runningGameID == nil, stoppingGameID == nil, !applicationTerminating,
              mutationGameID != game.id, !serviceSignInActive, !runtimeRepairActive,
              games.contains(game) else { return }
        let token = UUID()
        runToken = token
        runningGameID = game.id
        playState = .launching
        playErrors[game.id] = nil
        playLogs[game.id] = nil
        playNotices[game.id] = nil
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
        do {
            let environment = Self.launchEnvironment(ProcessInfo.processInfo.environment, engine: runner)
            let runID = Self.runID()
            runIDs[game.id] = runID
            let launcher = game.launcher
            let folder = game.folder
            let child = try await Task.detached(priority: .userInitiated) { [weak self] in
                try InstalledGameFiles.checkFolder(URL(fileURLWithPath: folder))
                try InstalledGameFiles.checkLauncher(URL(fileURLWithPath: launcher))
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

    @discardableResult private func finished(token: UUID, gameID: UUID, status: Int32) -> Bool {
        guard runToken == token else { return false }
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
        if status != 0 { playErrors[gameID] = "The game stopped unexpectedly (code \(status))." }
        return status != 0
    }

    func canStop(_ game: InstalledGame) -> Bool {
        loaded && !editing && !choosing && !mutationActive && !serviceSignInActive
            && !applicationTerminating && stoppingGameID == nil && runningGameID == game.id
            && launchStarted && process?.isRunning == true && games.contains(where: {
                $0.id == game.id && $0.storeId == game.storeId && $0.launcher == game.launcher
            })
    }

    func reserveStop(_ game: InstalledGame) throws -> UUID {
        guard canStop(game), let token = runToken else { throw GameScriptError.busy }
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

    func refreshAfterSetupRepair() async {
        guard mutationActive, runtimeRepairActive else { return }
        await refreshLaunchableGames()
    }

    func reserveMutation(gameID: UUID?) throws {
        guard loaded, !editing, !choosing, !mutationActive, !serviceSignInActive, !applicationTerminating,
              gameID == nil || runningGameID != gameID else { throw GameScriptError.busy }
        mutationActive = true
        mutationGameID = gameID
    }

    func releaseMutation() {
        mutationActive = false
        mutationGameID = nil
    }

    /// Persist (or clear with `nil`) a per-game engine override. Routing consumes
    /// this on the next launch; a selected-but-missing engine refuses launch.
    func setEngineOverride(_ override: RuntimeProviderKind?, for game: InstalledGame) async {
        guard loaded, !editing, !choosing, !mutationActive, !applicationTerminating,
              runningGameID != game.id, games.contains(where: { $0.id == game.id }) else { return }
        editing = true
        inspectionGeneration = UUID()
        defer { editing = false }
        do {
            applySavedGames(try await store.setEngineOverride(id: game.id, override: override))
            error = nil
        } catch { self.error = InstalledGameError.storage.localizedDescription }
    }

    func registerInstallation(folder: URL, launcher: URL, expectedStoreID: String) async throws {
        guard loaded, mutationActive, !editing, !applicationTerminating else { throw GameScriptError.busy }
        editing = true
        defer { editing = false }
        try await saveValidatedGame(folder: folder, launcher: launcher, expectedStoreID: expectedStoreID)
    }

    func removeUninstalled(_ id: UUID) async throws {
        guard mutationActive, mutationGameID == id, runningGameID != id, !editing else { throw GameScriptError.busy }
        editing = true
        inspectionGeneration = UUID()
        defer { editing = false }
        applySavedGames(try await store.remove(id: id))
        launchableIDs.remove(id)
        playErrors[id] = nil
        playLogs[id] = nil
        runIDs[id] = nil
    }

    private func saveValidatedGame(folder: URL, launcher: URL, expectedStoreID: String?) async throws {
        inspectionGeneration = UUID()
        let inspectPackage = inspectPackage
        let metadata = try await Task.detached(priority: .userInitiated) {
            let config = try MicrosoftGameConfig.read(folder: folder)
            try InstalledGameFiles.checkLauncher(launcher)
            if let expectedStoreID, config.storeId != expectedStoreID { throw GameScriptError.invalidReceipt }
            return (config, try inspectPackage(folder))
        }.value
        let previous = games.first(where: { $0.folder == folder.path })
        guard previous?.id != runningGameID || runningGameID == nil else { throw GameScriptError.busy }
        let game = InstalledGame(id: previous?.id ?? UUID(),
            title: metadata.0.title, identityName: metadata.0.identityName, version: metadata.0.version,
            storeId: metadata.0.storeId, folder: folder.path, launcher: launcher.path, importedAt: Date(),
            publisher: metadata.0.publisher, packageType: metadata.1)
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
        let result = await Task.detached(priority: .utility) {
            var launchable: Set<UUID> = []
            var publishers: [UUID: String] = [:]
            var packageTypes: [UUID: PackageType] = [:]
            var failures: [UUID: String] = [:]
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
                    try InstalledGameFiles.checkLauncher(URL(fileURLWithPath: game.launcher))
                    launchable.insert(game.id)
                } catch { continue }
            }
            return (launchable, publishers, packageTypes, failures)
        }.value
        guard inspectionGeneration == generation, !applicationTerminating else { return }
        launchableIDs = result.0.intersection(games.map(\.id))
        packageErrors = result.3
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
