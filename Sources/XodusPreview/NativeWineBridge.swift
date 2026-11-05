// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation
import XodusManagement

enum NativeWineBridgeError: Error, LocalizedError {
    case rejected(String)
    var errorDescription: String? {
        switch self {
        case .rejected(let reason):
            "The Wine bridge diagnostic cannot start: \(reason). No other engine was substituted."
        }
    }
}

struct NativeWineBridgeSelection: Sendable {
    // Exact installed candidates, not provider-wide admission or game qualification.
    enum Candidate: Sendable, CaseIterable {
        case highball, heroic
        var provider: ExternalGameProvider { self == .highball ? .highball : .heroic }
        var version: String { self == .highball ? "0.10.22" : "2.22.3" }
        var label: String { self == .highball ? "Highball r27" : "Heroic toolkit 3.0-3" }
        var recipeSHA256: String {
            self == .highball ? "0edac5bdefdd4a1baf99a0a7c95ff5a73b7f6764b67f94808808e30166d4a92b"
                : "aa50393b2b0fd06f9b9ad486dce0c52b598a68490b5bdf4a8532c253bfd039e7"
        }
        var registrySHA256: String {
            self == .highball ? "fb9f37b5f4139e8bf59b91e93a12efaf19265088dbd4d9e0968f5a88ef3afbb5"
                : "c8e74650509a777d01cccf688ba002f9b256d05a9d5d5ecc3f24f9716198bc12"
        }
        var engine: String {
            self == .highball ? "highball-r27-original-d3dmetal-probe"
                : "heroic-gptk-3.0-3-original-d3dmetal-probe"
        }
    }
    // Historical development fixture; shipping uses its generated producer pair.
    static let cliSHA256 = "fa1a637a751f2fe1d331a328de31e298f49d6f184989ab52914c7af74fc08760"
    let candidate: Candidate
    let registry: URL
    let inspection: EngineInspection
    let prefix: URL

    private struct Recipe: Decodable {
        struct Item: Decodable {
            let kind: String
            let sha256: String?
            let executable: Bool?
            let target: String?
            let mode: UInt16?
        }
        struct Component: Decodable { let path: String; let sha256: String }
        let provider: String
        let providerApp: String
        let runtimeRoot: String
        let manifestSHA256: String?
        let inventory: [String: Item]
        let components: [Component]
        let renderer: String
        let observedAcceptedLicenses: [String]?
        let licenseDocumentSHA256: String?
    }

    static func select(registry: URL, configuration: BackendConfiguration) async throws -> Self {
        let candidate = try await verifyFiles(registry: registry)
        let inspection = try await inspect(registry: registry, candidate: candidate, configuration: configuration)
        let prefix = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/Xodus/WineBridgeDiagnostics/\(UUID().uuidString)")
        return Self(candidate: candidate, registry: registry, inspection: inspection, prefix: prefix)
    }

    func validateLaunch(configuration: BackendConfiguration, arguments: [String]) async throws {
        func argument(_ key: String) throws -> String {
            let indexes = arguments.indices.filter { arguments[$0] == key }
            guard indexes.count == 1, let index = indexes.first, index + 1 < arguments.count else {
                throw NativeWineBridgeError.rejected("the diagnostic arguments changed")
            }
            return arguments[index + 1]
        }
        guard try argument("--registry") == registry.path,
              try argument("--engine") == candidate.engine,
              try argument("--expected-registry-sha256") == candidate.registrySHA256,
              try argument("--prefix") == prefix.path,
              arguments.contains("--no-auto-dismiss"),
              try argument("--timeout-seconds") == "120" else {
            throw NativeWineBridgeError.rejected("the explicit diagnostic selection changed")
        }
        try validateUnusedPrefix()
        guard try await Self.verifyFiles(registry: registry) == candidate,
              try await Self.inspect(registry: registry, candidate: candidate, configuration: configuration) == inspection else {
            throw NativeWineBridgeError.rejected("the selected provider or generic Wine inspection changed")
        }
        try validateUnusedPrefix()
    }

