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
    @StateObject private var selection = LibrarySelection()
    @ObservedObject private var art = LibraryCatalogArtwork.shared
    @ObservedObject private var xboxStats = LibraryXboxStats.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var artworkAllowed: Bool { allowsArtworkLoading ?? allowsStartupTasks }
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
    private var visible: [LibraryGame] {
        LibraryGame.visible(filter == .gamePass ? gamePassCatalog : collection,
                            query: query, filter: filter, sort: sort)
    }
    private var gamePassCatalog: [LibraryGame] {
        LibraryGame.gamePassCatalog(installed: installed.games,
                                    owned: library.accessIsCurrent ? library.representedGames : [],
                                    products: session.gamePassProducts)
    }
    private var continuing: [InstalledGame] {
        LibraryGame.continuing(LibraryGame.visible(collection, query: query, filter: filter, sort: sort),
                              launchableIDs: installed.launchableIDs)
    }
    private var localRecords: [LibraryGame] {
        LibraryGame.localRecords(installed: installed.games, qualified: collection, query: query, sort: sort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if query.isEmpty, !heroGames.isEmpty {
                heroCarousel
                if let game = heroGames.first(where: { $0.id == selection.heroID })?.installed {
                    InstalledPlayError(library: installed, game: game).padding(.horizontal, 56)
                }
            }
            VStack(alignment: .leading, spacing: 22) {
                if query.isEmpty, !continuing.isEmpty { continuePlaying }
                GameOperationProgressView(operations: operations)
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
                PCGamesView(library: library, installed: installed, operations: operations,
                            query: query, allowsStartupTasks: allowsStartupTasks, showsCollection: false,
                            browse: browse, recentActivity: recentActivity)
                LibraryControls(count: visible.count, filter: $selection.filter, sort: $selection.sort)
                    .id("library-games")
                if installed.loading { ProgressView("Loading installed games") }
                if visible.isEmpty {
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                    } else if !collection.isEmpty {
                        ContentUnavailableView {
                            Label("No \(filter.rawValue.lowercased()) games", systemImage: "gamecontroller")
                        } description: { Text("Only access-qualified PC games appear in Your Games. Preserved local installations are shown separately below.") }
                        actions: { Button("Show all games") { filter = .all } }
                    } else if library.hasSavedSignIn {
                        ContentUnavailableView {
                            Label("Your games are ready to load", systemImage: "gamecontroller")
                        } description: { Text("Load your account-held PC games. Local installations alone don't confirm account access.") }
                        actions: { Button("Load PC games") { library.refresh() }.disabled(library.busy || library.needsKeychainApproval) }
                    }
                } else {
                    LazyVGrid(columns: LibraryGridLayout.columns,
                              alignment: .leading, spacing: 30) {
                        ForEach(visible) { game in card(game) }
                    }
                }
                if filter == .gamePass {
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
                if filter != .gamePass, !localRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Installed on this Mac").font(.title2.weight(.semibold))
                        LazyVGrid(columns: LibraryGridLayout.columns,
                                  alignment: .leading, spacing: 30) {
                            ForEach(localRecords) { game in card(game) }
                        }
                    }.accessibilityIdentifier("xodus.library.localRecords")
                }
                if let error = art.error {
                    Label(error, systemImage: "photo.badge.exclamationmark").font(.callout).foregroundStyle(.secondary)
                }
                if let error = xboxStats.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                }
            }
            .task(id: (collection.map(\.id) + localRecords.map(\.id) + visible.map(\.id)).sorted().joined(separator: ",")) {
                guard artworkAllowed else { return }
                await art.load(ids: collection.map(\.id) + localRecords.compactMap { $0.installed?.storeId }
                    .filter(PCGamesClient.validProductID) + visible.map(\.id).filter(PCGamesClient.validProductID),
                    market: session.market, language: session.language)
            }
            .padding(.horizontal, 56).padding(.vertical, 22)
        }
        .task { if allowsStartupTasks { await library.loadOnAppear() } }
        .task(id: "\(precheckIDs.joined(separator: ",")):\(operations.canStartMutation)") {
            guard allowsStartupTasks, operations.canStartMutation, !precheckIDs.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            operations.precheck(precheckIDs)
        }
        .task(id: "\(filter.rawValue):\(session.isReady):\(session.market):\(session.language)") {
            guard allowsStartupTasks, filter == .gamePass else { return }
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

    // Apple TV pattern: recently played first, then the rest of the installed and owned collection.
    private var heroGames: [LibraryGame] {
        let order = Dictionary(continuing.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = collection.sorted {
            let left = $0.installed.flatMap { order[$0.id] } ?? ($0.installed == nil ? 2_000 : 1_000)
            let right = $1.installed.flatMap { order[$0.id] } ?? ($1.installed == nil ? 2_000 : 1_000)
            return left == right ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : left < right
        }
        return Array(ranked.prefix(6))
    }

    private var heroCarousel: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(heroGames) { game in
                            hero(game, selected: selection.heroID == game.id)
                                .frame(width: geometry.size.width).id(game.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.never).scrollTargetBehavior(.paging)
                .scrollPosition(id: $selection.heroID)
                if heroGames.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(heroGames) { game in
                            Button {
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { selection.heroID = game.id }
                            } label: {
                                Circle().fill(selection.heroID == game.id ? Color.white : Color.white.opacity(0.45))
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
        }
        .frame(height: 460)
        .onHover { selection.heroHovered = $0 }
        .onChange(of: heroGames.map(\.id), initial: true) { _, ids in
            if selection.heroID.map({ !ids.contains($0) }) ?? true { selection.heroID = ids.first }
        }
        .task(id: heroGames.map(\.id).joined(separator: ",")) {
            guard allowsStartupTasks, allowsHeroAnimation, !reduceMotion else { return }
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
        return LibraryHero(title: game.title,
                    logos: (xboxStats.cache?.games[id]?.logo.map { [$0] } ?? []) + (art.images[id]?.logos ?? []),
                    allowsArtworkLoading: artworkAllowed, height: 460) {
            LibraryHeroMedia(trailer: art.images[id]?.detail?.trailers.first,
                             allowsPlayback: allowsStartupTasks && allowsHeroAnimation && selected,
                             playingChanged: { playing in selection.heroPlaying = playing && selected }) {
                LibraryLandscapeView(references: art.images[id]?.landscape ?? [],
                                     installed: game.installed, allowsLoading: artworkAllowed)
            }
        } poster: {
            LibraryLandscapeView(references: art.images[id]?.cover.map { [$0] } ?? (game.cover.map { [$0] } ?? []),
                                 installed: game.installed, allowsLoading: artworkAllowed)
        } information: {
            information(id: id)
            if let match = game.installed { InstalledPackageTypeLabel(game: match) }
            LibraryGameSizeView(installed: game.installed, downloadBytes: art.images[id]?.facts.downloadBytes,
                                packageFormat: art.images[id]?.facts.packageFormat,
                                allowsMeasurement: artworkAllowed)
        } actions: {
            if let match = game.installed {
                InstalledEngineOverride(library: installed, game: match)
                InstalledPlayButton(library: installed, operations: operations, game: match,
                                    usesGlass: true, heroStyle: true)
                InstalledGameActions(library: installed, operations: operations, game: match,
                                     usesGlass: true, heroStyle: true)
            } else if let reason = unsupportedReason(game) {
                LibraryUnsupportedLabel(reason: reason, heroStyle: true)
                Button("View game") { open(game) }.modifier(LibraryActionStyle(primary: false))
            } else {
                Button {
                    if let pc = game.pc { Task { await operations.install(pc) } }
                } label: { Label("Install", systemImage: "icloud.and.arrow.down") }
                .modifier(LibraryActionStyle(primary: true))
                .disabled(game.pc == nil || !allowsStartupTasks || !operations.canStartMutation)
                Button("View game") { open(game) }.modifier(LibraryActionStyle(primary: false))
                if operations.precheckingProductID == game.id {
                    ProgressView().controlSize(.small).help("Checking whether this game runs on Mac")
                }
            }
        }
    }

    private func unsupportedReason(_ game: LibraryGame) -> String? {
        guard game.installed == nil, let result = operations.compatibility[game.id], !result.supported else { return nil }
        return result.reason ?? "This game isn't supported on Mac yet."
    }

    private var precheckIDs: [String] {
        let shown = heroGames + (filter == .gamePass ? [] : Array(visible.prefix(12)))
        var seen = Set<String>()
        return shown.filter { $0.installed == nil && $0.pc != nil && seen.insert($0.id).inserted }.map(\.id)
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

    private func open(_ game: LibraryGame) {
        do {
            let productID = game.installed?.storeId ?? game.id
            guard PCGamesClient.validProductID(productID) else {
                session.errorMessage = "This local record has no verified Store identity. Its files and saves are preserved."
                return
            }
            session.selectedProduct = try game.product ?? art.images[productID]?.product ??
                LibraryGame.details(id: productID, title: game.title, market: session.market, language: session.language,
                                    source: game.owned ? "AccountPCLibrary:identityOnly" : "LocalInstalledRegistry:identityOnly",
                                    pcCandidate: false)
        } catch { session.errorMessage = "Game details couldn't be opened. Your games haven't changed." }
    }

    private func information(id: String, compact: Bool = false) -> some View {
        let metadata = art.images[id]?.facts
        let xbox = xboxStats.cache?.games[id]
        let facts = metadata?.genres.isEmpty == false ? metadata :
            xbox.map { LibraryCatalogFacts(genres: $0.genres, capabilities: metadata?.capabilities ?? []) } ?? metadata
        let game = (filter == .gamePass ? gamePassCatalog : collection).first(where: { $0.id == id })
        return VStack(alignment: .leading, spacing: 5) {
            LibraryGameInformation(access: game.flatMap(LibraryAccess.init),
                                   gamePass: game?.gamePass == true,
                                   facts: facts, xbox: xbox, compact: compact)
        }
    }

    private func card(_ game: LibraryGame) -> some View {
        let artworkID = game.installed?.storeId ?? game.id
        return LibraryCover(title: game.title,
                     openLabel: "View",
                     alwaysShowsActions: game.installed != nil,
                     open: { open(game) }) {
            CatalogArtworkView(reference: artworkAllowed ? art.images[artworkID]?.cover ?? game.cover : nil,
                               status: (art.images[artworkID]?.cover ?? game.cover) == nil ? .absent : .available)
        } status: {
            HStack(spacing: 8) {
                if let match = game.installed {
                    InstalledPackageTypeLabel(game: match)
                } else if let format = art.images[artworkID]?.facts.packageFormat,
                   unsupportedReason(game) != nil {
                    LibraryPackageFormatLabel(format: format)
                }
                if game.installed != nil {
                    Label("Installed", systemImage: "internaldrive")
                    if game.eligibility == .installedUnknown {
                        Label("Access not verified", systemImage: "questionmark.circle")
                    }
                } else if let reason = unsupportedReason(game) {
                    Label("Not on Mac yet", systemImage: "laptopcomputer.slash").help(reason)
                } else {
                    LibraryGameSizeView(installed: nil, downloadBytes: art.images[artworkID]?.facts.downloadBytes,
                                        packageFormat: art.images[artworkID]?.facts.packageFormat,
                                        allowsMeasurement: artworkAllowed)
                }
            }
            if let match = game.installed { InstalledPlayError(library: installed, game: match) }
        } actions: {
            LibraryGlassCluster {
                if let match = game.installed {
                    InstalledEngineOverride(library: installed, game: match)
                    InstalledPlayButton(library: installed, operations: operations, game: match,
                                        usesGlass: true, prominent: false)
                    InstalledGameActions(library: installed, operations: operations, game: match, usesGlass: true)
                } else if game.pc != nil, unsupportedReason(game) != nil {
                    EmptyView()
                } else if game.pc != nil {
                    Button {
                        if let pc = game.pc { Task { await operations.install(pc) } }
                        else if let product = game.product {
                            Task { await operations.install(PCGame(product: product)) }
                        }
                    } label: {
                        Label("Install", systemImage: "icloud.and.arrow.down")
                    }
                    .labelStyle(.iconOnly)
                    .help("Install \(game.title)")
                    .modifier(LibraryActionStyle(primary: false))
                    .disabled(!allowsStartupTasks || !operations.canStartMutation)
                    .accessibilityLabel("Install \(game.title)")
                    .accessibilityIdentifier("xodus.pcGames.download")
                } else if game.gamePass {
                    Button {
                        if let product = game.product {
                            Task { await operations.install(PCGame(product: product)) }
                        }
                    } label: {
                        Label("Install", systemImage: "icloud.and.arrow.down")
                    }
                    .modifier(LibraryActionStyle(primary: false))
                    .disabled(!allowsStartupTasks || !operations.canStartMutation ||
                        !DiscoverBrowse.canReviewInstall(owned: false, accessIsCurrent: false,
                            gamePass: true, subscriptionActive: operations.gamePassActive,
                            pcCandidate: game.product?.pcCatalogCandidate == true))
                    .help("Install \(game.title)")
                    .accessibilityLabel("Install \(game.title)")
                    .accessibilityIdentifier("xodus.pcGames.install")
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
