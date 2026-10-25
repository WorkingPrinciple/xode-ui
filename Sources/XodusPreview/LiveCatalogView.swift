// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

@MainActor
final class DiscoverSelection: ObservableObject {
    let projection = PresentationCache<CatalogProjectionKey, CatalogProjection>(empty: .empty)
    @Published var genre: String?
    @Published var browseLimit = 16
    @Published var featuredID: String?
    var scrollID: String?
    @Published var featuredVisible = false
    @Published var scope: GameSearchScope = .allGames
    @Published var focusRequest = 0
    @Published private(set) var pagingSearch = false
    @Published private(set) var pagingNotice: String?
    private var pagingScope: String?
    private var pagingCursor: String?
    private var pagingHasMore = false
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
        resetPaging()
        browseLimit = 16
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

    func resetPaging() {
        pagingNotice = nil
        pagingScope = nil
        pagingCursor = nil
        pagingHasMore = false
    }

    private func searchScope(_ session: LiveSession, query: String) -> String {
        "\(session.accountHash ?? ""):\(session.market):\(session.language):\(query):\(scope.rawValue)"
    }

    func continuationNotice(session: LiveSession, query: String) -> String? {
        pagingScope == searchScope(session, query: query) && pagingCursor == session.nextCursor ? pagingNotice : nil
    }

    func canSearchFurther(session: LiveSession, query: String) -> Bool {
        pagingHasMore && session.nextCursor != nil && continuationNotice(session: session, query: query) != nil
    }

    func loadMoreSearch(session: LiveSession, query: String,
                        visibleIDs: () async -> Set<String>?) async {
        guard !pagingSearch, session.canLoadMoreCatalog else { return }
        pagingSearch = true
        defer { pagingSearch = false }
        let scope = searchScope(session, query: query)
        let initialVersion = session.catalogRequestVersion
        let original = await visibleIDs() ?? []
        guard !Task.isCancelled, session.catalogRequestVersion == initialVersion,
              scope == searchScope(session, query: query),
              session.catalogMatches(query: query) else { return }
        resetPaging()
        for page in 0..<4 {
            let version = session.catalogRequestVersion
            await session.refreshCatalog(query, more: true)
            guard !Task.isCancelled, session.catalogRequestVersion == version + 1,
                  scope == searchScope(session, query: query), session.catalogMatches(query: query),
                  !session.catalogStopped, session.catalogError == nil else { return }
            let current = await visibleIDs() ?? []
            guard !Task.isCancelled, session.catalogRequestVersion == version + 1,
                  scope == searchScope(session, query: query) else { return }
            if !current.subtracting(original).isEmpty { return }
            if session.nextCursor == nil || page == 3 || session.catalogAtLimit {
                pagingScope = scope
                pagingCursor = session.nextCursor
                pagingHasMore = session.nextCursor != nil && !session.catalogAtLimit
                if session.nextCursor == nil {
                    pagingNotice = "No more games in this search scope."
                } else if session.catalogAtLimit {
                    pagingNotice = "The catalogue reached this build's limit. Some games remain unloaded."
                } else {
                    pagingNotice = "No additional games found in the next four result pages."
                }
                return
            }
        }
    }
}

enum DiscoverBrowse {
    static let pageSize = 16
    static func admittedIDs(_ products: [CatalogProduct], limit: Int) -> [String] {
        Array(products.prefix(max(0, min(limit, 512))).map(\.id))
    }

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

