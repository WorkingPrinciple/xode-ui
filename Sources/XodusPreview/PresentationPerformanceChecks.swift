// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import CoreFoundation
import Foundation
import XodusManagement

@MainActor
enum PresentationPerformanceChecks {
    static func launch() -> Never {
        Task {
            do { try run(); try runCachedShelfComparison(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("Presentation benchmark failed: \(error)\n".utf8))
                exit(1)
            }
        }
        CFRunLoopRun()
        fatalError("Benchmark run loop ended")
    }

    static func correctness(check: (Bool, String) -> Void) throws {
        let products = try (0..<36).map {
            try LibraryGame.details(id: String(format: "9PERF%07d", $0), title: "Fixture \($0)",
                market: "US", language: "en-US", source: "SyntheticRenderOnly", pcCandidate: true)
        }
        let owned = products.prefix(12).map { PCGame(product: $0) }
        check(DiscoverBrowse.admittedIDs(products, limit: 16) == products.prefix(16).map(\.id),
              "REQ-81/82: Initial metadata admission uses sixteen ordered public IDs, never all Library games")
        check(DiscoverBrowse.admittedIDs(products, limit: 32).count == 32,
              "REQ-81: One explicit demand admits one further sixteen-game page")
        let shelfFacts = Dictionary(uniqueKeysWithValues: products.prefix(2).map {
            ($0.id, LibraryCatalogFacts(genres: ["Puzzle"], isBaseGame: true))
        })
        let boundedShelves = DiscoverBrowse.genreShelves(products: Array(products.prefix(2)),
            facts: shelfFacts, genres: ["Puzzle", "Action"], shelfLimit: 1, productLimit: 1)
        check(boundedShelves.keys.sorted() == ["Puzzle"]
              && boundedShelves["Puzzle"]?.map(\.id) == [products[0].id],
              "Discover genre shelf projections retain source order and enforce shelf/card bounds")
        check(DiscoverBrowse.genreShelves(products: products, facts: [:], genres: ["Puzzle"],
                  shelfLimit: -1, productLimit: -1).isEmpty,
              "Invalid shelf limits fail closed instead of trapping or expanding rendered work")
        let recent = ["Halo", "Forza"]
        check(DiscoverSearchOverlayLayout.isPresented(searchFocused: true, suggestionFocused: false,
                  query: "  ", searches: recent)
              && DiscoverSearchOverlayLayout.isPresented(searchFocused: false, suggestionFocused: true,
                  query: "", searches: recent)
              && !DiscoverSearchOverlayLayout.isPresented(searchFocused: false, suggestionFocused: false,
                  query: "", searches: recent)
              && !DiscoverSearchOverlayLayout.isPresented(searchFocused: true, suggestionFocused: false,
                  query: "Halo", searches: recent)
              && !DiscoverSearchOverlayLayout.isPresented(searchFocused: true, suggestionFocused: false,
                  query: "", searches: []),
              "Recent searches appear only for an empty active Discover search and dismiss on selection, blur or clear")
        check(DiscoverSearchOverlayLayout.keyboardFocus(query: "  ", searches: recent) == .search("Halo")
              && DiscoverSearchOverlayLayout.keyboardFocus(query: "", searches: []) == nil
              && DiscoverSearchOverlayLayout.keyboardFocus(query: "Halo", searches: recent) == nil,
              "Native Down/Return hands an empty search to its first recent suggestion without changing populated-search behavior")
        check(SubscriberBenefits.officialURL.scheme == "https"
              && SubscriberBenefits.officialURL.host == "www.xbox.com"
              && SubscriberBenefits.officialURL.path == "/xbox-game-pass/in-game-benefits",
              "REQ-83: Unavailable free-to-keep offers route only to official benefits guidance, not fabricated claim cards")
        let facts = Dictionary(uniqueKeysWithValues: products.map {
            ($0.id, LibraryCatalogFacts(genres: [], isBaseGame: true))
        })
        let installed = products.prefix(4).map {
            InstalledGame(id: UUID(), title: $0.title, identityName: "Fixture", version: "1",
                storeId: $0.id, folder: "/synthetic/not-read", launcher: "/synthetic/not-executed",
                importedAt: .distantPast)
        }
        func key(query: String = "", revision: UInt64 = 0, account: String? = "account-a",
                 scope: GameSearchScope = .allGames, genre: String? = nil) -> CatalogProjectionKey {
            CatalogProjectionKey(accountHash: account, query: query, owned: owned, products: products,
                gamePass: [], gamePassIDs: [products[20].id], installed: installed, accessIsCurrent: false,
                metadataRevision: revision, compatibility: [:], genre: genre, scope: scope,
                showsUnsupported: true)
        }
        for query in ["", "Fixture 1", "fixture", "missing"] {
            let input = key(query: query)
            let projection = CatalogProjection(key: input, facts: facts, isVisible: { _ in true })
            let original = CatalogSearchResults(query: query, ownedGames: owned, storeProducts: products,
                gamePassProductIDs: input.gamePassIDs)
            check(projection.visible.map(\.id) == original.storeProducts.map(\.id)
                  && projection.owned.map(\.id) == original.ownedMatches.map(\.id),
                  "Indexed Discover preserves search order and deduplication: \(query)")
            for product in original.storeProducts {
                let game = projection.index.games[product.id]
                check(game?.installed?.id == installed.first(where: { $0.storeId == product.id })?.id
                      && game?.pc == original.ownedGame(for: product.id)
                      && game?.accessIsCurrent == false,
                      "Indexed card preserves installed/account evidence without promoting authority")
            }
            let unclassified = CatalogProjection(key: key(), facts: [:], isVisible: { _ in true })
            check(unclassified.visible.isEmpty && unclassified.unresolvedClassificationCount == products.count
                  && unclassified.artworkIDs.count == products.count,
                  "Unclassified Discover items remain explicit unresolved metadata work, not displayed games or discarded load IDs")
            var mixedFacts = facts
            mixedFacts[products[0].id] = LibraryCatalogFacts(genres: ["Productivity"], isBaseGame: false)
            let mixed = CatalogProjection(key: key(), facts: mixedFacts, isVisible: { _ in true })
            check(!mixed.visible.contains { $0.id == products[0].id } && !mixed.genres.contains("Productivity"),
                  "Explicit public applications cannot leak through Discover cards or genre navigation")
        }
        let scopedFacts = Dictionary(uniqueKeysWithValues: products.map {
            ($0.id, LibraryCatalogFacts(genres: ["Puzzle"], isBaseGame: true))
        })
        let allScope = CatalogProjection(key: key(genre: "Puzzle"), facts: scopedFacts, isVisible: { _ in true })
        let installedScope = CatalogProjection(key: key(scope: .installed, genre: "Puzzle"), facts: scopedFacts,
                                               isVisible: { _ in true })
        let gamePassScope = CatalogProjection(key: key(scope: .gamePass, genre: "Puzzle"), facts: scopedFacts,
                                              isVisible: { _ in true })
        check(allScope.visible.count == products.count
              && allScope.genreShelves["Puzzle"]?.map(\.id) == Array(products.prefix(12).map(\.id))
              && installedScope.visible.map(\.id) == Array(products.prefix(4).map(\.id))
              && installedScope.genreShelves["Puzzle"]?.map(\.id) == Array(products.prefix(4).map(\.id))
              && gamePassScope.visible.map(\.id) == [products[20].id]
              && gamePassScope.genreShelves["Puzzle"]?.map(\.id) == [products[20].id],
              "Discover scope filters genre shelves as well as the main result set")
        let scopedCache = PresentationCache<CatalogProjectionKey, CatalogProjection>(empty: .empty)
        let installedKey = key(scope: .installed, genre: "Puzzle")
        scopedCache.prepare(installedKey) {
            CatalogProjection(key: installedKey, facts: scopedFacts, isVisible: { _ in true })
        }
        var updatedScopedFacts = scopedFacts
        updatedScopedFacts[products[0].id] = LibraryCatalogFacts(genres: ["Puzzle"], isBaseGame: false)
        let revisedInstalledKey = key(revision: 1, scope: .installed, genre: "Puzzle")
        scopedCache.prepare(revisedInstalledKey) {
            CatalogProjection(key: revisedInstalledKey, facts: updatedScopedFacts, isVisible: { _ in true })
        }
        check(scopedCache.builds == 2
              && scopedCache.current.genreShelves["Puzzle"]?.map(\.id)
                == Array(products[1...3].map(\.id)),
              "Metadata revision rebuilds a scoped genre shelf without retaining a newly ineligible title")
        let cache = PresentationCache<CatalogProjectionKey, CatalogProjection>(empty: .empty)
        for _ in 0..<100 {
            cache.prepare(key()) { CatalogProjection(key: key(), facts: [:], isVisible: { _ in true }) }
        }
        check(cache.builds == 1, "Unchanged body/scroll/hero updates retain one Discover projection")
        for changed in [key(query: "Fixture 1"), key(revision: 1), key(account: "account-b"),
                        key(scope: .installed)] {
            cache.prepare(changed) { CatalogProjection(key: changed, facts: [:], isVisible: { _ in true }) }
        }
        check(cache.builds == 5, "Query, metadata revision, account and scope changes invalidate projections")
        cache.clear(to: .empty)
        check(cache.current.index.games.isEmpty, "Account retirement releases retained private projection data")
        let searchSelection = DiscoverSelection()
        let firstSearch = key(query: "Fixture")
        searchSelection.prepare(firstSearch, accountScope: "account-a:US:en-US") {
            CatalogProjection(key: firstSearch, facts: facts, isVisible: { _ in true })
        }
        let nextSearch = key(query: "Fixture 1")
        searchSelection.prepare(nextSearch, accountScope: "account-a:US:en-US") { .empty }
        check(!searchSelection.previousResults.visible.isEmpty
              && !searchSelection.previousResults.owned.isEmpty
              && searchSelection.projection.current.visible.isEmpty,
              "REQ-59: Typing retains prior catalogue and library results separately from the pending query")
        searchSelection.prepare(key(query: "Fixture 12"), accountScope: "account-a:US:en-US") { .empty }
        check(!searchSelection.previousResults.visible.isEmpty,
              "REQ-59: Rapid edits cannot replace useful dimmed results with an empty pending projection")
        searchSelection.prepare(nextSearch, accountScope: "account-a:GB:en-GB") { .empty }
        check(searchSelection.previousResults.index.games.isEmpty,
              "REQ-59: A market/language change cannot retain prior-scope results")
        searchSelection.prepare(firstSearch, accountScope: "account-a:GB:en-GB") {
            CatalogProjection(key: firstSearch, facts: facts, isVisible: { _ in true })
        }
        searchSelection.prepare(nextSearch, accountScope: "account-a:GB:en-GB") { .empty }
        searchSelection.clear()
        check(searchSelection.previousResults.index.games.isEmpty
              && searchSelection.projection.current.index.games.isEmpty,
              "REQ-59: Account retirement releases current and dimmed private library results")
        func libraryKey(permitted: Set<String>, owned: [PCGame] = [], filter: LibraryFilter = .all) -> LibraryProjectionKey {
            LibraryProjectionKey(accountHash: "account-a", query: "", owned: owned, products: products,
                gamePass: [], active: false, installed: installed, permitted: permitted,
                launchable: Set(installed.map(\.id)), accessIsCurrent: true, metadataRevision: 0,
                compatibility: [:], filter: filter, sort: .title, showsUnsupported: true)
        }
        let permitted = Set(installed.map(\.storeId))
        let input = libraryKey(permitted: permitted)
        let projection = LibraryProjection(key: input, isVisible: { _ in true }, recommendable: { _ in true })
        let original = LibraryGame.collection(installed: installed, owned: [], products: products,
            gamePass: [], active: false, accessIsCurrent: true, permittedInstalledIDs: permitted)
        check(projection.collection.map(\.id) == original.map(\.id)
              && projection.visible.isEmpty
              && projection.local.count == installed.count,
              "Retained Library preserves qualified authority while all installed cards stay in one inventory")
        let libraryCache = PresentationCache<LibraryProjectionKey, LibraryProjection>(empty: .empty)
        libraryCache.prepare(input) { projection }
        let expired = libraryKey(permitted: [])
        libraryCache.prepare(expired) {
            LibraryProjection(key: expired, isVisible: { _ in true }, recommendable: { _ in true })
        }
        check(libraryCache.builds == 2 && libraryCache.current.collection.isEmpty
              && libraryCache.current.local.count == installed.count && libraryCache.current.hero.isEmpty,
              "Expiry/negative authority changes immediately remove qualified rows and heroes, not installed records")
        let localOnly = libraryCache.current.local
        for qualifiedPresent in [false, true] {
            for localPresent in [false, true] {
                for nativePresent in [false, true] {
                    let qualified = qualifiedPresent ? projection.visible : []
                    let local = localPresent ? localOnly : []
                    check(LibraryGame.displayedCount(qualified: qualified, local: local, native: nativePresent)
                          == qualified.count + local.count + (nativePresent ? 1 : 0),
                          "REQ-64: Displayed total includes qualified=\(qualifiedPresent), local=\(localPresent), native=\(nativePresent)")
                    check(LibraryGame.installedCount(local: local, native: nativePresent)
                          == LibraryGame.displayedCount(qualified: [], local: local, native: nativePresent),
                          "REQ64: Installed filter total and inventory section count the same registry and native cards")
                }
            }
        }
        let mixedInput = libraryKey(permitted: [installed[0].storeId])
        let mixed = LibraryProjection(key: mixedInput, isVisible: { _ in true }, recommendable: { _ in true })
        check(projection.local.map(\.id) == mixed.local.map(\.id)
              && mixed.local.map(\.id) == localOnly.map(\.id)
              && projection.local.count == installed.count
              && projection.visible.allSatisfy { $0.installed == nil },
              "Installed inventory stays in place through pending, partial and complete license checks without duplicate main-grid cards")
        let purchased = PCGame(id: installed[0].storeId, title: installed[0].title, artwork: nil,
                               acquisitionKind: .purchased)
        let ownedInventory = LibraryProjection(key: libraryKey(permitted: permitted,
            owned: [purchased], filter: .owned), isVisible: { _ in true }, recommendable: { _ in true })
        let ownedInstalled = LibraryGame.visible(ownedInventory.local, query: "", filter: .owned, sort: .title)
        check(ownedInventory.visible.isEmpty && ownedInstalled.count == 1
              && ownedInstalled.first?.installed?.id == installed[0].id
              && LibraryGame.visible(localOnly, query: "", filter: .owned, sort: .title).isEmpty,
              "Installed inventory retains purchased filtering without inventing ownership while grants are pending")
        let qualifiedIDs = Set(mixed.visible.compactMap { $0.installed?.id })
        let localIDs = Set(mixed.local.compactMap { $0.installed?.id })
        check(qualifiedIDs.isDisjoint(with: localIDs)
              && qualifiedIDs.union(localIDs) == Set(installed.map(\.id))
              && LibraryGame.displayedCount(qualified: mixed.visible, local: mixed.local, native: true)
                  == installed.count + 1
              && (mixed.visible + mixed.local).allSatisfy { !$0.owned },
              "REQ-64: Mixed qualified/local/native total counts each installation once without inventing ownership")
    }

