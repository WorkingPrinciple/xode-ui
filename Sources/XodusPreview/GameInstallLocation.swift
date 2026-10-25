// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct GameStorageVolume: Codable, Equatable, Sendable {
    let path: String

    func contains(_ folder: String) -> Bool {
        path.hasPrefix("/") && path.count <= 4096
            && URL(fileURLWithPath: path).standardizedFileURL.path == path
            && (path == "/" || folder == path || folder.hasPrefix(path + "/"))
    }

    static func read(at folder: URL) -> Self? {
        guard let values = try? folder.resourceValues(forKeys: [.volumeURLKey]),
              let volume = values.volume else { return nil }
        return Self(path: volume.standardizedFileURL.path)
    }

    static func mountedRoots() -> [String]? {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])
            .map { $0.map { $0.standardizedFileURL.path } }
    }

    func isUnavailable(mountedRoots: [String]?) -> Bool {
        guard let mountedRoots else { return false }
        return path != "/" && !mountedRoots.contains(path)
    }
}

struct GameInstallLocation: Codable, Equatable, Sendable {
    static let preferenceKey = "Xodus.installLocation"
    let folder: String
    let volume: GameStorageVolume

    init(folder: URL) throws {
        try GameScriptFiles.checkPath(folder)
        try InstalledGameFiles.checkFolder(folder)
        guard let volume = GameStorageVolume.read(at: folder) else {
            throw GameScriptError.invalidDestination
        }
        self.folder = folder.standardizedFileURL.path
        self.volume = volume
    }

    static func load(_ defaults: UserDefaults) throws -> Self? {
        guard defaults.object(forKey: preferenceKey) != nil else { return nil }
        guard let data = defaults.data(forKey: preferenceKey) else { throw GameScriptError.invalidDestination }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Self? {
        if data.isEmpty { return nil }
        guard data.count <= 16384 else { throw GameScriptError.invalidDestination }
        let location = try JSONDecoder().decode(Self.self, from: data)
        guard location.folder.hasPrefix("/"), location.folder.count <= 4096,
              URL(fileURLWithPath: location.folder).standardizedFileURL.path == location.folder,
              location.volume.contains(location.folder) else {
            throw GameScriptError.invalidDestination
        }
        return location
    }

    func destination(title: String, productID: String, paths: GameScriptPaths) throws -> URL {
        guard !volume.isUnavailable(mountedRoots: GameStorageVolume.mountedRoots()) else {
            throw GameInstallLocationError.driveUnavailable
        }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        try GameScriptFiles.checkPath(root)
        try InstalledGameFiles.checkFolder(root)
        return try paths.destination(title: title, productID: productID, root: root)
    }
}

enum GameInstallLocationError: Error, LocalizedError {
    case driveUnavailable

    var errorDescription: String? {
        "The selected install drive is unavailable. Reconnect it or choose another folder in Settings."
    }
}