    func validateUnusedPrefix() throws {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/Xodus/WineBridgeDiagnostics")
        guard prefix.deletingLastPathComponent().path == root.path,
              UUID(uuidString: prefix.lastPathComponent) != nil else {
            throw NativeWineBridgeError.rejected("the dedicated prefix is invalid")
        }
        try GameScriptFiles.checkPath(prefix, allowMissing: true)
        guard !FileManager.default.fileExists(atPath: prefix.path) else {
            throw NativeWineBridgeError.rejected("the diagnostic prefix already exists; explicitly select a new attempt")
        }
    }

    static func admitsBackend(_ configuration: BackendConfiguration,
                              pins: ShippingPairIdentity? = ShippingPairPins.approved) -> Bool {
#if !XODUS_SHIPPING
        if let identity = configuration.executableIdentity,
           identity.executable == configuration.executable, identity.sha256 == cliSHA256 {
            return true
        }
#endif
        return NativeLifecyclePins.admitsShippingConfiguration(configuration, pins: pins)
    }

    private static func inspect(registry: URL, candidate: Candidate,
                                configuration: BackendConfiguration) async throws -> EngineInspection {
        guard admitsBackend(configuration) else {
            throw NativeWineBridgeError.rejected("the paired native lifecycle executable is not selected")
        }
        let result = try await EngineInspectionClient().inspect(executable: configuration.executable,
            registry: registry, engine: candidate.engine, expectedDigest: candidate.registrySHA256,
            executableIdentity: configuration.executableIdentity, recordTimeout: .seconds(90))
        if !result.ready, let failure = result.error {
            throw NativeWineBridgeError.rejected("runtime inspection failed (\(failure.code)): \(failure.message)")
        }
        guard result.ready, !result.qualified, result.error == nil,
              result.admission == "genericWine", result.admittedProvider == nil,
              result.declaredProvider == nil else {
            throw NativeWineBridgeError.rejected("the selected runtime is not the reviewed generic Wine record")
        }
        return result
    }

