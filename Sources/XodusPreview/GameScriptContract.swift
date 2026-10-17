// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

enum GameScriptCommand: String, Codable, Sendable {
    case serviceStatus, serviceSignIn, check, gamePassStatus, gameStats, stop, setup, install, uninstall
    case xboxCompanion = "xbox-companion"
    case xboxAchievements = "xbox-achievements"

    var file: String {
        switch self {
        case .serviceStatus: "private-xodus-service-status.sh"
        case .serviceSignIn: "private-xodus-service-signin.sh"
        case .check: "private-xodus-check.sh"
        case .gamePassStatus: "private-xodus-gamepass-status.sh"
        case .gameStats, .xboxCompanion, .xboxAchievements: "private-xodus-manage.py"
        case .stop: "private-xodus-stop.sh"
        case .setup: "private-xodus-setup.sh"
        case .install: "private-xodus-install.sh"
        case .uninstall: "private-xodus-uninstall.sh"
        }
    }
}

enum GameScriptError: Error, LocalizedError, Equatable {
    case unavailable, invalidReceipt, invalidProgress, storage, busy, timeout, invalidDestination, missingStatus, statusMismatch
    case failed(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "This Mac isn't ready for this game operation. Check Xodus setup and try again."
        case .invalidReceipt: "Xodus couldn't confirm how the operation finished. Your installed list wasn't changed. Check the log before trying again."
        case .missingStatus: "The operation stopped without a result. Your installed list wasn't changed. Check the log before trying again."
        case .statusMismatch: "The operation returned conflicting results. Your installed list wasn't changed. Check the log before trying again."
        case .invalidProgress: "Download progress couldn't be read. The operation is stopping; partial files are kept."
        case .storage: "Xodus couldn't save the operation details. Check access to Application Support and try again."
        case .busy: "Wait for the current game or operation to finish."
        case .timeout: "The operation didn't finish. Check the log before trying again."
        case .invalidDestination: "The game folder isn't safe to use. Choose a different installation or check Xodus setup."
        case .failed(let code):
            switch code {
            case 10: "There isn't enough free space. Free up storage and try again."
            case 11: "This account couldn't download the game. Check your game sign-in and subscription, then try again."
            case 12: "This game can't be installed with Xodus yet."
            case 13: "The download couldn't be verified. Try installing again."
            case 14: "Installation cancelled. Partial files are kept; installing again resumes the download."
            case 21: "Xodus couldn't find a running environment for this game. Check the log."
            case 22: "Quit the running game or finish the download first."
            case 31: "Xodus couldn't create the game environment. Check the log and try Repair Xodus again."
            default: "The operation couldn't finish (code \(code)). Check the log and try again."
            }
        }
    }
}

struct GameServiceStatus: Codable, Equatable, Sendable {
    let serviceRunning: Bool
    let signedIn: Bool
    let accountHash: String?

    static func parse(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard (value.serviceRunning || !value.signedIn),
              value.accountHash.map(XboxAccountBinding.valid) ?? true,
              value.signedIn || value.accountHash == nil else { throw GameScriptError.invalidReceipt }
        return value
    }
}

enum XboxAccountBinding {
    static func valid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct GameScriptProgress: Decodable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case preparing, downloading, verifying, configuring, done, failed

        var title: String {
            switch self {
            case .preparing: "Preparing download"
            case .downloading: "Downloading"
            case .verifying: "Verifying download"
            case .configuring: "Setting up game"
            case .done: "Finishing installation"
            case .failed: "Installation stopped"
            }
        }
    }
    let phase: Phase
    let bytesDone: Int64
    let bytesTotal: Int64?
    let message: String?

    static func parse(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.bytesDone >= 0, value.bytesTotal.map({ $0 >= value.bytesDone }) ?? true,
              value.message.map({
                  !$0.isEmpty && $0.utf8.count <= 4096 &&
                  !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
              }) ?? true else { throw GameScriptError.invalidProgress }
        return value
    }
}

