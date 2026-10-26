// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

private struct CatalogPresentationActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var catalogPresentationActive: Bool {
        get { self[CatalogPresentationActiveKey.self] }
        set { self[CatalogPresentationActiveKey.self] = newValue }
    }
}

struct LiveRootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: LiveSession
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchFocused = false
    @FocusState private var discoverSuggestionFocus: DiscoverSearchFocus?
    @State private var libraryScrollCommand = 0
    @State private var libraryContainerSize: CGSize?
    @State private var libraryHasHero = false
    @State private var launchArgumentHandled = false
    @State private var libraryVisited = false
    @State private var discoverVisited = false
    @State private var firstLoad = LibraryFirstLoad()
    @State private var firstScreenArtwork = FirstScreenArtwork()
    @State private var readinessAfterFirstLoad = false
    @ObservedObject private var companion = XboxCompanionController.shared
#if !XODUS_SHIPPING
    var allowsStartupTasks = true
#endif

    private var scopedQuery: String { state.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var toolbarOverArtwork: Bool {
        immersiveDestination && (state.destination != .library || libraryHasHero)
    }
    private var requiresSignIn: Bool {
#if !XODUS_SHIPPING
        if CommandLine.arguments.contains("--export-live") || PreviewExporter.liveDataRequested
            || LibraryPreviewExporter.requested { return false }
#endif
        return !session.hasConfirmedSignIn
    }
    private var accountRecoveryAllowed: Bool { startupAllowed && session.hasConfirmedSignIn }
    private var unifiedAccountMode: Bool { session.supports(.odeAccountRead) }
    private var boundAccountHash: String? {
        guard accountRecoveryAllowed, !state.installedGames.accountDisconnecting else { return nil }
        if unifiedAccountMode {
            return session.accountHash
        }
        guard state.pcGames.accessIsCurrent else { return nil }
        return XboxAccountBinding.matching(application: session.accountHash,
            library: state.pcGames.accountHash, service: state.gameOperations.serviceStatus)
    }
    private var profileBootstrapBinding: String? {
        if unifiedAccountMode { return boundAccountHash }
        return session.accountBusy || state.gameOperations.serviceBusy ? nil : boundAccountHash
    }
    private var toolbarProfile: XboxProfile? {
        companion.cache?.toolbarProfile(for: boundAccountHash)
    }
    private var canImportGame: Bool {
        state.installedGames.loaded && !state.installedGames.editing
            && !state.installedGames.choosing && !state.installedGames.mutationActive
    }
    private var unifiedAccountVerified: Bool {
        if unifiedAccountMode {
            return boundAccountHash != nil && session.nativeLifecycleConfiguration != nil
        }
        return companion.cache?.confirmsAccount(boundAccountHash) == true
    }
    private var accountBindingMismatch: Bool {
        let values = [session.accountHash, state.pcGames.accountHash,
                      state.gameOperations.serviceStatus?.accountHash].compactMap { $0 }
        return values.count >= 2 && Set(values).count > 1
    }
    private var requiresAccountGate: Bool { unifiedAccountMode ? requiresSignIn : !unifiedAccountVerified }
    private var accountContentAllowed: Bool { startupAllowed && (unifiedAccountMode ? !requiresSignIn : unifiedAccountVerified) }
    private var heroAnimationAllowed: Bool {
        startupAllowed && !state.showingAccount && session.selectedProduct == nil
            && !session.signInPending && state.gameOperations.installConsent == nil
            && state.gameOperations.uninstallConsent == nil
            && !state.gameOperations.preparingConsent
            && state.installedGames.runningGameID == nil
            && !state.installedGames.mutationActive
    }
    private var startupAllowed: Bool {
#if XODUS_SHIPPING
        true
#else
        allowsStartupTasks && !CommandLine.arguments.contains("--export-live") &&
            !PreviewExporter.liveDataRequested && !LibraryPreviewExporter.requested
#endif
    }
    private var searchEnabled: Bool {
        !requiresAccountGate && !firstLoadCovers
    }
    /// REQ-119: this run's own sign-in just finished and there's no library to show yet.
    private var coldSignInPending: Bool {
        startupAllowed && LibraryFirstLoad.shouldBegin(interactiveSignIn: state.unifiedSignInRequested,
            signedIn: session.hasConfirmedSignIn, hasLibrary: !state.pcGames.representedGames.isEmpty)
    }
    private var firstLoadCovers: Bool { firstLoad.covers || coldSignInPending }
    private var firstScreenGames: [(id: String, cover: CatalogArtworkReference?)] {
        let projection = state.librarySelection.projection.current
        var seen = Set<String>()
        let games = (projection.hero + projection.visible).filter { seen.insert($0.id).inserted }
            .prefix(LibraryFirstLoad.firstScreenSize).map { (id: $0.installed?.storeId ?? $0.id, cover: $0.cover) }
        guard games.isEmpty else { return games }
        return state.pcGames.representedGames.prefix(LibraryFirstLoad.firstScreenSize).map { (id: $0.id, cover: $0.artwork) }
    }
    private var firstLoadInputs: LibraryFirstLoadInputs {
        let library = state.pcGames
        return LibraryFirstLoadInputs(
            signedIn: session.hasConfirmedSignIn, loading: library.busy || library.restoringPresence,
            gamesFound: library.representedGames.count,
            libraryComplete: library.snapshot != nil && !library.busy, error: library.error,
            needsAccountAction: library.needsSignIn || library.needsKeychainApproval
                || (library.error != nil && !session.accountCountryReady),
            artworkTotal: firstScreenArtwork.total, artworkReady: firstScreenArtwork.ready,
            artworkSettled: firstScreenArtwork.settled)
    }
    private var firstLoadArtworkKey: String {
        guard firstLoad.covers, LibraryFirstLoad.gamesReady(firstLoadInputs) else { return "idle" }
        return firstScreenGames.map(\.id).joined(separator: ",")
    }
    private var libraryArtworkAllowed: Bool {
#if XODUS_SHIPPING
        startupAllowed && session.accountCountryReady
#else
        (startupAllowed && session.accountCountryReady) || LibraryPreviewExporter.requested
#endif
    }
    private var searchPlaceholder: String {
        "Search all games"
    }
    private var refreshHelp: String {
        if state.destination == .discover {
            return session.discoveryCheckedAt.map { "Refresh Discover - checked \($0)" } ?? "Refresh Discover"
        }
        guard let snapshot = state.pcGames.snapshot else { return "Refresh Library" }
        let age = snapshot.updatedAt.formatted(.relative(presentation: .named))
        return "Refresh Library - updated \(age)"
    }

    private static let pendingFirstLoad: LibraryFirstLoad = {
        var value = LibraryFirstLoad()
        value.begin(at: .now)
        return value
    }()

    private func applyFirstLoad(_ change: (inout LibraryFirstLoad) -> Void) {
        let old = firstLoad
        change(&firstLoad)
        guard old != firstLoad else { return }
        if let text = LibraryFirstLoad.announcement(from: old, to: firstLoad) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        if case .finished(let handover) = firstLoad.phase {
            FirstLoadTimeline.mark("handover", "reason=\(handover)")
        }
    }

    /// Fetches the first screen's covers while the overlay shows, so the library opens with artwork.
    private func prefetchFirstScreenArtwork() async {
        let games = firstScreenGames
        firstScreenArtwork = FirstScreenArtwork()
        await LibraryCatalogArtwork.shared.load(ids: games.map(\.id).filter(PCGamesClient.validProductID),
                                                market: session.market, language: session.language)
        guard !Task.isCancelled else { return }
        let references = games.compactMap { LibraryCatalogArtwork.shared.images[$0.id]?.cover ?? $0.cover }
        firstScreenArtwork.total = references.count
        let reads = references.map { reference in
            Task { (try? await CatalogArtworkStore.shared.image(for: reference, bucket: .card)) != nil }
        }
        for read in reads {
            guard !Task.isCancelled else {
                reads.forEach { $0.cancel() }
                return
            }
            let loaded = await read.value
            firstScreenArtwork.ready += 1
            if loaded { FirstLoadTimeline.mark("firstArtwork") }
        }
        guard !Task.isCancelled else { return }
        firstScreenArtwork.settled = true
        FirstLoadTimeline.mark("firstScreenArtwork", "ready=\(firstScreenArtwork.ready) of=\(firstScreenArtwork.total)")
    }

    var body: some View {
        ScrollViewReader { proxy in
        Group {
            if requiresAccountGate {
                OdeStartupBackdrop()
                    .accessibilityIdentifier("xodus.welcome.background")
            } else if session.hasConfirmedSignIn, !session.accountCountryReady,
                      state.destination == .discover {
                Form {
                    Section("Account country") { AccountCountrySettings() }
                }
                .formStyle(.grouped)
                .accessibilityIdentifier("xodus.account.countryRequired")
            } else {
                ZStack {
                    if libraryVisited || state.destination == .library {
                        retainedBrowse(.library)
                    }
                    if discoverVisited || state.destination == .discover {
                        retainedBrowse(.discover)
                    }
                    if state.destination == .downloads {
                        LiveActivityView(operations: state.gameOperations, queue: state.downloadQueue,
                                         browseGames: { state.navigate(.discover) },
                                         resolveGame: { id in state.pcGames.representedGames.first { $0.id == id } })
                    }
                }
                .id("\(session.accountHash ?? ""):\(session.market):\(session.language)")
            }
        }
        .overlay {
            if firstLoadCovers {
                LibraryFirstLoadView(state: firstLoad.covers ? firstLoad : Self.pendingFirstLoad,
                                     inputs: firstLoadInputs,
                                     showNow: { applyFirstLoad { $0.showLibraryNow() } },
                                     tryAgain: {
                                         applyFirstLoad { $0.retry(at: .now) }
                                         Task { await state.pcGames.retryLibraryLoad() }
                                     })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: firstLoadCovers)
        .onChange(of: firstLoadInputs, initial: true) { _, inputs in
            applyFirstLoad { $0.update(inputs, now: .now) }
        }
        .onChange(of: firstLoadCovers) { _, covering in
            guard !covering, readinessAfterFirstLoad else { return }
            readinessAfterFirstLoad = false
            if session.hasConfirmedSignIn { state.showingReadiness = true }
        }
        .task(id: firstLoad.startedAt) {
            guard firstLoad.covers else { return }
            do { try await Task.sleep(for: LibraryFirstLoad.slowAfter) } catch { return }
            applyFirstLoad { $0.update(firstLoadInputs, now: .now) }
        }
        .task(id: firstLoadArtworkKey) {
            guard firstLoadArtworkKey != "idle", libraryArtworkAllowed else { return }
            await prefetchFirstScreenArtwork()
        }
        .onChange(of: state.destination, initial: true) { _, destination in
            if destination == .library { libraryVisited = true }
            if destination == .discover { discoverVisited = true }
        }
        .toolbar { rootToolbar }
        .onAppear {
#if !XODUS_SHIPPING
            PreviewExporter.startIfRequested(state: state, session: session)
            LibraryPreviewExporter.start(state: state, session: session)
#endif
        }
        .onReceive(state.pcGames.objectWillChange) { _ in state.objectWillChange.send() }
        .onPreferenceChange(LibraryHeroPresenceKey.self) { libraryHasHero = $0 }
        .onReceive(state.gameOperations.objectWillChange) { _ in state.objectWillChange.send() }
        .onReceive(state.installedGames.objectWillChange) { _ in state.objectWillChange.send() }
#if !XODUS_SHIPPING
        .onReceive(LibraryPreviewExporter.presentation.$showGrid) { show in
            if show { proxy.scrollTo("library-games", anchor: .top) }
        }
#endif
        .task {
            if startupAllowed {
                if UserDefaults.standard.bool(forKey: "Xodus.localNetwork.requestOnce") {
                    UserDefaults.standard.removeObject(forKey: "Xodus.localNetwork.requestOnce")
                    LocalNetworkDiscovery.shared.search()
                }
                await state.runtimeSettings.refreshCrossOverDependency()
            }
        }
        .task(id: "\(startupAllowed):\(session.isReady):\(unifiedAccountMode)") {
            guard startupAllowed, session.isReady,
                  state.configureUnifiedAccountMode(session: session) else { return }
            companion.useUnifiedAccount(session)
        }
        .task(id: accountRecoveryAllowed) {
            if accountRecoveryAllowed {
                if unifiedAccountMode {
                    state.configureUnifiedAccountMode(session: session)
                    companion.useUnifiedAccount(session)
                }
                await state.installedGames.load()
                async let collectionLoad: Void = state.pcGames.loadOnAppear()
                await state.installedGames.discoverNativeInstallations()
                await state.gameOperations.restore()
                await collectionLoad
                if unifiedAccountMode {
                    await state.pcGames.waitForLoad()
                    await companion.refresh(for: nil)
                    if session.nativeLifecycleConfiguration == nil { await session.prepareUnifiedRuntime() }
                    return
                }
                await state.gameOperations.loadGamePassCache()
                state.gameOperations.checkSetupOnce()
                state.gameOperations.refreshService()
                await state.gameOperations.waitForService()
            }
        }
        .task(id: profileBootstrapBinding) {
            guard profileBootstrapBinding != nil else { return }
            await companion.refresh(for: state.gameOperations.serviceStatus)
        }
        .task(id: session.accountCatalogScope) {
            guard startupAllowed, unifiedAccountMode else { return }
            state.librarySelection.projection.clear(to: .empty)
            state.discoverSelection.clear()
            await state.pcGames.retireUnifiedAccount()
            guard !Task.isCancelled, session.accountCountryReady else { return }
            await state.pcGames.refreshInBackground()
            if session.nativeLifecycleConfiguration == nil { await session.prepareUnifiedRuntime() }
        }
        .task(id: "\(unifiedAccountVerified):\(state.installedGames.loaded):\(state.installedGames.editing):\(state.installedGames.games.count)") {
            guard startupAllowed, !launchArgumentHandled, unifiedAccountVerified,
                  state.installedGames.loaded, !state.installedGames.editing,
                  let action = GameLaunchArguments.parse(Array(CommandLine.arguments.dropFirst())) else { return }
            launchArgumentHandled = true
            switch action {
            case .nativeMinecraft:
                await NativeMinecraft.shared.refresh()
                NativeMinecraft.shared.open()
            case .play(let productID):
                guard let game = state.installedGames.games.first(where: { $0.storeId == productID }) else {
                    session.errorMessage = "The requested game isn't registered as installed on this Mac."
                    return
                }
                await state.installedGames.play(game)
                if state.installedGames.runningGameID != game.id {
                    session.errorMessage = state.installedGames.playErrors[game.id]
                        ?? "The requested game couldn't start. Check its installation and runtime settings."
                }
            }
        }
        .task(id: unifiedAccountVerified) {
            state.installedGames.setAccountAccessAllowed(unifiedAccountVerified,
                message: "Your Xbox Live account is being checked. Try again when it finishes.")
        }
        .task(id: "\(session.accountCatalogScope):\(unifiedAccountVerified):\(state.installedGames.games.map(\.storeId).sorted().joined(separator: ","))") {
            guard startupAllowed, unifiedAccountMode else { return }
            while !Task.isCancelled {
                await state.installedGames.productAccess.refresh(session: session,
                    installedIDs: state.installedGames.games.map(\.storeId))
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
        .onReceive(state.installedGames.$games) { games in
            guard startupAllowed, unifiedAccountMode else { return }
            Task {
                await state.installedGames.productAccess.refresh(session: session,
                    installedIDs: games.map(\.storeId))
            }
        }
        .task(id: "\(session.accountHash ?? ""):\(state.pcGames.accountHash ?? ""):\(state.gameOperations.serviceStatus?.accountHash ?? "")") {
            guard accountBindingMismatch else { return }
            state.installedGames.setAccountAccessAllowed(false,
                message: "Account identity changed. Sign in again before accessing games.")
            companion.invalidateBinding()
            LibraryXboxStats.shared.invalidateBinding()
            _ = await state.signOut(session: session)
        }
        .task(id: "\(scenePhase == .active):\(session.hasConfirmedSignIn)") {
            if startupAllowed, scenePhase == .active {
                if accountContentAllowed { await refreshXboxStats() }
                await state.runtimeSettings.refreshCrossOverDependency()
            }
        }
        .task(id: scenePhase == .active) {
            if startupAllowed, scenePhase == .active {
                await session.revalidateAccountOnForeground()
                await state.pcGames.refreshInBackground()
                await state.installedGames.productAccess.refresh(session: session,
                    installedIDs: state.installedGames.games.map(\.storeId))
            }
        }
        .task(id: "\(session.hasConfirmedSignIn):\(state.gameOperations.serviceStatus?.accountHash ?? ""):\(state.gameOperations.serviceStatus?.signedIn == true):\(state.gameOperations.serviceSigningIn)") {
            let accessMessage: String
            if unifiedAccountMode {
                accessMessage = "Your Xbox account and game connection need to match. Check Account and refresh your library."
            } else if !session.hasConfirmedSignIn {
                accessMessage = "Sign in with Microsoft to play this game."
            } else if !state.pcGames.hasSavedSignIn || state.pcGames.needsSignIn {
                accessMessage = "Reconnect your Xbox library to play this game."
            } else if state.gameOperations.serviceStatus?.serviceRunning != true {
                accessMessage = "Xbox services are reconnecting automatically."
            } else {
                accessMessage = "Sign in to Xbox services to play this game."
            }
            state.installedGames.setAccountAccessAllowed(
                unifiedAccountVerified,
                message: accessMessage
            )
            if accountContentAllowed, !unifiedAccountMode {
                await LibraryXboxStats.shared.refresh(for: state.gameOperations.serviceStatus,
                    signingIn: state.gameOperations.serviceSigningIn)
                await XboxCompanionController.shared.refresh(
                    for: state.gameOperations.serviceSigningIn ? nil : state.gameOperations.serviceStatus)
            }
        }
        .task {
            if startupAllowed { await session.prepareWelcome() }
        }
        .task(id: "\(accountContentAllowed):\(state.destination.rawValue):\(state.showsRecentActivity):\(scenePhase == .active):\(session.isReady):\(session.connectionTransitioning):\(session.accountBusy)") {
            guard accountContentAllowed, scenePhase == .active else { return }
            await state.loadRecentActivityIfVisible(session: session)
        }
        .task(id: "\(accountContentAllowed):\(state.destination.rawValue):\(state.query):\(session.market):\(session.language):\(session.isReady)") {
            guard accountContentAllowed, session.accountCountryReady, state.destination == .discover else { return }
            await session.loadCatalogAfterInput(state.query)
        }
        .task(id: "\(accountContentAllowed):\(session.isReady):\(session.market):\(session.language)") {
            guard accountContentAllowed, session.accountCountryReady, session.isReady, state.destination == .library,
                  state.query.isEmpty, session.catalogMatches(query: "") else { return }
            await session.loadCatalogOnEntry("")
            guard !Task.isCancelled, session.catalogMatches(query: "") else { return }
            await LibraryCatalogArtwork.shared.load(ids: Array(session.products.prefix(16).map(\.id)),
                market: session.market, language: session.language)
        }
        .onChange(of: session.hasConfirmedSignIn) { _, confirmed in
            if confirmed {
                FirstLoadTimeline.begin(state.unifiedSignInRequested ? "interactive" : "restored")
                if coldSignInPending {
                    firstScreenArtwork = FirstScreenArtwork()
                    applyFirstLoad { $0.begin(at: .now) }
                    readinessAfterFirstLoad = true
                }
            } else {
                firstLoad = LibraryFirstLoad()
                readinessAfterFirstLoad = false
            }
            if confirmed, state.consumeUnifiedSignInRequest() {
                if !unifiedAccountMode { Task { await state.refreshGameServiceStatusAfterSignIn() } }
            } else if !confirmed {
                state.librarySelection.projection.clear(to: .empty)
                state.discoverSelection.clear()
                if unifiedAccountMode {
                    companion.invalidateBinding()
                    state.installedGames.productAccess.retire()
                    Task { await state.pcGames.retireUnifiedAccount() }
                }
                state.installedGames.setAccountAccessAllowed(false)
                session.selectedProduct = nil
                state.showingAccount = false
                state.showingSetup = false
                state.showingReadiness = false
                state.accountDestination = .account
            }
        }
        .sheet(isPresented: Binding(get: { requiresAccountGate || state.showingAccount
                                        || (state.showingReadiness && !firstLoadCovers) },
                                    set: { presented in
                                        if !presented { state.showingReadiness = false }
                                        state.showingAccount = !requiresAccountGate && presented
                                    }), onDismiss: {
            state.showingSetup = false
            state.showingReadiness = false
            state.accountDestination = .account
        }) {
            if requiresSignIn {
                LiveWelcomeView(session: session, runtime: state.runtimeSettings, operations: state.gameOperations)
                    .background {
                        WelcomeSheetTerminationBridge()
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            } else if state.showingReadiness, !state.showingAccount {
                ReadinessChecklistView(session: session, installed: state.installedGames,
                                       allowsStatusReads: startupAllowed,
                                       openSettingsPane: { pane in
                                           SettingsPaneSelection.select(pane)
                                           state.showingReadiness = false
                                           openSettings()
                                       }, done: { state.showingReadiness = false },
                                       calimochoInstaller: state.calimochoInstaller)
            } else {
#if !XODUS_SHIPPING
            LiveAccountView(refreshStatusOnAppear: !PreviewExporter.liveDataRequested)
#else
            LiveAccountView()
#endif
            }
        }
        .gameDetailSheet(item: $session.selectedProduct, operations: state.gameOperations,
                         allowed: startupAllowed, accountHash: session.accountHash) { product, reviewInstall in
            LiveProductView(product: product, library: state.pcGames,
                            installedLibrary: state.installedGames, operations: state.gameOperations,
                            allowsStartupTasks: startupAllowed, allowsArtworkLoading: libraryArtworkAllowed,
                            reviewInstall: reviewInstall)
        }
        .background {
            if !requiresSignIn { GameOperationPresentation(operations: state.gameOperations) }
        }
        .onChange(of: state.searchFocusRequest) { _, _ in
            guard searchEnabled else { return }
            searchFocused = true
        }
        .focusedSceneValue(\.gameSearchFocus, GameSearchFocus { state.requestSearchFocus() })
        }
    }

    private func refreshXboxStats() async {
        guard accountContentAllowed else { return }
        if unifiedAccountMode {
            await state.pcGames.waitForLoad()
            await companion.refresh(for: nil)
            return
        }
        state.gameOperations.refreshService()
        await state.gameOperations.waitForService()
        await LibraryXboxStats.shared.refresh(for: state.gameOperations.serviceStatus,
            signingIn: state.gameOperations.serviceSigningIn)
    }

    @ToolbarContentBuilder
    private var rootToolbar: some ToolbarContent {
        if !requiresAccountGate {
            XodusToolbar(selection: state.navigationSelection, searchText: $state.query,
                         searchFocused: Binding(get: { searchFocused }, set: { searchFocused = $0 }),
                         searchPlaceholder: searchPlaceholder, searchEnabled: searchEnabled,
                         accountLabel: session.accountLabel,
                         accountSymbol: session.accountSymbol,
                         accountArtwork: XboxCompanionArtwork.reference(toolbarProfile?.avatarURL),
                         accountBinding: boundAccountHash,
                         profileLoading: companion.refreshing,
                         profileFailed: companion.error != nil,
                         importGame: state.destination == .library && !state.showsRecentActivity
                            ? { Task { await state.installedGames.chooseGame() } } : nil,
                         importEnabled: canImportGame,
                         libraryContrast: toolbarOverArtwork, openSearch: {
                             state.navigate(.discover)
                         }, showSearchResults: showToolbarSearchResults,
                         recentSearchesPresented: Binding(get: { showsDiscoverRecentSearches },
                             set: { presented in
                                 if !presented { dismissDiscoverRecentSearches() }
                             }),
                         recentSearchesContent: AnyView(DiscoverRecentSearches(
                            selection: state.discoverSelection,
                            focused: $discoverSuggestionFocus,
                            select: selectRecentSearch,
                            dismiss: dismissDiscoverRecentSearches))) {
                state.openAccount()
            }
            ToolbarItem(placement: .primaryAction) {
                GameDownloadToolbarIndicator(operations: state.gameOperations)
            }
            if state.destination == .discover {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh Discover", systemImage: "arrow.clockwise") {
                        Task { await session.refreshCatalog(state.query) }
                    }
                    .labelStyle(.iconOnly).help(refreshHelp)
                    .modifier(NativeToolbarIconStyle())
                    .disabled(!startupAllowed || !session.isReady || session.searching)
                    .accessibilityIdentifier("xodus.catalog.refresh")
                    .padding(.trailing, 12)
                }
            }
        }
    }

    private var immersiveDestination: Bool {
        (state.destination == .library && !state.showsRecentActivity) || state.destination == .discover
    }

    private var showsDiscoverRecentSearches: Bool {
        state.destination == .discover
            && DiscoverSearchOverlayLayout.isPresented(searchFocused: searchFocused,
            suggestionFocused: discoverSuggestionFocus != nil, query: scopedQuery,
            searches: state.discoverSelection.recentSearches)
    }

    private func showToolbarSearchResults() {
        state.navigate(.discover)
        if accountContentAllowed, session.accountCountryReady, !scopedQuery.isEmpty {
            let query = scopedQuery
            Task { await session.loadCatalogOnEntry(query) }
        }
        searchFocused = false
        if let focus = DiscoverSearchOverlayLayout.keyboardFocus(
            query: state.query, searches: state.discoverSelection.recentSearches) {
            discoverSuggestionFocus = focus
        } else {
            state.discoverSelection.focusRequest += 1
        }
    }

    private func selectRecentSearch(_ query: String) {
        state.query = query
        discoverSuggestionFocus = nil
        searchFocused = true
    }

    private func dismissDiscoverRecentSearches() {
        discoverSuggestionFocus = nil
        searchFocused = false
    }

    private func retainedBrowse(_ destination: Destination) -> some View {
        let selected = state.destination == destination
        let active = selected && scenePhase == .active
        let immersive = destination == .discover || !state.showsRecentActivity
        let scrollID = Binding<String?>(get: {
            _ = libraryScrollCommand
            return destination == .library ? state.librarySelection.scrollID : state.discoverSelection.scrollID
        }, set: { value in
            if destination == .library { state.librarySelection.scrollID = value }
            else { state.discoverSelection.scrollID = value }
        })
        return ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if destination == .library {
                        library(positionCollection: { target in
                            state.librarySelection.scrollID = target
                            libraryScrollCommand += 1
                        })
                    } else { catalog }
                }
                .padding(immersive ? 0 : 30)
                .frame(minHeight: destination == .library ? libraryContainerSize.flatMap {
                    state.librarySelection.scopeMinimumHeight(viewport: $0)
                } : nil,
                       alignment: .top)
            }
            .scrollPosition(id: scrollID)
            .scrollIndicators(destination == .discover ? .never : .automatic)
            .modifier(LibraryScrollMeasurementObserver(
                selection: destination == .library ? state.librarySelection : nil,
                containerSize: $libraryContainerSize))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                if destination == .library { state.librarySelection.measureScrollFrame($0) }
            }
            .onGeometryChange(for: CGRect.self) {
                let frame = $0.frame(in: .global)
                return CGRect(x: frame.minX, y: frame.minY + $0.safeAreaInsets.top,
                              width: frame.width,
                              height: max(0, frame.height - $0.safeAreaInsets.top - $0.safeAreaInsets.bottom))
            } action: {
                if destination == .library { state.librarySelection.collectionViewportFrame = $0 }
            }

            .modifier(LibraryScrollEdge(enabled: immersive))
            .modifier(LibraryImmersion(enabled: immersive,
                                      underlapsToolbar: destination == .discover
                                        ? !state.gameOperations.hasDownloadStatus : libraryHasHero))
            .background(Color(nsColor: .windowBackgroundColor))
        .modifier(LibraryActionExtentObserver(selection: state.librarySelection) {
            if destination == .library { libraryScrollCommand += 1 }
        })
        .environment(\.catalogPresentationActive, active)
        .opacity(selected ? 1 : 0)
        .zIndex(selected ? 1 : 0)
        .allowsHitTesting(selected)
        .disabled(!selected)
        .accessibilityHidden(!selected)
    }

    private struct LibraryScrollMeasurementObserver: ViewModifier {
        let selection: LibrarySelection?
        @Binding var containerSize: CGSize?

        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 15, *), let selection {
                content.onScrollGeometryChange(for: LibraryScrollMeasurement.self) { geometry in
                    LibraryScrollMeasurement(offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height, containerHeight: geometry.containerSize.height,
                        containerWidth: geometry.containerSize.width,
                        insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom,
                        visibleY: geometry.visibleRect.minY, visibleMaxY: geometry.visibleRect.maxY,
                        visibleHeight: geometry.visibleRect.height)
                } action: { _, value in
                    selection.measureScroll(value)
                    let size = CGSize(width: value.containerWidth, height: value.containerHeight)
                    if containerSize != size { containerSize = size }
                }
                .onScrollPhaseChange { oldPhase, newPhase in
                    if newPhase == .idle, oldPhase == .interacting || oldPhase == .decelerating {
                        selection.finishedUserScroll()
                    }
                }
            } else {
                content
            }
        }
    }

    private func library(positionCollection: @escaping (String?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if state.showsRecentActivity {
                Button("Back to Library", systemImage: "chevron.left") { state.navigate(.library) }
                    .accessibilityIdentifier("xodus.library.back")
                LiveRecentLibraryView(query: scopedQuery,
                                      openAccount: { state.openAccount() },
                                      findInStore: { state.findInStore($0, session: session) })
                    .accessibilityIdentifier("xodus.library.recentActivity")
            } else {
                LiveLibraryView(library: state.pcGames, installed: state.installedGames,
                                operations: state.gameOperations,
                                query: state.query(for: .library).trimmingCharacters(in: .whitespacesAndNewlines),
                                allowsStartupTasks: startupAllowed && state.destination == .library && scenePhase == .active,
                                allowsArtworkLoading: libraryArtworkAllowed,
                                allowsHeroAnimation: heroAnimationAllowed && state.destination == .library && scenePhase == .active,
                                browse: { state.navigate(.discover) },
                                recentActivity: { state.openRecentActivity() },
                                positionCollection: positionCollection,
                                selection: state.librarySelection)
            }
        }
    }

    private var selectedFolderInspection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Inspect a game folder") { session.chooseInstallationFolder() }
                    .disabled(!session.isReady || !session.supports(.inspectInstallation) || session.inspectionBusy)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Inspect a game folder")
                    .accessibilityIdentifier("xodus.library.inspectFolder")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { session.chooseInstallationFolder() }
                if session.inspectionBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Inspecting installation")
                }
                Spacer()
            }
            Text(session.supports(.inspectInstallation)
                 ? "Choose a folder to check for an existing installation marker."
                 : "This build can't inspect a selected game folder.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.inspectionError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let inspection = session.inspection {
                LabeledContent("Selected folder",
                               value: URL(fileURLWithPath: inspection.directory).lastPathComponent)
                Text("An external installation marker was observed. Retail identity, game-file integrity, access and compatibility remain unknown. No registered entry was created; this game cannot be launched from this result.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Selected folder info") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Container header version", value: inspection.marker.observedPackageVersion)
                        LabeledContent("Marker file",
                                       value: ByteCountFormatter.string(fromByteCount: Int64(inspection.marker.bytes),
                                                                        countStyle: .file))
                        Text("Container ID: \(inspection.marker.contentID)")
                        Text("Header GUID: \(inspection.marker.headerProductGUID)")
                        Text("Header PDUID: \(inspection.marker.headerPDUID)")
                        Text("These header identifiers are not Microsoft Store product, edition or package identities. The metadata digest is not full game integrity.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption).textSelection(.enabled)
                }
            }
        }
    }
    private var catalog: some View {
        LiveCatalogView(library: state.pcGames, installed: state.installedGames,
                        operations: state.gameOperations,
                        query: state.query(for: .discover).trimmingCharacters(in: .whitespacesAndNewlines),
                        allowsArtworkLoading: libraryArtworkAllowed,
                        allowsStartupTasks: startupAllowed && state.destination == .discover && scenePhase == .active,
                        allowsHeroAnimation: heroAnimationAllowed && state.destination == .discover && scenePhase == .active,
                        clearSearch: { state.query = "" }, selection: state.discoverSelection,
                        searchLibrary: { query in
                            state.navigate(.library)
                            state.query = query
                            state.librarySelection.filter = .all
                        },
                        selectSearch: { query in state.query = query },
                        returnToSearch: { searchFocused = true })
    }
}

