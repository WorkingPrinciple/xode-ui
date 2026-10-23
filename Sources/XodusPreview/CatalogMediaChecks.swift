// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Darwin
import Foundation
import XodusManagement

private final class MediaFixtureState: @unchecked Sendable {
    struct Reply { let status: Int; let headers: [String: String]; let data: Data }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var requests: [URLRequest] = []
    func reset(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies; requests = []
    }
    func take(_ request: URLRequest) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return replies.isEmpty ? nil : replies.removeFirst()
    }
    func observed() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

private final class MediaFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = MediaFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let reply = Self.state.take(request),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                              headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
enum CatalogMediaChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CatalogMediaCacheError.storage
        }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("CatalogMediaChecks-\(UUID().uuidString)")
        free(canonical)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Synthetic public-media cache files are cleaned") }
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let pixels = bitmap.bitmapData else { throw ArtworkLoadError.invalidImage }
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ArtworkLoadError.invalidImage }
        func makeReference(_ suffix: String) throws -> CatalogArtworkReference {
            guard let result = PCGamesClient.artwork(uri: "https://store-images.s-microsoft.com/image/cache-fixture-\(suffix)",
                width: 32, height: 16, role: .hero) else { throw ArtworkLoadError.unavailable }
            return result
        }
        let reference = try makeReference("A")
        let url = try reference.validatedURL()
        func entry(_ url: URL) -> CatalogMediaEntry {
            CatalogMediaEntry(url: url.absoluteString, data: data,
                digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                mimeType: "image/png", etag: "\"fixture-v1\"", lastModified: nil,
                expiresAt: Date().addingTimeInterval(3600))
        }
        let directory = root.appendingPathComponent("public-media")
        let disk = CatalogMediaDiskCache(directory: directory)
        let absent = try await disk.lookup(url)
        check(absent.entry == nil && !FileManager.default.fileExists(atPath: directory.path),
              "Missing public-media cache is a read-only miss, not a directory-creating lookup")
        try await disk.store(entry(url), for: url, generation: absent.generation)
        let reopened = CatalogMediaDiskCache(directory: directory)
        let saved = try await reopened.lookup(url)
        check(saved.entry?.data == data && saved.entry?.etag == "\"fixture-v1\"" &&
              CatalogMediaDiskCache.key(url).count == 64,
              "Public images survive cache reopen in atomic URL-hashed entries with validators")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaFixtureProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        MediaFixtureProtocol.state.reset([])
        let freshStore = CatalogArtworkStore(diskCache: reopened, session: session)
        _ = try await freshStore.image(for: reference)
        check(MediaFixtureProtocol.state.observed().isEmpty,
              "A new artwork store decodes a fresh persisted image without a network request")
        let stale = CatalogMediaEntry(url: url.absoluteString, data: data, digest: entry(url).digest,
            mimeType: "image/png", etag: "\"fixture-v1\"", lastModified: nil, expiresAt: .distantPast)
        try await reopened.store(stale, for: url, generation: saved.generation)
        MediaFixtureProtocol.state.reset([.init(status: 304, headers: ["Cache-Control": "max-age=3600"], data: Data())])
        _ = try await CatalogArtworkStore(diskCache: reopened, session: session).image(for: reference)
        let revalidated = try await reopened.lookup(url)
        check(MediaFixtureProtocol.state.observed().first?.value(forHTTPHeaderField: "If-None-Match") == "\"fixture-v1\"" &&
              (revalidated.entry?.expiresAt ?? .distantPast) > Date(),
              "Expired public art sends its validator and a real304 renews the saved image")
        MediaFixtureProtocol.state.reset([.init(status: 200, headers: ["Content-Type": "image/png",
            "Cache-Control": "no-store"], data: data)])
        let uncached = try makeReference("NoStore")
        _ = try await CatalogArtworkStore(diskCache: reopened, session: session).image(for: uncached)
        check(try await reopened.lookup(uncached.validatedURL()).entry == nil,
              "HTTP no-store images decode but never persist")
        for reply in [MediaFixtureState.Reply(status: 302, headers: ["Content-Type": "image/png"], data: data),
                      .init(status: 200, headers: ["Content-Type": "text/html"], data: data),
                      .init(status: 200, headers: ["Content-Type": "image/png", "Content-Length": "8388609"], data: Data()),
                      .init(status: 200, headers: ["Content-Type": "image/png"], data: Data("invalid image".utf8))] {
            let rejected = try makeReference("Rejected")
            MediaFixtureProtocol.state.reset([reply])
            do {
                _ = try await CatalogArtworkStore(diskCache: reopened, session: session).image(for: rejected)
                check(false, "Redirect/non-image/oversize/invalid media is rejected before persistence")
            } catch { check(true, "Redirect/non-image/oversize/invalid media is rejected before persistence") }
            check(try await reopened.lookup(rejected.validatedURL()).entry == nil,
                  "Rejected public media creates no persistent entry")
        }
        let corruptFile = directory.appendingPathComponent(CatalogMediaDiskCache.key(url) + ".cache")
        try Data("corrupt cache".utf8).write(to: corruptFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptFile.path)
        MediaFixtureProtocol.state.reset([.init(status: 200, headers: ["Content-Type": "image/png"], data: data)])
        _ = try await CatalogArtworkStore(diskCache: reopened, session: session).image(for: reference)
        let recovered = try await reopened.lookup(url)
        check(MediaFixtureProtocol.state.observed().count == 1 && recovered.entry?.data == data,
              "Corrupt cache is explicitly diagnosed and replaced only with a validated public image")

        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let oneSize = try encoder.encode(entry(url)).count
        let lruDirectory = root.appendingPathComponent("lru")
        let lru = CatalogMediaDiskCache(directory: lruDirectory, maximumBytes: Int64(oneSize * 2))
        let second = try makeReference("B").validatedURL(), third = try makeReference("C").validatedURL()
        try await lru.store(entry(url), for: url, generation: 0)
        try await lru.store(entry(second), for: second, generation: 0)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: lruDirectory.appendingPathComponent(CatalogMediaDiskCache.key(second) + ".cache").path)
        _ = try await lru.lookup(url)
        try await lru.store(entry(third), for: third, generation: 0)
        let evicted = try await lru.lookup(second), retained = try await lru.lookup(url), newest = try await lru.lookup(third)
        check(evicted.entry == nil && retained.entry != nil && newest.entry != nil,
              "Disk LRU evicts the least recently used image at the exact byte ceiling")
        let sentinel = lruDirectory.appendingPathComponent("keep.txt")
        try Data("not cache data".utf8).write(to: sentinel)
        try await lru.clear()
        try await lru.store(entry(url), for: url, generation: 0)
        check(try await lru.lookup(url).entry == nil && FileManager.default.fileExists(atPath: sentinel.path),
              "Clear removes only cache entries and fences late writes from an older generation")
        let linkDirectory = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkDirectory, withDestinationURL: directory)
        do {
            _ = try await CatalogMediaDiskCache(directory: linkDirectory).lookup(url)
            check(false, "Public-media disk cache refuses a symlink root")
        } catch { check(true, "Public-media disk cache refuses a symlink root") }
        check(CatalogMediaHTTPPolicy.validator("bad\r\nheader") == nil,
              "Persistent HTTP validators cannot inject control characters")
    }
}
