// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore
import XodusManagement

enum GameLaunchArguments: Equatable {
    /// `engine` names a catalogue engine binding; it goes through the same per-game title scope as the
    /// Engine menu and is never substituted.
    case play(String, engine: String? = nil), nativeMinecraft

    static func parse(_ arguments: [String]) -> Self? {
        if arguments == ["--open-native-minecraft"] { return .nativeMinecraft }
        guard arguments.count == 2 || arguments.count == 4, arguments[0] == "--play-game",
              PCGamesClient.validProductID(arguments[1]) else { return nil }
        if arguments.count == 2 { return .play(arguments[1]) }
        guard arguments[2] == "--engine", validEngineName(arguments[3]) else { return nil }
        return .play(arguments[1], engine: arguments[3])
    }

    static func validEngineName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }
}

#if !XODUS_SHIPPING
private struct LibraryReviewAccessibility: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.xodusReviewReduceTransparency, LibraryPreviewExporter.reduceTransparencyRequested)
    }
}

enum DevelopmentArguments {
    static func accepts(_ arguments: [String]) -> Bool {
        if GameLaunchArguments.parse(arguments) != nil { return true }
        guard let mode = arguments.first else { return true }
        switch mode {
        case "--fixture", "--self-check", "--live-check", "--media-check", "--stats-check", "--game-operation-check", "--library-access-check", "--gamepass-collections-check", "--presentation-performance-check", "--search-performance-check", "--account-presentation-check", "--engine-selection-check", "--settings-check":
            return arguments.count == 1
        case "--export-preview", "--export-live", "--export-live-data":
            return arguments.count == 2
        case "--catalog-detail-check":
            return arguments.count == 4
        case "--gamepass-compatibility-export":
            return arguments.count == 2
        case "--xbox-companion-check":
            return arguments.count == 3
        case "--library-preview":
            if arguments.count == 2 { return true }
            if arguments.count == 3 { return arguments[2] == "--library-grid" }
            if arguments.count == 4 { return arguments[2] == "--discover-browse" }
            return arguments.count == 5 &&
                ["--discover-search", "--game-detail", "--game-detail-info"].contains(arguments[2])
        default:
            return false
        }
    }
}
#endif

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    var liveSession: LiveSession?
    var runtimeSettings: RuntimeProviderSettings?
    var installedGames: InstalledGamesController?
    var pcGames: PCGamesController?
    var calimochoInstaller: CalimochoReleaseInstallController?
    var gameOperations: GameOperationsController? {
        didSet {
            guard let gameOperations, gameOperations !== oldValue else { return }
            gameOperations.announceReady = { [weak self] in self?.readyNotifier.post($0) }
        }
    }
    let readyNotifier = GameReadyNotifier()
    let termination = ApplicationTerminationCoordinator()
    private var terminationRequested = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        readyNotifier.play = { [weak self] folder in
            guard let installed = self?.installedGames,
                  let game = installed.games.first(where: { $0.folder == folder }) else { return }
            Task { await installed.play(game) }
        }
        readyNotifier.playActive = { [weak self] in
            guard let installed = self?.installedGames else { return false }
            return installed.runningGameID != nil || installed.launchStarted
        }
        readyNotifier.configure()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        let systemQuit = Self.systemSessionEnding
        Task {
            defer { terminationRequested = false }
            if let installedGames, let id = installedGames.runningGameID {
                let title = installedGames.games.first { $0.id == id }?.title ?? "A game"
                guard RunningGameQuitConfirmation.confirm(title: title) else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            if let gameOperations, let download = gameOperations.stoppableDownloadForQuit {
                if !systemQuit {
                    let alert = NSAlert()
                    alert.messageText = GameDownloadCopy.quitTitle(title: download.title, percent: download.percent)
                    alert.informativeText = GameDownloadCopy.quitMessage
                    alert.addButton(withTitle: GameDownloadCopy.continueDownloading)
                    alert.addButton(withTitle: GameDownloadCopy.stopAndQuit)
                    guard alert.runModal() == .alertSecondButtonReturn else {
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                }
                await gameOperations.stopDownloadForQuit()
            }
            await LibraryXboxStats.shared.shutdown()
            await XboxCompanionController.shared.shutdown()
            let closed = await termination.shutdown(session: liveSession, runtime: runtimeSettings,
                                                    installedGames: installedGames, pcGames: pcGames,
                                                    gameOperations: gameOperations,
                                                    calimochoInstaller: calimochoInstaller)
            if !closed {
                LibraryXboxStats.shared.resumeAfterTerminationRefusal()
                XboxCompanionController.shared.resumeAfterTerminationRefusal()
            }
            // Logout/restart/shutdown is refused at once without a modal that would hang unattended.
            if Self.showsWaitBeforeQuitting(closed: closed, systemQuit: systemQuit,
                                            canQuit: gameOperations?.canQuit ?? true) {
                let alert = NSAlert()
                alert.messageText = "Wait before quitting \(AppBrand.displayName)"
                alert.informativeText = "Wait for the current game operation to finish. You can cancel an installation first."
                alert.addButton(withTitle: "Keep \(AppBrand.displayName) Open")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: closed)
        }
        return .terminateLater
    }

    nonisolated static func showsWaitBeforeQuitting(closed: Bool, systemQuit: Bool, canQuit: Bool) -> Bool {
        !closed && !systemQuit && !canQuit
    }

    /// Log out, restart and shut down must not be blocked by a download prompt.
    private static var systemSessionEnding: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }.contains(reason)
    }
}

