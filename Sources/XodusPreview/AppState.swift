// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import SwiftUI
import XodusCore

enum Destination: String, CaseIterable, Identifiable {
    case library = "Library", discover = "Discover", downloads = "Downloads"
    var id: String { rawValue }
}

enum LiveLibraryScope {
    case games, recentActivity
}

enum AccountDestination: String, CaseIterable, Identifiable {
    case account = "Account"
    case profile = "Profile"
    case achievements = "Achievements"
    case consoles = "My Consoles"
    case engines = "Engines"
    var id: String { rawValue }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case engines
    case account
    case advanced

    static let preferenceKey = "Xodus.settings.selectedPane"

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .engines: "gearshape.2"
        case .account: "person.crop.circle"
        case .advanced: "slider.horizontal.3"
        }
    }
}

enum SettingsPaneSelection {
    static func selected(defaults: UserDefaults = .standard) -> SettingsPane {
        defaults.string(forKey: SettingsPane.preferenceKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
    }

    static func select(_ pane: SettingsPane, defaults: UserDefaults = .standard) {
        defaults.set(pane.rawValue, forKey: SettingsPane.preferenceKey)
    }
}

#if !XODUS_SHIPPING
enum BrowseCategory: String, CaseIterable, Identifiable {
    case all = "All worlds", adventure = "Quiet adventures", space = "Space", puzzles = "Puzzles"
    var id: String { rawValue }

