// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OSLog
import OdeManagement

enum CatalogArtworkLoadPriority: String, Hashable, Sendable {
    case foreground
    case background
}

/// Per-load tallies; foreground and background loads run side by side, so nothing here is shared.
@MainActor
private final class CatalogArtworkLoadTally {
    var requested = 0
    var kept = 0
    var dropped = 0
    /// Products skipped as unreadable during this load; they make `error` retryable.
    var skipped = Set<String>()
}

@MainActor
final class LibraryCatalogArtwork: ObservableObject {
    static let shared = LibraryCatalogArtwork()
    struct Images: Sendable {
        let cover: CatalogArtworkReference?
        let hero: CatalogArtworkReference?
        let landscape: [CatalogArtworkReference]
        let logos: [CatalogArtworkReference]
        let facts: LibraryCatalogFacts
        let detail: CatalogDetailFacts?
        let product: CatalogProduct
    }
    @Published private(set) var images: [String: Images] = [:] {
        didSet { revision &+= 1 }
    }
    private(set) var revision: UInt64 = 0
    @Published private(set) var freeToPlayIDs = Set<String>() {
        didSet { if oldValue != freeToPlayIDs { revision &+= 1 } }
    }

    func recordFreeToPlay(_ ids: [String], market: String, language: String) {
        let nextScope = "\(market):\(PCGamesClient.language(language).lowercased())"
        _ = enterScope(nextScope)
        freeToPlayIDs = Set(ids.filter(PCGamesClient.validProductID))
    }
    @Published private(set) var error: String?
    @Published private(set) var detailErrors: [String: String] = [:]
    /// Product IDs whose public details are requested but not yet settled in this scope.
    @Published private(set) var pendingIDs: Set<String> = []
    private var pendingCounts: [String: Int] = [:]
    private var requested: [String: Date] = [:]
    private var pendingLoads: [CatalogArtworkLoadPriority: Task<Void, Never>] = [:]
    private var pendingLoadIDs: [CatalogArtworkLoadPriority: UUID] = [:]
    private var scope: String?
    private var generation = UUID()
    private var detailPending: [String: Task<Void, Never>] = [:]
    private var revalidations: [UUID: Task<Void, Never>] = [:]
    private let descriptors: PublicCatalogDescriptors
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.workingprinciple.xode", category: "catalog-detail")

    init(transport: (any PCGamesTransport)? = nil, descriptors: PublicCatalogDescriptors? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.descriptors = descriptors ?? transport.map { PublicCatalogDescriptors(transport: $0) } ?? .shared
        self.now = now
    }

    private func enterScope(_ next: String) -> UUID {
        if scope != next {
            generation = UUID()
            scope = next
            pendingLoads.values.forEach { $0.cancel() }
            pendingLoads = [:]
            pendingLoadIDs = [:]
            for task in detailPending.values { task.cancel() }
            detailPending = [:]
            for task in revalidations.values { task.cancel() }
            revalidations = [:]
            if !images.isEmpty { images = [:] }
            if !freeToPlayIDs.isEmpty { freeToPlayIDs = [] }
            if !detailErrors.isEmpty { detailErrors = [:] }
            if error != nil { error = nil }
            requested = [:]
            pendingCounts = [:]
            if !pendingIDs.isEmpty { pendingIDs = [] }
        }
        return generation
    }

    private func markPending(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { pendingCounts[id, default: 0] += 1 }
        let next = Set(pendingCounts.keys)
        if next != pendingIDs { pendingIDs = next }
    }

