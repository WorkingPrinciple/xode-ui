// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import OdeCore

@MainActor
private final class OffscreenInstallWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class InstallSheetFixture: ObservableObject {
    @Published var detail: PCGame?
    var requestInstall: (@MainActor () async -> Void)?
    var dismissed = false
}

private struct InstallSheetFixtureView: View {
    @ObservedObject var fixture: InstallSheetFixture
    @ObservedObject var operations: GameOperationsController

    var body: some View {
        Color.clear.frame(width: 640, height: 480)
            .gameDetailSheet(item: $fixture.detail, operations: operations, allowed: true,
                             onDismiss: { fixture.dismissed = true }) { game, reviewInstall in
                let action = GameInstallAction(game: game, operations: operations, reviewInstall: reviewInstall)
                action.padding(24).frame(width: 500, height: 400)
                    .onAppear { fixture.requestInstall = { await action.requestInstall() } }
            }
            .background { GameOperationPresentation(operations: operations) }
    }
}

@MainActor
enum NativeUIChecks {
    static func checkSettingsLayouts(check: (Bool, String) -> Void) throws {
        let suite = "OdeSettingsLayout-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "COR174 Settings layout checks use an isolated preference suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let testEnginesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OdeSettingsEngines-\(UUID().uuidString)", isDirectory: true)
        let installer = CalimochoReleaseInstallController(
            service: CalimochoReleaseInstallService(root: testEnginesRoot))
        let state = AppState(settingsDefaults: defaults, calimochoInstaller: installer)
        let session = LiveSession()
        let renderDirectory = ProcessInfo.processInfo.environment["ODE_SETTINGS_RENDER_DIRECTORY"]
            .map(URL.init(fileURLWithPath:))
        if let renderDirectory {
            try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
        }

        for pane in SettingsPane.allCases {
            SettingsPaneSelection.select(pane, defaults: defaults)
            check(SettingsPaneSelection.selected(defaults: defaults) == pane,
                  "COR174 \(pane.title) restores from its selected-pane preference")
            for width in [CGFloat(560), CGFloat(820)] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let host = NSHostingView(rootView: LiveSettingsView(allowsUpdateChecks: false)
                        .environmentObject(state)
                        .environmentObject(session)
                        .defaultAppStorage(defaults)
                        .frame(width: width, height: 900)
                        .background(Color(nsColor: .windowBackgroundColor)))
                    let window = OffscreenInstallWindow(
                        contentRect: CGRect(x: -10000, y: -10000, width: width, height: 900),
                        styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.sharingType = .none
                    window.contentView = host
                    defer {
                        window.orderOut(nil)
                        window.close()
                    }
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    window.displayIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    check(host.window === window && !window.isKeyWindow && !window.isMainWindow
                          && host.frame.width == width,
                          "COR174 \(pane.title) renders offscreen at \(Int(width)) in \(appearance.rawValue) without activation")
                    func descendants(_ view: NSView) -> [NSView] {
                        [view] + view.subviews.flatMap(descendants)
                    }
                    let tabViews = descendants(host).compactMap { $0 as? NSTabView }
                    check(tabViews.count == 1
                          && tabViews[0].tabViewItems.map(\.label) == SettingsPane.allCases.map(\.title)
                          && tabViews[0].selectedTabViewItem?.label == pane.title
                          && descendants(host).compactMap({ $0 as? NSSegmentedControl }).isEmpty,
                          "COR186 Settings uses the standard TabView with all four panes and restores \(pane.title) (no hand-built strip)")
                    if let renderDirectory, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let appearanceName = appearance == .darkAqua ? "dark" : "light"
                        try bitmap.representation(using: .png, properties: [:])?.write(to: renderDirectory
                            .appendingPathComponent("\(pane.rawValue)-\(Int(width))-\(appearanceName).png"))
                    }
                }
            }
        }
        let operations = state.gameOperations
        operations.useUnifiedAccount(session)
        check(operations.serviceLabel == "Check Xbox account connection"
              && operations.serviceAccountSymbol == "person.crop.circle.badge.exclamationmark",
              "COR174 Signed-out unified account status is truthful and non-successful")
        try checkSettingsFullContentRenders(state: state, session: session, defaults: defaults,
                                            renderDirectory: renderDirectory, check: check)
    }

    private static func checkSettingsFullContentRenders(state: AppState, session: LiveSession,
                                                        defaults: UserDefaults, renderDirectory: URL?,
                                                        check: (Bool, String) -> Void) throws {
        guard let renderDirectory else { return }
        for pane in [SettingsPane.account, .advanced] {
            SettingsPaneSelection.select(pane, defaults: defaults)
            for width in [CGFloat(560), CGFloat(820)] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let height: CGFloat = 2600
                    let host = NSHostingView(rootView: LiveSettingsView(allowsUpdateChecks: false)
                        .environmentObject(state)
                        .environmentObject(session)
                        .defaultAppStorage(defaults)
                        .frame(width: width, height: height)
                        .background(Color(nsColor: .windowBackgroundColor)))
                    let window = OffscreenInstallWindow(
                        contentRect: CGRect(x: -10000, y: -10000, width: width, height: height),
                        styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.sharingType = .none
                    window.contentView = host
                    defer {
                        window.orderOut(nil)
                        window.close()
                    }
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    window.displayIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    check(host.window === window && !window.isKeyWindow && !window.isMainWindow
                          && host.frame.height == height,
                          "COR174 \(pane.title) full-content render is offscreen at \(Int(width)) in \(appearance.rawValue)")
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                    let appearanceName = appearance == .darkAqua ? "dark" : "light"
                    try png.write(to: renderDirectory
                        .appendingPathComponent("\(pane.rawValue)-full-\(Int(width))-\(appearanceName).png"))
                }
            }
        }
    }

    static func checkSignedInSettingsAccountPane(session: LiveSession,
                                                 check: (Bool, String) -> Void) throws {
        let suite = "OdeSignedInSettings-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "COR174 signed-in Settings uses an isolated preference suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = NSApplication.shared.windows.count
        let state = AppState(settingsDefaults: defaults)
        state.pcGames.useUnifiedAccount(session)
        state.gameOperations.useUnifiedAccount(session)
        SettingsPaneSelection.select(.account, defaults: defaults)
        let height: CGFloat = 2600
        let host = NSHostingView(rootView: LiveSettingsView(allowsUpdateChecks: false)
            .environmentObject(state)
            .environmentObject(session)
            .defaultAppStorage(defaults)
            .frame(width: 560, height: height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 560, height: height)
        host.layoutSubtreeIfNeeded()
        check(session.hasConfirmedSignIn
              && SettingsPaneSelection.selected(defaults: defaults) == .account
              && host.window == nil && NSApplication.shared.windows.count == windows,
              "COR174 Signed-in Account pane renders from a confirmed synthetic session without a window or auth request")
        if let directory = ProcessInfo.processInfo.environment["ODE_SETTINGS_RENDER_DIRECTORY"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("account-signed-in-full-560-light.png"))
        }
    }

    static func checkCountryPendingLibrary(session: LiveSession, installed: InstalledGamesController,
                                           check: (Bool, String) -> Void) {
        let windows = NSApplication.shared.windows.count
        let state = AppState(installedGames: installed)
        state.librarySelection.filter = .owned
        let saved = installed.games
        let host = NSHostingView(rootView: LiveRootView(allowsStartupTasks: false)
            .environmentObject(state).environmentObject(session))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 860)
        host.layoutSubtreeIfNeeded()
        let projection = state.librarySelection.projection.current
        check(!session.accountCountryReady && !saved.isEmpty
              && Set(projection.local.compactMap(\.installed?.id)) == Set(saved.map(\.id))
              && state.librarySelection.filter == .owned,
              "Unknown country renders installed Library records without destroying the saved account filter")
        check(descendants(of: host).contains { $0 is NSPopUpButton }
              && host.window == nil && NSApplication.shared.windows.count == windows
              && installed.games == saved,
              "Unknown-country Library keeps inline native confirmation and does not mutate registrations or open a window")
    }

    static func checkAccountCountry(session: LiveSession, confirmationRequired: Bool,
                                    check: (Bool, String) -> Void) throws {
        let windows = NSApplication.shared.windows.count
        let host = NSHostingView(rootView: AccountCountrySettings().environmentObject(session).padding(20)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 400)
        host.layoutSubtreeIfNeeded()
        let controls = descendants(of: host)
        let buttons = controls.compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) }
        check(confirmationRequired ? (buttons.count == 2 && buttons.first?.isEnabled == false) : buttons.count == 1,
              "COR127 native country confirmation has no preselected country and is absent for verified accounts")
        check(host.window == nil && NSApplication.shared.windows.count == windows,
              "REQ101 country controls render without a native window or desktop input")
        if let folder = ProcessInfo.processInfo.environment["ODE_COUNTRY_PROOF"] {
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw GameScriptError.invalidReceipt
            }
            host.cacheDisplay(in: host.bounds, to: image)
            guard let png = image.representation(using: .png, properties: [:]) else {
                throw GameScriptError.invalidReceipt
            }
            let name = confirmationRequired ? "country-confirmation.png" : "country-verified.png"
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
    }

    static func checkAccountDismissalWhileLoading(session: LiveSession,
                                                   check: (Bool, String) -> Void) async throws {
        let windows = NSApplication.shared.windows.count
        let state = AppState()
        state.showingAccount = true
        var closed = false
        let host = NSHostingView(rootView: LiveAccountView(onClose: { closed = true },
            refreshStatusOnAppear: false).environmentObject(state).environmentObject(session))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 520)
        host.layoutSubtreeIfNeeded()
        let buttons = descendants(of: host).compactMap { $0 as? NSButton }
        let close = buttons.first { ["\r", "\u{1b}"].contains($0.keyEquivalent) }
        let protectedFooter = buttons.suffix(3).filter { $0 !== close }
        check(session.hasConfirmedSignIn && session.accountBusy && session.accountStatusChecking,
              "COR95: Populated Account is rendered while an existing-account status read is pending")
        check(close?.isEnabled == true,
              "COR95: Actual Account Close remains enabled during background account loading")
        check(close?.keyEquivalent == "\u{1b}",
              "COR95: Actual Account Close retains Escape while signed in and loading")
        check(protectedFooter.count == 2 && protectedFooter.allSatisfy { !$0.isEnabled }
              && !state.canSignOut(session: session),
              "COR95: Background loading still fences status and protected account mutations")
        close?.performClick(nil)
        for _ in 0..<10 where !closed {
            try await Task.sleep(for: .milliseconds(5))
        }
        check(closed && session.accountBusy && !session.signInPending,
              "COR95: Actual rendered Close invokes dismissal without cancelling the pending account read")
        check(host.window == nil && NSApplication.shared.windows.count == windows,
              "COR95: Loading dismissal check creates no native window or desktop input")
    }

    static func checkInstallSheetPresentation(operations: GameOperationsController, game: PCGame,
                                              check: (Bool, String) -> Void) async throws {
        let fixture = InstallSheetFixture()
        let window = OffscreenInstallWindow(contentRect: CGRect(x: -10000, y: -10000, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.contentView = NSHostingView(rootView: InstallSheetFixtureView(fixture: fixture, operations: operations))
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.close()
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        fixture.detail = game
        func wait(_ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<200 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw GameScriptError.timeout
        }
        try await wait { window.attachedSheet != nil && fixture.requestInstall != nil }
        let detailSheet = window.attachedSheet
        await fixture.requestInstall?()
        await fixture.requestInstall?()
        try await wait {
            fixture.dismissed && operations.presentedInstallConsent != nil
                && window.attachedSheet != nil && window.attachedSheet !== detailSheet
        }
        check(fixture.detail == nil && fixture.dismissed && operations.operation == nil
              && operations.presentedInstallConsent?.game.id == game.id && !window.isKeyWindow,
              "COR89 native presenter: detail dismisses before a distinct consent sheet attaches without activating a window or starting installation")
        check(window.attachedSheet?.contentView?.bounds.height ?? 0 >= 400,
              "COR89 native presenter: the consent renders a full native sheet rather than staying queued behind detail")
        await operations.cancelInstallConsent()
        try await wait { window.attachedSheet == nil }
        check(operations.operation == nil && operations.installConsent == nil && !window.isKeyWindow,
              "COR89 native presenter: cancelling the attached review closes it without starting installation")
    }

    static func run(check: (Bool, String) -> Void) {
        let recovery = LibraryDetailsRecoveryNotice(message: PCGamesController.detailUnavailableNotice)
        let recoveryHost = NSHostingView(rootView: recovery.frame(width: 380))
        recoveryHost.layoutSubtreeIfNeeded()
        check(!descendants(of: recoveryHost).contains { $0 is NSButton }
              && PCGamesController.detailNotice(busy: false, detailFailures: 4, usableGames: 13, retriesLeft: 0) == nil
              && PCGamesController.detailNotice(busy: false, detailFailures: 4, usableGames: 0, retriesLeft: 2) == nil
              && PCGamesController.detailNotice(busy: false, detailFailures: 4, usableGames: 0, retriesLeft: 0)
                == PCGamesController.detailUnavailableNotice
              && PCGamesController.detailRetryDelays.count == 3,
              "P0: Missing game details recover silently (3 bounded retries); while any game is usable nothing shows; afterwards only a quiet line with no Retry button")
        for width in [CGFloat(220), 380] {
            let renderer = ImageRenderer(content: recovery.frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true))
            check(renderer.cgImage.map { $0.width == Int(width) && $0.height >= 14 } == true,
                  "REQ98/P0 quiet recovery line wraps at \(Int(width))pt")
            if let directory = ProcessInfo.processInfo.environment["ODE_REFINEMENT_EVIDENCE"] {
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(rootView: recovery.padding(16)
                        .frame(width: width + 32, height: 140, alignment: .topLeading)
                        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                    host.frame = CGRect(x: 0, y: 0, width: width + 32, height: 140)
                    host.layoutSubtreeIfNeeded()
                    saveDetachedEvidence(host, directory: directory,
                        name: "library-recovery-\(scheme == .light ? "light" : "dark")-\(Int(width)).png",
                        check: check)
                }
            }
        }
        checkContinuePlayingScroller(check: check)
        checkDetailFirstCards(check: check)
        checkLoadingPresentation(check: check)
        checkActionExtentObservation(check: check)
        let blockedGame = PCGame(id: "FIXTURE00001", title: "Unavailable details", artwork: nil)
        let blockedOperations = GameOperationsController(installed: InstalledGamesController())
        let blockedReason = "PC game details for this title couldn't be loaded. Refresh your library to try again."
        let blockedInstall = GameInstallAction(game: blockedGame, operations: blockedOperations,
            enabled: false, disabledReason: blockedReason)
        check(!blockedInstall.canInstall && blockedInstall.unavailableReason == blockedReason,
              "REQ88: Disabled Install retains a visible, title-specific reason rather than tooltip-only help")
        for width in [CGFloat(220), 320, 650] {
            let content = blockedInstall.frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            let renderer = ImageRenderer(content: content)
            let image = renderer.cgImage
            check(image.map { $0.width == Int(width) && $0.height >= 39 } == true,
                  "REQ88: Disabled Install and wrapping recovery text render offscreen at \(Int(width)) points (\(image?.width ?? 0)x\(image?.height ?? 0))")
        }
        var recoverySelected = false
        let heroNotice = InstallUnavailableNotice(
            message: "PC Game Pass download access hasn't been confirmed for this account.",
            recoveryTitle: "Account settings", recover: { recoverySelected = true })
        heroNotice.recover?()
        check(recoverySelected && heroNotice.recoveryTitle == "Account settings",
              "COR88: Disabled Install recovery is an independent actionable control, not disabled with Install")
        for width in [CGFloat(220), 380] {
            let renderer = ImageRenderer(content: heroNotice
                .environment(\.libraryOnHeroMedia, true)
                .frame(width: width).background(Color.white))
            check(renderer.cgImage.map { $0.width == Int(width) && $0.height > 70 } == true,
                  "COR88: White-on-dark hero blocker and recovery wrap above bright artwork at \(Int(width))pt without clipping")
        }
        do { try RecentLibraryChecks.imageChecks(check: check) }
        catch { check(false, "Native image threshold/thumbnail checks complete without network access") }
        check(GameHeroMetadata.ratingLabel(CatalogStoreRating(average: 4.5, count: 123))
                == "\(4.5.formatted(.number.precision(.fractionLength(1)))) / 5 · 123 ratings"
              && LibraryPackageFormatLabel.help(format: "MSIXVC").contains("Package type: MSIXVC")
              && LibraryPackageFormatLabel.help(format: "MSIXVC").contains("doesn't confirm account access or Mac compatibility"),
              "Hero ratings retain their scale/count and package hover help never implies account or Mac clearance")
        let detailPackageBlocker = GameSupportPolicy.issues(packageFormat: "EAppx", antiCheat: nil)
        let detailAntiCheatBlocker = GameSupportPolicy.issues(packageFormat: nil, antiCheat: "Easy Anti-Cheat")
        let detailInstallBlocker = GameDetailFacetCopy.unsupportedInstallMessage(detailPackageBlocker + detailAntiCheatBlocker)
        check(detailInstallBlocker?.hasPrefix("Installation isn't available.") == true
              && detailInstallBlocker?.contains("can't run") == true
              && detailInstallBlocker?.contains("Easy Anti-Cheat") == true
              && detailInstallBlocker?.localizedCaseInsensitiveContains("EAppx") == false
              && GameDetailFacetCopy.unsupportedInstallMessage([]) == nil,
              "REQ88/62: Detail explains unsupported installation in plain language, retains named anti-cheat blockers, and omits package jargon from blocker copy")
        check(GameDetailFacetCopy.installation(installed: false) == "Not installed"
              && GameDetailFacetCopy.installation(installed: true) == "Installed on this Mac"
              && GameDetailFacetCopy.precheckStatus(productID: "FIXTURE00001", installed: false,
                  precheckingProductID: "FIXTURE00001") == "Checking installation requirements"
              && GameDetailFacetCopy.precheckStatus(productID: "FIXTURE00001", installed: true,
                  precheckingProductID: "FIXTURE00001") == nil
              && GameDetailFacetCopy.precheckStatus(productID: "FIXTURE00001", installed: false,
                  precheckingProductID: nil) == nil
              && GameCompatibilityFactsCopy.heading == "Compatibility"
              && GameCompatibilityFactsCopy.unsupported == "Not supported yet"
              && [
                  InstalledGameActionCopy.launchUnavailable,
                  GameCompatibilityFactsCopy.heading,
                  GameCompatibilityFactsCopy.unsupported,
                  NativeMinecraftDetailsCopy.summary,
                  NativeMinecraftDetailsCopy.worldPreservation
              ].allSatisfy { copy in
                  ["test", "evidence", "candidate", "qualification", "CLI only"]
                      .allSatisfy { !copy.localizedCaseInsensitiveContains($0) }
              },
              "Game details retain installation and compatibility facts without exposing launch qualification notes")
        check(NativeMinecraftDetailsCopy.summary.contains("official macOS Minecraft Launcher")
              && NativeMinecraftDetailsCopy.summary.contains("Microsoft sign-in")
              && NativeMinecraftDetailsCopy.worldPreservation.contains("Your worlds")
              && NativeMinecraftInstallation(state: .missing).action == "Install launcher"
              && NativeMinecraftInstallation(state: .ready, path: "/Applications/Minecraft.app",
                                             version: "1.0").action == "Open",
              "Minecraft details retain launcher, account, world and recovery actions without a testing journal")
        check(NativeMinecraftInstallation(state: .missing).appears(in: .all, query: "")
              && !NativeMinecraftInstallation(state: .missing).appears(in: .installed, query: "")
              && NativeMinecraftInstallation(state: .ready).appears(in: .installed, query: " MINECRAFT ")
              && !NativeMinecraftInstallation(state: .ready).appears(in: .owned, query: "")
              && !NativeMinecraftInstallation(state: .ready).appears(in: .gamePass, query: "")
              && !NativeMinecraftInstallation(state: .ready).appears(in: .all, query: "mortis"),
              "REQ-64: Native game visibility/count follows the actual filter, query and installation, never ownership")
        let minecraftDetails = NSHostingView(rootView: NativeMinecraftDetailsContent(
            minecraft: NativeMinecraft(), saveLocation: EmptyView(), close: {}))
        minecraftDetails.sizingOptions = []
        minecraftDetails.frame = CGRect(x: 0, y: 0, width: 540, height: 640)
        minecraftDetails.layoutSubtreeIfNeeded()
        check(minecraftDetails.window == nil && minecraftDetails.frame.width == 540
              && NativeMinecraft.shared.installation.state == .checking,
              "Minecraft information lays out without a window, launcher scan or test journal")
        let application = NSApplication.shared
        let windows = application.windows.count
        for (picture, loading, failed, expected) in [
            (true, false, false, "Profile picture"),
            (false, true, false, "Profile picture is loading"),
            (false, false, true, "Profile picture couldn't be loaded"),
            (false, false, false, "No profile picture available")
        ] {
            check(ToolbarAccountButton.pictureStatus(hasPicture: picture, loading: loading, failed: failed) == expected,
                  "REQ90: Profile fallback explicitly labels picture/loading/error/absence without inferring membership")
        }
        for width in [CGFloat(650), 1200] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let actions = NativeToolbarAccountActions(accountLabel: "Microsoft account", accountSymbol: "person.crop.circle",
                    libraryContrast: true, importGame: {}, openAccount: {})
                    .environment(\.catalogPresentationActive, false)
                let host = NSHostingView(rootView: actions)
                host.sizingOptions = [.intrinsicContentSize]
                host.appearance = NSAppearance(named: appearance)
                host.frame = CGRect(x: 0, y: 0, width: width, height: 64)
                host.layoutSubtreeIfNeeded()
                let fitting = host.intrinsicContentSize
                check(host.window == nil && fitting.width > 80 && fitting.width < 180
                      && fitting.height <= 64,
                      "REQ90: Native account/import group fits \(Int(width))pt \(appearance.rawValue) with trailing inset, without artwork fetch or window (\(fitting))")
            }
        }
        var hasHero = LibraryHeroPresenceKey.defaultValue
        LibraryHeroPresenceKey.reduce(value: &hasHero) { false }
        check(!hasHero, "A plain Library has no artwork underlap preference")
        LibraryHeroPresenceKey.reduce(value: &hasHero) { true }
        check(hasHero, "Actual hero artwork explicitly opts into toolbar underlap")
        for width in [CGFloat(320), 650, 1200] {
            let start = width
            check(HeroPageSnap.offset(original: start, proposed: start + width * 0.199,
                                     pageWidth: width, contentWidth: width * 5) == start,
                  "Hero stays on its current page below twenty percent at \(Int(width)) points")
            check(HeroPageSnap.offset(original: start, proposed: start + width * 0.2,
                                     pageWidth: width, contentWidth: width * 5) == width * 2,
                  "Hero advances at exactly twenty percent at \(Int(width)) points")
            check(HeroPageSnap.offset(original: start, proposed: start - width * 0.2,
                                     pageWidth: width, contentWidth: width * 5) == 0,
                  "Hero retreats at exactly twenty percent at \(Int(width)) points")
            check(HeroPageSnap.offset(original: 0, proposed: -width,
                                     pageWidth: width, contentWidth: width * 5) == 0
                  && HeroPageSnap.offset(original: width * 4, proposed: width * 5,
                                         pageWidth: width, contentWidth: width * 5) == width * 4,
                  "Hero paging clamps the first and last pages at \(Int(width)) points")
        }

        for size in [CGFloat(16), 48, 112, 1024] {
            let rect = CGRect(x: 7, y: 11, width: size, height: size)
            let mark = XOdeMark.path(in: rect)
            check(!mark.isEmpty && rect.contains(mark.boundingBoxOfPath),
                  "The shared Ode mark stays inside its native \(Int(size))-point icon bounds")
        }
        autoreleasepool { checkWelcomeTerminationPolicy(check: check) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(680), 860] {
                for (name, view) in [
                    ("Licenses", AnyView(AppLicensesView())),
                    ("Acknowledgments", AnyView(AppAcknowledgmentsView(inventory: AcknowledgmentsInventory())))
                ] {
                    let host = NSHostingView(rootView: view)
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 480)
                    host.layoutSubtreeIfNeeded()
                    check(host.window == nil && descendants(of: host).compactMap { $0 as? NSScrollView }
                        .allSatisfy { !$0.hasHorizontalScroller },
                        "\(name) uses a detached native legal surface at \(Int(width)) points in \(appearance.rawValue)")
                }
            }
        }
        check(AppLegalCopy.license.contains("GPL-3.0-only")
              && AppLegalCopy.acknowledgment.contains(FeaturedCredits.upstream.name)
              && AppLegalCopy.source.absoluteString == "https://github.com/WorkingPrinciple/xode-ui",
              "Legal destinations retain the app's exact license and existing upstream attribution without an invented organization")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [CGSize(width: 480, height: 480), CGSize(width: 560, height: 620)] {
                let session = LiveSession()
                let runtime = RuntimeProviderSettings()
                let welcome = NSHostingView(rootView: LiveWelcomeView(session: session, runtime: runtime,
                    operations: GameOperationsController(installed: InstalledGamesController()))
                    .environmentObject(AppState())
                    .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
                    .background(Color(nsColor: .windowBackgroundColor)))
                welcome.sizingOptions = []
                welcome.appearance = NSAppearance(named: appearance)
                welcome.frame = CGRect(origin: .zero, size: size)
                welcome.layoutSubtreeIfNeeded()
                let scrollViews = descendants(of: welcome).compactMap { $0 as? NSScrollView }
                check(welcome.window == nil && welcome.bounds.size == size && !scrollViews.isEmpty
                      && scrollViews.allSatisfy {
                          !$0.hasHorizontalScroller && ($0.documentView?.bounds.width ?? 0) <= size.width + 1
                      },
                      "X Ode welcome fits native \(appearance.rawValue) at \(Int(size.width)) points with a scrolling body")
                check(!session.hasConfirmedSignIn && !session.accountBusy
                      && !session.canStartWelcomeSignIn && !runtime.checkingDependency,
                      "Detached welcome layout cannot connect, sign in, inspect credentials or install CrossOver")
                if let directory = ProcessInfo.processInfo.environment["ODE_REFINEMENT_EVIDENCE"] {
                    saveDetachedEvidence(welcome, directory: directory,
                        name: "welcome-\(appearance.rawValue)-\(Int(size.width)).png", check: check)
                }
            }
        }
        let colours: [Color] = [.red, .green, .blue]
        let coverIssue = LibraryCompatibilityIssue(kind: .antiCheat, title: "Uses Easy Anti-Cheat",
            detail: "Synthetic title cannot run with this runtime.", source: nil)
        let statusCard = GameCard(title: "Synthetic title", compatibilityIssues: [coverIssue],
            showsGamePassCatalogBadge: true, open: {}) {
                Color.blue
            } status: { EmptyView() }
        check(statusCard.coverStatusDescription ==
              "In PC Game Pass catalog, Uses Easy Anti-Cheat. Synthetic title cannot run with this runtime.",
              "COR97/101: One existing cover control exposes catalog membership and exact compatibility reason without another keyboard stop")
        let packageCard = GameCard(title: "Unsupported PC title",
            compatibilityIssues: [LibraryCompatibilityIssue(kind: .packageType, title: "EAPPX",
                detail: GameSupportPolicy.issues(packageFormat: "EAPPX", antiCheat: nil)[0].detail, source: nil)], open: {}) {
                Color.blue
            } status: { EmptyView() }
        check(!packageCard.coverStatusDescription.contains("EAPPX")
              && !packageCard.coverStatusDescription.contains("MSIXVC")
              && packageCard.coverStatusDescription.contains("Not supported"),
              "REQ60/62: Card help and AX use plain compatibility state, never package format")
        let unknownCard = GameCard(title: "Unknown title", open: {}) {
            Color.blue
        } status: { EmptyView() }
        check(unknownCard.coverStatusDescription.isEmpty,
              "COR97/101: Unknown title gains neither a compatibility icon nor a membership claim")
        if let directory = ProcessInfo.processInfo.environment["ODE_REFINEMENT_EVIDENCE"] {
            for scheme in [ColorScheme.light, .dark] {
                let cards = HStack(alignment: .top, spacing: 24) { statusCard; unknownCard }
                    .padding(24).frame(width: 440, height: 400, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: cards)
                host.sizingOptions = []
                host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                host.frame = CGRect(x: 0, y: 0, width: 440, height: 400)
                host.layoutSubtreeIfNeeded()
                saveDetachedEvidence(host, directory: directory,
                    name: "cover-\(scheme == .light ? "light" : "dark").png", check: check)
            }
        }
        let covers = LazyVGrid(columns: LibraryGridLayout.columns, alignment: .leading, spacing: 30) {
            ForEach(0..<3) { index in
                GameCard(title: index == 1 ? "A longer two-line game title" : "Game \(index)",
                             open: {}) {
                    colours[index]
                } status: {
                    Text(Array(repeating: "Metadata", count: index + 1).joined(separator: "\n"))
                }
            }
        }
        .frame(width: 558, height: 520, alignment: .topLeading).background(.white)
        if let image = ImageRenderer(content: covers).cgImage,
           let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let bytes = context.data?.assumingMemoryBound(to: UInt8.self) {
                let starts = [85, 279, 473].enumerated().map { channel, x in
                    (0..<image.height).first { y in
                        let offset = (y * image.width + x) * 4
                        let colour = (0..<3).map { Int(bytes[offset + $0]) }
                        return colour[channel] > 128 &&
                            colour.enumerated().allSatisfy {
                                $0.offset == channel || $0.element < colour[channel] - 50
                            }
                    }
                }
                check(starts.allSatisfy { $0 != nil } && Set(starts.compactMap { $0 }).count == 1,
                      "Actual native cover grid aligns artwork despite unequal title and metadata heights")
            } else { check(false, "Native cover-grid pixels are available for alignment measurement") }
        } else { check(false, "Native cover grid renders offscreen without a window") }
        check(application.windows.count == windows,
              "Artwork alignment regression creates no native window or foreground action")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for reduceTransparency in [false, true] {
                let chrome = NSHostingView(rootView: HStack {
                    Picker("Navigate \(AppBrand.displayName)", selection: .constant(Destination.library)) {
                        Text("Library").tag(Destination.library)
                    }.pickerStyle(.segmented)
                    NativeToolbarSearch(text: .constant(""), focused: .constant(false), placeholder: "Search Library")
                }.modifier(NativeToolbarMaterial())
                    .environment(\.odeReviewReduceTransparency, reduceTransparency))
                chrome.sizingOptions = []
                chrome.appearance = NSAppearance(named: appearance)
                chrome.frame = CGRect(x: 0, y: 0, width: 460, height: 52)
                chrome.layoutSubtreeIfNeeded()
                check(chrome.window == nil && chrome.frame.height == 52,
                      "Native contrast chrome lays out detached in \(appearance.rawValue), app-local reduced-material fallback \(reduceTransparency)")
            }
        }
        if let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.clear(CGRect(x: 0, y: 0, width: 32, height: 16))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 8, y: 4, width: 16, height: 8))
            check(context.makeImage().map(LibraryLogoPolicy.isTransparent) == true,
                  "A real transparent title asset with visible ink qualifies as a hero logo")
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
            check(context.makeImage().map(LibraryLogoPolicy.isTransparent) == false,
                  "Opaque TitledHeroArt remains background artwork, not a fake transparent title logo")
            context.clear(CGRect(x: 0, y: 0, width: 32, height: 16))
            check(context.makeImage().map(LibraryLogoPolicy.isTransparent) == false,
                  "An empty transparent asset falls back to the accessible text title")
            context.setFillColor(CGColor(gray: 0.08, alpha: 1))
            context.fill(CGRect(x: 8, y: 4, width: 16, height: 8))
            check(context.makeImage().map(LibraryLogoPolicy.isTransparent) == false,
                  "A dark transparent logo falls back to the readable text title over dark hero art")
        } else { check(false, "Synthetic logo pixel context allocates without a window") }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(820), CGFloat(1440)] {
                let state = AppState()
                let session = LiveSession()
                let fixture = NSHostingView(rootView: FixtureLibraryView().environmentObject(state))
                fixture.sizingOptions = []
                fixture.appearance = NSAppearance(named: appearance)
                fixture.frame = CGRect(x: 0, y: 0, width: width, height: 874)
                fixture.layoutSubtreeIfNeeded()
                check(fixture.window == nil && fixture.frame.width == width && fixture.frame.height == 874,
                      "Library fixture lays out detached in \(appearance.rawValue) at \(Int(width)) points")
                let live = NSHostingView(rootView: LiveLibraryView(library: state.pcGames,
                    installed: state.installedGames, operations: state.gameOperations, query: "",
                    allowsStartupTasks: false, allowsArtworkLoading: false, browse: {}, recentActivity: {})
                    .environmentObject(session))
                live.sizingOptions = []
                live.appearance = NSAppearance(named: appearance)
                live.frame = CGRect(x: 0, y: 0, width: width, height: 874)
                live.layoutSubtreeIfNeeded()
                check(live.window == nil && session.phase == .disconnected && !state.pcGames.busy &&
                      !state.gameOperations.isBusy && !state.installedGames.loading,
                      "Library signed-out layout remains detached and side-effect-free at \(Int(width)) in \(appearance.rawValue)")
                for query in ["", "synthetic query"] {
                    let discover = NSHostingView(rootView: LiveCatalogView(library: state.pcGames,
                        installed: state.installedGames, operations: state.gameOperations, query: query,
                        allowsArtworkLoading: false, allowsStartupTasks: false, clearSearch: {})
                        .environmentObject(session))
                    discover.sizingOptions = []
                    discover.appearance = NSAppearance(named: appearance)
                    discover.frame = CGRect(x: 0, y: 0, width: width, height: 874)
                    discover.layoutSubtreeIfNeeded()
                    check(discover.window == nil && session.phase == .disconnected &&
                          !state.pcGames.busy && !state.gameOperations.isBusy,
                          "Discover \(query.isEmpty ? "browse" : "search") lays out without backend/media actions at \(Int(width)) in \(appearance.rawValue)")
                }
                do {
                    let product = try LibraryGame.details(id: "FIXTURE00002", title: "Original synthetic detail",
                        market: "US", language: "en-US", source: "synthetic-detail-layout", pcCandidate: true)
                    let detail = NSHostingView(rootView: LiveProductView(product: product, library: state.pcGames,
                        installedLibrary: state.installedGames, operations: state.gameOperations,
                        allowsStartupTasks: false, allowsArtworkLoading: false)
                        .environmentObject(session))
                    detail.sizingOptions = []
                    detail.appearance = NSAppearance(named: appearance)
                    detail.frame = CGRect(x: 0, y: 0, width: width, height: 780)
                    detail.layoutSubtreeIfNeeded()
                    check(detail.window == nil && session.phase == .disconnected && !state.gameOperations.isBusy,
                          "D3 missing-media detail remains detached and side-effect-free at \(Int(width)) in \(appearance.rawValue)")
                } catch { check(false, "D3 synthetic layout fixture decodes without real data") }
            }
        }
        let runtime = RuntimeProviderSettings()
        check(runtime.configuration == nil && runtime.plan == nil && !runtime.planning,
              "Runtime Settings start with no provider selected, no trial-default inheritance and no plan")
        for provider in RuntimeProviderKind.allCases {
            runtime.select(provider)
            check(runtime.configuration == .preset(provider) && runtime.plan == nil,
                  "Each native provider selection is a declaration, not installation or game evidence")
        }
        runtime.text(\.engine.version).wrappedValue = "11.0"
        runtime.text(\.graphics.version).wrappedValue = "4.0"
        check(runtime.configuration?.engine.version == "11.0"
              && runtime.configuration?.graphics.version == "4.0" && runtime.plan == nil,
              "Engine and graphics version bindings remain independent and invalidate previous planning evidence")
        runtime.text(\.engine.version).wrappedValue = ""
        check(runtime.configuration?.engine.version == nil && runtime.configuration?.graphics.version == "4.0",
              "Clearing a declared version means unknown, not a copied graphics version")
        for width in [CGFloat(440), CGFloat(560)] {
            let host = NSHostingView(rootView: Form {
                RuntimeProviderSection(settings: runtime, backendPath: "")
            }.formStyle(.grouped))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            host.layoutSubtreeIfNeeded()
            check(host.window == nil && host.frame.width == width,
                  "Runtime Settings allocate and lay out detached native controls at constrained Mac widths")
        }
        runtime.select(nil)
        check(runtime.configuration == nil && runtime.plan == nil && runtime.errorMessage == nil,
              "Clearing native provider selection leaves no fabricated default or plan")
        check(NativeToolbarSearch.width(text: "", focused: false) == 32
              && NativeToolbarSearch.width(text: "", focused: true) == 220,
              "Grouped native toolbar search stays compact until native editing or Command-F focus")
        let searchAccessibility = NativeToolbarSearch.collapsedAccessibility(for: "Search all games")
        check(searchAccessibility.label == "Search all games"
              && searchAccessibility.help == "Open catalogue search"
              && searchAccessibility.help != searchAccessibility.label,
              "REQ-19/59: Toolbar search help explains the action without repeating its accessible name")
        check(NativeToolbarSearch.width(text: "scoped query", focused: false) == 220,
              "A nonempty toolbar query retains the editor and native clear control after focus leaves")
        var lensFocus = false
        let searchState = AppState()
        searchState.navigate(.library)
        let lens = NativeToolbarSearch(text: .constant(""),
            focused: Binding(get: { lensFocus }, set: { lensFocus = $0 }),
            placeholder: "Search all games", openSearch: { searchState.navigate(.discover) })
        lens.expand()
        check(lensFocus && searchState.destination == .discover
              && NativeToolbarSearch.width(text: "", focused: lensFocus) == 220,
              "Header magnifier explicitly opens the global catalog and expands an empty editor before typing")
        lensFocus = false
        searchState.navigate(.downloads)
        var disabledLens = lens
        disabledLens.enabled = false
        disabledLens.expand()
        check(!lensFocus && searchState.destination == .downloads,
              "A disabled magnifier cannot navigate or request editor focus")
        for (query, focus, width) in [("", false, CGFloat(32)), ("", true, CGFloat(220)),
                                      ("scoped query", false, CGFloat(220))] {
            let host = NSHostingView(rootView: NativeToolbarSearch(
                text: .constant(query), focused: .constant(focus), placeholder: "Search your Library"))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 36)
            host.layoutSubtreeIfNeeded()
            let fields = descendants(of: host).compactMap { $0 as? NSSearchField }
            if width == 32 {
                check(host.window == nil && fields.isEmpty,
                      "Collapsed header search is an explicit action, not an unusable 32-point native editor")
            } else {
                check(host.window == nil && fields.count == 1
                      && fields.first.map { abs($0.bounds.width - width) < 1 && $0.window == nil } == true,
                      "Expanded toolbar layout contains one correctly sized detached native editor")
            }
        }
        var text = "old scope"
        var focused = false
        var edits = 0
        var search = NativeSearchField(
            text: Binding(get: { text }, set: { text = $0; edits += 1 }),
            focused: Binding(get: { focused }, set: { focused = $0 }),
            placeholder: "Search your Library")
        let coordinator = search.makeCoordinator()
        let field = search.makeField(coordinator: coordinator)
        let cell = field.cell as? NSSearchFieldCell
        check(field.window == nil && field.stringValue == text
              && field.placeholderString == "Search your Library",
              "Shared native search initializes text and scope without a window")
        check(field.accessibilityLabel() == NativeSearchField.accessibilityName
              && field.accessibilityLabel() != field.placeholderString,
              "REQ-19/59: Search editor has a concise accessibility name distinct from its visible placeholder")
        check(field.isBezeled && cell?.searchButtonCell != nil && cell?.cancelButtonCell != nil,
              "Shared search retains the stock bezel and one native search/cancel pair")
        let placeholderColor = field.placeholderAttributedString?
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        check(field.textColor == .controlTextColor && placeholderColor != .white,
              "Search uses semantic control text and the system placeholder appearance")
        field.stringValue = "edited query"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        coordinator.searchChanged(field)
        check(text == "edited query" && edits == 1,
              "Native edit notification and search action commit the query only once")
        field.stringValue = ""
        _ = field.sendAction(field.action, to: field.target)
        check(text.isEmpty && edits == 2, "The native clear/search action updates the same scoped binding")
        var resultRequests = 0
        search.showResults = { resultRequests += 1 }
        search.updateField(field, coordinator: coordinator)
        let editor = NSTextView()
        check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
              && coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
              && resultRequests == 2,
              "REQ-59: Down and Return in native search hand focus to results")
        check(GameSearchPresentation.focusReturnTarget(preferred: "known-title",
                available: ["other-title", "known-title"]) == "known-title"
              && GameSearchPresentation.focusReturnTarget(preferred: "removed-title",
                available: ["other-title"]) == nil,
              "REQ-11: Detail focus returns to its named title button only while that result remains available")
        text = "mortis"
        check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
              && text.isEmpty,
              "REQ-59: Escape clears the query using the same native search binding")
        focused = true
        check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
              && !focused
              && !DiscoverSearchOverlayLayout.isPresented(searchFocused: focused,
                  suggestionFocused: false, query: text, searches: ["Halo"]),
              "Escape from an empty native search resigns editor focus and dismisses recent suggestions")
        text = "next scope"
        search = NativeSearchField(text: search.$text, focused: search.$focused,
                                   placeholder: "Search Microsoft Store games")
        search.updateField(field, coordinator: coordinator)
        check(field.stringValue == "next scope" && field.placeholderString == search.placeholder && edits == 3,
              "Scope/binding refresh neither duplicates edits nor retains an old placeholder")
        focused = true
        search.enabled = false
        search.updateField(field, coordinator: coordinator)
        field.stringValue = "disabled edit"
        coordinator.searchChanged(field)
        check(!field.isEnabled && !field.wantsFocus && text == "next scope",
              "Disabled scoped search neither edits its binding nor requests focus")
        search.enabled = true
        search.updateField(field, coordinator: coordinator)
        check(field.wantsFocus && field.window == nil && field.stringValue == text,
              "Command-F focus intent survives re-enabling without creating or activating a window")
        check(NativeSearchField.endEditingClearsFocus(retired: false, attached: true, editing: false)
              && !NativeSearchField.endEditingClearsFocus(retired: false, attached: true, editing: true)
              && !NativeSearchField.endEditingClearsFocus(retired: false, attached: false, editing: false)
              && !NativeSearchField.endEditingClearsFocus(retired: true, attached: true, editing: false),
              "REQ-107: Only a settled, attached, current editor losing focus collapses search")
        focused = true
        search.updateField(field, coordinator: coordinator)
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        coordinator.settleEndEditing(field)
        check(focused && field.wantsFocus,
              "REQ-107: A toolbar rebuild that detaches the editor keeps the search the user opened")
        NativeSearchField.dismantleNSView(field, coordinator: coordinator)
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        check(focused && coordinator.retired && !field.wantsFocus,
              "REQ-107: A replaced editor's late notifications cannot change the new search")
        focused = false
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        check(!focused, "A retired editor cannot request focus for the replacement")
        search.updateField(field, coordinator: coordinator)
        check(!coordinator.retired && !field.wantsFocus, "A refreshed editor coordinator resumes ordinary focus tracking")

        var pressFocus = false, pressNavigations = 0
        let pressed = NativeToolbarSearch(text: .constant(""),
            focused: Binding(get: { pressFocus }, set: { pressFocus = $0 }),
            placeholder: "Search all games", openSearch: { pressNavigations += 1 })
        for _ in 0..<12 { pressed.expand() }
        check(pressFocus && pressNavigations == 12
              && NativeToolbarSearch.width(text: "", focused: pressFocus) == 220,
              "REQ-107: Repeated magnifier presses each reach the action and leave one expanded, focused editor")
        pressFocus = false
        for _ in 0..<12 {
            pressed.expand()
            pressFocus = false
        }
        pressed.expand()
        check(pressFocus && pressNavigations == 25,
              "REQ-107: Alternating press/dismiss cycles never leave the magnifier unresponsive")
        check(DiscoverLayout.contentTopInset(query: "forza", hasFeatured: true) == DiscoverLayout.toolbarClearance
              && DiscoverLayout.contentTopInset(query: "forza", hasFeatured: false) == DiscoverLayout.toolbarClearance
              && DiscoverLayout.contentTopInset(query: "", hasFeatured: false) == DiscoverLayout.toolbarClearance
              && DiscoverLayout.contentTopInset(query: "", hasFeatured: true) == 0
              && DiscoverLayout.toolbarClearance >= 80,
              "REQ-107: Search results start below the transparent toolbar, traffic lights and account button")
        // Detached hosting views don't hit-test; real click acceptance stays a native observation.
        check(NativeToolbarSearch.collapsedHitSize.width == NativeToolbarSearch.width(text: "", focused: false)
              && NativeToolbarSearch.collapsedHitSize.height >= 28,
              "REQ-107: The collapsed magnifier's rectangular hit shape spans its whole toolbar slot")

        let layout = AccountActionsLayout()
        let horizontalBounds = CGRect(x: 0, y: 0, width: 610, height: 28)
        let horizontal = layout.frames(for: [CGSize(width: 90, height: 28),
                                             CGSize(width: 110, height: 28),
                                             CGSize(width: 170, height: 28)], in: horizontalBounds)
        check(horizontal.count == 3 && horizontal.allSatisfy { horizontalBounds.contains($0) }
              && horizontal.last?.maxX == horizontalBounds.maxX
              && zip(horizontal, horizontal.dropFirst()).allSatisfy { $0.0.maxX <= $0.1.minX },
              "Roomy account footer has one nonoverlapping frame per action and a trailing primary action")
        let compactBounds = CGRect(x: 0, y: 0, width: 440, height: 108)
        let longTitles = [CGSize(width: 230, height: 28), CGSize(width: 250, height: 28),
                          CGSize(width: 310, height: 28)]
        let stacked = layout.frames(for: longTitles, in: compactBounds)
        check(stacked.count == 3 && stacked.allSatisfy { compactBounds.contains($0) }
              && zip(stacked, stacked.dropFirst()).allSatisfy { $0.0.maxY <= $0.1.minY },
              "Long pending/cancel/status/sign-in labels stack without duplicated or hidden actions")
        let mirrored = AccountActionsLayout(layoutDirection: .rightToLeft)
            .frames(for: longTitles, in: compactBounds)
        check(mirrored.count == stacked.count && mirrored.allSatisfy { $0.minX == compactBounds.minX },
              "The adaptive account footer respects right-to-left action alignment")
        typealias Sheet = AccountSheetLayout<Color, Text, Text>
        check(Sheet.headerHeight(for: 340) == 0 && Sheet.headerHeight(for: 620) < 210
              && Sheet.headerHeight(for: 700) == 210,
              "Account decoration shrinks before the stable footer at constrained heights")
        for size in [CGSize(width: 480, height: 480), CGSize(width: 650, height: 620)] {
            let footer = NSView()
            let host = NSHostingView(rootView: AccountSheetLayout(showsHeader: size.width > 500) {
                Color.clear
            } content: {
                Text(String(repeating: "Synthetic pending or failure explanation. ", count: 80))
                    .fixedSize(horizontal: false, vertical: true)
            } actions: {
                AccountActionsLayout {
                    Button("Cancel sign-in") {}
                    Button("Check status") {}
                    Button("Sign in with Microsoft") {}.disabled(true)
                }
                .accessibilityIdentifier("synthetic.account.footer")
                .background(LayoutWitness(view: footer))
            })
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            check(host.window == nil && host.bounds.size == size && host.fittingSize.height <= 700,
                  "Long synthetic Account body lays out offscreen within the bounded sheet size")
            let footerFrame = footer.convert(footer.bounds, to: host)
            check(footer.superview != nil && footerFrame.width > 0 && footerFrame.height > 0
                  && host.bounds.contains(footerFrame)
                  && !ancestors(of: footer).contains(where: { $0 is NSScrollView }),
                  "The synthetic Account action footer stays inside the sheet and outside scrolling content")
        }
        check(application.windows.count == windows && field.window == nil,
              "Native control/layout checks create no window, provider or backend connection")
    }

    static func checkLiveLayouts(session: LiveSession, check: (Bool, String) -> Void) {
        let windows = NSApplication.shared.windows.count
        let state = AppState()
        for destination in [Destination.discover, .library] {
            state.navigate(destination)
            for size in [CGSize(width: 820, height: 640), CGSize(width: 1200, height: 800)] {
                let host = NSHostingView(rootView: LiveRootView(allowsStartupTasks: false)
                    .environmentObject(state).environmentObject(session))
                host.sizingOptions = []
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let scrollViews = descendants(of: host).compactMap { $0 as? NSScrollView }
                check(host.window == nil && host.bounds.size == size
                      && (session.hasConfirmedSignIn ? !scrollViews.isEmpty : scrollViews.isEmpty)
                      && scrollViews.allSatisfy {
                          !$0.hasHorizontalScroller
                              && ($0.documentView?.bounds.width ?? 0) <= host.bounds.width + 1
                      },
                      "Replayed \(destination.rawValue) fits its viewport, with no game content when sign-in is unconfirmed")
            }
        }
        if let product = session.products.first {
            for size in [CGSize(width: 820, height: 600), CGSize(width: 1040, height: 780), CGSize(width: 1200, height: 850)] {
                let host = NSHostingView(rootView: LiveProductView(product: product, library: state.pcGames,
                    installedLibrary: state.installedGames, operations: state.gameOperations,
                    allowsStartupTasks: false, allowsArtworkLoading: false)
                    .environmentObject(session))
                host.sizingOptions = []
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let scrollViews = descendants(of: host).compactMap { $0 as? NSScrollView }
                check(host.window == nil && host.fittingSize.width <= 1200 && host.fittingSize.height <= 850
                      && scrollViews.allSatisfy {
                          !$0.hasHorizontalScroller && ($0.documentView?.bounds.width ?? 0) <= size.width + 1
                      },
                      "Replayed public multi-edition detail fits constrained and expanded native sheets without horizontal scrolling")
                check(!scrollViews.isEmpty && scrollViews.allSatisfy { !$0.hasHorizontalScroller },
                      "D3 detail retains native vertical scrolling at constrained and expanded sheet sizes")
            }
        }
        let consent = GameInstallConsent(game: PCGame(id: "FIXTURE00002", title: "Original Ridge", artwork: nil),
            destination: URL(fileURLWithPath: "/Users/Shared/Ode Games/Original Ridge"),
            freeBytes: 80_000_000_000, installedID: nil,
            compatibility: GameCompatibilityResult(storeId: "FIXTURE00002", packageBytes: 3_200_000_000,
                supported: true, reason: nil, checkedAt: "2026-10-07T00:00:00Z"))
        checkConsentContentHeight(operations: state.gameOperations, consent: consent, check: check)
        for size in [CGSize(width: 520, height: 440), CGSize(width: 640, height: 680)] {
            let install = NSHostingView(rootView: GameInstallConsentView(
                operations: state.gameOperations, consent: consent))
            install.sizingOptions = []
            install.frame = CGRect(origin: .zero, size: size)
            install.layoutSubtreeIfNeeded()
            let scrollViews = descendants(of: install).compactMap { $0 as? NSScrollView }
            let buttons = descendants(of: install).compactMap { $0 as? NSButton }
            check(install.window == nil && !scrollViews.isEmpty && buttons.count >= 2
                  && scrollViews.allSatisfy { !$0.hasHorizontalScroller },
                  "D4 install review uses a bounded native Form with reachable Cancel and Install actions")
        }
        let downloads = NSHostingView(rootView: LiveActivityView(operations: state.gameOperations,
                                                                 queue: state.downloadQueue)
            .environmentObject(session))
        downloads.sizingOptions = []
        downloads.frame = CGRect(x: 0, y: 0, width: 820, height: 600)
        downloads.layoutSubtreeIfNeeded()
        check(downloads.window == nil &&
              !descendants(of: downloads).compactMap { $0 as? NSTableView }.isEmpty &&
              descendants(of: downloads).compactMap { $0 as? NSScrollView }.allSatisfy {
                  !$0.hasHorizontalScroller
              },
              "D5 Downloads uses a native inset List without horizontal overflow")
        let account = NSHostingView(rootView: LiveAccountView(refreshStatusOnAppear: false)
            .environmentObject(state).environmentObject(session))
        account.sizingOptions = []
        account.frame = CGRect(x: 0, y: 0, width: 560, height: 480)
        account.layoutSubtreeIfNeeded()
        check(account.window == nil && NSApplication.shared.windows.count == windows
              && session.authentication == nil && !session.accountBusy && !session.signInPending,
              "Lean Account and live-data layouts create no window or credential request")
        let accountButtons = descendants(of: account).compactMap { $0 as? NSButton }
        check(!accountButtons.isEmpty && accountButtons.allSatisfy {
            !["Technical details", "Downloaded artwork", "Troubleshoot game setup", "Achievements", "Licenses", "Acknowledgments"]
                .contains($0.title)
        }, "Login keeps support, artwork and separate account destinations out of its action surface")
        let gameAccess = NSHostingView(rootView: GameServiceSignInActions(
            operations: state.gameOperations, statusText: state.gameOperations.serviceLabel,
            statusIdentifier: "ode.check.gameServiceStatus",
            checkIdentifier: "ode.check.gameServiceStatusAction",
            signInIdentifier: "ode.check.gameServiceSignIn",
            errorIdentifier: "ode.check.gameServiceError",
            logIdentifier: "ode.check.gameServiceLog",
            verifyIdentifier: "ode.check.gameServiceVerify"))
        gameAccess.sizingOptions = []
        gameAccess.frame = CGRect(x: 0, y: 0, width: 520, height: 300)
        gameAccess.layoutSubtreeIfNeeded()
        check(gameAccess.window == nil && !state.gameOperations.serviceBusy
              && state.gameOperations.serviceStatus == nil,
              "Detached Xbox game-service actions create no window or authentication request")
        for route in [AccountDestination.profile, .achievements, .consoles, .engines] {
            state.accountDestination = route
            let destination = NSHostingView(rootView: LiveAccountView(refreshStatusOnAppear: false)
                .environmentObject(state).environmentObject(session))
            destination.sizingOptions = []
            destination.frame = CGRect(x: 0, y: 0, width: 560, height: 620)
            destination.layoutSubtreeIfNeeded()
            check(destination.window == nil && NSApplication.shared.windows.count == windows
                  && !descendants(of: destination).compactMap { $0 as? NSScrollView }.isEmpty
                  && session.authentication == nil && !session.accountBusy,
                  "Account hub \(route.rawValue) destination lays out natively without starting authentication")
        }
        state.accountDestination = .account
        state.showingSetup = true
        let setupAccount = NSHostingView(rootView: LiveAccountView(refreshStatusOnAppear: false)
            .environmentObject(state).environmentObject(session))
        setupAccount.sizingOptions = []
        setupAccount.frame = CGRect(x: 0, y: 0, width: 480, height: 280)
        setupAccount.layoutSubtreeIfNeeded()
        check(setupAccount.window == nil && NSApplication.shared.windows.count == windows
              && state.gameOperations.setupResult == nil && !state.gameOperations.setupBusy
              && session.authentication == nil && !session.accountBusy,
              "Setup-focused Account allocates native controls without unrelated credentials, scripts or windows")
    }

    static func checkConsentContentHeight(operations: GameOperationsController, consent: GameInstallConsent,
                                         check: (Bool, String) -> Void) {
        var resume = consent
        resume.resuming = true
        var failed = consent
        failed.checkError = "The game drive couldn't be reached. Reconnect the drive and try again before installing."
        for width: CGFloat in [520, 640] {
            var heights: [CGFloat] = []
            for (name, fixture) in [("ordinary", consent), ("resume", resume), ("error", failed)] {
                let host = NSHostingView(rootView: GameInstallConsentView(operations: operations, consent: fixture))
                host.frame.size.width = width
                host.layoutSubtreeIfNeeded()
                let height = host.fittingSize.height
                heights.append(height)
                host.frame = CGRect(x: 0, y: 0, width: width, height: height)
                host.layoutSubtreeIfNeeded()
                let buttons = descendants(of: host).compactMap { $0 as? NSButton }
                let footer = buttons.filter {
                    let rect = $0.convert($0.bounds, to: host)
                    return host.isFlipped ? rect.midY > height - 80 : rect.midY < 80
                }
                let scrolls = descendants(of: host).compactMap { $0 as? NSScrollView }
                check(host.window == nil && height > 200 && height <= 620 && footer.count == 2
                      && footer.allSatisfy { host.bounds.contains($0.convert($0.bounds, to: host)) }
                      && scrolls.allSatisfy { !$0.hasHorizontalScroller },
                      "COR171: \(name) consent at \(Int(width)) fits its content and both footer actions (\(height), footer \(footer.count))")
                if let directory = ProcessInfo.processInfo.environment["ODE_REFINEMENT_EVIDENCE"] {
                    saveDetachedEvidence(host, directory: directory, name: "cor171-\(name)-\(Int(width)).png", check: check)
                }
            }
            // REQ114 I3/M6: resume now carries the restart note and Discard, so it differs from (not shrinks below) a fresh install.
            check(heights[1] != heights[0] && heights[2] > max(heights[0], heights[1]),
                  "COR171: Sheet height follows resume and recovery content instead of retaining blank fixed height (\(heights))")
        }
    }

    private static func saveDetachedEvidence(_ host: NSView, directory: String, name: String,
                                             check: (Bool, String) -> Void) {
        do {
            guard host.window == nil,
                  let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                check(false, "Detached refinement evidence has a bitmap without a native window")
                return
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                check(false, "Detached refinement evidence encodes PNG")
                return
            }
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name))
            check(true, "Detached refinement evidence saved: \(name)")
        } catch {
            check(false, "Detached refinement evidence failed: \(error.localizedDescription)")
        }
    }

    static func checkWelcomePrivacy(installed: InstalledGamesController, check: (Bool, String) -> Void) {
        let windows = NSApplication.shared.windows.count
        let state = AppState(installedGames: installed)
        let session = LiveSession()
        let savedGames = installed.games
        check(!savedGames.isEmpty, "Welcome privacy regression starts with actual synthetic installed records")
        for destination in Destination.allCases {
            state.navigate(destination)
            let host = NSHostingView(rootView: LiveRootView(allowsStartupTasks: false)
                .environmentObject(state).environmentObject(session))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: 820, height: 600)
            host.layoutSubtreeIfNeeded()
            check(host.window == nil && !session.hasConfirmedSignIn
                  && descendants(of: host).allSatisfy { !($0 is NSScrollView) }
                  && installed.games == savedGames,
                  "Signed-out \(destination.rawValue) mounts no game/catalog/download content and preserves installed records")
        }
        check(NSApplication.shared.windows.count == windows && !session.accountBusy,
              "Welcome privacy checks create no app window, backend, sign-in or registration mutation")
    }

    static func checkMainLibraryWithHistory(session: LiveSession, check: (Bool, String) -> Void) {
        let windows = NSApplication.shared.windows.count
        let state = AppState()
        for size in [CGSize(width: 820, height: 600), CGSize(width: 1200, height: 860)] {
            let host = NSHostingView(rootView: LiveRootView(allowsStartupTasks: false)
                .environmentObject(state).environmentObject(session))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let scrollViews = descendants(of: host).compactMap { $0 as? NSScrollView }
            check(host.window == nil && host.bounds.size == size && !state.showsRecentActivity
                  && scrollViews.allSatisfy {
                      !$0.hasHorizontalScroller && ($0.documentView?.bounds.width ?? 0) <= size.width + 1
                  },
                  "Main Library stays unavailable and fits native viewports even when history exists in memory")
        }
        check(NSApplication.shared.windows.count == windows && !session.accountBusy,
              "Retained-history Library layout checks show no window and start no activity load")
    }

    private static func checkWelcomeTerminationPolicy(check: (Bool, String) -> Void) {
        let welcomeWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 620),
                                     styleMask: [.titled], backing: .buffered, defer: true)
        let otherModal = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 480),
                                  styleMask: [.titled], backing: .buffered, defer: true)
        welcomeWindow.isReleasedWhenClosed = false
        otherModal.isReleasedWhenClosed = false
        defer {
            welcomeWindow.close()
            otherModal.close()
        }
        welcomeWindow.preventsApplicationTerminationWhenModal = true
        otherModal.preventsApplicationTerminationWhenModal = true
        let policyHost = NSHostingView(rootView: WelcomeSheetTerminationBridge()
            .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true))
        policyHost.sizingOptions = []
        policyHost.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        welcomeWindow.contentView?.addSubview(policyHost)
        policyHost.layoutSubtreeIfNeeded()
        guard let policyView = descendants(of: policyHost)
            .compactMap({ $0 as? WelcomeSheetTerminationBridge.WindowPolicyView }).first else {
            check(false, "XO-010: SwiftUI welcome bridge creates its native window policy view")
            return
        }
        check(policyView.window === welcomeWindow
              && !welcomeWindow.preventsApplicationTerminationWhenModal
              && otherModal.preventsApplicationTerminationWhenModal,
              "XO-010: Actual native window attachment disables only welcome's AppKit modal Quit blocker")
        policyView.removeFromSuperview()
        check(welcomeWindow.preventsApplicationTerminationWhenModal,
              "XO-010: Leaving welcome restores the original native modal policy for later account/installer sheets")
        otherModal.preventsApplicationTerminationWhenModal = false
        otherModal.contentView?.addSubview(policyView)
        WelcomeSheetTerminationBridge.dismantleNSView(policyView, coordinator: ())
        check(!otherModal.preventsApplicationTerminationWhenModal,
              "XO-010: SwiftUI dismantling preserves a window's originally nonblocking policy")
        policyView.removeFromSuperview()
        welcomeWindow.contentView?.addSubview(policyView)
        WelcomeSheetTerminationBridge.dismantleNSView(policyView, coordinator: ())
        check(welcomeWindow.preventsApplicationTerminationWhenModal
              && !welcomeWindow.isVisible && !otherModal.isVisible,
              "XO-010: Dismantling restores a blocking policy without presenting, dismissing or terminating an app")
        policyView.removeFromSuperview()
    }

    static func checkOperationFeedback(operations: GameOperationsController,
                                      installed: InstalledGamesController, game: PCGame,
                                      expectedStatus: String, cancelTitle: String?,
                                      check: (Bool, String) -> Void) {
        let windows = NSApplication.shared.windows.count
        let session = LiveSession()
        let catalog = NSHostingView(rootView: LiveCatalogView(
            library: PCGamesController(), installed: installed, operations: operations, query: "",
            allowsArtworkLoading: false, allowsStartupTasks: false, allowsHeroAnimation: false,
            clearSearch: {}).environmentObject(session))
        catalog.sizingOptions = []
        catalog.frame = CGRect(x: 0, y: 0, width: 820, height: 720)
        catalog.layoutSubtreeIfNeeded()
        let feedback = GameOperationProgressView(operations: operations)
        let installAction = GameInstallAction(game: game, operations: operations)
        check((installAction.preparing || installAction.active)
                ? installAction.registrationStatusTitle(installed: false) == nil
                : installAction.registrationStatusTitle(installed: false) != nil,
              "COR178: Active preparation/installation never renders a contradictory Not installed row status")
        let actionHost = NSHostingView(rootView: installAction)
        actionHost.sizingOptions = []
        actionHost.frame = CGRect(x: 0, y: 0, width: 230, height: 180)
        actionHost.layoutSubtreeIfNeeded()
        check(actionHost.window == nil && actionHost.fittingSize.width.isFinite
              && (operations.installingDirectly
                  ? installAction.preparing && installAction.showsCancel
                    && installAction.statusTitle == "Preparing installation"
                  : operations.operation != nil
                  ? installAction.active && installAction.showsCancel && operations.progress != nil
                  : installAction.failed && installAction.actionTitle == "Retry"),
              "UI-9 source: Shared tile/detail Install controls reflect preparation, byte progress/cancel or failure/retry")
        let availableCancellation = feedback.preparationCancelTitle ?? feedback.installCancelTitle
        check(catalog.window == nil && operations.hasDownloadStatus
              && (cancelTitle.map { availableCancellation == $0 } ?? (feedback.operationError == expectedStatus)),
              "F1: Detached Discover mounts with shared \(expectedStatus) feedback and applicable cancel presentation")
        let welcome = NSHostingView(rootView: LiveWelcomeView(session: session,
            runtime: RuntimeProviderSettings(), operations: operations)
            .environmentObject(AppState(installedGames: installed)))
        welcome.sizingOptions = []
        welcome.frame = CGRect(x: 0, y: 0, width: 480, height: 620)
        welcome.layoutSubtreeIfNeeded()
        let restricted = GameOperationProgressView(operations: operations, privacyRestricted: true)
        let restrictedCancellation = restricted.preparationCancelTitle ?? restricted.installCancelTitle
        check(welcome.window == nil
              && !descendants(of: welcome).compactMap { $0 as? NSScrollView }.isEmpty
              && (cancelTitle.map { restrictedCancellation == $0 } ?? true)
              && restricted.operationTitle != game.title && restricted.operationTitle != game.id
              && !restricted.showsLog && !restricted.showsGameSignIn
              && restricted.operationNotice == nil,
              "F2: Detached locked welcome retains cancel presentation without private title/product/log/account actions")
        if operations.error != nil {
            check(restricted.operationError == "The game operation needs attention. Sign in to review its details."
                  && restricted.operationError != expectedStatus,
                  "F2: Locked failure guidance redacts the underlying operation error")
        } else {
            check(operations.installingDirectly ? restricted.preparationTitle.contains(expectedStatus)
                  : restricted.operationTitle == "Game operation in progress" && operations.progress != nil,
                  "F2: Locked welcome shows the real preparation/progress state without unlocking browsing")
        }
        check(NSApplication.shared.windows.count == windows && !session.accountBusy
              && !session.hasConfirmedSignIn,
              "F1/F2: Feedback layouts create no window, management request or sign-in")
    }

    private static func ancestors(of view: NSView) -> [NSView] {
        guard let parent = view.superview else { return [] }
        return [parent] + ancestors(of: parent)
    }

    private static func checkContinuePlayingScroller(check: (Bool, String) -> Void) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: ContinuePlayingScrollView {
                HStack(spacing: 20) {
                    ForEach(0..<7) { index in
                        Button("Fixture title \(index + 1)") {}.frame(width: 260, height: 150)
                    }
                }.scrollTargetLayout()
            }.background(Color.blue.opacity(0.25)))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(x: 0, y: 0, width: 820, height: 200)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            host.layoutSubtreeIfNeeded()
            guard let scroll = descendants(of: host).compactMap({ $0 as? NSScrollView }).first else {
                check(false, "REQ-76: Continue Playing has an actual native horizontal scroll view")
                continue
            }
            scroll.scrollerStyle = .legacy
            scroll.autohidesScrollers = false
            scroll.tile()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            host.layoutSubtreeIfNeeded()
            check(!scroll.drawsBackground && !scroll.contentView.drawsBackground,
                  "REQ-76: The actual shelf has no opaque native scroll/clip background in \(appearance.rawValue)")
            check(!scroll.hasHorizontalScroller || scroll.horizontalScroller?.isHidden == true,
                  "COR-64: Only the shelf indicator stays hidden even with instance-local legacy style in \(appearance.rawValue)")
            let native = NSScrollView(frame: host.bounds)
            native.hasHorizontalScroller = true
            native.scrollerStyle = .legacy
            native.hasHorizontalScroller = false
            let document = NSView(frame: NSRect(x: 0, y: 0, width: 7 * 280 - 20, height: 150))
            native.documentView = document
            native.tile()
            let maxX = document.bounds.width - native.contentView.bounds.width
            native.contentView.scroll(to: NSPoint(x: maxX, y: 0))
            native.reflectScrolledClipView(native.contentView)
            check(maxX > 0 && native.contentView.bounds.maxX >= document.bounds.maxX - 1
                  && !native.hasHorizontalScroller,
                  "COR-64: Native seven-card document remains scrollable without a visible indicator in \(appearance.rawValue)")
            check(host.window == nil, "REQ-76: Shelf regression never opens a window or changes global preferences")
        }
    }

    private static func checkLoadingPresentation(check: (Bool, String) -> Void) {
        for pending in [false, true] {
            for content in [false, true] {
                for failed in [false, true] {
                    for accountAction in [false, true] {
                        for query in ["", "mortis"] {
                            let actual = LibraryLoadingPresentation.showsPlaceholders(pending: pending,
                                hasUsableContent: content, failed: failed,
                                requiresAccountAction: accountAction, query: query)
                            check(actual == (pending && !content && !failed && !accountAction && query.isEmpty),
                                  "REQ-75: Cold placeholders pending=\(pending) content=\(content) error=\(failed) consent=\(accountAction) query=\(query)")
                        }
                    }
                }
            }
        }
        check(GameLaunchPresentation.title(game: "Neutral game", stopping: false, checking: true, started: false)
                == "Checking Neutral game"
              && GameLaunchPresentation.title(game: "Neutral game", stopping: false, checking: false, started: false)
                == "Preparing Neutral game"
              && GameLaunchPresentation.title(game: "Neutral game", stopping: false, checking: false, started: true)
                == "Opening Neutral game"
              && GameLaunchPresentation.title(game: "Neutral game", stopping: true, checking: true, started: true)
                == "Stopping Neutral game",
              "REQ-75: Actual launch facts name checking/preparation/opening/stop without invented progress or success")
        for size in [CGSize(width: 820, height: 600), CGSize(width: 1440, height: 874),
                     CGSize(width: 1619, height: 1231)] {
            let host = NSHostingView(rootView: ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    OdeLoadingStatus(title: "Loading your PC games")
                    LibraryLoadingPlaceholders()
                }.padding(56)
            })
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            check(host.window == nil && host.fittingSize.width <= size.width + 1
                  && descendants(of: host).compactMap { $0 as? NSButton }.isEmpty,
                  "REQ-75: Static placeholders fit \(Int(size.width))x\(Int(size.height)) without window or actions")
        }
    }

    private static func checkActionExtentObservation(check: (Bool, String) -> Void) {
        let selection = LibrarySelection()
        var changes = 0
        let host = NSHostingView(rootView: ExtentObservationCheck(selection: selection) { changes += 1 })
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 820, height: 600)
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        check(changes == 0, "Initial nil action extent does not create a self-invalidating subscription")
        selection.collectionHeaderFrame = CGRect(x: 0, y: 100, width: 820, height: 40)
        selection.collectionViewportFrame = CGRect(x: 0, y: 0, width: 820, height: 600)
        selection.measureScroll(LibraryScrollMeasurement(offsetY: 400, contentHeight: 1500,
            containerHeight: 600, containerWidth: 820, insetTop: 0, insetBottom: 0,
            visibleY: 400, visibleMaxY: 1000, visibleHeight: 600))
        selection.prepareScopeExtent()
        settle()
        check(changes == 1, "A real action extent change invalidates the outer document exactly once")
        selection.prepareScopeExtent()
        selection.filter = .owned
        settle()
        check(changes == 1, "Equal extents and unrelated selection updates do not replay a document revision")
        selection.clearScopeExtent()
        settle()
        selection.clearScopeExtent()
        settle()
        check(changes == 2 && host.window == nil,
              "Clearing an extent publishes once and settles without a window or backend")
    }

    private struct ExtentObservationCheck: View {
        let selection: LibrarySelection
        let changed: () -> Void
        @State private var revision = 0

        var body: some View {
            Text("Revision \(revision)")
                .modifier(LibraryActionExtentObserver(selection: selection) {
                    revision += 1
                    changed()
                })
        }
    }

    private static func checkDetailFirstCards(check: (Bool, String) -> Void) {
        var opened = 0
        let card = GameCard(title: "A game with a longer two-line title", openLabel: "View",
                            open: { opened += 1 }) {
            Color.blue
        } status: { EmptyView() }
        check(card.openFromKeyboard() == .handled && opened == 1
              && card.artworkAccessibilityLabel == "View A game with a longer two-line title",
              "REQ-85: A named poster Return opens details once without starting play or installation")
        let host = NSHostingView(rootView: card.frame(width: 196))
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        check(height >= 196 * 1.5 + 36 && height < 196 * 1.5 + 70 && host.window == nil,
              "REQ-85: A 196-point poster reserves its art/title but no hidden or persistent action-row height: \(height)")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private struct LayoutWitness: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }
}
