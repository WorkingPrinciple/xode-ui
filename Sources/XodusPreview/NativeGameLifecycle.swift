// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import OSLog
import XodusManagement

enum NativeLifecyclePins {
    static let cliSHA256 = "33820b8f4acd0395b1e0aa1811880f21b29c4ba7ce583be98378a5f455e5c973"
}

struct NativeGameResult: Codable, Equatable, Sendable {
    struct Warning: Codable, Equatable, Sendable {
        let code: String
        let message: String
    }
    struct DownloadResume: Codable, Equatable, Sendable {
        let mode: String
        let message: String?
        var restartsFromZero: Bool { mode == "restart_incomplete_from_zero" }
    }
    let version: Int
    let runID: String
    let operation: String
    let product: String
    let success: Bool
    let exitCode: Int32
    let errorCode: String?
    let gameDirectory: String
    let logDirectory: String
    let resultPath: String
    let progressPath: String
    var error: String? = nil
    var popupMonitorError: String? = nil
    var warnings: [Warning]? = nil
    var wineExitCode: Int32? = nil
    var wineTerminationSignal: Int32? = nil
    var downloadResume: DownloadResume? = nil
    var titleRecipe: NativeTitleRecipeReceipt? = nil

    private enum CodingKeys: String, CodingKey {
        case version, operation, product, success, error, warnings
        case downloadResume = "download_resume"
        case titleRecipe = "title_recipe"
        case popupMonitorError = "popup_monitor_error"
        case wineExitCode = "wine_exit_code", wineTerminationSignal = "wine_termination_signal"
        case runID = "run_id", exitCode = "exit_code", errorCode = "error_code"
        case gameDirectory = "game_dir", logDirectory = "log_dir"
        case resultPath = "result_path", progressPath = "progress_path"
    }

    func validate(operation: String, product: String, gameDirectory: URL,
                  stateDirectory: URL, exitCode: Int32) throws {
        guard version == 1, UUID(uuidString: runID) != nil,
              self.operation == operation, self.product == product,
              self.gameDirectory == gameDirectory.path,
              self.exitCode == exitCode, success == (exitCode == 0),
              success ? errorCode == nil : Self.failureCodes.contains(errorCode ?? ""),
              logDirectory == stateDirectory.appendingPathComponent("runs/\(runID)").path,
              resultPath == URL(fileURLWithPath: logDirectory).appendingPathComponent("result.json").path,
              progressPath == URL(fileURLWithPath: logDirectory).appendingPathComponent("progress.jsonl").path else {
            throw GameScriptError.invalidReceipt
        }
    }

    static let failureCodes: Set<String> = Set<String>([
        "ACCOUNT_UNAVAILABLE", "ACCOUNT_MISMATCH", "ACCOUNT_CHANGED", "TIMEOUT", "CANCELLED", "OPERATION_FAILED",
        "RESOURCE_BUSY", "DISK_SPACE_FLOOR", "DISK_SPACE_FLOOR_INVALID",
        "UNINSTALL_PERMISSION_DENIED", "UNINSTALL_NOT_A_GAME", "UNINSTALL_UNSAFE_TREE", "UNINSTALL_FAILED",
        "PREFIX_MISSING_RESTORE_REQUIRED", "TITLE_RECIPE_REJECTED", "TITLE_RECIPE_REQUIRED"
    ]).union(installVerdictCodes).union(launchPreflightCodes)

    /// Review fc2f17d1 H1 (REQ-141): producer #7's installation verdicts arrive as a lifecycle error_code. They
    /// are ordinary failures that point at Repair or Remove; they never put the app into recovery.
    static let installVerdictCodes: Set<String> = [
        NativeInstallationStatus.repairRequiredCode, NativeInstallationStatus.identityUnprovenCode,
        NativeInstallationStatus.productMismatchCode
    ]

