// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore
import XodusManagement

enum GameLaunchArguments: Equatable {
    case play(String), nativeMinecraft

    static func parse(_ arguments: [String]) -> Self? {
        if arguments == ["--open-native-minecraft"] { return .nativeMinecraft }
        if arguments.count == 2, arguments[0] == "--play-game",
           PCGamesClient.validProductID(arguments[1]) { return .play(arguments[1]) }
        return nil
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
        case "--fixture", "--self-check", "--live-check", "--media-check", "--stats-check", "--game-operation-check", "--library-access-check", "--gamepass-collections-check", "--presentation-performance-check":
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
    var gameOperations: GameOperationsController?
    let termination = ApplicationTerminationCoordinator()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await LibraryXboxStats.shared.shutdown()
            await XboxCompanionController.shared.shutdown()
            let closed = await termination.shutdown(session: liveSession, runtime: runtimeSettings,
                                                    installedGames: installedGames, pcGames: pcGames,
                                                    gameOperations: gameOperations)
            if !closed {
                LibraryXboxStats.shared.resumeAfterTerminationRefusal()
                XboxCompanionController.shared.resumeAfterTerminationRefusal()
            }
            if !closed, gameOperations?.canQuit == false {
                let alert = NSAlert()
                alert.messageText = "Wait before quitting Ode to X"
                alert.informativeText = "Wait for the current game operation to finish. You can cancel an installation first."
                alert.addButton(withTitle: "Keep Ode to X open")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: closed)
        }
        return .terminateLater
    }
}

@main
struct XodusPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var session = LiveSession()
    @Environment(\.openWindow) private var openWindow

    private var navigationAllowed: Bool {
#if !XODUS_SHIPPING
        state.fixtureMode || session.hasConfirmedSignIn
#else
        session.hasConfirmedSignIn
#endif
    }

    init() {
        ProcessInfo.processInfo.processName = "Ode to X"
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
        if CommandLine.arguments.contains("--live-check") { NativeChecks.launch() }
        if CommandLine.arguments.contains("--library-access-check") { NativeChecks.launch(libraryAccessOnly: true) }
        if CommandLine.arguments.contains("--gamepass-collections-check")
            || CommandLine.arguments.contains("--gamepass-compatibility-export") {
            Task { @MainActor in
                let collections = GamePassCollections()
                await collections.load(market: PCGamesClient.market(Locale.current.region?.identifier), language: "en-US")
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
                            market: PCGamesClient.market(Locale.current.region?.identifier))
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
        WindowGroup("Ode to X") {
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
                }
        }

        .defaultSize(width: 1200, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Ode to X") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Ode to X"])
                }
                Button("Licenses") { openWindow(id: "licenses") }
                Button("Acknowledgments") { openWindow(id: "acknowledgments") }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Ode to X") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            CommandGroup(after: .newItem) {
                Button("Import installed Xbox game…") { Task { await state.installedGames.chooseGame() } }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
#if !XODUS_SHIPPING
                    .disabled(!session.hasConfirmedSignIn || state.fixtureMode || LibraryPreviewExporter.requested || !state.installedGames.loaded ||
                              state.installedGames.editing || state.installedGames.choosing ||
                              state.installedGames.mutationActive)
#else
                    .disabled(!session.hasConfirmedSignIn || !state.installedGames.loaded || state.installedGames.editing ||
                              state.installedGames.choosing || state.installedGames.mutationActive)
#endif
            }
            CommandMenu("Navigate") {
                Button("Library") { state.navigate(.library) }.keyboardShortcut("1")
                    .disabled(!navigationAllowed)
                Button("Discover") { state.navigate(.discover) }.keyboardShortcut("2")
                    .disabled(!navigationAllowed)
                Button("Downloads") { state.navigate(.downloads) }.keyboardShortcut("3")
                    .disabled(!navigationAllowed)
            }
            CommandMenu("Account") {
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
                Button("Engines") { state.openAccount(.engines) }
                    .disabled(state.fixtureMode || !session.hasConfirmedSignIn)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Return to live Ode to X") {
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
                Button("Engines") { state.openAccount(.engines) }
                    .disabled(!session.hasConfirmedSignIn)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
#endif
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
                }
        }
        Window("Licenses", id: "licenses") { AppLicensesView() }
            .defaultSize(width: 560, height: 420)
        Window("Acknowledgments", id: "acknowledgments") { AppAcknowledgmentsView() }
            .defaultSize(width: 560, height: 420)
    }
}