struct GameInstallResult: Decodable, Sendable {
    let folder: String
    let launcher: String
    let storeId: String
}

struct GameCompatibilityResult: Decodable, Equatable, Sendable {
    let storeId: String
    let packageBytes: Int64?
    let supported: Bool
    let reason: String?
    let checkedAt: String

    var badge: String { supported ? "Available to install" : "Installation unavailable" }
    var explanation: String {
        supported ? "Available to install" : reason ?? "This game can't be installed with Xodus yet."
    }
    var checkedDate: Date? {
        Self.parseDate(checkedAt)
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func parse(_ data: Data, productID: String) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard PCGamesClient.validProductID(productID), value.storeId == productID,
              value.packageBytes.map({ $0 >= 0 }) ?? true, value.checkedAt.utf8.count <= 64,
              value.checkedDate != nil,
              value.reason.map({ !$0.isEmpty && $0.utf8.count <= 4096
                  && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }) ?? true else {
            throw GameScriptError.invalidReceipt
        }
        return value
    }
}

struct GamePassStatusResult: Decodable, Equatable, Sendable {
    let active: Bool?
    let probeProductId: String?
    let checkedAt: String?

    private enum CodingKeys: String, CodingKey { case active, probeProductId, checkedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        active = try values.decode(Bool?.self, forKey: .active)
        probeProductId = try values.decodeIfPresent(String.self, forKey: .probeProductId)
        checkedAt = try values.decodeIfPresent(String.self, forKey: .checkedAt)
    }

    static func parse(_ data: Data, productID: String? = nil) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.probeProductId.map(PCGamesClient.validProductID) ?? true,
              value.checkedAt.map({ $0.utf8.count <= 64 && GameCompatibilityResult.parseDate($0) != nil }) ?? true,
              productID.map({ PCGamesClient.validProductID($0) && value.probeProductId == $0
                  && value.checkedAt != nil }) ?? true else { throw GameScriptError.invalidReceipt }
        return value
    }
}

struct GameStopResult: Decodable, Sendable {
    let storeId: String
    let stopped: Bool

    static func parse(_ data: Data, productID: String) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard PCGamesClient.validProductID(productID), value.storeId == productID, value.stopped else {
            throw GameScriptError.invalidReceipt
        }
        return value
    }
}

struct GameScriptPaths: Sendable {
    let scripts: URL
    let processed: URL
    let logs: URL
    let games: URL
    let journal: URL
    var compatibility: URL { processed.deletingLastPathComponent().appendingPathComponent("compatibility") }
    var gamePassStatus: URL { compatibility.appendingPathComponent("gamepass.json") }
    var gameStats: URL { processed.deletingLastPathComponent().appendingPathComponent("game-stats.json") }
    var statsRefreshLedger: URL { journal.deletingLastPathComponent().appendingPathComponent("game-stats-refresh.json") }
    var xboxCompanion: URL { processed.deletingLastPathComponent().appendingPathComponent("xbox-companion.json") }
    var xboxAchievements: URL { processed.deletingLastPathComponent().appendingPathComponent("achievements") }
    var xboxCompanionRefreshLedger: URL {
        journal.deletingLastPathComponent().appendingPathComponent("xbox-companion-refresh.json")
    }