    /// L15 COR-318 (producer #8) and L12 REQ-151: a launch refused before Wine starts. Each is an ordinary
    /// receipt with its own explanation; none puts the app into recovery.
    static let launchPreflightCodes: Set<String> = [
        "PREFIX_OS_UNSUPPORTED", "PREFIX_OS_TOO_OLD", "PREFIX_OS_UNREADABLE",
        "PACKAGE_OS_REQUIREMENT_INVALID", "PACKAGE_COMMAND_LINE_INVALID",
        "RUNTIME_CAPABILITY_MISSING", "EXECUTABLE_AMBIGUOUS",
        "COMPATIBILITY_BLOCKED", "COMPATIBILITY_DB_INVALID", "GENERIC_PREFIX_REQUIRED",
        // Producer #11 (REQ-164): game prerequisites and the CrossOver bottle, all refused before the game starts.
        "PREREQUISITE_PREFIX_UNOWNED", "PREREQUISITE_INSTALLER_UNAVAILABLE", "PREREQUISITE_INSTALLER_MISMATCH",
        "PREREQUISITE_INSTALL_FAILED", "PREREQUISITE_LAYOUT_INVALID",
        "CROSSOVER_BOTTLE_ENVIRONMENT_CONFLICT", "CROSSOVER_BOTTLE_REGISTRY_CONFLICT", "CROSSOVER_BOTTLE_IN_USE",
        "PREFIX_PROFILE_INCOMPLETE"
    ]

    var preflightMessage: String? {
        switch success ? nil : errorCode {
        case "PREFIX_OS_TOO_OLD":
            "This game needs a newer Windows version than its Wine prefix reports, so it wasn't started. Nothing was changed. Choose an engine that supports it; the game then gets a new prefix."
        case "PREFIX_OS_UNSUPPORTED":
            "This game needs a newer Windows version than the selected engine can provide, so it wasn't started. Nothing was changed. Choose another engine, or update X Ode when one becomes available."
        case "PREFIX_OS_UNREADABLE":
            "X Ode couldn't read which Windows version this game's prefix reports, so the game wasn't started. Nothing was changed. Open the launch log for details."
        case "PACKAGE_OS_REQUIREMENT_INVALID", "PACKAGE_COMMAND_LINE_INVALID":
            "This game's package information is damaged, so it wasn't started. Nothing was changed. Repair the installation, then play again."
        case "RUNTIME_CAPABILITY_MISSING":
            "This game needs a newer runtime than this version of X Ode includes, so it wasn't started. Update X Ode to play this game. Use Copy Diagnostics to share the details."
        case "PREREQUISITE_PREFIX_UNOWNED":
            "This game needs a Windows component installed in a prefix X Ode manages, and this prefix isn't one, so the game wasn't started. Nothing was changed."
        case "PREREQUISITE_INSTALLER_UNAVAILABLE":
            "A Windows component this game needs couldn't be downloaded, so the game wasn't started. Check your connection, then play again."
        case "PREREQUISITE_INSTALLER_MISMATCH":
            "The Windows component this game needs didn't match its verified download, so it wasn't installed and the game wasn't started."
        case "PREREQUISITE_INSTALL_FAILED", "PREREQUISITE_LAYOUT_INVALID":
            "A Windows component this game needs couldn't be set up in its prefix, so the game wasn't started. Use Copy Diagnostics and send them to support."
        case "CROSSOVER_BOTTLE_ENVIRONMENT_CONFLICT", "CROSSOVER_BOTTLE_REGISTRY_CONFLICT":
            "This game's CrossOver bottle has settings that conflict with the verified setup, so the game wasn't started. Nothing was changed."
        case "CROSSOVER_BOTTLE_IN_USE":
            "This game's CrossOver bottle is in use by another program. Close it in CrossOver, then play again."
        case "PREFIX_PROFILE_INCOMPLETE":
            "This game's prefix isn't fully set up for the selected engine, so the game wasn't started. Nothing was changed. Use Copy Diagnostics and send them to support."
        case "COMPATIBILITY_BLOCKED":
            "This game can't run in X Ode yet (for example, it uses anti-cheat or isn't a supported package), so it wasn't started. Nothing was changed."
        case "COMPATIBILITY_DB_INVALID":
            "X Ode's game compatibility list couldn't be verified, so the game wasn't started. Nothing was changed. Update X Ode, then try again."
        case "GENERIC_PREFIX_REQUIRED":
            "This engine choice needs a separate prefix that X Ode couldn't prepare, so the game wasn't started and its existing prefix and saves weren't touched. Use Copy Diagnostics and send them to support."
        case "EXECUTABLE_AMBIGUOUS":
            "This game's package lists more than one program, and X Ode can't tell which one to start, so the game wasn't started. Nothing was changed."
        default: nil
        }
    }

