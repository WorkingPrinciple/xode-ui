// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusCore

enum GameInstallationDiscoveryError: Error, LocalizedError {
    case serviceUnavailable, identityChanged, inspectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            "The verified local service isn't connected. Reconnect Ode to check installation completeness before importing."
        case .identityChanged:
            "Game configuration changed during discovery. Check this installation again."
        case .inspectionFailed(let reason): reason
        }
    }
}

enum GameInstallationDiscovery {
    struct Candidate: Sendable {
        let folder: URL
        let config: MicrosoftGameConfig
        let package: PackageType
        let volume: GameStorageVolume?
    }

    struct Observation: Sendable {
        var candidates: [Candidate] = []
        var errors: [String] = []
    }

    static func scan(originalRoot: URL, location: GameInstallLocation?, entries: [InstalledGame],
                     mountedRoots: [String]?,
                     inspectPackage: @Sendable (URL) throws -> PackageType) throws -> Observation {
        var roots: [(URL, GameStorageVolume?, Bool)] = [(originalRoot, nil, false)]
        if let location {
            roots.append((URL(fileURLWithPath: location.folder), location.volume, true))
        }
        roots += entries.map {
            (URL(fileURLWithPath: $0.folder).deletingLastPathComponent(), $0.storageVolume, true)
        }
        guard roots.count <= 514 else { throw InstalledGameError.invalidRegistry }
        let recorded = Set(entries.map(\.folder))
        var seen = Set<String>(), childrenRead = 0
        var result = Observation()
        for (root, volume, required) in roots {
            guard seen.insert(root.standardizedFileURL.path).inserted else { continue }
            do {
                guard volume?.isUnavailable(mountedRoots: mountedRoots) != true else {
                    throw GameInstallLocationError.driveUnavailable
                }
                if !required, !FileManager.default.fileExists(atPath: root.path) { continue }
                try GameScriptFiles.checkPath(root)
                try InstalledGameFiles.checkFolder(root)
                var enumerationError: Error?
                guard let children = FileManager.default.enumerator(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                    errorHandler: { _, error in enumerationError = error; return false }) else {
                    throw InstalledGameError.missingFolder
                }
                for case let folder as URL in children {
                    childrenRead += 1
                    guard childrenRead <= 512 else { throw InstalledGameError.invalidRegistry }
                    guard !recorded.contains(folder.path),
                          try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                          FileManager.default.fileExists(atPath: folder.appendingPathComponent("MicrosoftGame.config").path)
                    else { continue }
                    do {
                        try GameScriptFiles.checkPath(folder)
                        let config = try MicrosoftGameConfig.read(folder: folder)
                        guard PCGamesClient.validProductID(config.storeId) else {
                            throw InstalledGameError.invalidConfig
                        }
                        result.candidates.append(Candidate(folder: folder, config: config,
                            package: try inspectPackage(folder), volume: GameStorageVolume.read(at: folder)))
                    } catch {
                        result.errors.append("\(folder.path): \(error.localizedDescription)")
                    }
                }
                if let enumerationError { throw enumerationError }
            } catch {
                result.errors.append("\(root.path): \(error.localizedDescription)")
                if childrenRead > 512 { break }
            }
        }
        return result
    }
}