    func includes(_ game: Game) -> Bool {
        switch self {
        case .all: true
        case .adventure: ["harbor", "signal", "tide"].contains(game.art)
        case .space: game.art == "orbit"
        case .puzzles: ["ridge", "moss"].contains(game.art)
        }
    }
}

@MainActor
final class SheetInteraction: ObservableObject {
    @Published var showInstall = false
    @Published var acceptsExperimental = false
    @Published var cancelled = false
}
#endif

@MainActor
final class AppState: ObservableObject {
    let runtimeSettings = RuntimeProviderSettings()
    let calimochoInstaller: CalimochoReleaseInstallController
    let installedGames: InstalledGamesController
    let pcGames: PCGamesController
    let librarySelection = LibrarySelection()
    let discoverSelection = DiscoverSelection()
    private let gameScriptPaths: GameScriptPaths
    private let settingsDefaults: UserDefaults
    lazy var gameOperations: GameOperationsController = {
        let operations = GameOperationsController(installed: installedGames, paths: gameScriptPaths,
                                                  installLocationDefaults: .standard)
        let installed = installedGames
        operations.confirmLifecycle = { request in
            // Never put a modal over a running game or over another app; the action is simply not taken.
            guard GameReadyNotifier.interruptionAllowed(
                playing: installed.runningGameID != nil || installed.launchStarted,
                frontmost: NSApp?.isActive ?? false) else { return false }
            let alert = NSAlert()
            alert.messageText = request.messageText
            alert.informativeText = request.informativeText
            alert.addButton(withTitle: request.actionTitle)
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        return operations
    }()
    lazy var downloadQueue = DownloadQueueController(
        driver: GameOperationsInstallDriver(operations: gameOperations))
#if !XODUS_SHIPPING
    @Published var fixtureMode = CommandLine.arguments.contains("--fixture")
        || CommandLine.arguments.contains("--export-preview") || LibraryPreviewExporter.fixtureRequested
    @Published var sortByTitle = false
    @Published var accessFilter: Entitlement? = nil
    @Published var category: BrowseCategory = .all
    @Published var inventory: InventoryState = .complete
    @Published var connected = true
    @Published var showingWelcome = false
    @Published var selectedGame: Game?
    @Published var jobs: [FixtureJob] = []
    @Published var installed = Set(Fixtures.games.filter(\.initiallyInstalled).map(\.id))
    @Published var lowSpace = false
    @Published var message: String?
#endif
    @Published var showingAccount = false
    @Published var accountDestination: AccountDestination = .account
    @Published var showingSetup = false
    /// Set when the user signs in from the welcome screen; the sheet then shows the readiness checklist.
    @Published var showingReadiness = false
    /// REQ-119: the setup view covers the window; navigation, Import and Account wait.
    @Published private(set) var firstLoadCoveringWindows = Set<UUID>()
    var firstLoadCovering: Bool { !firstLoadCoveringWindows.isEmpty }
    /// Each window reports its own setup view; closing one never uncovers another still in setup.
    func setFirstLoadCovering(_ covering: Bool, window: UUID) {
        if covering { firstLoadCoveringWindows.insert(window) } else { firstLoadCoveringWindows.remove(window) }
    }
    @Published var destination: Destination = .library
    @Published var query = ""
    @Published private(set) var unifiedSignInRequested = false
    /// Incremented by Edit ▸ Find…; the window focuses the toolbar search field.
    @Published private(set) var searchFocusRequest = 0
    private var destinationQueries: [Destination: String] = [:]
    @Published private(set) var liveLibraryScope: LiveLibraryScope = .games

    init(installedGames: InstalledGamesController = InstalledGamesController(),
         pcGames: PCGamesController = PCGamesController(), gameScriptPaths: GameScriptPaths = .production,
         settingsDefaults: UserDefaults = .standard,
         calimochoInstaller: CalimochoReleaseInstallController = CalimochoReleaseInstallController()) {
        self.calimochoInstaller = calimochoInstaller
        self.installedGames = installedGames
        self.pcGames = pcGames
        self.gameScriptPaths = gameScriptPaths
        self.settingsDefaults = settingsDefaults
    }

    func canSignOut(session: LiveSession) -> Bool {
        session.canDisconnectAccount && gameOperations.canDisconnectAccount
            && !pcGames.busy && !pcGames.restoringPresence && !runtimeSettings.planning
    }

    func beginUnifiedSignIn(session: LiveSession) async {
        guard !unifiedSignInRequested else { return }
        unifiedSignInRequested = true
        await session.beginSignIn()
        if !session.signInPending, !session.hasConfirmedSignIn {
            unifiedSignInRequested = false
        }
    }

    func recoverUnifiedSignIn(session: LiveSession) async {
        if session.needsAccountDisconnect {
            guard await signOut(session: session) else { return }
        }
        await beginUnifiedSignIn(session: session)
    }

    func cancelUnifiedSignIn(session: LiveSession) async {
        unifiedSignInRequested = false
        await session.cancelSignIn()
    }

    func consumeUnifiedSignInRequest() -> Bool {
        guard unifiedSignInRequested else { return false }
        unifiedSignInRequested = false
        return true
    }

    func refreshGameServiceStatusAfterSignIn() async {
        gameOperations.refreshService()
        await gameOperations.waitForService()
    }

    @discardableResult
    func signOut(session: LiveSession) async -> Bool {
        guard canSignOut(session: session), gameOperations.beginAccountDisconnect() else { return false }
        librarySelection.projection.clear(to: .empty)
        discoverSelection.projection.clear(to: .empty)
        installedGames.setAccountAccessAllowed(false)
        installedGames.productAccess.retire()
        defer { gameOperations.finishAccountDisconnect() }
        guard pcGames.beginAccountDisconnect() else { return false }
        defer { pcGames.finishAccountDisconnect() }
        if pcGames.usesUnifiedAccount {
            let result = await session.signOut {
                await self.gameOperations.cancelPrecheck()
                guard await session.stopUnifiedRuntime() else {
                    return "The game connection hasn't stopped. Your saved account was not removed."
                }
                XboxCompanionController.shared.invalidateBinding()
                LibraryXboxStats.shared.invalidateBinding()
                await self.pcGames.retireUnifiedAccount()
                return nil
            }
            if result {
                installedGames.suspendAccountView()
                session.confirmAppSignOut()
            }
            return result
        }
        let result = await session.signOut {
            await self.gameOperations.cancelPrecheck()
            guard await self.gameOperations.signOutForApp() else {
                return self.gameOperations.serviceError ?? "\(AppBrand.displayName) couldn't start game-service sign-out. No other sign-in was removed."
            }
            guard await self.pcGames.signOut() else {
                return "Game-service sign-out was confirmed, but \(AppBrand.displayName) couldn't remove its saved PC-library sign-in. The launcher profile was not disconnected. Check account status before retrying."
            }
            return nil
        }
        if result {
            installedGames.suspendAccountView()
            session.confirmAppSignOut()
        } else {
            let application = session.accountHash
            let library = pcGames.accountHash
            let service = gameOperations.serviceStatus?.accountHash
            installedGames.setAccountAccessAllowed(
                session.hasConfirmedSignIn && application != nil
                    && application == library && library == service
            )
        }
        return result
    }

    var showsRecentActivity: Bool {
        destination == .library && liveLibraryScope == .recentActivity
    }

    var navigationSelection: Binding<Destination> {
        Binding(get: { self.destination }, set: { self.selectTab($0) })
    }

    /// Choosing a tab opens that tab's home. Search is its own state: choosing Discover
    /// leaves any earlier results, which stay one click away in recent searches.
    func selectTab(_ value: Destination) {
        navigate(value)
        if value == .discover { query = "" }
    }

    func requestSearchFocus() {
        navigate(.discover)
        searchFocusRequest += 1
    }

    func canRefresh(session: LiveSession) -> Bool {
        switch destination {
        case .discover: session.isReady && !session.searching
        case .library: showsRecentActivity ? session.isReady : !pcGames.busy
        case .downloads: session.supports(.jobs) && !session.activity.isReconciling
        }
    }

    func refreshCurrentDestination(session: LiveSession) async {
        guard canRefresh(session: session) else { return }
        switch destination {
        case .discover: await session.refreshCatalog(query)
        case .library:
            if showsRecentActivity { await session.reloadRecentLibrary() }
            else { pcGames.refresh() }
        case .downloads: await session.refreshActivity()
        }
    }

    func query(for destination: Destination) -> String {
        destination == self.destination ? query : destinationQueries[destination] ?? ""
    }

    func navigate(_ value: Destination) {
        if !showsRecentActivity { destinationQueries[destination] = query }
        destination = value
        query = destinationQueries[value] ?? ""
        liveLibraryScope = .games
#if !XODUS_SHIPPING
        accessFilter = nil
        sortByTitle = false
        category = .all
#endif
    }

    func openRecentActivity() {
        navigate(.library)
        query = ""
        liveLibraryScope = .recentActivity
    }

    func openAccount(_ destination: AccountDestination = .account) {
        guard !firstLoadCovering else { return }
        if destination == .engines {
            SettingsPaneSelection.select(.engines, defaults: settingsDefaults)
            showingAccount = false
            return
        }
        showingSetup = false
        accountDestination = destination
        showingAccount = true
    }

    @discardableResult
    func configureUnifiedAccountMode(session: LiveSession) -> Bool {
        guard session.supports(.odeAccountRead) else { return false }
        pcGames.useUnifiedAccount(session)
        gameOperations.useUnifiedAccount(session)
        installedGames.useUnifiedAccount(session)
        return true
    }

    func loadRecentActivityIfVisible(session: LiveSession) async {
        guard showsRecentActivity else { return }
        await session.loadRecentLibraryOnEntry()
    }

    func findInStore(_ titleName: String, session: LiveSession) {
        session.selectedProduct = nil
        navigate(.discover)
        query = titleName
    }

#if !XODUS_SHIPPING
    var visibleGames: [Game] {
        guard inventory != .empty && inventory != .failed else { return [] }
        let games = Fixtures.games.filter {
            let inScope = destination == .discover || $0.entitlement == .purchase || $0.entitlement == .subscription
            let matchesAccess = destination != .library || accessFilter == nil || $0.entitlement == accessFilter
            let matchesCategory = destination != .discover || !query.isEmpty || category.includes($0)
            return inScope && matchesAccess && matchesCategory
                && (query.isEmpty || $0.title.localizedStandardContains(query))
        }
        return sortByTitle ? games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : games
    }

    func decision(for game: Game) -> InstallDecision {
        guard connected else { return .blocked("Connect the fixture account first.") }
        return ActionPolicy.evaluate(game, inventory: inventory, now: Fixtures.checkedAt,
                                     fingerprint: Fixtures.fingerprint)
    }

    func enqueue(_ game: Game) {
        guard decision(for: game) == .allowed, let package = game.package else {
            message = decision(for: game).reason ?? "The fixture package is unavailable."
            return
        }
        guard InstallPlan(game: game, package: package,
                          availableBytes: availableBytes).hasEnoughSpace else {
            message = "Not enough simulated storage. No job was created."
            return
        }
        guard !installed.contains(game.id),
              !jobs.contains(where: { $0.gameID == game.id && !$0.phase.isTerminal }) else {
            message = "This fixture is already installed or in the simulated queue."
            return
        }
        jobs.append(FixtureJob(gameID: game.id))
        selectedGame = nil
        navigate(.downloads)
    }

    var availableBytes: Int64 { (lowSpace ? 5 : 120) * Fixtures.gigabyte }

    func updateJob(_ id: UUID, operation: (inout FixtureJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            message = "The fixture job is no longer in the queue."
            return
        }
        operation(&jobs[index])
        if jobs[index].phase == .completed { installed.insert(jobs[index].gameID) }
    }

    func simulateLaunch(_ game: Game) {
        guard installed.contains(game.id), decision(for: game) == .allowed else {
            message = decision(for: game).reason ?? "This fixture is not installed."
            return
        }
        message = "Simulation only: \(game.title) would launch here. No game or runtime was started."
    }

    func reset() {
        jobs = []
        installed = Set(Fixtures.games.filter(\.initiallyInstalled).map(\.id))
        inventory = .complete
        lowSpace = false
        connected = true
        navigate(.library)
        selectedGame = nil
        showingWelcome = false
        showingAccount = false
        accountDestination = .account
        message = nil
    }
#endif
}
