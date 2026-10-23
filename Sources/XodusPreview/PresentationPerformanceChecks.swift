// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import CoreFoundation
import Foundation
import XodusManagement

@MainActor
enum PresentationPerformanceChecks {
    static func launch() -> Never {
        Task {
            do { try run(); exit(0) }
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
        let facts = Dictionary(uniqueKeysWithValues: products.map {
            ($0.id, LibraryCatalogFacts(genres: [], isBaseGame: true))
        })
        let installed = products.prefix(4).map {
            InstalledGame(id: UUID(), title: $0.title, identityName: "Fixture", version: "1",
                storeId: $0.id, folder: "/synthetic/not-read", launcher: "/synthetic/not-executed",
                importedAt: .distantPast)
        }
        func key(query: String = "", revision: UInt64 = 0, account: String? = "account-a") -> CatalogProjectionKey {
            CatalogProjectionKey(accountHash: account, query: query, owned: owned, products: products,
                gamePass: [], gamePassIDs: [products[20].id], installed: installed, accessIsCurrent: false,
                metadataRevision: revision, compatibility: [:], genre: nil, showsUnsupported: true)
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
        let cache = PresentationCache<CatalogProjectionKey, CatalogProjection>(empty: .empty)
        for _ in 0..<100 {
            cache.prepare(key()) { CatalogProjection(key: key(), facts: [:], isVisible: { _ in true }) }
        }
        check(cache.builds == 1, "Unchanged body/scroll/hero updates retain one Discover projection")
        for changed in [key(query: "Fixture 1"), key(revision: 1), key(account: "account-b")] {
            cache.prepare(changed) { CatalogProjection(key: changed, facts: [:], isVisible: { _ in true }) }
        }
        check(cache.builds == 4, "Query, metadata revision and account replacement invalidate projections")
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
        func libraryKey(permitted: Set<String>) -> LibraryProjectionKey {
            LibraryProjectionKey(accountHash: "account-a", query: "", owned: [], products: products,
                gamePass: [], active: false, installed: installed, permitted: permitted,
                launchable: Set(installed.map(\.id)), accessIsCurrent: true, metadataRevision: 0,
                compatibility: [:], filter: .all, sort: .title, showsUnsupported: true)
        }
        let permitted = Set(installed.map(\.storeId))
        let input = libraryKey(permitted: permitted)
        let projection = LibraryProjection(key: input, isVisible: { _ in true }, recommendable: { _ in true })
        let original = LibraryGame.collection(installed: installed, owned: [], products: products,
            gamePass: [], active: false, accessIsCurrent: true, permittedInstalledIDs: permitted)
        check(projection.collection.map(\.id) == original.map(\.id)
              && projection.visible.map(\.id) == LibraryGame.visible(original, query: "", filter: .all, sort: .title).map(\.id)
              && projection.local.isEmpty, "Retained Library preserves qualified join, sort and local separation")
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
                }
            }
        }
        let mixedInput = libraryKey(permitted: [installed[0].storeId])
        let mixed = LibraryProjection(key: mixedInput, isVisible: { _ in true }, recommendable: { _ in true })
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
            for implementation in ["baseline", "indexed-cold", "indexed-warm"] {
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
                    if implementation == "indexed-cold" { cache.clear(to: .empty) }
                    cache.prepare(key) { CatalogProjection(key: key, facts: [:], isVisible: { _ in true }) }
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
                "worstMS": samples.last!, "resultBuildsPerEvaluation":
                    implementation == "baseline" ? count + 1 : implementation == "indexed-cold" ? 1 : 0,
                "installedComparisonsPerEvaluation": implementation == "baseline" ? count * (count + 1) / 2 : 0,
                "projectionBuilds": cache.builds,
                "checksum": checksum, "renderOnlyNotWireCoverage": true,
                "actualFramesOrInputLatencyMeasured": false
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            }
        }
    }
}
#endif
