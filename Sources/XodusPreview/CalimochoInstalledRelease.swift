// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

struct CalimochoInstalledRelease: Sendable {
    static let engineName = "calimocho-11.20-4.0b3-06"
    static let version = "0.1120.4.6"
    static let wineSHA256 = "803a62d101303bb3160da4aa8a506857c3d1e1146aa4a0c9ee8250357ef12505"
    static let wineserverSHA256 = "7102d70405e7667acf143e710723f58fb24d32eee81468b1f0f02279343601d0"
    static let descriptorSHA256 = "d3ca32d8d706be0ca948f661f76e68c4a735b78362c6fb95fe50c12eb5db18ff"
    static let releaseURL = URL(string: "https://github.com/WorkingPrinciple/calimocho/releases/tag/engine-0.1120.4.6")!
    static var enginesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Xode/Engines", isDirectory: true)
    }
    static var registriesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Xodus/EngineRegistries", isDirectory: true)
    }

    enum Failure: LocalizedError {
        case notInstalled, invalidDescriptor, registryMissing, registryLimit, ambiguousRegistry

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Calimocho isn't installed in its supported Engines folder. Obtain the pinned release, then check again."
            case .invalidDescriptor:
                "Calimocho's installed release description doesn't match this app's pinned release. No engine was selected."
            case .registryMissing:
                "Calimocho is present, but its matching installation registry is missing or inconsistent. Choose its verified registry in Advanced Registry."
            case .registryLimit:
                "There are too many installation records to check automatically. Choose the Calimocho registry in Advanced Registry."
            case .ambiguousRegistry:
                "More than one Calimocho configuration was found. Choose the intended registry in Advanced Registry; no default was changed."
            }
        }
    }

    let registry: URL
    let registrySHA256: String

    static func locate(release: CalimochoRelease = .release06,
                       root: URL = enginesRoot, registries: URL = registriesRoot,
                       preferredRegistry: String? = nil) throws -> Self {
        try Task.checkCancellation()
        let engineName = release.rawValue
        let engine = root.appendingPathComponent(engineName, isDirectory: true)
        try GameScriptFiles.checkPath(engine, allowMissing: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: engine.path, isDirectory: &directory), directory.boolValue else {
            throw Failure.notInstalled
        }
        let descriptor = try InstalledGameFiles.readRegular(
            engine.appendingPathComponent("calimocho-engine.json"), maximumBytes: 65_536)
        guard CalimochoRelease.digest(descriptor) == release.descriptorSHA256 else {
            throw Failure.invalidDescriptor
        }
        try GameScriptFiles.checkPath(registries, allowMissing: true)
        guard FileManager.default.fileExists(atPath: registries.path) else { throw Failure.registryMissing }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: registries, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw Failure.registryMissing
        }
        var inspected = 0
        var records: [Self] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            inspected += 1
            guard inspected <= 128 else { throw Failure.registryLimit }
            guard url.lastPathComponent.hasPrefix(engineName + "-"), url.pathExtension == "json" else { continue }
            guard records.count < 16 else { throw Failure.registryLimit }
            let record = try NativeEngineRegistry.read(url)
            guard let entry = record.engines.first(where: { $0.name == engineName }),
                  entry.provider?.id == "calimocho", entry.provider?.contract_version == 1,
                  entry.sha256 == release.wineSHA256, entry.wineserver_sha256 == release.wineserverSHA256,
                  entry.wine == engine.appendingPathComponent("bin/wine").path,
                  entry.wineserver == engine.appendingPathComponent("bin/wineserver").path else {
                throw Failure.registryMissing
            }
            records.append(Self(registry: url, registrySHA256: record.byteDigest))
        }
        if let enumerationError { throw enumerationError }
        guard !records.isEmpty else { throw Failure.registryMissing }
        if let preferredRegistry, let preferred = records.first(where: { $0.registry.path == preferredRegistry }) {
            return preferred
        }
        guard Set(records.map(\.registrySHA256)).count == 1 else { throw Failure.ambiguousRegistry }
        return records.sorted { $0.registry.path < $1.registry.path }[0]
    }
}