    var installVerdict: NativeInstallationStatus.Action? {
        guard !success, let errorCode, Self.installVerdictCodes.contains(errorCode) else { return nil }
        return errorCode == NativeInstallationStatus.repairRequiredCode ? .repair : .remove
    }

    /// The backend refused uninstall because the folder no longer proves it is this installed game.
    var damagedInstallation: Bool { !success && errorCode == "UNINSTALL_NOT_A_GAME" }

    var failureMessage: String {
        if let verdict = installVerdictMessage { return verdict }
        if let preflight = preflightMessage { return preflight }
        if operation == "launch" { return InstalledGameActionCopy.launchUnavailable }
        return operationFailureMessage
    }

    func installationFailureMessage() async -> String {
        guard !success, operation != "launch", errorCode == "OPERATION_FAILED" else { return failureMessage }
        let diagnosticURL = URL(fileURLWithPath: logDirectory).appendingPathComponent("stderr.log")
        do {
            let diagnostic = try await Task.detached {
                try GameScriptFiles.checkPath(diagnosticURL)
                let data = try InstalledGameFiles.readRegular(diagnosticURL, maximumBytes: 4_194_304)
                return String(decoding: data, as: UTF8.self)
            }.value
            return NativeDiskSpaceFailure.parse(diagnostic)?.message ?? failureMessage
        } catch {
            Logger(subsystem: "io.github.dragoshont.xodus", category: "GameOperation")
                .error("Optional installation diagnostic unavailable or rejected for run \(runID, privacy: .public); retaining backend failure")
            return failureMessage
        }
    }

    private var operationFailureMessage: String {
        switch errorCode {
        case "ACCOUNT_UNAVAILABLE": "Your Xbox sign-in couldn't be read. Check Account and approve any macOS Keychain prompt."
        case "ACCOUNT_MISMATCH", "ACCOUNT_CHANGED": "Your Xbox account changed. Refresh your library before trying again."
        case "CANCELLED": "The operation was stopped. Downloading again will start over."
        case "TIMEOUT":
            operation == "launch"
                ? "The launcher took too long and was stopped before a playable game appeared. Open the launch log to see what happened."
                : "The \(operation) operation took too long. Check its log before trying again; completion wasn't confirmed."
        case "RESOURCE_BUSY": "This installation is in use. Wait for its current operation to finish and try again."
        case "DISK_SPACE_FLOOR": "There isn't enough free space to continue safely. Free space on the installation drive before retrying."
        case "DISK_SPACE_FLOOR_INVALID": "The free-space limit is invalid. Check the operation log before retrying."
        case "UNINSTALL_PERMISSION_DENIED":
            "Nothing was deleted. macOS denied write access to files in \(gameDirectory). Check that folder's permissions in Finder, then try again."
        case "UNINSTALL_NOT_A_GAME":
            "This folder no longer looks like an installed game, so it wasn't deleted. Repair the installation, or remove it from the Library and keep its files."
        case "UNINSTALL_UNSAFE_TREE":
            "Nothing was deleted because the game folder contains links or special files. Review \(gameDirectory) in Finder, or remove it from the Library and keep its files."
        case "UNINSTALL_FAILED":
            "The game folder couldn't be fully deleted. Some files in \(gameDirectory) may remain. Check it in Finder, or remove the game from the Library and keep its files."
        default: "The game operation failed. Open its log to review the cause before retrying."
        }
    }

    struct NativeDiskSpaceFailure: Equatable, Sendable {
        let requiredBytes: Int64
        let availableBytes: Int64
        var code: String { "DISK_SPACE" }
        var message: String {
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return "Not enough space. This installation needs \(required); \(available) is available. Free space on the installation drive, then download again. The download will start over."
        }

        static func parse(_ diagnostic: String) -> Self? {
            for line in diagnostic.split(whereSeparator: \.isNewline) {
                let prefix = "Streaming failed: not enough free disk space: need "
                guard line.hasPrefix(prefix), line.hasSuffix(" bytes") else { continue }
                let counts = line.dropFirst(prefix.count).dropLast(" bytes".count)
                    .components(separatedBy: " bytes, have ")
                guard counts.count == 2,
                      counts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                      let required = Int64(counts[0]), let available = Int64(counts[1]),
                      required > available else { continue }
                return Self(requiredBytes: required, availableBytes: available)
            }
            return nil
        }
    }

