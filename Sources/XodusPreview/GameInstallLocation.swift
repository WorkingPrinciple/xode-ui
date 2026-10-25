// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct GameStorageVolume: Codable, Equatable, Sendable {
    let path: String

    func contains(_ folder: String) -> Bool {
        path.hasPrefix("/") && path.count <= 4096
            && URL(fileURLWithPath: path).standardizedFileURL.path == path
            && (path == "/" || folder == path || folder.hasPrefix(path + "/"))
    }

    static func read(at folder: URL) -> Self? {
        guard folder.standardizedFileURL.path == folder.resolvingSymlinksInPath().standardizedFileURL.path,
              let values = try? folder.resourceValues(forKeys: [.volumeURLKey]),
              let volume = values.volume else { return nil }
        let result = Self(path: volume.standardizedFileURL.path)
        return result.contains(folder.path) ? result : nil
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
        let values = try folder.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard values.volumeIsReadOnly != true, FileManager.default.isWritableFile(atPath: folder.path) else {
            throw GameInstallLocationError.notWritable
        }
        guard let volume = GameStorageVolume.read(at: folder) else {
            throw GameScriptError.invalidDestination
        }
        self.folder = folder.standardizedFileURL.path
        self.volume = volume
    }

    static func rootURL(path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded.utf8.count <= 4096,
              !expanded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GameScriptError.invalidDestination
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    static func validateDestination(_ destination: URL, productID: String,
                                    managedRecord: GameOperationRecord?) throws {
        try GameScriptFiles.checkPath(destination, allowMissing: true)
        var info = stat()
        guard lstat(destination.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw InstalledGameFiles.folderReadError(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        guard let record = managedRecord, record.kind == .install, record.productID == productID,
              record.destination == destination.path, record.installedID == nil else {
            throw GameInstallLocationError.destinationExists
        }
        try record.validate()
        try InstalledGameFiles.checkFolder(destination)
        if try MicrosoftGameConfig.configurationFile(in: destination) != nil {
            guard try MicrosoftGameConfig.read(folder: destination).storeId == productID else {
                throw InstalledGameError.invalidConfig
            }
        }
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
    case driveUnavailable, notWritable, destinationExists

    var errorDescription: String? {
        switch self {
        case .driveUnavailable: "The selected install drive is unavailable. Reconnect it or choose another folder."
        case .notWritable: "The selected folder isn't writable. Choose another folder."
        case .destinationExists: "A folder already exists at this destination. Check or import it, or choose another install folder."
        }
    }
}
