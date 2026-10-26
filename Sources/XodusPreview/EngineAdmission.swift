// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusManagement

enum EngineInspectionError: Error, LocalizedError {
    case unsupported, invalidResponse, failed, timedOut, shutdownFailed
    case rejected(EngineInspection.Failure)

    var errorDescription: String? {
        switch self {
        case .unsupported: "This app engine does not support provider inspection. Generic Wine settings remain available."
        case .invalidResponse: "Provider inspection returned inconsistent evidence. No provider was admitted."
        case .failed: "The engine record could not be verified. Refresh or choose a different registry."
        case .timedOut: "Provider inspection timed out. Retry Refresh; no engine was selected."
        case .shutdownFailed: "Provider inspection has not stopped. Quit the app before retrying."
        case .rejected(let failure):
            "Calimocho verification failed (\(failure.code)): \(failure.message). Refresh the registry in Engines and explicitly select the verified build again. No game was started or other engine substituted."
        }
    }
}

struct EngineInspection: Codable, Equatable, Sendable {
    struct Failure: Codable, Equatable, Sendable { let code: String; let message: String }
    let schemaVersion: Int
    let capability: String
    let registrySha256: String?
    let engineName: String?
    let declaredProvider: String?
    let admittedProvider: String?
    let admission: String?
    let ready: Bool
    let qualified: Bool
    let wineSha256: String?
    let wineserverSha256: String?
    let error: Failure?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, capability, registrySha256, engineName, declaredProvider, admittedProvider
        case admission, ready, qualified, wineSha256, wineserverSha256, error
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(capability, forKey: .capability)
        try values.encode(registrySha256, forKey: .registrySha256)
        try values.encode(engineName, forKey: .engineName)
        try values.encode(declaredProvider, forKey: .declaredProvider)
        try values.encode(admittedProvider, forKey: .admittedProvider)
        try values.encode(admission, forKey: .admission)
        try values.encode(ready, forKey: .ready)
        try values.encode(qualified, forKey: .qualified)
        try values.encode(wineSha256, forKey: .wineSha256)
        try values.encode(wineserverSha256, forKey: .wineserverSha256)
        try values.encode(error, forKey: .error)
    }

    static func decode(_ bytes: Data, engine: String, registryDigest: String?, exitCode: Int32) throws -> Self {
        let json = try JSONValue.decodeUnique(bytes, maximumBytes: 32_768)
        guard case .object(let fields) = json,
              Set(fields.keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw EngineInspectionError.invalidResponse
        }
        let value = try json.decode(Self.self)
        guard value.schemaVersion == 1, value.capability == "engineAdmissionV1", !value.qualified,
              value.admission.map({ ["genericWine", "admitted", "unadmitted"].contains($0) }) ?? true,
              value.declaredProvider.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
              [value.registrySha256, value.wineSha256, value.wineserverSha256].allSatisfy({
                  $0 == nil || validDigest($0)
              }) else {
            throw EngineInspectionError.invalidResponse
        }
        if value.ready {
            guard exitCode == 0, value.error == nil, value.engineName == engine,
                  validDigest(value.registrySha256), validDigest(value.wineSha256),
                  validDigest(value.wineserverSha256),
                  registryDigest.map({ $0 == value.registrySha256 }) ?? true else {
                throw EngineInspectionError.invalidResponse
            }
            switch value.admission {
            case "admitted":
                guard value.declaredProvider == "calimocho", value.admittedProvider == "calimocho" else {
                    throw EngineInspectionError.invalidResponse
                }
            case "genericWine":
                guard value.admittedProvider == nil, value.declaredProvider != "calimocho" else {
                    throw EngineInspectionError.invalidResponse
                }
            default: throw EngineInspectionError.invalidResponse
            }
        } else {
            guard exitCode != 0, let error = value.error, !error.code.isEmpty,
                  ["PROVIDER_NOT_ADMITTED", "ENGINE_INSPECTION_FAILED"].contains(error.code),
                  !error.message.isEmpty, error.message.utf8.count <= 1_024,
                  value.admission != "admitted",
                  value.admittedProvider == nil,
                  value.engineName.map({ $0 == engine }) ?? true else {
                throw EngineInspectionError.invalidResponse
            }
            if value.admission == "unadmitted" {
                guard value.declaredProvider == "calimocho", error.code == "PROVIDER_NOT_ADMITTED" else {
                    throw EngineInspectionError.invalidResponse
                }
            }
        }
        return value
    }

    static func validDigest(_ value: String?) -> Bool {
        value.map { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } ?? false
    }
}

