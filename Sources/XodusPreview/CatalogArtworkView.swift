// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import ImageIO
import OSLog
import SwiftUI
import XodusManagement

enum ArtworkLoadError: Error, Equatable {
    case unavailable, oversized, invalidImage
}

enum CatalogImagePolicy {
    static let maximumBytes = 8 * 1024 * 1024

    static func validatePixels(width: Int, height: Int) throws {
        guard (1...8192).contains(width), (1...8192).contains(height),
              width * height <= 16_777_216 else { throw ArtworkLoadError.oversized }
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= maximumBytes else { throw ArtworkLoadError.oversized }
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ArtworkLoadError.invalidImage
        }
        try validatePixels(width: width, height: height)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ArtworkLoadError.invalidImage }
        return image
    }
}

private final class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

@MainActor
final class CatalogArtworkStore {
    static let shared = CatalogArtworkStore()
    private let cache = NSCache<NSURL, NSImage>()
    private var pending: [URL: Task<NSImage, Error>] = [:]
    private let session: URLSession
    private let disk: CatalogMediaDiskCache?
    private var expires: [URL: Date] = [:]
    private var generation = 0
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "catalog-artwork")

    init(diskCache: CatalogMediaDiskCache? = CatalogArtworkStore.defaultDiskCache(), session suppliedSession: URLSession? = nil) {
        disk = diskCache
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 4
        session = suppliedSession ?? URLSession(configuration: configuration, delegate: ArtworkRedirectPolicy(),
                             delegateQueue: nil)
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 40
    }

    nonisolated private static func defaultDiskCache() -> CatalogMediaDiskCache? {
        let isolated = ["--library-preview", "--export-preview", "--export-live", "--fixture", "--self-check", "--live-check", "--media-check", "--stats-check"]
        return CommandLine.arguments.contains(where: isolated.contains) ? nil : .production()
    }

    func clearCache() async throws {
        generation += 1
        cache.removeAllObjects()
        expires.removeAll()
        try await disk?.clear()
    }

    func image(for reference: CatalogArtworkReference) async throws -> NSImage {
        let url = try reference.validatedURL()
        if let image = cache.object(forKey: url as NSURL), expires[url].map({ $0 > Date() }) == true { return image }
        if let task = pending[url] { return try await task.value }
        let session = session
        let disk = disk
        let logger = logger
        let epoch = generation
        let task = Task {
            let (image, expiry) = try await Task.detached(priority: .utility) {
                var saved: CatalogMediaEntry?
                var diskGeneration: Int?
                if let disk {
                    do {
                        let lookup = try await disk.lookup(url)
                        diskGeneration = lookup.generation
                        saved = lookup.entry
                        if let saved, saved.expiresAt > Date() {
                            return (try CatalogImagePolicy.decode(saved.data), saved.expiresAt)
                        }
                    } catch {
                        saved = nil
                        logger.warning("stage=imageCacheReadFailed; requesting public artwork")
                        do {
                            try await disk.remove(url)
                            diskGeneration = try await disk.lookup(url).generation
                        } catch { logger.warning("stage=imageCacheUnavailable; public artwork is memory-only") }
                    }
                }
                var request = URLRequest(url: url)
                request.httpShouldHandleCookies = false
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                request.setValue(saved?.etag, forHTTPHeaderField: "If-None-Match")
                request.setValue(saved?.lastModified, forHTTPHeaderField: "If-Modified-Since")
                let (stream, response) = try await session.bytes(for: request)
                defer { stream.task.cancel() }
                guard let http = response as? HTTPURLResponse, response.url == url,
                      http.statusCode == 200 || (http.statusCode == 304 &&
                        (saved?.etag != nil || saved?.lastModified != nil)) else {
                    throw ArtworkLoadError.unavailable
                }
                var data = Data()
                let mime: String
                if http.statusCode == 304, let saved {
                    data = saved.data
                    mime = saved.mimeType
                } else {
                    guard let type = http.mimeType, type.hasPrefix("image/") else { throw ArtworkLoadError.unavailable }
                    mime = type
                    guard response.expectedContentLength <= CatalogImagePolicy.maximumBytes else { throw ArtworkLoadError.oversized }
                    for try await byte in stream {
                        guard data.count < CatalogImagePolicy.maximumBytes else { throw ArtworkLoadError.oversized }
                        data.append(byte)
                    }
                }
                let decoded = try CatalogImagePolicy.decode(data)
                let now = Date()
                let expiry = CatalogMediaHTTPPolicy.expiry(http, now: now)
                if let disk, let diskGeneration {
                    let entry = expiry.map {
                        CatalogMediaEntry(url: url.absoluteString, data: data,
                            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                            mimeType: mime,
                            etag: CatalogMediaHTTPPolicy.validator(http.value(forHTTPHeaderField: "ETag")) ??
                                (http.statusCode == 304 ? saved?.etag : nil),
                            lastModified: CatalogMediaHTTPPolicy.validator(http.value(forHTTPHeaderField: "Last-Modified")) ??
                                (http.statusCode == 304 ? saved?.lastModified : nil),
                            expiresAt: $0)
                    }
                    do { try await disk.store(entry, for: url, generation: diskGeneration) }
                    catch { logger.warning("stage=imageCacheWriteFailed; public artwork is memory-only") }
                }
                return (decoded, expiry ?? now)
            }.value
            if epoch == generation { expires[url] = expiry }
            return NSImage(cgImage: image, size: .zero)
        }
        pending[url] = task
        defer { pending[url] = nil }
        let image = try await task.value
        if epoch == generation {
            cache.setObject(image, forKey: url as NSURL,
                            cost: Int(image.size.width * image.size.height) * 4)
            if expires.count > 160 { expires = expires.filter { cache.object(forKey: $0.key as NSURL) != nil } }
        }
        logger.notice("stage=imageDecoded count=1")
        return image
    }

    func preload(_ references: [CatalogArtworkReference]) async -> Int {
        let tasks = references.map { reference in
            Task {
                do { _ = try await image(for: reference); return true }
                catch { return false }
            }
        }
        var failures = 0
        for task in tasks { if !(await task.value) { failures += 1 } }
        return failures
    }
}

