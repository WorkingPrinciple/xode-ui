// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OdeManagement

@MainActor
final class HalloweenCatalog: ObservableObject {
    @Published private(set) var products: [CatalogProduct] = []
    @Published private(set) var facts: [String: LibraryCatalogFacts] = [:]
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var scope: String?
    private var completed = false
    private var generation = UUID()
    private let artwork: LibraryCatalogArtwork

    init(artwork: LibraryCatalogArtwork = .shared) {
        self.artwork = artwork
    }

    func load(scope nextScope: String?, market: String, language: String, refresh: Bool = false) async {
        if scope != nextScope {
            scope = nextScope
            generation = UUID()
            products = []
            facts = [:]
            error = nil
            loading = false
            completed = false
        }
        guard nextScope != nil, !Task.isCancelled, !loading, refresh || !completed else { return }
        let token = generation
        loading = true
        defer { if token == generation { loading = false } }
        await artwork.load(ids: HalloweenShelf.editorialIDs, market: market, language: language, refresh: refresh)
        guard !Task.isCancelled, token == generation else { return }
        products = HalloweenShelf.editorialIDs.compactMap { artwork.images[$0]?.product }
            .filter(\.pcCatalogCandidate)
        facts = Dictionary(uniqueKeysWithValues: products.compactMap { product in
            artwork.images[product.id].map { (product.id, $0.facts) }
        })
        error = artwork.error == nil ? nil : "Halloween games couldn't all be loaded. Try again."
        completed = error == nil
    }
}
