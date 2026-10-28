// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OdeManagement

/// Discover shelves backed by Xbox's own public Game Pass lists (the official xbox.com Game Pass page maps
/// each collection to a catalog.gamepass.com list). Members keep the list's own order; no dates, prices or
/// rankings are invented. A shelf with no classified, visible games is absent rather than a placeholder.
enum DiscoverGamePassShelf: String, CaseIterable, Identifiable {
    case recentlyAdded = "XGPPMPRecentlyAdded"
    case mostPopular = "pcgaVTpopular"
    case leavingSoon = "SubsXGPLeavingSoon"
    case freeToPlay = "ftpbenefitspc"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: "Recently added to Game Pass"
        case .mostPopular: "Most popular on Game Pass"
        case .leavingSoon: "Leaving Game Pass soon"
        case .freeToPlay: "Free to play"
        }
    }

    static var keys: [String] { allCases.map(\.rawValue) }

    /// REQ-81: shelves wait until the first browse page has settled (loaded, failed or stopped) and its
    /// first-view metadata is no longer pending, so they never compete with the first useful content.
    static func mayStart(firstPageSettled: Bool, firstViewPending: Bool) -> Bool {
        firstPageSettled && !firstViewPending
    }

    /// Games a shelf may show: official members only, Microsoft-classified PC base games, in list order.
    static func products(_ collection: GamePassCollection?, facts: [String: LibraryCatalogFacts],
                         isVisible: (CatalogProduct) -> Bool) -> [CatalogProduct] {
        guard let collection, !collection.isUpcoming else { return [] }
        let listed = Set(collection.productIDs)
        var seen = Set<String>()
        return GameSurfaceFilter.games(collection.products, facts: facts).filter {
            (listed.isEmpty || listed.contains($0.id)) && seen.insert($0.id).inserted && isVisible($0)
        }
    }
}
