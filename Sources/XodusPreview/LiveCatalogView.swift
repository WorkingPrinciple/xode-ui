// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

@MainActor
final class DiscoverSelection: ObservableObject {
    let projection = PresentationCache<CatalogProjectionKey, CatalogProjection>(empty: .empty)
    @Published var genre: String?
    @Published var featuredID: String?
    var scrollID: String?
    @Published var featuredVisible = false
    @Published var scope: GameSearchScope = .allGames
    @Published var focusRequest = 0
    @Published var recentSearches = UserDefaults.standard.stringArray(forKey: "Xodus.recentGameSearches") ?? []
    private(set) var previousResults = CatalogProjection.empty
    private var query: String?
    private var accountScope: String?

    func recordSearch(_ query: String) {
        recentSearches = GameSearchHistory.recording(query, in: recentSearches)
        UserDefaults.standard.set(recentSearches, forKey: "Xodus.recentGameSearches")
    }

    func clearHistory() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "Xodus.recentGameSearches")
    }

    func clear() {
        projection.clear(to: .empty)
        previousResults = .empty
        query = nil
        accountScope = nil
    }

    func prepare(_ key: CatalogProjectionKey, accountScope: String,
                 build: () -> CatalogProjection) {
        if self.accountScope != accountScope {
            projection.clear(to: .empty)
            previousResults = .empty
            self.accountScope = accountScope
        } else if query != key.query,
                  (!projection.current.visible.isEmpty || !projection.current.owned.isEmpty) {
            previousResults = projection.current
        }
        query = key.query
        projection.prepare(key, build: build)
    }
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
        String(localized: "No games match ‘\(query)’.")
    }
    static func noOtherGames(_ query: String) -> String {
        String(localized: "No other games match “\(query)”.")
    }
    static let emptyDescription = String(localized: "Try another title or clear your search.")

    static let partial = "Some results may be missing."
    static let unavailable = "Search isn't available right now."
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("Xodus.showUnsupportedGames") private var showsUnsupportedGames = false
    let query: String
    var allowsArtworkLoading = true
    var allowsStartupTasks = true
    var allowsHeroAnimation = true
    @Environment(\.catalogPresentationActive) private var presentationActive
    let clearSearch: () -> Void
    @ObservedObject var selection = DiscoverSelection()
    var searchLibrary: (String) -> Void = { _ in }
    var selectSearch: (String) -> Void = { _ in }
    var returnToSearch: () -> Void = {}
    @FocusState private var focusedResult: String?
    @State private var showsCoverage = false

    private var projection: CatalogProjection { selection.projection.current }
    private var results: CatalogSearchResults { projection.index.results }
    private var facts: [String: LibraryCatalogFacts] { projection.facts }
    private var genres: [String] { projection.genres }
    private var visible: [CatalogProduct] {
        projection.visible.filter { selection.scope.includes(game($0)) }
    }
    private var ownedMatches: [PCGame] {
        projection.owned.filter { selection.scope.includes(game($0)) }
    }
    private var hiddenUnsupportedCount: Int { projection.hiddenCount }
    private var canRefresh: Bool {
        allowsStartupTasks && session.isReady && (session.supports(.search)
            || (query.isEmpty ? session.supports(.discover) : session.supports(.query)))
    }
    private var pending: Bool {
        canRefresh && !query.isEmpty && (!session.catalogMatches(query: query) || session.searching)
            && session.catalogError == nil && !session.catalogStopped
    }
    private var searchUnavailable: Bool {
        session.catalogError != nil || (!query.isEmpty && !canRefresh && !session.searching)
    }
    private var partial: Bool {
        !session.discoveryFailures.isEmpty || projection.unresolvedClassificationCount > 0
            || session.gamePassCatalogError != nil
    }
    private var validEmptySearch: Bool {
        !query.isEmpty && session.catalogMatches(query: query) && !session.searching &&
            !session.catalogStopped && session.catalogError == nil && session.discoveryFailures.isEmpty &&
            (!allowsStartupTasks || (session.isReady && canRefresh))
    }
    private var columns: [GridItem] { LibraryGridLayout.columns }

    var body: some View {
        let key = CatalogProjectionKey(accountHash: session.accountHash, query: query, owned: library.representedGames,
            products: session.catalogMatches(query: query) ? session.products : [],
            gamePass: session.gamePassProducts, gamePassIDs: session.gamePassProductIDs,
            installed: installed.games, accessIsCurrent: library.accessIsCurrent,
            metadataRevision: art.revision, compatibility: operations.compatibility,
            genre: selection.genre, showsUnsupported: showsUnsupportedGames)
        selection.prepare(key, accountScope: "\(session.accountHash ?? ""):\(session.market):\(session.language)") {
            CatalogProjection(key: key, facts: art.images.mapValues(\.facts), isVisible: isVisible)
        }
        return content
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            if operations.hasDownloadStatus {
                GameOperationProgressView(operations: operations)
                    .padding(.horizontal, 56).padding(.top, 24)
                    .accessibilityIdentifier("xodus.catalog.installStatus")
            }
            if query.isEmpty, !visible.isEmpty { featuredCarousel }
            VStack(alignment: .leading, spacing: 28) {
                if query.isEmpty {
                    if !selection.recentSearches.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Recent searches").font(.headline)
                                Spacer()
                                Button("Clear recent searches") { selection.clearHistory() }
                            }
                            ForEach(selection.recentSearches.prefix(8), id: \.self) { recent in
                                Button(recent, systemImage: "clock") { selectSearch(recent) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if !genres.isEmpty { browseGenres }
                } else {
                    Text("Results for \"\(query)\"").font(.largeTitle.bold())
                    Picker("Search scope", selection: $selection.scope) {
                        ForEach(GameSearchScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    if !ownedMatches.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("In your library (\(ownedMatches.count))").font(.title2.weight(.semibold))
                            VStack(spacing: 0) {
                                ForEach(ownedMatches.prefix(5)) { owned in
                                    libraryRow(game(owned))
                                    Divider()
                                }
                            }
                            if ownedMatches.count > 5 {
                                Button("Show all \(ownedMatches.count) in Library") { searchLibrary(query) }
                            }
                        }
                    } else if pending, !selection.previousResults.owned.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Previous library results · Updating…").font(.headline)
                            ForEach(selection.previousResults.owned.prefix(5)) { owned in
                                if let game = selection.previousResults.index.games[owned.id],
                                   selection.scope.includes(game) {
                                    libraryRow(game)
                                }
                            }
                        }
                        .opacity(0.45).allowsHitTesting(false).disabled(true).accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Games (\(visible.count))").font(.title2.weight(.semibold))
                        Spacer()
                        LibrarySupportMenu(hiddenCount: hiddenUnsupportedCount,
                                           showsUnsupportedGames: $showsUnsupportedGames)
                        if pending || session.searching {
                            ProgressView().controlSize(.small).accessibilityLabel("Searching for games")
                            Button("Stop search") { session.stopCatalogSearch() }
                                .accessibilityIdentifier("xodus.catalog.stop")
                        }
                    }
                    if searchUnavailable {
                        HStack {
                            Label(DiscoverCopy.unavailable, systemImage: "exclamationmark.circle")
                            Button("Retry") { retry() }.disabled(!canRefresh)
                        }.foregroundStyle(.secondary)
                    } else if session.catalogStopped {
                        HStack {
                            Text("Search stopped.")
                            Button("Retry") { retry() }.disabled(!canRefresh)
                        }
                    } else if partial {
                        HStack {
                            Text(DiscoverCopy.partial)
                            Button("Retry") { retry() }.disabled(!canRefresh)
                        }
                    }
                    if !visible.isEmpty {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(visible) { product in
                                card(game(product)).id("discover-card-\(product.id)")
                                    .focusable().focused($focusedResult, equals: product.id)
                                    .onKeyPress(.return) { open(game(product)); return .handled }
                            }
                        }
                        .scrollTargetLayout()
                    } else if pending {
                        let previous = selection.previousResults.visible.filter {
                            selection.previousResults.index.games[$0.id].map(selection.scope.includes) == true
                        }
                        if !previous.isEmpty {
                            Text("Previous results · Updating…").font(.callout).foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 28) {
                                ForEach(previous) { product in
                                    if let game = selection.previousResults.index.games[product.id] {
                                        card(game)
                                    }
                                }
                            }.opacity(0.45).allowsHitTesting(false).disabled(true).accessibilityHidden(true)
                        }
                    } else if ownedMatches.isEmpty {
                        if !searchUnavailable && !partial {
                            unavailable
                        }
                    } else if !session.searching && session.catalogError == nil {
                        Text(DiscoverCopy.noOtherGames(query)).foregroundStyle(.secondary)
                    }
                    if session.nextCursor != nil, session.catalogMatches(query: query) {
                        if session.catalogAtLimit {
                            Text("The catalogue reached this build's limit. Some games remain unloaded.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("xodus.catalog.limit")
                        } else {
                            Button("More games") { Task { await session.refreshCatalog(query, more: true) } }
                                .disabled(!canRefresh || !session.canLoadMoreCatalog)
                                .accessibilityLabel("Load more catalog results")
                                .accessibilityIdentifier("xodus.catalog.loadMore")
                        }
                    }
                }
                catalogInfo
            }
            .padding(.horizontal, 56).padding(.bottom, 32)
            .padding(.top, query.isEmpty && !visible.isEmpty ? 0 : 86)
        }
        .onChange(of: query) { _, value in
            selection.genre = nil
            if value.isEmpty { selection.scope = .allGames }
        }
        .onChange(of: selection.focusRequest) { _, _ in
            selection.recordSearch(query)
            focusedResult = ownedMatches.first?.id ?? visible.first?.id
            if focusedResult == nil { returnToSearch() }
        }
        .onExitCommand {
            focusedResult = nil
            returnToSearch()
        }
        .task(id: CatalogArtworkLoadKey(market: session.market, language: session.language,
                                       ids: presentationActive ? projection.artworkIDs : [])) {
            guard allowsArtworkLoading, presentationActive else { return }
            await art.load(ids: results.storeProducts.map(\.id) + (library.snapshot?.games.map(\.id) ?? []),
                           market: session.market, language: session.language)
        }
    }

    private func retry() {
        Task { await session.refreshCatalog(query) }
    }

    private func libraryRow(_ game: LibraryGame) -> some View {
        HStack(spacing: 14) {
            Button { open(game) } label: {
                HStack(spacing: 14) {
                    CatalogArtworkView(reference: allowsArtworkLoading ? art.images[game.id]?.cover ?? game.cover : nil,
                                       status: .available)
                        .frame(width: 48, height: 48).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.title).font(.headline)
                        AccessBadges(facts: game.facts)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("View \(game.title)")
            .accessibilityValue(game.facts.badgeLabels().joined(separator: ", "))
            .focusable()
            .focused($focusedResult, equals: game.id)
            .onKeyPress(.return) { open(game); return .handled }
            Text(game.installed == nil ? "Not installed" : "Installed")
                .font(.callout).foregroundStyle(.secondary)
            if !unsupportedIssues(game).isEmpty {
                Button("View details") { open(game) }
                    .help("Open compatibility details")
            } else {
                actions(game, primary: false)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private func game(_ product: CatalogProduct) -> LibraryGame {
        projection.index.games[product.id] ?? LibraryGame(id: product.id, title: product.title,
            installed: installed.games.first { $0.storeId == product.id },
            pc: results.ownedGame(for: product.id), product: product,
            owned: results.ownedGame(for: product.id).map { $0.acquisitionKind == .purchased } ?? false,
            gamePass: session.gamePassProductIDs.contains(product.id), accessIsCurrent: library.accessIsCurrent)
    }

    private func game(_ owned: PCGame) -> LibraryGame {
        projection.index.games[owned.id] ?? LibraryGame(id: owned.id, title: owned.title,
            installed: installed.games.first { $0.storeId == owned.id }, pc: owned,
            product: session.products.first { $0.id == owned.id }, owned: owned.acquisitionKind == .purchased,
            gamePass: session.gamePassProductIDs.contains(owned.id), accessIsCurrent: library.accessIsCurrent)
    }

    private func open(_ game: LibraryGame) {
        if !query.isEmpty, allowsStartupTasks { selection.recordSearch(query) }
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
                LibraryGameInformation(gameFacts: game.facts,
                                       facts: facts[game.id])
                if game.installed != nil { Label("Installed", systemImage: "internaldrive").font(.caption) }
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
                    if let product = projection.genreProducts[genre] {
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
        return GameCard(title: game.title, gameFacts: game.facts, openLabel: "View",
                            alwaysShowsActions: true, open: { open(game) }) {
            CatalogArtworkView(reference: allowsArtworkLoading ? cover : nil,
                               status: cover == nil ? .absent : .available)
        } status: {
            if !unsupportedIssues(game).isEmpty {
                LibraryCompatibilityIndicators(issues: unsupportedIssues(game))
            }
            if game.installed != nil { Label("Installed", systemImage: "internaldrive").font(.caption) }
            if let match = game.installed { InstalledPlayError(library: installed, game: match) }
        } actions: {
            VStack(alignment: .leading, spacing: 8) {
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
                 ? "Some games have known package or anti-cheat blockers. Show unsupported games to see each reason."
                 : validEmptySearch ? DiscoverCopy.emptyDescription
                 : selection.genre != nil && query.isEmpty ? "Choose another genre from the loaded selection."
                 : session.catalogMessage(query: query, canRefresh: canRefresh))
        } actions: {
            if hiddenUnsupportedCount > 0 { Button("Show unsupported games") { showsUnsupportedGames = true } }
            if selection.genre != nil { Button("All genres") { selection.genre = nil } }
            if !session.isReady, allowsStartupTasks { Button("Settings", action: openSettings.callAsFunction) }
            if !query.isEmpty {
                Button("Search Library") { searchLibrary(query) }
                Button("Clear Search", action: clearSearch)
            }
        }.frame(maxWidth: .infinity, minHeight: 220)
    }

    private var catalogInfo: some View {
        Button("Game Pass catalogue coverage", systemImage: "info.circle") { showsCoverage = true }
        .buttonStyle(.plain).font(.callout).foregroundStyle(.primary)
        .popover(isPresented: $showsCoverage) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Catalogue coverage").font(.headline)
                switch session.catalogCorpus {
                case "pcGamePassDiscovery":
                    Text("Xbox PC Game Pass catalogue.")
                case "publicMicrosoftStoreSearch":
                    Text("Xbox and Microsoft Store search, plus loaded PC Game Pass games.")
                default:
                    Text("Previously loaded public game details.")
                }
                Text(session.discoveryCheckedAt.map { "Last refreshed: \($0)" } ?? "Refresh time unavailable.")
                Text("Membership badges have partial coverage. A missing badge doesn't mean a game isn't included.")
                Text("A catalogue listing doesn't verify your account's access. Mac compatibility varies by game.")
            }
            .font(.callout).textSelection(.enabled).padding(20).frame(width: 340)
        }
    }
}
