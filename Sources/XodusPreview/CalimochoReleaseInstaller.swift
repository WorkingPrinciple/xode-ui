// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI

private final class CalimochoExtractionRecovery: @unchecked Sendable {
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
    case removing

    var label: String {
        switch self {
        case .preparing: "Checking available space…"
        case .downloading: "Downloading Calimocho…"
        case .verifying: "Verifying the download…"
        case .extracting: "Unpacking Calimocho…"
        case .checkingAdmission: "Checking engine admission…"
        case .removing: "Moving Calimocho to the Trash…"
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
    case engineMissing
    case engineBusy
    case extraction
    case extractionShutdownFailed
    case installInProgress
    case stagingCleanup(String)
    case trash(String)

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
        case .engineMissing:
            "The pinned Calimocho engine folder isn't installed."
        case .engineBusy:
            "Quit the running game and finish any game or engine operation before removing Calimocho."
        case .extraction:
            "Calimocho couldn't be unpacked. Temporary files were removed; try again."
        case .extractionShutdownFailed:
            "Calimocho extraction hasn't stopped. Keep the app open and try quitting again. Temporary files were kept."
        case .installInProgress:
            "Another Calimocho install is in progress. Wait for it to finish, then try again."
        case .stagingCleanup(let detail):
            "The install failed and temporary files couldn't be removed: \(detail)"
        case .trash(let detail):
            "Calimocho couldn't be moved to the Trash: \(detail)"
        }
    }
}

struct CalimochoReleaseInstallService: Sendable {
    struct ArchiveEntry: Equatable {
        enum Kind: Equatable { case directory, regular, symlink }
        let path: String
        let kind: Kind
        let uncompressedSize: Int64
    }

    let pin: CalimochoReleasePin
    let root: URL
    let session: URLSession
    let availableSpace: @Sendable (URL) throws -> Int64?
    let extractArchive: @Sendable (URL, URL) async throws -> Void
    let verifyEngine: @Sendable (CalimochoReleasePin, URL) throws -> Void