@main
struct XodusPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var session = LiveSession()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private func openSettingsPane(_ pane: SettingsPane) {
        SettingsPaneSelection.select(pane)
        openSettings()
    }

    private var navigationAllowed: Bool {
#if !XODUS_SHIPPING
        (state.fixtureMode || session.hasConfirmedSignIn) && !state.firstLoadCovering
#else
        session.hasConfirmedSignIn && !state.firstLoadCovering
#endif
    }

    init() {
        ProcessInfo.processInfo.processName = AppBrand.displayName
        if let peer = ConcurrentAppGuard.runningPeer(bundleID: Bundle.main.bundleIdentifier,
                running: NSWorkspace.shared.runningApplications.compactMap { app in
                    app.bundleIdentifier.map { ConcurrentAppGuard.Running(bundleID: $0, pid: app.processIdentifier) } },
                selfPID: ProcessInfo.processInfo.processIdentifier) {
            ConcurrentAppGuard.refuse(peer: peer)
        }
        // Two apps launched at the same moment can both miss each other in the process list; the shared
        // lock admits exactly one of them.
        if let bundleID = Bundle.main.bundleIdentifier, ConcurrentAppGuard.peers[bundleID] != nil,
           !ConcurrentAppGuard.holdInstanceLock() {
            ConcurrentAppGuard.refuse(peer: "Another X Ode app")
        }
        QualificationDiagnostics.importOrdinaryPreferences()
#if XODUS_SHIPPING
        if !CommandLine.arguments.dropFirst().isEmpty,
           GameLaunchArguments.parse(Array(CommandLine.arguments.dropFirst())) == nil {
            FileHandle.standardError.write(Data("This application does not accept preview, test or development arguments.\n".utf8))
            exit(64)
        }
#else
        guard DevelopmentArguments.accepts(Array(CommandLine.arguments.dropFirst())) else {
            FileHandle.standardError.write(Data("Unsupported development arguments; ordinary startup was not attempted.\n".utf8))
            exit(64)
        }
        if Bundle.main.object(forInfoDictionaryKey: "XodusLibraryReviewBuild") as? Bool == true,
           !LibraryPreviewExporter.requested {
            FileHandle.standardError.write(Data("Use the staged read-only Library review job; ordinary startup is disabled.\n".utf8))
            exit(64)
        }
        if PreviewExporter.liveDataRequested {
            do {
                let configuration = try PreviewExporter.liveConfiguration()
                _session = StateObject(wrappedValue: LiveSession(configuration: configuration))
            } catch {
                FileHandle.standardError.write(Data("Actual live export requires the explicitly admitted, compiled-pin-bound installed pair.\n".utf8))
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--presentation-performance-check") { PresentationPerformanceChecks.launch() }
        if CommandLine.arguments.contains("--search-performance-check") { SearchPerformanceChecks.launch() }
        if CommandLine.arguments.contains("--engine-selection-check") { NativeChecks.launch(engineSelectionOnly: true) }
        if CommandLine.arguments.contains("--settings-check") { NativeChecks.launch(settingsOnly: true) }
        if CommandLine.arguments.contains("--live-check") { NativeChecks.launch() }
        if CommandLine.arguments.contains("--account-presentation-check") { NativeChecks.launch(accountPresentationOnly: true) }
        if CommandLine.arguments.contains("--library-access-check") { NativeChecks.launch(libraryAccessOnly: true) }
        if CommandLine.arguments.contains("--gamepass-collections-check")
            || CommandLine.arguments.contains("--gamepass-compatibility-export") {
            Task { @MainActor in
                let collections = GamePassCollections()
                guard let value = ProcessInfo.processInfo.environment["XODUS_PUBLIC_CATALOG_MARKET"],
                      let country = XboxAccountCountry.normalized(value) else {
                    print("Public catalogue checks require explicit XODUS_PUBLIC_CATALOG_MARKET; no account country is inferred.")
                    exit(64)
                }
                await collections.load(market: country, language: "en-US")
                for category in collections.collections {
                    print("\(category.key): \(category.title); feed=\(category.feedID); records=\(category.productIDs.count); resolved=\(category.products.count); error=\(category.error != nil)")
                }
                if let error = collections.error { print(error) }
                let valid = collections.error == nil && !collections.collections.isEmpty
                    && collections.collections.first?.key == "pdoPC"
                    && collections.collections.allSatisfy { $0.error == nil }
                if valid, CommandLine.arguments.contains("--gamepass-compatibility-export") {
                    do {
                        try await collections.exportCompatibility(to: URL(fileURLWithPath: CommandLine.arguments[2]),
                            market: country)
                    } catch {
                        print("Public compatibility export failed; no successful snapshot is claimed.")
                        exit(1)
                    }
                }
                exit(valid ? 0 : 1)
            }
            CFRunLoopRun()
            fatalError("Public catalogue check exited its run loop unexpectedly.")
        }
        if CommandLine.arguments.contains("--media-check") { NativeChecks.launch(mediaOnly: true) }
        if CommandLine.arguments.contains("--stats-check") { NativeChecks.launch(statsOnly: true) }
        if CommandLine.arguments.contains("--game-operation-check") { NativeChecks.launch(gameOperationsOnly: true) }
        if CommandLine.arguments.contains("--catalog-detail-check") {
            exit(PreviewChecks.checkDetailMetadata() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--xbox-companion-check") {
            exit(PreviewChecks.checkXboxCompanion() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--self-check") {
            exit(PreviewChecks.run() ? 0 : 1)
        }
#endif
    }

    var body: some Scene {
        WindowGroup(AppBrand.displayName) {
            Group {
#if !XODUS_SHIPPING
                if state.fixtureMode { RootView() }
                else { LiveRootView() }
#else
                LiveRootView()
#endif
            }
#if !XODUS_SHIPPING
                .allowsHitTesting(!LibraryPreviewExporter.requested)
                .modifier(LibraryReviewAccessibility())
#endif
                .environmentObject(state)
                .environmentObject(session)
                .frame(minWidth: 820, minHeight: 600)
                .onAppear {
                    delegate.liveSession = session
                    delegate.runtimeSettings = state.runtimeSettings
                    delegate.installedGames = state.installedGames
                    delegate.pcGames = state.pcGames
                    delegate.gameOperations = state.gameOperations
                    delegate.calimochoInstaller = state.calimochoInstaller
                }
        }

        .defaultSize(width: 1200, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppBrand.displayName)") { AppBrandPresentation.orderFrontAboutPanel() }
                ForEach(AcknowledgmentsNavigation.appMenu, id: \.title) { item in
                    Button(item.title) { AcknowledgmentsNavigation.shared.open(item.focus) { openWindow(id: $0) } }
                }
                Button("\(AppBrand.displayName) Licence…") { openWindow(id: "licenses") }
            }
            CommandGroup(after: .appSettings) {
                Button("Engines…") { openSettingsPane(.engines) }
#if !XODUS_SHIPPING
                    .disabled(state.fixtureMode)
#endif
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit \(AppBrand.displayName)") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            // The standard Edit menu: Spelling and Grammar, Substitutions, Transformations and Speech.
            TextEditingCommands()
            GameSearchCommands(navigationAllowed: navigationAllowed)
            CommandGroup(before: .toolbar) {
                Button("Refresh") { Task { await state.refreshCurrentDestination(session: session) } }
                    .keyboardShortcut("r")
                    .disabled(!navigationAllowed || !state.canRefresh(session: session))
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button(AppBrand.supportTitle) { openWindow(id: AppBrandPresentation.supportWindowID) }
                Button("Send Feedback…") { openWindow(id: AppBrandPresentation.supportWindowID) }
                Divider()
                ForEach(AcknowledgmentsNavigation.helpMenu, id: \.title) { item in
                    Button(item.title) { AcknowledgmentsNavigation.shared.open(item.focus) { openWindow(id: $0) } }
                }
            }
            CommandGroup(after: .newItem) {
                Button(NativeToolbarImportButton.title + "…") { Task { await state.installedGames.chooseGame() } }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
#if !XODUS_SHIPPING
                    .disabled(!session.hasConfirmedSignIn || state.firstLoadCovering || state.fixtureMode || LibraryPreviewExporter.requested || !state.installedGames.loaded ||
                              state.installedGames.editing || state.installedGames.choosing ||
                              state.installedGames.mutationActive)
#else
                    .disabled(!session.hasConfirmedSignIn || state.firstLoadCovering || !state.installedGames.loaded || state.installedGames.editing ||
                              state.installedGames.choosing || state.installedGames.mutationActive)
#endif
            }
            CommandMenu("Navigate") {
                Button("Library") { state.navigate(.library) }.keyboardShortcut("1")
                    .disabled(!navigationAllowed)
                Button("Discover") { state.selectTab(.discover) }.keyboardShortcut("2")
                    .disabled(!navigationAllowed)
                Button("Downloads") { state.navigate(.downloads) }.keyboardShortcut("3")
                    .disabled(!navigationAllowed)
            }
            CommandMenu("Account") {
                Group {
#if !XODUS_SHIPPING
                Button("Account") { state.openAccount() }
                    .disabled(state.fixtureMode)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Profile") { state.openAccount(.profile) }
                    .disabled(state.fixtureMode || !session.hasConfirmedSignIn)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Achievements") { state.openAccount(.achievements) }
                    .disabled(state.fixtureMode || !session.hasConfirmedSignIn)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("My Consoles") { state.openAccount(.consoles) }
                    .disabled(state.fixtureMode || !session.hasConfirmedSignIn)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Return to live \(AppBrand.displayName)") {
                    state.fixtureMode = false
                    state.navigate(.library)
                }.disabled(!state.fixtureMode)
#else
                Button("Account") { state.openAccount() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Profile") { state.openAccount(.profile) }
                    .disabled(!session.hasConfirmedSignIn)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Achievements") { state.openAccount(.achievements) }
                    .disabled(!session.hasConfirmedSignIn)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("My Consoles") { state.openAccount(.consoles) }
                    .disabled(!session.hasConfirmedSignIn)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
#endif
                            }
                .disabled(state.firstLoadCovering)
            }
        }
        Settings {
            Group {
#if !XODUS_SHIPPING
                if state.fixtureMode { PreviewSettings() }
                else { LiveSettingsView() }
#else
                LiveSettingsView()
#endif
            }
                .environmentObject(state)
                .environmentObject(session)
                .onAppear {
                    delegate.liveSession = session
                    delegate.runtimeSettings = state.runtimeSettings
                    delegate.installedGames = state.installedGames
                    delegate.pcGames = state.pcGames
                    delegate.gameOperations = state.gameOperations
                    delegate.calimochoInstaller = state.calimochoInstaller
                }
        }
        Window("Licenses", id: "licenses") { AppLicensesView() }
            .defaultSize(width: 560, height: 420)
        Window("Acknowledgments", id: AppAcknowledgmentsView.windowID) { AppAcknowledgmentsView() }
            .defaultSize(width: 860, height: 600)
        Window(AppBrand.supportTitle, id: AppBrandPresentation.supportWindowID) {
            BetaSupportView { openSettingsPane(.advanced) }
        }
            .defaultSize(width: 480, height: 360)
            .windowResizability(.contentSize)
    }
}


/// REQ-138: the ordinary and Qualification apps share one game service, journal and registry, so only one
/// may run at a time. The second one explains and quits before touching any state.
enum ConcurrentAppGuard {
    static let peers = ["io.github.dragoshont.xodus.development": "X Ode",
                        "io.github.dragoshont.xodus.qualification": "X Ode Qualification"]

    struct Running: Equatable { let bundleID: String; let pid: Int32 }

    /// Another X Ode app, or a second copy of this one (same bundle ID, different process), already running.
    static func runningPeer(bundleID: String?, running: [Running], selfPID: Int32) -> String? {
        guard let bundleID, let ownName = peers[bundleID] else { return nil }
        if running.contains(where: { $0.bundleID == bundleID && $0.pid != selfPID }) { return "Another copy of \(ownName)" }
        return peers.first { peer in peer.key != bundleID && running.contains { $0.bundleID == peer.key } }?.value
    }

    static func message(peer: String) -> String {
        "\(peer) is already running. Quit it first; both apps share the same games and game service."
    }

    /// REQ-138: one exclusive flock shared by the ordinary and Qualification apps, held for the process's life.
    static var instanceLockFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Xodus/app-instance.lock")
    }
    nonisolated(unsafe) private static var heldInstanceLock: Int32 = -1

    enum InstanceLock: Equatable { case held(Int32), busy, unavailable }

    /// `busy` when another process (or another open of the file here) holds the lock. A lock file that can't be
    /// opened is `unavailable` and doesn't block launch; the process-list check still applies.
    static func acquireInstanceLock(_ url: URL) -> InstanceLock {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return .busy
        }
        return .held(fd)
    }

    static func holdInstanceLock() -> Bool {
        guard heldInstanceLock < 0 else { return true }
        switch acquireInstanceLock(instanceLockFile) {
        case .busy: return false
        case .held(let fd): heldInstanceLock = fd; return true
        case .unavailable: return true
        }
    }

    @MainActor static func refuse(peer: String) {
        let alert = NSAlert()
        alert.messageText = "\(AppBrand.displayName) can't open while \(peer) is running"
        alert.informativeText = message(peer: peer)
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(0)
    }
}
