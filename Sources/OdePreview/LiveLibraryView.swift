// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import OdeManagement

private struct LibraryHeroFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    fileprivate var libraryHeroInteraction: Bool? {
        get { self[LibraryHeroFocusKey.self] }
        set { self[LibraryHeroFocusKey.self] = newValue }
    }
}

/// Silent, bounded artwork/details retry after a failed load (P0).
enum LibraryArtworkRetry {
    static let delays: [Duration] = [.seconds(3), .seconds(12), .seconds(45)]
}

enum LibraryAccessCopy {
    static let checking = "Checking access…"
}

struct LiveLibraryView: View {
    @ObservedObject var library: PCGamesController
    @ObservedObject var installed: InstalledGamesController
    @ObservedObject var operations: GameOperationsController
    var queue: DownloadQueueController? = nil
    @EnvironmentObject private var session: LiveSession
    let query: String
    var allowsStartupTasks = true
    /// REQ-75: the app's real startup state; tab selection and window focus never change it.
    var startupComplete = true
    @Environment(\.browseTabSelected) private var tabSelected
    var allowsArtworkLoading: Bool? = nil
    var allowsHeroAnimation = true
    let browse: () -> Void
    let recentActivity: () -> Void
    var positionCollection: (String?) -> Void = { _ in }
    @ObservedObject var selection = LibrarySelection()
    @ObservedObject private var art = LibraryCatalogArtwork.shared
    @StateObject private var freeToPlay = GamePassCollections(artwork: .shared,
        keys: [DiscoverGamePassShelf.freeToPlay.rawValue], loadsProductDetails: false)
    @ObservedObject private var xboxStats = LibraryXboxStats.shared
    @ObservedObject private var macEvidence = MacGameEvidenceStore.shared
    @ObservedObject private var nativeMinecraft = NativeMinecraft.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.catalogPresentationActive) private var presentationActive
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @FocusedValue(\.libraryHeroInteraction) private var heroInteraction
    @State private var heroVisible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var detailFocusReturnID: String?
    @FocusState private var focusedGameID: String?
    @AppStorage(LibrarySupportVisibility.preferenceKey)
    private var showsUnsupportedGames = LibrarySupportVisibility.defaultShowsUnsupported
    private var countryUnresolved: Bool { session.hasConfirmedSignIn && !session.accountCountryReady }
    private var artworkAllowed: Bool { !countryUnresolved && (allowsArtworkLoading ?? allowsStartupTasks) }
    private var heroMotionAllowed: Bool { allowsHeroAnimation && selection.localDetail == nil }
    private var filter: LibraryFilter {
        get { countryUnresolved ? .installed : selection.filter }
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
    private var countsNativeMinecraft: Bool {
        showsNativeMinecraft && nativeMinecraft.installation.countsAsInstalled
    }
    private var showsNativeMinecraft: Bool {
        nativeMinecraft.installation.appears(in: filter, query: query)
    }
    private var visibleLocalRecords: [LibraryGame] {
        LibraryGame.uniqueInstalled(LibraryGame.visible(localRecords, query: "", filter: filter, sort: sort).filter(isVisible),
                                    nativeShown: showsNativeMinecraft)
    }
    private var accountCollectionIncomplete: Bool {
        !library.accessIsCurrent || library.snapshot?.isComplete != true
    }
    private var showsLoadingPlaceholders: Bool {
        LibraryLoadingPresentation.showsPlaceholders(
            library: library, loadingInstalled: installed.loading,
            hasUsableContent: hasUsableLibraryContent,
            query: query) && installed.error == nil
    }
    private var hasUsableLibraryContent: Bool {
        !collection.isEmpty || !localRecords.isEmpty
            || (showsNativeMinecraft && [.ready, .repair].contains(nativeMinecraft.installation.state))
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
                // REQ-119: unchecked installed games show now; only Play waits for the access check.
                installed.productAccess.permits($0, account: session.accountHash)
                    || installed.productAccess.pending($0, account: session.accountHash)
            }), launchable: installed.launchableIDs, accessIsCurrent: library.accessIsCurrent,
            metadataRevision: art.revision, compatibility: operations.compatibility,
            filter: filter, sort: sort, showsUnsupported: showsUnsupported,
            gamePassPlanActive: library.gamePassPlanActive,
            denied: Set(installed.games.map(\.storeId).filter {
                !installed.productAccess.permits($0, account: session.accountHash)
                    && !installed.productAccess.pending($0, account: session.accountHash)
            }))
    }

    private func changeScope(filter nextFilter: LibraryFilter, showsUnsupported: Bool) {
        let key = projectionKey(filter: nextFilter, showsUnsupported: showsUnsupported)
        let next = LibraryProjection(key: key,
            isVisible: { showsUnsupported || unsupportedIssues($0).isEmpty }, recommendable: recommendable)
        let targets = LibraryGame.collectionTargets(qualified: next.visible,
            local: LibraryGame.visible(next.local, query: "", filter: nextFilter, sort: sort)
                .filter { showsUnsupported || unsupportedIssues($0).isEmpty },
            native: nativeMinecraft.installation.appears(in: nextFilter, query: query))
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
            }
            VStack(alignment: .leading, spacing: 22) {
                if query.isEmpty, !continuing.isEmpty { continuePlaying }
                if query.isEmpty, !recentlyInstalled.isEmpty { recentlyInstalledShelf }
                GameOperationSlimRow(operations: operations)
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
                if countryUnresolved {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your installed games stay visible. Confirm your account country to browse the catalogue and Game Pass.")
                                .font(.callout).foregroundStyle(.secondary)
                            AccountCountrySettings()
                        }
                    } label: {
                        Label("Account country for browsing", systemImage: "globe")
                    }
                    .accessibilityIdentifier("ode.library.countryNotice")
                } else {
                    PCGamesView(library: library, installed: installed, operations: operations,
                            query: query, allowsStartupTasks: allowsStartupTasks, showsCollection: false,
                            browse: browse, recentActivity: recentActivity)
                }
                VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 0) {
                LibraryControls(count: LibraryGame.displayedCount(
                                    qualified: visible, local: visibleLocalRecords, native: countsNativeMinecraft),
                                hiddenUnsupportedCount: hiddenUnsupportedCount,
                                filter: Binding(get: { filter }, set: { filter = $0 }), sort: $selection.sort,
                                showsUnsupportedGames: Binding(get: { showsUnsupportedGames }, set: {
                                    changeScope(filter: filter, showsUnsupported: $0)
                                }),
                                allowsSorting: true, allowsAccountFilters: !countryUnresolved)
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
                        .accessibilityIdentifier("ode.library.purchaseProvenance")
                }
                if installed.loading { OdeLoadingStatus(title: "Loading installed games") }
                if LibraryLoadingPresentation.showsAccessProgress(
                    checking: installed.productAccess.checking, hasUsableContent: hasUsableLibraryContent) {
                    OdeLoadingStatus(title: "Checking game access")
                }
                if showsLoadingPlaceholders {
                    LibraryLoadingPlaceholders()
                } else if visible.isEmpty && !showsNativeMinecraft && visibleLocalRecords.isEmpty {
                    if [.owned, .gamePass].contains(filter), accountCollectionIncomplete {
                        ContentUnavailableView {
                            Label(filter == .owned ? "Purchased library unavailable" : "Game Pass library unavailable",
                                  systemImage: "books.vertical")
                        } description: {
                            Text(filter == .owned
                                 ? "\(AppBrand.displayName) hasn't loaded a complete current PC collection. This doesn't mean you own no games."
                                 : "\(AppBrand.displayName) hasn't loaded a complete current PC collection. Public catalog listings alone don't verify your account's subscription access.")
                        }
                    } else if hiddenUnsupportedCount > 0, !showsUnsupportedGames {
                        ContentUnavailableView {
                            Label("No games verified yet", systemImage: "gamecontroller")
                        } description: {
                            Text("Some games have known package or anti-cheat blockers. Open game details for compatibility information, or show unsupported games.")
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
                // P0 (owner): missing artwork or details degrade silently and retry; no inline error text.
                if let error = xboxStats.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                }
                if !visibleLocalRecords.isEmpty || showsNativeMinecraft {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Installed games (\(LibraryGame.installedCount(local: visibleLocalRecords, native: countsNativeMinecraft)))")
                            .font(.title2.weight(.semibold))
                        LazyVGrid(columns: LibraryGridLayout.columns, alignment: .leading, spacing: 30) {
                            ForEach(visibleLocalRecords) { game in card(game).id("library-local-\(game.id)") }
                            if showsNativeMinecraft {
                                NativeMinecraftCard {
                                    CatalogArtworkView(reference: artworkAllowed ? art.images["9PJ8266BHFWN"]?.cover : nil,
                                        status: art.images["9PJ8266BHFWN"]?.cover == nil ? .absent : .available)
                                }.id("library-native-minecraft")
                            }
                        }
                        .scrollTargetLayout()
                    }
                }
                }
                }
            }
            .task(id: (heroGames.map(\.id) + collection.map(\.id) + localRecords.map(\.id) + visible.map(\.id))
                .sorted().joined(separator: ",") + ":\(presentationActive)") {
                guard artworkAllowed, presentationActive else { return }
                let ids = heroGames.map { $0.installed?.storeId ?? $0.id } + collection.map(\.id) + localRecords.compactMap { $0.installed?.storeId }
                    .filter(PCGamesClient.validProductID) + visible.map(\.id).filter(PCGamesClient.validProductID)
                    + ["9PJ8266BHFWN"]
                await art.load(ids: ids, market: session.market, language: session.language)
                for delay in LibraryArtworkRetry.delays where art.error != nil {
                    do { try await Task.sleep(for: delay) } catch { return }
                    await art.load(ids: ids, market: session.market, language: session.language, refresh: true)
                }
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
        .gameDetailSheet(item: $selection.localDetail, operations: operations, allowed: startupComplete,
                         accountHash: session.accountHash, onDismiss: {
            restoreDetailFocus()
        }) { entry, reviewInstall in
            if let product = entry.product {
                LiveProductView(product: product, library: library, installedLibrary: installed,
                    operations: operations, installationID: entry.game.id,
                    allowsStartupTasks: startupComplete, allowsArtworkLoading: artworkAllowed,
                    reviewInstall: reviewInstall)
            } else {
                LocalInstalledGameView(game: entry.game, installed: installed, operations: operations)
            }
        }
        .onChange(of: session.selectedProduct) { previous, current in
            guard previous != nil, current == nil else { return }
            restoreDetailFocus()
        }
        .onDisappear {
            selection.heroHovered = false
            selection.heroPlaying = false
            selection.localDetail = nil
        }
        .task(id: "\(allowsStartupTasks):\(session.accountCatalogScope)") {
            guard allowsStartupTasks, session.accountCountryReady else { return }
            await freeToPlay.load(market: session.market, language: session.language)
        }
        .task(id: "\(allowsStartupTasks):\(countryUnresolved)") {
            if allowsStartupTasks && !countryUnresolved { await library.loadOnAppear() }
        }
        .task(id: allowsStartupTasks) {
            guard allowsStartupTasks else { return }
            while !Task.isCancelled {
                await macEvidence.refresh()
                if NSApp.isActive { await installed.refreshNativeInstallationStatuses() }
                await NativeMinecraft.shared.refresh()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .task(id: allowsStartupTasks) {
            guard allowsStartupTasks else { return }
            while !Task.isCancelled {
                await installed.discoverNativeInstallations()
                do { try await Task.sleep(for: .seconds(30)) }
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
            GameHeroAccess(facts: game.heroFacts(cachedAccessAt: library.representedSnapshot?.updatedAt,
                freeToPlay: art.freeToPlayIDs.contains(id)))
            information(id: id, showsAccessBadges: false)
            if let details = art.images[id]?.detail { GameHeroMetadata(details: details) }
        } actions: {
            if !unsupportedIssues(game).isEmpty {
                LibraryCompatibilityIndicators(issues: unsupportedIssues(game), heroStyle: true)
                Button("View game") { open(game) }.modifier(LibraryActionStyle(primary: false))
            } else if let match = game.installed {
                InstalledPlayButton(library: installed, operations: operations, game: match,
                                    displayTitle: game.title, usesGlass: true, heroStyle: true, showsDiagnostics: false)
                InstalledGameActions(library: installed, operations: operations, game: match,
                                     usesGlass: true, heroStyle: true)
            } else {
                let install = (game.pc ?? game.product.map(PCGame.init(product:))).map { pc in
                    GameInstallAction(game: pc, operations: operations,
                        enabled: BrowseGate.installEnabled(startupComplete: startupComplete,
                            canReview: DiscoverBrowse.canReviewInstall(
                                owned: game.pc != nil, accessIsCurrent: library.accessIsCurrent(for: game.id),
                                gamePass: game.gamePass, subscriptionActive: operations.gamePassActive,
                                pcCandidate: true)),
                        showsDiagnostics: false,
                        disabledReason: BrowseGate.installDisabledReason(startupComplete: startupComplete,
                            otherwise: library.installAccessNotice(for: game.id)), queue: queue)
                }
                let blockedReason = install?.heroReplacementReason
                if let install, blockedReason == nil { install }
                Button(blockedReason == nil ? "View game" : "View Details") { open(game) }
                    .modifier(LibraryActionStyle(primary: install != nil && blockedReason != nil))
                if let blockedReason,
                   library.error == nil || blockedReason != library.installAccessNotice(for: game.id) {
                    Label(blockedReason, systemImage: "info.circle")
                        .font(.callout).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ode.library.hero.reason")
                }
                if operations.precheckingProductID == game.id {
                    ProgressView().controlSize(.small).help("Checking whether this game runs on Mac")
                }
            }
        }
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

    private var recentlyInstalled: [InstalledGame] {
        LibraryGame.recentlyInstalled(installed.games)
    }

    /// REQ-66: Recently Installed, ordered by real install-completion dates. Absent without any.
    private var recentlyInstalledShelf: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recently Installed").font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(recentlyInstalled) { game in
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                open(recentGame(game), focusID: "installed-\(game.id)")
                            } label: {
                                LibraryLandscapeView(references: art.images[game.storeId]?.landscape ?? [],
                                                     installed: game, allowsLoading: artworkAllowed)
                                    .frame(width: 260, height: 110).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .focusable(tabSelected)
                            .focused($focusedGameID, equals: "installed-\(game.id)")
                            .focusEffectDisabled()
                            .onKeyPress(.return) {
                                open(recentGame(game), focusID: "installed-\(game.id)")
                                return .handled
                            }
                            .modifier(SearchResultFocusRing(focused: focusedGameID == "installed-\(game.id)"))
                            .accessibilityLabel("View \(game.title)")
                            .contextMenu {
                                Button("View details") { open(recentGame(game), focusID: "installed-\(game.id)") }
                            }
                            Text(game.title).font(.headline).lineLimit(1)
                            if let date = game.installedOn {
                                Text("Installed \(Text(date, style: .relative)) ago")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.frame(width: 260, alignment: .leading)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ode.library.recentlyInstalled")
    }

    private var continuePlaying: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    selection.beginScopeMeasurement(filter: .installed, target: "library-games")
                    withTransaction(Transaction(animation: nil)) {
                        selection.clearScopeExtent()
                        positionCollection("library-games")
                        selection.filter = .installed
                        sort = .recentlyPlayed
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Continue Playing (\(continuing.count))")
                        Image(systemName: "chevron.right").font(.headline)
                    }
                    .font(.title2.weight(.semibold))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ode.library.continuePlaying.showAll")
                .accessibilityLabel("Continue Playing (\(continuing.count))")
                .accessibilityHint("Show installed games by last played")
                .help("Show installed games by last played")
                Spacer()
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

            ContinuePlayingScrollView {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(continuing) { game in
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                open(recentGame(game), focusID: "recent-\(game.id)")
                            } label: {
                                LibraryLandscapeView(references: art.images[game.storeId]?.landscape ?? [],
                                                     installed: game, allowsLoading: artworkAllowed)
                                    .frame(width: 260, height: 110).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .focusable(tabSelected)
                            .focused($focusedGameID, equals: "recent-\(game.id)")
                            .focusEffectDisabled()
                            .onKeyPress(.return) {
                                open(recentGame(game), focusID: "recent-\(game.id)")
                                return .handled
                            }
                            .modifier(SearchResultFocusRing(focused: focusedGameID == "recent-\(game.id)"))
                            .accessibilityLabel("View \(game.title)")
                            .accessibilityHint("Open game details to play")
                            .contextMenu {
                                Button("View details") { open(recentGame(game), focusID: "recent-\(game.id)") }
                            }
                            Text(game.title).font(.headline).lineLimit(1)
                            if let facts = projection.byID[game.storeId]?.facts { AccessBadges(facts: facts) }
                            if let date = game.lastPlayedAt {
                                Text("Last played \(Text(date, style: .relative)) ago")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.frame(width: 260, alignment: .leading).id(game.id)
                    }
                }
                .scrollTargetLayout()
            }
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

    private func recentGame(_ game: InstalledGame) -> LibraryGame {
        (collection + localRecords).first { $0.installed?.id == game.id }
            ?? LibraryGame(id: game.id.uuidString, title: game.title, installed: game,
                           pc: nil, product: nil, owned: false, gamePass: false, accessIsCurrent: false)
    }

    private func open(_ game: LibraryGame, focusID: String? = nil) {
        detailFocusReturnID = nil
        focusedGameID = nil
        do {
            let productID = game.installed?.storeId ?? game.id
            guard PCGamesClient.validProductID(productID) else {
                if let local = game.installed {
                    detailFocusReturnID = focusID ?? game.id
                    selection.localDetail = InstalledGameDetailSelection(game: local, product: nil)
                }
                else { session.errorMessage = "Game details couldn't be opened." }
                return
            }

            let product = try game.product ?? art.images[productID]?.product ??
                LibraryGame.details(id: productID, title: game.title, market: session.market, language: session.language,
                                    source: game.owned ? "AccountPCLibrary:identityOnly" : "LocalInstalledRegistry:identityOnly",
                                    pcCandidate: false)
            if let local = game.installed {
                detailFocusReturnID = focusID ?? game.id
                selection.localDetail = InstalledGameDetailSelection(game: local, product: product)
            } else {
                detailFocusReturnID = focusID ?? game.id
                session.selectedProduct = product
            }
        } catch { session.errorMessage = "Game details couldn't be opened. Your games haven't changed." }
    }

    private func restoreDetailFocus() {
        guard let detailFocusReturnID else { return }
        let available = Set((visible + visibleLocalRecords).map(\.id) + continuing.map { "recent-\($0.id)" }
            + recentlyInstalled.map { "installed-\($0.id)" })
        focusedGameID = GameSearchPresentation.focusReturnTarget(preferred: detailFocusReturnID,
                                                                  available: available)
        self.detailFocusReturnID = nil
    }

    private func information(id: String, compact: Bool = false, showsAccessBadges: Bool = true) -> some View {
        let metadata = art.images[id]?.facts
        let xbox = xboxStats.cache?.games[id]
        let facts = metadata?.genres.isEmpty == false ? metadata :
            xbox.map { LibraryCatalogFacts(genres: $0.genres, capabilities: metadata?.capabilities ?? []) } ?? metadata
        let game = projection.byID[id]
        return LibraryGameInformation(gameFacts: game?.facts ?? GameFacts(),
                                       showsAccessBadges: showsAccessBadges,
                                      facts: facts, xbox: xbox, compact: compact)
    }

    private func card(_ game: LibraryGame) -> some View {
        let artworkID = game.installed?.storeId ?? game.id
        return GameCard(title: game.title, gameFacts: game.facts,
                     compatibilityIssues: unsupportedIssues(game),
                     showsGamePassCatalogBadge: session.gamePassBadgeProductIDs.contains(artworkID),
                     openLabel: "View",
                     focusReturn: ($focusedGameID, game.id),
                     open: { open(game) }) {
            CatalogArtworkView(reference: artworkAllowed ? art.images[artworkID]?.cover ?? game.cover : nil,
                               status: (art.images[artworkID]?.cover ?? game.cover) == nil ? .absent : .available)
        } status: {
            if game.installed != nil, installed.productAccess.pending(artworkID, account: session.accountHash),
               !installed.productAccess.permits(artworkID, account: session.accountHash) {
                Label(LibraryAccessCopy.checking, systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ode.library.card.checkingAccess")
            } else {
                GameCardDownloadStatus(operations: operations, productID: artworkID)
            }
        }
        .contextMenu {
            Button("View details") { open(game) }
            if let match = game.installed {
                InstalledGameManagement(library: installed, operations: operations, game: match)
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: match.folder) }
            }
        }
    }
}

/// QA U3: on Library and Discover home, a running operation is one slim line under the toolbar's
/// download indicator. Full progress and the single Stop control live in Downloads and the game's page.
struct GameOperationSlimRow: View {
    @ObservedObject var operations: GameOperationsController
    static let maximumHeight: CGFloat = 28

    private var line: (title: String, detail: String, fraction: Double?)? {
        if let indicator = operations.downloadIndicator {
            return (indicator.title, indicator.summary, indicator.fraction)
        }
        if operations.installingDirectly { return ("Preparing installation…", "", nil) }
        return nil
    }

    var body: some View {
        if let line {
            HStack(spacing: 10) {
                if let fraction = line.fraction {
                    ProgressView(value: fraction).frame(width: 90)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(line.title).fontWeight(.medium).lineLimit(1)
                if !line.detail.isEmpty {
                    Text(line.detail).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .frame(maxHeight: Self.maximumHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Download progress for \(line.title)")
            .accessibilityValue(line.detail)
            .accessibilityIdentifier("ode.operation.slim")
        } else if let error = operations.error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .help(error)
                .frame(maxHeight: Self.maximumHeight)
                .accessibilityIdentifier("ode.operation.slim.error")
        }
    }
}