struct AdmittedEngineSelection: Codable, Equatable, Sendable {
    let registryPath: String
    let inspection: EngineInspection

    static let preferenceKey = "Xodus.lifecycle.admittedEngine.standaloneWine"

    static func read(defaults: UserDefaults) throws -> Self {
        guard let bytes = defaults.data(forKey: preferenceKey) else {
            throw NativeLaunchError.engineNotSelected
        }
        let selection = try JSONDecoder().decode(Self.self, from: bytes)
        guard let engine = selection.inspection.engineName,
              let digest = selection.inspection.registrySha256 else {
            throw NativeLaunchError.engineUnavailable
        }
        try selection.validate(registryPath: selection.registryPath, engineName: engine, registryDigest: digest)
        return selection
    }

    func validate(registryPath: String, engineName: String, registryDigest: String) throws {
        guard self.registryPath == registryPath, inspection.engineName == engineName,
              inspection.registrySha256 == registryDigest else {
            throw NativeLaunchError.selectionChanged
        }
        guard inspection.ready, inspection.error == nil,
              inspection.schemaVersion == 1, inspection.capability == "engineAdmissionV1", !inspection.qualified,
              inspection.admission == "admitted", inspection.admittedProvider == "calimocho",
              inspection.declaredProvider == "calimocho" else {
            throw NativeLaunchError.providerNotAdmitted
        }
        guard
              EngineInspection.validDigest(inspection.wineSha256),
              EngineInspection.validDigest(inspection.wineserverSha256) else {
            throw NativeLaunchError.engineUnavailable
        }
    }
}

