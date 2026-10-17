// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusCore

enum PackageInspector {
    static func detect(folder: URL) throws -> PackageType {
        PackageType.classify(try inspect(folder: folder))
    }

    static func inspect(folder: URL) throws -> PackageTypeEvidence {
        try InstalledGameFiles.checkFolder(folder)
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var evidence = PackageTypeEvidence()
        var manifests: [URL] = []
        for entry in entries {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { throw InstalledGameError.invalidConfig }
            guard info.st_mode & S_IFMT == S_IFREG else { continue }
            let name = entry.lastPathComponent.lowercased()
            if name == "microsoftgame.config" { evidence.hasMicrosoftGameConfig = true }
            if name == "appxmanifest.xml" { manifests.append(entry) }
            if name.hasSuffix(".eappx") || name.hasSuffix(".eappxbundle") {
                if !evidence.encryptedPackageMarker {
                    evidence.encryptedPackageMarker = PackageType.hasEncryptedAppxHeader(
                        try readPrefix(entry, maximumBytes: 65_536))
                }
            }
            if name.hasSuffix(".msixvc"), !evidence.hasMSIXVCHeader {
                evidence.hasMSIXVCHeader = PackageType.hasMSIXVCHeader(try readPrefix(entry, maximumBytes: 4096))
            }
            if name.hasSuffix(".exe"), !evidence.hasWin32Executable {
                evidence.hasWin32Executable = PackageType.hasPEHeader(try readPrefix(entry, maximumBytes: 1_048_576))
            }
        }
        guard manifests.count <= 1 else { throw InstalledGameError.invalidConfig }
        if let manifest = manifests.first {
            let bytes = try readPrefix(manifest, maximumBytes: 1_048_577)
            let facts = try AppxManifestFacts.parse(bytes)
            evidence.hasAppxManifest = true
            evidence.targetDeviceFamilies = facts.targetDeviceFamilies
            evidence.declaresFullTrustEntryPoint = facts.fullTrust
            evidence.declaresUWPApplication = facts.uwpApplication
        }
        return evidence
    }

    private static func readPrefix(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw InstalledGameError.invalidConfig }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { handle.closeFile() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw InstalledGameError.invalidConfig
        }
        let bytes = try handle.read(upToCount: maximumBytes) ?? Data()
        var after = stat(), current = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &current) == 0,
              info.st_dev == after.st_dev, info.st_ino == after.st_ino,
              current.st_dev == after.st_dev, current.st_ino == after.st_ino,
              info.st_size == after.st_size, info.st_mode == after.st_mode,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              bytes.count == min(Int(info.st_size), maximumBytes) else {
            throw InstalledGameError.invalidConfig
        }
        return bytes
    }
}
