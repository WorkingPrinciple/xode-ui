// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation
import OSLog

/// One saved public catalogue descriptor: the public product JSON for a product, market and language.
/// It holds no account, entitlement or token data, but the saved product IDs reflect what the library and
/// Discover showed and the market reflects the account country, so sign-out clears it.
struct PublicDescriptorRecord: Codable, Sendable {
    let schema: Int
    let productID: String
    let market: String
    let language: String
    let fetchedAt: Date
    let digest: String
    let product: Data
}

/// REQ-121: bounded on-disk copy of public descriptors so a restart can draw tiles from the last
/// verified details while they are revalidated. Saved copies are never treated as fresh.
actor PublicDescriptorDiskCache {
    struct Key: Hashable, Sendable {
        let id: String
        let market: String
        let language: String
    }
    struct Saved: Sendable {
        let bytes: Data
        let fetchedAt: Date
    }
    static let schemaVersion = 1
    static let maximumBytes: Int64 = 64 * 1024 * 1024
    static let maximumEntries = 2048
    static let maximumAge: TimeInterval = 7 * 86_400
    static let sweepInterval: TimeInterval = 600
    private static let maximumFileBytes = PCGamesHTTP.maximumBytes + 16_384
    private let directory: URL
    private let limit: Int64
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date
    private var knownBytes: Int64?
    private var lastSweep: Date?
    private(set) var sweeps = 0
    private(set) var rejected = 0
    private let logger = Logger(subsystem: "com.workingprinciple.xode", category: "pc-library")

    init(directory: URL, maximumBytes: Int64 = PublicDescriptorDiskCache.maximumBytes,
         maximumAge: TimeInterval = PublicDescriptorDiskCache.maximumAge,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        limit = maximumBytes
        self.maximumAge = maximumAge
        self.now = now
    }

    /// The app's cache folder, only for an interactive or game-launch run; checks and previews stay isolated.
    static func production(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> PublicDescriptorDiskCache? {
        guard arguments.isEmpty || GameLaunchArguments.parse(arguments) != nil else { return nil }
        return Self(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Ode to X/PublicDescriptors", isDirectory: true))
    }

    static func fileName(_ key: Key) -> String {
        SHA256.hash(data: Data("v\(schemaVersion)\n\(key.market)\n\(key.language)\n\(key.id)".utf8))
            .map { String(format: "%02x", $0) }.joined() + ".descriptor"
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Saved descriptors for `keys`. Unreadable, foreign, outdated or older-schema entries are removed and skipped.
    func read(_ keys: [Key]) -> [Key: Saved] {
        guard (try? exists()) == true else { return [:] }
        if lastSweep == nil { sweepLogged() }
        var result: [Key: Saved] = [:]
        for key in keys { if let saved = readEntry(key) { result[key] = saved } }
        return result
    }

    private func readEntry(_ key: Key) -> Saved? {
        let file = directory.appendingPathComponent(Self.fileName(key))
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno != ENOENT { discard(file) }
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { handle.closeFile() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= Self.maximumFileBytes,
              let bytes = try? handle.read(upToCount: Self.maximumFileBytes + 1),
              bytes.count <= Self.maximumFileBytes,
              let record = try? PropertyListDecoder().decode(PublicDescriptorRecord.self, from: bytes),
              record.schema == Self.schemaVersion, record.productID == key.id,
              record.market == key.market, record.language == key.language,
              !record.product.isEmpty, record.product.count <= PCGamesHTTP.maximumBytes,
              record.digest == Self.digest(record.product),
              let object = try? JSONSerialization.jsonObject(with: record.product) as? [String: Any],
              object["ProductId"] as? String == key.id,
              record.fetchedAt.timeIntervalSince1970.isFinite else {
            discard(file)
            return nil
        }
        let age = now().timeIntervalSince(record.fetchedAt)
        guard age >= -300, age <= maximumAge else {
            discard(file)
            return nil
        }
        return Saved(bytes: record.product, fetchedAt: record.fetchedAt)
    }

    private func discard(_ file: URL) {
        rejected += 1
        logger.warning("stage=descriptorCacheEntryRejected; refetching public details")
        if unlink(file.path) != 0, errno != ENOENT {
            logger.warning("stage=descriptorCacheRemoveFailed; saved public details are ignored")
        }
    }

    func store(_ values: [Key: Data], fetchedAt: Date) throws {
        guard !values.isEmpty else { return }
        try prepare()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for (key, product) in values {
            guard product.count <= PCGamesHTTP.maximumBytes else { continue }
            let bytes = try encoder.encode(PublicDescriptorRecord(schema: Self.schemaVersion, productID: key.id,
                market: key.market, language: key.language, fetchedAt: fetchedAt,
                digest: Self.digest(product), product: product))
            guard bytes.count <= Self.maximumFileBytes else { continue }
            let target = directory.appendingPathComponent(Self.fileName(key))
            var previous = stat()
            let replaced: Int64 = lstat(target.path, &previous) == 0 ? Int64(previous.st_size) : 0
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CatalogMediaCacheError.storage }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: bytes)
                guard fsync(fd) == 0 else { throw CatalogMediaCacheError.storage }
                try handle.close()
                guard rename(temporary.path, target.path) == 0 else { throw CatalogMediaCacheError.storage }
            } catch {
                handle.closeFile()
                _ = unlink(temporary.path)
                throw error
            }
            if let known = knownBytes { knownBytes = known - replaced + Int64(bytes.count) }
        }
        // Clean up once per session, when over budget, or on the sweep timer; never after every save.
        if knownBytes.map({ $0 > limit }) ?? true
            || lastSweep.map({ now().timeIntervalSince($0) >= Self.sweepInterval }) ?? true {
            try sweep()
        }
    }

    /// Deletes saved descriptors the network no longer returns.
    func remove(_ keys: [Key]) throws {
        guard try exists() else { return }
        for key in keys {
            let file = directory.appendingPathComponent(Self.fileName(key))
            var info = stat()
            let removed: Int64 = lstat(file.path, &info) == 0 ? Int64(info.st_size) : 0
            if unlink(file.path) != 0, errno != ENOENT { throw CatalogMediaCacheError.storage }
            if let known = knownBytes { knownBytes = max(0, known - removed) }
        }
    }

    func clear() throws {
        knownBytes = 0
        guard try exists() else { return }
        for file in try files() {
            if unlink(file.url.path) != 0, errno != ENOENT { throw CatalogMediaCacheError.storage }
        }
    }

    private func exists() throws -> Bool {
        try GameScriptFiles.checkPath(directory, allowMissing: true)
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw CatalogMediaCacheError.storage }
            return false
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw CatalogMediaCacheError.storage
        }
        return true
    }

    private func prepare() throws {
        if try exists() { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard try exists() else { throw CatalogMediaCacheError.storage }
    }

    private struct File {
        let url: URL
        let bytes: Int64
        let modified: Date
    }

    /// Lists saved entries. Files another process removes mid-listing are skipped, not treated as damage.
    private func files() throws -> [File] {
        let time = Date()
        var result: [File] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                guard errno == ENOENT else { throw CatalogMediaCacheError.storage }
                continue
            }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            if url.pathExtension == "tmp", url.lastPathComponent.hasPrefix("."),
               UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst())) != nil {
                if info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), time.timeIntervalSince(modified) > 3600,
                   unlink(url.path) != 0, errno != ENOENT { throw CatalogMediaCacheError.storage }
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "descriptor", name.utf8.count == 64,
                  name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
            result.append(File(url: url, bytes: Int64(info.st_size), modified: modified))
        }
        return result
    }

    private func sweepLogged() {
        do { try sweep() } catch {
            lastSweep = now()
            logger.warning("stage=descriptorCacheSweepFailed; saved public details stay bounded on the next sweep")
        }
    }

    private func sweep() throws {
        sweeps += 1
        lastSweep = now()
        guard try exists() else { knownBytes = 0; return }
        let time = Date()
        var entries = try files().sorted { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified < $1.modified }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var count = entries.count
        while let oldest = entries.first,
              total > limit || count > Self.maximumEntries || time.timeIntervalSince(oldest.modified) > maximumAge {
            entries.removeFirst()
            if unlink(oldest.url.path) != 0, errno != ENOENT { throw CatalogMediaCacheError.storage }
            total -= oldest.bytes
            count -= 1
        }
        knownBytes = total
    }
}
