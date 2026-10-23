// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OSLog
import XodusManagement

@MainActor
final class LibraryCatalogArtwork: ObservableObject {
    static let shared = LibraryCatalogArtwork()
    struct Images {
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
    private var requested = Set<String>()
    private var pending: Task<Void, Never>?
    private var scope: String?
    private var generation = UUID()
    private var pendingID = UUID()
    private var detailPending: [String: Task<Void, Never>] = [:]
    private let transport: any PCGamesTransport
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "catalog-detail")

    init(transport: any PCGamesTransport = PCGamesHTTP()) {
        self.transport = transport
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
            requested = []
        }
        return generation
    }

    func loadDetail(id: String, market: String, language: String) async {
        let nextScope = "\(PCGamesClient.market(market)):\(PCGamesClient.language(language).lowercased())"
        guard PCGamesClient.validProductID(id) else { return }
        let epoch = enterScope(nextScope)
        if images[id]?.detail != nil { return }
        if let task = detailPending[id] { await task.value; return }
        let task = Task {
            let detailLoader = LibraryCatalogArtwork(transport: transport)
            await detailLoader.load(ids: [id], market: market, language: language)
            guard !Task.isCancelled, generation == epoch else { return }
            if let image = detailLoader.images[id] {
                images[id] = image
                requested.insert(id)
            }
            let message = detailLoader.detailErrors[id] ?? detailLoader.error
            if detailErrors[id] != message { detailErrors[id] = message }
        }
        detailPending[id] = task
        await task.value
        if generation == epoch { detailPending[id] = nil }
    }

    func load(ids: [String], market: String, language: String) async {
        let nextScope = "\(PCGamesClient.market(market)):\(PCGamesClient.language(language).lowercased())"
        let epoch = enterScope(nextScope)
        while let pending {
            await pending.value
            guard !Task.isCancelled, generation == epoch else { return }
        }
        guard !Task.isCancelled, generation == epoch else { return }
        let ids = Set(ids.filter(PCGamesClient.validProductID)).subtracting(requested).sorted()
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
                    var url = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/products")
                    url?.queryItems = [URLQueryItem(name: "bigIds", value: batch.joined(separator: ",")),
                                      URLQueryItem(name: "market", value: PCGamesClient.market(market)),
                                      URLQueryItem(name: "languages", value: PCGamesClient.language(language))]
                    guard let endpoint = url?.url else { throw PCGamesError.invalidResponse }
                    var request = URLRequest(url: endpoint)
                    request.httpShouldHandleCookies = false
                    let response = try await transport.send(request)
                    guard !Task.isCancelled, generation == epoch else { return }
                    guard response.status == 200 else { throw PCGamesError.http(response.status) }
                    let products = try JSONDecoder().decode(PCGamesCatalog.self, from: response.data).Products
                    guard products.count <= batch.count, Set(products.map(\.ProductId)).count == products.count,
                          products.allSatisfy({ batch.contains($0.ProductId) }) else { throw PCGamesError.invalidResponse }
                    var details: [String: CatalogDetailPayload.Product] = [:]
                    do {
                        let values = try JSONDecoder().decode(CatalogDetailPayload.self, from: response.data).Products
                        guard values.count <= batch.count, Set(values.map(\.ProductId)).count == values.count,
                              values.allSatisfy({ batch.contains($0.ProductId) }) else { throw PCGamesError.invalidResponse }
                        details = Dictionary(uniqueKeysWithValues: values.map { ($0.ProductId, $0) })
                    } catch {
                        logger.warning("Optional public detail payload was rejected; library identity and artwork remain separate.")
                    }
                    var prices: [String: CatalogCommerce] = [:]
                    do {
                        let values = try JSONDecoder().decode(CatalogCommerce.Payload.self, from: response.data).Products
                        guard values.count <= batch.count, Set(values.map(\.ProductId)).count == values.count,
                              values.allSatisfy({ batch.contains($0.ProductId) }) else { throw PCGamesError.invalidResponse }
                        for value in values {
                            prices[value.ProductId] = CatalogCommerce.price(value, market: PCGamesClient.market(market))
                        }
                    } catch {
                        logger.warning("Public PC price offers were rejected; prices stay unavailable and no free acquisition is offered.")
                    }
                    var batchImages: [String: Images] = [:]
                    var batchErrors = detailErrors
                    for product in products {
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
                            pcCandidate: product.isPC)
                        var detailFacts: CatalogDetailFacts?
                        do {
                            guard let value = details[product.ProductId] else { throw PCGamesError.invalidResponse }
                            detailFacts = try CatalogDetailFacts(product: value, images: art,
                                                               market: market, language: language)
                            batchErrors[product.ProductId] = nil
                        } catch {
                            batchErrors[product.ProductId] =
                                "Microsoft returned game details Ode to X couldn't read. Try again."
                            logger.warning("Optional public game details were rejected; game access and actions are unchanged.")
                        }
                        batchImages[product.ProductId] = Images(cover: cover, hero: heroes.first,
                            landscape: unique, logos: Self.logoReferences(in: art),
                            facts: LibraryCatalogFacts(properties: product.Properties,
                                                       downloadBytes: product.pcDownloadBytes,
                                                       packageFormat: product.pcPackageFormat,
                                                       pcPackageListed: product.pcPackageListing,
                                                       commerce: prices[product.ProductId]),
                            detail: detailFacts, product: detail)
                    }
                    if !batchImages.isEmpty {
                        images.merge(batchImages, uniquingKeysWith: { _, new in new })
                    }
                    if batchErrors != detailErrors { detailErrors = batchErrors }
                    requested.formUnion(batch)
                }
                if generation == epoch, error != nil { error = nil }
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

    func retry(id: String, market: String, language: String) async {
        requested.remove(id)
        await load(ids: [id], market: market, language: language)
    }

    func preload() async -> Int {
        await CatalogArtworkStore.shared.preload(images.values.flatMap { $0.landscape + $0.logos })
    }

    static func logoReferences(in images: [PCGamesCatalog.Product.Localized.Image]) -> [CatalogArtworkReference] {
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

struct LibraryCatalogFacts {
    let genres: [String]
    let capabilities: [LibraryCapability]
    let downloadBytes: Int64?
    let packageFormat: String?
    let pcPackageListed: Bool?
    let commerce: CatalogCommerce?

    init(genres: [String], capabilities: [LibraryCapability] = [], downloadBytes: Int64? = nil,
         packageFormat: String? = nil, pcPackageListed: Bool? = nil, commerce: CatalogCommerce? = nil) {
        self.genres = Array(genres.prefix(2))
        self.capabilities = capabilities
        self.downloadBytes = downloadBytes
        self.packageFormat = packageFormat
        self.pcPackageListed = pcPackageListed
        self.commerce = commerce
    }

    init(properties: PCGamesCatalog.Product.PropertiesDTO?, downloadBytes: Int64? = nil,
         packageFormat: String? = nil, pcPackageListed: Bool? = nil, commerce: CatalogCommerce? = nil) {
        self.downloadBytes = downloadBytes
        self.packageFormat = packageFormat
        self.pcPackageListed = pcPackageListed
        self.commerce = commerce
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
