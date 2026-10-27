// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import XodusManagement

/// REQ-5/24/25/65/81/85 source regressions for game-only Discover surfaces and official Game Pass shelves.
@MainActor
enum DiscoverShelfChecks {
    static func product(_ id: String, pcCandidate: Bool = false) throws -> CatalogProduct {
        let payload: [String: Any] = [
            "productID": id, "title": id, "market": "US", "language": "en-US",
            "source": "MicrosoftDisplayCatalog:v7", "checkedAt": "2026-10-26T00:00:00Z",
            "freshness": "current", "editions": [], "pcCatalogCandidate": pcCandidate,
            "artwork": [], "artworkStatus": "absent"
        ]
        return try JSONDecoder().decode(CatalogProduct.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    static func run(check: (Bool, String) -> Void) throws {
        try classificationChecks(check: check)
        try shelfChecks(check: check)
        accessBadgeChecks(check: check)
        try gamePassAvailabilityChecks(check: check)
        try pendingSearchChecks(check: check)
        let home = NSHomeDirectory()
        let surfaced = [NativeMinecraftCardCopy.help, NativeMinecraftCardCopy.label(version: "2.6.12"),
                        NativeMinecraftCardCopy.label(version: nil),
                        NativeMinecraftCardCopy.label(version: "\(home)/Applications/Minecraft.app")]
        check(surfaced[1] == "Minecraft Launcher · 2.6.12" && surfaced[2] == "Minecraft Launcher"
              && surfaced[3] == "Minecraft Launcher"
              && !surfaced.contains { $0.contains(home) || $0.contains("/Users/") || $0.contains("/") },
              "REQ-23/60: the Library Minecraft card label and help name the launcher without any home or filesystem path")
        check(!RecentActivityCopy.findAction.contains("Store")
              && !RecentActivityCopy.findLabel("Fixture").contains("Store"),
              "REQ-60: recent-activity cards name the in-app Discover search, not a Store or source")
    }

    private static func accessBadgeChecks(check: (Bool, String) -> Void) {
        func card(_ facts: GameFacts, gamePass: Bool) -> GameCard<EmptyView, EmptyView> {
            GameCard(title: "Fixture", gameFacts: facts, showsGamePassCatalogBadge: gamePass, open: {},
                     artwork: { EmptyView() }, status: { EmptyView() })
        }
        let purchased = GameFacts(ownership: .purchased(nil), accessIsCurrent: true)
        let stale = GameFacts(ownership: .purchased(nil), accessIsCurrent: false)
        let subscription = GameFacts(ownership: .inLibraryUnknownAcquisition, accessIsCurrent: true)
        check(card(purchased, gamePass: true).artworkBadges == ["Owned", "Game Pass"]
              && card(purchased, gamePass: false).artworkBadges == ["Owned"]
              && card(GameFacts(), gamePass: true).artworkBadges == ["Game Pass"]
              && card(GameFacts(), gamePass: false).artworkBadges.isEmpty,
              "REQ-63: cards show purchase and Game Pass membership independently: both, either or neither")
        check(card(stale, gamePass: false).artworkBadges.isEmpty
              && card(subscription, gamePass: false).artworkBadges.isEmpty
              && card(purchased, gamePass: true).coverStatusDescription == "Owned, In PC Game Pass catalog",
              "REQ-63: stale holdings and subscription grants never assert ownership; VoiceOver hears both facts")
    }

    private static func classificationChecks(check: (Bool, String) -> Void) throws {
        let facts: [String: LibraryCatalogFacts] = [
            "FIXTURE00001": LibraryCatalogFacts(genres: ["Puzzle"], pcPackageListed: true, isBaseGame: true),
            "FIXTURE00002": LibraryCatalogFacts(genres: ["Productivity"], pcPackageListed: true, isBaseGame: false),
            "FIXTURE00003": LibraryCatalogFacts(genres: ["Puzzle"], pcPackageListed: false, isBaseGame: true),
            "FIXTURE00004": LibraryCatalogFacts(genres: ["Strategy"], pcPackageListed: true),
            "FIXTURE00005": LibraryCatalogFacts(genres: ["Strategy"], isBaseGame: true)
        ]
        let products = try facts.keys.sorted().map { try product($0) } + [try product("FIXTURE00006")]
        let admitted = GameSurfaceFilter.games(products, facts: facts)
        check(admitted.map(\.id) == ["FIXTURE00001"]
              && GameSurfaceFilter.counts(products, facts: facts)
                  == GameSurfaceFilter.Counts(games: 1, excluded: 2, unresolved: 3)
              && DiscoverBrowse.genres(products: admitted, facts: facts)
                  == ["Puzzle"],
              "REQ-5: base-game plus Windows Desktop facts keep games, exclude apps and non-PC products, and leave missing or partial classification unresolved before genre aggregation")
        let candidate = try product("FIXTURE00005", pcCandidate: true)
        let nonPC = try product("FIXTURE00003", pcCandidate: true)
        check(GameSurfaceFilter.classification(candidate, facts: facts) == .game
              && GameSurfaceFilter.classification(nonPC, facts: facts) == .notGame,
              "REQ-5: the existing PC package evidence seam fills only a missing listing; observed non-PC listing still excludes")
        let key = CatalogProjectionKey(accountHash: nil, query: "", owned: [], products: products,
            gamePass: [], gamePassIDs: [], installed: [], accessIsCurrent: false, metadataRevision: 0,
            compatibility: [:], genre: nil, showsUnsupported: true)
        let projection = CatalogProjection(key: key, facts: facts, isVisible: { _ in true })
        check(projection.visible.map(\.id) == ["FIXTURE00001"] && projection.genres == ["Puzzle"]
              && projection.unresolvedClassificationCount == 3,
              "REQ-5: Discover browse, genres and unresolved count use the same game-surface classification")
    }

    private static func shelfChecks(check: (Bool, String) -> Void) throws {
        let feeds = [
            "XGPPMPRecentlyAdded": "00000000-0000-4000-8000-000000000011",
            "pcgaVTpopular": "00000000-0000-4000-8000-000000000012",
            "SubsXGPLeavingSoon": "00000000-0000-4000-8000-000000000013",
            "pccomingsoon": "00000000-0000-4000-8000-000000000014",
            "pdoPC": "00000000-0000-4000-8000-000000000015"
        ]
        let html = """
            <script src="/en-US/xbox-game-pass/games/js/xgpcatPopulate-MWF2.js"></script>
            <span class="colgroup collections-pc hidden">
            <a data-col="pcgaVTpopular"><span>Most popular</span></a>
            <a data-col="pccomingsoon"><span>Coming soon</span></a>
            <a data-col="SubsXGPLeavingSoon"><span>Leaving soon</span></a>
            <a data-col="pdoPC"><span>Play day one</span></a>
            <span class="colgroup collections-cloud hidden">
            """
        let mapping = String(data: try JSONSerialization.data(withJSONObject: feeds, options: [.sortedKeys]),
                             encoding: .utf8) ?? "{}"
        let script = """
            var globalAdd = {
              "00000000-0000-4000-8000-000000000016": { colname: "ftpbenefitspc", plat: "pc",
                title: "In-game benefits**en-gb", spot: 5, startstring: "ftpbenefitspc" }
            }
            var newListIds = Object.keys(globalAdd);
            guidAmpt = \(mapping);
            """
        let definitions = try GamePassCollectionSource.definitions(html: html, script: script)
        let selected = GamePassCollections.select(definitions, keys: DiscoverGamePassShelf.keys, retaining: [])
        check(selected.map(\.key) == DiscoverGamePassShelf.keys
              && selected.first { $0.key == "SubsXGPLeavingSoon" }?.feedID == feeds["SubsXGPLeavingSoon"]
              && selected.first { $0.key == "ftpbenefitspc" }?.feedID == "00000000-0000-4000-8000-000000000016"
              && !selected.contains { $0.isUpcoming },
              "REQ-65/25: Discover selects only the official Recently added, Most popular, Leaving soon and free-to-play lists, in shelf order, never Coming soon")

        let game = try product("FIXTURE00021", pcCandidate: true)
        let otherGame = try product("FIXTURE00022", pcCandidate: true)
        let app = try product("FIXTURE00023", pcCandidate: true)
        let unknown = try product("FIXTURE00024")
        let facts: [String: LibraryCatalogFacts] = [
            game.id: LibraryCatalogFacts(genres: [], pcPackageListed: true, isBaseGame: true),
            otherGame.id: LibraryCatalogFacts(genres: [], pcPackageListed: true, isBaseGame: true),
            app.id: LibraryCatalogFacts(genres: [], pcPackageListed: true, isBaseGame: false)
        ]
        var recent = selected[0]
        recent.productIDs = [otherGame.id, app.id, unknown.id, game.id]
        recent.products = [otherGame, app, unknown, game]
        check(DiscoverGamePassShelf.products(recent, facts: facts) { _ in true }.map(\.id) == [otherGame.id, game.id],
              "REQ-65/5: shelf keeps the official list order and shows only classified PC games")
        check(DiscoverGamePassShelf.products(recent, facts: facts) { $0.id != otherGame.id }.map(\.id) == [game.id]
              && DiscoverGamePassShelf.products(nil, facts: facts) { _ in true }.isEmpty,
              "REQ-65: shelves honour the supported-games filter and are absent without a populated source")
        let upcoming = GamePassCollection(key: "pccomingsoon", feedID: feeds["pccomingsoon"] ?? "",
            title: "Coming soon", productIDs: recent.productIDs, products: recent.products)
        check(DiscoverGamePassShelf.products(upcoming, facts: facts) { _ in true }.isEmpty,
              "REQ-65: unreleased Coming soon members never appear as playable shelves")

        let retained = GamePassCollections.select(definitions, keys: DiscoverGamePassShelf.keys, retaining: [recent])
        check(retained[0].products.map(\.id) == recent.products.map(\.id) && retained[0].productIDs.isEmpty
              && retained[0].loadedCount == recent.products.count,
              "REQ-65: a refresh keeps previous members until the official list is read again")
        let partial = GamePassCollections.merged([game], retaining: [otherGame, game], ids: [otherGame.id, game.id])
        check(partial.map(\.id) == [otherGame.id, game.id],
              "REQ-65: a still-listed member whose metadata failed this time is not falsely removed")
        let complete = GamePassCollections.merged([game], retaining: [otherGame, game], ids: [game.id])
        check(complete.map(\.id) == [game.id],
              "REQ-65: a member absent from a complete official list response leaves the shelf")
        check(Set(DiscoverGamePassShelf.allCases.map(\.title)).count == DiscoverGamePassShelf.allCases.count
              && !DiscoverGamePassShelf.allCases.contains { shelf in
                  ["price", "buy", "get ", "deal", "claim", "save", "store", "ultimate"].contains {
                      shelf.title.lowercased().contains($0)
                  }
              },
              "REQ-24/25/60: shelf titles carry no commerce, Store or invented tier wording")
    }

    private static func gamePassAvailabilityChecks(check: (Bool, String) -> Void) throws {
        func collection(_ json: String) throws -> OdeAccountCollection {
            let value = try JSONDecoder().decode(OdeAccountCollection.self, from: Data(json.utf8))
            try value.validate()
            return value
        }
        let items = #"[{"productID":"FIXTURE00031","acquisitionKind":"purchased"}]"#
        let legacy = try collection(#"{"items":\#(items)}"#)
        let current = try collection(#"{"items":\#(items),"activeSubscriptions":["CFQ7TTC0KHS0"]}"#)
        var rejected = 0
        for plans in [#"["cfq7ttc0khs0"]"#, #"["CFQ7TTC0KHS0","CFQ7TTC0KHS0"]"#,
                      "[" + (0..<33).map { #""PLAN\#(String(format: "%08d", $0))""# }.joined(separator: ",") + "]"] {
            do { _ = try collection(#"{"items":\#(items),"activeSubscriptions":\#(plans)}"#) } catch { rejected += 1 }
        }
        check(legacy.activeSubscriptions == nil && current.activeSubscriptions == ["CFQ7TTC0KHS0"] && rejected == 3,
              "REQ-7: Library reads accept optional activeSubscriptions and reject malformed, duplicate or excessive plan IDs")
        check(!PCGamesController(market: "GB").gamePassPlanActive,
              "REQ-7: no licence read means no active Game Pass plan")

        let brotato = try product("FIXTURE00032", pcCandidate: true)
        let purchased = try product("FIXTURE00033", pcCandidate: true)
        let outside = try product("FIXTURE00034", pcCandidate: true)
        func installed(_ id: String) -> InstalledGame {
            InstalledGame(id: UUID(), title: id, identityName: "Fixture.\(id)", version: "1.0.0.0", storeId: id,
                          folder: "/synthetic/\(id)", launcher: "", importedAt: Date(), usesNativeLifecycle: true)
        }
        let local = [installed(brotato.id), installed(purchased.id), installed(outside.id)]
        let held = [PCGame(id: purchased.id, title: purchased.id, artwork: nil, acquisitionKind: .purchased)]
        func rows(planActive: Bool) -> [LibraryGame] {
            LibraryGame.collection(installed: local, owned: held, products: [], gamePass: [brotato, purchased],
                                   active: planActive, accessIsCurrent: true, gamePassPlanActive: planActive)
        }
        let active = rows(planActive: true)
        let row = active.first { $0.id == brotato.id }
        check(row?.availableWithGamePass == true && row?.eligibility == .gamePass
              && row?.facts.badgeLabels() == [GameFacts.availableWithGamePassLabel]
              && row?.facts.heroAccessLabels() == [GameFacts.availableWithGamePassLabel]
              && LibraryGame.visible(active, query: "", filter: .gamePass, sort: .title).contains { $0.id == brotato.id }
              && !LibraryGame.visible(active, query: "", filter: .owned, sort: .title).contains { $0.id == brotato.id },
              "REQ-7/63: an installed Game Pass title that isn't a collection row is available with Game Pass, in the Game Pass filter, never Owned or missing")
        let owned = active.first { $0.id == purchased.id }
        check(owned?.availableWithGamePass == false
              && owned?.facts.badgeLabels() == ["Owned", "Game Pass"],
              "REQ-63: a purchased Game Pass title stays Owned plus Game Pass, not merely available")
        let denied = LibraryGame.collection(installed: local, owned: held, products: [], gamePass: [brotato, purchased],
            active: true, accessIsCurrent: true, gamePassPlanActive: true, deniedInstalledIDs: [brotato.id])
        check(!denied.contains { $0.id == brotato.id },
              "REQ-7: a settled per-title access denial for this account wins over the general Game Pass plan")
        check(!active.contains { $0.id == outside.id } && !rows(planActive: false).contains { $0.id == brotato.id },
              "REQ-7: without an active plan or public PC Game Pass membership, nothing is presented as Game Pass access")
        let noPlan = LibraryGame(id: brotato.id, title: brotato.id, installed: nil, pc: nil, product: brotato,
                                 owned: false, gamePass: true, accessIsCurrent: true)
        check(!noPlan.facts.badgeLabels().contains(GameFacts.availableWithGamePassLabel)
              && noPlan.facts.heroAccessLabels() == ["Ownership not confirmed", "In PC Game Pass catalog"],
              "REQ-63: catalogue membership alone never claims the account can play it")
    }

    private static func pendingSearchChecks(check: (Bool, String) -> Void) throws {
        let payload: [String: Any] = [
            "productID": "FIXTURE00041", "title": "Valor Mortis", "market": "US", "language": "en-US",
            "source": "MicrosoftDisplayCatalog:v7", "checkedAt": "2026-10-27T00:00:00Z",
            "freshness": "current", "editions": [], "pcCatalogCandidate": true,
            "artwork": [], "artworkStatus": "absent"
        ]
        let valor = try JSONDecoder().decode(CatalogProduct.self, from: JSONSerialization.data(withJSONObject: payload))
        let other = try product("FIXTURE00042", pcCandidate: true)
        let facts = [valor.id: LibraryCatalogFacts(genres: ["Action"], pcPackageListed: true, isBaseGame: true),
                     other.id: LibraryCatalogFacts(genres: ["Action"], pcPackageListed: true, isBaseGame: true)]
        func projection(query: String, products: [CatalogProduct], local: [CatalogProduct]) -> CatalogProjection {
            CatalogProjection(key: CatalogProjectionKey(accountHash: nil, query: query, owned: [], products: products,
                gamePass: [], gamePassIDs: [], installed: [], accessIsCurrent: false, metadataRevision: 0,
                compatibility: [:], genre: nil, showsUnsupported: true, local: local),
                facts: facts, isVisible: { _ in true })
        }
        let pending = projection(query: "mortis", products: [], local: [valor, other])
        check(pending.visible.map(\.id) == [valor.id] && pending.index.results.localIDs == [valor.id],
              "REQ-10/59: while the public query is pending, an installed or already-loaded Discover game matches \"mortis\" at once instead of Games (0)")
        let renamed = try JSONDecoder().decode(CatalogProduct.self, from: JSONSerialization.data(withJSONObject:
            payload.merging(["title": "Valor Mortis (local copy)"]) { _, new in new }))
        let settled = projection(query: "mortis", products: [valor], local: [renamed])
        check(settled.visible.map(\.id) == [valor.id] && settled.visible.first?.title == "Valor Mortis" && projection(query: "", products: [other], local: [valor])
                  .index.results.localIDs.isEmpty,
              "REQ-10/59: local matches merge with public results without duplicates and never alter empty-query browse")
    }
}