actor EngineInspectionClient {
    private var child: Process?
    var hasOwnedProcess: Bool { child?.isRunning == true }

    func closeOwnedProcess() async throws {
        guard let child, child.isRunning else { return }
        child.terminate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while child.isRunning, ContinuousClock.now < deadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while child.isRunning, ContinuousClock.now < killDeadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        guard !child.isRunning else { throw EngineInspectionError.shutdownFailed }
    }

    func validateLaunch(configuration: BackendConfiguration, arguments: [String],
                        selection: AdmittedEngineSelection?, product: String? = nil) async throws {
        guard arguments.contains("--expected-registry-sha256") else { return }
        func argument(_ key: String) throws -> String {
            let positions = arguments.indices.filter { arguments[$0] == key }
            guard positions.count == 1, let index = positions.first, index + 1 < arguments.count else {
                throw EngineInspectionError.invalidResponse
            }
            return arguments[index + 1]
        }
        let registry = try argument("--registry"), engine = try argument("--engine")
        let digest = try argument("--expected-registry-sha256")
        guard let selection else { throw EngineInspectionError.failed }
        try selection.validate(registryPath: registry, engineName: engine, registryDigest: digest)
        let fresh = try await inspect(executable: configuration.executable, registry: URL(fileURLWithPath: registry),
                                      engine: engine, expectedDigest: digest,
                                      executableIdentity: configuration.executableIdentity)
        if !fresh.ready, let failure = fresh.error { throw EngineInspectionError.rejected(failure) }
        guard fresh == selection.inspection else { throw NativeLaunchError.selectionChanged }
        if engine == NativeFH6Recipe.engineName {
            guard product == NativeFH6Recipe.productID,
                  try argument("--title-recipe") == NativeFH6Recipe.id,
                  try argument("--package-identity") == NativeFH6Recipe.packageIdentity,
                  !arguments.contains("--shim-dir") else { throw NativeLaunchError.titleRecipeUnavailable }
            let probe = try await run(executable: configuration.executable,
                arguments: ["title-recipe-inspect", "--contract-version", "1"],
                executableIdentity: configuration.executableIdentity)
            let capability = try JSONValue.decodeUnique(probe.0, maximumBytes: 32_768)
            guard probe.1 == 0, case .object(let fields) = capability,
                  Set(fields.keys) == ["schemaVersion", "capability", "supported"],
                  capability["schemaVersion"]?.uint64 == 1,
                  capability["capability"]?.string == "titleRecipeV1",
                  capability["supported"] == .bool(true) else { throw EngineInspectionError.unsupported }
            let result = try await run(executable: configuration.executable, arguments: [
                "title-recipe-inspect", "--recipe", NativeFH6Recipe.id,
                "--product", NativeFH6Recipe.productID, "--package-identity", NativeFH6Recipe.packageIdentity,
                "--engine", engine, "--registry", registry, "--expected-registry-sha256", digest
            ], executableIdentity: configuration.executableIdentity)
            _ = try NativeTitleRecipeInspection.decode(result.0, selection: selection, exitCode: result.1)
        } else if arguments.contains("--title-recipe") || arguments.contains("--package-identity") {
            throw NativeLaunchError.titleRecipeUnavailable
        }
    }

    func inspect(executable: URL, registry: URL, engine: String, expectedDigest: String? = nil,
                 executableIdentity: NativeAuthHostBinding? = nil) async throws -> EngineInspection {
        let probe = try await run(executable: executable, arguments: ["engine-inspect", "--contract-version", "1"],
                                  executableIdentity: executableIdentity)
        struct Capability: Decodable { let schemaVersion: Int; let capability: String; let supported: Bool }
        guard probe.1 == 0,
              let capability = try? JSONValue.decodeUnique(probe.0, maximumBytes: 32_768).decode(Capability.self),
              capability.schemaVersion == 1, capability.capability == "engineAdmissionV1", capability.supported else {
            throw EngineInspectionError.unsupported
        }
        var arguments = ["engine-inspect", "--registry", registry.path, "--engine", engine]
        if let expectedDigest {
            guard EngineInspection.validDigest(expectedDigest) else { throw EngineInspectionError.invalidResponse }
            arguments += ["--expected-registry-sha256", expectedDigest]
        }
        let result = try await run(executable: executable, arguments: arguments, executableIdentity: executableIdentity)
        return try EngineInspection.decode(result.0, engine: engine, registryDigest: expectedDigest, exitCode: result.1)
    }

    private func run(executable: URL, arguments: [String],
                     executableIdentity: NativeAuthHostBinding?) async throws -> (Data, Int32) {
        guard child == nil else { throw EngineInspectionError.shutdownFailed }
        try Task.checkCancellation()
#if XODUS_SHIPPING
        guard executableIdentity != nil else { throw EngineInspectionError.unsupported }
#endif
        if let executableIdentity {
            guard executableIdentity.executable == executable else { throw EngineInspectionError.unsupported }
            _ = try executableIdentity.validatedArguments()
        }
        let process = Process(), output = Pipe(), diagnostic = Pipe()
        let handles = [output.fileHandleForReading, diagnostic.fileHandleForReading]
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = diagnostic
        process.environment = ProcessInfo.processInfo.environment.filter {
            ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL"].contains($0.key)
        }
        do {
            for handle in handles {
                let flags = fcntl(handle.fileDescriptor, F_GETFL)
                guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw EngineInspectionError.failed
                }
            }
            try process.run()
        } catch {
            for handle in handles { try handle.close() }
            throw EngineInspectionError.unsupported
        }
        child = process
        var bytes = Data(), diagnostics = 0
        var closed = [false, false]
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        do {
            while process.isRunning || closed.contains(false) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw EngineInspectionError.timedOut }
                for index in handles.indices where !closed[index] {
                    var buffer = [UInt8](repeating: 0, count: 4_096)
                    let count = Darwin.read(handles[index].fileDescriptor, &buffer, buffer.count)
                    if count == 0 { closed[index] = true }
                    else if count > 0 {
                        if index == 0 { bytes.append(contentsOf: buffer.prefix(count)) }
                        else { diagnostics += count }
                        guard bytes.count <= 32_768, diagnostics <= 8_192 else {
                            throw EngineInspectionError.invalidResponse
                        }
                    } else if errno != EAGAIN && errno != EINTR { throw EngineInspectionError.failed }
                }
                if process.isRunning || closed.contains(false) { try await Task.sleep(for: .milliseconds(5)) }
            }
            guard process.terminationReason == .exit else { throw EngineInspectionError.failed }
            for handle in handles { try handle.close() }
            child = nil
            return (bytes, process.terminationStatus)
        } catch {
            if process.isRunning { process.terminate() }
            let stopDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning, ContinuousClock.now < stopDeadline {
                await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning, ContinuousClock.now < killDeadline {
                await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
            }
            for handle in handles { try handle.close() }
            guard !process.isRunning else { throw EngineInspectionError.shutdownFailed }
            child = nil
            throw error
        }
    }
}