    static func genreShelves(products: [CatalogProduct], facts: [String: LibraryCatalogFacts],
                             genres: [String], shelfLimit: Int = 3, productLimit: Int = 12)
        -> [String: [CatalogProduct]] {
        let selectedGenres = genres.prefix(max(0, min(shelfLimit, 3)))
        let boundedProductLimit = max(0, min(productLimit, 12))
        var shelves: [String: [CatalogProduct]] = [:]
        for genre in selectedGenres where shelves[genre] == nil {
            shelves[genre] = Array(products.lazy.filter {
                facts[$0.id]?.genres.contains(genre) == true
            }.prefix(boundedProductLimit))
        }
        return shelves
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

    static let partial = "Some games couldn't be loaded."
    static let unavailable = "Search isn't available right now."
}

struct SearchResultPlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.tertiary)
                }
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                .frame(height: 14).padding(.trailing, 32)
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                .frame(width: 80, height: 10)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum DiscoverLayout {
    /// Clears the transparent toolbar, traffic lights and account button when no hero sits under them.
    static let toolbarClearance: CGFloat = 86
    static let backdropMinimumHeight: CGFloat = 1_100

    static func contentTopInset(query: String, hasFeatured: Bool) -> CGFloat {
        query.isEmpty && hasFeatured ? 0 : toolbarClearance
    }
}

enum SubscriberBenefits {
    static let officialURL = URL(string: "https://www.xbox.com/xbox-game-pass/in-game-benefits")!
}

enum DiscoverSearchFocus: Hashable {
    case search(String)
    case clear
}

enum DiscoverSearchOverlayLayout {
    static func isPresented(searchFocused: Bool, suggestionFocused: Bool,
                            query: String, searches: [String]) -> Bool {
        (searchFocused || suggestionFocused)
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !searches.isEmpty
    }

    static func keyboardFocus(query: String, searches: [String]) -> DiscoverSearchFocus? {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = searches.first else { return nil }
        return .search(first)
    }
}

struct DiscoverRecentSearches: View {
    @ObservedObject var selection: DiscoverSelection
    @FocusState.Binding var focused: DiscoverSearchFocus?
    var select: (String) -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent searches").font(.headline)
                Spacer()
                Button("Clear") { selection.clearHistory() }
                    .buttonStyle(.plain)
                    .focused($focused, equals: .clear)
                    .accessibilityIdentifier("xodus.discover.clearRecentSearches")
            }
            ForEach(selection.recentSearches.prefix(8), id: \.self) { query in
                Button {
                    select(query)
                } label: {
                    Label(query, systemImage: "clock")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .focused($focused, equals: .search(query))
                .accessibilityIdentifier("xodus.discover.recentSearch.\(query)")
            }
        }
        .frame(width: 300, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent searches")
        .accessibilityIdentifier("xodus.discover.recentSearches")
        .onExitCommand(perform: dismiss)
    }
}

