// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

@MainActor
final class PresentationCache<Key: Equatable, Value> {
    private var key: Key?
    private(set) var current: Value
    private(set) var builds = 0

    init(empty: Value) { current = empty }

    func clear(to empty: Value) {
        key = nil
        current = empty
    }

    func prepare(_ key: Key, build: () -> Value) {
        guard self.key != key else { return }
        current = build()
        self.key = key
        builds += 1
    }
}

struct CatalogCardIndex {
    let results: CatalogSearchResults
    let games: [String: LibraryGame]

    init(query: String, owned: [PCGame], products: [CatalogProduct], gamePass: [CatalogProduct],
         gamePassIDs: Set<String>, installed: [InstalledGame], accessIsCurrent: Bool,
         local: [CatalogProduct] = []) {
        results = CatalogSearchResults(query: query, ownedGames: owned, storeProducts: products,
            gamePassProductIDs: gamePassIDs, gamePassProducts: gamePass, localProducts: local)
        let local = Dictionary(installed.map { ($0.storeId, $0) }, uniquingKeysWith: { first, _ in first })
        let catalog = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var indexed: [String: LibraryGame] = [:]
        for product in results.storeProducts {
            let pc = results.ownedGame(for: product.id)
            indexed[product.id] = LibraryGame(id: product.id, title: product.title,
                installed: local[product.id], pc: pc, product: product,
                owned: pc.map { $0.acquisitionKind == .purchased } ?? false,
                gamePass: gamePassIDs.contains(product.id), accessIsCurrent: accessIsCurrent)
        }
        for pc in results.ownedMatches {
            indexed[pc.id] = LibraryGame(id: pc.id, title: pc.title, installed: local[pc.id],
                pc: pc, product: catalog[pc.id], owned: pc.acquisitionKind == .purchased,
                gamePass: gamePassIDs.contains(pc.id), accessIsCurrent: accessIsCurrent)
        }
        games = indexed
    }
}

struct CatalogProjectionKey: Equatable {
    let accountHash: String?
    let query: String
    let owned: [PCGame]
    let products: [CatalogProduct]
    let gamePass: [CatalogProduct]
    let gamePassIDs: Set<String>
    let installed: [InstalledGame]
    let accessIsCurrent: Bool
    let metadataRevision: UInt64
    let compatibility: [String: GameCompatibilityResult]
    let genre: String?
    var scope: GameSearchScope = .allGames
    let showsUnsupported: Bool
    var local: [CatalogProduct] = []
}

struct CatalogProjection {
    let index: CatalogCardIndex
    let facts: [String: LibraryCatalogFacts]
    let genres: [String]
    let genreProducts: [String: CatalogProduct]
    let genreShelves: [String: [CatalogProduct]]
    let visible: [CatalogProduct]
    let owned: [PCGame]
    let hiddenCount: Int
    let artworkIDs: [String]
    var unresolvedClassificationCount: Int {
        GameSurfaceFilter.counts(index.results.storeProducts, facts: facts).unresolved
    }

    static let empty = Self(index: CatalogCardIndex(query: "", owned: [], products: [], gamePass: [],
        gamePassIDs: [], installed: [], accessIsCurrent: false), facts: [:], genres: [],
        genreProducts: [:], genreShelves: [:], visible: [], owned: [], hiddenCount: 0, artworkIDs: [])

