// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation
import SwiftUI

final class CalimochoExtractionRecovery: @unchecked Sendable {
    static let shared = CalimochoExtractionRecovery()
    private let lock = NSLock()
    private var survivors: [Process] = []

    func retain(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        survivors.append(process)
    }

    func hasLiveProcess() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        survivors.removeAll { !$0.isRunning }
        return !survivors.isEmpty
    }
}

enum CalimochoInstallProgress: Equatable, Sendable {
    case preparing
    case downloading(received: Int64, total: Int64)
    case verifying
    case extracting
    case checkingAdmission

    var label: String {
        switch self {
        case .preparing: "Checking available space…"
        case .downloading: "Downloading Calimocho…"
        case .verifying: "Verifying the download…"
        case .extracting: "Unpacking Calimocho…"
        case .checkingAdmission: "Checking engine admission…"
        }
    }

    var fraction: Double? {
        guard case .downloading(let received, let total) = self, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
}

enum CalimochoInstallError: LocalizedError, Equatable {
    case unavailable
    case insufficientSpace(required: Int64, available: Int64?)
    case invalidResponse
    case archiveSize(expected: Int64, actual: Int64)
    case archiveDigest
    case invalidArchive(String)
    case engineAlreadyExists
    case extraction
    case extractionShutdownFailed
    case verificationShutdownFailed
    case installInProgress
    case stagingCleanup(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The pinned Calimocho release is missing its download or integrity details."
        case .insufficientSpace(let required, let available):
            if let available {
                "There isn't enough free space to download and unpack Calimocho. Need \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)); \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
            } else {
                "Available disk space couldn't be checked, so Calimocho wasn't downloaded."
            }
        case .invalidResponse:
            "The Calimocho download didn't return a successful archive response."
        case .archiveSize(let expected, let actual):
            "The Calimocho archive is incomplete or the wrong size (\(actual) bytes; expected \(expected)). Try again."
        case .archiveDigest:
            "The Calimocho archive failed its SHA-256 check. It wasn't unpacked. Try again."
        case .invalidArchive(let detail):
            "The Calimocho archive couldn't be safely unpacked: \(detail)"
        case .engineAlreadyExists:
            "A Calimocho folder with this release name already exists. It wasn't replaced; remove it first if you want to reinstall."
        case .extraction:
            "Calimocho couldn't be unpacked. Temporary files were removed; try again."
        case .extractionShutdownFailed:
            "Calimocho extraction hasn't stopped. Keep the app open and try quitting again. Temporary files were kept."
        case .verificationShutdownFailed:
            "Calimocho verification or cleanup hasn't finished. Keep the app open and retry quitting. A filesystem or signature operation may still be returning; its staging files were not removed underneath it."
        case .installInProgress:
            "Another Calimocho install is in progress. Wait for it to finish, then try again."
        case .stagingCleanup(let detail):
            "The install failed and temporary files couldn't be removed: \(detail)"
        }
    }
}

