// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusManagement

struct NativeInstallationStatus: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case complete, partial, missing }
    enum Action: Equatable { case play, install, resume, repair, check, remove }

    /// REQ-141: the backend's repair verdicts. Repair-required offers Repair; an installation whose identity
    /// can't be proven offers Remove from Library (Keep Files) with the reason, never an endless Retry.
    static let repairRequiredCode = "INSTALL_REPAIR_REQUIRED"
    static let identityUnprovenCode = "INSTALL_IDENTITY_UNPROVEN"
    static let productMismatchCode = "INSTALL_PRODUCT_MISMATCH"
    static let productMismatchExplanation = "This folder holds a different game than the one in your library, so X Ode won't repair or play it. Remove it from the Library (its files are kept), then download the game again."
    static let repairRequiredExplanation = "This installation needs repair before it can be played. Use Repair; your saves aren't touched."
    static let identityUnprovenExplanation = "X Ode can't prove this folder holds your copy of the game, so it won't repair or play it. Remove it from the Library (its files are kept), then download the game again."

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
        let code = reasonCode ?? errorCode
        if code == Self.repairRequiredCode { return .repair }
        if code == Self.identityUnprovenCode || code == Self.productMismatchCode { return .remove }
        guard success else { return .check }
        return switch status {
        case .complete: .play
        case .missing: .install
        case .partial:
            reasonCode == "PRODUCT_MISMATCH" ? .remove
                : ["MANIFEST_INVALID", "PACKAGE_METADATA_INVALID"].contains(reasonCode ?? "") ? .repair : .resume
        case nil: .check
        }
    }

    var explanation: String? {
        if (reasonCode ?? errorCode) == Self.repairRequiredCode { return Self.repairRequiredExplanation }
        if (reasonCode ?? errorCode) == Self.identityUnprovenCode { return Self.identityUnprovenExplanation }
        if [Self.productMismatchCode, "PRODUCT_MISMATCH"].contains(reasonCode ?? errorCode ?? "") {
            return Self.productMismatchExplanation
        }
        if errorCode == "RESOURCE_BUSY" {
            return "This installation is in use. Wait for its current operation to finish, then check again."
        }
        if !success { return "The installation couldn't be checked. Try again." }
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
    static let largeInstallTimeout: Duration = .seconds(900)
    private var process: Process?
    private let storageProbe = GameStorageProbe()
    var isRunning: Bool { process?.isRunning == true }

    static func failureMessage(_ error: Error) -> String {
        if let error = error as? GameScriptError, case .timeout = error {
            return "Check is taking longer than expected. Try checking the installation again."
        }
        return "The installation couldn't be checked. \(error.localizedDescription)"
    }

    func run(configuration: BackendConfiguration, product: String, gameDirectory: URL,
             stateDirectory: URL? = nil, timeout: Duration = NativeInstallationQuery.defaultTimeout,
             storageProbe: GameStorageProbe? = nil) async throws -> NativeInstallationStatus {
        guard process == nil, PCGamesClient.validProductID(product) else { throw GameScriptError.busy }
#if XODUS_SHIPPING
        guard configuration.executableIdentity != nil else { throw GameScriptError.runtimeUnavailable }
#endif
        if let identity = configuration.executableIdentity {
            guard identity.executable == configuration.executable else { throw GameScriptError.runtimeUnavailable }
            _ = try await Task.detached { try identity.validatedArguments() }.value
        }
        try Task.checkCancellation()
        try await (storageProbe ?? self.storageProbe).read {
            try GameScriptFiles.checkPath(gameDirectory, allowMissing: true)
        }
        let state = stateDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Xodus/InstallationStatus/\(InstalledGamesController.runID())")
        try GameScriptFiles.checkPath(state, allowMissing: true)
        guard state.path != gameDirectory.path, !state.path.hasPrefix(gameDirectory.path + "/"),
              !FileManager.default.fileExists(atPath: state.path) else { throw GameScriptError.invalidDestination }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let outputURL = state.appendingPathComponent("stdout.json")
        let errorURL = state.appendingPathComponent("stderr.log")
        try GameScriptFiles.writePrivate(Data(), to: outputURL)
        try GameScriptFiles.writePrivate(Data(), to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let diagnostic = try FileHandle(forWritingTo: errorURL)
        defer { output.closeFile(); diagnostic.closeFile(); process = nil }
        let child = Process()
        child.executableURL = configuration.executable
        child.arguments = ["install-status", product, "--game-dir", gameDirectory.path, "--state-dir", state.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = diagnostic
        child.environment = InstalledGamesController.launchEnvironment(ProcessInfo.processInfo.environment)
        process = child
        try child.run()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while child.isRunning {
                guard ContinuousClock.now < deadline else { throw GameScriptError.timeout }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if child.isRunning { child.terminate() }
            let grace = ContinuousClock.now.advanced(by: .seconds(2))
            while child.isRunning && ContinuousClock.now < grace {
                await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            await Task.detached { child.waitUntilExit() }.value
            throw error
        }
        child.waitUntilExit()
        try output.synchronize()
        let bytes = try InstalledGameFiles.readRegular(outputURL, maximumBytes: 1_048_576, privateFile: true)
        let value = try JSONDecoder().decode(NativeInstallationStatus.self, from: bytes)
        try value.validate(product: product, gameDirectory: gameDirectory, stateDirectory: state,
                           exitCode: child.terminationStatus)
        try GameScriptFiles.checkPath(URL(fileURLWithPath: value.resultPath))
        let persisted = try InstalledGameFiles.readRegular(URL(fileURLWithPath: value.resultPath),
                                                          maximumBytes: 1_048_576, privateFile: true)
        guard try JSONDecoder().decode(NativeInstallationStatus.self, from: persisted) == value else {
            throw GameScriptError.statusMismatch
        }
        return value
    }
}
