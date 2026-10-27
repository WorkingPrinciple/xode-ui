// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

struct CatalogSearchResults {
    let ownedMatches: [PCGame]
    let storeProducts: [CatalogProduct]
    /// REQ-10/59: title matches among games the app already holds (installed or loaded on Discover).
    /// They show at once and stay valid while a public query or a library refresh is still running.
    let localIDs: Set<String>
    private let ownedByID: [String: PCGame]
    private let gamePassProductIDs: Set<String>

    init(query: String, ownedGames: [PCGame], storeProducts: [CatalogProduct],
         gamePassProductIDs: Set<String>, gamePassProducts: [CatalogProduct] = [],
         localProducts: [CatalogProduct] = []) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var byID: [String: PCGame] = [:]
        for game in ownedGames where byID[game.id] == nil { byID[game.id] = game }
        ownedByID = byID
        var matchedIDs = Set<String>()
        ownedMatches = query.isEmpty ? [] : ownedGames.filter {
            $0.title.range(of: query, options: .caseInsensitive) != nil
                && matchedIDs.insert($0.id).inserted
        }
        var visibleIDs = matchedIDs
        let passMatches = query.isEmpty ? [] : gamePassProducts.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
        let localMatches = query.isEmpty ? [] : localProducts.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
        localIDs = Set(localMatches.map(\.id))
        // Live search and catalogue records win; local copies only fill in games they don't yet include.
        self.storeProducts = (storeProducts + passMatches + localMatches).filter { visibleIDs.insert($0.id).inserted }
        self.gamePassProductIDs = gamePassProductIDs
    }

    func ownedGame(for productID: String) -> PCGame? { ownedByID[productID] }

    func facts(for productID: String, accessIsCurrent: Bool = true) -> GameFacts {
        GameFacts(pc: ownedByID[productID], gamePass: gamePassProductIDs.contains(productID),
                  accessIsCurrent: accessIsCurrent)
    }
}
