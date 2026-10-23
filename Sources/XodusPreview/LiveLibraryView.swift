// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusManagement

struct LiveLibraryView: View {
    @ObservedObject var library: PCGamesController
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    @EnvironmentObject private var session: LiveSession
    let query: String
    var allowsStartupTasks = true
    var allowsArtworkLoading: Bool? = nil
    var allowsHeroAnimation = true
    let browse: () -> Void
    let recentActivity: () -> Void
    var showCollection: () -> Void = {}
    @StateObject private var selection = LibrarySelection()
    @StateObject private var passCollections = GamePassCollections()
    @State private var selectedPassCollection: String?
    @ObservedObject private var art = LibraryCatalogArtwork.shared
    @ObservedObject private var xboxStats = LibraryXboxStats.shared
    @ObservedObject private var macEvidence = MacGameEvidenceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("Xodus.showUnsupportedGames") private var showsUnsupportedGames = false
    private var artworkAllowed: Bool { allowsArtworkLoading ?? allowsStartupTasks }
    private var heroMotionAllowed: Bool { allowsHeroAnimation && selection.localDetail == nil }
    private var filter: LibraryFilter {
        get { selection.filter }
        nonmutating set { selection.filter = newValue }
    }
    private var sort: LibrarySort {
        get { selection.sort }
        nonmutating set { selection.sort = newValue }
    }

