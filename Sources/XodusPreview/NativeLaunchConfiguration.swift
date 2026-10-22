// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import XodusCore
import XodusManagement

struct NativeEngineRegistry: Decodable {
    struct Entry: Decodable, Identifiable {
        struct SmokeTest: Decodable { let status: String }
        let name: String
        let kind: String
        let wine: String
        let smoke_test: SmokeTest
        let presentation_validation: SmokeTest?
        let engine_label: String?
        var id: String { name }
        var isAvailable: Bool {
            smoke_test.status == "pass" && presentation_validation?.status != "failed"
                && wine.hasPrefix("/") && RunnerAvailabilityDetector.isExecutable(URL(fileURLWithPath: wine))
        }
    }
    let engines: [Entry]

    static func read(_ url: URL) throws -> Self {
        try GameScriptFiles.checkPath(url)
        let bytes = try InstalledGameFiles.readRegular(url, maximumBytes: 2_097_152)
        let registry = try JSONDecoder().decode(Self.self, from: bytes)
        guard Set(registry.engines.map(\.name)).count == registry.engines.count,
              registry.engines.allSatisfy({
                  !$0.name.isEmpty && $0.name.utf8.count <= 128
                      && $0.name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                          || (97...122).contains($0) || [45, 46, 95].contains($0) }
              }) else { throw GameScriptError.runtimeUnavailable }
        return registry
    }
}

struct NativeRuntimeReference: Sendable {
    let primary: NativeAuthHostBinding
    let legacy: NativeAuthHostBinding

    func validate() async throws -> URL {
        guard primary.executable.lastPathComponent == "xgameruntime.dll",
              legacy.executable == primary.executable.deletingLastPathComponent()
                .appendingPathComponent("xgameruntime_legacy.dll") else { throw GameScriptError.runtimeUnavailable }
        // DLLs are data, not macOS executables. Reuse the receipt reader's bounded,
        // non-symlink regular-file checks, then bind both halves to their frozen hashes.
        for artifact in [primary, legacy] {
            let bytes = try await Task.detached {
                try GameScriptFiles.checkPath(artifact.executable)
                return try InstalledGameFiles.readRegular(artifact.executable, maximumBytes: 67_108_864)
            }.value
            guard NativeRuntimeReference.hash(bytes) == artifact.sha256,
                  artifact.expectedBytes.map({ $0 == bytes.count }) ?? true else {
                throw GameScriptError.runtimeUnavailable
            }
        }
        return primary.executable
    }

    static func capture(_ primary: URL) throws -> Self {
        guard primary.lastPathComponent == "xgameruntime.dll" else { throw GameScriptError.runtimeUnavailable }
        func binding(_ url: URL) throws -> NativeAuthHostBinding {
            try GameScriptFiles.checkPath(url)
            let bytes = try InstalledGameFiles.readRegular(url, maximumBytes: 67_108_864)
            return NativeAuthHostBinding(executable: url, sha256: hash(bytes), expectedBytes: Int64(bytes.count))
        }
        return try Self(primary: binding(primary),
                        legacy: binding(primary.deletingLastPathComponent().appendingPathComponent("xgameruntime_legacy.dll")))
    }

    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeLocalRuntime: Codable {
    let primaryPath: String
    let primarySHA256: String
    let legacySHA256: String

    init(_ reference: NativeRuntimeReference) {
        primaryPath = reference.primary.executable.path
        primarySHA256 = reference.primary.sha256
        legacySHA256 = reference.legacy.sha256
    }

    var reference: NativeRuntimeReference {
        let primary = URL(fileURLWithPath: NativeTitleLaunchProfile.expand(primaryPath))
        return NativeRuntimeReference(primary: .init(executable: primary, sha256: primarySHA256),
            legacy: .init(executable: primary.deletingLastPathComponent().appendingPathComponent("xgameruntime_legacy.dll"),
                          sha256: legacySHA256))
    }
}

struct NativeShimReference: Sendable {
    let directory: URL
    let hashes: [String: String]

    static let approved = Self(directory: URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Ode to X/Engines/profiles/native-web-shims-v1"),
        hashes: [
            "windows.web.dll": "da4059506a4763b1f5b584c99a36d3c8f2596d5c8d619346958a3ee1c04c3c2e",
            "XCurl.dll": "238f94356df33e52a5656a763bdf65402f53bab5b47338c4ec91d9cd1163aac3",
            "cacert.pem": "a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505"
        ])