    private func settlePending(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let count = pendingCounts[id] else { continue }
            pendingCounts[id] = count > 1 ? count - 1 : nil
        }
        let next = Set(pendingCounts.keys)
        if next != pendingIDs { pendingIDs = next }
    }

    func retireScope() {
        _ = enterScope("retired:\(UUID().uuidString)")
    }

    func loadDetail(id: String, market: String, language: String) async {
        guard let market = PCGamesClient.market(market) else {
            retireScope()
            error = "Confirm your account country before loading game details."
            return
        }
        let nextScope = "\(market):\(PCGamesClient.language(language).lowercased())"
        guard PCGamesClient.validProductID(id) else { return }
        let epoch = enterScope(nextScope)
        if images[id]?.detail != nil, let expiry = requested[id], expiry > now() { return }
        if let task = detailPending[id] { await task.value; return }
        let task = Task {
            let detailLoader = LibraryCatalogArtwork(descriptors: descriptors, now: now)
            await detailLoader.load(ids: [id], market: market, language: language)
            guard !Task.isCancelled, generation == epoch else { return }
            if let image = detailLoader.images[id] {
                images[id] = image
                requested[id] = detailLoader.requested[id]
            }
            let message = detailLoader.detailErrors[id] ?? detailLoader.error
            if detailErrors[id] != message { detailErrors[id] = message }
        }
        detailPending[id] = task
        await task.value
        if generation == epoch { detailPending[id] = nil }
    }

    func load(ids: [String], market: String, language: String, refresh: Bool = false,
              priority: CatalogArtworkLoadPriority = .foreground) async {
        guard let market = PCGamesClient.market(market) else {
            retireScope()
            error = "Confirm your account country before loading game details."
            return
        }
        let span = LoadSignposts.begin("LibraryCatalogArtwork.load",
            "priority=\(priority.rawValue) inputIDs=\(Set(ids.filter(PCGamesClient.validProductID)).count)")
        let tally = CatalogArtworkLoadTally()
        defer {
            LoadSignposts.end("LibraryCatalogArtwork.load", span,
                "priority=\(priority.rawValue) requestedIDs=\(tally.requested) keptIDs=\(tally.kept) droppedIDs=\(tally.dropped) unresolvedIDs=\(tally.requested - tally.kept - tally.dropped)")
        }
        let nextScope = "\(market):\(PCGamesClient.language(language).lowercased())"
        let epoch = enterScope(nextScope)
        let marked = Set(ids.filter { PCGamesClient.validProductID($0) && (refresh || images[$0] == nil) })
        markPending(marked)
        defer { if generation == epoch { settlePending(marked) } }
        while let pending = pendingLoads[priority] {
            await pending.value
            guard !Task.isCancelled, generation == epoch else { return }
        }
        guard !Task.isCancelled, generation == epoch else { return }
        let time = now()
        // REQ-121: keep the caller's order so the first visible tiles are in the first batches.
        var seen = Set<String>()
        let ids = ids.filter { PCGamesClient.validProductID($0) && seen.insert($0).inserted }
            .filter { refresh || (requested[$0].map { $0 <= time } ?? true) }
        guard !ids.isEmpty else { return }
        tally.requested = ids.count
        let batches = stride(from: 0, to: ids.count, by: 20).map { Array(ids[$0..<min($0 + 20, ids.count)]) }
        let descriptors = descriptors
        let token = UUID()
        let task = Task {
            defer {
                if generation == epoch, pendingLoadIDs[priority] == token {
                    pendingLoads[priority] = nil
                    pendingLoadIDs[priority] = nil
                }
            }
            var failure: (any Error)?
            do {
                let background = priority == .background
                try await withThrowingTaskGroup(of: PCGamesClient.DescriptorBatchResult.self) { group in
                    var started = 0
                    while started < min(PCGamesClient.descriptorConcurrency, batches.count) {
                        PCGamesClient.addDescriptorRead(&group, index: started, batch: batches[started], descriptors: descriptors,
                            market: market, language: language, refresh: refresh, background: background)
                        started += 1
                    }
                    while let (_, batch, result) = try await group.next() {
                        guard !Task.isCancelled, generation == epoch else { throw CancellationError() }
                        do {
                            let read = try result.get()
                            let counts = try await apply(read.data, batch: batch, staleIDs: read.staleIDs,
                                                         market: market, language: language, epoch: epoch)
                            tally.kept += counts.kept
                            tally.dropped += counts.dropped
                            tally.skipped.formUnion(counts.skipped)
                            LoadSignposts.event("descriptorIDs",
                                "requestedIDs=\(counts.requested) keptIDs=\(counts.kept) droppedIDs=\(counts.dropped)")
                            if let revalidation = read.revalidation {
                                follow(revalidation, staleIDs: read.staleIDs, market: market, language: language, epoch: epoch)
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch { failure = failure ?? error }
                        if started < batches.count {
                            PCGamesClient.addDescriptorRead(&group, index: started, batch: batches[started], descriptors: descriptors,
                            market: market, language: language, refresh: refresh, background: background)
                            started += 1
                        }
                    }
                }
                // Review M4: `error` is the foreground outcome; a background warmup keeps per-ID
                // detail errors only, so it can't clear or raise the library's recovery state.
                guard generation == epoch, priority == .foreground else { return }
                if let failure {
                    self.error = Self.message(failure)
                } else {
                    let failures = await descriptors.failures(ids: ids, market: market, language: language)
                    guard generation == epoch else { return }
                    error = failures.isEmpty && tally.skipped.isEmpty
                        ? nil : "Some public game details couldn't be loaded. Try again."
                }
            } catch is CancellationError { }
            catch {
                guard generation == epoch, priority == .foreground else { return }
                self.error = Self.message(error)
            }
        }
        pendingLoads[priority] = task
        pendingLoadIDs[priority] = token
        await task.value
    }

    private static func message(_ error: any Error) -> String {
        (error as? PCGamesError)?.localizedDescription
            ?? "Game artwork and details couldn't be loaded. Check your connection and try again."
    }

    /// Publishes one batch. Saved (stale) entries are asked for again after `staleRetryDelay` unless their
    /// revalidation lands first.
    private func apply(_ data: Data, batch: [String], staleIDs: Set<String>, market: String, language: String,
                       epoch: UUID) async throws -> (requested: Int, kept: Int, dropped: Int, skipped: Set<String>) {
        let expirations = await descriptors.expirations(ids: batch, market: market, language: language)
        let failures = await descriptors.failures(ids: batch, market: market, language: language)
        guard !Task.isCancelled, generation == epoch else { throw CancellationError() }
        let parsed = try await Self.parseResponse(data, batch: batch, market: market, language: language)
        guard !Task.isCancelled, generation == epoch else { throw CancellationError() }
        let keptIDs = Set(parsed.keptProductIDs)
        let dropped = Set(batch).subtracting(keptIDs).count
        if parsed.rejectedDetailPayload {
            logger.warning("Optional public detail payload was rejected; library identity and artwork remain separate.")
        }
        if !parsed.errors.isEmpty {
            logger.warning("Optional public game details were rejected; game access and actions are unchanged.")
        }
        var batchErrors = detailErrors
        for (id, message) in failures { batchErrors[id] = message }
        for id in parsed.images.keys { batchErrors[id] = parsed.errors[id] }
        for id in parsed.skipped {
            batchErrors[id] = "Game details are temporarily unavailable. Try again."
        }
        if !parsed.images.isEmpty {
            for (id, image) in parsed.images {
                CatalogArtworkIdentity.register([image.cover, image.hero].compactMap { $0 } + image.landscape + image.logos,
                                                owner: id)
            }
            images.merge(parsed.images, uniquingKeysWith: { _, new in new })
        }
        if batchErrors != detailErrors { detailErrors = batchErrors }
        let retry = now().addingTimeInterval(PublicCatalogDescriptors.staleRetryDelay)
        for id in parsed.images.keys { requested[id] = staleIDs.contains(id) ? retry : expirations[id] }
        return (batch.count, keptIDs.count, dropped, parsed.skipped)
    }

    /// When a revalidation lands, adopts fresh expiries and republishes only the tiles whose details changed.
    private func follow(_ revalidation: Task<PublicCatalogDescriptors.Revalidated, Never>, staleIDs: Set<String>,
                        market: String, language: String, epoch: UUID) {
        let id = UUID()
        revalidations[id] = Task {
            defer { if generation == epoch { revalidations[id] = nil } }
            let changed = await revalidation.value.changed
            guard !Task.isCancelled, generation == epoch else { return }
            let ordered = staleIDs.sorted()
            let fresh = await descriptors.expirations(ids: ordered, market: market, language: language)
            guard !Task.isCancelled, generation == epoch else { return }
            for (id, expiry) in fresh where !changed.contains(id) { requested[id] = expiry }
            let updated = ordered.filter(changed.contains)
            guard !updated.isEmpty else { return }
            do {
                let data = try await descriptors.load(ids: updated, market: market, language: language)
                _ = try await apply(data, batch: updated, staleIDs: [], market: market,
                                    language: language, epoch: epoch)
            } catch is CancellationError { }
            catch {
                logger.warning("Revalidated public game details couldn't be shown; saved details remain.")
            }
        }
    }

    /// Waits until background revalidations started by earlier loads have been published.
    func waitForRevalidations() async {
        while let task = revalidations.values.first { await task.value }
    }

    struct ParsedResponse: Sendable {
        let images: [String: Images]
        let errors: [String: String]
        let rejectedDetailPayload: Bool
        let keptProductIDs: [String]
        /// Present but unreadable products; retryable, never silently dropped (review M2).
        var skipped: Set<String> = []
    }

    nonisolated static func parseResponse(_ data: Data, batch: [String], market: String,
                                         language: String) async throws -> ParsedResponse {
        let worker = Task.detached(priority: .utility) {
            try normalizeResponse(data, batch: batch, market: market, language: language)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    nonisolated static func normalizeResponse(_ data: Data, batch: [String], market: String,
                                             language: String) throws -> ParsedResponse {
        try Task.checkCancellation()
        // P0: per-item tolerance; an unreadable product skips only itself.
        let readable = try PCGamesClient.tolerantProducts(data, batch: batch)
        let products = readable.products
        var skipped = readable.dropped
        var details: [String: CatalogDetailPayload.Product] = [:]
        var rejectedDetailPayload = false
        do {
            let values = try JSONDecoder().decode(CatalogDetailPayload.self, from: data).Products
            guard values.count <= batch.count, Set(values.map(\.ProductId)).count == values.count,
                  values.allSatisfy({ batch.contains($0.ProductId) }) else { throw PCGamesError.invalidResponse }
            details = Dictionary(uniqueKeysWithValues: values.map { ($0.ProductId, $0) })
        } catch {
            rejectedDetailPayload = true
            // Keep each product's readable details rather than dropping the whole batch.
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = root["Products"] as? [Any] {
                for item in items {
                    guard let one = try? JSONSerialization.data(withJSONObject: ["Products": [item]]),
                          let value = try? JSONDecoder().decode(CatalogDetailPayload.self, from: one).Products.first,
                          batch.contains(value.ProductId), details[value.ProductId] == nil else { continue }
                    details[value.ProductId] = value
                }
            }
        }
        var batchImages: [String: Images] = [:]
        var batchErrors: [String: String] = [:]
        for product in products {
            try Task.checkCancellation()
            let art = product.LocalizedProperties?.first?.Images ?? []
            func references(_ purposes: [String], portrait: Bool) -> [CatalogArtworkReference] {
                var values: [CatalogArtworkReference] = []
                for purpose in purposes {
                    for image in art where image.ImagePurpose == purpose {
                        guard let width = image.Width, let height = image.Height,
                              portrait ? height > width : width > height else { continue }
                        if let value = PCGamesClient.artwork(uri: image.Uri, width: width, height: height,
                                                            role: portrait ? .boxArt : .hero) {
                            if !values.contains(value) { values.append(value) }
                        }
                    }
                }
                return values
            }
            let cover = references(["BoxArt", "Poster"], portrait: true).first
            let heroes = references(["SuperHeroArt", "TitledHeroArt", "TitleHeroArt", "Hero"], portrait: false)
            let screenshots = references(["Screenshot"], portrait: false)
            let landscape = Array(heroes.prefix(2)) + Array(screenshots.prefix(1)) + (cover.map { [$0] } ?? [])
            var unique: [CatalogArtworkReference] = []
            for value in landscape where !unique.contains(value) { unique.append(value) }
            let title = product.LocalizedProperties?.first?.ProductTitle ?? product.ProductId
            guard let detail = try? LibraryGame.details(id: product.ProductId, title: title,
                artwork: (heroes.first.map { [$0] } ?? []) + (cover.map { [$0] } ?? []),
                market: market, language: language, source: "MicrosoftDisplayCatalog:v7",
                pcCandidate: product.isBaseGame == true && product.isPC) else {
                skipped.insert(product.ProductId)
                continue
            }
            var detailFacts: CatalogDetailFacts?
            do {
                guard let value = details[product.ProductId] else { throw PCGamesError.invalidResponse }
                detailFacts = try CatalogDetailFacts(product: value, images: art,
                                                   market: market, language: language)
                batchErrors[product.ProductId] = nil
            } catch {
                batchErrors[product.ProductId] =
                    "Microsoft returned game details \(AppBrand.displayName) couldn't read. Try again."
            }
            batchImages[product.ProductId] = Images(cover: cover, hero: heroes.first,
                landscape: unique, logos: Self.logoReferences(in: art),
                facts: LibraryCatalogFacts(properties: product.Properties,
                                           downloadBytes: product.pcDownloadBytes,
                                           packageFormat: product.pcPackageFormat,
                                           pcPackageListed: product.pcPackageListing,
                                           isBaseGame: product.isBaseGame),
                detail: detailFacts, product: detail)
        }
        return ParsedResponse(images: batchImages, errors: batchErrors,
            rejectedDetailPayload: rejectedDetailPayload, keptProductIDs: products.map(\.ProductId).filter { !skipped.contains($0) },
            skipped: skipped)
    }

    func retry(id: String, market: String, language: String) async {
        requested.removeValue(forKey: id)
        await load(ids: [id], market: market, language: language, refresh: true)
    }

    func preload() async -> Int {
        await CatalogArtworkStore.shared.preload(images.values.flatMap { $0.landscape + $0.logos })
    }

    nonisolated static func logoReferences(in images: [PCGamesCatalog.Product.Localized.Image]) -> [CatalogArtworkReference] {
        ["Logo", "TitledHeroArt", "TitleHeroArt"].compactMap { purpose in
            images.first(where: { $0.ImagePurpose == purpose }).flatMap {
                PCGamesClient.artwork(uri: $0.Uri, width: $0.Width, height: $0.Height, role: .hero)
            }
        }
    }
}

enum LibraryCapability: String, CaseIterable, Identifiable {
    case singlePlayer = "Single player", multiplayer = "Online multiplayer", coop = "Co-op", crossPlatform = "Cross-platform multiplayer"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .singlePlayer: "person.fill"
        case .multiplayer: "person.2.fill"
        case .coop: "person.2"
        case .crossPlatform: "network"
        }
    }
    private var catalogNames: Set<String> {
        switch self {
        case .singlePlayer: ["SinglePlayer"]
        case .multiplayer: ["XblOnlineMultiPlayer"]
        case .coop: ["XblLocalCoop", "XblOnlineCoop", "XblCrossPlatformCoop"]
        case .crossPlatform: ["XblCrossPlatformMultiPlayer", "XblCrossPlatformCoop"]
        }
    }
    func matches(_ name: String) -> Bool { catalogNames.contains(name) }
}

struct LibraryCatalogFacts: Sendable {
    let genres: [String]
    let capabilities: [LibraryCapability]
    let downloadBytes: Int64?
    let packageFormat: String?
    let pcPackageListed: Bool?
    let isBaseGame: Bool?

    init(genres: [String], capabilities: [LibraryCapability] = [], downloadBytes: Int64? = nil,
         packageFormat: String? = nil, pcPackageListed: Bool? = nil, isBaseGame: Bool? = nil) {
        self.genres = Array(genres.prefix(2))
        self.capabilities = capabilities
        self.downloadBytes = downloadBytes
        self.packageFormat = packageFormat
        self.pcPackageListed = pcPackageListed
        self.isBaseGame = isBaseGame
    }

    init(properties: PCGamesCatalog.Product.PropertiesDTO?, downloadBytes: Int64? = nil,
         packageFormat: String? = nil, pcPackageListed: Bool? = nil, isBaseGame: Bool? = nil) {
        self.downloadBytes = downloadBytes
        self.packageFormat = packageFormat
        self.pcPackageListed = pcPackageListed
        self.isBaseGame = isBaseGame
        var seen = Set<String>()
        genres = Array((properties?.Categories ?? properties?.Category.map { [$0] } ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty && $0 != "Games" && $0.utf8.count <= 128 &&
                !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                seen.insert($0).inserted
            }.prefix(2))
        let attributes = (properties?.Attributes ?? []).filter {
            $0.ApplicablePlatforms.map { $0.contains("Desktop") || $0.contains("Windows.Desktop") } ?? true
        }
        capabilities = LibraryCapability.allCases.filter { capability in
            attributes.contains { $0.Name.map(capability.matches) ?? false }
        }
    }
}
