// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

enum CatalogMediaCacheError: Error { case storage, invalidEntry }

struct CatalogMediaEntry: Codable, Sendable {
    let url: String
    let data: Data
    let digest: String
    let mimeType: String
    let etag: String?
    let lastModified: String?
    let expiresAt: Date
}

enum CatalogMediaHTTPPolicy {
    static func validator(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }

    static func expiry(_ response: HTTPURLResponse, now: Date) -> Date? {
        let directives = (response.value(forHTTPHeaderField: "Cache-Control") ?? "")
            .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if directives.contains("no-store") { return nil }
        if directives.contains("no-cache") { return now }
        let age = max(0, Double(response.value(forHTTPHeaderField: "Age") ?? "") ?? 0)
        for directive in directives where directive.hasPrefix("max-age=") {
            let value = directive.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                return now.addingTimeInterval(max(0, min(seconds, 86_400) - age))
            }
        }
        if let text = response.value(forHTTPHeaderField: "Expires") {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            if let expires = parser.date(from: text) {
                return min(max(now, expires), now.addingTimeInterval(86_400))
            }
        }
        return now.addingTimeInterval(21_600)
    }
}

actor CatalogMediaDiskCache {
    struct Lookup: Sendable {
        let entry: CatalogMediaEntry?
        let generation: Int
    }
    static let maximumBytes: Int64 = 512 * 1024 * 1024
    private let directory: URL
    private let limit: Int64
    private var generation = 0
    private var swept = false
    private static let maximumFileBytes = CatalogImagePolicy.maximumBytes + 16_384

    init(directory: URL, maximumBytes: Int64 = CatalogMediaDiskCache.maximumBytes) {
        self.directory = directory
        limit = maximumBytes
    }

    static func production() -> CatalogMediaDiskCache {
        Self(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Xodus/CatalogMedia", isDirectory: true))
    }

    static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func lookup(_ url: URL) throws -> Lookup {
        try validate(url)
        guard try exists() else { return Lookup(entry: nil, generation: generation) }
        if !swept { try prune(); swept = true }
        let file = directory.appendingPathComponent(Self.key(url) + ".cache")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return Lookup(entry: nil, generation: generation) }
        guard fd >= 0 else { throw CatalogMediaCacheError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { handle.closeFile() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= Self.maximumFileBytes,
              let bytes = try handle.read(upToCount: Self.maximumFileBytes + 1),
              bytes.count <= Self.maximumFileBytes else { throw CatalogMediaCacheError.invalidEntry }
        let entry = try PropertyListDecoder().decode(CatalogMediaEntry.self, from: bytes)
        guard entry.url == url.absoluteString, !entry.data.isEmpty,
              entry.data.count <= CatalogImagePolicy.maximumBytes,
              entry.mimeType.hasPrefix("image/"), entry.mimeType.utf8.count <= 128,
              entry.digest == SHA256.hash(data: entry.data).map({ String(format: "%02x", $0) }).joined(),
              CatalogMediaHTTPPolicy.validator(entry.etag) == entry.etag,
              CatalogMediaHTTPPolicy.validator(entry.lastModified) == entry.lastModified,
              entry.expiresAt.timeIntervalSince1970.isFinite else { throw CatalogMediaCacheError.invalidEntry }
        guard futimes(fd, nil) == 0 else { throw CatalogMediaCacheError.storage }
        return Lookup(entry: entry, generation: generation)
    }

    func store(_ entry: CatalogMediaEntry?, for url: URL, generation expected: Int) throws {
        try validate(url)
        guard expected == generation else { return }
        guard let entry else { try remove(url); return }
        guard entry.url == url.absoluteString, entry.data.count <= CatalogImagePolicy.maximumBytes else {
            throw CatalogMediaCacheError.invalidEntry
        }
        try prepare()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(entry)
        guard bytes.count <= Self.maximumFileBytes, Int64(bytes.count) <= limit else {
            throw CatalogMediaCacheError.storage
        }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CatalogMediaCacheError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: bytes)
            guard fsync(fd) == 0 else { throw CatalogMediaCacheError.storage }
            try handle.close()
            let target = directory.appendingPathComponent(Self.key(url) + ".cache")
            guard rename(temporary.path, target.path) == 0 else { throw CatalogMediaCacheError.storage }
        } catch {
            handle.closeFile()
            if unlink(temporary.path) != 0, errno != ENOENT { throw CatalogMediaCacheError.storage }
            throw error
        }
        try prune()
        swept = true
    }

    func remove(_ url: URL) throws {
        try validate(url)
        guard try exists() else { return }
        let file = directory.appendingPathComponent(Self.key(url) + ".cache")
        if unlink(file.path) != 0, errno != ENOENT { throw CatalogMediaCacheError.storage }
    }

    func clear() throws {
        generation += 1
        guard try exists() else { return }
        for file in try files() {
            guard unlink(file.url.path) == 0 else { throw CatalogMediaCacheError.storage }
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

    private func validate(_ url: URL) throws {
        guard PCGamesClient.artwork(uri: url.absoluteString, width: nil, height: nil, role: .hero) != nil else {
            throw CatalogMediaCacheError.invalidEntry
        }
    }

    private struct File {
        let url: URL
        let bytes: Int64
        let accessed: Date
    }

    private func files() throws -> [File] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [File] = []
        for url in urls {
            if url.pathExtension == "tmp", url.lastPathComponent.hasPrefix("."),
               UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst())) != nil {
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw CatalogMediaCacheError.storage }
                if Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 3600 {
                    guard unlink(url.path) == 0 else { throw CatalogMediaCacheError.storage }
                }
                continue
            }
            guard url.pathExtension == "cache" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.utf8.count == 64, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_mode & 0o777 == 0o600, info.st_size >= 0 else { throw CatalogMediaCacheError.storage }
            result.append(File(url: url, bytes: info.st_size,
                accessed: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)))
        }
        return result
    }

    private func prune() throws {
        let entries = try files().sorted { $0.accessed == $1.accessed ? $0.url.path < $1.url.path : $0.accessed < $1.accessed }
        var total: Int64 = 0
        for entry in entries {
            let (sum, overflow) = total.addingReportingOverflow(entry.bytes)
            guard !overflow else { throw CatalogMediaCacheError.storage }
            total = sum
        }
        for entry in entries where total > limit {
            guard unlink(entry.url.path) == 0 else { throw CatalogMediaCacheError.storage }
            total -= entry.bytes
        }
    }
}