    var installVerdictMessage: String? {
        switch success ? nil : errorCode {
        case NativeInstallationStatus.repairRequiredCode: NativeInstallationStatus.repairRequiredExplanation
        case NativeInstallationStatus.identityUnprovenCode: NativeInstallationStatus.identityUnprovenExplanation
        case NativeInstallationStatus.productMismatchCode: NativeInstallationStatus.productMismatchExplanation
        default: nil
        }
    }

    func launchFailureMessage(stoppedByUser: Bool) -> String? {
        guard operation == "launch" else { return success ? nil : failureMessage }
        if let verdict = installVerdictMessage { return verdict }
        if let preflight = preflightMessage { return preflight }
        if stoppedByUser, errorCode == "CANCELLED" || errorCode == "OPERATION_FAILED" { return nil }
        if errorCode == "OPERATION_FAILED", error == "Account broker did not shut down cleanly",
           wineExitCode == 0, wineTerminationSignal == nil { return nil }
        if !success, errorCode == "PREFIX_MISSING_RESTORE_REQUIRED"
            || (error ?? "").hasPrefix("PREFIX_MISSING_RESTORE_REQUIRED:") {
            return NativePrefixCopy.missingRestoreRequired
        }
        if !success, errorCode == "TITLE_RECIPE_REQUIRED" || (error ?? "").hasPrefix("TITLE_RECIPE_REQUIRED") {
            return InstalledGameActionCopy.titleRecipeRequired
        }
        return success ? nil : InstalledGameActionCopy.launchUnavailable
    }

    func playerMessage() async throws -> String? {
        let log = URL(fileURLWithPath: logDirectory)
        let observations = try await Task.detached {
            func readIfBounded(_ name: String) throws -> Data? {
                let path = log.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: path.path) else { return nil }
                try GameScriptFiles.checkPath(path)
                let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 4_194_304 else { return nil }
                if size == 0 { return Data() }
                return try InstalledGameFiles.readRegular(path, maximumBytes: 4_194_304)
            }
            let diagnostic = try readIfBounded("stderr.log").map { String(decoding: $0, as: UTF8.self) } ?? ""
            let windows = try readIfBounded("windows.jsonl")
            let recorded: Bool?
            if let windows {
                struct Window: Decodable { let dialog: Bool; let title: String }
                let events = try windows.split(separator: 10).map { try JSONDecoder().decode(Window.self, from: Data($0)) }
                recorded = events.contains { !$0.dialog && !$0.title.isEmpty }
            } else { recorded = nil }
            return (diagnostic, recorded)
        }.value
        return NativePlayerFailure.message(errorCode: errorCode, error: error,
            diagnostic: observations.0, windowRecorded: observations.1,
            monitorReliable: popupMonitorError == nil && (warnings ?? []).isEmpty,
            success: success)
    }
}

enum NativeLifecycleCancellation: Error {
    case launchStopped

    static func check(operation: String, cancelled: Bool) throws {
        guard cancelled else { return }
        if operation == "launch" { throw Self.launchStopped }
        throw GameScriptError.failed(14)
    }
}

/// REQ-46: a game's Wine prefix is gone but its owner record survives, so its saves may be lost.
enum NativePrefixCopy {
    static let missingRestoreRequired = "This game's Wine prefix is missing, so the game wasn't started. Its saves may have been in it. Restore the prefix folder from your backup to the same place, then play again. \(AppBrand.displayName) didn't create a new one, because a new prefix wouldn't bring your saves back. Nothing was changed."
}

enum NativePlayerFailure {
    static func message(errorCode: String?, error: String?, diagnostic: String,
                        windowRecorded: Bool?, monitorReliable: Bool, success: Bool) -> String? {
        if errorCode == "TIMEOUT" {
            return "The launcher took too long and was stopped before a playable game appeared. Open the launch log to see what happened."
        }
        if errorCode == "PREFIX_MISSING_RESTORE_REQUIRED"
            || (error ?? "").hasPrefix("PREFIX_MISSING_RESTORE_REQUIRED:") {
            return NativePrefixCopy.missingRestoreRequired
        }
        guard errorCode == nil || errorCode == "OPERATION_FAILED" else { return nil }
        let text = (error ?? "") + "\n" + diagnostic
        if !success, (text.contains("err:module:import_dll Library") && text.contains("not found")
            || text.contains("Library not loaded:") || text.contains("runtime DLL not found")) {
            return "A required runtime component couldn't be loaded. Open the launch log to see its name. No repair has been applied."
        }
        if monitorReliable, windowRecorded == false {
            return "The game closed before \(AppBrand.displayName) detected its window. Open the launch log to review the exit."
        }
        return nil
    }
}

