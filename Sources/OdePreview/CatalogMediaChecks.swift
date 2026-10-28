// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Darwin
import Foundation
import OdeManagement

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
        let sharedReference = try makeReference("SharedLibraryDiscover")
        MediaFixtureProtocol.state.reset([.init(status: 200, headers: [
            "Content-Type": "image/png", "Cache-Control": "max-age=3600"
        ], data: data)])
        let sharedStore = CatalogArtworkStore(diskCache: reopened, session: session)
        async let libraryImage = sharedStore.image(for: sharedReference, bucket: .card)
        async let discoverImage = sharedStore.image(for: sharedReference, bucket: .card)
        let (firstCard, secondCard) = try await (libraryImage, discoverImage)
        let warmCard = try await sharedStore.image(for: sharedReference, bucket: .card)
        _ = try await sharedStore.image(for: sharedReference, bucket: .hero)
        check(firstCard === secondCard && firstCard === warmCard
              && MediaFixtureProtocol.state.observed().count == 1,
              "REQ-82: Library/Discover concurrent card artwork coalesces one download; warm cards reuse the decoded image and hero size reuses saved bytes")
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
            } catch {
                check(true, "Redirect/non-image/oversize/invalid media is rejected before persistence")
                let held = PCGame(id: "FIXTURE00001", title: "Held with unavailable artwork", artwork: rejected)
                let row = LibraryGame.collection(installed: [], owned: [held], products: [],
                    gamePass: [], active: false)[0]
                check(row.title == held.title && row.facts.badgeLabels() == ["In your library"]
                      && row.facts.support == .unknown
                      && DiscoverBrowse.canReviewInstall(owned: row.pc != nil,
                        accessIsCurrent: row.accessIsCurrent, gamePass: false,
                        subscriptionActive: false, pcCandidate: true),
                      "REQ-50: Actual artwork load failure does not withdraw held UI facts or review eligibility")
            }
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

        // REQ-121: cleanup cadence. Saves under budget never rescan the folder until the sweep timer.
        let cadenceClock = MediaFixtureClock()
        let cadenceDirectory = root.appendingPathComponent("cadence")
        let cadence = CatalogMediaDiskCache(directory: cadenceDirectory, now: { cadenceClock.now() })
        for suffix in ["D", "E", "F"] {
            let saved = try makeReference(suffix).validatedURL()
            try await cadence.store(entry(saved), for: saved, generation: 0)
        }
        let earlySweeps = await cadence.sweeps
        cadenceClock.advance(CatalogMediaDiskCache.sweepInterval)
        let later = try makeReference("G").validatedURL()
        try await cadence.store(entry(later), for: later, generation: 0)
        let timedSweeps = await cadence.sweeps
        check(earlySweeps == 1 && timedSweeps == 2,
              "REQ-121: The artwork disk cache sweeps once per session and on its timer, not after every save")

        // REQ-121: sign-out clears saved artwork and saved public descriptors together.
        let signOutDirectory = root.appendingPathComponent("sign-out")
        let savedArtwork = CatalogMediaDiskCache(directory: signOutDirectory.appendingPathComponent("media"))
        try await savedArtwork.store(entry(url), for: url, generation: 0)
        let savedDescriptors = PublicDescriptorDiskCache(directory: signOutDirectory.appendingPathComponent("descriptors"))
        let savedKey = PublicDescriptorDiskCache.Key(id: "9SIGNOUT0001", market: "GB", language: "en-gb")
        try await savedDescriptors.store([savedKey: try JSONSerialization.data(withJSONObject: ["ProductId": "9SIGNOUT0001"])],
                                         fetchedAt: Date())
        let signOutStore = CatalogArtworkStore(diskCache: savedArtwork, session: session,
                                               descriptors: PublicCatalogDescriptors(persistence: savedDescriptors))
        let artworkBefore = try await savedArtwork.lookup(url).entry != nil
        let descriptorsBefore = await savedDescriptors.read([savedKey]).count
        try await signOutStore.clearForSignOut()
        let artworkAfter = try await savedArtwork.lookup(url).entry != nil
        let descriptorsAfter = await savedDescriptors.read([savedKey]).count
        check(artworkBefore && descriptorsBefore == 1 && !artworkAfter && descriptorsAfter == 0,
              "REQ-121: Sign-out cleanup clears both saved artwork and saved public descriptors")

        // REQ-121: decoded-artwork memory budget and memory-pressure eviction.
        check(CatalogArtworkStore.memoryCountLimit == 200 && CatalogArtworkStore.memoryCostLimit == 256 * 1024 * 1024
              && CatalogArtworkStore(diskCache: nil, session: session).memoryLimits == (200, 256 * 1024 * 1024),
              "REQ-121: Decoded artwork keeps up to 200 images or 256 MiB in memory")
        let pressured = CatalogArtworkStore(diskCache: nil, session: session)
        let pressureReference = try makeReference("Pressure")
        let reply = MediaFixtureState.Reply(status: 200, headers: [
            "Content-Type": "image/png", "Cache-Control": "max-age=3600"], data: data)
        MediaFixtureProtocol.state.reset([reply, reply])
        let decoded = try await pressured.image(for: pressureReference, bucket: .card)
        let warm = try await pressured.image(for: pressureReference, bucket: .card)
        let beforePressure = MediaFixtureProtocol.state.observed().count
        let cachedBefore = pressured.cachedImage(for: pressureReference, bucket: .hero) != nil
        pressured.handleMemoryPressure()
        let cachedAfter = pressured.cachedImage(for: pressureReference, bucket: .card) != nil
        _ = try await pressured.image(for: pressureReference, bucket: .card)
        check(decoded === warm && beforePressure == 1 && cachedBefore && !cachedAfter
              && MediaFixtureProtocol.state.observed().count == 2 && pressured.pressureEvictions == 1,
              "REQ-121: Memory pressure evicts decoded artwork, and the next read decodes it again")

        // REQ-121: a tile keeps its artwork only while the same game's artwork is resized or refreshed.
        let tileStore = CatalogArtworkStore(diskCache: nil, session: session)
        let tracker = ArtworkDrawTracker(firstTileCount: 1)
        let tile = ArtworkPresentation(store: tileStore, tracker: tracker)
        let gameA = "product:9TILEA000001"
        let first = CatalogArtworkRequest(reference: try makeReference("TileA"), bucket: .card, identity: gameA)
        MediaFixtureProtocol.state.reset([reply])
        await tile.load(first)
        let shown = tile.displayImage(for: first)
        let refreshing = CatalogArtworkRequest(reference: try makeReference("TileA2"), bucket: .card, identity: gameA)
        let keptWhileRefreshing = tile.displayImage(for: refreshing)
        MediaFixtureProtocol.state.reset([])
        await tile.load(refreshing)
        let keptAfterFailure = tile.displayImage(for: refreshing)
        let sameGameFailed = tile.failed
        let refreshed = CatalogArtworkRequest(reference: try makeReference("TileA3"), bucket: .card, identity: gameA)
        MediaFixtureProtocol.state.reset([reply])
        let replacing = Task { await tile.load(refreshed) }
        let keptWhileLoading = tile.displayImage(for: refreshed)
        await replacing.value
        let replaced = tile.displayImage(for: refreshed)
        check(shown != nil && keptWhileRefreshing === shown && keptAfterFailure === shown && sameGameFailed
              && keptWhileLoading === shown && replaced != nil && replaced !== shown && !tile.failed,
              "REQ-121: A tile keeps its artwork while the same game's refreshed artwork loads or fails")

        let ownedFirst = try makeReference("TileC1"), ownedRefresh = try makeReference("TileC2")
        CatalogArtworkIdentity.register([ownedFirst, ownedRefresh], owner: "9TILEC000001")
        let libraryTile = ArtworkPresentation(store: tileStore)
        let libraryFirst = CatalogArtworkRequest(reference: ownedFirst, bucket: .card)
        MediaFixtureProtocol.state.reset([reply])
        await libraryTile.load(libraryFirst)
        let libraryShown = libraryTile.displayImage(for: libraryFirst)
        let libraryKept = libraryTile.displayImage(for: CatalogArtworkRequest(reference: ownedRefresh, bucket: .card))
        let notBorrowed = libraryTile.displayImage(for: CatalogArtworkRequest(reference: try makeReference("TileD"),
                                                                               bucket: .card))
        check(libraryShown != nil && libraryKept === libraryShown && notBorrowed == nil,
              "REQ-121: A refreshed URL the catalogue publishes for the same product keeps the tile's art; another URL never borrows it")

        let row = ArtworkPresentation(store: tileStore)
        let rowGameA = CatalogArtworkRequest(reference: try makeReference("RowA"), bucket: .card, identity: "product:9ROWA0000001")
        MediaFixtureProtocol.state.reset([reply])
        await row.load(rowGameA)
        let rowShown = row.displayImage(for: rowGameA)
        let rowGameB = CatalogArtworkRequest(reference: try makeReference("RowB"), bucket: .card, identity: "product:9ROWB0000001")
        let whileOtherGameLoads = row.displayImage(for: rowGameB)
        MediaFixtureProtocol.state.reset([])
        await row.load(rowGameB)
        let afterOtherGameFails = row.displayImage(for: rowGameB)
        check(rowShown != nil && whileOtherGameLoads == nil && afterOtherGameFails == nil && row.failed && row.image == nil,
              "REQ-121: Another game's artwork never shows the previous game's image, and its failure shows the failure placeholder")

        let withdrawnRequest = CatalogArtworkRequest(reference: nil, bucket: .card, identity: gameA)
        let withdrawnDisplay = tile.displayImage(for: withdrawnRequest)
        await tile.load(withdrawnRequest)
        check(withdrawnDisplay == nil && tile.image == nil && tile.displayImage(for: withdrawnRequest) == nil,
              "REQ-121: Withdrawing artwork (no reference, as when artwork isn't allowed) removes art already drawn")
        let recreated = ArtworkPresentation(store: tileStore)
        let resized = CatalogArtworkRequest(reference: refreshed.reference, bucket: .hero, identity: gameA)
        check(recreated.displayImage(for: refreshed) === replaced && recreated.displayImage(for: resized) != nil
              && recreated.image(for: refreshed) == nil,
              "REQ-121: A recreated or resized tile draws already decoded artwork on its first frame")
        check(tracker.firstTilesDrawn && tracker.drawn == 1 && tracker.failed == 1 && tracker.active == 0
              && tracker.completedBursts == 3,
              "REQ-121: Tile draw signposts count real artwork, failures and completed visible bursts")
    }
}

private final class MediaFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
