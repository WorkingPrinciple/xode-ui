// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

struct LiveRootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var session: LiveSession
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var searchFocused: Bool
    @State private var libraryHasHero = false
    @State private var launchArgumentHandled = false
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
        guard accountRecoveryAllowed, state.pcGames.accessIsCurrent,
              !state.installedGames.accountDisconnecting else { return nil }
        if unifiedAccountMode {
            return session.accountHash == state.pcGames.accountHash ? session.accountHash : nil
        }
        return XboxAccountBinding.matching(application: session.accountHash,
            library: state.pcGames.accountHash, service: state.gameOperations.serviceStatus)
    }
    private var profileBootstrapBinding: String? {
        if unifiedAccountMode { return boundAccountHash }
        return session.accountBusy || state.gameOperations.serviceBusy ? nil : boundAccountHash
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
        state.destination == .discover
            || (state.destination == .library && !state.showsRecentActivity)
            || (state.showsRecentActivity && session.recentLibrary != nil)
    }
    private var libraryArtworkAllowed: Bool {
#if XODUS_SHIPPING
        startupAllowed
#else
        startupAllowed || LibraryPreviewExporter.requested
#endif
    }
    private var searchPlaceholder: String {
        state.destination == .library ? (state.showsRecentActivity ? "Search recent activity" : "Search your PC games")
            : state.destination == .downloads ? "Search Library or Discover"
            : "Search Discover"
    }
    private var refreshHelp: String {
        if state.destination == .discover {
            return session.discoveryCheckedAt.map { "Refresh Discover - checked \($0)" } ?? "Refresh Discover"
        }
        guard let snapshot = state.pcGames.snapshot else { return "Refresh Library" }
        let age = snapshot.updatedAt.formatted(.relative(presentation: .named))
        return "Refresh Library - updated \(age)"
    }

    var body: some View {
        ScrollViewReader { proxy in
        Group {
            if requiresAccountGate {
                Text("Ode to X").font(.title.bold()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .accessibilityIdentifier("xodus.welcome.background")
            } else if state.destination == .downloads {
                LiveActivityView(operations: state.gameOperations, queue: state.downloadQueue) { state.navigate(.discover) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if state.destination == .library {
                            library { proxy.scrollTo("library-games", anchor: .top) }
                        }
                        else { catalog }
                    }
                    .padding(immersiveDestination ? 0 : 30)
                }
                .modifier(LibraryScrollEdge(enabled: immersiveDestination))
                .modifier(LibraryImmersion(enabled: immersiveDestination, underlapsToolbar: toolbarOverArtwork))
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .toolbar {
            if !requiresAccountGate {
            XodusToolbar(selection: state.navigationSelection, searchText: $state.query,
                         searchFocused: Binding(get: { searchFocused }, set: { searchFocused = $0 }),
                         searchPlaceholder: searchPlaceholder, searchEnabled: searchEnabled,
                         accountLabel: session.accountLabel,
                         accountSymbol: session.accountSymbol,
                         libraryContrast: toolbarOverArtwork) {
                state.openAccount()
            }
            if state.destination == .library && !state.showsRecentActivity {
                ToolbarItem(placement: .primaryAction) {
                    Button("Import installed Xbox game", systemImage: "plus") {
                        Task { await state.installedGames.chooseGame() }
                    }
                    .labelStyle(.iconOnly).help("Import installed game")
                    .modifier(NativeToolbarIconStyle())
                    .disabled(!state.installedGames.loaded || state.installedGames.editing ||
                              state.installedGames.choosing || state.installedGames.mutationActive)
                    .accessibilityIdentifier("xodus.installed.import")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh Library", systemImage: "arrow.clockwise") {
                        Task { await state.pcGames.retryLibraryLoad() }
                        Task { await refreshXboxStats() }
                        if state.gameOperations.gamePassActive, session.isReady, session.supports(.discover) {
                            Task { await session.refreshCatalog("") }
                        }
                    }
                        .labelStyle(.iconOnly).help(refreshHelp).keyboardShortcut("r")
                        .modifier(NativeToolbarIconStyle())
                        .disabled(!startupAllowed || state.pcGames.busy || state.pcGames.restoringPresence)
                        .accessibilityIdentifier("xodus.pcGames.refresh")
                }
            }
            if state.destination == .discover {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh Discover", systemImage: "arrow.clockwise") {
                        Task { await session.refreshCatalog(state.query) }
                    }
                    .labelStyle(.iconOnly).help(refreshHelp).keyboardShortcut("r")
                    .modifier(NativeToolbarIconStyle())
                    .disabled(!startupAllowed || !session.isReady || session.searching)
                    .accessibilityIdentifier("xodus.catalog.refresh")
                }
            }
            }
        }
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
        .task(id: accountRecoveryAllowed) {
            if accountRecoveryAllowed {
                if unifiedAccountMode {
                    state.pcGames.useUnifiedAccount(session)
                    companion.useUnifiedAccount(session)
                    state.gameOperations.useUnifiedAccount(session)
                    state.installedGames.useUnifiedAccount(session)
                }
                await state.pcGames.loadOnAppear()
                await state.installedGames.load()
                await state.installedGames.discoverNativeInstallations()
                await state.gameOperations.restore()
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
            }
        }
        .task(id: "\(session.hasConfirmedSignIn):\(state.gameOperations.serviceStatus?.accountHash ?? ""):\(state.gameOperations.serviceStatus?.signedIn == true):\(state.gameOperations.serviceSigningIn)") {
            let accessMessage: String
            if unifiedAccountMode {
                accessMessage = "Your Xbox account and game connection need to match. Check Account and refresh your library."
            } else if !session.hasConfirmedSignIn {
                accessMessage = "Sign in with Xbox Live to play this game."
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
            guard accountContentAllowed, state.destination == .discover else { return }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            await session.loadCatalogOnEntry(state.query)
            if state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               session.supports(.discover), !session.catalogStopped {
                await session.loadGamePassCatalog()
            }
        }
        .onChange(of: session.hasConfirmedSignIn) { _, confirmed in
            if confirmed, state.consumeUnifiedSignInRequest() {
                if !unifiedAccountMode { Task { await state.refreshGameServiceStatusAfterSignIn() } }
            } else if !confirmed {
                if unifiedAccountMode {
                    companion.invalidateBinding()
                    Task { await state.pcGames.retireUnifiedAccount() }
                }
                state.installedGames.setAccountAccessAllowed(false)
                session.selectedProduct = nil
                state.showingAccount = false
                state.showingSetup = false
                state.accountDestination = .account
            }
        }
        .sheet(isPresented: Binding(get: { requiresAccountGate || state.showingAccount },
                                    set: { state.showingAccount = !requiresAccountGate && $0 }), onDismiss: {
            state.showingSetup = false
            state.accountDestination = .account
        }) {
            if requiresSignIn {
                LiveWelcomeView(session: session, runtime: state.runtimeSettings, operations: state.gameOperations)
                    .background {
                        WelcomeSheetTerminationBridge()
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            } else {
#if !XODUS_SHIPPING
            LiveAccountView(refreshStatusOnAppear: !PreviewExporter.liveDataRequested)
#else
            LiveAccountView()
#endif
            }
        }
        .sheet(item: $session.selectedProduct) { product in
            LiveProductView(product: product, library: state.pcGames,
                            installedLibrary: state.installedGames, operations: state.gameOperations,
                            allowsStartupTasks: startupAllowed, allowsArtworkLoading: libraryArtworkAllowed)
        }
        .background {
            if !requiresSignIn { GameOperationPresentation(operations: state.gameOperations) }
        }
        .background {
            Button("Focus search") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
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

    private var immersiveDestination: Bool {
        (state.destination == .library && !state.showsRecentActivity) || state.destination == .discover
    }

    private func library(showCollection: @escaping () -> Void) -> some View {
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
                                operations: state.gameOperations, query: scopedQuery,
                                allowsStartupTasks: startupAllowed,
                                allowsArtworkLoading: libraryArtworkAllowed,
                                allowsHeroAnimation: heroAnimationAllowed,
                                browse: { state.navigate(.discover) },
                                recentActivity: { state.openRecentActivity() },
                                showCollection: showCollection)
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
                        operations: state.gameOperations, query: scopedQuery,
                        allowsArtworkLoading: libraryArtworkAllowed,
                        allowsStartupTasks: startupAllowed, allowsHeroAnimation: heroAnimationAllowed,
                        clearSearch: { state.query = "" })
    }
}

struct LiveActivityView: View {
    @ObservedObject var operations: GameOperationsController
    @ObservedObject var queue: DownloadQueueController
    var browseGames: () -> Void = {}
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
                if session.activity.jobs.isEmpty && !operations.hasDownloadStatus && queue.jobs.isEmpty {
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
            .task(id: operations.operation?.productID) {
                guard let id = operations.operation?.productID else { return }
                await artwork.load(ids: [id], market: session.market, language: session.language)
            }
        }
    }
}
