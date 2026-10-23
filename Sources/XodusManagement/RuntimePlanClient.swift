// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import XodusCore

public enum RuntimePlanningError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration, invalidPlan, unavailable, timedOut, cancelled, transportFailed, shutdownFailed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Check the declared component versions, hashes and sources. No runtime was inspected or changed."
        case .invalidPlan:
            "The engine returned an invalid configuration plan. Update the paired engine; no plan was accepted."
        case .unavailable:
            "Configuration planning is unavailable in this engine. Choose a trusted build that supports runtime-plan."
        case .timedOut:
            "The configuration plan did not finish in time. No runtime was inspected or changed."
        case .cancelled:
            "Configuration planning was cancelled. No runtime was inspected or changed."
        case .transportFailed:
            "The configuration request could not reach the selected engine. No plan was accepted."
        case .shutdownFailed:
            "The planning process has not stopped. Another planning process was not started."
        }
    }
}

public struct RuntimePlanContract: Sendable {
    public static let maximumInputBytes = 16_384
    public static let maximumOutputBytes = 32_768
    private let validator: ContractValidator

    public init() throws {
        guard let url = Bundle.module.url(forResource: "runtime-providers-v1.schema", withExtension: "json") else {
            throw RuntimePlanningError.unavailable
        }
        validator = try ContractValidator(schemaURL: url,
                                         schemaIdentifier: "urn:xodus:runtime-provider-configuration:1")
    }

    public func request(_ configuration: RuntimeProviderConfiguration) throws -> Data {
        do {
            let data = try JSONEncoder().encode(configuration)
            let value = try JSONValue.decodeUnique(data, maximumBytes: Self.maximumInputBytes)
            try validator.validate(value, definition: "configuration")
            return data
        } catch { throw RuntimePlanningError.invalidConfiguration }
    }

    public func response(_ data: Data, requested: RuntimeProviderConfiguration) throws -> RuntimeConfigurationPlan {
        do {
            guard data.last == 10, data.count <= Self.maximumOutputBytes,
                  !data.dropLast().contains(10), !data.contains(13) else { throw RuntimePlanningError.invalidPlan }
            _ = try request(requested)
            let value = try JSONValue.decodeUnique(data, maximumBytes: Self.maximumOutputBytes)
            try validator.validate(value, definition: "plan")
            let plan = try value.decode(RuntimeConfigurationPlan.self)
            guard plan.configuration == requested,
                  plan.prefixRelativePath == "runtime-prefixes/v1/\(try requested.identity())/\(plan.generationID)" else {
                throw RuntimePlanningError.invalidPlan
            }
            return plan
        } catch { throw RuntimePlanningError.invalidPlan }
    }
}