struct CalimochoReleaseInstallService: Sendable {
    struct ArchiveEntry: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case directory, regular, symlink }
        let path: String
        let kind: Kind
        let uncompressedSize: Int64
    }

    let pin = CalimochoReleasePin.release06
    let root: URL
    let verification: CalimochoVerificationWork
    init(root: URL = CalimochoReleaseEngines.defaultEnginesRoot,
         verification: CalimochoVerificationWork = CalimochoVerificationWork()) {
        self.root = root
        self.verification = verification
    }

    var engineURL: URL { root.appendingPathComponent(pin.engineName, isDirectory: true) }

    func install(progress: @escaping @Sendable (CalimochoInstallProgress) async -> Void) async throws -> URL {
        guard let url = pin.downloadURL, url.scheme == "https",
              url.host == "github.com", let archiveHash = pin.archiveSha256,
              archiveHash.count == 64, archiveHash.allSatisfy(\.isHexDigit),
              let archiveBytes = pin.archiveByteCount, archiveBytes > 0,
              let expandedBytes = pin.expandedByteCount, expandedBytes > 0 else {
            throw CalimochoInstallError.unavailable
        }
        try Task.checkCancellation()
        try prepareRoot()
        let lockURL = root.appendingPathComponent(".calimocho-install.lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else { throw GameScriptError.storage }
        defer { close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(), lockInfo.st_nlink == 1 else {
            throw CalimochoInstallError.invalidArchive("The install lock is unsafe.")
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw CalimochoInstallError.installInProgress }
            throw GameScriptError.storage
        }
        guard try !existsWithoutFollowingLinks(engineURL) else { throw CalimochoInstallError.engineAlreadyExists }
        let (requiredSpace, overflow) = archiveBytes.addingReportingOverflow(expandedBytes)
        guard !overflow else { throw CalimochoInstallError.unavailable }
        await progress(.preparing)
        let available = try Self.volumeAvailableSpace(root)
        guard let available, available >= requiredSpace else {
            throw CalimochoInstallError.insufficientSpace(required: requiredSpace, available: available)
        }
        try Task.checkCancellation()

        let staging = root.appendingPathComponent(".calimocho-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let archive = staging.appendingPathComponent("release.zip")
            try await download(url, to: archive, expectedSize: archiveBytes, progress: progress)
            await progress(.verifying)
            try Task.checkCancellation()
            let entries = try await verification.run { cancellation in
                guard try CalimochoReleaseEngines.fileDigest(archive, checkCancellation: cancellation.check)
                        == archiveHash.lowercased() else { throw CalimochoInstallError.archiveDigest }
                try cancellation.check()
                let data = try Data(contentsOf: archive, options: .mappedIfSafe)
                try cancellation.check()
                return try Self.inspectArchive(data, engineName: pin.engineName,
                    expandedLimit: expandedBytes, checkCancellation: cancellation.check)
            }
            try Task.checkCancellation()
            let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            await progress(.extracting)
            try await Self.dittoExtract(archive, extracted)
            try Task.checkCancellation()
            let topLevel = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            guard topLevel.count == 1, topLevel[0].lastPathComponent == pin.engineName else {
                throw CalimochoInstallError.invalidArchive("It must contain only \(pin.engineName).")
            }
            let engine = topLevel[0]
            _ = try await verification.run { cancellation in
                try Self.verifyExtractedEntries(entries, under: extracted, engineName: pin.engineName,
                                                checkCancellation: cancellation.check)
                return try CalimochoReleaseEngines.verify(pin, root: engine.deletingLastPathComponent(),
                                                          checkCancellation: cancellation.check)
            }
            try Task.checkCancellation()
            guard try !existsWithoutFollowingLinks(engineURL) else { throw CalimochoInstallError.engineAlreadyExists }
            guard renamex_np(engine.path, engineURL.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw CalimochoInstallError.engineAlreadyExists }
                throw GameScriptError.storage
            }
            do {
                try await verification.run(cancelWithParent: false) { _ in
                    try FileManager.default.removeItem(at: staging)
                }
            } catch {
                throw CalimochoInstallError.stagingCleanup(error.localizedDescription)
            }
            return engineURL
        } catch {
            if error as? CalimochoInstallError == .extractionShutdownFailed { throw error }
            do {
                try await verification.run(cancelWithParent: false) { _ in
                    if try existsWithoutFollowingLinks(staging) { try FileManager.default.removeItem(at: staging) }
                }
            } catch {
                throw CalimochoInstallError.stagingCleanup(error.localizedDescription)
            }
            throw error
        }
    }

    private func prepareRoot() throws {
        do { try GameScriptFiles.checkPath(root, allowMissing: true) }
        catch { throw CalimochoInstallError.invalidArchive("The Engines folder has an unsafe path.") }
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        do { try GameScriptFiles.checkPath(root) }
        catch { throw CalimochoInstallError.invalidArchive("The Engines folder contains a symbolic link.") }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw CalimochoInstallError.invalidArchive("The Engines folder must be owned by this user.")
        }
    }

    private func download(_ url: URL, to destination: URL, expectedSize: Int64,
                         progress: @escaping @Sendable (CalimochoInstallProgress) async -> Void) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 300)
        request.httpMethod = "GET"
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https",
              (200..<300).contains(response.statusCode),
              response.expectedContentLength < 0 || response.expectedContentLength == expectedSize else {
            throw CalimochoInstallError.invalidResponse
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw GameScriptError.storage
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { handle.closeFile() }
        var received: Int64 = 0
        var buffer: [UInt8] = []
        buffer.reserveCapacity(262_144)
        for try await byte in bytes {
            try Task.checkCancellation()
            received += 1
            guard received <= expectedSize else {
                throw CalimochoInstallError.archiveSize(expected: expectedSize, actual: received)
            }
            buffer.append(byte)
            if buffer.count == 262_144 {
                try handle.write(contentsOf: Data(buffer))
                buffer.removeAll(keepingCapacity: true)
                await progress(.downloading(received: received, total: expectedSize))
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: Data(buffer)) }
        try handle.synchronize()
        guard received == expectedSize else {
            throw CalimochoInstallError.archiveSize(expected: expectedSize, actual: received)
        }
        await progress(.downloading(received: received, total: expectedSize))
    }

    static func dittoExtract(_ archive: URL, _ destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        do {
            try Task.checkCancellation()
            try process.run()
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw CalimochoInstallError.extraction
            }
        } catch {
            if process.isRunning {
                process.terminate()
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning, ContinuousClock.now < deadline {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning, ContinuousClock.now < killDeadline {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
                }
                guard !process.isRunning else {
                    CalimochoExtractionRecovery.shared.retain(process)
                    throw CalimochoInstallError.extractionShutdownFailed
                }
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func volumeAvailableSpace(_ root: URL) throws -> Int64? {
        try root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity.map(Int64.init)
    }

    private func existsWithoutFollowingLinks(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw GameScriptError.storage }
        return false
    }

    static func inspectArchive(_ data: Data, engineName: String,
                               expandedLimit: Int64,
                               checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [ArchiveEntry] {
        try checkCancellation()
        let bytes = [UInt8](data)
        try checkCancellation()
        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        func checkedRange(_ start: Int, _ count: Int, before limit: Int) -> Range<Int>? {
            guard start >= 0, count >= 0, start <= limit, count <= limit - start else { return nil }
            return start..<(start + count)
        }
        guard bytes.count >= 22 else { throw CalimochoInstallError.invalidArchive("The ZIP directory is missing.") }
        let searchStart = max(0, bytes.count - 22 - 65_535)
        var endRecord: Int?
        for offset in stride(from: bytes.count - 22, through: searchStart, by: -1) {
            try checkCancellation()
            if u32(offset) == 0x06054b50, offset + 22 + Int(u16(offset + 20)) == bytes.count {
                endRecord = offset
                break
            }
        }
        guard let endRecord,
              u16(endRecord + 4) == 0, u16(endRecord + 6) == 0,
              u16(endRecord + 8) == u16(endRecord + 10),
              u16(endRecord + 10) > 0, u16(endRecord + 10) < 0xffff,
              u32(endRecord + 12) != 0xffff_ffff, u32(endRecord + 16) != 0xffff_ffff else {
            throw CalimochoInstallError.invalidArchive("It uses an unsupported or incomplete ZIP directory.")
        }
        let count = Int(u16(endRecord + 10))
        guard count <= 4096 else { throw CalimochoInstallError.invalidArchive("It contains too many entries.") }
        let centralStart = Int(u32(endRecord + 16))
        let centralSize = Int(u32(endRecord + 12))
        guard centralStart >= 0, centralSize >= 0, centralStart <= endRecord,
              centralSize == endRecord - centralStart else {
            throw CalimochoInstallError.invalidArchive("The ZIP directory is out of bounds.")
        }
        var cursor = centralStart
        var entries: [ArchiveEntry] = []
        var recordRanges: [Range<Int>] = []
        var normalizedPaths = Set<String>()
        var totalExpanded: Int64 = 0
        var topLevelNames = Set<String>()
        for _ in 0..<count {
            try checkCancellation()
            guard checkedRange(cursor, 46, before: endRecord) != nil, u32(cursor) == 0x02014b50 else {
                throw CalimochoInstallError.invalidArchive("An entry header is malformed.")
            }
            let madeBy = u16(cursor + 4)
            let flags = u16(cursor + 8)
            let method = u16(cursor + 10)
            let crc = u32(cursor + 16)
            let compressedSize = Int(u32(cursor + 20))
            let uncompressedSize = Int(u32(cursor + 24))
            let nameLength = Int(u16(cursor + 28))
            let extraLength = Int(u16(cursor + 30))
            let commentLength = Int(u16(cursor + 32))
            let disk = u16(cursor + 34)
            let external = u32(cursor + 38)
            let localOffset = Int(u32(cursor + 42))
            guard flags & ~UInt16(0x080e) == 0, method == 0 || method == 8, disk == 0,
                  compressedSize < Int.max, uncompressedSize < Int.max,
                  checkedRange(cursor + 46, nameLength + extraLength + commentLength, before: endRecord) != nil else {
                throw CalimochoInstallError.invalidArchive("It contains an encrypted, split, or unsupported entry.")
            }
            let nameRange = (cursor + 46)..<(cursor + 46 + nameLength)
            guard let name = String(bytes: bytes[nameRange], encoding: .utf8), !name.isEmpty,
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  name.utf8.count <= 1024 else {
                throw CalimochoInstallError.invalidArchive("An entry has an unsafe or invalid name.")
            }
            let isDirectoryName = name.hasSuffix("/")
            let canonical = isDirectoryName ? String(name.dropLast()) : name
            let components = canonical.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
            }), components.first.map(String.init) == engineName else {
                throw CalimochoInstallError.invalidArchive("Every entry must stay inside \(engineName).")
            }
            topLevelNames.insert(String(components[0]))
            let normalized = canonical.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedPaths.insert(normalized).inserted else {
                throw CalimochoInstallError.invalidArchive("It contains duplicate or case-colliding paths.")
            }
            let unixMode = UInt16(truncatingIfNeeded: external >> 16)
            let fileType = unixMode & 0xf000
            let unixHost = madeBy >> 8 == 3
            let kind: ArchiveEntry.Kind
            if unixHost, fileType != 0 {
                switch fileType {
                case 0x4000: kind = .directory
                case 0x8000: kind = .regular
                case 0xa000: kind = .symlink
                default: throw CalimochoInstallError.invalidArchive("It contains a special file.")
                }
            } else {
                kind = isDirectoryName ? .directory : .regular
            }
            guard (kind == .directory) == isDirectoryName,
                  kind != .directory || uncompressedSize == 0,
                  kind != .symlink || uncompressedSize <= 4096 else {
                throw CalimochoInstallError.invalidArchive("An entry's type or size is inconsistent.")
            }
            totalExpanded += Int64(uncompressedSize)
            guard totalExpanded <= expandedLimit else {
                throw CalimochoInstallError.invalidArchive("Its expanded contents exceed the pinned release size.")
            }

            let localHeaderSize = 30 + nameLength
            guard localOffset < centralStart, checkedRange(localOffset, localHeaderSize, before: centralStart) != nil,
                  u32(localOffset) == 0x04034b50,
                  u16(localOffset + 6) == flags, u16(localOffset + 8) == method,
                  Int(u16(localOffset + 26)) == nameLength,
                  let localNameRange = checkedRange(localOffset + 30, nameLength, before: centralStart),
                  bytes[localNameRange] == bytes[nameRange],
                  checkedRange(localOffset + localHeaderSize, Int(u16(localOffset + 28)), before: centralStart) != nil else {
                throw CalimochoInstallError.invalidArchive("An entry's local header doesn't match the ZIP directory.")
            }
            let dataStart = localOffset + localHeaderSize + Int(u16(localOffset + 28))
            guard let dataRange = checkedRange(dataStart, compressedSize, before: centralStart) else {
                throw CalimochoInstallError.invalidArchive("An entry's compressed data is out of bounds.")
            }
            let dataEnd = dataRange.upperBound
            var recordEnd = dataEnd
            if flags & 0x0008 == 0 {
                guard u32(localOffset + 14) == crc,
                      Int(u32(localOffset + 18)) == compressedSize,
                      Int(u32(localOffset + 22)) == uncompressedSize else {
                    throw CalimochoInstallError.invalidArchive("An entry's local sizes or checksum don't match.")
                }
            } else {
                let descriptorStart = dataEnd + (dataEnd + 4 <= centralStart && u32(dataEnd) == 0x08074b50 ? 4 : 0)
                guard checkedRange(descriptorStart, 12, before: centralStart) != nil,
                      u32(descriptorStart) == crc,
                      Int(u32(descriptorStart + 4)) == compressedSize,
                      Int(u32(descriptorStart + 8)) == uncompressedSize else {
                    throw CalimochoInstallError.invalidArchive("An entry's data descriptor doesn't match.")
                }
                recordEnd = descriptorStart + 12
            }
            recordRanges.append(localOffset..<recordEnd)
            entries.append(ArchiveEntry(path: canonical, kind: kind, uncompressedSize: Int64(uncompressedSize)))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == endRecord, topLevelNames == [engineName],
              entries.contains(where: { $0.path == engineName && $0.kind == .directory }) else {
            throw CalimochoInstallError.invalidArchive("It must contain exactly one top-level folder named \(engineName).")
        }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.kind) })
        for entry in entries {
            try checkCancellation()
            let parts = entry.path.split(separator: "/").map(String.init)
            for count in 1..<parts.count {
                let parent = parts.prefix(count).joined(separator: "/")
                if let kind = byPath[parent], kind != .directory {
                    throw CalimochoInstallError.invalidArchive("A file or symlink is used as a parent folder.")
                }
            }
        }
        recordRanges.sort { $0.lowerBound < $1.lowerBound }
        for pair in zip(recordRanges, recordRanges.dropFirst()) where pair.0.upperBound > pair.1.lowerBound {
            throw CalimochoInstallError.invalidArchive("ZIP entries overlap.")
        }
        return entries
    }

    private static func symlinkStaysInEngine(_ target: String, path: String, engineName: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"),
              !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        var resolved = Array(path.split(separator: "/").dropLast()).map(String.init)
        for part in target.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." { return false }
            if part == ".." {
                guard resolved.count > 1 else { return false }
                resolved.removeLast()
            } else {
                resolved.append(String(part))
            }
        }
        return resolved.first == engineName && resolved.count > 1
    }

    static func verifyExtractedEntries(_ entries: [ArchiveEntry], under root: URL,
                                      engineName: String,
                                      checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        try checkCancellation()
        guard let engineRoot = realpath(root.appendingPathComponent(engineName).path, nil) else {
            throw CalimochoInstallError.invalidArchive("The extracted engine folder couldn't be resolved.")
        }
        defer { free(engineRoot) }
        let enginePath = String(cString: engineRoot)
        for entry in entries {
            try checkCancellation()
            let url = root.appendingPathComponent(entry.path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw CalimochoInstallError.invalidArchive("An expected entry is missing.")
            }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            let isRegular = info.st_mode & S_IFMT == S_IFREG
            let isSymlink = info.st_mode & S_IFMT == S_IFLNK
            guard (entry.kind == .directory && isDirectory)
                    || (entry.kind == .regular && isRegular)
                    || (entry.kind == .symlink && isSymlink) else {
                throw CalimochoInstallError.invalidArchive("An extracted entry changed type.")
            }
            if isSymlink {
                let targetURL = URL(fileURLWithPath: url.path)
                var buffer = [CChar](repeating: 0, count: 4097)
                let length = readlink(targetURL.path, &buffer, buffer.count - 1)
                guard length > 0, length < buffer.count - 1,
                      let target = String(bytes: buffer.prefix(length).map { UInt8(bitPattern: $0) }, encoding: .utf8),
                      symlinkStaysInEngine(target, path: entry.path, engineName: engineName),
                      let resolved = realpath(url.path, nil) else {
                    throw CalimochoInstallError.invalidArchive("An extracted symlink leaves the engine folder.")
                }
                defer { free(resolved) }
                let resolvedPath = String(cString: resolved)
                guard resolvedPath == enginePath || resolvedPath.hasPrefix(enginePath + "/") else {
                    throw CalimochoInstallError.invalidArchive("An extracted symlink leaves the engine folder.")
                }
            }
        }
    }
}
