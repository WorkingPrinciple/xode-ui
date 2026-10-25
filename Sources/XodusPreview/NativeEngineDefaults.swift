// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import XodusManagement

struct NativeEngineDefaults: Decodable {
    struct Binding: Decodable {
        let registryPath: String
        let registrySha256: String
        let engineName: String
        let wineSha256: String
        let wineserverSha256: String

        @MainActor func inspect(configuration: BackendConfiguration,
                                inspector: EngineInspectionClient = EngineInspectionClient()) async throws -> AdmittedEngineSelection {
            let path = NativeTitleLaunchProfile.expand(registryPath)
            let registry = URL(fileURLWithPath: path)
            try GameScriptFiles.checkPath(registry)
            let bytes = try InstalledGameFiles.readRegular(registry, maximumBytes: 2_097_152)
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == registrySha256 else {
                throw NativeLaunchError.selectionChanged
            }
            let result = try await inspector.inspect(executable: configuration.executable,
                registry: registry, engine: engineName, expectedDigest: registrySha256,
                executableIdentity: configuration.executableIdentity)
            let selection = AdmittedEngineSelection(registryPath: path, inspection: result)
            try selection.validate(registryPath: path, engineName: engineName, registryDigest: registrySha256)
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

    static func read() throws -> Self {
        let bytes = try Data(contentsOf: LaunchRecipeResources.engineDefaultsURL())
        guard bytes.count <= 65_536 else { throw NativeLaunchError.invalidProfile }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.version == 1, (1...16).contains(value.bindings.count),
              Set(value.bindings.map(\.engineName)).count == value.bindings.count,
              value.bindings.contains(where: { $0.engineName == value.defaultEngine }),
              value.bindings.allSatisfy({
                  NativeTitleLaunchProfile.expand($0.registryPath).hasPrefix("/")
                    && EngineInspection.validDigest($0.registrySha256)
                    && EngineInspection.validDigest($0.wineSha256)
                    && EngineInspection.validDigest($0.wineserverSha256)
              }) else { throw NativeLaunchError.invalidProfile }
        return value
    }
}