    func validate() async throws {
        guard Set(hashes.keys) == ["windows.web.dll", "XCurl.dll", "cacert.pem"] else {
            throw NativeLaunchError.shimsUnavailable
        }
        let names = try await Task.detached {
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }.value
        guard Set(names) == Set(hashes.keys) else { throw NativeLaunchError.shimsUnavailable }
        for (name, expected) in hashes {
            let url = directory.appendingPathComponent(name)
            let bytes = try await Task.detached {
                try GameScriptFiles.checkPath(url)
                return try InstalledGameFiles.readRegular(url, maximumBytes: 67_108_864)
            }.value
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected else {
                throw NativeLaunchError.shimsUnavailable
            }
        }
    }
}

struct NativeTitleLaunchProfile: Codable {
    struct PinnedFile: Codable {
        let path: String
        let sha256: String
        var destination: String? = nil

        var url: URL { URL(fileURLWithPath: NativeTitleLaunchProfile.expand(path)) }

        func validate() async throws {
            let bytes = try await Task.detached {
                try GameScriptFiles.checkPath(url)
                return try InstalledGameFiles.readRegular(url, maximumBytes: 67_108_864)
            }.value
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256 else {
                throw NativeLaunchError.invalidProfile
            }
        }
    }

    let version: Int
    let productID: String
    let engine: String?
    let shimDirectory: String?
    let environment: [String: String]
    var unsetEnvironment: [String]? = nil
    var crossOverEnvironment: [String: String]? = nil
    var executable: String? = nil
    var timeoutSeconds: UInt? = nil
    var noAutoDismiss: Bool? = nil
    var runtime: NativeLocalRuntime? = nil
    var requiredFiles: [PinnedFile]? = nil
    var prefixRegistryImports: [PinnedFile]? = nil
    var prefixOverlays: [PinnedFile]? = nil
    var provider: RuntimeProviderKind? = nil

    private struct Catalogue: Decodable {
        let version: Int
        let profiles: [NativeTitleLaunchProfile]
        let providerOverrides: [NativeTitleLaunchProfile]?
    }

    static func expand(_ value: String) -> String {
        value.replacingOccurrences(of: "${HOME}", with: NSHomeDirectory())
    }

    static func bundledProfiles() throws -> [Self] {
        let bytes = try Data(contentsOf: LaunchRecipeResources.profilesURL())
        guard bytes.count <= 1_048_576 else { throw NativeLaunchError.invalidProfile }
        let catalogue = try JSONDecoder().decode(Catalogue.self, from: bytes)
        let profiles = catalogue.profiles + (catalogue.providerOverrides ?? [])
        guard catalogue.version == 1, profiles.count <= 512,
              catalogue.profiles.allSatisfy({ $0.provider == nil }),
              (catalogue.providerOverrides ?? []).allSatisfy({ $0.provider != nil }),
              Set(profiles.map({ $0.productID + ":" + ($0.provider?.rawValue ?? "default") })).count == profiles.count else {
            throw NativeLaunchError.invalidProfile
        }
        for profile in profiles { try profile.validate(productID: profile.productID) }
        return profiles
    }

