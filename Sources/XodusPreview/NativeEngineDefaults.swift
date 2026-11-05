// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin
import XodusManagement

struct NativeEngineDefaults: Decodable {
    struct Binding: Decodable, Sendable {
        let registryPath: String?
        let registrySha256: String?
        let engineName: String
        let wineSha256: String
        let wineserverSha256: String

        var release: CalimochoReleasePin? {
            guard registryPath == nil, registrySha256 == nil,
                  let pin = CalimochoReleasePin.named(engineName),
                  pin.wineSha256 == wineSha256, pin.wineserverSha256 == wineserverSha256 else { return nil }
            return pin
        }

        func registry(enginesRoot: URL = CalimochoReleaseEngines.defaultEnginesRoot,
                      registries: URL = CalimochoReleaseEngines.defaultRegistriesRoot,
                      checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> (String, String) {
            try checkCancellation()
            if let release {
                let engine = try CalimochoReleaseEngines.verify(release, root: enginesRoot,
                                                               checkCancellation: checkCancellation)
                try checkCancellation()
                let rendered = try CalimochoReleaseEngines.renderRegistry(engine, registries: registries)
                try checkCancellation()
                return (rendered.url.path, rendered.digest)
            }
            guard let registryPath, let registrySha256 else { throw NativeLaunchError.invalidProfile }
            let path = NativeTitleLaunchProfile.expand(registryPath)
            let registry = URL(fileURLWithPath: path)
            try GameScriptFiles.checkPath(registry)
            let bytes = try InstalledGameFiles.readRegular(registry, maximumBytes: 2_097_152)
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == registrySha256 else {
                throw NativeLaunchError.selectionChanged
            }
            return (path, registrySha256)
        }

        @MainActor func inspect(configuration: BackendConfiguration,
                                inspector: EngineInspectionClient = EngineInspectionClient(),
                                enginesRoot: URL = CalimochoReleaseEngines.defaultEnginesRoot,
                                registries: URL = CalimochoReleaseEngines.defaultRegistriesRoot,
                                verification: CalimochoVerificationWork = CalimochoVerificationWork()) async throws -> AdmittedEngineSelection {
            let (path, digest) = try await verification.run { cancellation in
                try registry(enginesRoot: enginesRoot, registries: registries,
                             checkCancellation: cancellation.check)
            }
            try Task.checkCancellation()
            let result = try await inspector.inspect(executable: configuration.executable,
                registry: URL(fileURLWithPath: path), engine: engineName, expectedDigest: digest,
                executableIdentity: configuration.executableIdentity,
                recordTimeout: release == nil ? .seconds(5) : .seconds(90))
            if !result.ready, let failure = result.error {
                throw EngineInspectionError.rejected(failure)
            }
            let selection = AdmittedEngineSelection(registryPath: path, inspection: result)
            try selection.validate(registryPath: path, engineName: engineName, registryDigest: digest)
            guard result.wineSha256 == wineSha256, result.wineserverSha256 == wineserverSha256 else {
                throw NativeLaunchError.selectionChanged
            }
            return selection
        }
    }

    let version: Int
    let defaultEngine: String
    let bindings: [Binding]
    static let preferenceKey = "Xodus.lifecycle.defaultAdmission.v2"
    static let automaticKey = "Xodus.lifecycle.automaticDefault.v1"

    struct Automatic: Codable, Equatable {
        let selection: AdmittedEngineSelection
        let home: String
        let enginesRoot: String
        let registriesRoot: String
        var previousHomes: [String]? = nil

        func validates(_ selected: AdmittedEngineSelection, home: URL,
                       enginesRoot: URL, registries: URL) throws -> Bool {
            guard selection == selected,
                  self.home.hasPrefix("/"), URL(fileURLWithPath: self.home).standardizedFileURL.path == self.home,
                  self.enginesRoot == self.home + "/Library/Application Support/Xode/Engines",
                  registriesRoot == self.home + "/Library/Application Support/Xodus/EngineRegistries",
                  enginesRoot.path == home.path + "/Library/Application Support/Xode/Engines",
                  registries.path == home.path + "/Library/Application Support/Xodus/EngineRegistries",
                  (previousHomes ?? []).count <= 16,
                  (previousHomes ?? []).allSatisfy({
                      $0.hasPrefix("/") && $0 != "/"
                          && URL(fileURLWithPath: $0).standardizedFileURL.path == $0
                  }),
                  let engine = selected.inspection.engineName,
                  let pin = CalimochoReleasePin.named(engine),
                  selected.inspection.wineSha256 == pin.wineSha256,
                  selected.inspection.wineserverSha256 == pin.wineserverSha256,
                  let digest = selected.inspection.registrySha256,
                  selected.registryPath == registriesRoot + "/\(engine)-ode-default-v2-\(digest).json" else {
                return false
            }
            try selected.validate(registryPath: selected.registryPath, engineName: engine, registryDigest: digest)
            return true
        }
    }

