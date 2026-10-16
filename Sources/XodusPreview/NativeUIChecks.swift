// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import XodusCore

@MainActor
enum NativeUIChecks {
    static func run(check: (Bool, String) -> Void) {
        do { try RecentLibraryChecks.imageChecks(check: check) }
        catch { check(false, "Native image threshold/thumbnail checks complete without network access") }
        let application = NSApplication.shared
        let windows = application.windows.count
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [CGSize(width: 480, height: 480), CGSize(width: 560, height: 620)] {
                let session = LiveSession()
                let runtime = RuntimeProviderSettings()
                let welcome = NSHostingView(rootView: LiveWelcomeView(session: session, runtime: runtime))
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
            }
        }
        let colours: [Color] = [.red, .green, .blue]
        let covers = LazyVGrid(columns: LibraryGridLayout.columns, alignment: .leading, spacing: 30) {
            ForEach(0..<3) { index in
                LibraryCover(title: index == 1 ? "A longer two-line game title" : "Game \(index)",
                             open: {}) {
                    colours[index]
                } status: {
                    Text(Array(repeating: "Metadata", count: index + 1).joined(separator: "\n"))
                } actions: { EmptyView() }
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
                    Picker("Navigate Xodus", selection: .constant(Destination.library)) {
                        Text("Library").tag(Destination.library)
                    }.pickerStyle(.segmented)
                    NativeToolbarSearch(text: .constant(""), focused: .constant(false), placeholder: "Search Library")
                }.modifier(NativeToolbarMaterial())
                    .environment(\.xodusReviewReduceTransparency, reduceTransparency))
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
        check(NativeToolbarSearch.width(text: "scoped query", focused: false) == 220,
              "A nonempty toolbar query retains the editor and native clear control after focus leaves")
        for (query, focus, width) in [("", false, CGFloat(32)), ("", true, CGFloat(220)),
                                      ("scoped query", false, CGFloat(220))] {
            let host = NSHostingView(rootView: NativeToolbarSearch(
                text: .constant(query), focused: .constant(focus), placeholder: "Search your Library"))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 36)
            host.layoutSubtreeIfNeeded()
            let fields = descendants(of: host).compactMap { $0 as? NSSearchField }
            check(host.window == nil && fields.count == 1
                  && fields.first.map { abs($0.bounds.width - width) < 1 && $0.window == nil } == true,
                  "Compact/expanded toolbar layout contains exactly one correctly sized detached native editor")
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
        text = "next scope"
        search = NativeSearchField(text: search.$text, focused: search.$focused,
                                   placeholder: "Search Microsoft Store games")
        search.updateField(field, coordinator: coordinator)
        check(field.stringValue == "next scope" && field.placeholderString == search.placeholder && edits == 2,
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
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        search.updateField(field, coordinator: coordinator)
        check(!focused && !field.wantsFocus, "Ending native editing clears the shared focus intent")

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
            destination: URL(fileURLWithPath: "/Users/Shared/Xodus Games/Original Ridge"),
            freeBytes: 80_000_000_000, installedID: nil,
            compatibility: GameCompatibilityResult(storeId: "FIXTURE00002", packageBytes: 3_200_000_000,
                supported: true, reason: nil, checkedAt: "2026-10-07T00:00:00Z"))
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
                  && !scrollViews.isEmpty && scrollViews.allSatisfy {
                      !$0.hasHorizontalScroller && ($0.documentView?.bounds.width ?? 0) <= size.width + 1
                  },
                  "Main Library stays unavailable and fits native viewports even when history exists in memory")
        }
        check(NSApplication.shared.windows.count == windows && !session.accountBusy,
              "Retained-history Library layout checks show no window and start no activity load")
    }

    private static func ancestors(of view: NSView) -> [NSView] {
        guard let parent = view.superview else { return [] }
        return [parent] + ancestors(of: parent)
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