    static func read(productID: String, defaults: UserDefaults, provider: RuntimeProviderKind? = nil) throws -> Self? {
        let bundled = try bundledProfiles().filter { $0.productID == productID }
        if let provider, let override = bundled.first(where: { $0.provider == provider }) { return override }
        if let primary = bundled.first(where: { $0.provider == nil }) { return primary }
        guard let directory = defaults.string(forKey: "Xodus.lifecycle.profileDirectory"), !directory.isEmpty else { return nil }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(productID + ".json")
        try GameScriptFiles.checkPath(url, allowMissing: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let profile = try JSONDecoder().decode(Self.self, from: InstalledGameFiles.readRegular(url, maximumBytes: 65_536))
        try profile.validate(productID: productID)
        return profile
    }

    private func validate(productID: String) throws {
        func validKey(_ key: String) -> Bool {
            key.range(of: "^[A-Z_][A-Z0-9_]{0,127}$", options: .regularExpression) != nil
        }
        func relative(_ path: String) -> Bool {
            !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.utf8.contains(0)
                && path.utf8.count <= 4096
                && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { ["", ".", ".."].contains(String($0)) })
        }
        let mirrored = crossOverEnvironment ?? [:]
        guard version == 1, self.productID == productID, PCGamesClient.validProductID(productID),
              environment.count <= 64, mirrored.count <= 64,
              environment.merging(mirrored, uniquingKeysWith: { first, _ in first }).allSatisfy({ key, value in
                  validKey(key)
                      && value.utf8.count <= 16_384 && !value.utf8.contains(0)
              }), mirrored.allSatisfy({ environment[$0.key] == $0.value }),
              mirrored.isEmpty || environment["CX_ENV"] == nil,
              (unsetEnvironment ?? []).count <= 64,
              (unsetEnvironment ?? []).allSatisfy({ validKey($0) && environment[$0] == nil }),
              executable.map(relative) ?? true,
              timeoutSeconds.map({ (1...3600).contains($0) }) ?? true else {
            throw NativeLaunchError.invalidProfile
        }
        for file in (requiredFiles ?? []) + (prefixRegistryImports ?? []) + (prefixOverlays ?? []) {
            guard Self.expand(file.path).hasPrefix("/"), !file.path.utf8.contains(0),
                  file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  file.destination.map(relative) ?? true else { throw NativeLaunchError.invalidProfile }
        }
        guard (prefixOverlays ?? []).allSatisfy({ $0.destination != nil }) else { throw NativeLaunchError.invalidProfile }
        if let directory = shimDirectory {
            guard directory.hasPrefix("/") else { throw NativeLaunchError.invalidProfile }
            try GameScriptFiles.checkPath(URL(fileURLWithPath: directory))
        }
    }

    var launchEnvironment: [String: String] {
        var result = environment.mapValues(Self.expand)
        if let mirrored = crossOverEnvironment, !mirrored.isEmpty {
            result["CX_ENV"] = mirrored.keys.sorted().map {
                let quoted = Self.expand(mirrored[$0] ?? "").replacingOccurrences(of: "'", with: "'\\''")
                return "\($0)='\(quoted)'"
            }.joined(separator: " ")
        }
        return result
    }

    var arguments: [String] {
        var result: [String] = []
        if let executable { result += ["--exe", executable] }
        if let timeoutSeconds { result += ["--timeout-seconds", String(timeoutSeconds)] }
        if noAutoDismiss == true { result += ["--no-auto-dismiss"] }
        return result
    }

    func registryForLaunch(base: URL, engine: String, outputDirectory: URL? = nil) async throws -> URL {
        for file in (requiredFiles ?? []) + (prefixRegistryImports ?? []) + (prefixOverlays ?? []) {
            try await file.validate()
        }
        guard prefixRegistryImports != nil || prefixOverlays != nil else { return base }
        let bytes = try InstalledGameFiles.readRegular(base, maximumBytes: 2_097_152)
        guard var document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              var engines = document["engines"] as? [[String: Any]],
              let index = engines.firstIndex(where: { $0["name"] as? String == engine }) else {
            throw NativeLaunchError.invalidProfile
        }
        if let imports = prefixRegistryImports {
            engines[index]["prefix_registry_imports"] = imports.map { ["source": $0.url.path, "sha256": $0.sha256] }
        }
        if let overlays = prefixOverlays {
            engines[index]["prefix_overlays"] = overlays.map { ["source": $0.url.path, "destination": $0.destination ?? ""] }
        }
        document["engines"] = engines
        let directory = outputDirectory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/Xodus/LaunchRegistries/\(UUID().uuidString)")
        try GameScriptFiles.checkPath(directory, allowMissing: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let output = directory.appendingPathComponent("registry.json")
        try GameScriptFiles.writePrivate(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), to: output)
        return output
    }
}

enum NativeRuntimePins {
    // Populated only after the component owner qualifies the primary/legacy pair.
    static let approved: NativeRuntimeReference? = nil
}

struct NativeLaunchConfiguration {
    let engine: String
    let registry: URL
    let prefix: URL
    let runtime: NativeRuntimeReference
    let profile: NativeTitleLaunchProfile?
    let shims: NativeShimReference