    init(pin: CalimochoReleasePin = .release04,
         root: URL = CalimochoReleaseEngines.defaultEnginesRoot,
         session: URLSession = .shared,
         availableSpace: @escaping @Sendable (URL) throws -> Int64? = Self.volumeAvailableSpace,
         extractArchive: @escaping @Sendable (URL, URL) async throws -> Void = Self.dittoExtract,
         verifyEngine: @escaping @Sendable (CalimochoReleasePin, URL) throws -> Void = {
             _ = try CalimochoReleaseEngines.verify($0, root: $1.deletingLastPathComponent())
         }) {
        self.pin = pin
        self.root = root
        self.session = session
        self.availableSpace = availableSpace
        self.extractArchive = extractArchive
        self.verifyEngine = verifyEngine
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
        try removeStaleStaging()
        guard !existsWithoutFollowingLinks(engineURL) else { throw CalimochoInstallError.engineAlreadyExists }
        let (requiredSpace, overflow) = archiveBytes.addingReportingOverflow(expandedBytes)
        guard !overflow else { throw CalimochoInstallError.unavailable }
        await progress(.preparing)
        let available = try availableSpace(root)
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
            guard try CalimochoReleaseEngines.fileDigest(archive) == archiveHash.lowercased() else {
                throw CalimochoInstallError.archiveDigest
            }
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            let entries = try Self.inspectArchive(data, engineName: pin.engineName,
                                                  expandedLimit: expandedBytes)
            try Task.checkCancellation()
            let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            await progress(.extracting)
            try await extractArchive(archive, extracted)
            try Task.checkCancellation()
            let topLevel = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            guard topLevel.count == 1, topLevel[0].lastPathComponent == pin.engineName else {
                throw CalimochoInstallError.invalidArchive("It must contain only \(pin.engineName).")
            }
            let engine = topLevel[0]
            try Self.verifyExtractedEntries(entries, under: extracted, engineName: pin.engineName)
            try verifyEngine(pin, engine)
            try Task.checkCancellation()
            guard !existsWithoutFollowingLinks(engineURL) else { throw CalimochoInstallError.engineAlreadyExists }
            guard renamex_np(engine.path, engineURL.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw CalimochoInstallError.engineAlreadyExists }
                throw GameScriptError.storage
            }
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                throw CalimochoInstallError.stagingCleanup(error.localizedDescription)
            }
            return engineURL
        } catch {
            if error as? CalimochoInstallError == .extractionShutdownFailed { throw error }
            do {
                if existsWithoutFollowingLinks(staging) { try FileManager.default.removeItem(at: staging) }
            } catch {
                throw CalimochoInstallError.stagingCleanup(error.localizedDescription)
            }
            throw error
        }
    }

    func removalTarget(isBusy: Bool) throws -> URL {
        guard !isBusy else { throw CalimochoInstallError.engineBusy }
        guard existsWithoutFollowingLinks(engineURL) else { throw CalimochoInstallError.engineMissing }
        var info = stat()
        guard lstat(engineURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              (try? GameScriptFiles.checkPath(engineURL)) != nil else {
            throw CalimochoInstallError.invalidArchive("The engine folder isn't a regular, private folder.")
        }
        return engineURL
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

    private func removeStaleStaging() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            let prefix = ".calimocho-install-"
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
                  Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= 600 else { continue }
            do { try FileManager.default.removeItem(at: candidate) }
            catch { throw CalimochoInstallError.stagingCleanup(error.localizedDescription) }
        }
    }

    private func download(_ url: URL, to destination: URL, expectedSize: Int64,
                         progress: @escaping @Sendable (CalimochoInstallProgress) async -> Void) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 300)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
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
        try await dittoExtract(archive, destination, didStart: { _ in })
    }

    static func dittoExtract(_ archive: URL, _ destination: URL,
                             didStart: @escaping @Sendable (Int32) -> Void) async throws {
        try await runExtractionProcess(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                       arguments: ["-x", "-k", archive.path, destination.path], didStart: didStart)
    }

    static func runExtractionProcess(executable: URL, arguments: [String],
                                     didStart: @escaping @Sendable (Int32) -> Void) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        do {
            try Task.checkCancellation()
            try process.run()
            didStart(process.processIdentifier)
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

    private func existsWithoutFollowingLinks(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func inspectArchive(_ data: Data, engineName: String,
                               expandedLimit: Int64) throws -> [ArchiveEntry] {
        let bytes = [UInt8](data)
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
                                               engineName: String) throws {
        guard let engineRoot = realpath(root.appendingPathComponent(engineName).path, nil) else {
            throw CalimochoInstallError.invalidArchive("The extracted engine folder couldn't be resolved.")
        }
        defer { free(engineRoot) }
        let enginePath = String(cString: engineRoot)
        for entry in entries {
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

@MainActor
final class CalimochoReleaseInstallController: ObservableObject {
    @Published private(set) var progress: CalimochoInstallProgress?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var noticeSymbol = "info.circle"
    @Published private(set) var checkingUpdates = false
    @Published private(set) var updateOutcome: CalimochoUpdateOutcome?
    @Published private(set) var updateMessage: String?
    @Published private(set) var installedReleases: [LocalCalimochoRelease] = []
    @Published private(set) var removableOldRelease: LocalCalimochoRelease?
    private let service: CalimochoReleaseInstallService
    private var task: Task<Void, Never>?
    private var terminating = false
    private var extractionShutdownFailed = false
    private let extractionStillRunning: @MainActor () -> Bool
    private let releaseCheck: CalimochoReleaseCheck
    private let updateDefaults: UserDefaults
    private let now: () -> Date
    private var checkTask: Task<Void, Never>?
    private var latestCheckedVersion: CalimochoVersion?
    static let lastUpdateCheckKey = "Xodus.calimocho.lastUpdateCheck.v1"
    static let lastUpdateVersionKey = "Xodus.calimocho.lastUpdateVersion.v1"
    static let pendingUpdateKey = "Xodus.calimocho.pendingUpdate.v1"
    static let pendingRemovalKey = "Xodus.calimocho.pendingRemoval.v1"

    init(service: CalimochoReleaseInstallService = CalimochoReleaseInstallService(),
         releaseCheck: CalimochoReleaseCheck = CalimochoReleaseCheck(),
         updateDefaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         extractionStillRunning: @escaping @MainActor () -> Bool = {
             CalimochoExtractionRecovery.shared.hasLiveProcess()
         }) {
        self.service = service
        self.releaseCheck = releaseCheck
        self.updateDefaults = updateDefaults
        self.now = now
        self.extractionStillRunning = extractionStillRunning
        self.latestCheckedVersion = updateDefaults.string(forKey: Self.lastUpdateVersionKey).flatMap(CalimochoVersion.init)
    }

    var isWorking: Bool { task != nil }
    var enginesRoot: URL { service.root }
    var engineURL: URL { service.engineURL }
    var offersPinnedUpdate: Bool {
        if case .pinnedUpdate = updateOutcome { return true }
        if case .finishUpdate = updateOutcome { return true }
        return false
    }
    var hasEngineFolder: Bool {
        var info = stat()
        return lstat(engineURL.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    func install(refreshAdmission: @escaping @MainActor () async -> Bool) {
        guard task == nil, !terminating else { return }
        errorMessage = nil
        notice = nil
        progress = .preparing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await service.install { [weak self] value in
                    await MainActor.run { self?.progress = value }
                }
                progress = .checkingAdmission
                let admitted = await refreshAdmission()
                noticeSymbol = admitted ? "checkmark.circle" : "hourglass"
                notice = admitted
                    ? "Calimocho is installed and admitted by the game service."
                    : "Calimocho is installed, but the game service hasn't admitted it. It isn't ready to play."
            } catch is CancellationError {
                noticeSymbol = "info.circle"
                notice = "Download canceled. Temporary files were removed."
            } catch {
                extractionShutdownFailed = error as? CalimochoInstallError == .extractionShutdownFailed
                errorMessage = error.localizedDescription
            }
            progress = nil
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func shutdownForApplicationTermination() async -> Bool {
        terminating = true
        checkTask?.cancel()
        await checkTask?.value
        let pending = task
        pending?.cancel()
        await pending?.value
        if extractionShutdownFailed && !extractionStillRunning() { extractionShutdownFailed = false }
        return !extractionShutdownFailed
    }

    func resumeAfterTerminationRefusal() { terminating = false }

    func checkForUpdates(automatic: Bool) async {
        guard !terminating, !checkingUpdates, !isWorking else { return }
        do { installedReleases = try LocalCalimochoRelease.installed(root: enginesRoot) }
        catch { updateMessage = "The installed Calimocho version couldn't be read: \(error.localizedDescription)"; return }
        guard let pinned = service.pin.releaseVersion else {
            updateMessage = CalimochoUpdateError.invalidResponse.localizedDescription
            return
        }
        do { try restoreUpdateRecovery(pinned: pinned) }
        catch { updateMessage = "Calimocho update recovery couldn't be read: \(error.localizedDescription)"; return }
        if let latest = latestCheckedVersion {
            updateOutcome = .decide(installed: installedReleases, pinned: pinned, latest: latest)
            updateMessage = updateOutcome?.message
        } else if let old = installedReleases.first, old.version < pinned {
            updateOutcome = .pinnedUpdate(old)
            updateMessage = updateOutcome?.message
        }
        applyPendingUpdateOutcome()
        let date = now()
        if automatic, let previous = updateDefaults.object(forKey: Self.lastUpdateCheckKey) as? Date,
           (0..<86_400).contains(date.timeIntervalSince(previous)) { return }
        updateDefaults.set(date, forKey: Self.lastUpdateCheckKey)
        checkingUpdates = true
        updateMessage = nil
        let pending = Task { [self] in
            defer { checkingUpdates = false; checkTask = nil }
            do {
                let latest = try await releaseCheck.latest()
                try Task.checkCancellation()
                let outcome = CalimochoUpdateOutcome.decide(installed: installedReleases, pinned: pinned, latest: latest)
                latestCheckedVersion = latest
                updateDefaults.set(latest.description, forKey: Self.lastUpdateVersionKey)
                updateOutcome = outcome
                updateMessage = outcome.message
                applyPendingUpdateOutcome()
            } catch is CancellationError {
                updateMessage = nil
            } catch {
                updateMessage = error.localizedDescription
            }
        }
        checkTask = pending
        await pending.value
    }

    private var pendingUpdate: LocalCalimochoRelease?

    private func restoreUpdateRecovery(pinned: CalimochoVersion) throws {
        pendingUpdate = nil
        if let bytes = updateDefaults.data(forKey: Self.pendingUpdateKey) {
            let old = try JSONDecoder().decode(LocalCalimochoRelease.self, from: bytes)
            if old.version < pinned, installedReleases.contains(old), hasEngineFolder { pendingUpdate = old }
        }
        if pendingUpdate == nil, hasEngineFolder,
           EngineDefaults.defaultEngine(updateDefaults).map({ $0 == .calimocho }) ?? true,
           let bytes = updateDefaults.data(forKey: NativeEngineDefaults.preferenceKey) {
            let selection = try JSONDecoder().decode(AdmittedEngineSelection.self, from: bytes)
            if selection.inspection.admittedProvider == "calimocho",
               let old = installedReleases.first(where: {
                   $0.engineName == selection.inspection.engineName && $0.version < pinned
               }) { pendingUpdate = old }
        }
        removableOldRelease = nil
        if let bytes = updateDefaults.data(forKey: Self.pendingRemovalKey) {
            let old = try JSONDecoder().decode(LocalCalimochoRelease.self, from: bytes)
            let selected = try NativeEngineSettings.defaultAdmissionName(defaults: updateDefaults)
            if old.version < pinned, installedReleases.contains(old), selected != old.engineName {
                removableOldRelease = old
            }
        }
    }

    private func applyPendingUpdateOutcome() {
        if let pendingUpdate {
            updateOutcome = .finishUpdate(pendingUpdate)
            updateMessage = updateOutcome?.message
        }
    }

    func update(from old: LocalCalimochoRelease,
                isBusy: @MainActor () -> Bool,
                reserve: @MainActor () throws -> Void,
                release: @escaping @MainActor () -> Void,
                admit: @escaping @MainActor () async -> Bool,
                activate: @escaping @MainActor () async throws -> Void) {
        guard task == nil, !terminating, !checkingUpdates else { return }
        do {
            guard !isBusy(), let version = service.pin.releaseVersion, old.version < version,
                  try LocalCalimochoRelease.installed(root: enginesRoot).contains(old) else {
                throw CalimochoUpdateError.busy
            }
            if hasEngineFolder {
                guard pendingUpdate == old else { throw CalimochoInstallError.engineAlreadyExists }
            }
            try reserve()
        } catch { errorMessage = error.localizedDescription; return }
        errorMessage = nil
        notice = nil
        progress = .preparing
        task = Task { [self] in
            defer { release(); progress = nil; task = nil }
            var installedNew = false
            let finishing = hasEngineFolder
            do {
                updateDefaults.set(try JSONEncoder().encode(old), forKey: Self.pendingUpdateKey)
                if !finishing {
                    _ = try await service.install { [weak self] value in
                        await MainActor.run { self?.progress = value }
                    }
                    installedNew = true
                }
                try Task.checkCancellation()
                progress = .checkingAdmission
                guard await admit() else { throw CalimochoUpdateError.admission }
                try Task.checkCancellation()
                let refreshedReleases = try LocalCalimochoRelease.installed(root: enginesRoot)
                let removalRecord = try JSONEncoder().encode(old)
                try await activate()
                updateDefaults.set(removalRecord, forKey: Self.pendingRemovalKey)
                updateDefaults.removeObject(forKey: Self.pendingUpdateKey)
                pendingUpdate = nil
                installedReleases = refreshedReleases
                removableOldRelease = old
                if let pinned = service.pin.releaseVersion, let latest = latestCheckedVersion {
                    updateOutcome = .decide(installed: refreshedReleases, pinned: pinned, latest: latest)
                } else { updateOutcome = .upToDate }
                updateMessage = updateOutcome?.message
                noticeSymbol = "checkmark.circle"
                notice = "The pinned Calimocho update is installed and admitted."
            } catch {
                let failure = error
                extractionShutdownFailed = failure as? CalimochoInstallError == .extractionShutdownFailed
                if installedNew {
                    do {
                        let target = try service.removalTarget(isBusy: false)
                        try FileManager.default.removeItem(at: target)
                        _ = await Task { await admit() }.value
                    } catch {
                        errorMessage = "The update failed and the new engine couldn't be removed: \(error.localizedDescription)"
                        return
                    }
                }
                if !finishing {
                    updateDefaults.removeObject(forKey: Self.pendingUpdateKey)
                    pendingUpdate = nil
                }
                if failure is CancellationError {
                    noticeSymbol = "info.circle"
                    notice = "Update canceled. The previous engine and default were kept."
                } else { errorMessage = failure.localizedDescription }
            }
        }
    }

    func removeOld(isBusy: @escaping @MainActor @Sendable () -> Bool,
                   reserve: @MainActor () throws -> Void,
                   release: @escaping @MainActor () -> Void,
                   recycle: @escaping @MainActor @Sendable (URL) async throws -> Void = CalimochoReleaseInstallController.moveToTrash) {
        guard let old = removableOldRelease, !isWorking, !terminating else { return }
        do {
            guard !isBusy(), let pinned = service.pin.releaseVersion, old.version < pinned,
                  try LocalCalimochoRelease.installed(root: enginesRoot).contains(old),
                  try NativeEngineSettings.defaultAdmissionName(defaults: updateDefaults) != old.engineName else {
                throw CalimochoUpdateError.busy
            }
            try reserve()
        } catch { errorMessage = error.localizedDescription; return }
        let target = enginesRoot.appendingPathComponent(old.engineName, isDirectory: true)
        progress = .removing
        task = Task { [self] in
            defer { release(); progress = nil; task = nil }
            do {
                guard try LocalCalimochoRelease.installed(root: enginesRoot).contains(old) else {
                    throw CalimochoUpdateError.busy
                }
                try await recycle(target)
                removableOldRelease = nil
                updateDefaults.removeObject(forKey: Self.pendingRemovalKey)
                installedReleases = try LocalCalimochoRelease.installed(root: enginesRoot)
                updateMessage = "The previous Calimocho engine was moved to the Trash."
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func remove(isBusy: @escaping @MainActor @Sendable () -> Bool,
                refreshAdmission: @escaping @MainActor () async -> Void) {
        remove(isBusy: isBusy, refreshAdmission: refreshAdmission, recycle: Self.moveToTrash)
    }

    func remove(isBusy: @escaping @MainActor @Sendable () -> Bool,
                refreshAdmission: @escaping @MainActor () async -> Void,
                recycle: @escaping @MainActor @Sendable (URL) async throws -> Void) {
        guard task == nil, !terminating else { return }
        guard !isBusy() else { errorMessage = CalimochoInstallError.engineBusy.localizedDescription; return }
        errorMessage = nil
        notice = nil
        progress = .removing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let target = try service.removalTarget(isBusy: isBusy())
                do { try await recycle(target) }
                catch { throw CalimochoInstallError.trash(error.localizedDescription) }
                progress = .checkingAdmission
                await refreshAdmission()
                notice = "Calimocho was moved to the Trash. Game prefixes and saves weren't changed."
                noticeSymbol = "info.circle"
            } catch {
                errorMessage = error.localizedDescription
            }
            progress = nil
            task = nil
        }
    }

    fileprivate static func moveToTrash(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}