    private var collection: [LibraryGame] {
        LibraryGame.collection(installed: installed.games, owned: library.representedGames,
                               products: session.products, gamePass: session.gamePassProducts,
                               active: operations.gamePassActive, accessIsCurrent: library.accessIsCurrent)
    }
    private var visibleCandidates: [LibraryGame] {
        LibraryGame.visible(filter == .gamePass ? selectedPassGames : libraryGames,
                            query: query, filter: filter, sort: sort)
    }
    private var libraryGames: [LibraryGame] {
        LibraryGame.displayCollection(installed: installed.games, account: collection)
    }
    private var visible: [LibraryGame] {
        visibleCandidates.filter(isVisible)
    }
    private var hiddenUnsupportedCount: Int {
        visibleCandidates.count - visible.count
    }
    private var gamePassCatalog: [LibraryGame] {
        LibraryGame.gamePassCatalog(installed: installed.games,
                                    owned: library.accessIsCurrent ? library.representedGames : [],
                                    products: session.gamePassProducts)
    }
    private var gamePassHighlights: [LibraryGame] {
        Array(gamePassCatalog.filter(isVisible).prefix(10))
    }
    private func games(in collection: GamePassCollection) -> [LibraryGame] {
        let held = library.accessIsCurrent ? library.representedGames : []
        return collection.products.filter(\.pcCatalogCandidate).map { product in
            let pc = held.first { $0.id == product.id }
            return LibraryGame(id: product.id, title: product.title,
                installed: installed.games.first { $0.storeId == product.id }, pc: pc, product: product,
                owned: pc.map { $0.acquisitionKind != .subscription } ?? false, gamePass: true)
        }.filter(isVisible)
    }
    private var selectedPassGames: [LibraryGame] {
        passCollections.collections.first(where: { $0.key == selectedPassCollection }).map { games(in: $0) }
            ?? gamePassCatalog
    }
    private var editorialGames: [LibraryGame] {
        passCollections.collections.flatMap { Array(games(in: $0).prefix(10)) }
    }
    private var selectedPreviewCollection: GamePassCollection? {
        guard filter == .gamePass else { return nil }
        return passCollections.collections.first {
            $0.key == selectedPassCollection && ($0.isUpcoming || $0.isBenefits)
        }
    }
    private var cataloguePreviewIDs: [String] {
        passCollections.collections.filter { $0.isUpcoming || $0.isBenefits }.flatMap { $0.products.map(\.id) }
    }
    private var continuing: [InstalledGame] {
        LibraryGame.continuing(LibraryGame.visible(collection, query: query, filter: filter, sort: sort).filter(isVisible),
                              launchableIDs: installed.launchableIDs)
    }
    private var localRecords: [LibraryGame] {
        LibraryGame.localRecords(installed: installed.games, qualified: collection, query: query, sort: sort)
    }
    private var classifiedGames: [LibraryGame] {
        let catalogue = OfflineGameCompatibility.snapshot?.products ?? [:]
        let ids = Set(catalogue.filter { $0.value.supported01 }.map(\.key))
            .union(macEvidence.games.filter { $0.value.engine != "native-macos" }.map(\.key))
        return ids.compactMap { id -> LibraryGame? in
            guard let title = catalogue[id]?.title ?? macEvidence.games[id]?.title else { return nil }
            let pc = library.accessIsCurrent ? library.representedGames.first { $0.id == id } : nil
            return LibraryGame(id: id, title: title,
                installed: installed.games.first { $0.storeId == id }, pc: pc,
                product: art.images[id]?.product,
                owned: pc.map { $0.acquisitionKind != .subscription } ?? false,
                gamePass: session.gamePassProducts.contains { $0.id == id })
        }.filter { isVisible($0) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var showsNativeMinecraft: Bool {
        query.isEmpty || "Minecraft: Java Edition".localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ambientBackdrop
            VStack(alignment: .leading, spacing: 0) {
            if query.isEmpty, !heroGames.isEmpty {
                heroCarousel
                if let game = heroGames.first(where: { $0.id == selection.heroID })?.installed {
                    InstalledPlayError(library: installed, game: game).padding(.horizontal, 56)
                }
            }
            VStack(alignment: .leading, spacing: 22) {
                if query.isEmpty, !continuing.isEmpty { continuePlaying }
                if !classifiedGames.isEmpty || showsNativeMinecraft {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Game compatibility").font(.title2.weight(.semibold))
                        Text("Windows package and anti-cheat details. Game access is checked separately.")
                            .font(.callout).foregroundStyle(.secondary)
                        LazyVGrid(columns: LibraryGridLayout.columns, alignment: .leading, spacing: 30) {
                            if showsNativeMinecraft {
                                NativeMinecraftCard {
                                    CatalogArtworkView(reference: artworkAllowed ? art.images["9PJ8266BHFWN"]?.cover : nil,
                                        status: art.images["9PJ8266BHFWN"]?.cover == nil ? .absent : .available)
                                }
                            }
                            ForEach(classifiedGames) { game in card(game) }
                        }
                    }
                }
                if query.isEmpty {
                    ForEach(Array(passCollections.collections.filter { $0.key != "pcgaVTaz" }.prefix(2))) { category in
                        if !games(in: category).isEmpty {
                            gamePassShelf(title: category.title,
                                subtitle: category.isBenefits ? "Game Pass benefits catalogue. Account eligibility is separate."
                                    : category.isUpcoming ? "Coming to PC Game Pass. Availability is not yet confirmed."
                                    : "Explore the PC Game Pass catalogue.",
                                games: Array(games(in: category).prefix(10)), collection: category.key)
                        }
                        if let error = category.error {
                            HStack {
                                Text("\(category.title): \(error)").font(.callout).foregroundStyle(.secondary)
                                Button("Try again") {
                                    Task { await passCollections.loadCollection(category.key, market: session.market, language: session.language) }
                                }.disabled(category.loading)
                            }
                        }
                    }
                    if passCollections.loading {
                        ProgressView("Loading Game Pass collections").controlSize(.small)
                    }
                    if let error = passCollections.error {
                        HStack {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                            Button("Try again") {
                                Task { await passCollections.load(market: session.market, language: session.language, refresh: true) }
                            }.disabled(passCollections.loading)
                        }
                    }
                }
                GameOperationProgressView(operations: operations)
                if OfflineGameCompatibility.unavailable {
                    Text("The offline compatibility catalogue couldn't be read. Live package checks remain available.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = installed.error {
                    ContentUnavailableView {
                        Label("Installed games unavailable", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Try again") { Task { await installed.load() } }.disabled(installed.loading)
                    }
                }
                if let error = installed.historyError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                if let error = installed.discoveryError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                PCGamesView(library: library, installed: installed, operations: operations,
                            query: query, allowsStartupTasks: allowsStartupTasks, showsCollection: false,
                            browse: browse, recentActivity: recentActivity)
                LibraryControls(count: selectedPreviewCollection?.products.count ?? visible.count,
                                hiddenUnsupportedCount: hiddenUnsupportedCount,
                                filter: $selection.filter, sort: $selection.sort,
                                showsUnsupportedGames: $showsUnsupportedGames,
                                allowsSorting: selectedPreviewCollection == nil)
                    .id("library-games")
                if filter == .gamePass {
                    Picker("Collection", selection: $selectedPassCollection) {
                        Text("All PC games").tag(Optional<String>.none)
                        ForEach(passCollections.collections.filter { $0.key != "pcgaVTaz" }) { category in
                            Text(category.title).tag(Optional(category.key))
                        }
                    }.frame(maxWidth: 360)
                }
                if installed.loading { ProgressView("Loading installed games") }
                if let category = selectedPreviewCollection {
                    cataloguePreviewShelf(category)
                } else if visible.isEmpty {
                    if hiddenUnsupportedCount > 0, !showsUnsupportedGames {
                        ContentUnavailableView {
                            Label("No games verified yet", systemImage: "gamecontroller")
                        } description: {
                            Text("Ode to X 0.1 installs MSIXVC games. Known anti-cheat is not supported. The supported filter shows verified classifications; other games may be untested on Mac.")
                        } actions: {
                            Button("Show unsupported games") { showsUnsupportedGames = true }
                        }
                    } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else if filter == .gamePass {
                        ContentUnavailableView {
                            Label(session.gamePassCatalogLoading || session.gamePassCatalogPaging
                                  ? "Loading PC Game Pass" : "PC Game Pass catalogue unavailable",
                                  systemImage: "ticket")
                        } description: { Text(session.gamePassLibraryNotice) }
                        actions: {
                            Button("Load Game Pass games") {
                                Task { await session.loadGamePassCatalog(refresh: true) }
                            }.disabled(!allowsStartupTasks || !session.isReady || session.gamePassCatalogPaging)
                        }
                    } else if !libraryGames.isEmpty {
                        ContentUnavailableView {
                            Label("No \(filter.rawValue.lowercased()) games to show", systemImage: "gamecontroller")
                        } description: { Text("Try another filter to see the games in your library.") }
                        actions: { Button("Show all games") { filter = .all } }
                    } else if library.accessIsCurrent, library.representedGames.isEmpty {
                        if !localRecords.isEmpty || !gamePassHighlights.isEmpty {
                            Text("No PC games found in this account.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView {
                                Label("No PC games found", systemImage: "gamecontroller")
                            } description: { Text("Browse the catalogue to find PC games.") }
                            actions: { Button("Browse games", action: browse) }
                        }
                    }
                } else {
                    LazyVGrid(columns: LibraryGridLayout.columns,
                              alignment: .leading, spacing: 30) {
                        ForEach(visible) { game in card(game) }
                    }
                }
                if filter == .gamePass {
                    if let category = passCollections.collections.first(where: { $0.key == selectedPassCollection }),
                       category.hasMore {
                        ProgressView("Loading more \(category.title) games")
                            .task(id: "\(category.key):\(category.loadedCount)") {
                                await passCollections.loadCollection(category.key, market: session.market,
                                    language: session.language, more: true)
                            }
                    }
                    if session.gamePassCatalogLoading || session.gamePassCatalogPaging {
                        ProgressView("Loading PC Game Pass · \(session.gamePassProducts.count.formatted()) games")
                    }
                    Label(session.gamePassLibraryNotice, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error = session.gamePassCatalogError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Refresh Game Pass") {
                            Task { await session.loadGamePassCatalog(refresh: true) }
                        }
                        if session.gamePassCatalogHasMore {
                            Button("Load remaining games") {
                                Task { await session.loadGamePassCatalog() }
                            }
                        }
                    }
                    .disabled(!allowsStartupTasks || !session.isReady || session.gamePassCatalogPaging || session.searching)
                }
                if let error = art.error {
                    Label(error, systemImage: "photo.badge.exclamationmark").font(.callout).foregroundStyle(.secondary)
                }
                if let error = xboxStats.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                }
                if query.isEmpty {
                    ForEach(passCollections.collections.filter {
                    !["pcgaVTaz", "pdoPC", "XGPPMPRecentlyAdded"].contains($0.key)
                    }) { category in
                    if (category.isUpcoming || category.isBenefits), !category.products.isEmpty {
                        cataloguePreviewShelf(category)
                    } else if !games(in: category).isEmpty {
                        gamePassShelf(title: category.title,
                            subtitle: category.isBenefits ? "Games with subscription benefits. Eligibility is checked separately."
                                : category.isUpcoming ? "Upcoming PC catalogue. Release dates and access are not inferred."
                                : "Explore this PC Game Pass collection.",
                            games: Array(games(in: category).prefix(10)), collection: category.key)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.title).font(.title2.weight(.semibold))
                            if category.error == nil {
                                Text(category.loading ? "Loading this collection."
                                     : "No verified PC packages are available in this collection yet.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Link(category.isBenefits ? "Explore benefits on Xbox" : "View Xbox catalogue",
                                 destination: GamePassCollectionSource.page)
                        }
                    }
                    if let error = category.error {
                        HStack {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                            Button("Try again") {
                                Task { await passCollections.loadCollection(category.key, market: session.market,
                                    language: session.language, more: category.loadedCount > 0) }
                            }.disabled(category.loading)
                        }
                    }
                    }
                }
            }
            .task(id: (heroGames.map(\.id) + collection.map(\.id) + localRecords.map(\.id) + visible.map(\.id)
                + gamePassHighlights.map(\.id) + editorialGames.map(\.id)
                + cataloguePreviewIDs + classifiedGames.map(\.id)).sorted().joined(separator: ",")) {
                guard artworkAllowed else { return }
                await art.load(ids: heroGames.map(\.id) + collection.map(\.id) + localRecords.compactMap { $0.installed?.storeId }
                    .filter(PCGamesClient.validProductID) + visible.map(\.id).filter(PCGamesClient.validProductID)
                    + gamePassHighlights.map(\.id).filter(PCGamesClient.validProductID)
                    + editorialGames.map(\.id) + cataloguePreviewIDs + classifiedGames.map(\.id) + ["9PJ8266BHFWN"],
                    market: session.market, language: session.language)
            }
            .padding(.horizontal, 56).padding(.vertical, 22)
            }
        }
        .preference(key: LibraryHeroPresenceKey.self, value: query.isEmpty && !heroGames.isEmpty)
        .sheet(item: $selection.localDetail) { entry in
            if let product = entry.product {
                LiveProductView(product: product, library: library, installedLibrary: installed,
                    operations: operations, installationID: entry.game.id,
                    allowsStartupTasks: allowsStartupTasks, allowsArtworkLoading: artworkAllowed)
            } else {
                LocalInstalledGameView(game: entry.game, installed: installed, operations: operations)
            }
        }
        .task { if allowsStartupTasks { await library.loadOnAppear() } }
        .task {
            guard allowsStartupTasks else { return }
            while !Task.isCancelled {
                await macEvidence.refresh()
                await installed.discoverNativeInstallations()
                await NativeMinecraft.shared.refresh()
                if NSApp.isActive { await installed.refreshNativeInstallationStatuses() }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .task(id: precheckIDs.joined(separator: ",")) {
            guard allowsStartupTasks, !precheckIDs.isEmpty else { return }
            guard !Task.isCancelled else { return }
            operations.precheck(precheckIDs)
        }
        .task(id: "\(session.isReady):\(session.market):\(session.language):\(query.isEmpty)") {
            guard allowsStartupTasks, session.isReady, query.isEmpty else { return }
            await passCollections.load(market: session.market, language: session.language)
        }
        .task(id: "\(filter.rawValue):\(session.isReady):\(session.market):\(session.language)") {
            guard allowsStartupTasks, filter == .gamePass else { return }
            await session.loadGamePassCatalog()
        }
        .task(id: "\(session.isReady):\(session.market):\(session.language):\(query.isEmpty)") {
            guard allowsStartupTasks, session.isReady, query.isEmpty, session.gamePassProducts.isEmpty else { return }
            await session.loadGamePassCatalog()
        }
        .onChange(of: session.isReady) { _, ready in
            if !ready { selection.requestedGamePassScope = nil }
        }
        .task(id: "\(operations.gamePassActive):\(session.isReady):\(session.searching):\(session.market):\(session.language)") {
            guard allowsStartupTasks, filter != .gamePass, operations.gamePassActive, session.isReady,
                  session.supports(.discover), session.gamePassProducts.isEmpty, !session.searching else { return }
            let scope = "\(session.market):\(session.language)"
            guard selection.requestedGamePassScope != scope else { return }
            selection.requestedGamePassScope = scope
            await session.refreshCatalog("")
        }
    }

    private var heroGames: [LibraryGame] {
        func recommendable(_ game: LibraryGame) -> Bool {
            LibrarySupportVisibility.issues(productID: game.id, installed: false,
                packageFormat: art.images[game.id]?.facts.packageFormat,
                compatibility: operations.compatibility[game.id]).isEmpty
        }
        return LibraryGame.heroCandidates(qualified: collection.filter(recommendable),
            catalogue: gamePassCatalog.filter(recommendable), continuingIDs: continuing.map(\.id))
    }

    private var heroCarousel: some View {
        ZStack(alignment: .bottom) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(heroGames) { game in
                            hero(game, selected: selection.heroID == game.id)
                                .containerRelativeFrame(.horizontal).id(game.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.never).scrollTargetBehavior(HeroPageSnap())
                .scrollPosition(id: $selection.heroID, anchor: .leading)
                if heroGames.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(heroGames) { game in
                            Button {
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { selection.heroID = game.id }
                            } label: {
                                Circle().fill(selection.heroID == game.id ? Color.primary : Color.secondary.opacity(0.55))
                                    .frame(width: 8, height: 8).frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show \(game.title)")
                            .accessibilityAddTraits(selection.heroID == game.id ? .isSelected : [])
                        }
                    }
                    .padding(.bottom, 18)
                }
        }
        .frame(height: 460).clipped()
        .onHover { selection.heroHovered = $0 }
        .onChange(of: heroGames.map(\.id), initial: true) { _, ids in
            if selection.heroID.map({ !ids.contains($0) }) ?? true { selection.heroID = ids.first }
        }
        .task(id: "\(heroGames.map(\.id).joined(separator: ",")):\(heroMotionAllowed):\(reduceMotion)") {
            guard allowsStartupTasks, heroMotionAllowed, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled, !selection.heroHovered, !selection.heroPlaying, heroGames.count > 1 else { continue }
                let ids = heroGames.map(\.id)
                let next = ids.firstIndex(of: selection.heroID ?? "").map { ids[($0 + 1) % ids.count] } ?? ids[0]
                withAnimation(.smooth(duration: 0.6)) { selection.heroID = next }
            }
        }
    }

    private func hero(_ game: LibraryGame, selected: Bool) -> some View {
        let id = game.installed?.storeId ?? game.id
        let landscape = landscapeReferences(game)
        return LibraryHero(title: game.title,
                    logos: (xboxStats.cache?.games[id]?.logo.map { [$0] } ?? []) + (art.images[id]?.logos ?? []),
                    allowsArtworkLoading: artworkAllowed, height: 460) {
            LibraryHeroMedia(trailer: art.images[id]?.detail?.trailers.first,
                             allowsPlayback: allowsStartupTasks && heroMotionAllowed && selected,
                             playingChanged: { playing in selection.heroPlaying = playing && selected }) {
                LibraryLandscapeView(references: landscape,
                                     installed: game.installed, allowsLoading: artworkAllowed)
            }
        } poster: {
            LibraryLandscapeView(references: art.images[id]?.cover.map { [$0] } ?? (game.cover.map { [$0] } ?? []),
                                 installed: game.installed, allowsLoading: artworkAllowed)
        } information: {
            Text(game.pc?.acquisitionKind == .subscription ? "Included with your subscription"
                 : game.pc != nil ? "In your library" : "PC Game Pass catalogue")
                .font(.callout.weight(.medium))
            information(id: id)
            LibraryGameSizeView(installed: game.installed, downloadBytes: art.images[id]?.facts.downloadBytes,
                                productID: id,
                                pcPackageListed: LibraryPCPackageEvidence.listed(
                                    observed: art.images[id]?.facts.pcPackageListed, candidate: game.product?.pcCatalogCandidate),
                                packageFormat: art.images[id]?.facts.packageFormat,
                                allowsMeasurement: artworkAllowed)
        } actions: {
            if !unsupportedIssues(game).isEmpty {
                LibraryCompatibilityIndicators(issues: unsupportedIssues(game), heroStyle: true)
                Button("View game") { open(game) }.modifier(LibraryActionStyle(primary: false))
            } else if let match = game.installed {
                InstalledPlayButton(library: installed, operations: operations, game: match,
                                    usesGlass: true, heroStyle: true)
                InstalledGameActions(library: installed, operations: operations, game: match,
                                     usesGlass: true, heroStyle: true)
            } else {
                if let pc = game.pc ?? game.product.map(PCGame.init(product:)) {
                    GameInstallAction(game: pc, operations: operations,
                        enabled: allowsStartupTasks && DiscoverBrowse.canReviewInstall(
                            owned: game.pc != nil, accessIsCurrent: library.accessIsCurrent,
                            gamePass: game.gamePass, subscriptionActive: operations.gamePassActive,
                            pcCandidate: true))
                }
                Button("View game") { open(game) }.modifier(LibraryActionStyle(primary: false))
                if operations.precheckingProductID == game.id {
                    ProgressView().controlSize(.small).help("Checking whether this game runs on Mac")
                }
            }
        }
    }

    private func unsupportedReason(_ game: LibraryGame) -> String? {
        let issues = unsupportedIssues(game)
        return issues.isEmpty ? nil : issues.map(\.detail).joined(separator: " ")
    }

    private func unsupportedIssues(_ game: LibraryGame) -> [LibraryCompatibilityIssue] {
        operations.supportIssues(
            productID: game.installed?.storeId ?? game.id,
            packageFormat: game.installed?.packageType?.label ?? art.images[game.id]?.facts.packageFormat
        )
    }

    private func isVisible(_ game: LibraryGame) -> Bool {
        showsUnsupportedGames || unsupportedIssues(game).isEmpty
    }

    @ViewBuilder private var ambientBackdrop: some View {
        if let game = heroGames.first(where: { $0.id == selection.heroID }) ?? heroGames.first {
            LibraryAmbientBackdrop(references: landscapeReferences(game),
                                   installed: game.installed, allowsLoading: artworkAllowed)
        } else {
            Color(nsColor: .windowBackgroundColor).frame(height: 820)
        }
    }

    private func landscapeReferences(_ game: LibraryGame) -> [CatalogArtworkReference] {
        let id = game.installed?.storeId ?? game.id
        let loaded = art.images[id]?.landscape ?? []
        return loaded.isEmpty ? game.product?.artwork.filter { $0.role == .hero } ?? [] : loaded
    }

    private var precheckIDs: [String] {
        let shown = heroGames + gamePassHighlights + editorialGames + Array(visibleCandidates.prefix(24))
        var seen = Set<String>()
        return shown.compactMap { game in
            let id = game.installed?.storeId ?? game.id
            return PCGamesClient.validProductID(id) && seen.insert(id).inserted ? id : nil
        }
    }

    private var continuePlaying: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Continue Playing").font(.title2.weight(.semibold))
                Spacer()
                Button("See All") { filter = .installed; sort = .recentlyPlayed }
                    .accessibilityLabel("Show installed games by last played")
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(continuing) { game in
                        VStack(alignment: .leading, spacing: 10) {
                            LibraryLandscapeView(references: art.images[game.storeId]?.landscape ?? [],
                                                 installed: game, allowsLoading: artworkAllowed)
                                .frame(width: 260, height: 110).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .bottomTrailing) {
                                    InstalledPlayButton(library: installed, operations: operations, game: game,
                                                        usesGlass: true, prominent: false)
                                        .padding(12)
                                }
                            Text(game.title).font(.headline).lineLimit(1)
                            HStack {
                                InstalledPackageTypeLabel(game: game)
                                Spacer()
                                InstalledEngineOverride(library: installed, game: game)
                            }
                            if let date = game.lastPlayedAt {
                                Text("Last played \(Text(date, style: .relative)) ago")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            InstalledPlayError(library: installed, game: game)
                        }.frame(width: 260, alignment: .leading).id(game.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selection.recentGameID, anchor: .leading)
            .onChange(of: continuing.map(\.id), initial: true) { _, ids in
                if selection.recentGameID.map({ !ids.contains($0) }) ?? true {
                    selection.recentGameID = ids.first
                }
            }
        }
    }

    private var gamePassHighlightsSection: some View {
        gamePassShelf(title: "PC Game Pass highlights",
            subtitle: "Explore the PC Game Pass catalogue.", games: gamePassHighlights)
    }

    private func cataloguePreviewShelf(_ category: GamePassCollection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title).font(.title2.weight(.semibold))
                    Text(category.isUpcoming
                         ? "Upcoming announcements. PC packages and availability may not be published yet."
                         : "Games with subscription benefits. This is not a list of owned or installable games.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if filter != .gamePass || selectedPassCollection != category.key {
                    Button("See All") { selectCollection(category.key) }
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(category.products) { product in
                        Button { session.selectedProduct = product } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                LibraryLandscapeView(references: art.images[product.id]?.landscape
                                    ?? product.artwork.filter { $0.role == .hero },
                                    installed: nil, allowsLoading: artworkAllowed)
                                    .frame(width: 260, height: 130).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(product.title).font(.headline).lineLimit(1)
                                Text(category.isUpcoming ? "Coming soon" : "Subscription benefits")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.frame(width: 260, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.scrollTargetLayout()
            }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
        }
    }

    private func gamePassShelf(title: String, subtitle: String, games: [LibraryGame],
                               collection: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("See All") { selectCollection(collection) }
                    .accessibilityLabel("Show all \(title) games")
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(games) { game in
                        Button { open(game) } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                LibraryLandscapeView(references: art.images[game.id]?.landscape ?? [],
                                                     installed: game.installed, allowsLoading: artworkAllowed)
                                    .frame(width: 260, height: 130).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                HStack {
                                    Text(game.title).font(.headline).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if !unsupportedIssues(game).isEmpty {
                                        LibraryCompatibilityIndicators(issues: unsupportedIssues(game))
                                    }
                                }
                                Text(game.owned ? "In your library" : "Game Pass catalog")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(width: 260, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private func open(_ game: LibraryGame) {
        do {
            let productID = game.installed?.storeId ?? game.id
            guard PCGamesClient.validProductID(productID) else {
                if let local = game.installed { selection.localDetail = InstalledGameDetailSelection(game: local, product: nil) }
                else { session.errorMessage = "Game details couldn't be opened." }
                return
            }

            let product = try game.product ?? art.images[productID]?.product ??
                LibraryGame.details(id: productID, title: game.title, market: session.market, language: session.language,
                                    source: game.owned ? "AccountPCLibrary:identityOnly" : "LocalInstalledRegistry:identityOnly",
                                    pcCandidate: false)
            if let local = game.installed {
                selection.localDetail = InstalledGameDetailSelection(game: local, product: product)
            } else { session.selectedProduct = product }
        } catch { session.errorMessage = "Game details couldn't be opened. Your games haven't changed." }
    }

    private func selectCollection(_ key: String?) {
        selectedPassCollection = key
        filter = .gamePass
        sort = .title
        Task { @MainActor in
            await Task.yield()
            showCollection()
        }
    }

    private func information(id: String, compact: Bool = false) -> some View {
        let metadata = art.images[id]?.facts
        let xbox = xboxStats.cache?.games[id]
        let facts = metadata?.genres.isEmpty == false ? metadata :
            xbox.map { LibraryCatalogFacts(genres: $0.genres, capabilities: metadata?.capabilities ?? []) } ?? metadata
        let game = (filter == .gamePass ? gamePassCatalog : collection).first(where: { $0.id == id })
        return LibraryGameInformation(access: game.flatMap(LibraryAccess.init),
                                      gamePass: game?.gamePass == true,
                                      facts: facts, xbox: xbox, compact: compact)
    }

    private func card(_ game: LibraryGame) -> some View {
        let artworkID = game.installed?.storeId ?? game.id
        return LibraryCover(title: game.title,
                     openLabel: "View",
                     alwaysShowsActions: true,
                     open: { open(game) }) {
            CatalogArtworkView(reference: artworkAllowed ? art.images[artworkID]?.cover ?? game.cover : nil,
                               status: (art.images[artworkID]?.cover ?? game.cover) == nil ? .absent : .available)
        } status: {
            if !unsupportedIssues(game).isEmpty {
                LibraryCompatibilityIndicators(issues: unsupportedIssues(game))
            }
            if let evidence = OfflineGameCompatibility.publisherEvidence(for: artworkID) {
                Label(evidence.technologies.joined(separator: ", "), systemImage: "shield")
                    .accessibilityLabel("Anti-cheat: \(evidence.technologies.joined(separator: ", "))")
            }
            LibraryGameSizeView(installed: game.installed,
                                downloadBytes: art.images[artworkID]?.facts.downloadBytes,
                                productID: artworkID,
                                pcPackageListed: LibraryPCPackageEvidence.listed(
                                    observed: art.images[artworkID]?.facts.pcPackageListed, candidate: game.product?.pcCatalogCandidate),
                                packageFormat: game.installed?.packageType?.label
                                    ?? art.images[artworkID]?.facts.packageFormat,
                                allowsMeasurement: artworkAllowed)
            if let match = game.installed {
                InstalledPlayError(library: installed, game: match)
            }
        } actions: {
            LibraryGlassCluster {
                if let match = game.installed {
                    if unsupportedIssues(game).isEmpty {
                        InstalledPlayButton(library: installed, operations: operations, game: match,
                                            usesGlass: true, prominent: false)
                    }
                    InstalledGameActions(library: installed, operations: operations, game: match, usesGlass: true,
                                         details: { open(game) })
                } else if unsupportedReason(game) != nil {
                    EmptyView()
                } else if let pc = game.pc {
                    GameInstallAction(game: pc, operations: operations,
                        enabled: allowsStartupTasks && library.accessIsCurrent, primary: false)
                } else if game.gamePass, let product = game.product {
                    GameInstallAction(game: PCGame(product: product), operations: operations,
                        enabled: allowsStartupTasks &&
                        DiscoverBrowse.canReviewInstall(owned: false, accessIsCurrent: false,
                            gamePass: true, subscriptionActive: operations.gamePassActive,
                            pcCandidate: product.pcCatalogCandidate), primary: false)
                } else {
                    GameInstallAction(game: PCGame(id: game.id, title: game.title, artwork: game.cover),
                        operations: operations, enabled: allowsStartupTasks && library.accessIsCurrent,
                        primary: false)
                }
            }
        }
        .contextMenu {
            if let match = game.installed {
                InstalledEngineOverride(library: installed, game: match)
                InstalledGameManagement(library: installed, operations: operations, game: match)
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: match.folder) }
            } else { Button("View game") { open(game) } }
        }
    }
}
