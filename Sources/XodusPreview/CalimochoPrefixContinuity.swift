// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusManagement

enum CalimochoPrefixContinuity {
    static func location(productID: String, installationID: UUID, engine: String, root: URL) -> URL {
        if let pin = CalimochoReleasePin.named(engine), PCGamesClient.validProductID(productID) {
            return root.appendingPathComponent(productID).appendingPathComponent(family(pin))
        }
        return root.appendingPathComponent(installationID.uuidString).appendingPathComponent(engine)
    }

    static func family(_ pin: CalimochoReleasePin) -> String {
        pin.engineName.split(separator: "-").prefix(2).joined(separator: "-")
    }

    static func markerMatches(_ bytes: Data, pin: CalimochoReleasePin) throws -> Bool {
        let value = try JSONValue.decodeUnique(bytes, maximumBytes: 4_096)
        guard case .object(let fields) = value,
              Set(fields.keys) == ["version", "engine", "wine_sha256"],
              fields["version"]?.uint64 == 1,
              let owner = fields["engine"]?.string.flatMap(CalimochoReleasePin.named),
              family(owner) == family(pin),
              fields["wine_sha256"]?.string == owner.wineSha256 else { return false }
        return true
    }

    static func prepare(prefix: URL, selection: AdmittedEngineSelection,
                        productID: String, legacyIDs: [UUID]) throws {
        guard let name = selection.inspection.engineName, let pin = CalimochoReleasePin.named(name),
              prefix.lastPathComponent == family(pin),
              prefix.deletingLastPathComponent().lastPathComponent == productID,
              PCGamesClient.validProductID(productID) else { return }
        guard selection.inspection.ready, selection.inspection.admission == "admitted",
              selection.inspection.admittedProvider == "calimocho",
              selection.inspection.wineSha256 == pin.wineSha256,
              selection.inspection.wineserverSha256 == pin.wineserverSha256 else {
            throw NativeLaunchError.providerNotAdmitted
        }
        let parent = prefix.deletingLastPathComponent()
        let root = parent.deletingLastPathComponent()
        try GameScriptFiles.checkPath(root, allowMissing: true)
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard errno == ENOENT else { throw GameScriptError.storage }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw NativeLaunchError.prefixConflict
        }
        try GameScriptFiles.checkPath(parent, allowMissing: true)
        if lstat(parent.path, &info) != 0 {
            guard errno == ENOENT else { throw GameScriptError.storage }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } else {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                throw NativeLaunchError.prefixConflict
            }
        }
        let lock = open(parent.appendingPathComponent(".calimocho-prefix.lock").path,
                        O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw NativeLaunchError.prefixConflict }
        defer { close(lock) }
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NativeLaunchError.prefixConflict }
        defer { flock(lock, LOCK_UN) }
        if lstat(prefix.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                throw NativeLaunchError.prefixConflict
            }
            let bytes = try InstalledGameFiles.readRegular(marker(for: prefix), maximumBytes: 4_096)
            guard try markerMatches(bytes, pin: pin) else { throw NativeLaunchError.prefixConflict }
            try writeMarker(prefix: prefix, pin: pin)
            return
        }
        guard errno == ENOENT else { throw GameScriptError.storage }
        let previous = CalimochoReleasePin.all.filter {
            family($0) == family(pin)
        }.sorted { ($0.releaseVersion?.revision ?? 0) > ($1.releaseVersion?.revision ?? 0) }
        var sources: [(URL, CalimochoReleasePin)] = []
        for id in Set(legacyIDs) {
            for old in previous {
                let source = root.appendingPathComponent(id.uuidString).appendingPathComponent(old.engineName)
                if lstat(source.path, &info) != 0 {
                    guard errno == ENOENT else { throw GameScriptError.storage }
                    continue
                }
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                    throw NativeLaunchError.prefixConflict
                }
                sources.append((source, old))
            }
        }
        guard sources.count <= 1 else { throw NativeLaunchError.prefixConflict }
        if let (source, old) = sources.first {
            try GameScriptFiles.checkPath(source)
            let oldMarker = marker(for: source)
            if lstat(oldMarker.path, &info) == 0 {
                let bytes = try InstalledGameFiles.readRegular(oldMarker, maximumBytes: 4_096)
                let value = try JSONValue.decodeUnique(bytes, maximumBytes: 4_096)
                guard value["engine"]?.string == old.engineName,
                      try markerMatches(bytes, pin: old) else {
                    throw NativeLaunchError.prefixConflict
                }
            } else if errno != ENOENT { throw GameScriptError.storage }
            try Task.checkCancellation()
            let stage = parent.appendingPathComponent(".calimocho-prefix-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stage) }
            // Recursive COPYFILE_CLONE preserves Wine's symlinks, not their external targets.
            guard copyfile(source.path, stage.path, nil,
                           copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE
                                            | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)) == 0 else {
                throw NativeLaunchError.prefixContinuity(String(cString: strerror(errno)))
            }
            try Task.checkCancellation()
            try GameScriptFiles.checkPath(parent)
            guard renamex_np(stage.path, prefix.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NativeLaunchError.prefixContinuity(String(cString: strerror(errno)))
            }
            let newMarker = marker(for: prefix)
            try GameScriptFiles.checkPath(newMarker, allowMissing: true)
            if lstat(newMarker.path, &info) == 0 {
                throw NativeLaunchError.prefixConflict
            }
            guard errno == ENOENT else { throw GameScriptError.storage }
            try writeMarker(prefix: prefix, pin: pin)
            return
        }
    }

    private static func writeMarker(prefix: URL, pin: CalimochoReleasePin) throws {
        try GameScriptFiles.writePrivate(JSONSerialization.data(withJSONObject: [
            "version": 1, "engine": pin.engineName, "wine_sha256": pin.wineSha256
        ], options: [.sortedKeys]), to: marker(for: prefix))
    }

    static func marker(for prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent(".\(prefix.lastPathComponent).xodus-engine-owner.json")
    }
}
