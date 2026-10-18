// SPDX-License-Identifier: GPL-3.0-only
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
    let installedGames: InstalledGamesController
    let pcGames: PCGamesController
    private let gameScriptPaths: GameScriptPaths
    lazy var gameOperations = GameOperationsController(installed: installedGames, paths: gameScriptPaths)
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
    @Published var destination: Destination = .library
    @Published var query = ""
    @Published private(set) var unifiedSignInRequested = false
    private var destinationQueries: [Destination: String] = [:]
    @Published private(set) var liveLibraryScope: LiveLibraryScope = .games

    init(installedGames: InstalledGamesController = InstalledGamesController(),
         pcGames: PCGamesController = PCGamesController(), gameScriptPaths: GameScriptPaths = .production) {
        self.installedGames = installedGames
        self.pcGames = pcGames
        self.gameScriptPaths = gameScriptPaths
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

    func cancelUnifiedSignIn(session: LiveSession) async {
        unifiedSignInRequested = false
        await session.cancelSignIn()
    }

    func consumeUnifiedSignInRequest() -> Bool {
        guard unifiedSignInRequested else { return false }
        unifiedSignInRequested = false
        return true
    }

    @discardableResult
    func signOut(session: LiveSession) async -> Bool {
        guard canSignOut(session: session), gameOperations.beginAccountDisconnect() else { return false }
        installedGames.setAccountAccessAllowed(false)
        defer { gameOperations.finishAccountDisconnect() }
        guard pcGames.beginAccountDisconnect() else { return false }
        defer { pcGames.finishAccountDisconnect() }
        let result = await session.signOut {
            await self.gameOperations.cancelPrecheck()
            guard await self.gameOperations.signOutForApp() else {
                return self.gameOperations.serviceError ?? "X Ode couldn't start game-service sign-out. No other sign-in was removed."
            }
            guard await self.pcGames.signOut() else {
                return "Game-service sign-out was confirmed, but X Ode couldn't remove its saved PC-library sign-in. The launcher profile was not disconnected. Check account status before retrying."
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
        Binding(get: { self.destination }, set: { self.navigate($0) })
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
        showingSetup = false
        accountDestination = destination
        showingAccount = true
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
