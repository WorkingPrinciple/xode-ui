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
        let wineserver: String?
        let sha256: String?
        let wineserver_sha256: String?
        let smoke_test: SmokeTest?
        let presentation_validation: SmokeTest?
        let engine_label: String?
        let environment: [String: String]?
        let version: String?
        let source_url: String?
        let provider: Provider?
        var id: String { name }
        var isAvailable: Bool {
            (smoke_test?.status == "pass"
                || name == NativeFH6Recipe.engineName && provider?.id == "calimocho"
                    && sha256 == CalimochoReleasePin.release06.wineSha256
                    && wineserver_sha256 == CalimochoReleasePin.release06.wineserverSha256)
                && presentation_validation?.status != "failed"
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
                    == "fee9bff4b12a11949292e3c10eb27cf89d5894e3f822fc6486904af48d2a8218" else {
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
    var wineSha256: String? = nil
    var wineserverSha256: String? = nil
    var timeoutSeconds: UInt? = nil
    var noAutoDismiss: Bool? = nil
    var runtime: NativeLocalRuntime? = nil
    var requiredFiles: [PinnedFile]? = nil
    var prefixRegistryImports: [PinnedFile]? = nil
    var prefixOverlays: [PinnedFile]? = nil
    var provider: RuntimeProviderKind? = nil
    var dllOverrides: String? = nil
    var dllOverrideEvidence: DLLOverrideEvidence? = nil
    var preservedPrefixPath: String? = nil
    var registrySHA256: String? = nil
    /// Reviewed backend game-only recipe (L6 `--game-recipe`, producer 01b333e7+); never a free-form override.
    var gameRecipe: String? = nil
    /// Reviewed scoped popup rules (L6 producer #2 `--auto-dismiss-rules`); conflicts with `noAutoDismiss`.
    var autoDismissRules: String? = nil

    func enginePinsMatch(_ inspection: EngineInspection) -> Bool {
        guard let engine else { return true }
        guard engine == inspection.engineName else { return false }
        if wineSha256 == nil && wineserverSha256 == nil { return true }
        guard let wineSha256, let wineserverSha256 else { return false }
        return wineSha256 == inspection.wineSha256 && wineserverSha256 == inspection.wineserverSha256
    }

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

    /// Validates a decoded profile exactly as a local profile is validated (used by checks).
    func validatedForChecks() throws -> Self { try validate(productID: productID); return self }

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
        if wineSha256 != nil || wineserverSha256 != nil {
            guard let engine, let pin = engine == NativeFH6Recipe.engineName
                    ? CalimochoReleasePin.release06 : CalimochoReleasePin.named(engine),
                  wineSha256 == pin.wineSha256, wineserverSha256 == pin.wineserverSha256 else {
                throw NativeLaunchError.invalidProfile
            }
        }
        if self.productID == NativeFH6Recipe.productID || engine == NativeFH6Recipe.engineName {
            try NativeFH6Recipe.validate(profile: self)
        }
        if preservedPrefixPath != nil || registrySHA256 != nil {
            guard productID == "BQVQTL3PCH05",
                  engine == "calimocho-wine11.20-gptk4b3-tls-vulkan-private",
                  preservedPrefixPath == "${HOME}/Library/Application Support/XodusCLI/prefixes/req71-nms-calimocho-port11b-v1",
                  registrySHA256 == "170ca4ad08a5274b614e74bf740866ef219a97fdc7855270c5d8fa03192ed609",
                  executable == "Binaries/NMS.exe", noAutoDismiss == true,
                  environment == ["XODUS_PRIVATE_LOCAL_SAVES": "1", "XODUS_XBL_ONLINE": "1"],
                  runtime?.primarySHA256 == "6c9d97d3b1690c6c314d303be5d6da82f630808fc33a57395c8e102216a802a8",
                  runtime?.legacySHA256 == "cfe7e5f837fabc51b8066809ca69c2ee0a7852512afbb1979190ec495b0b8b96",
                  prefixRegistryImports == nil, prefixOverlays == nil, dllOverrides == nil else {
                throw NativeLaunchError.invalidProfile
            }
        }
        if let autoDismissRules {
            guard noAutoDismiss != true, NativeAutoDismissRules.productID(for: autoDismissRules) == productID else {
                throw NativeLaunchError.invalidProfile
            }
        }
        if let gameRecipe {
            guard NativeGameRecipe.productID(for: gameRecipe) == productID, let engine,
                  engine != NativeFH6Recipe.engineName, CalimochoReleasePin.named(engine) != nil,
                  wineSha256 != nil, wineserverSha256 != nil,
                  dllOverrides == nil, environment["WINEDLLOVERRIDES"] == nil,
                  prefixRegistryImports == nil, prefixOverlays == nil, preservedPrefixPath == nil,
                  registrySHA256 == nil else { throw NativeLaunchError.invalidProfile }
        }
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

    /// Probe/QA arguments, including the profile's qualification time bound.
    var arguments: [String] {
        var result: [String] = []
        if let executable { result += ["--exe", executable] }
        if let timeoutSeconds { result += ["--timeout-seconds", String(timeoutSeconds)] }
        if noAutoDismiss == true { result += ["--no-auto-dismiss"] }
        if let autoDismissRules { result += ["--auto-dismiss-rules", autoDismissRules] }
        if let gameRecipe { result += ["--game-recipe", gameRecipe] }
        return result
    }

    /// User Play arguments: a qualification time bound must never end a player's session.
    var playArguments: [String] {
        var result: [String] = []
        if let executable { result += ["--exe", executable] }
        if noAutoDismiss == true { result += ["--no-auto-dismiss"] }
        if let autoDismissRules { result += ["--auto-dismiss-rules", autoDismissRules] }
        if let gameRecipe { result += ["--game-recipe", gameRecipe] }
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

    static func validateOverride(_ selection: AdmittedEngineSelection, game: InstalledGame,
                                 defaults: UserDefaults = .standard) throws {
        try NativeFH6Recipe.requireEnabled(productID: game.storeId)
        if let engine = selection.inspection.engineName {
            try NativeFH6Recipe.validate(game: game, engine: engine)
        }
        let provider = selection.inspection.admittedProvider
        guard AdmittedProviderScope.permits(provider, productID: game.storeId) else {
            throw NativeLaunchError.providerNotAdmitted
        }
        // A title-scoped provider owns its launch contract; the title's Calimocho profile doesn't apply.
        if AdmittedProviderScope.isTitleScoped(provider) { return }
        let profile = try NativeTitleLaunchProfile.read(productID: game.storeId, defaults: defaults,
                                                       provider: .calimocho)
        if let profile {
            guard profile.enginePinsMatch(selection.inspection),
                  profile.registrySHA256.map({ $0 == selection.inspection.registrySha256 }) ?? true else {
                throw NativeLaunchError.configurationConflict
            }
        }
    }

    @MainActor static func resolveDefault(game: InstalledGame, configuration: BackendConfiguration,
                               provider: RuntimeProviderKind?, defaults: UserDefaults = .standard,
                               runtime: NativeRuntimeReference? = NativeRuntimePins.approved,
                               evidence: MacGameEvidence.Game? = nil,
                               engineDefaults: NativeEngineDefaults? = nil) async throws -> Self {
        try NativeFH6Recipe.requireEnabled(productID: game.storeId)
        guard provider == nil || provider == .calimocho else { throw NativeLaunchError.providerPolicy }
        let profile = try NativeTitleLaunchProfile.read(productID: game.storeId, defaults: defaults,
                                                       provider: .calimocho, evidence: evidence)
        let saved = try NativeEngineDefaults.savedAdmission(defaults: defaults)
        let catalog = try engineDefaults ?? NativeEngineDefaults.read()
        let selection: AdmittedEngineSelection
        if let override = game.engineOverrideV2 {
            guard override.version == 2, override.chosenAt.timeIntervalSince1970.isFinite else {
                throw NativeLaunchError.selectionChanged
            }
            selection = override.selection
            try validateOverride(selection, game: game, defaults: defaults)
        } else if let titleEngine = profile?.engine {
            guard let binding = catalog.bindings.first(where: { $0.engineName == titleEngine }),
                  profile?.wineSha256.map({ $0 == binding.wineSha256 }) ?? true,
                  profile?.wineserverSha256.map({ $0 == binding.wineserverSha256 }) ?? true,
                  profile?.registrySHA256.map({ $0 == binding.registrySha256 }) ?? true else {
                throw NativeLaunchError.engineUnavailable
            }
            selection = try await binding.inspect(configuration: configuration)
        } else if let saved {
            selection = saved
        } else {
            guard let binding = catalog.bindings.first(where: { $0.engineName == catalog.defaultEngine }) else {
                throw NativeLaunchError.engineNotSelected
            }
            selection = try await binding.inspect(configuration: configuration)
        }
        guard let engine = selection.inspection.engineName,
              let digest = selection.inspection.registrySha256 else { throw NativeLaunchError.engineUnavailable }
        try NativeFH6Recipe.validate(game: game, engine: engine)
        try await EngineInspectionClient().validateLaunch(configuration: configuration, arguments: [
            "--registry", selection.registryPath, "--engine", engine, "--expected-registry-sha256", digest
        ] + (engine == NativeFH6Recipe.engineName ? NativeFH6Recipe.arguments : []),
            selection: selection, product: game.storeId)
        if game.engineOverrideV2 == nil, saved == nil {
            guard let binding = catalog.bindings.first(where: { $0.engineName == catalog.defaultEngine }) else {
                throw NativeLaunchError.engineNotSelected
            }
            let defaultSelection = engine == binding.engineName ? selection : try await binding.inspect(configuration: configuration)
            defaults.set(try JSONEncoder().encode(defaultSelection), forKey: NativeEngineDefaults.preferenceKey)
            if provider == nil { EngineDefaults.setDefaultEngine(.calimocho, defaults) }
        }
        // Per-game records are retained as history, never used to route a current launch.
        var effective = game
        effective.engineOverride = .calimocho
        effective.engineSelection = selection
        return try resolve(game: effective, provider: .calimocho, defaults: defaults,
                           runtime: runtime, evidence: evidence)
    }

    static func resolve(game: InstalledGame, provider: RuntimeProviderKind?,
                        defaults: UserDefaults = .standard,
                        runtime: NativeRuntimeReference? = NativeRuntimePins.approved,
                        shims: NativeShimReference = .approved,
                        provenEngine: String? = nil, evidence: MacGameEvidence.Game? = nil,
                        detectCrossOver: () -> CrossOverDependencyState = CrossOverDetector.detect) throws -> Self {
        try resolve(game: game, provider: provider, defaults: defaults, runtime: runtime, shims: shims,
                    provenEngine: provenEngine, evidence: evidence, detectCrossOver: detectCrossOver,
                    candidateOverride: nil)
    }

    #if !XODUS_SHIPPING
    static func resolveForChecks(game: InstalledGame, defaults: UserDefaults,
                                 runtime: NativeRuntimeReference, shims: NativeShimReference,
                                 candidate: NativeCandidateLaunchCatalogue.Row) throws -> Self {
        try resolve(game: game, provider: nil, defaults: defaults, runtime: runtime, shims: shims,
                    candidateOverride: candidate)
    }
    #endif

    private static func resolve(game: InstalledGame, provider: RuntimeProviderKind?,
                                defaults: UserDefaults,
                                runtime: NativeRuntimeReference?,
                                shims: NativeShimReference,
                                provenEngine: String? = nil, evidence: MacGameEvidence.Game? = nil,
                                detectCrossOver: () -> CrossOverDependencyState = CrossOverDetector.detect,
                                candidateOverride: NativeCandidateLaunchCatalogue.Row?) throws -> Self {
        try NativeFH6Recipe.requireEnabled(productID: game.storeId)
        let localRuntime = try defaults.data(forKey: "Xodus.lifecycle.runtime")
            .map { try JSONDecoder().decode(NativeLocalRuntime.self, from: $0).reference }
        let selected: AdmittedEngineSelection?
        if game.engineOverride == .calimocho {
            guard let saved = game.engineSelection else { throw NativeLaunchError.engineNotSelected }
            selected = saved
        } else if provider == .calimocho {
            selected = try AdmittedEngineSelection.read(defaults: defaults)
        } else {
            selected = nil
        }
        let titleScoped = AdmittedProviderScope.isTitleScoped(selected?.inspection.admittedProvider)
        if let selected, !AdmittedProviderScope.permits(selected.inspection.admittedProvider, productID: game.storeId) {
            throw NativeLaunchError.providerNotAdmitted
        }
        var profile = titleScoped ? nil : try NativeTitleLaunchProfile.read(productID: game.storeId,
            defaults: defaults, provider: provider, evidence: evidence)
        if let selected, let profile {
            guard profile.enginePinsMatch(selected.inspection) else { throw NativeLaunchError.configurationConflict }
        }
        let workingRecipe = NativeWorkingLaunchRecipe.admitted(productID: game.storeId, evidence: evidence)
        let qualified = profile?.engine == NativeWorkingLaunchRecipe.engine ? workingRecipe : nil
        let releasePinnedProfile: Bool
        if let profile, let engine = profile.engine, let pin = CalimochoReleasePin.named(engine) {
            releasePinnedProfile = profile.wineSha256 == pin.wineSha256
                && profile.wineserverSha256 == pin.wineserverSha256
        } else {
            releasePinnedProfile = false
        }
        let candidate = qualified != nil || releasePinnedProfile || titleScoped
            ? nil : try candidateOverride ?? NativeCandidateLaunchCatalogue.row(productID: game.storeId)
        if let candidate {
            try candidate.validateManifest(folder: URL(fileURLWithPath: game.folder))
            guard profile?.engine == candidate.profile, profile?.executable == candidate.manifest_executable else {
                throw NativeLaunchError.invalidProfile
            }
        }
        guard let runtime = profile?.runtime?.reference ?? runtime ?? localRuntime else { throw NativeLaunchError.runtimeNotQualified }
        guard let registryPath = selected?.registryPath ?? defaults.string(forKey: "Xodus.lifecycle.registry"),
              registryPath.hasPrefix("/") else { throw NativeLaunchError.registryMissing }
        let registryURL = URL(fileURLWithPath: registryPath)
        let registry = try NativeEngineRegistry.read(registryURL)
        if let selected {
            guard let engine = selected.inspection.engineName else { throw NativeLaunchError.engineUnavailable }
            try selected.validate(registryPath: registryPath, engineName: engine, registryDigest: registry.byteDigest)
        }
        if let digest = profile?.registrySHA256 {
            guard selected != nil, digest == registry.byteDigest else { throw NativeLaunchError.engineUnavailable }
        }
        var entry = try selectEngine(registry: registry,
                                     provider: selected != nil || qualified != nil || profile?.engine != nil || candidate != nil || profile?.dllOverrides != nil ? nil : provider, defaults: defaults,
                                     provenEngine: selected?.inspection.engineName ?? profile?.engine ?? provenEngine,
                                     scopedAdmission: titleScoped)
        if let selected {
            guard entry.sha256 == selected.inspection.wineSha256,
                  entry.wineserver_sha256 == selected.inspection.wineserverSha256,
                  entry.wineserver?.hasPrefix("/") == true else {
                throw NativeLaunchError.selectionChanged
            }
        }
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
        if selected != nil, defaults.string(forKey: "Xodus.lifecycle.fallback.\(game.storeId)") != nil {
            throw NativeLaunchError.configurationConflict
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
        try NativeFH6Recipe.validate(game: game, engine: engineName)
        guard entry.wine.hasPrefix("/"), RunnerAvailabilityDetector.isExecutable(URL(fileURLWithPath: entry.wine)) else {
            throw NativeLaunchError.engineUnavailable
        }
        if entry.kind.lowercased() == "crossover", !detectCrossOver().isVerified {
            throw NativeLaunchError.engineUnavailable
        }
        if profile?.preservedPrefixPath != nil {
            guard permitsPreservedNMSInstallation(game) else {
                throw NativeLaunchError.configurationConflict
            }
        }
        let prefixRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Application Support/Xodus/Prefixes")
        let titlePrefix = engineName == NativeFH6Recipe.engineName
            ? NativeFH6Recipe.prefix(root: prefixRoot) : nil
        let prefix = profile?.preservedPrefixPath.map { URL(fileURLWithPath: NativeTitleLaunchProfile.expand($0)) }
            ?? qualified?.prefix ?? titlePrefix ?? CalimochoPrefixContinuity.location(
                productID: game.storeId, installationID: game.id, engine: engineName,
                root: prefixRoot)
        try GameScriptFiles.checkPath(prefix, allowMissing: true)
        if let selected = profile?.shimDirectory, selected != shims.directory.path {
            throw NativeLaunchError.invalidProfile
        }
        var admitted = selected
        if admitted == nil, entry.provider?.id == "calimocho" {
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

    static func permitsPreservedNMSInstallation(_ game: InstalledGame, home: String = NSHomeDirectory()) -> Bool {
        game.storeId == "BQVQTL3PCH05" && game.identityName == "HelloGames.NoMansSky"
            && GameInstallationDiscovery.defaultLibraryRoots(home: home).contains {
                game.folder == $0.appendingPathComponent("NoMansSky-Xbox").path
            }
    }

    /// `scopedAdmission`: a CrossOver/Highball engine whose title-scoped backend admission was freshly
    /// verified; its availability is that admission plus an executable Wine, not a registry smoke test.
    static func selectEngine(registry: NativeEngineRegistry, provider: RuntimeProviderKind?,
                             defaults: UserDefaults, provenEngine: String?,
                             scopedAdmission: Bool = false) throws -> NativeEngineRegistry.Entry {
        let selected = provider.flatMap { defaults.string(forKey: "Xodus.lifecycle.engine.\($0.rawValue)") }
        if provider != nil || provenEngine != nil {
            guard let name = provider != nil ? selected : provenEngine,
                  let entry = registry.engines.first(where: { $0.name == name }),
                  provider.map({ EngineManagementPolicy.matches(entry, provider: $0)
                      || ($0 == .standaloneWine && entry.provider?.id == "calimocho"
                          && defaults.data(forKey: AdmittedEngineSelection.preferenceKey) != nil) }) ?? true,
                  entry.isAvailable || scopedAdmission && entry.wine.hasPrefix("/")
                    && RunnerAvailabilityDetector.isExecutable(URL(fileURLWithPath: entry.wine)) else {
                throw NativeLaunchError.engineUnavailable
            }
            return entry
        }
        throw NativeLaunchError.engineNotSelected
    }

    func arguments() async throws -> [String] {
        _ = try await prefixNotice()
        if admittedSelection != nil {
            guard profile?.prefixRegistryImports == nil, profile?.prefixOverlays == nil,
                  profile?.dllOverrides == nil else { throw NativeLaunchError.invalidProfile }
        }
        let dll = try await runtime.validate()
        if engine == NativeFH6Recipe.engineName {
            guard let profile, admittedSelection != nil else { throw NativeLaunchError.titleRecipeUnavailable }
            try NativeFH6Recipe.validate(profile: profile)
        } else {
            try await shims.validate()
        }
        let selectedRegistry = try await profile?.registryForLaunch(base: registry, engine: engine) ?? registry
        if let admittedSelection {
            guard selectedRegistry == registry, let digest = admittedSelection.inspection.registrySha256 else {
                throw NativeLaunchError.engineUnavailable
            }
            return ["--engine", engine, "--registry", selectedRegistry.path,
                    "--expected-registry-sha256", digest, "--prefix", prefix.path,
                    "--runtime-dll", dll.path]
                + (engine == NativeFH6Recipe.engineName ? NativeFH6Recipe.arguments : ["--shim-dir", shims.directory.path])
                + (profile?.playArguments ?? [])
        }
        return ["--engine", engine, "--registry", selectedRegistry.path, "--prefix", prefix.path,
                "--runtime-dll", dll.path, "--shim-dir", shims.directory.path] + (profile?.playArguments ?? [])
    }

    func prefixNotice() async throws -> String? {
        guard let selection = admittedSelection else { return nil }
        return try await Task.detached {
            try GameScriptFiles.checkPath(prefix, allowMissing: true)
            let marker = prefix.deletingLastPathComponent()
                .appendingPathComponent(".\(prefix.lastPathComponent).xodus-engine-owner.json")
            try GameScriptFiles.checkPath(marker, allowMissing: true)
            if FileManager.default.fileExists(atPath: marker.path) {
                let bytes = try InstalledGameFiles.readRegular(marker, maximumBytes: 4_096)
                if let pin = CalimochoReleasePin.named(engine),
                   prefix.lastPathComponent == CalimochoPrefixContinuity.family(pin),
                   try CalimochoPrefixContinuity.markerMatches(bytes, pin: pin) {
                    return nil
                }
                let value = try JSONValue.decodeUnique(bytes, maximumBytes: 4_096)
                guard case .object(let fields) = value,
                      Set(fields.keys) == ["version", "engine", "wine_sha256"],
                      fields["version"]?.uint64 == 1,
                      fields["engine"]?.string == engine,
                      fields["wine_sha256"]?.string == selection.inspection.wineSha256 else {
                    throw NativeLaunchError.prefixConflict
                }
                return nil
            }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: prefix.path, isDirectory: &directory) {
                guard directory.boolValue else { throw NativeLaunchError.prefixConflict }
                let members = try FileManager.default.contentsOfDirectory(atPath: prefix.path)
                if !members.isEmpty {
                    return "This existing prefix is legacy-unclaimed. It will be used as-is, without claiming ownership, migrating files or moving saves."
                }
            }
            return nil
        }.value
    }
}

enum NativeLaunchError: Error, LocalizedError {
    case titleRecipeUnavailable
    case prefixContinuity(String)
    case candidateBlocked(String)
    case runtimeNotQualified, registryMissing, engineNotSelected, engineUnavailable, invalidProfile, shimsUnavailable,
         installationNotReady, configurationConflict, legacyLauncher, prefixConflict, providerPolicy,
         selectionChanged, providerNotAdmitted
    var errorDescription: String? {
        switch self {
        case .titleRecipeUnavailable:
            "Forza Horizon 6 needs its verified Calimocho title recipe and prefix preparation support. Refresh Engines or install the matching app update. No game was started or plain Calimocho engine substituted."
        case .prefixContinuity(let detail):
            "The previous Calimocho prefix couldn't be preserved: \(detail). The game wasn't started. The previous prefix was kept."
        case .candidateBlocked(let reason): reason
        case .runtimeNotQualified:
            "This game's tested runtime isn't set up on this Mac. Open Engines to choose the runtime it needs. No other runtime was substituted."
        case .registryMissing:
            "No engine is set up for this game. Open Engines to choose one before playing."
        case .engineNotSelected:
            "Choose a verified Calimocho build in Engines before playing. No CrossOver or GPTK engine was substituted."
        case .configurationConflict:
            "This game's launch recipe does not match the selected Calimocho configuration. No engine or prefix was substituted. Choose a matching verified configuration."
        case .legacyLauncher:
            "This legacy launch script cannot verify the selected Calimocho configuration. Use the connected \(AppBrand.displayName) lifecycle service; the script was not started."
        case .prefixConflict:
            "This prefix has conflicting or invalid ownership, or multiple previous prefixes were found. The game wasn't started. Existing saved data was kept. Choose a matching configuration."
        case .providerPolicy:
            "Only a verified Calimocho configuration can be launched in \(AppBrand.displayName). Historical CrossOver, GPTK and generic Wine choices are retained but cannot run. Choose Calimocho in Engines."
        case .selectionChanged:
            "The saved Calimocho configuration has changed. Refresh and explicitly select the verified build again. No other engine was substituted."
        case .providerNotAdmitted:
            "This Calimocho configuration has not passed artifact admission. Refresh its registry in Engines. It cannot launch or fall back to another provider."
        case .engineUnavailable:
            "The engine this game uses isn't available on this Mac. Open Engines to restore it or choose another. No other engine was substituted."
        case .invalidProfile:
            "The title's local launch profile is invalid. Check its product ID and use the verified native-web-shims-v1 folder, separate from the game runtime."
        case .shimsUnavailable:
            "The native sign-in components are missing or have changed. Restore native-web-shims-v1 before playing."
        case .installationNotReady:
            "This installation isn't verified complete. Check it, download it again or repair it before playing."
        }
    }
}

/// Reviewed backend game recipes: each changes only its own title's game process (never prefix setup) and is
/// admitted by the backend only on an exact production release engine.
enum NativeGameRecipe {
    static let known: [String: String] = ["hades-mscoree-v1": "9P8DL6W0JBB8"]
    static func productID(for recipe: String) -> String? { known[recipe] }
}

/// Reviewed scoped popup rules: only the named dialog is pressed; generic Continue/OK rules stay off.
enum NativeAutoDismissRules {
    static let known: [String: String] = ["fh6-compat": "9NR1R1XWLCNB"]
    static func productID(for rules: String) -> String? { known[rules] }
}