struct NativeGameProgress {
    private struct Event: Decodable {
        let event: String
        let id: UInt64?
        let delta_bytes: Int64?
        let remaining_bytes: Int64?
        let phase: String?
    }
    private(set) var bytesDone: Int64 = 0
    private(set) var bytesTotal: Int64?
    private(set) var phase: GameScriptProgress.Phase = .preparing
    private var readingPackage = false

    mutating func consume(_ line: Data) throws {
        let event = try JSONDecoder().decode(Event.self, from: line)
        switch event.event {
        case "bytes":
            guard event.id != nil, let delta = event.delta_bytes, delta >= 0,
                  bytesDone <= Int64.max - delta else { throw GameScriptError.invalidProgress }
            if event.id == UInt64.max {
                readingPackage = true
            } else {
                bytesDone += delta
                phase = .downloading
            }
            if let total = bytesTotal, bytesDone > total { bytesTotal = nil }
        case "remaining":
            guard let remaining = event.remaining_bytes, remaining >= 0,
                  bytesDone <= Int64.max - remaining else { throw GameScriptError.invalidProgress }
            bytesTotal = bytesDone + remaining
        case "phase":
            guard let text = event.phase, !text.isEmpty else { throw GameScriptError.invalidProgress }
            if text.localizedCaseInsensitiveContains("verif") { phase = .verifying }
            else if bytesDone > 0 { phase = .downloading }
        case "file_started":
            if let id = event.id, id != UInt64.max { phase = .downloading }
        case "file_finished", "completed":
            break
        default:
            throw GameScriptError.invalidProgress
        }
    }

    var value: GameScriptProgress {
        GameScriptProgress(phase: phase, bytesDone: bytesDone, bytesTotal: bytesTotal,
                           message: phase == .preparing && readingPackage ? "Reading package" : nil)
    }
}

@MainActor
final class NativeGameLifecycle {
    private var process: Process?
    private var progressFile: FileHandle?
    private var pending = Data()
    private var progress = NativeGameProgress()
    private var active = false
    private var cancellationRequested = false
    private(set) var started = false
    private(set) var stateDirectory: URL?
    private(set) var completedResult: NativeGameResult?
    var isRunning: Bool { process?.isRunning == true }
    var processIdentifier: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    static func directory(runID: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/Xodus/Lifecycle/\(runID)", isDirectory: true)
    }

