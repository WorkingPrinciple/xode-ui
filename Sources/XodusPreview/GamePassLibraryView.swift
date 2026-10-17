// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

struct GamePassLibraryView: View {
    @ObservedObject var library: PCGamesController
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    @EnvironmentObject private var session: LiveSession
    let query: String
    var allowsStartupTasks = true

    private var visibleProducts: [CatalogProduct] {
        session.gamePassProducts.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        Group {
            if operations.gamePassActive {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Game Pass").font(.title.bold())
                        Spacer()
                        Button("Refresh") { Task { await session.refreshCatalog("") } }
                            .disabled(session.searching || !session.isReady || !session.supports(.discover))
                            .accessibilityLabel("Refresh Game Pass games")
                    }
                    if session.gamePassProducts.isEmpty {
                        if session.searching { ProgressView("Loading Game Pass games").controlSize(.small) }
                        else {
                            Text(session.catalogError ?? "Connect Xodus and refresh to load Game Pass games.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } else if visibleProducts.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        LazyVGrid(columns: LibraryGridLayout.columns, spacing: 28) {
                            ForEach(visibleProducts) { product in
                                PCGameTile(game: PCGame(product: product), installed: installed, operations: operations,
                                           allowsArtworkLoading: allowsStartupTasks,
                                           badge: library.snapshot?.games.contains(where: { $0.id == product.id }) == true
                                                ? .owned : .gamePass,
                                           viewDetails: { session.selectedProduct = product })
                            }
                        }
                        if session.catalogCorpus == "pcGamePassDiscovery", let notice = session.catalogNotice {
                            Label(notice, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: "\(operations.gamePassActive):\(session.isReady):\(session.market):\(session.language)") {
            guard allowsStartupTasks, operations.gamePassActive, session.isReady,
                  session.supports(.discover), session.gamePassProducts.isEmpty, !session.searching else { return }
            await session.refreshCatalog("")
        }
    }
}
