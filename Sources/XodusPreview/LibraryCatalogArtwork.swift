// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OSLog
import XodusManagement

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
    @Published private(set) var error: String?
    @Published private(set) var detailErrors: [String: String] = [:]
    private var requested: [String: Date] = [:]
    private var pending: Task<Void, Never>?
    private var scope: String?
    private var generation = UUID()
    private var pendingID = UUID()
    private var detailPending: [String: Task<Void, Never>] = [:]
    private let descriptors: PublicCatalogDescriptors
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "catalog-detail")

    init(transport: (any PCGamesTransport)? = nil, descriptors: PublicCatalogDescriptors? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.descriptors = descriptors ?? transport.map { PublicCatalogDescriptors(transport: $0) } ?? .shared
        self.now = now
    }

    private func enterScope(_ next: String) -> UUID {
        if scope != next {
            generation = UUID()
            scope = next
            pending?.cancel()
            pending = nil
            for task in detailPending.values { task.cancel() }
            detailPending = [:]
            if !images.isEmpty { images = [:] }
            if !detailErrors.isEmpty { detailErrors = [:] }
            if error != nil { error = nil }
            requested = [:]
        }
        return generation
    }

    func loadDetail(id: String, market: String, language: String) async {
        let nextScope = "\(PCGamesClient.market(market)):\(PCGamesClient.language(language).lowercased())"
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

    func load(ids: [String], market: String, language: String, refresh: Bool = false) async {
        let nextScope = "\(PCGamesClient.market(market)):\(PCGamesClient.language(language).lowercased())"
        let epoch = enterScope(nextScope)
        while let pending {
            await pending.value
            guard !Task.isCancelled, generation == epoch else { return }
        }
        guard !Task.isCancelled, generation == epoch else { return }
        let time = now()
        let ids = Set(ids.filter(PCGamesClient.validProductID))
            .filter { refresh || (requested[$0].map { $0 <= time } ?? true) }.sorted()
        guard !ids.isEmpty else { return }
        let token = UUID()
        let task = Task {
            defer {
                if generation == epoch, pendingID == token { pending = nil }
            }
            do {
                for start in stride(from: 0, to: ids.count, by: 20) {
                    try Task.checkCancellation()
                    let batch = Array(ids[start..<min(start + 20, ids.count)])
                    let data = try await descriptors.load(ids: batch, market: market, language: language, refresh: refresh)
                    let expirations = await descriptors.expirations(ids: batch, market: market, language: language)
                    let failures = await descriptors.failures(ids: batch, market: market, language: language)
                    guard !Task.isCancelled, generation == epoch else { return }
                    let parsed = try await Self.parseResponse(data, batch: batch, market: market, language: language)
                    guard !Task.isCancelled, generation == epoch else { return }
                    if parsed.rejectedDetailPayload {
                        logger.warning("Optional public detail payload was rejected; library identity and artwork remain separate.")
                    }
                    if !parsed.errors.isEmpty {
                        logger.warning("Optional public game details were rejected; game access and actions are unchanged.")
                    }
                    var batchErrors = detailErrors
                    for (id, message) in failures { batchErrors[id] = message }
                    for id in parsed.images.keys { batchErrors[id] = parsed.errors[id] }
                    if !parsed.images.isEmpty {
                        images.merge(parsed.images, uniquingKeysWith: { _, new in new })
                    }
                    if batchErrors != detailErrors { detailErrors = batchErrors }
                    for id in parsed.images.keys { requested[id] = expirations[id] }
                }
                if generation == epoch {
                    let failures = await descriptors.failures(ids: ids, market: market, language: language)
                    error = failures.isEmpty ? nil : "Some public game details couldn't be loaded. Try again."
                }
            } catch is CancellationError { }
            catch {
                guard generation == epoch else { return }
                self.error = (error as? PCGamesError)?.localizedDescription
                    ?? "Game artwork and details couldn't be loaded. Check your connection and try again."
            }
        }
        pending = task
        pendingID = token
        await task.value
    }

    struct ParsedResponse: Sendable {
        let images: [String: Images]
        let errors: [String: String]
        let rejectedDetailPayload: Bool
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
        let products = try JSONDecoder().decode(PCGamesCatalog.self, from: data).Products
        guard products.count <= batch.count, Set(products.map(\.ProductId)).count == products.count,
              products.allSatisfy({ batch.contains($0.ProductId) }) else { throw PCGamesError.invalidResponse }
        var details: [String: CatalogDetailPayload.Product] = [:]
        var rejectedDetailPayload = false
        do {
            let values = try JSONDecoder().decode(CatalogDetailPayload.self, from: data).Products
            guard values.count <= batch.count, Set(values.map(\.ProductId)).count == values.count,
                  values.allSatisfy({ batch.contains($0.ProductId) }) else { throw PCGamesError.invalidResponse }
            details = Dictionary(uniqueKeysWithValues: values.map { ($0.ProductId, $0) })
        } catch {
            rejectedDetailPayload = true
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
            let detail = try LibraryGame.details(id: product.ProductId, title: title,
                artwork: (heroes.first.map { [$0] } ?? []) + (cover.map { [$0] } ?? []),
                market: market, language: language, source: "MicrosoftDisplayCatalog:v7",
                pcCandidate: product.isBaseGame == true && product.isPC)
            var detailFacts: CatalogDetailFacts?
            do {
                guard let value = details[product.ProductId] else { throw PCGamesError.invalidResponse }
                detailFacts = try CatalogDetailFacts(product: value, images: art,
                                                   market: market, language: language)
                batchErrors[product.ProductId] = nil
            } catch {
                batchErrors[product.ProductId] =
                    "Microsoft returned game details Ode to X couldn't read. Try again."
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
            rejectedDetailPayload: rejectedDetailPayload)
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
