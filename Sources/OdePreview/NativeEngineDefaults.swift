// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import OdeManagement
import OSLog

struct NativeEngineDefaults: Decodable {
    struct Binding: Decodable {
        /// Absent for release engines: their registry is rendered on this Mac after verification.
        let registryPath: String?
        let registrySha256: String?
        let engineName: String
        let wineSha256: String
        let wineserverSha256: String
        /// TEMPORARY (first beta, Ode decision B): a developer-local engine kept only so NMS keeps its
        /// verified engine on the owner's Mac. Elsewhere its files are absent and Play reports that.
        var developerLocal: Bool? = nil
        /// Title-scoped provider ("crossover" or "highball"); nil means Calimocho.
        var provider: String? = nil

        var admittedProvider: String { provider ?? AdmittedProviderScope.calimocho }

        /// Highball's registry has no fixed bytes: it is rendered from the backend verdict on this Mac.
        var isHighball: Bool {
            provider == AdmittedProviderScope.highball && registryPath == nil && registrySha256 == nil
                && engineName == HighballContract.engineName && wineSha256 == HighballContract.wineSha256
                && wineserverSha256 == HighballContract.wineserverSha256
        }

        var release: CalimochoReleasePin? {
            guard provider == nil, registryPath == nil, registrySha256 == nil, let pin = CalimochoReleasePin.named(engineName),
                  pin.wineSha256 == wineSha256, pin.wineserverSha256 == wineserverSha256 else { return nil }
            return pin
        }

        var isFH6Recipe: Bool {
            provider == nil && registryPath == nil && registrySha256 == nil && developerLocal != true
                && engineName == NativeFH6Recipe.engineName
                && wineSha256 == CalimochoReleasePin.release06.wineSha256
                && wineserverSha256 == CalimochoReleasePin.release06.wineserverSha256
        }

        /// Path and expected bytes digest of the registry to inspect, rendering it for release engines.
        func registry(enginesRoot: URL = CalimochoReleaseEngines.defaultEnginesRoot,
                      registries: URL = CalimochoReleaseEngines.defaultRegistriesRoot,
                      signature: (URL, String) -> Bool = CalimochoReleaseEngines.codeSignatureValid) throws -> (path: String, digest: String) {
            if let pin = release ?? (isFH6Recipe ? .release06 : nil) {
                let verified = try CalimochoReleaseEngines.verify(pin, root: enginesRoot, signature: signature)
                let rendered = try isFH6Recipe
                    ? NativeFH6Recipe.renderRegistry(verified, registries: registries)
                    : CalimochoReleaseEngines.renderRegistry(verified, registries: registries)
                return (rendered.url.path, rendered.digest)
            }
            guard let registryPath, let registrySha256 else { throw NativeLaunchError.engineUnavailable }
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
                                inspector: EngineInspectionClient = EngineInspectionClient()) async throws -> AdmittedEngineSelection {
            let (path, digest) = isHighball
                ? try await inspector.highballRegistry(executable: configuration.executable,
                    executableIdentity: configuration.executableIdentity,
                    registries: CalimochoReleaseEngines.defaultRegistriesRoot)
                : try registry()
            let result = try await inspector.inspect(executable: configuration.executable,
                registry: URL(fileURLWithPath: path), engine: engineName, expectedDigest: digest,
                executableIdentity: configuration.executableIdentity)
            let selection = AdmittedEngineSelection(registryPath: path, inspection: result)
            try selection.validate(registryPath: path, engineName: engineName, registryDigest: digest)
            guard result.wineSha256 == wineSha256, result.wineserverSha256 == wineserverSha256 else {
                throw NativeLaunchError.selectionChanged
            }
            guard result.admittedProvider == admittedProvider else { throw NativeLaunchError.providerNotAdmitted }
            return selection
        }
    }

    let version: Int
    let defaultEngine: String
    let bindings: [Binding]
    static let preferenceKey = "Ode.lifecycle.defaultAdmission.v2"

    /// Engines admitted for one title only; they never appear as default choices.
    static var titleScopedEngineNames: Set<String> {
        Set(((try? read())?.bindings ?? []).filter { $0.provider != nil }.map(\.engineName))
    }

    static func permitsGlobalDefault(_ selection: AdmittedEngineSelection) -> Bool {
        selection.inspection.engineName != NativeFH6Recipe.engineName
            && selection.inspection.admittedProvider == AdmittedProviderScope.calimocho
    }

    static func savedAdmission(defaults: UserDefaults) throws -> AdmittedEngineSelection? {
        guard let bytes = defaults.data(forKey: preferenceKey), !bytes.isEmpty else { return nil }
        let saved = try JSONDecoder().decode(AdmittedEngineSelection.self, from: bytes)
        guard permitsGlobalDefault(saved) else {
            defaults.removeObject(forKey: preferenceKey)
            Logger(subsystem: "com.workingprinciple.xode", category: "EngineSelection")
                .error("Removed an invalid title-only global default; the ordinary catalogue default is used.")
            guard defaults.object(forKey: preferenceKey) == nil else { throw GameScriptError.storage }
            return nil
        }
        return saved
    }

    static func read() throws -> Self {
        let bytes = try Data(contentsOf: LaunchRecipeResources.engineDefaultsURL())
        guard bytes.count <= 65_536 else { throw NativeLaunchError.invalidProfile }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.version == 1, (1...16).contains(value.bindings.count),
              value.defaultEngine != NativeFH6Recipe.engineName,
              Set(value.bindings.map(\.engineName)).count == value.bindings.count,
              value.bindings.contains(where: { $0.engineName == value.defaultEngine }),
              value.bindings.allSatisfy({ binding in
                  guard EngineInspection.validDigest(binding.wineSha256),
                        EngineInspection.validDigest(binding.wineserverSha256) else { return false }
                  let fixedRegistry = binding.developerLocal == true
                      && binding.registryPath.map { NativeTitleLaunchProfile.expand($0).hasPrefix("/") } == true
                      && EngineInspection.validDigest(binding.registrySha256)
                  if binding.provider != nil {
                      guard AdmittedProviderScope.isTitleScoped(binding.provider),
                            binding.engineName != value.defaultEngine, binding.developerLocal == true else { return false }
                      return binding.provider == AdmittedProviderScope.highball ? binding.isHighball : fixedRegistry
                  }
                  return binding.isFH6Recipe || binding.release != nil && binding.developerLocal != true || fixedRegistry
              }) else { throw NativeLaunchError.invalidProfile }
        return value
    }
}
