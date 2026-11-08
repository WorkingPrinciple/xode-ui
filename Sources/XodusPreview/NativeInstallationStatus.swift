// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusManagement

struct NativeInstallationStatus: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case complete, partial, missing }
    enum Action: Equatable { case play, install, resume, repair, check }

    let version: Int
    let operation: String
    let product: String
    let runID: String
    let gameDirectory: String
    let logDirectory: String
    let resultPath: String
    let success: Bool
    let exitCode: Int32
    let errorCode: String?
    let status: Status?
    let reasonCode: String?
    let detail: String?
    let filesTotal: UInt64?
    let contentID: String?

    private enum CodingKeys: String, CodingKey {
        case version, operation, product, success, status, detail
        case runID = "run_id", gameDirectory = "game_dir", logDirectory = "log_dir"
        case resultPath = "result_path", exitCode = "exit_code", errorCode = "error_code"
        case reasonCode = "reason_code", filesTotal = "files_total", contentID = "content_id"
    }

    var action: Action {
        guard success else { return .check }
        return switch status {
        case .complete: .play
        case .missing: .install
        case .partial:
            ["MANIFEST_INVALID", "PRODUCT_MISMATCH", "PACKAGE_METADATA_INVALID"].contains(reasonCode ?? "")
                ? .repair : .resume
        case nil: .check
        }
    }

    var explanation: String? {
        if errorCode == "RESOURCE_BUSY" {
            return "This installation is in use. Wait for its current operation to finish, then check again."
        }
        if !success { return "The installation couldn't be checked. Try again or open its log." }
        return detail
    }

    func validate(product: String, gameDirectory: URL, stateDirectory: URL, exitCode: Int32) throws {
        guard version == 1, operation == "install-status", self.product == product,
              UUID(uuidString: runID) != nil, self.gameDirectory == gameDirectory.path,
              self.exitCode == exitCode, success == (exitCode == 0),
              success ? status != nil && errorCode == nil : status == nil && errorCode?.isEmpty == false,
              logDirectory == stateDirectory.appendingPathComponent("runs/\(runID)").path,
              resultPath == URL(fileURLWithPath: logDirectory).appendingPathComponent("result.json").path,
              errorCode.map({ $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true,
              detail.map({ $0.utf8.count <= 16_384 && !$0.utf8.contains(0) }) ?? true,
              reasonCode.map({ $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true,
              contentID.map({ $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true else {
            throw GameScriptError.invalidReceipt
        }
    }
}

@MainActor
final class NativeInstallationQuery {
    static let defaultTimeout: Duration = .seconds(120)
    private var process: Process?
    private let storageProbe: GameStorageProbe
    init(storageProbe: GameStorageProbe) { self.storageProbe = storageProbe }
    var isRunning: Bool { process?.isRunning == true }

    static func failureMessage(_ error: Error) -> String {
        if let error = error as? GameScriptError, case .timeout = error {
            return "Check is taking longer than expected. Try checking the installation again."
        }
        return "The installation couldn't be checked. \(error.localizedDescription)"
    }

    func run(configuration: BackendConfiguration, product: String, gameDirectory: URL,
             stateDirectory: URL? = nil, timeout: Duration = NativeInstallationQuery.defaultTimeout) async throws -> NativeInstallationStatus {
        guard process == nil, PCGamesClient.validProductID(product) else { throw GameScriptError.busy }
#if XODUS_SHIPPING
        guard configuration.executableIdentity != nil else { throw GameScriptError.runtimeUnavailable }
#endif
        try Task.checkCancellation()
        let state = stateDirectory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Xodus/InstallationStatus/\(InstalledGamesController.runID())",
                                   isDirectory: true)
        let child = Process()
        process = child
        defer { process = nil }
        let environment = InstalledGamesController.launchEnvironment(ProcessInfo.processInfo.environment)
        // Admission includes staging and receipt I/O as well as the inspector.
        // A cancelled waiter cannot release this reservation before child cleanup.
        do {
            return try await storageProbe.read(timeout: timeout + .seconds(30), key: gameDirectory.path) {
                try Self.inspect(child: child, configuration: configuration, product: product,
                    gameDirectory: gameDirectory, state: state, timeout: timeout, environment: environment)
            }
        } catch {
            if error is CancellationError {
                while child.isRunning {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
                }
            }
            throw error
        }
    }

    nonisolated private static func inspect(child: Process, configuration: BackendConfiguration,
                                           product: String, gameDirectory: URL, state: URL,
                                           timeout: Duration, environment: [String: String]) throws -> NativeInstallationStatus {
        try Task.checkCancellation()
        if let identity = configuration.executableIdentity {
            guard identity.executable == configuration.executable else { throw GameScriptError.runtimeUnavailable }
            _ = try identity.validatedArguments()
        }
        try GameScriptFiles.checkPath(gameDirectory, allowMissing: true)
        let outputURL = state.appendingPathComponent("stdout.json", isDirectory: false)
        let errorURL = state.appendingPathComponent("stderr.log", isDirectory: false)
        try GameScriptFiles.checkPath(state, allowMissing: true)
        guard state.path != gameDirectory.path, !state.path.hasPrefix(gameDirectory.path + "/"),
              !FileManager.default.fileExists(atPath: state.path) else { throw GameScriptError.invalidDestination }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        func removeUnstartedState() throws {
            for file in [outputURL, errorURL] {
                guard unlink(file.path) == 0 || errno == ENOENT else { throw GameScriptError.storage }
            }
            guard rmdir(state.path) == 0 || errno == ENOENT else { throw GameScriptError.storage }
        }
        let output: FileHandle
        let diagnostic: FileHandle
        do {
            try GameScriptFiles.writePrivate(Data(), to: outputURL)
            try Task.checkCancellation()
            try GameScriptFiles.writePrivate(Data(), to: errorURL)
            output = try FileHandle(forWritingTo: outputURL)
            do { diagnostic = try FileHandle(forWritingTo: errorURL) }
            catch { output.closeFile(); throw error }
        } catch {
            try removeUnstartedState()
            throw error
        }
        defer { output.closeFile() }
        defer { diagnostic.closeFile() }
        child.executableURL = configuration.executable
        child.arguments = ["install-status", product, "--game-dir", gameDirectory.path, "--state-dir", state.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = diagnostic
        child.environment = environment
        do {
            try Task.checkCancellation()
            try child.run()
        } catch {
            try removeUnstartedState()
            throw error
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while child.isRunning {
                guard ContinuousClock.now < deadline else { throw GameScriptError.timeout }
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.05)
            }
        } catch {
            if child.isRunning { child.terminate() }
            let grace = ContinuousClock.now.advanced(by: .seconds(2))
            while child.isRunning && ContinuousClock.now < grace {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            throw error
        }
        child.waitUntilExit()
        try Task.checkCancellation()
        let exitCode = child.terminationStatus
        try output.synchronize()
        let bytes = try InstalledGameFiles.readRegular(outputURL, maximumBytes: 1_048_576, privateFile: true)
        let value = try JSONDecoder().decode(NativeInstallationStatus.self, from: bytes)
        try value.validate(product: product, gameDirectory: gameDirectory, stateDirectory: state,
                           exitCode: exitCode)
        let resultURL = URL(fileURLWithPath: value.resultPath, isDirectory: false)
        try GameScriptFiles.checkPath(resultURL)
        let persisted = try InstalledGameFiles.readRegular(resultURL, maximumBytes: 1_048_576, privateFile: true)
        guard try JSONDecoder().decode(NativeInstallationStatus.self, from: persisted) == value else {
            throw GameScriptError.statusMismatch
        }
        return value
    }
}