    init(key: CatalogProjectionKey, facts: [String: LibraryCatalogFacts],
         isVisible: (LibraryGame) -> Bool) {
        let index = CatalogCardIndex(query: key.query, owned: key.owned, products: key.products,
            gamePass: key.gamePass, gamePassIDs: key.gamePassIDs, installed: key.installed,
            accessIsCurrent: key.accessIsCurrent, local: key.local)
        self.index = index
        self.facts = facts
        let games = GameSurfaceFilter.games(index.results.storeProducts, facts: facts)
        genres = DiscoverBrowse.genres(products: games, facts: facts)
        var first: [String: CatalogProduct] = [:]
        for product in games {
            for genre in facts[product.id]?.genres ?? [] where first[genre] == nil { first[genre] = product }
        }

        genreProducts = first
        let candidates = DiscoverBrowse.visible(products: games, facts: facts,
            genre: key.query.isEmpty ? key.genre : nil)
        let classifiedProducts = candidates.filter { product in
            !key.query.isEmpty || index.games[product.id].map(isVisible) == true
        }
        let visibleProducts = classifiedProducts.filter { product in
            index.games[product.id].map(key.scope.includes) == true
        }
        visible = visibleProducts
        genreShelves = DiscoverBrowse.genreShelves(products: visibleProducts, facts: facts, genres: genres)
        let classifiedOwned = index.results.ownedMatches.filter { pc in
            !key.query.isEmpty || index.games[pc.id].map(isVisible) == true
        }
        owned = classifiedOwned.filter { pc in
            index.games[pc.id].map(key.scope.includes) == true
        }
        hiddenCount = candidates.count - classifiedProducts.count
            + index.results.ownedMatches.count - classifiedOwned.count
        artworkIDs = Array(Set(index.results.storeProducts.map(\.id) + key.owned.map(\.id))).sorted()
    }

    private init(index: CatalogCardIndex, facts: [String: LibraryCatalogFacts], genres: [String],
                 genreProducts: [String: CatalogProduct], genreShelves: [String: [CatalogProduct]],
                 visible: [CatalogProduct], owned: [PCGame],
                 hiddenCount: Int, artworkIDs: [String]) {
        self.index = index; self.facts = facts; self.genres = genres; self.genreProducts = genreProducts
        self.genreShelves = genreShelves
        self.visible = visible; self.owned = owned; self.hiddenCount = hiddenCount; self.artworkIDs = artworkIDs
    }
}

struct CatalogArtworkLoadKey: Equatable {
    let market: String
    let language: String
    let ids: [String]
}

struct LibraryProjectionKey: Equatable {
    let accountHash: String?
    let query: String
    let owned: [PCGame]
    let products: [CatalogProduct]
    let gamePass: [CatalogProduct]
    let active: Bool
    let installed: [InstalledGame]
    let permitted: Set<String>
    let launchable: Set<UUID>
    let accessIsCurrent: Bool
    let metadataRevision: UInt64
    let compatibility: [String: GameCompatibilityResult]
    let filter: LibraryFilter
    let sort: LibrarySort
    let showsUnsupported: Bool
    var gamePassPlanActive = false
    var denied: Set<String> = []
}

struct LibraryProjection {
    let collection: [LibraryGame]
    let byID: [String: LibraryGame]
    let candidates: [LibraryGame]
    let visible: [LibraryGame]
    let local: [LibraryGame]
    let continuing: [InstalledGame]
    let hero: [LibraryGame]

    static let empty = Self(collection: [], byID: [:], candidates: [], visible: [], local: [],
                            continuing: [], hero: [])

    init(key: LibraryProjectionKey, isVisible: (LibraryGame) -> Bool,
         recommendable: (LibraryGame) -> Bool) {
        collection = LibraryGame.collection(installed: key.installed, owned: key.owned, products: key.products,
            gamePass: key.gamePass, active: key.active, accessIsCurrent: key.accessIsCurrent,
            permittedInstalledIDs: key.permitted, gamePassPlanActive: key.gamePassPlanActive,
            deniedInstalledIDs: key.denied)
        byID = Dictionary(collection.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        candidates = LibraryGame.visible(collection.filter { $0.installed == nil },
            query: key.query, filter: key.filter, sort: key.sort)
        visible = candidates.filter(isVisible)
        local = LibraryGame.localRecords(installed: key.installed, qualified: collection,
            query: key.query, sort: key.sort, includingQualified: true)
        continuing = LibraryGame.continuing(collection.filter(recommendable), launchableIDs: key.launchable)
        hero = LibraryGame.heroCandidates(qualified: collection.filter(recommendable),
            catalogue: [], continuingIDs: continuing.map(\.id))
    }

    private init(collection: [LibraryGame], byID: [String: LibraryGame], candidates: [LibraryGame],
                 visible: [LibraryGame], local: [LibraryGame], continuing: [InstalledGame], hero: [LibraryGame]) {
        self.collection = collection; self.byID = byID; self.candidates = candidates
        self.visible = visible; self.local = local; self.continuing = continuing; self.hero = hero
    }
}