/// One owned, pure runtime-plan subprocess. This never starts the management/authentication route.
public actor RuntimePlanClient {
    private var child: Process?
    public var hasOwnedProcess: Bool { child?.isRunning == true }

    public init() {}

    public func closeOwnedProcess() async throws {
        guard let process = child else { return }
        try await stop(process)
        child = nil
    }

    public func plan(executable: URL, configuration: RuntimeProviderConfiguration,
                     timeoutSeconds: TimeInterval = 5,
                     executableIdentity: NativeAuthHostBinding? = nil) async throws -> RuntimeConfigurationPlan {
        guard child == nil else { throw RuntimePlanningError.shutdownFailed }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 30 else {
            throw RuntimePlanningError.invalidConfiguration
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        let contract = try RuntimePlanContract()
        let request = try contract.request(configuration)
        if Task.isCancelled { throw RuntimePlanningError.cancelled }
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RuntimePlanningError.unavailable
        }
        let process = Process()
        let input = Pipe(), output = Pipe(), diagnostic = Pipe()
        process.executableURL = executable
        process.arguments = ["runtime-plan"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostic
        let environment = ProcessInfo.processInfo.environment
        process.environment = environment.filter { ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL"].contains($0.key) }
        let handles = [input.fileHandleForWriting, output.fileHandleForReading, diagnostic.fileHandleForReading]
        do {
            for handle in handles {
                let flags = fcntl(handle.fileDescriptor, F_GETFL)
                guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw RuntimePlanningError.transportFailed
                }
            }
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw RuntimePlanningError.transportFailed
            }
            if let identity = executableIdentity {
                guard identity.executable == executable else { throw RuntimePlanningError.unavailable }
                _ = try identity.validatedArguments()
            }
            try process.run()
        } catch {
            try close(handles)
            throw RuntimePlanningError.unavailable
        }
        child = process
        var sent = 0, inputClosed = false, outputClosed = false, diagnosticClosed = false
        var response = Data(), diagnosticBytes = 0
        do {
            while !inputClosed || !outputClosed || !diagnosticClosed || process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw RuntimePlanningError.timedOut }
                if !inputClosed {
                    let written = request.withUnsafeBytes { bytes in
                        Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress?.advanced(by: sent),
                                     request.count - sent)
                    }
                    if written > 0 { sent += written }
                    else if written < 0 && errno != EAGAIN && errno != EINTR {
                        throw errno == EPIPE ? RuntimePlanningError.unavailable : RuntimePlanningError.transportFailed
                    }
                    if sent == request.count {
                        try input.fileHandleForWriting.close()
                        inputClosed = true
                    }
                }
                if !outputClosed {
                    let chunk = try read(output.fileHandleForReading)
                    outputClosed = chunk?.isEmpty == true
                    if let chunk {
                        guard response.count + chunk.count <= RuntimePlanContract.maximumOutputBytes else {
                            throw RuntimePlanningError.invalidPlan
                        }
                        response.append(chunk)
                    }
                }
                if !diagnosticClosed {
                    let chunk = try read(diagnostic.fileHandleForReading)
                    diagnosticClosed = chunk?.isEmpty == true
                    diagnosticBytes += chunk?.count ?? 0
                    guard diagnosticBytes <= 8_192 else { throw RuntimePlanningError.invalidPlan }
                }
                if !inputClosed || !outputClosed || !diagnosticClosed || process.isRunning {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            try Task.checkCancellation()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw RuntimePlanningError.unavailable
            }
            let plan = try contract.response(response, requested: configuration)
            try close([output.fileHandleForReading, diagnostic.fileHandleForReading])
            child = nil
            return plan
        } catch {
            let failure: RuntimePlanningError = error is CancellationError ? .cancelled
                : (error as? RuntimePlanningError ?? .transportFailed)
            response.removeAll()
            try await stop(process)
            try close(inputClosed ? [output.fileHandleForReading, diagnostic.fileHandleForReading] : handles)
            child = nil
            throw failure
        }
    }

    private func read(_ handle: FileHandle) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
        if count >= 0 { return Data(buffer.prefix(count)) }
        if errno == EAGAIN || errno == EINTR { return nil }
        throw RuntimePlanningError.transportFailed
    }

    private func close(_ handles: [FileHandle]) throws {
        var failed = false
        for handle in handles {
            if handle.fileDescriptor < 0 { continue }
            do { try handle.close() }
            catch { failed = true }
        }
        if failed { throw RuntimePlanningError.transportFailed }
    }

    private func stop(_ process: Process) async throws {
        if process.isRunning { process.terminate() }
        let graceful = ContinuousClock.now.advanced(by: .milliseconds(250))
        while process.isRunning && ContinuousClock.now < graceful {
            try await Task.detached { try await Task.sleep(for: .milliseconds(5)) }.value
        }
        if process.isRunning {
            guard kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else {
                throw RuntimePlanningError.shutdownFailed
            }
        }
        let reaped = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning && ContinuousClock.now < reaped {
            try await Task.detached { try await Task.sleep(for: .milliseconds(5)) }.value
        }
        guard !process.isRunning else { throw RuntimePlanningError.shutdownFailed }
    }
}
