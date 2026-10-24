// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import XodusCore
import XodusManagement

struct NativeEngineRegistry: Decodable {
    struct Entry: Decodable, Identifiable {
        struct SmokeTest: Decodable { let status: String }
        struct Provider: Decodable { let id: String; let contract_version: Int }
        let name: String
        let kind: String
        let wine: String
        let smoke_test: SmokeTest
        let presentation_validation: SmokeTest?
        let engine_label: String?
        let environment: [String: String]?
        let version: String?
        let source_url: String?
        let provider: Provider?
        var id: String { name }
        var isAvailable: Bool {
            smoke_test.status == "pass" && presentation_validation?.status != "failed"
                && wine.hasPrefix("/") && RunnerAvailabilityDetector.isExecutable(URL(fileURLWithPath: wine))
        }
    }
    let engines: [Entry]
    private(set) var byteDigest: String = ""
    enum CodingKeys: String, CodingKey { case engines }

    static func read(_ url: URL) throws -> Self {
        try GameScriptFiles.checkPath(url)
        let bytes = try InstalledGameFiles.readRegular(url, maximumBytes: 2_097_152)
        var registry = try JSONDecoder().decode(Self.self, from: bytes)
        registry.byteDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard Set(registry.engines.map(\.name)).count == registry.engines.count,
              registry.engines.allSatisfy({
                  !$0.name.isEmpty && $0.name.utf8.count <= 128
                      && $0.name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                          || (97...122).contains($0) || [45, 46, 95].contains($0) }
                      && ($0.provider.map { !$0.id.isEmpty && $0.id.utf8.count <= 64 && $0.contract_version == 1 } ?? true)
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
    struct RuntimeCatalogue: Decodable {
        struct Item: Decodable {
            struct Launch: Decodable {
                let engine: String
                let executable: String
                let environment: [String: String]
                let unsetEnvironment: [String]
            }
            struct Evidence: Decodable {
                let runId: String?
                let receiptPath: String?
                let cliExitCode: Int?
                let wineExitCode: Int?
            }
            let storeId: String
            let status: String
            let pendingTest: Bool
            let launch: Launch
            let evidence: Evidence
            var observed: Bool {
                !pendingTest && status == "title-screen-observed"
                    && evidence.runId.flatMap(UUID.init(uuidString:)) != nil
                    && evidence.receiptPath?.hasPrefix("/") == true
                    && evidence.cliExitCode == 0 && evidence.wineExitCode == 0
            }
        }
        let schemaVersion: Int
        let cliSha256: String
        let evidenceCliSha256: String
        let primaryRuntimeSha256: String
        let legacyRuntimeSha256: String
        let items: [Item]

        static func bundled() throws -> Self {
            let bytes = try Data(contentsOf: LaunchRecipeResources.runtimeProfilesURL())
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
                    == "4380da353400ac386048de0c1c3776026cf3e7ba288000b0d011364205949f5f" else {
                throw NativeLaunchError.invalidProfile
            }
            let catalogue = try JSONDecoder().decode(Self.self, from: bytes)
            guard catalogue.schemaVersion == 1, catalogue.cliSha256 == NativeLifecyclePins.cliSHA256,
                  catalogue.evidenceCliSha256 == "adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604",
                  Set(catalogue.items.map(\.storeId)).count == catalogue.items.count else {
                throw NativeLaunchError.invalidProfile
            }
            return catalogue
        }
    }

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
    var engine: String?
    let shimDirectory: String?
    var environment: [String: String]
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
    var dllOverrides: String? = nil
    var dllOverrideEvidence: DLLOverrideEvidence? = nil

    struct DLLOverrideEvidence: Codable {
        let runID: String
        let receiptSHA256: String
        let registrySHA256: String
        let scope: String
    }

    private struct Catalogue: Decodable {
        let version: Int
        let profiles: [NativeTitleLaunchProfile]
        let providerOverrides: [NativeTitleLaunchProfile]?
        let engineFallbacks: [EngineFallback]?
    }

    struct EngineFallback: Decodable {
        let baseEngine: String
        let engine: String
        let library: PinnedFile
    }

    static func bundledEngineFallbacks() throws -> [EngineFallback] {
        let bytes = try Data(contentsOf: LaunchRecipeResources.profilesURL())
        guard bytes.count <= 1_048_576 else { throw NativeLaunchError.invalidProfile }
        let catalogue = try JSONDecoder().decode(Catalogue.self, from: bytes)
        let rules = catalogue.engineFallbacks ?? []
        guard catalogue.version == 1, rules.count <= 3,
              Set(rules.map(\.baseEngine)).count == rules.count,
              Set(rules.map(\.engine)).count == rules.count else { throw NativeLaunchError.invalidProfile }
        return rules
    }

    func applyingFallback(_ selected: String, baseEngine: String) throws -> Self {
        guard let rule = try Self.bundledEngineFallbacks().first(where: {
            $0.baseEngine == baseEngine && $0.engine == selected
        }) else { throw NativeLaunchError.invalidProfile }
        var result = self
        result.engine = selected
        result.environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = rule.library.path
        result.requiredFiles = (requiredFiles ?? []) + [rule.library]
        try result.validate(productID: productID)
        return result
    }

    static func expand(_ value: String) -> String {
        value.replacingOccurrences(of: "${HOME}", with: NSHomeDirectory())
    }

    static func bundledProfiles() throws -> [Self] {
        let bytes = try Data(contentsOf: LaunchRecipeResources.profilesURL())
        guard bytes.count <= 1_048_576 else { throw NativeLaunchError.invalidProfile }
        let catalogue = try JSONDecoder().decode(Catalogue.self, from: bytes)
        let runtimeCatalogue = try RuntimeCatalogue.bundled()
        var active = catalogue.profiles
        let candidates = try NativeCandidateLaunchCatalogue.rows().filter(\.admitted).map(\.launchProfile)
        guard Set(active.map(\.productID)).isDisjoint(with: candidates.map(\.productID)) else {
            throw NativeLaunchError.invalidProfile
        }
        active += candidates
        for item in runtimeCatalogue.items {
            if !item.observed {
                guard !active.contains(where: {
                    $0.productID == item.storeId && $0.environment["XODUS_PRIVATE_RUNTIME_COM_STA"] == "1"
                }) else { throw NativeLaunchError.invalidProfile }
                continue
            }
            guard let index = active.firstIndex(where: { $0.productID == item.storeId }),
                  active[index].engine == item.launch.engine,
                  active[index].executable == item.launch.executable,
                  active[index].runtime?.primarySHA256 == runtimeCatalogue.primaryRuntimeSha256,
                  active[index].runtime?.legacySHA256 == runtimeCatalogue.legacyRuntimeSha256,
                  item.launch.environment["XODUS_PRIVATE_CALLER_OWNS_COM"] == nil,
                  item.launch.unsetEnvironment.contains("XODUS_PRIVATE_CALLER_OWNS_COM") else {
                throw NativeLaunchError.invalidProfile
            }
            active[index].environment.merge(item.launch.environment, uniquingKeysWith: { _, observed in observed })
            active[index].unsetEnvironment = Array(Set((active[index].unsetEnvironment ?? [])
                + item.launch.unsetEnvironment)).sorted()
        }
        let profiles = active + (catalogue.providerOverrides ?? [])
        guard catalogue.version == 1, profiles.count <= 512,
              catalogue.profiles.allSatisfy({ $0.provider == nil }),
              (catalogue.providerOverrides ?? []).allSatisfy({ $0.provider != nil }),
              Set(profiles.map({ $0.productID + ":" + ($0.provider?.rawValue ?? "default") })).count == profiles.count else {
            throw NativeLaunchError.invalidProfile
        }
        for profile in profiles { try profile.validate(productID: profile.productID) }
        return profiles
    }

    static func read(productID: String, defaults: UserDefaults, provider: RuntimeProviderKind? = nil,
                     evidence: MacGameEvidence.Game? = nil) throws -> Self? {
        if let issue = NativeCandidateLaunchCatalogue.issue(productID: productID, evidence: evidence) {
            throw NativeLaunchError.candidateBlocked(issue)
        }
        let bundled = try bundledProfiles().filter { $0.productID == productID }
        if let provider, let override = bundled.first(where: { $0.provider == provider }) { return override }
        if let primary = bundled.first(where: { $0.provider == nil }) { return primary }
        guard let directory = defaults.string(forKey: "Xodus.lifecycle.profileDirectory"), !directory.isEmpty else { return nil }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(productID + ".json")
        try GameScriptFiles.checkPath(url, allowMissing: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let profile = try JSONDecoder().decode(Self.self, from: InstalledGameFiles.readRegular(url, maximumBytes: 65_536))
        try profile.validate(productID: productID)
        if profile.environment["XODUS_PRIVATE_RUNTIME_COM_STA"] == "1",
           try RuntimeCatalogue.bundled().items.contains(where: { $0.storeId == productID && !$0.observed }) {
            throw NativeLaunchError.invalidProfile
        }
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
        if let dllOverrides {
            guard productID == "9NH0MSG29X6L", engine == "apple-gptk-4.0b3",
                  executable == "Mixtape.exe", dllOverrides == "msvcp140_2,vcruntime140_1=n,b",
                  environment["XODUS_PRIVATE_RUNTIME_COM_STA"] == nil,
                  environment["WINEDLLOVERRIDES"] == nil,
                  dllOverrideEvidence?.runID == "005115dd-7928-4fbc-9ffa-28379040292d",
                  dllOverrideEvidence?.receiptSHA256 == "f0041fb14f5dc9bec12fa1368697aab72b26ae36822e0d80d59ccb1d361686bb",
                  dllOverrideEvidence?.registrySHA256 == "9fe5bebba1b390f8605364085c3e917d32b2090f18bc0a59a454b6d0573204f1",
                  dllOverrideEvidence?.scope.isEmpty == false else { throw NativeLaunchError.invalidProfile }
        } else if dllOverrideEvidence != nil { throw NativeLaunchError.invalidProfile }
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
        try validate(productID: productID)
        for file in (requiredFiles ?? []) + (prefixRegistryImports ?? []) + (prefixOverlays ?? []) {
            try await file.validate()
        }
        guard prefixRegistryImports != nil || prefixOverlays != nil || dllOverrides != nil else { return base }
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
        if let dllOverrides {
            guard engine == self.engine,
                  var environment = engines[index]["environment"] as? [String: String],
                  let original = environment["WINEDLLOVERRIDES"], !original.isEmpty,
                  !original.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !original.split(separator: ";").contains(where: { clause in
                      let names = clause.prefix(while: { $0 != "=" }).split(separator: ",").map {
                          $0.trimmingCharacters(in: .whitespaces).lowercased()
                      }
                      return names.contains("msvcp140_2") || names.contains("vcruntime140_1")
                  }) else { throw NativeLaunchError.invalidProfile }
            environment["WINEDLLOVERRIDES"] = original + ";" + dllOverrides
            engines[index]["environment"] = environment
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
    var admittedSelection: AdmittedEngineSelection? = nil

    static func resolve(game: InstalledGame, provider: RuntimeProviderKind?,
                        defaults: UserDefaults = .standard,
                        runtime: NativeRuntimeReference? = NativeRuntimePins.approved,
                        shims: NativeShimReference = .approved,
                        provenEngine: String? = nil, evidence: MacGameEvidence.Game? = nil) throws -> Self {
        let localRuntime = try defaults.data(forKey: "Xodus.lifecycle.runtime")
            .map { try JSONDecoder().decode(NativeLocalRuntime.self, from: $0).reference }
        var profile = try NativeTitleLaunchProfile.read(productID: game.storeId, defaults: defaults,
                                                       provider: provider, evidence: evidence)
        let qualified = NativeWorkingLaunchRecipe.admitted(productID: game.storeId, evidence: evidence)
        let candidate = qualified != nil ? nil : try NativeCandidateLaunchCatalogue.row(productID: game.storeId)
        if let candidate {
            try candidate.validateManifest(folder: URL(fileURLWithPath: game.folder))
            guard profile?.engine == candidate.profile, profile?.executable == candidate.manifest_executable else {
                throw NativeLaunchError.invalidProfile
            }
        }
        guard let runtime = profile?.runtime?.reference ?? runtime ?? localRuntime else { throw NativeLaunchError.runtimeNotQualified }
        guard let registryPath = defaults.string(forKey: "Xodus.lifecycle.registry"),
              registryPath.hasPrefix("/") else { throw NativeLaunchError.registryMissing }
        let registryURL = URL(fileURLWithPath: registryPath)
        let registry = try NativeEngineRegistry.read(registryURL)
        var entry = try selectEngine(registry: registry,
                                     provider: qualified != nil || profile?.engine != nil || candidate != nil || profile?.dllOverrides != nil ? nil : provider, defaults: defaults,
                                     provenEngine: profile?.engine ?? provenEngine)
        try candidate?.validateEngine(entry, fallback: defaults.string(forKey: "Xodus.lifecycle.fallback.\(game.storeId)"))
        if let qualified {
            guard let profile else { throw NativeLaunchError.invalidProfile }
            try qualified.validate(profile, entry: entry,
                fallback: defaults.string(forKey: "Xodus.lifecycle.fallback.\(game.storeId)"))
        }
        if profile?.dllOverrides != nil {
            guard entry.name == profile?.engine,
                  defaults.string(forKey: "Xodus.lifecycle.fallback.\(game.storeId)") == nil,
                  (profile?.unsetEnvironment ?? []).allSatisfy({ entry.environment?[$0] == nil }) else {
                throw NativeLaunchError.invalidProfile
            }
        }
        if let profile, profile.environment["XODUS_PRIVATE_RUNTIME_COM_STA"] == "1" {
            guard profile.engine == entry.name,
                  (profile.unsetEnvironment ?? []).allSatisfy({ entry.environment?[$0] == nil }),
                  entry.environment?["XODUS_PRIVATE_RUNTIME_COM_STA"].map({ $0 == "1" }) ?? true else {
                throw NativeLaunchError.invalidProfile
            }
        }
        if let selected = defaults.string(forKey: "Xodus.lifecycle.fallback.\(game.storeId)") {
            let titleProfile = profile ?? NativeTitleLaunchProfile(version: 1, productID: game.storeId,
                engine: entry.name, shimDirectory: nil, environment: [:])
            let fallback = try titleProfile.applyingFallback(selected, baseEngine: entry.name)
            guard let library = fallback.launchEnvironment["CX_APPLEGPTK_LIBD3DSHARED_PATH"],
                  let sibling = registry.engines.first(where: { $0.name == selected }),
                  sibling.isAvailable, sibling.wine == entry.wine,
                  sibling.environment == (entry.environment ?? [:]).merging(
                    ["CX_APPLEGPTK_LIBD3DSHARED_PATH": library],
                    uniquingKeysWith: { _, selected in selected }) else {
                throw NativeLaunchError.invalidProfile
            }
            entry = sibling
            profile = fallback
        }
        let engineName = entry.name
        guard entry.wine.hasPrefix("/"), RunnerAvailabilityDetector.isExecutable(URL(fileURLWithPath: entry.wine)) else {
            throw NativeLaunchError.engineUnavailable
        }
        let prefix = qualified?.prefix ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/Xodus/Prefixes/\(game.id.uuidString)/\(engineName)")
        try GameScriptFiles.checkPath(prefix, allowMissing: true)
        if let selected = profile?.shimDirectory, selected != shims.directory.path {
            throw NativeLaunchError.invalidProfile
        }
        var admitted: AdmittedEngineSelection?
        if entry.provider?.id == "calimocho" {
            guard let bytes = defaults.data(forKey: AdmittedEngineSelection.preferenceKey) else {
                throw NativeLaunchError.engineUnavailable
            }
            let selection = try JSONDecoder().decode(AdmittedEngineSelection.self, from: bytes)
            try selection.validate(registryPath: registryURL.path, engineName: entry.name,
                                   registryDigest: registry.byteDigest)
            admitted = selection
        }
        return Self(engine: engineName, registry: registryURL, prefix: prefix, runtime: runtime,
                        profile: profile, shims: shims, admittedSelection: admitted)
    }

    static func selectEngine(registry: NativeEngineRegistry, provider: RuntimeProviderKind?,
                             defaults: UserDefaults, provenEngine: String?) throws -> NativeEngineRegistry.Entry {
        let selected = provider.flatMap { defaults.string(forKey: "Xodus.lifecycle.engine.\($0.rawValue)") }
        if provider != nil || provenEngine != nil {
            guard let name = provider != nil ? selected : provenEngine,
                  let entry = registry.engines.first(where: { $0.name == name }),
                  provider.map({ EngineManagementPolicy.matches(entry, provider: $0)
                      || ($0 == .standaloneWine && entry.provider?.id == "calimocho"
                          && defaults.data(forKey: AdmittedEngineSelection.preferenceKey) != nil) }) ?? true,
                  entry.isAvailable else {
                throw NativeLaunchError.engineUnavailable
            }
            return entry
        }
        let available = registry.engines.filter { $0.isAvailable && $0.provider?.id != "calimocho" }
        guard let entry = available.first(where: { $0.engine_label == "Free Wine" || $0.kind.lowercased() == "free" })
                ?? available.first else { throw NativeLaunchError.engineUnavailable }
        return entry
    }

    func arguments() async throws -> [String] {
        if admittedSelection != nil {
            guard profile?.prefixRegistryImports == nil, profile?.prefixOverlays == nil,
                  profile?.dllOverrides == nil else { throw NativeLaunchError.invalidProfile }
        }
        let dll = try await runtime.validate()
        try await shims.validate()
        let selectedRegistry = try await profile?.registryForLaunch(base: registry, engine: engine) ?? registry
        if let admittedSelection {
            guard selectedRegistry == registry, let digest = admittedSelection.inspection.registrySha256 else {
                throw NativeLaunchError.engineUnavailable
            }
            return ["--engine", engine, "--registry", selectedRegistry.path,
                    "--expected-registry-sha256", digest, "--prefix", prefix.path,
                    "--runtime-dll", dll.path, "--shim-dir", shims.directory.path] + (profile?.arguments ?? [])
        }
        return ["--engine", engine, "--registry", selectedRegistry.path, "--prefix", prefix.path,
                "--runtime-dll", dll.path, "--shim-dir", shims.directory.path] + (profile?.arguments ?? [])
    }
}

enum NativeLaunchError: Error, LocalizedError {
    case candidateBlocked(String)
    case runtimeNotQualified, registryMissing, engineNotSelected, engineUnavailable, invalidProfile, shimsUnavailable,
         installationNotReady
    var errorDescription: String? {
        switch self {
        case .candidateBlocked(let reason): reason
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