    static func resolve(game: InstalledGame, provider: RuntimeProviderKind?,
                        defaults: UserDefaults = .standard,
                        runtime: NativeRuntimeReference? = NativeRuntimePins.approved,
                        shims: NativeShimReference = .approved,
                        provenEngine: String? = nil) throws -> Self {
        let localRuntime = try defaults.data(forKey: "Xodus.lifecycle.runtime")
            .map { try JSONDecoder().decode(NativeLocalRuntime.self, from: $0).reference }
        let profile = try NativeTitleLaunchProfile.read(productID: game.storeId, defaults: defaults, provider: provider)
        guard let runtime = profile?.runtime?.reference ?? runtime ?? localRuntime else { throw NativeLaunchError.runtimeNotQualified }
        guard let registryPath = defaults.string(forKey: "Xodus.lifecycle.registry"),
              registryPath.hasPrefix("/") else { throw NativeLaunchError.registryMissing }
        let registryURL = URL(fileURLWithPath: registryPath)
        let registry = try NativeEngineRegistry.read(registryURL)
        let entry = try selectEngine(registry: registry,
                                     provider: profile?.provider != nil ? nil : provider, defaults: defaults,
                                     provenEngine: profile?.engine ?? provenEngine)
        let engineName = entry.name
        guard entry.wine.hasPrefix("/"), RunnerAvailabilityDetector.isExecutable(URL(fileURLWithPath: entry.wine)) else {
            throw NativeLaunchError.engineUnavailable
        }
        let prefix = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/Xodus/Prefixes/\(game.id.uuidString)/\(engineName)")
        try GameScriptFiles.checkPath(prefix, allowMissing: true)
        if let selected = profile?.shimDirectory, selected != shims.directory.path {
            throw NativeLaunchError.invalidProfile
        }
        return Self(engine: engineName, registry: registryURL, prefix: prefix, runtime: runtime,
                        profile: profile, shims: shims)
    }

    static func selectEngine(registry: NativeEngineRegistry, provider: RuntimeProviderKind?,
                             defaults: UserDefaults, provenEngine: String?) throws -> NativeEngineRegistry.Entry {
        let selected = provider.flatMap { defaults.string(forKey: "Xodus.lifecycle.engine.\($0.rawValue)") }
        if provider != nil || provenEngine != nil {
            guard let name = provider != nil ? selected : provenEngine,
                  let entry = registry.engines.first(where: { $0.name == name }),
                  entry.isAvailable else {
                throw NativeLaunchError.engineUnavailable
            }
            return entry
        }
        let available = registry.engines.filter(\.isAvailable)
        guard let entry = available.first(where: { $0.engine_label == "Free Wine" || $0.kind.lowercased() == "free" })
                ?? available.first else { throw NativeLaunchError.engineUnavailable }
        return entry
    }

    func arguments() async throws -> [String] {
        let dll = try await runtime.validate()
        try await shims.validate()
        let selectedRegistry = try await profile?.registryForLaunch(base: registry, engine: engine) ?? registry
        return ["--engine", engine, "--registry", selectedRegistry.path, "--prefix", prefix.path,
                "--runtime-dll", dll.path, "--shim-dir", shims.directory.path] + (profile?.arguments ?? [])
    }
}

enum NativeLaunchError: Error, LocalizedError {
    case runtimeNotQualified, registryMissing, engineNotSelected, engineUnavailable, invalidProfile, shimsUnavailable,
         installationNotReady
    var errorDescription: String? {
        switch self {
        case .runtimeNotQualified:
            "Choose the local primary and legacy runtime pair in Runtime settings before playing. Experimental local runtimes do not require release qualification."
        case .registryMissing:
            "Choose the engine registry in Runtime settings before playing."
        case .engineNotSelected:
            "Choose a tested registry engine for this provider in Runtime settings. No other engine was substituted."
        case .engineUnavailable:
            "The selected registry engine is no longer available. Restore it or choose another engine in Runtime settings."
        case .invalidProfile:
            "The title's local launch profile is invalid. Check its product ID and use the verified native-web-shims-v1 folder, separate from the game runtime."
        case .shimsUnavailable:
            "The native sign-in components are missing or have changed. Restore native-web-shims-v1 before playing."
        case .installationNotReady:
            "This installation isn't verified complete. Check it, resume the download or repair it before playing."
        }
    }
}
