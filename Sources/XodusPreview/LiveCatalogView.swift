// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

@MainActor
final class DiscoverSelection: ObservableObject {
    @Published var genre: String?
    @Published var featuredID: String?
    @Published var featuredVisible = false
}

enum DiscoverBrowse {
    static func genres(products: [CatalogProduct], facts: [String: LibraryCatalogFacts]) -> [String] {
        Set(products.flatMap { facts[$0.id]?.genres ?? [] }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    static func visible(products: [CatalogProduct], facts: [String: LibraryCatalogFacts],
                        genre: String?) -> [CatalogProduct] {
        guard let genre else { return products }
        return products.filter { facts[$0.id]?.genres.contains(genre) == true }
    }

    static func canReviewInstall(owned: Bool, accessIsCurrent: Bool, gamePass: Bool,
                                 subscriptionActive: Bool, pcCandidate: Bool) -> Bool {
        guard pcCandidate else { return false }
        if owned && accessIsCurrent { return true }
        return gamePass && subscriptionActive
    }
}

enum DiscoverCopy {
    static func noResults(_ query: String) -> String {
        String(localized: "No Results for “\(query)”")
    }
    static func noOtherGames(_ query: String) -> String {
        String(localized: "No other games match “\(query)”.")
    }
    static let emptyDescription = String(localized: "Try another title or clear your search.")
}

#if !XODUS_SHIPPING
struct CatalogReviewSnapshot: Decodable {
    let products: [CatalogProduct]

    func pcProducts(market: String, language: String) throws -> [CatalogProduct] {
        guard !products.isEmpty, products.count <= 64,
              Set(products.map(\.id)).count == products.count,
              products.allSatisfy({ PCGamesClient.validProductID($0.id) && !$0.title.isEmpty &&
                  $0.title.utf8.count <= 512 }) else { throw ManagementError.invalidPayload }
        let pc = products.filter(\.pcCatalogCandidate)
        guard !pc.isEmpty else { throw ManagementError.invalidPayload }
        for product in pc { try product.validatePublicScope(market: market, language: language) }
        return pc
    }
}
#endif

struct LiveCatalogView: View {
    @ObservedObject var library: PCGamesController
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    @EnvironmentObject private var session: LiveSession
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var art = LibraryCatalogArtwork.shared
    @StateObject private var selection = DiscoverSelection()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("Xodus.showUnsupportedGames") private var showsUnsupportedGames = false
    let query: String
    var allowsArtworkLoading = true
    var allowsStartupTasks = true
    var allowsHeroAnimation = true
    let clearSearch: () -> Void

    private var results: CatalogSearchResults {
        CatalogSearchResults(query: query, ownedGames: library.representedGames,
            storeProducts: session.catalogMatches(query: query) ? session.products : [],
            gamePassProductIDs: session.gamePassProductIDs)
    }
    private var facts: [String: LibraryCatalogFacts] { art.images.mapValues(\.facts) }
    private var genres: [String] { DiscoverBrowse.genres(products: results.storeProducts, facts: facts) }
    private var visibleCandidates: [CatalogProduct] {
        DiscoverBrowse.visible(products: results.storeProducts, facts: facts, genre: query.isEmpty ? selection.genre : nil)
    }
    private var visible: [CatalogProduct] { visibleCandidates.filter { isVisible(game($0)) } }
    private var ownedMatches: [PCGame] { results.ownedMatches.filter { isVisible(game($0)) } }
    private var hiddenUnsupportedCount: Int {
        visibleCandidates.count - visible.count + results.ownedMatches.count - ownedMatches.count
    }
    private var canRefresh: Bool {
        allowsStartupTasks && session.isReady && (session.supports(.search)
            || (query.isEmpty ? session.supports(.discover) : session.supports(.query)))
    }
    private var storeHeading: String {
        if !query.isEmpty { return "More games" }
        return session.catalogCorpus == "pcGamePassDiscovery" ? "PC Game Pass catalog" : "Explore games"
    }
    private var validEmptySearch: Bool {
        !query.isEmpty && session.catalogMatches(query: query) && !session.searching &&
            !session.catalogStopped && session.catalogError == nil && session.discoveryFailures.isEmpty &&
            (!allowsStartupTasks || (session.isReady && canRefresh))
    }
    private var columns: [GridItem] { LibraryGridLayout.columns }

    var body: some View {
        let results = self.results
        VStack(alignment: .leading, spacing: 28) {
            if operations.hasDownloadStatus {
                GameOperationProgressView(operations: operations)
                    .padding(.horizontal, 56).padding(.top, 24)
                    .accessibilityIdentifier("xodus.catalog.installStatus")
            }
            if query.isEmpty, !visible.isEmpty { featuredCarousel }
            VStack(alignment: .leading, spacing: 28) {
                if query.isEmpty {
                    if !genres.isEmpty { browseGenres }
                } else {
                    Text("Results for \"\(query)\"").font(.largeTitle.bold())
                    if !ownedMatches.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Your games").font(.title2.weight(.semibold))
                            if library.error != nil || library.busy {
                                Text("Showing your last complete PC library.").font(.callout).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: columns, spacing: 28) {
                                ForEach(ownedMatches) { card(game($0)) }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(storeHeading).font(.title2.weight(.semibold))
                        Spacer()
                        LibrarySupportMenu(hiddenCount: hiddenUnsupportedCount,
                                           showsUnsupportedGames: $showsUnsupportedGames)
                        if session.searching {
                            ProgressView().controlSize(.small).accessibilityLabel("Searching for games")
                            Button("Stop search") { session.stopCatalogSearch() }
                                .accessibilityIdentifier("xodus.catalog.stop")
                        }
                    }
                    if !query.isEmpty, library.snapshot == nil {
                        Text("Load your PC library in Library to include your games in search.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let notice = session.catalogNotice {
                        Label(notice, systemImage: session.catalogStopped ? "pause.circle" : "exclamationmark.circle")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !visible.isEmpty {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(visible) { card(game($0)) }
                        }
                    } else if ownedMatches.isEmpty {
                        unavailable
                    } else if !session.searching && session.catalogError == nil {
                        Text(DiscoverCopy.noOtherGames(query)).foregroundStyle(.secondary)
                    }
                    if session.nextCursor != nil, session.catalogMatches(query: query) {
                        Button("More games") { Task { await session.refreshCatalog(query, more: true) } }
                            .disabled(!canRefresh || !session.canLoadMoreCatalog)
                            .accessibilityLabel("Load more catalog results")
                            .accessibilityIdentifier("xodus.catalog.loadMore")
                    }
                }
                catalogInfo
            }
            .padding(.horizontal, 56).padding(.bottom, 32)
            .padding(.top, query.isEmpty && !visible.isEmpty ? 0 : 86)
        }
        .onChange(of: query) { _, _ in selection.genre = nil }
        .task(id: "\(session.market):\(session.language):\(session.products.map(\.id).joined(separator: ",")):\(library.snapshot?.games.map(\.id).joined(separator: ",") ?? "")") {
            guard allowsArtworkLoading else { return }
            await art.load(ids: session.products.map(\.id) + (library.snapshot?.games.map(\.id) ?? []),
                           market: session.market, language: session.language)
        }
    }

    private func game(_ product: CatalogProduct) -> LibraryGame {
        LibraryGame(id: product.id, title: product.title,
            installed: installed.games.first { $0.storeId == product.id },
            pc: results.ownedGame(for: product.id), product: product,
            owned: results.ownedGame(for: product.id).map { $0.acquisitionKind != .subscription } ?? false,
            gamePass: session.gamePassProductIDs.contains(product.id),
            accessIsCurrent: library.accessIsCurrent)
    }

    private func game(_ owned: PCGame) -> LibraryGame {
        LibraryGame(id: owned.id, title: owned.title,
            installed: installed.games.first { $0.storeId == owned.id }, pc: owned,
            product: session.products.first { $0.id == owned.id },
            owned: owned.acquisitionKind != .subscription,
            gamePass: session.gamePassProductIDs.contains(owned.id),
            accessIsCurrent: library.accessIsCurrent)
    }

    private func open(_ game: LibraryGame) {
        do {
            session.selectedProduct = try game.product ?? art.images[game.id]?.product ??
                LibraryGame.details(id: game.id, title: game.title,
                    market: session.market, language: session.language,
                    source: "AccountPCLibrary:identityOnly", pcCandidate: false)
        } catch { session.errorMessage = "Game details couldn't be opened. Your games haven't changed." }
    }

    private func landscape(_ game: LibraryGame) -> [CatalogArtworkReference] {
        art.images[game.id]?.landscape ??
            (game.product?.artwork.filter { $0.role == .hero } ?? [])
            + (game.cover.map { [$0] } ?? [])
    }

    private func canReviewInstall(_ game: LibraryGame) -> Bool {
        DiscoverBrowse.canReviewInstall(owned: game.pc != nil, accessIsCurrent: library.accessIsCurrent,
            gamePass: game.gamePass, subscriptionActive: operations.gamePassActive,
            pcCandidate: game.pc != nil || game.product?.pcCatalogCandidate == true)
    }

    private var featuredGames: [CatalogProduct] { Array(visible.prefix(5)) }

    private var featuredCarousel: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(featuredGames) { product in
                            hero(game(product), selected: selection.featuredID == product.id)
                                .frame(width: geometry.size.width).id(product.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.never).scrollTargetBehavior(HeroPageSnap())
                .scrollPosition(id: $selection.featuredID, anchor: .leading)
                if featuredGames.count > 1 {
                    HStack(spacing: 10) {
                        ForEach(featuredGames) { product in
                            Button {
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                                    selection.featuredID = product.id
                                }
                            } label: {
                                Circle().fill(selection.featuredID == product.id ? Color.primary : Color.secondary.opacity(0.55))
                                    .frame(width: 7, height: 7)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show \(product.title)")
                            .accessibilityAddTraits(selection.featuredID == product.id ? .isSelected : [])
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(height: 340)
        .modifier(HeroScrollVisibility { selection.featuredVisible = $0 })
        .onDisappear { selection.featuredVisible = false }
        .onChange(of: featuredGames.map(\.id), initial: true) { _, ids in
            if selection.featuredID.map({ !ids.contains($0) }) ?? true { selection.featuredID = ids.first }
        }
    }

    private func hero(_ game: LibraryGame, selected: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            LibraryHeroMedia(trailer: art.images[game.id]?.detail?.trailers.first,
                             allowsPlayback: allowsStartupTasks && allowsHeroAnimation
                                 && selection.featuredVisible && selected) {
                LibraryLandscapeView(references: landscape(game), installed: game.installed,
                                     allowsLoading: allowsArtworkLoading)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 210)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 14) {
                LibraryLogoTitle(title: game.title, references: art.images[game.id]?.logos ?? [],
                                 allowsLoading: allowsArtworkLoading)
                LibraryGameInformation(access: LibraryAccess(game), gamePass: game.gamePass,
                                       facts: facts[game.id])
                if game.installed != nil { Label("Installed", systemImage: "internaldrive").font(.caption) }
                LibraryGameSizeView(installed: game.installed, downloadBytes: facts[game.id]?.downloadBytes,
                                    productID: game.id,
                                    pcPackageListed: LibraryPCPackageEvidence.listed(
                                        observed: facts[game.id]?.pcPackageListed, candidate: game.product?.pcCatalogCandidate),
                                    packageFormat: facts[game.id]?.packageFormat,
                                    allowsMeasurement: allowsArtworkLoading)
                LibraryGlassCluster {
                    actions(game, primary: true)
                    Button("View game") { open(game) }
                        .modifier(LibraryActionStyle(primary: game.installed == nil && !canReviewInstall(game)))
                }.controlSize(.large)
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 56).padding(.bottom, 28)
            .foregroundStyle(.white)
        }
        .frame(height: 340).clipped().modifier(LibraryBackgroundExtension())
        .accessibilityElement(children: .contain)
    }

    private var browseGenres: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Browse genres").font(.title2.weight(.semibold))
                Spacer()
                Menu(selection.genre ?? "All genres") {
                    Button("All genres") { selection.genre = nil }
                    ForEach(genres, id: \.self) { genre in Button(genre) { selection.genre = genre } }
                }.fixedSize().accessibilityLabel("Filter the shown games by genre")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 24)], spacing: 16) {
                ForEach(Array(genres.prefix(4)), id: \.self) { genre in
                    if let product = results.storeProducts.first(where: { facts[$0.id]?.genres.contains(genre) == true }) {
                        Button { selection.genre = selection.genre == genre ? nil : genre } label: {
                            ZStack(alignment: .bottomLeading) {
                                LibraryLandscapeView(references: landscape(game(product)), installed: nil,
                                                     allowsLoading: allowsArtworkLoading)
                                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)],
                                               startPoint: .top, endPoint: .bottom)
                                Text(genre).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                                    .lineLimit(2).padding(16)
                            }
                            .frame(height: 140).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.tint, lineWidth: selection.genre == genre ? 2 : 0)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(genre) games in this selection")
                        .accessibilityAddTraits(selection.genre == genre ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func card(_ game: LibraryGame) -> some View {
        let cover = art.images[game.id]?.cover ?? game.cover
        return LibraryCover(title: game.title, openLabel: "View",
                            alwaysShowsActions: true, open: { open(game) }) {
            CatalogArtworkView(reference: allowsArtworkLoading ? cover : nil,
                               status: cover == nil ? .absent : .available)
        } status: {
            if !unsupportedIssues(game).isEmpty {
                LibraryCompatibilityIndicators(issues: unsupportedIssues(game))
            }
            LibraryGameInformation(access: LibraryAccess(game), gamePass: game.gamePass,
                                   facts: facts[game.id], compact: true)
            if game.installed != nil { Label("Installed", systemImage: "internaldrive").font(.caption) }
            LibraryGameSizeView(installed: game.installed, downloadBytes: facts[game.id]?.downloadBytes,
                                productID: game.id,
                                pcPackageListed: LibraryPCPackageEvidence.listed(
                                    observed: facts[game.id]?.pcPackageListed, candidate: game.product?.pcCatalogCandidate),
                                packageFormat: facts[game.id]?.packageFormat,
                                allowsMeasurement: allowsArtworkLoading)
            if let match = game.installed { InstalledPlayError(library: installed, game: match) }
            if game.product?.freshness == "cached" { Text("Offline details").font(.caption) }
        } actions: {
            LibraryGlassCluster {
                actions(game, primary: false)
                if let match = game.installed {
                    InstalledGameActions(library: installed, operations: operations, game: match, usesGlass: true)
                } else {
                    Button("View game", systemImage: "ellipsis") { open(game) }
                        .modifier(LibraryActionStyle(primary: false)).labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                }
            }
        }
    }

    private func unsupportedIssues(_ game: LibraryGame) -> [LibraryCompatibilityIssue] {
        operations.supportIssues(productID: game.id,
            packageFormat: game.installed?.packageType?.label ?? facts[game.id]?.packageFormat)
    }

    private func isVisible(_ game: LibraryGame) -> Bool {
        showsUnsupportedGames || unsupportedIssues(game).isEmpty
    }

    @ViewBuilder private func actions(_ game: LibraryGame, primary: Bool) -> some View {
        if !unsupportedIssues(game).isEmpty {
            if primary { LibraryCompatibilityIndicators(issues: unsupportedIssues(game), heroStyle: true) }
        } else if let match = game.installed {
            InstalledPlayButton(library: installed, operations: operations, game: match,
                                usesGlass: true, prominent: primary)
        } else if let pc = game.pc ?? game.product.map(PCGame.init(product:)) {
            GameInstallAction(game: pc, operations: operations,
                              enabled: allowsStartupTasks && canReviewInstall(game), primary: primary)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label(hiddenUnsupportedCount > 0 ? "No games verified yet"
                  : validEmptySearch ? DiscoverCopy.noResults(query)
                  : selection.genre != nil && query.isEmpty ? "No games in this genre" : session.catalogEmptyTitle,
                  systemImage: "magnifyingglass")
        } description: {
            Text(hiddenUnsupportedCount > 0
                 ? "Ode to X 0.1 supports MSIXVC games classified without anti-cheat. Show unsupported games to see each reason."
                 : validEmptySearch ? DiscoverCopy.emptyDescription
                 : selection.genre != nil && query.isEmpty ? "Choose another genre from the loaded selection."
                 : session.catalogMessage(query: query, canRefresh: canRefresh))
        } actions: {
            if hiddenUnsupportedCount > 0 { Button("Show unsupported games") { showsUnsupportedGames = true } }
            if selection.genre != nil { Button("All genres") { selection.genre = nil } }
            if !session.isReady, allowsStartupTasks { Button("Settings", action: openSettings.callAsFunction) }
            if !query.isEmpty { Button("Clear Search", action: clearSearch) }
        }.frame(maxWidth: .infinity, minHeight: 220)
    }

    private var catalogInfo: some View {
        DisclosureGroup("About these games") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Owned games come from your PC library. Game Pass games require an active subscription.")
                Text("Genres filter the games currently shown. Search coverage is partial; Mac compatibility varies by game.")
                if !allowsStartupTasks { Text("Read-only preview. Search uses the loaded games; installation and gameplay are disabled.") }
                if let error = session.catalogError { Text(error) }
                if !session.discoveryFailures.isEmpty {
                    Text("Some games couldn't be loaded. Refresh to try again.")
                }
            }
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 12)
        }
    }
}
