// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusManagement

private struct LibraryHeroFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    fileprivate var libraryHeroInteraction: Bool? {
        get { self[LibraryHeroFocusKey.self] }
        set { self[LibraryHeroFocusKey.self] = newValue }
    }
}

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
    var positionCollection: (String?) -> Void = { _ in }
    @ObservedObject var selection = LibrarySelection()
    @ObservedObject private var art = LibraryCatalogArtwork.shared
    @ObservedObject private var xboxStats = LibraryXboxStats.shared
    @ObservedObject private var macEvidence = MacGameEvidenceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.catalogPresentationActive) private var presentationActive
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @FocusedValue(\.libraryHeroInteraction) private var heroInteraction
    @State private var heroVisible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @AppStorage("Xodus.showUnsupportedGames") private var showsUnsupportedGames = false
    private var artworkAllowed: Bool { allowsArtworkLoading ?? allowsStartupTasks }
    private var heroMotionAllowed: Bool { allowsHeroAnimation && selection.localDetail == nil }
    private var filter: LibraryFilter {
        get { selection.filter }
        nonmutating set { changeScope(filter: newValue, showsUnsupported: showsUnsupportedGames) }
    }
    private var sort: LibrarySort {
        get { selection.sort }
        nonmutating set { selection.sort = newValue }
    }

    private var projection: LibraryProjection { selection.projection.current }
    private var collection: [LibraryGame] { projection.collection }
    private var visibleCandidates: [LibraryGame] { projection.candidates }
    private var visible: [LibraryGame] { projection.visible }
    private var hiddenUnsupportedCount: Int {
        visibleCandidates.count - visible.count
    }
    private var continuing: [InstalledGame] { projection.continuing }
    private var localRecords: [LibraryGame] { projection.local }
    private var showsNativeMinecraft: Bool {
        [.all, .installed].contains(filter)
            && (query.isEmpty || "Minecraft: Java Edition".localizedCaseInsensitiveContains(query))
    }
    private var accountCollectionIncomplete: Bool {
        !library.accessIsCurrent || library.snapshot?.isComplete != true
    }
    private var purchaseNotice: String? {
        guard filter == .owned else { return nil }
        if accountCollectionIncomplete {
            return "Your purchased PC games aren't fully available yet. Shown purchases may be incomplete; installed-game access is checked separately."
        }
        let unknown = library.representedGames.filter { $0.acquisitionKind == .unknown }.count
        return unknown > 0
            ? "\(unknown.formatted()) games in your PC library have an unidentified acquisition source and aren't classified as Owned."
            : nil
    }
    private func projectionKey(filter: LibraryFilter, showsUnsupported: Bool) -> LibraryProjectionKey {
        LibraryProjectionKey(accountHash: session.accountHash, query: query, owned: library.representedGames,
            products: session.products, gamePass: session.gamePassProducts, active: operations.gamePassActive,
            installed: installed.games, permitted: Set(installed.games.map(\.storeId).filter {
                installed.productAccess.permits($0, account: session.accountHash)
            }), launchable: installed.launchableIDs, accessIsCurrent: library.accessIsCurrent,
            metadataRevision: art.revision, compatibility: operations.compatibility,
            filter: filter, sort: sort, showsUnsupported: showsUnsupported)
    }

    private func changeScope(filter nextFilter: LibraryFilter, showsUnsupported: Bool) {
        let key = projectionKey(filter: nextFilter, showsUnsupported: showsUnsupported)
        let next = LibraryProjection(key: key,
            isVisible: { showsUnsupported || unsupportedIssues($0).isEmpty }, recommendable: recommendable)
        var targets = Set(next.visible.map { "library-card-\($0.id)" })
        if [.all, .installed].contains(nextFilter) {
            targets.formUnion(next.local.filter { showsUnsupported || unsupportedIssues($0).isEmpty }
                .map { "library-local-\($0.id)" })
        }
        let target = selection.collectionTarget(remaining: targets)
        selection.beginScopeMeasurement(filter: nextFilter, target: target)
        withTransaction(Transaction(animation: nil)) {
            selection.prepareScopeExtent()
            positionCollection(target)
            selection.filter = nextFilter
            showsUnsupportedGames = showsUnsupported
        }
    }

    var body: some View {
        let key = projectionKey(filter: filter, showsUnsupported: showsUnsupportedGames)
        selection.projection.prepare(key) {
            LibraryProjection(key: key, isVisible: isVisible, recommendable: recommendable)
        }
        return content
    }

    private var content: some View {
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
                VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 0) {
                LibraryControls(count: visible.count,
                                hiddenUnsupportedCount: hiddenUnsupportedCount,
                                filter: Binding(get: { filter }, set: { filter = $0 }), sort: $selection.sort,
                                showsUnsupportedGames: Binding(get: { showsUnsupportedGames }, set: {
                                    changeScope(filter: filter, showsUnsupported: $0)
                                }),
                                allowsSorting: true)
                    .id("library-games")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        selection.measureHeader($0)
                    }
                }
                .scrollTargetLayout()
                VStack(alignment: .leading, spacing: 22) {
                if let purchaseNotice {
                    Label(purchaseNotice, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("xodus.library.purchaseProvenance")
                }
                if installed.loading { ProgressView("Loading installed games") }
                if installed.productAccess.checking { ProgressView("Loading your games").controlSize(.small) }
                if visible.isEmpty {
                    if [.owned, .gamePass].contains(filter), accountCollectionIncomplete {
                        ContentUnavailableView {
                            Label(filter == .owned ? "Purchased library unavailable" : "Game Pass library unavailable",
                                  systemImage: "books.vertical")
                        } description: {
                            Text(filter == .owned
                                 ? "Ode to X hasn't loaded a complete current PC collection. This doesn't mean you own no games."
                                 : "Ode to X hasn't loaded a complete current PC collection. Public catalog listings alone don't verify your account's subscription access.")
                        }
                    } else if hiddenUnsupportedCount > 0, !showsUnsupportedGames {
                        ContentUnavailableView {
                            Label("No games verified yet", systemImage: "gamecontroller")
                        } description: {
                            Text("Ode to X 0.1 installs MSIXVC games. Known anti-cheat is not supported. The supported filter shows verified classifications; other games may be untested on Mac.")
                        } actions: {
                            Button("Show unsupported games") { changeScope(filter: filter, showsUnsupported: true) }
                        }
                    } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else if !collection.isEmpty {
                        ContentUnavailableView {
                            Label(filter == .owned ? "No confirmed purchases in this collection"
                                  : "No \(filter.rawValue.lowercased()) games to show", systemImage: "gamecontroller")
                        } description: {
                            Text(filter == .owned
                                 ? "Owned includes purchase or redemption evidence in your loaded PC library, not subscriptions or unidentified acquisition."
                                 : "Try another filter to see the games in your library.")
                        }
                        actions: { Button("Show all games") { filter = .all } }
                    } else if library.accessIsCurrent, library.representedGames.isEmpty,
                              localRecords.isEmpty, !installed.productAccess.checking {
                        ContentUnavailableView {
                            Label("No PC games found", systemImage: "gamecontroller")
                        } description: { Text("Browse Discover to find PC games.") }
                        actions: { Button("Browse games", action: browse) }
                    }
                } else {
                    LazyVGrid(columns: LibraryGridLayout.columns,
                              alignment: .leading, spacing: 30) {
                        ForEach(visible) { game in card(game).id("library-card-\(game.id)") }
                    }
                    .scrollTargetLayout()
                }
                if let error = art.error {
                    Label(error, systemImage: "photo.badge.exclamationmark").font(.callout).foregroundStyle(.secondary)
                }
                if let error = xboxStats.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                }
                if [.all, .installed].contains(filter), !localRecords.filter(isVisible).isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Installed on this Mac").font(.title2.weight(.semibold))
                        LazyVGrid(columns: LibraryGridLayout.columns, alignment: .leading, spacing: 30) {
                            ForEach(localRecords.filter(isVisible)) { game in card(game).id("library-local-\(game.id)") }
                        }
                        .scrollTargetLayout()
                    }
                }
                if showsNativeMinecraft {
                    NativeMinecraftCard {
                        CatalogArtworkView(reference: artworkAllowed ? art.images["9PJ8266BHFWN"]?.cover : nil,
                            status: art.images["9PJ8266BHFWN"]?.cover == nil ? .absent : .available)
                    }.frame(maxWidth: 220)
                }
                }
                }
            }
            .task(id: (heroGames.map(\.id) + collection.map(\.id) + localRecords.map(\.id) + visible.map(\.id))
                .sorted().joined(separator: ",") + ":\(presentationActive)") {
                guard artworkAllowed, presentationActive else { return }
                await art.load(ids: heroGames.map { $0.installed?.storeId ?? $0.id } + collection.map(\.id) + localRecords.compactMap { $0.installed?.storeId }
                    .filter(PCGamesClient.validProductID) + visible.map(\.id).filter(PCGamesClient.validProductID)
                    + ["9PJ8266BHFWN"],
                    market: session.market, language: session.language)
                for game in heroGames {
                    guard !Task.isCancelled else { return }
                    await art.loadDetail(id: game.installed?.storeId ?? game.id, market: session.market, language: session.language)
                }
            }
            .padding(.horizontal, 56).padding(.vertical, 22)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                selection.measureAncestor("content", frame: $0)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            selection.measureAncestor("root", frame: $0)
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
        .onDisappear {
            selection.heroHovered = false
            selection.heroPlaying = false
            selection.localDetail = nil
        }
        .task(id: allowsStartupTasks) { if allowsStartupTasks { await library.loadOnAppear() } }
        .task(id: allowsStartupTasks) {
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
        .task(id: precheckIDs.joined(separator: ",") + ":\(allowsStartupTasks)") {
            guard allowsStartupTasks, !precheckIDs.isEmpty else { return }
            guard !Task.isCancelled else { return }
            operations.precheck(precheckIDs)
        }
    }

    private var heroGames: [LibraryGame] { projection.hero }

    private func recommendable(_ game: LibraryGame) -> Bool {
        let id = game.installed?.storeId ?? game.id
        return LibrarySupportVisibility.issues(productID: id, installed: game.installed != nil,
            packageFormat: game.installed?.packageType?.label ?? art.images[id]?.facts.packageFormat,
            compatibility: operations.compatibility[id]).isEmpty
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
        .focusedValue(\.libraryHeroInteraction, true)
        .modifier(HeroScrollVisibility { heroVisible = $0 })
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onHover { selection.heroHovered = $0 }
        .onChange(of: heroGames.map(\.id), initial: true) { _, ids in
            if selection.heroID.map({ !ids.contains($0) }) ?? true { selection.heroID = ids.first }
        }
        .task(id: "\(heroGames.map(\.id).joined(separator: ",")):\(heroMotionAllowed):\(reduceMotion):\(heroVisible):\(heroInteraction == true):\(voiceOver):\(lowPower)") {
            guard allowsStartupTasks, heroMotionAllowed, heroVisible, !reduceMotion,
                  heroInteraction != true, !voiceOver, !lowPower else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled, !selection.heroHovered, !selection.heroPlaying,
                      heroVisible, heroInteraction != true, heroGames.count > 1 else { continue }
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
                 : game.pc != nil ? "In your library" : "Installed on this Mac")
                .font(.callout.weight(.medium))
            information(id: id)
            if let details = art.images[id]?.detail { GameHeroMetadata(details: details) }
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
        let shown = heroGames + Array(visibleCandidates.prefix(24))
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
                Button("See All") {
                    selection.beginScopeMeasurement(filter: .installed, target: "library-games")
                    withTransaction(Transaction(animation: nil)) {
                        selection.clearScopeExtent()
                        positionCollection("library-games")
                        selection.filter = .installed
                        sort = .recentlyPlayed
                    }
                }
                    .accessibilityLabel("Show installed games by last played")
                Button("Show next recently played game", systemImage: "chevron.right") {
                    let index = continuing.firstIndex { $0.id == selection.recentGameID } ?? 0
                    guard continuing.indices.contains(index + 1) else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                        selection.recentGameID = continuing[index + 1].id
                    }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(continuing.last?.id == selection.recentGameID || continuing.count < 2)
                .help("Scroll to the next recently played game")
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
                            if let facts = projection.byID[game.storeId]?.facts { AccessBadges(facts: facts) }
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
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selection.recentGameID, anchor: .leading)
            .onChange(of: continuing.map(\.id), initial: true) { _, ids in
                if selection.recentGameID.map({ !ids.contains($0) }) ?? true {
                    selection.recentGameID = ids.first
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                selection.measureAncestor("horizontal", frame: $0)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            selection.measureAncestor("lane", frame: $0)
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

    private func information(id: String, compact: Bool = false) -> some View {
        let metadata = art.images[id]?.facts
        let xbox = xboxStats.cache?.games[id]
        let facts = metadata?.genres.isEmpty == false ? metadata :
            xbox.map { LibraryCatalogFacts(genres: $0.genres, capabilities: metadata?.capabilities ?? []) } ?? metadata
        let game = projection.byID[id]
        return LibraryGameInformation(gameFacts: game?.facts ?? GameFacts(),
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
            AccessBadges(facts: game.facts)
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
