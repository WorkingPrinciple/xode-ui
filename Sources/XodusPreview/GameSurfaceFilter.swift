// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

/// Admits only products Microsoft classifies as a base game with a Windows Desktop package.
/// Missing or conflicting catalog metadata stays unresolved; it is never guessed from title or ownership.
enum GameSurfaceFilter {
    enum Classification: Equatable {
        case game
        case notGame
        case unresolved
    }

    struct Counts: Equatable {
        let games: Int
        let excluded: Int
        let unresolved: Int
        var total: Int { games + excluded + unresolved }
    }

    static func classification(_ facts: LibraryCatalogFacts?, pcCandidate: Bool? = nil) -> Classification {
        guard let facts else { return .unresolved }
        let listed = LibraryPCPackageEvidence.listed(observed: facts.pcPackageListed, candidate: pcCandidate)
        if facts.isBaseGame == false || listed == false { return .notGame }
        guard facts.isBaseGame == true, listed == true else { return .unresolved }
        return .game
    }

    static func classification(_ product: CatalogProduct, facts: [String: LibraryCatalogFacts]) -> Classification {
        classification(facts[product.id], pcCandidate: product.pcCatalogCandidate)
    }

    static func games(_ products: [CatalogProduct], facts: [String: LibraryCatalogFacts]) -> [CatalogProduct] {
        products.filter { classification($0, facts: facts) == .game }
    }

    static func counts(_ products: [CatalogProduct], facts: [String: LibraryCatalogFacts]) -> Counts {
        var games = 0, excluded = 0, unresolved = 0
        for product in products {
            switch classification(product, facts: facts) {
            case .game: games += 1
            case .notGame: excluded += 1
            case .unresolved: unresolved += 1
            }
        }
        return Counts(games: games, excluded: excluded, unresolved: unresolved)
    }
}
