// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

enum CalimochoRelease: String, CaseIterable, Sendable {
    case release04 = "calimocho-11.20-4.0b3-04"
    case release06 = "calimocho-11.20-4.0b3-06"

    var version: String { self == .release04 ? "0.1120.4.4" : "0.1120.4.6" }
    var descriptorSHA256: String {
        self == .release04 ? "98473033e8b1e4f02a1986749b684d0becd5e2be7d0ff388f7a2049566296425"
            : CalimochoInstalledRelease.descriptorSHA256
    }
    var manifestSHA256: String {
        self == .release04 ? "5ce80d16347304d2cd5d149072fed4aeed848e854fe17e20c3bd45c5013b2aba"
            : "db1b642e1d1a93cf50a3620a994ca049e34ce2352dc25fc34617a651302528bf"
    }
    var wineSHA256: String {
        self == .release04 ? "2482af598928431f89fc32c99de72e72e146195dd86a859cc834bcab57fad3d0"
            : CalimochoInstalledRelease.wineSHA256
    }
    var wineserverSHA256: String {
        self == .release04 ? "655812965207694589e550bd58156c7841c08eeae50ecd09a1c8d803ed78cfc9"
            : CalimochoInstalledRelease.wineserverSHA256
    }
    var archiveSHA256: String {
        self == .release04 ? "193420eff603e05e9c76344de14e961ed230f016fd129f00667a176251a2fb6b"
            : "3fc4467b466b6f8f0855c1934b2fe6a3d1c02b0c5ca85037860b735e4e419ee5"
    }
    var archiveBytes: Int64 { self == .release04 ? 200_070_449 : 200_075_043 }
    var expandedBytes: Int64 { self == .release04 ? 695_591_512 : 695_625_804 }
    var tag: String { "engine-\(version)" }
    var releaseURL: URL { URL(string: "https://github.com/WorkingPrinciple/calimocho/releases/tag/\(tag)")! }
    var archiveURL: URL {
        URL(string: "https://github.com/WorkingPrinciple/calimocho/releases/download/\(tag)/\(rawValue)-macos.zip")!
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func registryData(engine: URL) throws -> Data {
        struct Descriptor: Decodable { let environment: [String: String] }
        try GameScriptFiles.checkPath(engine)
        let descriptor = try InstalledGameFiles.readRegular(
            engine.appendingPathComponent("calimocho-engine.json"), maximumBytes: 65_536)
        let manifest = try InstalledGameFiles.readRegular(
            engine.appendingPathComponent("MANIFEST.sha256"), maximumBytes: 2_097_152)
        guard Self.digest(descriptor) == descriptorSHA256, Self.digest(manifest) == manifestSHA256 else {
            throw CalimochoInstalledRelease.Failure.invalidDescriptor
        }
        let values = try JSONDecoder().decode(Descriptor.self, from: descriptor)
        let environment = values.environment.mapValues {
            $0.replacingOccurrences(of: "${ENGINE_ROOT}", with: engine.path)
        }
        let entry: [String: Any] = [
            "name": rawValue, "kind": "free", "local_only": false,
            "provider": ["id": "calimocho", "contract_version": 1],
            "renderer": "apple-4.0b3", "install_path": engine.path,
            "wine": engine.appendingPathComponent("bin/wine").path,
            "wineserver": engine.appendingPathComponent("bin/wineserver").path,
            "sha256": wineSHA256, "wineserver_sha256": wineserverSHA256,
            "environment": environment, "version": version
        ]
        return try JSONSerialization.data(withJSONObject: ["schema_version": 1, "blocked": [], "engines": [entry]],
                                          options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }
}