    static func run() throws {
        for count in [36, 300, 512, 565] {
            let products = try (0..<count).map { index in
                try LibraryGame.details(id: String(format: "9PERF%07d", index),
                    title: String(format: "Fixture %04d", count - index), market: "US", language: "en-US",
                    source: "SyntheticRenderOnly", pcCandidate: true)
            }
            let owned = products.map { PCGame(product: $0) }
            let installed = products.map {
                InstalledGame(id: UUID(), title: $0.title, identityName: "Fixture",
                    version: "1.0.0.0", storeId: $0.id, folder: "/synthetic/not-read",
                    launcher: "/synthetic/not-executed", importedAt: .distantPast)
            }
            let key = CatalogProjectionKey(accountHash: nil, query: "", owned: owned,
                products: products, gamePass: [], gamePassIDs: [], installed: installed, accessIsCurrent: true,
                metadataRevision: 0, compatibility: [:], genre: nil, showsUnsupported: true)
            for implementation in ["baseline", "indexed-cold", "indexed-warm", "bounded-first-view"] {
              let evaluatedKey = implementation == "bounded-first-view"
                ? CatalogProjectionKey(accountHash: nil, query: "", owned: owned,
                    products: Array(products.prefix(16)), gamePass: [], gamePassIDs: [],
                    installed: installed, accessIsCurrent: true, metadataRevision: 0,
                    compatibility: [:], genre: nil, showsUnsupported: true)
                : key
              let cache = PresentationCache<CatalogProjectionKey, CatalogProjection>(empty: .empty)
              if implementation == "indexed-warm" {
                  cache.prepare(key) { CatalogProjection(key: key, facts: [:], isVisible: { _ in true }) }
              }
              var samples: [Double] = []
              var checksum = 0
              for _ in 0..<20 {
                let start = ContinuousClock.now
                if implementation == "baseline" {
                let results = CatalogSearchResults(query: "", ownedGames: owned, storeProducts: products,
                    gamePassProductIDs: [])
                for product in results.storeProducts {
                    let repeated = CatalogSearchResults(query: "", ownedGames: owned,
                        storeProducts: products, gamePassProductIDs: [])
                    checksum += repeated.ownedGame(for: product.id)?.title.count ?? 0
                    checksum += installed.first(where: { $0.storeId == product.id })?.title.count ?? 0
                }
                } else {
                    if implementation != "indexed-warm" { cache.clear(to: .empty) }
                    cache.prepare(evaluatedKey) { CatalogProjection(key: evaluatedKey, facts: [:], isVisible: { _ in true }) }
                    let projection = cache.current
                    for product in projection.index.results.storeProducts {
                        checksum += projection.index.games[product.id]?.pc?.title.count ?? 0
                        checksum += projection.index.games[product.id]?.installed?.title.count ?? 0
                    }
                }
                let elapsed = start.duration(to: .now).components
                samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
            samples.sort()
            let result: [String: Any] = [
                "kind": "synthetic-discover-card-preparation", "implementation": implementation,
                "items": count, "samples": samples.count, "medianMS": (samples[9] + samples[10]) / 2, "p95MS": samples[18],
                "admittedProducts": evaluatedKey.products.count,
                "worstMS": samples.last!, "resultBuildsPerEvaluation":
                    implementation == "baseline" ? count + 1 : implementation == "indexed-warm" ? 0 : 1,
                "installedComparisonsPerEvaluation": implementation == "baseline" ? count * (count + 1) / 2 : 0,
                "projectionBuilds": cache.builds,
                "checksum": checksum, "renderOnlyNotWireCoverage": true,
                "actualFramesOrInputLatencyMeasured": false
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            }
        }
        let categories = ["Action", "Adventure", "Role-playing", "Strategy"]
        let shelfProducts = try (0..<512).map { index in
            try LibraryGame.details(id: String(format: "9SHELF%06d", index),
                title: String(format: "Shelf fixture %04d", index), market: "US", language: "en-US",
                source: "SyntheticRenderOnly", pcCandidate: true)
        }
        let shelfFacts = Dictionary(uniqueKeysWithValues: shelfProducts.enumerated().map { index, product in
            (product.id, LibraryCatalogFacts(genres: [categories[index % categories.count]], isBaseGame: true))
        })
        let genres = Array(categories.prefix(3))
        var bodyUpdateSamples: [Double] = []
        var shelfChecksum = 0
        for _ in 0..<20 {
            let start = ContinuousClock.now
            for _ in 0..<80 {
                for genre in genres {
                    shelfChecksum += DiscoverBrowse.visible(products: shelfProducts, facts: shelfFacts,
                                                            genre: genre).prefix(12).count
                }
            }
            let elapsed = start.duration(to: .now).components
            bodyUpdateSamples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        bodyUpdateSamples.sort()
        print(String(decoding: try JSONSerialization.data(withJSONObject: [
            "kind": "synthetic-discover-scroll-shelf-body-updates",
            "implementation": "repeated-body-filter", "loadedProducts": shelfProducts.count,
            "shelves": genres.count, "simulatedBodyUpdates": 80, "samples": bodyUpdateSamples.count,
            "medianMS": (bodyUpdateSamples[9] + bodyUpdateSamples[10]) / 2,
            "p95MS": bodyUpdateSamples[18], "checksum": shelfChecksum, "actualFramesMeasured": false
        ], options: [.sortedKeys]), as: UTF8.self))
    }

    private static func runCachedShelfComparison() throws {
        let categories = ["Action", "Adventure", "Role-playing", "Strategy"]
        let products = try (0..<512).map { index in
            try LibraryGame.details(id: String(format: "9SHELF%06d", index),
                title: String(format: "Shelf fixture %04d", index), market: "US", language: "en-US",
                source: "SyntheticRenderOnly", pcCandidate: true)
        }
        let facts = Dictionary(uniqueKeysWithValues: products.enumerated().map { index, product in
            (product.id, LibraryCatalogFacts(genres: [categories[index % categories.count]], isBaseGame: true))
        })
        let genres = Array(categories.prefix(3))
        let key = CatalogProjectionKey(accountHash: nil, query: "", owned: [], products: products,
            gamePass: [], gamePassIDs: [], installed: [], accessIsCurrent: false,
            metadataRevision: 0, compatibility: [:], genre: nil, showsUnsupported: true)
        let projection = CatalogProjection(key: key, facts: facts, isVisible: { _ in true })
        var samples: [Double] = []
        var checksum = 0
        for _ in 0..<20 {
            let start = ContinuousClock.now
            for _ in 0..<80 {
                for genre in genres {
                    checksum += projection.genreShelves[genre]?.count ?? 0
                }
            }
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        samples.sort()
        print(String(decoding: try JSONSerialization.data(withJSONObject: [
            "kind": "synthetic-discover-scroll-shelf-body-updates",
            "implementation": "cached-projection-shelves", "loadedProducts": products.count,
            "shelves": genres.count, "simulatedBodyUpdates": 80, "samples": samples.count,
            "medianMS": (samples[9] + samples[10]) / 2, "p95MS": samples[18],
            "checksum": checksum, "actualFramesMeasured": false
        ], options: [.sortedKeys]), as: UTF8.self))
    }
}
#endif