    func xboxAchievementsFile(titleID: String) throws -> URL {
        guard titleID.range(of: #"^[0-9]{1,10}$"#, options: .regularExpression)
                == titleID.startIndex..<titleID.endIndex else { throw GameScriptError.invalidReceipt }
        return xboxAchievements.appendingPathComponent(titleID + ".json")
    }

    func compatibilityFile(productID: String) throws -> URL {
        guard PCGamesClient.validProductID(productID) else { throw GameScriptError.invalidReceipt }
        return compatibility.appendingPathComponent(productID + ".json")
    }

    static var production: Self {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return Self(scripts: home.appendingPathComponent("Library/Application Support/Xodus/Runtime/scripts/macos"),
                    processed: home.appendingPathComponent("Library/Application Support/XodusRemote/processed"),
                    logs: home.appendingPathComponent("Library/Logs/XodusRemote"),
                    games: home.appendingPathComponent("Games/Xodus"),
                    journal: home.appendingPathComponent("Library/Application Support/Xodus/game-operation.json"))
    }

    static func validRunID(_ value: String) -> Bool {
        value.range(of: #"^xodus-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"#, options: .regularExpression)
            == value.startIndex..<value.endIndex
    }

    func receipt(_ runID: String, suffix: String) throws -> URL {
        guard Self.validRunID(runID), ["status", "result.json", "progress.json"].contains(suffix) else {
            throw GameScriptError.invalidReceipt
        }
        return processed.appendingPathComponent(runID + "." + suffix)
    }

    func destination(title: String, productID: String) throws -> URL {
        guard PCGamesClient.validProductID(productID) else { throw GameScriptError.invalidDestination }
        let safeTitle = String(title.unicodeScalars.filter {
            (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value)
        }.prefix(96))
        guard !safeTitle.isEmpty else { throw GameScriptError.invalidDestination }
        return games.appendingPathComponent(safeTitle + "-Xbox", isDirectory: true)
    }
}

enum GameScriptFiles {
    static func writePrivate(_ data: Data, to file: URL) throws {
        let parent = file.deletingLastPathComponent()
        try checkPath(parent, allowMissing: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(parent.path, 0o700) == 0,
              data.count <= 64 * 1024 else { throw GameScriptError.storage }
        let tmp = parent.appendingPathComponent(".private-write-\(UUID().uuidString).json")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GameScriptError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0 else { throw GameScriptError.storage }
            try handle.close()
            guard rename(tmp.path, file.path) == 0 else { throw GameScriptError.storage }
        } catch {
            handle.closeFile()
            if unlink(tmp.path) != 0 && errno != ENOENT { throw GameScriptError.storage }
            throw error
        }
    }

    static func checkPath(_ url: URL, allowMissing: Bool = false) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("."),
              !url.pathComponents.contains(".."), url.path != "/" else { throw GameScriptError.invalidDestination }
        var current = ""
        for part in url.pathComponents.dropFirst() {
            current += "/" + part
            var info = stat()
            if lstat(current, &info) != 0 {
                if errno == ENOENT, allowMissing { return }
                throw GameScriptError.invalidDestination
            }
            guard info.st_mode & S_IFMT != S_IFLNK else { throw GameScriptError.invalidDestination }
        }
    }

    static func read(_ url: URL, maximumBytes: Int = 64 * 1024, missingAllowed: Bool = false) throws -> Data? {
        try checkPath(url.deletingLastPathComponent(), allowMissing: missingAllowed)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT, missingAllowed { return nil }
        guard fd >= 0 else { throw GameScriptError.invalidReceipt }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { handle.closeFile() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= maximumBytes,
              let data = try handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else {
            throw GameScriptError.invalidReceipt
        }
        return data
    }

    static func script(_ command: GameScriptCommand, paths: GameScriptPaths) throws -> URL {
        let url = paths.scripts.appendingPathComponent(command.file)
        do { try checkPath(url) }
        catch { throw GameScriptError.unavailable }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw GameScriptError.unavailable
        }
        return url
    }

    static func status(_ data: Data) throws -> Int {
        guard let text = String(data: data, encoding: .utf8) else { throw GameScriptError.invalidReceipt }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
              let code = Int(trimmed), (0...255).contains(code) else { throw GameScriptError.invalidReceipt }
        return code
    }

    static func log(runID: String, paths: GameScriptPaths) -> URL? {
        guard let url = InstalledGamesController.sessionLog(runID: runID, directory: paths.logs),
              (try? checkPath(url)) != nil else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() else { return nil }
        return url
    }

    static func availableSpace(for destination: URL) throws -> Int64 {
        try checkPath(destination, allowMissing: true)
        var parent = destination
        while !FileManager.default.fileExists(atPath: parent.path) {
            guard parent.path != "/" else { throw GameScriptError.invalidDestination }
            parent.deleteLastPathComponent()
        }
        let values = try FileManager.default.attributesOfFileSystem(forPath: parent.path)
        guard let bytes = values[.systemFreeSize] as? NSNumber, bytes.int64Value >= 0 else {
            throw GameScriptError.invalidDestination
        }
        return bytes.int64Value
    }
}

struct GameScriptOutcome: Sendable {
    let code: Int
    let result: Data?
    let log: URL?
}

actor GameScriptRunner {
    let paths: GameScriptPaths
    private var process: Process?
    private var activeRunID: String?
    private var cancellationRequested = false
    private var pendingCancellation: String?

    init(paths: GameScriptPaths = .production) { self.paths = paths }

    func cancel(runID: String) {
        guard GameScriptPaths.validRunID(runID) else { return }
        if activeRunID == nil { pendingCancellation = runID; return }
        guard activeRunID == runID else { return }
        cancellationRequested = true
        if let process, process.isRunning { process.terminate() }
    }

    func run(command: GameScriptCommand, runID: String, arguments: [String] = [],
             progress: @escaping @Sendable (GameScriptProgress) async -> Void = { _ in }) async throws -> GameScriptOutcome {
        guard activeRunID == nil else { throw GameScriptError.busy }
        guard GameScriptPaths.validRunID(runID) else { throw GameScriptError.invalidReceipt }
        if command == .install || command == .uninstall {
            guard arguments.count == 2, PCGamesClient.validProductID(arguments[0]),
                  arguments[1].hasPrefix("/"), arguments[1] != "/",
                  !arguments[1].split(separator: "/").contains(".."),
                  !arguments[1].split(separator: "/").contains("."),
                  command != .uninstall || arguments[1].hasPrefix(paths.games.path + "/") else {
                throw GameScriptError.invalidDestination
            }
            try GameScriptFiles.checkPath(URL(fileURLWithPath: arguments[1]), allowMissing: command == .install)
        } else if command == .setup {
            guard arguments.count == 1, ["check", "repair"].contains(arguments[0]) else {
                throw GameScriptError.invalidReceipt
            }
        } else if [.check, .gamePassStatus, .stop].contains(command) {
            guard arguments.count == 1, PCGamesClient.validProductID(arguments[0]) else {
                throw GameScriptError.invalidReceipt
            }
        } else if command == .xboxAchievements {
            guard arguments.count == 1,
                  arguments[0].range(of: #"^[0-9]{1,10}$"#, options: .regularExpression)
                    == arguments[0].startIndex..<arguments[0].endIndex else {
                throw GameScriptError.invalidReceipt
            }
        } else {
            guard arguments.isEmpty else { throw GameScriptError.invalidReceipt }
        }
        activeRunID = runID
        cancellationRequested = pendingCancellation == runID
        pendingCancellation = nil
        defer { activeRunID = nil; process = nil }
        if cancellationRequested, [.install, .check, .gameStats, .xboxCompanion, .xboxAchievements].contains(command) {
            return GameScriptOutcome(code: 14, result: nil, log: nil)
        }
        let script = try GameScriptFiles.script(command, paths: paths)
        for suffix in ["status", "result.json", "progress.json"] {
            guard !FileManager.default.fileExists(atPath: try paths.receipt(runID, suffix: suffix).path) else {
                throw GameScriptError.invalidReceipt
            }
        }
        let env = InstalledGamesController.launchEnvironment(ProcessInfo.processInfo.environment)
        let child = try await Task.detached(priority: .userInitiated) {
            let child = Process()
            let managed = [.gameStats, .xboxCompanion, .xboxAchievements].contains(command)
            child.executableURL = managed ? script : URL(fileURLWithPath: "/bin/bash")
            let operation = command == .gameStats ? "game-stats" : command.rawValue
            child.arguments = managed ? [operation, runID] + arguments : [script.path, runID] + arguments
            child.environment = env
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            return child
        }.value
        process = child
        if cancellationRequested, child.isRunning { child.terminate() }
        let deadline = ContinuousClock.now.advanced(by: command == .serviceStatus ? .seconds(30)
            : [.check, .gamePassStatus, .gameStats, .xboxCompanion, .xboxAchievements,
               .stop, .setup].contains(command) ? .seconds(120) : .seconds(1800))
        var lastProgress: GameScriptProgress?
        var observationError: GameScriptError?
        while child.isRunning {
            if command == .install, observationError == nil {
                do {
                    if let data = try GameScriptFiles.read(paths.receipt(runID, suffix: "progress.json"), missingAllowed: true) {
                        let value = try GameScriptProgress.parse(data)
                        if value != lastProgress { await progress(value); lastProgress = value }
                    }
                } catch {
                    observationError = .invalidProgress
                    if child.isRunning { child.terminate() }
                }
            }
            if [.serviceStatus, .serviceSignIn, .check, .gamePassStatus, .gameStats,
                .xboxCompanion, .xboxAchievements, .stop, .setup].contains(command) {
                if ContinuousClock.now >= deadline, observationError == nil {
                    observationError = .timeout
                    if child.isRunning { child.terminate() }
                }
            }
            // Cancellation or a bounded observation failure terminates only this owned child.
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch {
                if child.isRunning { child.terminate() }
                // Join the owned child even when its observing task is cancelled.
                await Task.detached { child.waitUntilExit() }.value
                throw error
            }
        }
        guard let data = try GameScriptFiles.read(paths.receipt(runID, suffix: "status"), maximumBytes: 32,
                                                 missingAllowed: true) else {
            throw GameScriptError.missingStatus
        }
        let code = try GameScriptFiles.status(data)
        guard Int(child.terminationStatus) == code else { throw GameScriptError.statusMismatch }
        if let observationError { throw observationError }
        if command == .install, code != 0,
           let data = try GameScriptFiles.read(paths.receipt(runID, suffix: "progress.json"), missingAllowed: true) {
            let value = try GameScriptProgress.parse(data)
            if value.phase == .failed { await progress(value) }
        }
        let result = code == 0 && [.install, .serviceStatus, .check, .gamePassStatus, .gameStats,
                                   .xboxCompanion, .xboxAchievements, .stop, .setup].contains(command)
            ? try GameScriptFiles.read(paths.receipt(runID, suffix: "result.json")) : nil
        return GameScriptOutcome(code: code, result: result, log: GameScriptFiles.log(runID: runID, paths: paths))
    }
}

struct GameOperationRecord: Codable, Identifiable, Sendable {
    enum Kind: String, Codable { case install, repair, uninstall }
    let id: String
    let kind: Kind
    let productID: String
    let title: String
    let destination: String
    let installedID: UUID?

    func validate() throws {
        guard GameScriptPaths.validRunID(id), PCGamesClient.validProductID(productID),
              !title.isEmpty, title.utf8.count <= 4096, destination.hasPrefix("/"), destination != "/",
              destination.utf8.count <= 4096, !destination.split(separator: "/").contains(".."),
              !destination.split(separator: "/").contains("."),
              kind == .install ? installedID == nil : installedID != nil else { throw GameScriptError.storage }
    }
}

actor GameOperationJournal {
    private let file: URL
    init(file: URL) { self.file = file }

    func load() throws -> GameOperationRecord? {
        guard let data = try GameScriptFiles.read(file, missingAllowed: true) else { return nil }
        let record = try JSONDecoder().decode(GameOperationRecord.self, from: data)
        try record.validate()
        return record
    }

    func save(_ record: GameOperationRecord) throws {
        try record.validate()
        try GameScriptFiles.writePrivate(JSONEncoder().encode(record), to: file)
    }

    func clear() throws {
        if unlink(file.path) != 0 && errno != ENOENT { throw GameScriptError.storage }
    }
}