enum HalloweenShelf {
    // Theme provenance only, not current offers, events or subscription membership.
    // Xbox Wire, 2025-10-14:
    // https://news.xbox.com/en-us/2025/10/14/shocktober-xbox-2025-sale-deals-halloween-xbox/
    static let editorialIDs = [
        "9N9097G0XZMB", "C0N22P73QZ60", "9NXSMCH8RP60", "9MT5NJ5W7B8Z",
        "9PG0PMB5Q0GT", "BT5P2X999VH2", "C1C4DZJPBC2V", "9MW715J1P29D"
    ]
    static func isActive(on date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: date)
        guard let start = calendar.date(from: DateComponents(year: year, month: 10, day: 1)),
              let halloween = calendar.date(from: DateComponents(year: year, month: 10, day: 31)),
              let end = calendar.date(byAdding: .day,
                value: (8 - calendar.component(.weekday, from: halloween)) % 7 + 1,
                to: halloween) else { return false }
        return date >= start && date < end
    }

    static func products(_ loaded: [CatalogProduct], facts: [String: LibraryCatalogFacts],
                         on date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> [CatalogProduct] {
        guard isActive(on: date, timeZone: timeZone) else { return [] }
        var seen = Set<String>()
        return Array(loaded.filter { product in
            guard product.pcCatalogCandidate, editorialIDs.contains(product.id) || facts[product.id]?.genres.contains(where: { genre in
                let words = genre.lowercased().split { !$0.isLetter }
                return words.contains("horror") || words.contains("spooky") || words.contains("halloween")
            }) == true else { return false }
            return seen.insert(product.id).inserted
        }.prefix(12))
    }
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
    @ObservedObject var art = LibraryCatalogArtwork.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(LibrarySupportVisibility.preferenceKey)
    private var showsUnsupportedGames = LibrarySupportVisibility.defaultShowsUnsupported
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
    @State private var detailFocusReturnID: String?
    @State private var seasonalDate = Date()
    @StateObject private var halloweenCatalog = HalloweenCatalog()

    private var projection: CatalogProjection { selection.projection.current }
    private var results: CatalogSearchResults { projection.index.results }
    private var facts: [String: LibraryCatalogFacts] { projection.facts }
    private var genres: [String] { projection.genres }
    private var visible: [CatalogProduct] {
        projection.visible
    }
    private var ownedMatches: [PCGame] {
        projection.owned
    }
    private var operationHasInlineControls: Bool {
        guard !query.isEmpty,
              let owner = operations.operation?.productID ?? operations.directInstallProductID else { return false }
        return ownedMatches.prefix(5).contains {
            $0.id == owner && unsupportedIssues(game($0)).isEmpty
        }
    }
    var showsOperationFeedback: Bool {
        operations.hasDownloadStatus
            && (!operationHasInlineControls || operations.error != nil || operations.notice != nil)
    }
    private var hiddenUnsupportedCount: Int { projection.hiddenCount }
    private var retainedPublicIDs: Set<String> {
        session.retainedPublicIDs(query: query, pending: pending)
    }
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
        !session.searching && session.catalogMatches(query: query) && (query.isEmpty
            ? (!session.discoveryFailures.isEmpty || session.gamePassCatalogError != nil)
            : session.catalogHasQueryWarning)
    }
    private var validEmptySearch: Bool {
        !query.isEmpty && session.catalogMatches(query: query) && !session.searching &&
            !session.catalogStopped && session.catalogError == nil && session.discoveryFailures.isEmpty
            && session.catalogSourceFailure == nil &&
            (!allowsStartupTasks || (session.isReady && canRefresh))
    }
    private var columns: [GridItem] { LibraryGridLayout.columns }
    /// Current results still waiting for public details; they appear as cards once classified.
    private var classifyingCount: Int {
        guard !query.isEmpty, allowsArtworkLoading, session.catalogMatches(query: query) else { return 0 }
        return GameSearchPresentation.classifyingCount(storeIDs: results.storeProducts.map(\.id),
            classified: Set(facts.keys), pending: art.pendingIDs)
    }

    private var projectionKey: CatalogProjectionKey {
        CatalogProjectionKey(accountHash: session.accountHash, query: query, owned: library.representedGames,
            products: session.catalogMatches(query: query)
                ? Array(session.products.prefix(query.isEmpty ? selection.browseLimit : 512)) : [],
            gamePass: Array(session.gamePassProducts.prefix(query.isEmpty ? selection.browseLimit : 512)),
            gamePassIDs: session.gamePassProductIDs,
            installed: installed.games, accessIsCurrent: library.accessIsCurrent,
            metadataRevision: art.revision, compatibility: operations.compatibility,
            genre: selection.genre, scope: selection.scope, showsUnsupported: showsUnsupportedGames)
    }

    var body: some View {
        let key = projectionKey
        selection.prepare(key, accountScope: "\(session.accountHash ?? ""):\(session.market):\(session.language)") {
            CatalogProjection(key: key, facts: art.images.mapValues(\.facts), isVisible: isVisible)
        }
        return content
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            if showsOperationFeedback {
                GameOperationProgressView(operations: operations)
                    .padding(.horizontal, 56).padding(.top, 24)
                    .accessibilityIdentifier("xodus.catalog.installStatus")
            }
            if query.isEmpty, !visible.isEmpty { featuredCarousel }
            VStack(alignment: .leading, spacing: 28) {
                if query.isEmpty {
                    if !genres.isEmpty { browseGenres }
                    if selection.genre == nil {
                        let halloween = HalloweenShelf.products(halloweenCatalog.products,
                            facts: halloweenCatalog.facts, on: seasonalDate).filter { isVisible(game($0)) }
                        if HalloweenShelf.isActive(on: seasonalDate),
                           !halloween.isEmpty || halloweenCatalog.loading || halloweenCatalog.error != nil {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Halloween games").font(.title2.weight(.semibold))
                                if halloweenCatalog.loading && halloween.isEmpty {
                                    ProgressView("Loading Halloween games")
                                }
                                if let error = halloweenCatalog.error {
                                    Text(error).foregroundStyle(.secondary)
                                    Button("Retry Halloween games") {
                                        Task { await loadHalloween(refresh: true) }
                                    }.disabled(halloweenCatalog.loading)
                                }
                                if !halloween.isEmpty {
                                    browseShelf(halloween, demandLoads: false, shelfID: "Halloween")
                                }
                            }
                            .accessibilityIdentifier("xodus.catalog.halloween")
                        }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 24) {
                            resultsTitle
                            Spacer(minLength: 0)
                            scopePicker
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            resultsTitle
                            scopePicker
                        }
                    }
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
                        Text(query.isEmpty ? (selection.genre ?? (session.supports(.discover) ? "Explore PC Game Pass" : "Explore games"))
                             : "Games (\(visible.count))").font(.title2.weight(.semibold))
                        Spacer()
                        if query.isEmpty {
                            LibrarySupportMenu(hiddenCount: hiddenUnsupportedCount,
                                               showsUnsupportedGames: $showsUnsupportedGames)
                        }
                        if pending || session.searching {
                            ProgressView().controlSize(.small).accessibilityLabel("Searching for games")
                            Button("Stop search") { session.stopCatalogSearch() }
                                .accessibilityIdentifier("xodus.catalog.stop")
                        }
                    }
                    if searchUnavailable {
                        VStack(alignment: .leading) {
                            HStack {
                                Label(DiscoverCopy.unavailable, systemImage: "exclamationmark.circle")
                                Button("Retry") { retry() }.disabled(!canRefresh)
                            }
                            if session.catalogSourceFailure != nil {
                                Text("Some search sources couldn't be checked. Results may be incomplete.")
                            }
                        }.foregroundStyle(.secondary)
                    } else if session.catalogStopped {
                        HStack {
                            Text("Search stopped.")
                            Button("Retry") { retry() }.disabled(!canRefresh)
                        }
                    } else if partial {
                        HStack {
                            Text(session.catalogSourceFailure == nil ? DiscoverCopy.partial
                                 : "Some search sources couldn't be checked. Results may be incomplete.")
                            if query.isEmpty || session.catalogCanRetryQueryWarning {
                                Button("Retry") { retry() }.disabled(!canRefresh)
                            }
                        }
                    }
                    if !visible.isEmpty {
                        if query.isEmpty {
                            browseShelf(visible, demandLoads: true)
                            if selection.genre == nil {
                                ForEach(Array(genres.prefix(3)), id: \.self) { genre in
                                    VStack(alignment: .leading, spacing: 16) {
                                        Button { selection.genre = genre } label: {
                                            Label(genre, systemImage: "chevron.right")
                                                .font(.title2.weight(.semibold))
                                        }.buttonStyle(.plain)
                                            .accessibilityLabel("Browse \(genre) games")
                                        browseShelf(projection.genreShelves[genre] ?? [],
                                                    demandLoads: false, shelfID: genre)
                                    }.padding(.top, 16)
                                }
                            }
                        } else {
                            LazyVGrid(columns: columns, spacing: 28) {
                                ForEach(visible) { product in
                                    card(game(product)).id("discover-card-\(product.id)")
                                        .opacity(retainedPublicIDs.contains(product.id) ? 0.45 : 1)
                                        .disabled(retainedPublicIDs.contains(product.id))
                                        .allowsHitTesting(!retainedPublicIDs.contains(product.id))
                                        .accessibilityHidden(retainedPublicIDs.contains(product.id))
                                }
                                ForEach(0..<min(classifyingCount, GameSearchPresentation.placeholderLimit),
                                        id: \.self) { _ in
                                    SearchResultPlaceholderCard()
                                }
                            }
                            .scrollTargetLayout()
                        }
                    } else if classifyingCount > 0 {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(0..<min(classifyingCount, GameSearchPresentation.placeholderLimit),
                                    id: \.self) { _ in
                                SearchResultPlaceholderCard()
                            }
                        }
                        .accessibilityIdentifier("xodus.catalog.searchPlaceholders")
                    } else if pending {
                        let previous = selection.previousResults.visible.filter {
                            selection.previousResults.index.games[$0.id].map(selection.scope.includes) == true
                        }
                        if previous.isEmpty {
                            LazyVGrid(columns: columns, spacing: 28) {
                                ForEach(0..<6, id: \.self) { _ in SearchResultPlaceholderCard() }
                            }
                            .accessibilityIdentifier("xodus.catalog.searchPlaceholders")
                        } else {
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
                    if let notice = selection.continuationNotice(session: session, query: query), !query.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(notice).foregroundStyle(.secondary)
                                .accessibilityIdentifier("xodus.catalog.continuationEnd")
                            if selection.canSearchFurther(session: session, query: query) {
                                Button("Search further") { Task { await loadNextBrowsePage() } }
                                    .disabled(!canRefresh || session.searching || selection.pagingSearch)
                                    .accessibilityIdentifier("xodus.catalog.searchFurther")
                            }
                        }
                    } else if (session.nextCursor != nil || (query.isEmpty &&
                        selection.browseLimit < max(session.products.count, session.gamePassProducts.count))),
                       session.catalogMatches(query: query) {
                        if session.catalogAtLimit {
                            Text("The catalogue reached this build's limit. Some games remain unloaded.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("xodus.catalog.limit")
                        } else {
                            Button("More games") { Task { await loadNextBrowsePage() } }
                                .disabled(!canRefresh || session.searching || selection.pagingSearch)
                                .accessibilityLabel("Load more catalog results")
                                .accessibilityIdentifier("xodus.catalog.loadMore")
                        }
                    }
                }
                if query.isEmpty {
                    Link("Game Pass benefits", destination: SubscriberBenefits.officialURL)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 56).padding(.bottom, 32)
            .padding(.top, DiscoverLayout.contentTopInset(query: query, hasFeatured: !visible.isEmpty))
        }
        .onChange(of: query) { _, value in
            selection.genre = nil
            if value.isEmpty { selection.scope = .allGames }
        }
        .onAppear { seasonalDate = Date() }
        .onChange(of: presentationActive) { _, active in
            if active { seasonalDate = Date() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            seasonalDate = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            seasonalDate = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            seasonalDate = Date()
        }
        .onChange(of: session.selectedProduct) { previous, current in
            guard previous != nil, current == nil else { return }
            restoreDetailFocus()
        }
        .onChange(of: selection.focusRequest) { _, _ in
            selection.recordSearch(query)
            focusedResult = GameSearchPresentation.firstFocusableID(local: ownedMatches.map(\.id),
                publicResults: visible.map(\.id), retainedPublic: retainedPublicIDs)
            if focusedResult == nil { returnToSearch() }
        }
        .onExitCommand(perform: exitSearchResults)
        .task(id: halloweenScope) { await loadHalloween() }
        .task(id: CatalogArtworkLoadKey(market: session.market, language: session.language,
                                       ids: presentationActive ? metadataIDs : [])) {
            guard allowsArtworkLoading, presentationActive else { return }
            await art.load(ids: metadataIDs,
                           market: session.market, language: session.language)
        }
        .background(alignment: .top) {
            ambientBackdrop.frame(minHeight: DiscoverLayout.backdropMinimumHeight, alignment: .top)
        }
    }

    private var resultsTitle: some View {
        Text("Results for \"\(query)\"").font(.title2.bold())
            .lineLimit(2).truncationMode(.tail)
            .textSelection(.enabled)
    }

    private var scopePicker: some View {
        // The picker's own title is its accessibility name; a second label was announced twice.
        Picker("Search scope", selection: $selection.scope) {
            ForEach(GameSearchScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
        .accessibilityIdentifier("xodus.catalog.scope")
    }

    private var halloweenScope: String? {
        guard query.isEmpty, presentationActive, allowsStartupTasks, session.isReady,
              session.accountCountryReady, HalloweenShelf.isActive(on: seasonalDate) else { return nil }
        return "\(session.accountCatalogScope):\(Calendar.current.component(.year, from: seasonalDate))"
    }

    private func loadHalloween(refresh: Bool = false) async {
        await halloweenCatalog.load(scope: halloweenScope, market: session.market,
            language: session.language, refresh: refresh)
    }

    private var metadataIDs: [String] {
        DiscoverBrowse.admittedIDs(results.storeProducts,
            limit: query.isEmpty ? selection.browseLimit : 512)
    }

    private var ambientGame: LibraryGame? {
        if !query.isEmpty, visible.isEmpty, let previous = selection.previousResults.visible.first {
            return selection.previousResults.index.games[previous.id]
        }
        let product = visible.first { $0.id == selection.featuredID } ?? visible.first
        return product.map(game)
    }

    // One backdrop identity for browse and search keeps the last artwork while results change.
    private var ambientBackdrop: some View {
        let game = ambientGame
        return LibraryAmbientBackdrop(references: game.map(landscape) ?? [], installed: game?.installed,
                                      allowsLoading: allowsArtworkLoading)
            .opacity(0.22)
    }

    private func browseShelf(_ products: [CatalogProduct], demandLoads: Bool, shelfID: String? = nil) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 24) {
                ForEach(products) { product in
                    card(game(product)).frame(width: 196)
                        .id(shelfID.map { "discover-\($0)-card-\(product.id)" } ?? "discover-card-\(product.id)")
                        .modifier(HeroScrollVisibility { visible in
                            guard visible, demandLoads, selection.genre == nil, products.count >= 8,
                                  product.id == products.last?.id, presentationActive,
                                  session.catalogError == nil, !session.catalogStopped else { return }
                            Task { await loadNextBrowsePage() }
                        })
                }
            }.scrollTargetLayout().padding(.bottom, 8)
        }
        .scrollIndicators(.never)
        .accessibilityElement(children: .contain)
        .accessibilityLabel((shelfID ?? selection.genre).map { "\($0) games" }
            ?? (session.supports(.discover) ? "Loaded PC Game Pass games" : "Loaded games"))
    }

    private func loadNextBrowsePage() async {
        guard canRefresh, presentationActive, !session.searching else { return }
        if query.isEmpty, selection.browseLimit < max(session.products.count, session.gamePassProducts.count) {
            selection.browseLimit = min(512, selection.browseLimit + DiscoverBrowse.pageSize)
        } else if session.canLoadMoreCatalog {
            if query.isEmpty { selection.browseLimit = min(512, selection.browseLimit + DiscoverBrowse.pageSize) }
            if query.isEmpty {
                await session.refreshCatalog(query, more: true)
            } else {
                await selection.loadMoreSearch(session: session, query: query) {
                    var current = CatalogProjection(key: projectionKey, facts: art.images.mapValues(\.facts), isVisible: isVisible)
                    await art.load(ids: current.index.results.storeProducts.map(\.id),
                                   market: session.market, language: session.language)
                    current = CatalogProjection(key: projectionKey, facts: art.images.mapValues(\.facts), isVisible: isVisible)
                    return Set(current.visible.filter {
                        current.index.games[$0.id].map(selection.scope.includes) == true
                    }.map(\.id))
                }
            }
        }
    }

    func exitSearchResults() {
        focusedResult = nil
        clearSearch()
        returnToSearch()
    }

    private func retry() {
        selection.resetPaging()
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
            if let status = GameInstallAction(game: PCGame(id: game.id, title: game.title, artwork: nil),
                                              operations: operations)
                .registrationStatusTitle(installed: game.installed != nil) {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            if !unsupportedIssues(game).isEmpty {
                Button("View details") { open(game) }
                    .help("Open compatibility details")
                    .accessibilityLabel(GameSearchPresentation.compatibilityDetailsActionLabel(for: game.title))
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
        detailFocusReturnID = nil
        focusedResult = nil
        do {
            let product = try game.product ?? art.images[game.id]?.product ??
                LibraryGame.details(id: game.id, title: game.title,
                    market: session.market, language: session.language,
                    source: "AccountPCLibrary:identityOnly", pcCandidate: false)
            detailFocusReturnID = game.id
            if !query.isEmpty, allowsStartupTasks { selection.recordSearch(query) }
            session.selectedProduct = product
        } catch { session.errorMessage = "Game details couldn't be opened. Your games haven't changed." }
    }

    private func restoreDetailFocus() {
        guard let detailFocusReturnID else { return }
        let available = Set(ownedMatches.map(\.id) + visible.map(\.id)).subtracting(retainedPublicIDs)
        if let target = GameSearchPresentation.focusReturnTarget(preferred: detailFocusReturnID,
                                                                  available: available) {
            focusedResult = target
        } else {
            returnToSearch()
        }
        self.detailFocusReturnID = nil
    }

    private func landscape(_ game: LibraryGame) -> [CatalogArtworkReference] {
        art.images[game.id]?.landscape ??
            (game.product?.artwork.filter { $0.role == .hero } ?? [])
            + (game.cover.map { [$0] } ?? [])
    }

    private func canReviewInstall(_ game: LibraryGame) -> Bool {
        DiscoverBrowse.canReviewInstall(owned: game.pc != nil, accessIsCurrent: library.accessIsCurrent(for: game.id),
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
            DiscoverHeroScrim(increasedContrast: colorSchemeContrast == .increased)
            let blockedReason = heroDownloadUnavailableReason(game)
            VStack(alignment: .leading, spacing: 14) {
                LibraryLogoTitle(title: game.title, references: art.images[game.id]?.logos ?? [],
                                 allowsLoading: allowsArtworkLoading)
                LibraryGameInformation(gameFacts: game.facts,
                                       facts: facts[game.id])
                    .environment(\.libraryOnHeroMedia, true)
                if game.installed != nil { Label("Installed", systemImage: "internaldrive").font(.caption) }
                LibraryGlassCluster {
                    // A disabled Download with no reason is a dead end; the hero offers details instead.
                    if blockedReason == nil { actions(game, primary: true) }
                    Button(blockedReason == nil ? "View game" : "View Details") { open(game) }
                        .modifier(LibraryActionStyle(primary: blockedReason != nil
                            || (game.installed == nil && !canReviewInstall(game))))
                        .accessibilityIdentifier("xodus.discover.hero.details")
                }.controlSize(.large)
                if let blockedReason {
                    Label(blockedReason, systemImage: "info.circle")
                        .font(.callout).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("xodus.discover.hero.reason")
                }
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
        return GameCard(title: game.title, gameFacts: game.facts,
                            compatibilityIssues: unsupportedIssues(game),
                            showsGamePassCatalogBadge: session.gamePassBadgeProductIDs.contains(game.id), openLabel: "View",
                            searchFocus: query.isEmpty ? nil : ($focusedResult, game.id),
                            focusReturn: query.isEmpty ? ($focusedResult, game.id) : nil,
                            open: { open(game) }) {
            CatalogArtworkView(reference: allowsArtworkLoading ? cover : nil,
                               status: cover == nil ? .absent : .available)
        } status: {
            if game.installed != nil { Label("Installed", systemImage: "internaldrive").font(.caption) }
        }
    }

    private func unsupportedIssues(_ game: LibraryGame) -> [LibraryCompatibilityIssue] {
        operations.supportIssues(productID: game.id,
            packageFormat: game.installed?.packageType?.label ?? facts[game.id]?.packageFormat
                ?? halloweenCatalog.facts[game.id]?.packageFormat)
    }

    private func isVisible(_ game: LibraryGame) -> Bool {
        showsUnsupportedGames || unsupportedIssues(game).isEmpty
    }

    /// The reason the hero swaps Download for View Details, or nil to keep the install control.
    private func heroDownloadUnavailableReason(_ game: LibraryGame) -> String? {
        guard unsupportedIssues(game).isEmpty, game.installed == nil,
              let pc = game.pc ?? game.product.map(PCGame.init(product:)) else { return nil }
        return installAction(game, pc: pc, primary: true).heroReplacementReason
    }

    private func installAction(_ game: LibraryGame, pc: PCGame, primary: Bool) -> GameInstallAction {
        GameInstallAction(game: pc, operations: operations,
                          enabled: allowsStartupTasks && canReviewInstall(game), primary: primary,
                          showsDiagnostics: false,
                          disabledReason: !allowsStartupTasks ? "Wait for \(AppBrand.displayName) to finish starting."
                            : game.pc == nil && game.product?.pcCatalogCandidate != true
                                ? "PC availability for this title hasn't been confirmed. Installation is unavailable."
                                : library.installAccessNotice(for: game.id))
    }

    @ViewBuilder private func actions(_ game: LibraryGame, primary: Bool) -> some View {
        if !unsupportedIssues(game).isEmpty {
            if primary { LibraryCompatibilityIndicators(issues: unsupportedIssues(game), heroStyle: true) }
        } else if let match = game.installed {
            InstalledPlayButton(library: installed, operations: operations, game: match,
                                displayTitle: game.title, usesGlass: true, prominent: primary, showsDiagnostics: false)
        } else if let pc = game.pc ?? game.product.map(PCGame.init(product:)) {
            installAction(game, pc: pc, primary: primary)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label(hiddenUnsupportedCount > 0 ? "No games verified yet"
                  : validEmptySearch ? DiscoverCopy.noResults(query)
                  : selection.genre != nil && query.isEmpty ? "No games to show" : session.catalogEmptyTitle,
                  systemImage: "magnifyingglass")
        } description: {
            Text(hiddenUnsupportedCount > 0
                 ? "Some games have known package or anti-cheat blockers. Show unsupported games to see each reason."
                 : validEmptySearch ? DiscoverCopy.emptyDescription
                 : selection.genre != nil && query.isEmpty ? "Try another genre."
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

}

/// Darkens hero artwork behind the white title, facts, reason and buttons. Measured by rendering
/// over pure white artwork (BrandUXChecks): body text from 45% of the hero height down keeps at
/// least 4.5:1, the large title from 30% keeps 3:1, and Increase Contrast keeps 4.5:1 from 20%.
struct DiscoverHeroScrim: View {
    var increasedContrast = false

    static func stops(increasedContrast: Bool) -> [(location: Double, opacity: Double)] {
        increasedContrast
            ? [(0, 0.2), (0.2, 0.62), (1, 0.9)]
            : [(0, 0), (0.2, 0.4), (0.45, 0.68), (1, 0.85)]
    }

    static func opacity(at location: Double, increasedContrast: Bool) -> Double {
        let stops = stops(increasedContrast: increasedContrast)
        guard let upper = stops.firstIndex(where: { $0.location >= location }) else { return stops.last!.opacity }
        guard upper > 0 else { return stops[0].opacity }
        let a = stops[upper - 1], b = stops[upper]
        return a.opacity + (b.opacity - a.opacity) * (location - a.location) / (b.location - a.location)
    }

    var body: some View {
        LinearGradient(stops: Self.stops(increasedContrast: increasedContrast).map {
            Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location)
        }, startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// When a hero may swap its install control for View Details plus a reason. Only a static
/// "can't install" qualifies: while this game is preparing, installing, checking an existing
/// installation or prechecking, the control keeps its in-place progress and Cancel.
enum HeroInstallReplacement {
    static func reason(unavailable: String?, active: Bool, preparing: Bool, checking: Bool,
                       prechecking: Bool) -> String? {
        guard let unavailable, !active, !preparing, !checking, !prechecking else { return nil }
        return unavailable
    }
}

extension GameInstallAction {
    /// Mirrors the in-place states GameInstallAction renders for this game.
    var heroReplacementReason: String? {
        HeroInstallReplacement.reason(unavailable: unavailableReason, active: active, preparing: preparing,
            checking: operations.checkingExistingInstallation(productID: game.id)
                || (operations.installationCheckRequired(for: game)
                    && operations.existingInstallationError(productID: game.id) == nil),
            prechecking: operations.precheckingProductID == game.id)
    }
}