@MainActor
private final class ArtworkPresentation: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private var loadID = UUID()

    func load(_ reference: CatalogArtworkReference?) async {
        let token = UUID()
        loadID = token
        image = nil
        failed = false
        guard let reference else { loading = false; return }
        loading = true
        defer { if loadID == token { loading = false } }
        do {
            let loaded = try await CatalogArtworkStore.shared.image(for: reference)
            try Task.checkCancellation()
            guard loadID == token else { return }
            image = loaded
        } catch is CancellationError { }
        catch { if loadID == token { failed = true } }
    }
}

struct CatalogArtworkView: View {
    let reference: CatalogArtworkReference?
    var status: CatalogArtworkStatus = .absent
    var contentMode: ContentMode = .fill
    @StateObject private var presentation = ArtworkPresentation()

    private var fallbackMessage: String {
        if presentation.failed { return "Artwork couldn't be loaded" }
        switch status {
        case .available: return "Loading artwork"
        case .absent: return "No artwork provided"
        case .rejected: return "Artwork isn't available from an approved source"
        case .notQueried: return "Artwork hasn't been checked"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = presentation.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    ZStack {
                        Color(nsColor: .controlBackgroundColor)
                        if presentation.loading { ProgressView().controlSize(.small) }
                        else {
                            Image(systemName: presentation.failed ? "photo.badge.exclamationmark" : "gamecontroller")
                                .font(.title2).foregroundStyle(.secondary)
                        }
                    }
                    .help(fallbackMessage)
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: reference) { await presentation.load(reference) }
    }
}
