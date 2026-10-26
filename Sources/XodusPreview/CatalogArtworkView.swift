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

enum CatalogImageBucket: Int, CaseIterable, Sendable {
    case card = 640, medium = 1280, hero = 2400

    static func target(reference: CatalogArtworkReference?, size: CGSize, scale: CGFloat,
                       mode: ContentMode) -> Self? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return nil }
        var pixels = max(size.width, size.height) * scale
        if let width = reference?.width, let height = reference?.height, width > 0, height > 0 {
            let horizontal = size.width / CGFloat(width), vertical = size.height / CGFloat(height)
            let ratio = mode == .fill ? max(horizontal, vertical) : min(horizontal, vertical)
            pixels = CGFloat(max(width, height)) * ratio * scale
        }
        return allCases.first { CGFloat($0.rawValue) >= pixels } ?? .hero
    }
}

enum CatalogImagePolicy {
    static let maximumBytes = 8 * 1024 * 1024
    static let processingVersion = 1

    static func validatePixels(width: Int, height: Int) throws {
        guard (1...8192).contains(width), (1...8192).contains(height),
              width * height <= 16_777_216 else { throw ArtworkLoadError.oversized }
    }

    static func validatedSource(_ data: Data) throws -> CGImageSource {
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
        return source
    }

    static func decode(_ data: Data, bucket: CatalogImageBucket = .hero) throws -> CGImage {
        let source = try validatedSource(data)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket.rawValue,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ArtworkLoadError.invalidImage }
        return image
    }
}