    /// Captured before asynchronous work; checked again without suspension before any preference write.
    struct PreferenceSnapshot: Equatable {
        static let keys = [EngineDefaults.defaultEngineKey, EngineDefaults.choiceRevisionKey, preferenceKey, automaticKey,
                           AdmittedEngineSelection.preferenceKey, "Xodus.lifecycle.registry",
                           "Xodus.lifecycle.engine.calimocho"]
        private let values: NSDictionary

        init(_ defaults: UserDefaults) {
            values = NSDictionary(dictionary: Dictionary(uniqueKeysWithValues:
                Self.keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } }))
        }
    }

    static func saved(defaults: UserDefaults) throws -> AdmittedEngineSelection? {
        guard let value = defaults.object(forKey: preferenceKey) else { return nil }
        guard let bytes = value as? Data else { throw NativeLaunchError.selectionChanged }
        return try JSONDecoder().decode(AdmittedEngineSelection.self, from: bytes)
    }

    static func automatic(defaults: UserDefaults, selection: AdmittedEngineSelection,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          enginesRoot: URL = CalimochoReleaseEngines.defaultEnginesRoot,
                          registries: URL = CalimochoReleaseEngines.defaultRegistriesRoot) throws -> Automatic? {
        guard let data = defaults.data(forKey: automaticKey) else { return nil }
        let record = try JSONDecoder().decode(Automatic.self, from: data)
        return try record.validates(selection, home: home, enginesRoot: enginesRoot, registries: registries)
            ? record : nil
    }

    @MainActor static func commitAutomatic(_ selection: AdmittedEngineSelection,
                                          expected: PreferenceSnapshot, defaults: UserDefaults,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          enginesRoot: URL = CalimochoReleaseEngines.defaultEnginesRoot,
                                          registries: URL = CalimochoReleaseEngines.defaultRegistriesRoot) throws {
        guard PreferenceSnapshot(defaults) == expected,
              try mayPrepareAutomatically(defaults: defaults, home: home,
                                           enginesRoot: enginesRoot, registries: registries) else {
            throw NativeLaunchError.automaticSelectionChanged
        }
        guard let engine = selection.inspection.engineName, let digest = selection.inspection.registrySha256,
              let pin = CalimochoReleasePin.named(engine),
              selection.inspection.wineSha256 == pin.wineSha256,
              selection.inspection.wineserverSha256 == pin.wineserverSha256,
              selection.registryPath == registries.appendingPathComponent(
                "\(engine)-ode-default-v2-\(digest).json").path else {
            throw NativeLaunchError.selectionChanged
        }
        try selection.validate(registryPath: selection.registryPath, engineName: engine, registryDigest: digest)
        let registry = try NativeEngineRegistry.read(URL(fileURLWithPath: selection.registryPath))
        guard registry.byteDigest == digest, registry.engines.count == 1,
              let entry = registry.engines.first, entry.name == engine,
              entry.sha256 == pin.wineSha256, entry.wineserver_sha256 == pin.wineserverSha256,
              entry.wine == enginesRoot.appendingPathComponent("\(engine)/bin/wine").path,
              entry.wineserver == enginesRoot.appendingPathComponent("\(engine)/bin/wineserver").path,
              entry.provider?.id == "calimocho", entry.provider?.contract_version == 1 else {
            throw NativeLaunchError.selectionChanged
        }
        var record = Automatic(selection: selection, home: home.path, enginesRoot: enginesRoot.path,
                               registriesRoot: registries.path)
        if let prior = try saved(defaults: defaults) {
            if let automatic = try automatic(defaults: defaults, selection: prior, home: home,
                                             enginesRoot: enginesRoot, registries: registries) {
                record.previousHomes = Array(Set((automatic.previousHomes ?? []) + [automatic.home]))
                    .filter { $0 != home.path }.sorted()
            } else if try missingAutomaticLegacyDefault(prior, defaults: defaults, home: home),
                      let range = prior.registryPath.range(of: "/src/copilot-worktrees/calimocho/") {
                let oldHome = String(prior.registryPath[..<range.lowerBound])
                if oldHome != home.path { record.previousHomes = [oldHome] }
            }
        }
        guard (record.previousHomes ?? []).count <= 16 else { throw NativeLaunchError.selectionChanged }
        // Test/development custom roots may be explicitly prepared, but are never home-migration records.
        let bytes = try JSONEncoder().encode(selection)
        let provenance = try JSONEncoder().encode(record)
        guard PreferenceSnapshot(defaults) == expected else { throw NativeLaunchError.automaticSelectionChanged }
        defaults.set(bytes, forKey: preferenceKey)
        defaults.set(bytes, forKey: AdmittedEngineSelection.preferenceKey)
        defaults.set(selection.registryPath, forKey: "Xodus.lifecycle.registry")
        EngineDefaults.setDefaultEngine(.calimocho, defaults)
        defaults.set(provenance, forKey: automaticKey)
    }

    static func mayPrepareAutomatically(defaults: UserDefaults,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       enginesRoot: URL = CalimochoReleaseEngines.defaultEnginesRoot,
                                       registries: URL = CalimochoReleaseEngines.defaultRegistriesRoot) throws -> Bool {
        if let value = defaults.object(forKey: EngineDefaults.defaultEngineKey) {
            guard let raw = value as? String, raw == "calimocho" else { return false }
        } else if defaults.object(forKey: EngineDefaults.choiceRevisionKey) != nil {
            return false
        }
        guard defaults.string(forKey: "Xodus.lifecycle.engine.calimocho")?.isEmpty != false else { return false }
        guard let selected = try saved(defaults: defaults) else {
            // A legacy Settings choice remains explicit even if the newer preference is absent.
            return defaults.object(forKey: AdmittedEngineSelection.preferenceKey) == nil
                && defaults.string(forKey: "Xodus.lifecycle.registry")?.isEmpty != false
        }
        if let record = try automatic(defaults: defaults, selection: selected, home: home,
                                      enginesRoot: enginesRoot, registries: registries) {
            guard defaults.data(forKey: AdmittedEngineSelection.preferenceKey)
                    .map({ (try? JSONDecoder().decode(AdmittedEngineSelection.self, from: $0)) == selected }) ?? true,
                  defaults.string(forKey: "Xodus.lifecycle.registry").map({ $0 == record.selection.registryPath }) ?? true else {
                return false
            }
            let relocated = home.path + String(selected.registryPath.dropFirst(record.home.count))
            for path in Set([selected.registryPath, relocated]) {
                let url = URL(fileURLWithPath: path)
                try GameScriptFiles.checkPath(url, allowMissing: true)
                var info = stat()
                if lstat(path, &info) == 0 {
                    let bytes = try InstalledGameFiles.readRegular(url, maximumBytes: 65_536, privateFile: true)
                    guard CalimochoReleaseEngines.digest(bytes) == selected.inspection.registrySha256 else {
                        throw NativeLaunchError.selectionChanged
                    }
                } else if errno != ENOENT { throw NativeLaunchError.engineUnavailable }
            }
            return true
        }
        return try missingAutomaticLegacyDefault(selected, defaults: defaults, home: home)
    }

    static func previousAutomaticHomes(defaults: UserDefaults) throws -> [URL] {
        guard let selection = try saved(defaults: defaults) else { return [] }
        if let record = try automatic(defaults: defaults, selection: selection) {
            return Array(Set((record.previousHomes ?? []) + [record.home])).sorted().map {
                URL(fileURLWithPath: $0)
            }
        }
        if try missingAutomaticLegacyDefault(selection, defaults: defaults),
           let range = selection.registryPath.range(of: "/src/copilot-worktrees/calimocho/") {
            return [URL(fileURLWithPath: String(selection.registryPath[..<range.lowerBound]))]
        }
        return []
    }

    static func missingAutomaticLegacyDefault(_ selection: AdmittedEngineSelection,
                                              defaults: UserDefaults = .standard,
                                              home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Bool {
        let legacyName = "calimocho-wine11.20-gptk4b3-tls-vulkan-private"
        let registryDigest = "170ca4ad08a5274b614e74bf740866ef219a97fdc7855270c5d8fa03192ed609"
        let suffix = "/src/copilot-worktrees/calimocho/dragoshont-cautious-potato/build/winehq-11.20/metal-port-11b-private-binding-01"
        let filename = "/calimocho-wine11.20-gptk4b3-tls-vulkan-private.registry.local.PERF-FROZEN-170ca4ad.json"
        guard selection.registryPath.hasSuffix(suffix + filename) else { return false }
        let oldHome = String(selection.registryPath.dropLast((suffix + filename).count))
        guard oldHome.hasPrefix("/"), oldHome != "/",
              URL(fileURLWithPath: oldHome).standardizedFileURL.path == oldHome else { return false }
        let base = oldHome + suffix
        let registry = URL(fileURLWithPath: base)
            .appendingPathComponent("calimocho-wine11.20-gptk4b3-tls-vulkan-private.registry.local.PERF-FROZEN-170ca4ad.json")
        guard selection.registryPath == registry.path, selection.inspection.engineName == legacyName,
              selection.inspection.registrySha256 == registryDigest,
              selection.inspection.wineSha256 == "f6d0546fad2d0dafaa09a9fe6cabe75bb070567df6b0933ecd3622dcb6349194",
              selection.inspection.wineserverSha256 == "e3ec4e7e76cee273f17d5fa3459902642f73d6921e94c576aa74e8cdbdcd7da1",
              defaults.string(forKey: "Xodus.lifecycle.engine.calimocho")?.isEmpty != false else {
            return false
        }
        try selection.validate(registryPath: registry.path, engineName: legacyName, registryDigest: registryDigest)
        if let value = defaults.object(forKey: AdmittedEngineSelection.preferenceKey) {
            guard let bytes = value as? Data,
                  try JSONDecoder().decode(AdmittedEngineSelection.self, from: bytes) == selection else { return false }
        }
        if let path = defaults.string(forKey: "Xodus.lifecycle.registry"), !path.isEmpty,
           path != selection.registryPath { return false }
        // Only this historical automatic tuple is recognized without its removed checkout.
        // No arbitrary selection or changed registry gains migration eligibility.
        try GameScriptFiles.checkPath(registry, allowMissing: true)
        var registryInfo = stat()
        if lstat(registry.path, &registryInfo) == 0 {
            let loaded = try NativeEngineRegistry.read(registry)
            guard loaded.byteDigest == registryDigest,
              let entry = loaded.engines.first(where: { $0.name == legacyName }),
              entry.wine == base + "/install/bin/wine",
              entry.wineserver == base + "/install/bin/wineserver" else {
                throw NativeLaunchError.selectionChanged
            }
        } else if errno != ENOENT { throw NativeLaunchError.engineUnavailable }
        if oldHome != home.path {
            let movedInstall = URL(fileURLWithPath: home.path + suffix + "/install")
            try GameScriptFiles.checkPath(movedInstall, allowMissing: true)
            var moved = stat()
            if lstat(movedInstall.path, &moved) == 0 { return false }
            guard errno == ENOENT else { throw NativeLaunchError.engineUnavailable }
        }
        let install = URL(fileURLWithPath: base).appendingPathComponent("install")
        try GameScriptFiles.checkPath(install, allowMissing: true)
        var info = stat()
        if lstat(install.path, &info) == 0 { return false }
        guard errno == ENOENT else { throw NativeLaunchError.engineUnavailable }
        return true
    }

    static func read() throws -> Self {
        let bytes = try Data(contentsOf: LaunchRecipeResources.engineDefaultsURL())
        guard bytes.count <= 65_536 else { throw NativeLaunchError.invalidProfile }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.version == 1, (1...16).contains(value.bindings.count),
              Set(value.bindings.map(\.engineName)).count == value.bindings.count,
              value.bindings.contains(where: { $0.engineName == value.defaultEngine }),
              value.bindings.allSatisfy({ binding in
                  EngineInspection.validDigest(binding.wineSha256)
                    && EngineInspection.validDigest(binding.wineserverSha256)
                    && (binding.release != nil
                        || (binding.registryPath.map { NativeTitleLaunchProfile.expand($0).hasPrefix("/") } == true
                            && EngineInspection.validDigest(binding.registrySha256)))
              }) else { throw NativeLaunchError.invalidProfile }
        return value
    }
}