    func run(configuration: BackendConfiguration, accountHash: String, operation: String,
             product: String, gameDirectory: URL, runID: String,
             stateRoot: URL? = nil, launchArguments: [String] = [],
             launchEnvironment: [String: String] = [:],
             unsetLaunchEnvironment: [String] = [],
             engineSelection: AdmittedEngineSelection? = nil,
             prepareAdmittedPrefix: () async throws -> Void = {},
             onStarted: () -> Void = {},
             onProgress: (GameScriptProgress) -> Void = { _ in }) async throws -> NativeGameResult {
        guard !active, ["install", "repair", "uninstall", "launch"].contains(operation),
              XboxAccountBinding.valid(accountHash), PCGamesClient.validProductID(product),
              GameScriptPaths.validRunID(runID) else { throw GameScriptError.invalidReceipt }
        active = true
        cancellationRequested = false
        started = false
        completedResult = nil
        stateDirectory = nil
        defer { active = false }
#if XODUS_SHIPPING
        guard configuration.executableIdentity != nil else { throw GameScriptError.runtimeUnavailable }
#endif
        if let identity = configuration.executableIdentity {
            guard identity.executable == configuration.executable else { throw GameScriptError.runtimeUnavailable }
            _ = try await Task.detached { try identity.validatedArguments() }.value
        }
        try NativeLifecycleCancellation.check(operation: operation,
            cancelled: cancellationRequested || Task.isCancelled)
        if operation == "launch", product == NativeFH6Recipe.productID,
           !launchArguments.contains("--expected-registry-sha256") {
            throw NativeLaunchError.titleRecipeUnavailable
        }
        if launchArguments.contains("--expected-registry-sha256") {
            try await EngineInspectionClient().validateLaunch(configuration: configuration,
                arguments: launchArguments, selection: engineSelection, product: product)
            try NativeLifecycleCancellation.check(operation: operation,
                cancelled: cancellationRequested || Task.isCancelled)
            if operation == "launch" {
                try await prepareAdmittedPrefix()
                try NativeLifecycleCancellation.check(operation: operation,
                    cancelled: cancellationRequested || Task.isCancelled)
            }
        }
        try GameScriptFiles.checkPath(gameDirectory, allowMissing: operation == "install")
        let state = stateRoot ?? Self.directory(runID: runID)
        try GameScriptFiles.checkPath(state, allowMissing: true)
        guard !FileManager.default.fileExists(atPath: state.path) else { throw GameScriptError.invalidDestination }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        stateDirectory = state
        progress = NativeGameProgress()
        pending = Data()
        let outputURL = state.appendingPathComponent("launcher-result.json")
        let diagnosticURL = state.appendingPathComponent("launcher-stderr.log")
        try GameScriptFiles.writePrivate(Data(), to: outputURL)
        try GameScriptFiles.writePrivate(Data(), to: diagnosticURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let diagnostic = try FileHandle(forWritingTo: diagnosticURL)
        defer {
            output.closeFile()
            diagnostic.closeFile()
            progressFile?.closeFile()
            progressFile = nil
            process = nil
        }
        let child = Process()
        child.executableURL = configuration.executable
        child.arguments = [operation, product, "--game-dir", gameDirectory.path,
                           "--state-dir", state.path, "--account-hash", accountHash,
                           "--allow-keychain-prompt"] + launchArguments
        var environment = InstalledGamesController.launchEnvironment(ProcessInfo.processInfo.environment)
        for key in unsetLaunchEnvironment { environment.removeValue(forKey: key) }
        child.environment = environment.merging(launchEnvironment) { _, selected in selected }
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = diagnostic
        process = child
        try child.run()
        started = true
        // Lets a relaunched app find and verify this exact backend if the app is force quit.
        try? GameScriptFiles.writePrivate(Data("\(child.processIdentifier)\n".utf8),
                                          to: state.appendingPathComponent(NativeOrphanRun.pidFileName))
        onStarted()
        do {
            while child.isRunning {
                try readProgress(state: state, onProgress: onProgress)
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            if child.isRunning { child.terminate() }
            // Join the CLI's owned-child cleanup, even if the caller was cancelled.
            while child.isRunning {
                await Task.detached { try? await Task.sleep(for: .milliseconds(150)) }.value
            }
            throw error
        }
        child.waitUntilExit()
        while try readProgress(state: state, onProgress: onProgress) {}
        guard pending.isEmpty else { throw GameScriptError.invalidProgress }
        try output.synchronize()
        let result = try Self.readResult(state: state, operation: operation, product: product,
                                        gameDirectory: gameDirectory, exitCode: child.terminationStatus)
        if launchArguments.contains("--title-recipe"), result.success {
            guard product == NativeFH6Recipe.productID, let receipt = result.titleRecipe,
                  let engineSelection,
                  receipt.registrySha256 == engineSelection.inspection.registrySha256,
                  let prefixIndex = launchArguments.firstIndex(of: "--prefix"), prefixIndex + 1 < launchArguments.count,
                  receipt.destinationPath == URL(fileURLWithPath: launchArguments[prefixIndex + 1])
                    .appendingPathComponent(NativeFH6Recipe.overlayDestination).path else {
                throw GameScriptError.invalidReceipt
            }
            let registry = try NativeEngineRegistry.read(URL(fileURLWithPath: engineSelection.registryPath))
            guard let entry = registry.engines.first(where: { $0.name == NativeFH6Recipe.engineName }),
                  receipt.sourcePath == URL(fileURLWithPath: entry.wine).deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent(NativeFH6Recipe.overlaySource).path else {
                throw GameScriptError.invalidReceipt
            }
        } else if !launchArguments.contains("--title-recipe"), result.titleRecipe != nil {
            throw GameScriptError.invalidReceipt
        }
        completedResult = result
        try NativeLifecycleCancellation.check(operation: operation,
            cancelled: cancellationRequested || Task.isCancelled)
        return result
    }

    static func readResult(state: URL, operation: String, product: String,
                           gameDirectory: URL, exitCode: Int32? = nil) throws -> NativeGameResult {
        let bytes = try InstalledGameFiles.readRegular(state.appendingPathComponent("launcher-result.json"),
                                                       maximumBytes: 1_048_576, privateFile: true)
        let value = try JSONDecoder().decode(NativeGameResult.self, from: bytes)
        let document = try JSONValue.decodeUnique(bytes, maximumBytes: 1_048_576)
        if document["title_recipe"] != nil, value.titleRecipe == nil { throw GameScriptError.invalidReceipt }
        if let receipt = value.titleRecipe {
            guard operation == "launch", product == NativeFH6Recipe.productID else {
                throw GameScriptError.invalidReceipt
            }
            guard let titleReceipt = document["title_recipe"] else { throw GameScriptError.invalidReceipt }
            try NativeTitleRecipeReceipt.validateShape(titleReceipt, includesPath: true)
            try receipt.validate(logDirectory: value.logDirectory)
            guard let path = receipt.receiptPath else { throw GameScriptError.invalidReceipt }
            try GameScriptFiles.checkPath(URL(fileURLWithPath: path))
            let file = try InstalledGameFiles.readRegular(URL(fileURLWithPath: path), maximumBytes: 32_768, privateFile: true)
            let json = try JSONValue.decodeUnique(file, maximumBytes: 32_768)
            try NativeTitleRecipeReceipt.validateShape(json, includesPath: false)
            var persistedReceipt = try json.decode(NativeTitleRecipeReceipt.self)
            persistedReceipt.receiptPath = path
            guard persistedReceipt == receipt else { throw GameScriptError.statusMismatch }
        }
        try value.validate(operation: operation, product: product, gameDirectory: gameDirectory,
                           stateDirectory: state, exitCode: exitCode ?? value.exitCode)
        try GameScriptFiles.checkPath(URL(fileURLWithPath: value.resultPath))
        let persisted = try InstalledGameFiles.readRegular(URL(fileURLWithPath: value.resultPath),
                                                          maximumBytes: 1_048_576, privateFile: true)
        guard try JSONDecoder().decode(NativeGameResult.self, from: persisted) == value else {
            throw GameScriptError.statusMismatch
        }
        return value
    }

    func cancel() {
        cancellationRequested = true
        if let process, process.isRunning { process.terminate() }
    }

    /// Follows the progress of a run started by a previous app process. Never spawns or signals.
    func follow(state: URL, onProgress: (GameScriptProgress) -> Void) throws {
        guard !active else { return }
        while try readProgress(state: state, onProgress: onProgress) {}
    }

    func endFollow() {
        guard !active else { return }
        progressFile?.closeFile()
        progressFile = nil
        pending = Data()
        progress = NativeGameProgress()
    }

    @discardableResult
    private func readProgress(state: URL, onProgress: (GameScriptProgress) -> Void) throws -> Bool {
        if progressFile == nil {
            let runs = state.appendingPathComponent("runs")
            guard FileManager.default.fileExists(atPath: runs.path) else { return false }
            try GameScriptFiles.checkPath(runs)
            let entries = try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)
            guard entries.count <= 1 else { throw GameScriptError.invalidReceipt }
            guard let run = entries.first, UUID(uuidString: run.lastPathComponent) != nil else { return false }
            let path = run.appendingPathComponent("progress.jsonl")
            guard FileManager.default.fileExists(atPath: path.path) else { return false }
            try GameScriptFiles.checkPath(path)
            let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw GameScriptError.invalidProgress }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
                close(descriptor)
                throw GameScriptError.invalidProgress
            }
            progressFile = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        guard let data = try progressFile?.read(upToCount: 262_144), !data.isEmpty else { return false }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: newline)
            guard line.count <= 65_536 else { throw GameScriptError.invalidProgress }
            if !line.isEmpty {
                try progress.consume(Data(line))
                onProgress(progress.value)
            }
            pending.removeSubrange(...newline)
        }
        guard pending.count <= 65_536 else { throw GameScriptError.invalidProgress }
        return true
    }
}
