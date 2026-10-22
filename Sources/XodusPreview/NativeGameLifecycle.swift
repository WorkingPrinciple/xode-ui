// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusManagement

enum NativeLifecyclePins {
    static let cliSHA256 = "adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604"
}

struct NativeGameResult: Codable, Equatable, Sendable {
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

    private enum CodingKeys: String, CodingKey {
        case version, operation, product, success
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

    static let failureCodes: Set<String> = [
        "ACCOUNT_UNAVAILABLE", "ACCOUNT_MISMATCH", "ACCOUNT_CHANGED", "TIMEOUT", "CANCELLED", "OPERATION_FAILED",
        "RESOURCE_BUSY"
    ]

    var failureMessage: String {
        switch errorCode {
        case "ACCOUNT_UNAVAILABLE": "Your Xbox sign-in couldn't be read. Check Account and approve any macOS Keychain prompt."
        case "ACCOUNT_MISMATCH", "ACCOUNT_CHANGED": "Your Xbox account changed. Refresh your library before trying again."
        case "CANCELLED": "The operation was cancelled. Partial files are kept; you can retry the installation."
        case "TIMEOUT": "The game did not finish starting before the launch probe ended."
        case "RESOURCE_BUSY": "This installation is in use. Wait for its current operation to finish and try again."
        default: "The game operation failed. Open its log to review the cause before retrying."
        }
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

    mutating func consume(_ line: Data) throws {
        let event = try JSONDecoder().decode(Event.self, from: line)
        switch event.event {
        case "bytes":
            guard event.id != nil, let delta = event.delta_bytes, delta >= 0,
                  bytesDone <= Int64.max - delta else { throw GameScriptError.invalidProgress }
            if event.id != UInt64.max { bytesDone += delta }
            phase = .downloading
            if let total = bytesTotal, bytesDone > total { bytesTotal = nil }
        case "remaining":
            guard let remaining = event.remaining_bytes, remaining >= 0,
                  bytesDone <= Int64.max - remaining else { throw GameScriptError.invalidProgress }
            bytesTotal = bytesDone + remaining
        case "phase":
            guard let text = event.phase, !text.isEmpty else { throw GameScriptError.invalidProgress }
            phase = text.localizedCaseInsensitiveContains("verif") ? .verifying : .downloading
        case "file_started", "file_finished", "completed":
            break
        default:
            throw GameScriptError.invalidProgress
        }
    }

    var value: GameScriptProgress {
        GameScriptProgress(phase: phase, bytesDone: bytesDone, bytesTotal: bytesTotal, message: nil)
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
             onStarted: () -> Void = {},
             onProgress: (GameScriptProgress) -> Void = { _ in }) async throws -> NativeGameResult {
        guard !active, ["install", "repair", "uninstall", "launch"].contains(operation),
              XboxAccountBinding.valid(accountHash), PCGamesClient.validProductID(product),
              GameScriptPaths.validRunID(runID) else { throw GameScriptError.invalidReceipt }
        active = true
        cancellationRequested = false
        started = false
        defer { active = false }
#if XODUS_SHIPPING
        guard configuration.executableIdentity != nil else { throw GameScriptError.runtimeUnavailable }
#endif
        if let identity = configuration.executableIdentity {
            guard identity.executable == configuration.executable else { throw GameScriptError.runtimeUnavailable }
            _ = try await Task.detached { try identity.validatedArguments() }.value
        }
        guard !cancellationRequested, !Task.isCancelled else { throw GameScriptError.failed(14) }
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
        return try Self.readResult(state: state, operation: operation, product: product,
                                   gameDirectory: gameDirectory, exitCode: child.terminationStatus)
    }

    static func readResult(state: URL, operation: String, product: String,
                           gameDirectory: URL, exitCode: Int32? = nil) throws -> NativeGameResult {
        let bytes = try InstalledGameFiles.readRegular(state.appendingPathComponent("launcher-result.json"),
                                                       maximumBytes: 1_048_576, privateFile: true)
        let value = try JSONDecoder().decode(NativeGameResult.self, from: bytes)
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
