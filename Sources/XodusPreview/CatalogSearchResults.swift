// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

enum CatalogAccessBadge: String {
    case owned = "Owned", library = "In your library", subscription = "Subscription (plan unknown)", gamePass = "Game Pass"
}

enum CatalogGamePassListingCopy {
    static func description(for listing: CatalogGamePassListing) -> String {
        switch listing.status {
        case .unknown:
            return "Subscription listings unavailable; this is not an exclusion."
        case .known where listing.plans.isEmpty:
            return "No subscriptions listed in this partial Xbox result; absence is not exclusion."
        case .known:
            let names = listing.plans.map { $0.name ?? "Unlabelled subscription (\($0.id))" }
            return "Listed subscriptions (partial; account coverage unknown): \(names.joined(separator: ", "))."
        }
    }
}

struct CatalogSearchResults {
    let ownedMatches: [PCGame]
    let storeProducts: [CatalogProduct]
    private let ownedByID: [String: PCGame]
    private let gamePassProductIDs: Set<String>

    init(query: String, ownedGames: [PCGame], storeProducts: [CatalogProduct],
         gamePassProductIDs: Set<String>, gamePassProducts: [CatalogProduct] = []) {
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
        self.storeProducts = (storeProducts + passMatches).filter { visibleIDs.insert($0.id).inserted }
        self.gamePassProductIDs = gamePassProductIDs
    }

    func ownedGame(for productID: String) -> PCGame? { ownedByID[productID] }

    func badge(for productID: String) -> CatalogAccessBadge? {
        if let held = ownedByID[productID] {
            switch held.acquisitionKind {
            case .purchased: return .owned
            case .subscription: return .subscription
            case .unknown: return .library
            }
        }
        return gamePassProductIDs.contains(productID) ? .gamePass : nil
    }

    func sourceLabel(for productID: String) -> String {
        if ownedByID[productID] != nil { return "Your PC library" }
        return gamePassProductIDs.contains(productID) ? "PC Game Pass catalogue" : "Xbox / Microsoft Store"
    }
}