struct LiveActivityView: View {
    static func loadArtwork(productID: String?, session: LiveSession, artwork: LibraryCatalogArtwork) async {
        guard session.accountCountryReady, let productID else { return }
        await artwork.load(ids: [productID], market: session.market, language: session.language)
    }
    @ObservedObject var operations: GameOperationsController
    @ObservedObject var queue: DownloadQueueController
    var browseGames: () -> Void = {}
    var resolveGame: (String) -> PCGame? = { _ in nil }
    @EnvironmentObject private var session: LiveSession
    @ObservedObject private var artwork = LibraryCatalogArtwork.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.largeTitle.bold())
                Spacer()
                Button("Refresh activity") {
                    Task { await session.refreshActivity() }
                }.disabled(!session.supports(.jobs) || session.activity.isReconciling)
            }
            .padding(.horizontal, 30).padding(.vertical, 24)
            List {
                DownloadQueueView(queue: queue)
                StoppedDownloadsSection(operations: operations, resolveGame: resolveGame)
                if operations.installingDirectly {
                    Section("Current") { GameOperationProgressView(operations: operations) }
                }
                if let operation = operations.operation {
                    Section("Current") {
                        HStack(alignment: .top, spacing: 16) {
                            CatalogArtworkView(reference: artwork.images[operation.productID]?.cover,
                                               status: artwork.images[operation.productID]?.cover == nil
                                                   ? .absent : .available)
                                .frame(width: 64, height: 96).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityHidden(true)
                            GameOperationProgressView(operations: operations)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 8)
                    }
                }
                if operations.operation == nil, let error = operations.error {
                    Section {
                        ContentUnavailableView {
                            Label("Download stopped", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            if operations.log != nil {
                                Button("Show log") { operations.showLog() }
                            }
                        }
                    }
                }
                if let notice = operations.notice {
                    Section {
                        Label(notice, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("xodus.install.result")
                    }
                }
                if let notice = session.activityNotice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if session.activity.needsSnapshot && !session.activity.jobs.isEmpty {
                    Section {
                        Label("Refresh activity before changing a check.",
                              systemImage: "arrow.clockwise").foregroundStyle(.secondary)
                    }
                }
                if session.activity.jobs.isEmpty && !operations.hasDownloadStatus && queue.jobs.isEmpty
                    && operations.resumableInstallations.isEmpty {
                    ContentUnavailableView {
                        Label("No downloads", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Install a game from Library or Discover. Download progress and cancellation appear here once an installation starts.")
                    } actions: {
                        Button("Browse games", action: browseGames)
                            .accessibilityIdentifier("xodus.downloads.browse")
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .listRowBackground(Color.clear)
                }
                if !session.activity.jobs.isEmpty {
                    Section("Recent game checks") {
                        ForEach(session.activity.jobs) { job in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 14) {
                                    Image(systemName: job.state == .completed
                                          ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                                        .font(.title2).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.activityTitle(job)).font(.headline)
                                        Text("Package check").font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(job.state.rawValue.capitalized).foregroundStyle(.secondary)
                                }
                                HStack {
                                    if !job.state.isTerminal, session.supports(.cancel) {
                                        Button("Cancel") { Task { await session.changeJob(job, command: .cancel) } }
                                            .disabled(session.activity.needsSnapshot || session.activity.isReconciling)
                                    }
                                    if job.state == .failed, job.error?.retryable == true, job.attempt < 3,
                                       session.supports(.retry) {
                                        Button("Retry") { Task { await session.changeJob(job, command: .retry) } }
                                            .disabled(session.activity.needsSnapshot || session.activity.isReconciling)
                                    }
                                }
                                if let error = job.error {
                                    Text(error.retryable && job.attempt < 3 && session.supports(.retry)
                                         ? "This check couldn't finish. Retry when you're ready."
                                         : "This check couldn't finish, and retry isn't available.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                DisclosureGroup("Details") {
                                    Text("Product ID: \(job.product.productID)").textSelection(.enabled)
                                    if let error = job.error { Text("Error code: \(error.code)") }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                if let error = session.activityError {
                    Section("Activity error") {
                        Text(error).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .task(id: "\(session.accountCatalogScope):\(operations.operation?.productID ?? "")") {
                await Self.loadArtwork(productID: operations.operation?.productID, session: session, artwork: artwork)
            }
        }
    }
}
