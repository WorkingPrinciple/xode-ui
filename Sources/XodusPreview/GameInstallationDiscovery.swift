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
    static func mountedLibraryRoots(_ volumes: [String]?, home: String = NSHomeDirectory()) -> [URL] {
        let prefixes = ["/Volumes/", home + "/Mounts/"]
        return Array(Set((volumes ?? []).filter { path in
            prefixes.contains { prefix in
                path.hasPrefix(prefix) && !path.dropFirst(prefix.count).isEmpty
                    && !path.dropFirst(prefix.count).contains("/")
            } && URL(fileURLWithPath: path).standardizedFileURL.path == path
        })).sorted().map { URL(fileURLWithPath: $0).appendingPathComponent("Xodus") }
    }

    struct Candidate: Sendable {
        let folder: URL
        let config: MicrosoftGameConfig
        let package: PackageType
        let volume: GameStorageVolume?
    }

    struct Observation: Sendable {
        var candidates: [Candidate] = []
        var errors: [String] = []
        var scannedRoots: Set<String> = []
        var childrenRead = 0
        var identifiedInstallations: [String: String] = [:]
    }

    static func scan(originalRoot: URL, location: GameInstallLocation?, entries: [InstalledGame],
                     mountedRoots: [String]?,
                     includeRecordedRoots: Bool = true,
                     maximumChildren: Int = 512,
                     inspectPackage: @Sendable (URL) throws -> PackageType) throws -> Observation {
        var roots: [(URL, GameStorageVolume?, Bool)] = [(originalRoot, nil, false)]
        if let location {
            roots.append((URL(fileURLWithPath: location.folder), location.volume, true))
        }
        roots += (includeRecordedRoots ? entries : []).map {
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
                    result.childrenRead = childrenRead
                    guard childrenRead <= maximumChildren else { throw InstalledGameError.invalidRegistry }
                    guard !recorded.contains(folder.path),
                          try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                    else { continue }
                    do {
                        try GameScriptFiles.checkPath(folder)
                        guard try MicrosoftGameConfig.configurationFile(in: folder) != nil else { continue }
                        let config = try MicrosoftGameConfig.read(folder: folder)
                        guard PCGamesClient.validProductID(config.storeId) else {
                            throw InstalledGameError.invalidConfig
                        }
                        result.identifiedInstallations[folder.path] = config.storeId
                        guard let storageVolume = GameStorageVolume.read(at: folder) else {
                            throw GameScriptError.invalidDestination
                        }
                        result.candidates.append(Candidate(folder: folder, config: config,
                            package: try inspectPackage(folder), volume: storageVolume))
                    } catch {
                        if error as? InstalledGameError != .invalidConfig {
                            result.errors.append("\(folder.path): \(error.localizedDescription)")
                        }
                    }
                }
                if let enumerationError { throw enumerationError }
                result.scannedRoots.insert(root.path)
            } catch {
                result.errors.append("\(root.path): \(error.localizedDescription)")
                if childrenRead > maximumChildren { break }
            }
        }
        return result
    }
}