    private static func verifyFiles(registry: URL) async throws -> Candidate {
        let task = Task.detached(priority: .utility) { () throws -> Candidate in
            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            func check() throws {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw NativeWineBridgeError.rejected("complete dependency verification exceeded 90 seconds")
                }
            }
            func hash(_ url: URL) throws -> String {
                try check()
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else {
                    throw NativeWineBridgeError.rejected("a reviewed file cannot be opened: \(url.lastPathComponent)")
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { handle.closeFile() }
                var before = stat()
                guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                      before.st_size >= 0, before.st_size <= 4_294_967_296 else {
                    throw NativeWineBridgeError.rejected("a reviewed file is not bounded regular data")
                }
                var value = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    try check()
                    value.update(data: data)
                }
                var after = stat()
                guard fstat(descriptor, &after) == 0,
                      before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                      before.st_size == after.st_size, before.st_mode == after.st_mode,
                      before.st_uid == after.st_uid,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
                    throw NativeWineBridgeError.rejected("a reviewed file changed while hashing")
                }
                return value.finalize().map { String(format: "%02x", $0) }.joined()
            }
            try GameScriptFiles.checkPath(registry)
            let registryBytes = try InstalledGameFiles.readRegular(registry, maximumBytes: 2_097_152)
            let registryHash = SHA256.hash(data: registryBytes).map({ String(format: "%02x", $0) }).joined()
            guard let candidate = Candidate.allCases.first(where: { $0.registrySHA256 == registryHash }) else {
                throw NativeWineBridgeError.rejected("the complete registry differs from a source-pinned candidate")
            }
            let recipeURL = registry.deletingLastPathComponent().appendingPathComponent("recipe.json")
            try GameScriptFiles.checkPath(recipeURL)
            let bytes = try InstalledGameFiles.readRegular(recipeURL, maximumBytes: 2_097_152)
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == candidate.recipeSHA256 else {
                throw NativeWineBridgeError.rejected("the archive-qualified recipe differs from the source-pinned candidate")
            }
            let recipe = try JSONValue.decodeUnique(bytes, maximumBytes: 2_097_152).decode(Recipe.self)
            guard recipe.renderer == "original-d3dmetal", recipe.provider == candidate.provider.rawValue,
                  case .detected(let app) = ExternalApplicationDetector.detect(candidate.provider),
                  app.location.path == recipe.providerApp, app.version == candidate.version else {
                throw NativeWineBridgeError.rejected("the observed provider identity changed")
            }
            let root = URL(fileURLWithPath: recipe.runtimeRoot, isDirectory: true)
            guard root.resolvingSymlinksInPath() == root else {
                throw NativeWineBridgeError.rejected("the runtime root now resolves elsewhere")
            }
            switch candidate {
            case .highball:
                throw NativeWineBridgeError.rejected(
                    "Highball's effective engine store cannot be proven without inspecting Highball's process environment; its supported HIGHBALL_HOME override can select a different store than config.json. The native Highball bridge is unavailable until a supported read-only proof is available")
            case .heroic:
                guard recipe.observedAcceptedLicenses == nil,
                      recipe.licenseDocumentSHA256 == "b099088947b67c1707de9b8e8f8dd5e03a4af8048451e455b9044553beeabcf8" else {
                    throw NativeWineBridgeError.rejected("the provider-linked agreement changed; Heroic has no activation receipt")
                }
            }
            var observed = Set<String>()
            func walk(_ directory: URL) throws {
                try check()
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
                      mode & 0o022 == 0 else {
                    throw NativeWineBridgeError.rejected("the runtime directory is not owner-controlled")
                }
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    try check()
                    let name = String(url.path.dropFirst(root.path.count + 1))
                    guard let expected = recipe.inventory[name] else {
                        throw NativeWineBridgeError.rejected("an unreviewed runtime item appeared: \(name)")
                    }
                    observed.insert(name)
                    let item = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard (item[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                        throw NativeWineBridgeError.rejected("a runtime item's owner changed: \(name)")
                    }
                    if let expectedMode = expected.mode,
                       (item[.posixPermissions] as? NSNumber)?.uint16Value != expectedMode {
                        throw NativeWineBridgeError.rejected("a reviewed runtime mode changed: \(name)")
                    }
                    switch (item[.type] as? FileAttributeType, expected.kind) {
                    case (.typeSymbolicLink, "symlink"):
                        guard try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == expected.target,
                              url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                            throw NativeWineBridgeError.rejected("a runtime link changed or escaped: \(name)")
                        }
                    case (.typeDirectory, "directory"):
                        try walk(url)
                    case (.typeRegular, "file"):
                        guard let mode = (item[.posixPermissions] as? NSNumber)?.uint16Value,
                              mode & 0o022 == 0, (mode & 0o111 != 0) == expected.executable,
                              try hash(url) == expected.sha256 else {
                            throw NativeWineBridgeError.rejected("a runtime file changed: \(name)")
                        }
                    default:
                        throw NativeWineBridgeError.rejected("a runtime item's type changed: \(name)")
                    }
                }
            }
            try walk(root)
            guard observed == Set(recipe.inventory.keys) else {
                throw NativeWineBridgeError.rejected("the complete runtime inventory is missing items")
            }
            for component in recipe.components {
                let url = URL(fileURLWithPath: component.path)
                try GameScriptFiles.checkPath(url)
                guard try hash(url) == component.sha256 else {
                    throw NativeWineBridgeError.rejected("a reviewed provider archive or agreement changed")
                }
            }
            try check()
            guard try hash(registry) == candidate.registrySHA256, try hash(recipeURL) == candidate.recipeSHA256 else {
                throw NativeWineBridgeError.rejected("the selected recipe changed during verification")
            }
            return candidate
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

}
