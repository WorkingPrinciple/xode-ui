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
            let projection = CatalogProjection(key: input, facts: [:], isVisible: { _ in true })
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