private actor ArtworkWorkAdmission {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var active = 0
    private var waiters: [Waiter] = []
    #if DEBUG
    private(set) var peak = 0
    #endif

    func acquire() async throws {
        try Task.checkCancellation()
        if active < 2 {
            active += 1
            #if DEBUG
            peak = max(peak, active)
            #endif
            return
        }
        guard waiters.count < 64 else { throw ArtworkLoadError.unavailable }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelQueued(id) }
        }
    }

    private func cancelQueued(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().continuation.resume() }
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
    static let shared: CatalogArtworkStore = {
        let store = CatalogArtworkStore(descriptors: .shared)
        store.observeMemoryPressure()
        return store
    }()
    /// REQ-121: room for a full library of decoded cards plus heroes; memory pressure empties it.
    static let memoryCountLimit = 200
    static let memoryCostLimit = 256 * 1024 * 1024
    private struct ByteKey: Hashable { let url: URL; let generation: Int }
    private struct ImageKey: Hashable {
        let bytes: ByteKey
        let bucket: CatalogImageBucket
        let version = CatalogImagePolicy.processingVersion
        var cacheKey: NSString { "\(bytes.generation):\(version):\(bucket.rawValue):\(bytes.url.absoluteString)" as NSString }
    }
    private struct DiskUpdate: Sendable { let entry: CatalogMediaEntry?; let generation: Int }
    private struct ImageRead {
        let task: Task<NSImage, Error>
        var consumers: Set<UUID>
    }
    private struct ImageBytes: Sendable {
        let data: Data
        let expiry: Date?
        let isDiskHit: Bool
        let update: DiskUpdate?
    }
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [ImageKey: ImageRead] = [:]
    private var bytePending: [ByteKey: Task<ImageBytes, Error>] = [:]
    private let admission = ArtworkWorkAdmission()
    private let session: URLSession
    private let disk: CatalogMediaDiskCache?
    private var expires: [ImageKey: Date] = [:]
    private var generation = 0
    private let descriptors: PublicCatalogDescriptors?
    private var pressure: DispatchSourceMemoryPressure?
    private(set) var pressureEvictions = 0
    #if DEBUG
    private(set) var decodedVariants = 0
    private(set) var byteReads = 0
    #endif
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "catalog-artwork")

    init(diskCache: CatalogMediaDiskCache? = CatalogArtworkStore.defaultDiskCache(), session suppliedSession: URLSession? = nil,
         descriptors: PublicCatalogDescriptors? = nil) {
        disk = diskCache
        self.descriptors = descriptors
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
        cache.totalCostLimit = Self.memoryCostLimit
        cache.countLimit = Self.memoryCountLimit
    }

    var memoryLimits: (count: Int, cost: Int) { (cache.countLimit, cache.totalCostLimit) }

    private func observeMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleMemoryPressure() }
        }
        source.resume()
        pressure = source
    }

    /// Drops decoded artwork under memory pressure. Tiles keep the image they already show; saved bytes stay on disk.
    func handleMemoryPressure() {
        pressureEvictions += 1
        cache.removeAllObjects()
        expires.removeAll()
        logger.notice("stage=memoryPressureEviction; decoded artwork released")
    }

    /// A decoded image already in memory for this artwork, preferring the requested size, then larger, then smaller.
    /// It lets a recreated or resized tile draw at once; expiry is not checked because a load follows.
    func cachedImage(for reference: CatalogArtworkReference, bucket: CatalogImageBucket) -> NSImage? {
        guard let url = try? reference.validatedURL() else { return nil }
        let larger = CatalogImageBucket.allCases.filter { $0.rawValue >= bucket.rawValue }
        let smaller = CatalogImageBucket.allCases.filter { $0.rawValue < bucket.rawValue }.reversed()
        for candidate in larger + smaller {
            let key = ImageKey(bytes: ByteKey(url: url, generation: generation), bucket: candidate)
            if let image = cache.object(forKey: key.cacheKey) { return image }
        }
        return nil
    }

    nonisolated private static func defaultDiskCache() -> CatalogMediaDiskCache? {
        let isolated = ["--library-preview", "--export-preview", "--export-live", "--fixture", "--self-check", "--live-check", "--media-check", "--stats-check", "--presentation-performance-check", "--search-performance-check"]
        return CommandLine.arguments.contains(where: isolated.contains) ? nil : .production()
    }

    func clearCache() async throws {
        generation += 1
        cache.removeAllObjects()
        expires.removeAll()
        try await disk?.clear()
        try await descriptors?.clearPersisted()
    }

    /// Sign-out cleanup: removes saved artwork and, for the shared store, saved public descriptors, whose
    /// product IDs reflect the library and whose market reflects the account country.
    func clearForSignOut() async throws {
        generation += 1
        cache.removeAllObjects()
        expires.removeAll()
        LibraryCatalogArtwork.shared.retireScope()
        var artworkFailure: (any Error)?
        do { try await disk?.clear() }
        catch { artworkFailure = error }
        do { try await descriptors?.clearForSignOut() }
        catch { throw error }
        if let artworkFailure { throw artworkFailure }
    }

    #if DEBUG
    func peakConcurrentWork() async -> Int { await admission.peak }
    #endif

    func image(for reference: CatalogArtworkReference, bucket: CatalogImageBucket = .hero) async throws -> NSImage {
        try Task.checkCancellation()
        let url = try reference.validatedURL()
        let key = ImageKey(bytes: ByteKey(url: url, generation: generation), bucket: bucket)
        if let image = cache.object(forKey: key.cacheKey), expires[key].map({ $0 > Date() }) == true { return image }
        let consumer = UUID()
        let task: Task<NSImage, Error>
        if var read = pending[key] {
            read.consumers.insert(consumer)
            pending[key] = read
            task = read.task
        } else {
            task = startImage(key, url: url, bucket: bucket)
            pending[key] = ImageRead(task: task, consumers: [consumer])
        }
        defer { releaseConsumer(consumer, key: key) }
        let image = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in self.releaseConsumer(consumer, key: key) }
        }
        try Task.checkCancellation()
        return image
    }

    private func releaseConsumer(_ consumer: UUID, key: ImageKey) {
        guard var read = pending[key], read.consumers.remove(consumer) != nil else { return }
        if read.consumers.isEmpty {
            pending[key] = nil
            read.task.cancel()
        } else { pending[key] = read }
    }

    private func startImage(_ key: ImageKey, url: URL, bucket: CatalogImageBucket) -> Task<NSImage, Error> {
        Task {
            try await admission.acquire()
            do {
                try Task.checkCancellation()
                var bytes = try await imageBytes(key.bytes)
                try Task.checkCancellation()
                let decoded: CGImage
                do { decoded = try await decode(bytes.data, bucket: bucket) }
                catch {
                    guard bytes.isDiskHit, let disk else { throw error }
                    logger.warning("stage=imageCacheDecodeFailed; requesting public artwork")
                    do { try await disk.remove(url) }
                    catch { logger.warning("stage=imageCacheRemoveFailed; bypassing saved artwork") }
                    bytes = try await imageBytes(key.bytes, bypassingSaved: true)
                    try Task.checkCancellation()
                    decoded = try await decode(bytes.data, bucket: bucket)
                }
                try Task.checkCancellation()
                if let update = bytes.update, let disk {
                    do { try await disk.store(update.entry, for: url, generation: update.generation) }
                    catch { logger.warning("stage=imageCacheWriteFailed; public artwork is memory-only") }
                }
                try Task.checkCancellation()
                #if DEBUG
                decodedVariants += 1
                #endif
                let image = NSImage(cgImage: decoded, size: .zero)
                if key.bytes.generation == generation, let expiry = bytes.expiry, expiry > Date() {
                    expires[key] = expiry
                    cache.setObject(image, forKey: key.cacheKey, cost: decoded.bytesPerRow * decoded.height)
                    if expires.count > 2 * Self.memoryCountLimit {
                        expires = expires.filter { cache.object(forKey: $0.key.cacheKey) != nil }
                    }
                }
                logger.notice("stage=imageDecoded count=1 maxPixels=\(bucket.rawValue)")
                await admission.release()
                return image
            } catch {
                await admission.release()
                throw error
            }
        }
    }

    private func decode(_ data: Data, bucket: CatalogImageBucket) async throws -> CGImage {
        try await Task.detached(priority: .utility) { try CatalogImagePolicy.decode(data, bucket: bucket) }.value
    }

    private func imageBytes(_ key: ByteKey, bypassingSaved: Bool = false) async throws -> ImageBytes {
        if let task = bytePending[key] { return try await task.value }
        let url = key.url
        let session = session
        let disk = disk
        let logger = logger
        #if DEBUG
        byteReads += 1
        #endif
        let task = Task {
            try await Task.detached(priority: .utility) {
                var saved: CatalogMediaEntry?
                var diskGeneration: Int?
                if let disk {
                    do {
                        let lookup = try await disk.lookup(url)
                        diskGeneration = lookup.generation
                        saved = bypassingSaved ? nil : lookup.entry
                        if let saved, saved.expiresAt > Date() {
                            _ = try CatalogImagePolicy.validatedSource(saved.data)
                            return ImageBytes(data: saved.data, expiry: saved.expiresAt, isDiskHit: true, update: nil)
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
                _ = try CatalogImagePolicy.validatedSource(data)
                let now = Date()
                let expiry = CatalogMediaHTTPPolicy.expiry(http, now: now)
                var update: DiskUpdate?
                if disk != nil, let diskGeneration {
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
                    update = DiskUpdate(entry: entry, generation: diskGeneration)
                }
                return ImageBytes(data: data, expiry: expiry, isDiskHit: false, update: update)
            }.value
        }
        bytePending[key] = task
        defer { bytePending[key] = nil }
        return try await task.value
    }

    func preload(_ references: [CatalogArtworkReference]) async -> Int {
        let tasks = references.map { reference in
            Task {
                do { _ = try await image(for: reference, bucket: .card); return true }
                catch { return false }
            }
        }
        var failures = 0
        for task in tasks { if !(await task.value) { failures += 1 } }
        return failures
    }
}

struct CatalogArtworkRequest: Hashable {
    let reference: CatalogArtworkReference?
    let bucket: CatalogImageBucket?
    /// Whose artwork this is, usually a product ID. Nil uses the product that published the URL, else the URL.
    var identity: String? = nil
}

/// Maps published catalogue artwork URLs to the product that owns them, so a tile can tell a refreshed URL
/// for the same game from another game's artwork.
@MainActor
enum CatalogArtworkIdentity {
    private static var owners: [URL: String] = [:]

    static func register(_ references: [CatalogArtworkReference], owner: String) {
        if owners.count > 8_192 { owners.removeAll(keepingCapacity: true) }
        for reference in references {
            if let url = try? reference.validatedURL() { owners[url] = owner }
        }
    }

    static func identity(of request: CatalogArtworkRequest) -> String? {
        if let identity = request.identity { return identity }
        guard let url = try? request.reference?.validatedURL() else { return nil }
        return owners[url].map { "product:\($0)" } ?? "url:\(url.absoluteString)"
    }
}

@MainActor
final class ArtworkPresentation: ObservableObject {
    /// The last decoded image. While a request for the same artwork identity loads (a resize, or a refreshed
    /// URL for the same product), the tile keeps showing it (REQ-121); any other artwork never borrows it.
    @Published private(set) var image: NSImage?
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private var loadID = UUID()
    private var imageRequest: CatalogArtworkRequest?
    private var imageIdentity: String?
    private var drawn = false
    private let store: CatalogArtworkStore
    private let tracker: ArtworkDrawTracker?

    init(store: CatalogArtworkStore = .shared, tracker: ArtworkDrawTracker? = nil) {
        self.store = store
        self.tracker = tracker
    }

    /// The image decoded for exactly this request, or nil while another request's image is retained.
    func image(for request: CatalogArtworkRequest) -> NSImage? { imageRequest == request ? image : nil }

    /// What a tile draws: this request's image, else an already decoded copy of the same URL, else the tile's
    /// previous image only when it is the same artwork identity. A withdrawn reference (nil, for example when
    /// artwork isn't allowed) or another game's artwork draws the placeholder instead.
    func displayImage(for request: CatalogArtworkRequest) -> NSImage? {
        if imageRequest == request, let image { return image }
        guard let reference = request.reference else { return nil }
        if let bucket = request.bucket, let cached = store.cachedImage(for: reference, bucket: bucket) { return cached }
        guard let image, let imageIdentity, imageIdentity == CatalogArtworkIdentity.identity(of: request) else { return nil }
        return image
    }

    private func forgetImage() {
        image = nil
        imageRequest = nil
        imageIdentity = nil
    }

    func load(_ request: CatalogArtworkRequest) async {
        let token = UUID()
        loadID = token
        failed = false
        if request.reference == nil, image != nil { forgetImage() }
        guard let reference = request.reference, let bucket = request.bucket else { loading = false; return }
        let tracked = imageRequest == request ? nil : tracker
        tracked?.began()
        var outcome = (drawn: false, failed: false)
        loading = true
        defer {
            if loadID == token { loading = false }
            tracked?.finished(drawn: outcome.drawn, failed: outcome.failed)
        }
        do {
            let loaded = try await store.image(for: reference, bucket: bucket)
            try Task.checkCancellation()
            guard loadID == token else { return }
            image = loaded
            imageRequest = request
            imageIdentity = CatalogArtworkIdentity.identity(of: request)
            outcome.drawn = !drawn
            drawn = true
        } catch is CancellationError { }
        catch {
            if loadID == token {
                failed = true
                outcome.failed = true
                if imageIdentity != CatalogArtworkIdentity.identity(of: request) { forgetImage() }
            }
        }
    }
}

struct CatalogArtworkView: View {
    let reference: CatalogArtworkReference?
    var status: CatalogArtworkStatus = .absent
    var contentMode: ContentMode = .fill
    /// The product or other owner of this artwork, when the caller knows it (see `CatalogArtworkRequest.identity`).
    var identity: String? = nil
    @StateObject private var presentation = ArtworkPresentation(tracker: .shared)
    @Environment(\.displayScale) private var displayScale
    @Environment(\.catalogPresentationActive) private var presentationActive

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
            let request = CatalogArtworkRequest(reference: reference,
                bucket: CatalogImageBucket.target(reference: reference, size: geometry.size,
                                                   scale: displayScale, mode: contentMode),
                identity: identity.map { "product:\($0)" })
            Group {
                if let image = presentation.displayImage(for: request) {
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
            .task(id: presentationActive ? request : nil) {
                guard presentationActive else { return }
                await presentation.load(request)
            }
        }
        .accessibilityHidden(true)
    }
}
