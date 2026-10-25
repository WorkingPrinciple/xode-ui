// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import AppKit
import SwiftUI
import Vision
import XodusManagement

/// COR-186/REQ-114 beta UX regressions: brand, onboarding, Engines, Discover hero, toolbar
/// accessibility, menus and jargon. Detached views and synthetic state only; no window activation,
/// sign-in, network, engine inspection or game action.
@MainActor
enum BrandUXChecks {
    static let renderDirectory = ProcessInfo.processInfo.environment["XODUS_UX_RENDER_DIRECTORY"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    static func run(check: (Bool, String) -> Void) {
        if let renderDirectory {
            try? FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
        }
        brand(check: check)
        navigation(check: check)
        engines(check: check)
        heroContrast(check: check)
        toolbarAccessibility(check: check)
        welcome(check: check)
        readiness(check: check)
        support(check: check)
        jargon(check: check)
    }

    // MARK: Brand

    static func brand(check: (Bool, String) -> Void) {
        check(AppBrand.displayName == "Xode" && AppBrand.company == "Working Principle"
              && AppBrand.website == "xode.win" && AppBrand.versionLabel == "0.11.4 Beta"
              && AppBrand.nameWithChannel == "Xode Beta" && AppBrand.supportTitle == "Xode Beta Support"
              && AppBrand.copyright == "© Working Principle · xode.win",
              "COR186: One AppBrand defines Xode, Working Principle, xode.win and 0.11.4 Beta")
        let about = AppBrandPresentation.aboutPanelOptions
        check(about[.applicationName] as? String == "Xode"
              && about[.applicationVersion] as? String == "0.11.4 Beta"
              && (about[.credits] as? NSAttributedString)?.string == "© Working Principle · xode.win",
              "COR186/COR187: About shows Xode 0.11.4 Beta and © Working Principle · xode.win")
        let session = LiveSession()
        let copy = [WelcomeCopy.title, WelcomeCopy.tagline, WelcomeCopy.account, WelcomeCopy.signIn, WelcomeCopy.keychain,
                    EnginesCopy.lead, EnginesCopy.crossOver, EnginesCopy.crossOverLicense,
                    session.accountLabel, LiveSession.signOutConfirmationMessage, session.libraryMessage,
                    ManagementError.stateLocked.errorDescription ?? "", ManagementError.startFailed.errorDescription ?? "",
                    AppLegalCopy.acknowledgment, AppLegalCopy.trademarks,
                    LibraryPackageFormatLabel.help(format: "MSIXVC")]
            + GameSupportPolicy.issues(packageFormat: "EAppx", antiCheat: "BattlEye").map(\.detail)
        let retired = copy.filter { text in
            AppBrand.retiredNames.contains { text.contains($0) }
                || text.range(of: #"\bOde\b"#, options: .regularExpression) != nil
                || text.contains("Xodus returned") || text.contains("Xodus engine")
        }
        check(retired.isEmpty && session.accountLabel == "Connect Xode"
              && LiveSession.signOutConfirmationMessage.contains("from Xode on this Mac")
              && AppLegalCopy.acknowledgment.contains("Xodus"),
              "COR186: User-visible copy names Xode only, keeping the upstream Xodus credit: \(retired)")
    }

    // MARK: Navigation, Find and Refresh

    static func navigation(check: (Bool, String) -> Void) {
        let state = AppState()
        let session = LiveSession()
        state.navigate(.discover)
        state.query = "halo"
        state.navigate(.library)
        state.selectTab(.discover)
        check(state.destination == .discover && state.query.isEmpty,
              "COR186 M5: Choosing the Discover tab after a search opens Discover home, not stale results")
        state.query = "forza"
        state.navigationSelection.wrappedValue = .discover
        check(state.destination == .discover && state.query.isEmpty,
              "COR186 M5: Re-choosing Discover from the toolbar tabs returns to Discover home")
        state.query = "ori"
        state.navigate(.library)
        state.navigate(.discover)
        check(state.query == "ori",
              "REQ-8: Programmatic navigation (search, Find in Store) still keeps the Discover query")
        state.navigate(.library)
        state.query = "library filter"
        state.selectTab(.discover)
        state.selectTab(.library)
        check(state.destination == .library && state.query == "library filter",
              "REQ-8: Choosing the Library tab keeps its own query")
        let before = state.searchFocusRequest
        state.query = ""
        state.navigate(.discover)
        state.query = "dredge"
        state.navigate(.downloads)
        state.requestSearchFocus()
        check(state.searchFocusRequest == before + 1 && state.destination == .discover && state.query == "dredge",
              "COR186 menu: Edit ▸ Find… opens Discover search with the current search kept")
        check(!state.canRefresh(session: session),
              "COR186 menu: View ▸ Refresh is disabled while Discover isn't connected")
        state.navigate(.downloads)
        check(!state.canRefresh(session: session),
              "COR186 menu: View ▸ Refresh is disabled for Downloads without an activity service")
    }

    // MARK: Engines

    static func engines(check: (Bool, String) -> Void) {
        let names = [
            "calimocho-wine11.20-gptk4b3-tls-vulkan-private",
            "calimocho-wine11.20-gptk4b3-tls-vulkan",
            "calimocho-wine11.20-gptk4b3-ags54-minidump-dirt5",
            "calimocho-wine11.20-gptk4b3-gameinput-empty-witcher"
        ].map(EngineDisplayName.presentation(for:))
        check(names.map(\.name) == ["Calimocho", "Calimocho (alternate build)", "Calimocho for DIRT 5",
                                    "Calimocho for The Witcher"]
              && names.map(\.detail) == ["Wine 11.20", "Wine 11.20",
                                         "Wine 11.20 · Tuned for DIRT 5 only", "Wine 11.20 · Tuned for The Witcher only"]
              && names.map(\.titleSpecific) == [false, false, true, true]
              && !names.contains { $0.name.contains("Private") || $0.name.contains("11.20") },
              "COR186 U2: Engines use plain names with a secondary line; game-specific builds say so")
        check(EngineDisplayName.name(nil) == "Calimocho" && EngineDisplayName.name("Wine Staging") == "Wine Staging"
              && EngineChoice.named("calimocho-wine11.20-gptk4b3-tls-vulkan-private", ready: true).id
                == "calimocho-wine11.20-gptk4b3-tls-vulkan-private",
              "COR186 U2: Display names never change engine IDs, and unknown engines keep their own names")
        let ready = EngineChoice.named("calimocho-wine11.20-gptk4b3-tls-vulkan-private", ready: true)
        let failed = EngineChoice.named("calimocho-wine11.20-gptk4b3-tls-vulkan-private", ready: false)
        check(CalimochoAvailability.from(choices: [], checking: false) == .notChecked
              && CalimochoAvailability.from(choices: [], checking: true) == .checking
              && CalimochoAvailability.from(choices: [], checking: false, installed: false) == .missing
              && CalimochoAvailability.from(choices: [failed], checking: false, installed: true)
                == .invalid(CalimochoAvailability.unverifiedReason)
              && CalimochoAvailability.from(choices: [failed, ready], checking: true, installed: false) == .ready
              && CalimochoAvailability.missing.message?.hasPrefix("Calimocho isn't installed.") == true
              && CalimochoAvailability.missing.message?.contains("Check Again") == true
              && CalimochoAvailability.invalid("Signature changed.").message == "Calimocho couldn't be verified. Signature changed."
              && CalimochoAvailability.missing.needsDownload && CalimochoAvailability.invalid("x").needsDownload
              && !CalimochoAvailability.ready.needsDownload && CalimochoAvailability.notChecked.message == nil
              && CalimochoAvailability.notChecked.emptyListMessage != nil,
              "REQ-114(4): Calimocho renders Ready, Missing (Get + Check Again) or Invalid (reason); an unchecked list never claims it's missing")
        let release = EngineDisplayName.presentation(for: CalimochoRelease.engineID)
        check(release.name == "Calimocho 11.20 (GPTK 4.0b3) · 01" && !release.titleSpecific
              && CalimochoRelease.getTitle == "Get Calimocho (beta)"
              && CalimochoRelease.downloadURL.absoluteString
                == "https://github.com/dragoshont/calimocho/releases/tag/engine-11.20-4.0b3-01"
              && CalimochoRelease.manifest(home: URL(fileURLWithPath: "/Users/example")).path
                == "/Users/example/Library/Application Support/Xode/Engines/calimocho-11.20-4.0b3-01/calimocho-engine.json"
              && !CalimochoRelease.isPresent(home: FileManager.default.temporaryDirectory
                  .appendingPathComponent("XodusNoEngine-\(UUID().uuidString)")),
              "REQ-115: The released engine shows its release name and one Get Calimocho (beta) link to the release tag")
        check(AppLegalCopy.d3dMetal.contains("Apple D3DMetal") && AppLegalCopy.d3dMetal.contains("non-commercial")
              && AppLegalCopy.d3dMetal.contains("downloaded separately"),
              "COR187: Licenses state that Calimocho bundles Apple D3DMetal under Apple's non-commercial license, downloaded separately")
        let detected = CrossOverDependencyState.installed(.init(
            location: URL(fileURLWithPath: "/Applications/CrossOver.app"), version: "25.1", buildVersion: "25.1.0"))
        check(!CrossOverLocationRow.offersUseApp(location: "/Applications/CrossOver.app", saved: nil, state: detected)
              && !CrossOverLocationRow.offersUseApp(location: "/Volumes/Apps/CrossOver.app",
                                                    saved: "/Volumes/Apps/CrossOver.app", state: detected)
              && CrossOverLocationRow.offersUseApp(location: "/Volumes/Apps/CrossOver.app", saved: nil, state: detected)
              && CrossOverLocationRow.offersUseApp(location: "/Applications/CrossOver.app", saved: nil, state: .absent)
              && !CrossOverLocationRow.offersUseApp(location: "  ", saved: nil, state: .absent),
              "COR186 M8: Use App appears only when the field names an app other than the one in use")

        let settings = RuntimeProviderSettings(detectCrossOver: { detected })
        let suite = "XodusBrandUXEngines-\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else { return }
        defer { store.removePersistentDomain(forName: suite) }
        let scenarios: [(String, [EngineChoice], CalimochoAvailability?)] = [
            ("missing", [], .missing),
            ("invalid", [failed], .invalid(CalimochoAvailability.unverifiedReason)),
            ("ready", [EngineChoice.named(CalimochoRelease.engineID, ready: true), ready,
                       EngineChoice.named("calimocho-wine11.20-gptk4b3-ags54-minidump-dirt5", ready: true)], nil)]
        for (scenario, choices, status) in scenarios {
            for scheme in [ColorScheme.light, .dark] {
                let form = EngineConfiguratorForm(choices: choices, defaultID: ready.id, defaultName: ready.name,
                    checking: false, error: nil, settings: settings, allowsFileReads: false,
                    userEngineStore: store, setDefault: { _ in }, refresh: {}, showsAdvanced: false,
                    calimochoStatus: status) { EmptyView() }
                let labels = render(form, size: CGSize(width: 600, height: 900), scheme: scheme,
                                    name: "engines-\(scenario)-\(scheme == .dark ? "dark" : "light")")
                let joined = labels.joined(separator: " ")
                check(labels.filter { $0 == "Check Again" }.count == 1
                      && joined.contains("Engines run Windows games")
                      && joined.contains("Play currently uses Calimocho")
                      && !joined.contains("Private") && !joined.contains("Use App"),
                      "COR186 M8/U2: \(scenario) Engines (\(scheme)) leads with an explanation, one Check Again, plain names and honest CrossOver copy: \(labels)")
                switch scenario {
                case "missing":
                    check(joined.contains("Get Calimocho (beta)") && joined.contains("Calimocho isn't installed")
                          && joined.contains("Check Again") && joined.contains("No engines are installed yet"),
                          "REQ-114(4): Missing Calimocho shows a plain message, Get Calimocho (beta) and Check Again (\(scheme))")
                case "invalid":
                    check(joined.contains("Get Calimocho (beta)") && joined.contains("couldn't be verified")
                          && joined.contains("Not Verified") && !labels.contains("Default"),
                          "REQ-114(4): Invalid Calimocho gives the reason, marks the engine Not Verified and offers Get (\(scheme))")
                default:
                    check(!joined.contains("Get Calimocho") && joined.contains("Calimocho for DIRT 5")
                          && joined.contains("GPTK 4.0b3"),
                          "COR186 U2: Ready engines show no download prompt and name release and game-specific builds (\(scheme))")
                }
            }
        }
    }

    // MARK: Discover hero contrast

    static func contrast(_ color: NSColor, against other: NSColor = .white) -> Double {
        func luminance(_ color: NSColor) -> Double {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            func linear(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let a = luminance(color), b = luminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func heroContrast(check: (Bool, String) -> Void) {
        let height: CGFloat = 340
        for increased in [false, true] {
            let view = ZStack { Color.white; DiscoverHeroScrim(increasedContrast: increased) }
                .frame(width: 200, height: height)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: 200, height: height)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                check(false, "COR186 M4: Hero scrim renders offscreen")
                continue
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            func minimumContrast(from start: Double) -> Double {
                let scale = Double(bitmap.pixelsHigh) / Double(height)
                let first = Int(start * Double(height) * scale)
                return stride(from: first, to: bitmap.pixelsHigh - 1, by: 2).compactMap {
                    bitmap.colorAt(x: bitmap.pixelsWide / 2, y: $0).map { contrast($0) }
                }.min() ?? 0
            }
            let title = minimumContrast(from: increased ? 0.2 : 0.3), body = minimumContrast(from: 0.45)
            if ProcessInfo.processInfo.environment["XODUS_SCRIM_DEBUG"] != nil {
                print("SCRIM", increased, stride(from: 0.0, through: 0.95, by: 0.05).map {
                    String(format: "%.2f:%.2f", $0, minimumContrast(from: $0))
                }.joined(separator: " "))
            }
            if increased {
                check(title >= 4.5 && body >= 4.5,
                      "COR186 M4: With Increase Contrast, white hero text over white artwork keeps ≥4.5:1 from 20% down (title \(title), body \(body))")
            } else {
                check(title >= 3 && body >= 4.5,
                      "COR186 M4: White hero text over white artwork keeps ≥4.5:1 for body text from 45% and ≥3:1 for the large title from 30% (title \(title), body \(body))")
            }
            save(bitmap, name: "hero-scrim-\(increased ? "increased" : "standard")-over-white")
        }
        // Before/after evidence: the old bottom gradient and the new scrim over bright artwork.
        for (name, scrim) in [("before", AnyView(LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.8)],
                                                               startPoint: .top, endPoint: .bottom).frame(height: 210))),
                              ("after", AnyView(DiscoverHeroScrim())),
                              ("after-increased-contrast", AnyView(DiscoverHeroScrim(increasedContrast: true)))] {
            let hero = ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(red: 1, green: 0.97, blue: 0.85), .white], startPoint: .top, endPoint: .bottom)
                scrim
                VStack(alignment: .leading, spacing: 14) {
                    Text("Bright Artwork Game").font(.largeTitle.bold())
                    LibraryGameInformation(gameFacts: GameFacts(), facts: nil).environment(\.libraryOnHeroMedia, true)
                    Text("Adventure / Puzzle").font(.callout).foregroundStyle(.white.opacity(0.92))
                    LibraryGlassCluster {
                        Button("View Details") {}.modifier(LibraryActionStyle(primary: true))
                    }.controlSize(.large)
                    Label(InstalledProductAccess.notIncludedNotice, systemImage: "info.circle").font(.callout)
                }
                .padding(.horizontal, 56).padding(.bottom, 28)
                .foregroundStyle(.white)
            }
            render(hero, size: CGSize(width: 900, height: 340), scheme: .light, name: "discover-hero-\(name)")
        }
        let samples = stride(from: 0.0, through: 1.0, by: 0.05)
        check(samples.allSatisfy {
                  DiscoverHeroScrim.opacity(at: $0, increasedContrast: true)
                    >= DiscoverHeroScrim.opacity(at: $0, increasedContrast: false)
              }
              && zip(samples, samples.dropFirst()).allSatisfy {
                  DiscoverHeroScrim.opacity(at: $0.1, increasedContrast: false)
                    >= DiscoverHeroScrim.opacity(at: $0.0, increasedContrast: false)
              },
              "COR186 M4: The scrim darkens toward the text and Increase Contrast is never lighter")
    }

    // MARK: Toolbar accessibility

    static func accessibilityLabels(_ root: Any, depth: Int = 0) -> [String] {
        guard depth < 40 else { return [] }
        var labels: [String] = []
        var children: [Any] = []
        if let element = root as? NSAccessibilityProtocol {
            if let label = element.accessibilityLabel(), !label.isEmpty { labels.append(label) }
            children = element.accessibilityChildren() ?? []
        }
        if let view = root as? NSView { children += view.subviews }
        return labels + children.flatMap { accessibilityLabels($0, depth: depth + 1) }
    }

    static func toolbarAccessibility(check: (Bool, String) -> Void) {
        check(ToolbarAccountButton.title("Microsoft sign-in saved") == "Account: Microsoft sign-in saved"
              && NativeToolbarImportButton.title == "Import Installed Game",
              "COR186 M6: Account and Import toolbar items have their own explicit names")
        // Offscreen SwiftUI builds no accessibility tree without an assistive client, so the
        // announced names are checked here by construction and natively by VoiceOver QA.
        check(ToolbarAccountButton.title("Connect Xode") != NativeToolbarImportButton.title
              && !ToolbarAccountButton.title("Sign in with Microsoft").localizedCaseInsensitiveContains("Import"),
              "COR186 M6: The account item's name can never be the Import item's name")
        check(DownloadQueueRow.progressLabel("Pentiment") == "Download progress for Pentiment",
              "COR186 minor 6: Queue progress bars name their game")
    }

    // MARK: Welcome, readiness and support

    static func welcome(check: (Bool, String) -> Void) {
        check(WelcomeCopy.title == "Welcome to Xode" && WelcomeCopy.tagline == "Play your Xbox PC games on Mac."
              && WelcomeCopy.account == "Sign in with your Microsoft account to see PC games you own or play with PC Game Pass."
              && WelcomeCopy.signIn == "Sign in with Microsoft" && WelcomeCopy.keychain.contains("Keychain")
              && WelcomeCopy.keychain.contains("Xode"),
              "COR186 M7: Welcome copy uses Xode, Microsoft account and the Keychain explanation")
        for scheme in [ColorScheme.light, .dark] {
            let view = LiveWelcomeView(session: LiveSession(), runtime: RuntimeProviderSettings(),
                operations: GameOperationsController(installed: InstalledGamesController()))
                .environmentObject(AppState())
            let labels = render(view, size: CGSize(width: 560, height: 620), scheme: scheme,
                                name: "welcome-\(scheme == .dark ? "dark" : "light")")
            let joined = labels.joined(separator: " ")
            check(joined.contains("Welcome to Xode") && joined.contains("Sign in with Microsoft")
                  && joined.contains("Microsoft account") && !joined.contains("Xbox Live")
                  && !joined.contains("Windows Live") && labels.allSatisfy { $0 != "Ode" },
                  "COR186 M7: Rendered welcome (\(scheme)) shows the Xode copy and Microsoft sign-in: \(labels)")
        }
    }

    static func readiness(check: (Bool, String) -> Void) {
        check(ReadinessChecklistView.engineStatus(.ready).0 == .done
              && ReadinessChecklistView.engineStatus(.notChecked).0 == .waiting
              && ReadinessChecklistView.engineStatus(.missing).0 == .attention
              && ReadinessChecklistView.engineStatus(.invalid("x")).0 == .attention,
              "COR186 M7: Readiness maps Calimocho state to ready, checking or needs attention")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("XodusReadiness-\(UUID().uuidString)/Games/Not created yet").path
        let space = GamesFolderSpace.measure(folder: missing)
        check(space.folder == missing && (space.availableBytes ?? 0) > 0
              && !FileManager.default.fileExists(atPath: missing)
              && GamesFolderSpace(folder: "/", availableBytes: 5_000_000_000).isLow
              && !GamesFolderSpace(folder: "/", availableBytes: 200_000_000_000).isLow
              && !GamesFolderSpace(folder: "/", availableBytes: nil).isLow,
              "COR186 M7: Games-folder space reads the nearest existing folder without creating it")
        let state = AppState()
        for scheme in [ColorScheme.light, .dark] {
            let view = ReadinessChecklistView(session: LiveSession(), installed: InstalledGamesController(),
                                              allowsStatusReads: false)
                .environmentObject(state)
            let labels = render(view, size: CGSize(width: 520, height: 460), scheme: scheme,
                                name: "readiness-\(scheme == .dark ? "dark" : "light")")
            let joined = labels.joined(separator: " ")
            check(joined.contains("You're signed in") && joined.contains("Microsoft account")
                  && joined.contains("Calimocho") && joined.contains("games folder") && joined.contains("Continue"),
                  "COR186 M7: Readiness checklist (\(scheme)) lists account, engine and games folder: \(labels)")
        }
    }

    static func support(check: (Bool, String) -> Void) {
        for scheme in [ColorScheme.light, .dark] {
            let labels = render(BetaSupportView {}, size: CGSize(width: 480, height: 420), scheme: scheme,
                                name: "support-\(scheme == .dark ? "dark" : "light")")
            let joined = labels.joined(separator: " ")
            check(joined.contains("Xode Beta Support") && joined.contains("0.11.4 Beta")
                  && joined.contains("Diagnostic Summary") && !joined.contains("http"),
                  "COR186 menu: Help ▸ Xode Beta Support (\(scheme)) explains feedback without an unverified link: \(labels)")
        }
    }

    // MARK: Jargon

    static func jargon(check: (Bool, String) -> Void) {
        let package = GameSupportPolicy.issues(packageFormat: "EAppx", antiCheat: nil)
        let antiCheat = GameSupportPolicy.issues(packageFormat: "MSIXVC", antiCheat: "BattlEye")
        check(package.first?.detail == "This game comes as a EAPPX package, which Xode can't install yet."
              && antiCheat.first?.detail == "Games that use BattlEye can't run in Xode yet."
              && !(package + antiCheat).contains { $0.detail.contains("0.1") },
              "COR186 minor 7: Blocker details are plain and carry no stale version")
        check(LibraryPackageFormatLabel.plainName("MSIXVC") == "Xbox PC game"
              && LibraryPackageFormatLabel.plainName("EAppx") == "Microsoft Store app"
              && LibraryPackageFormatLabel.plainName("Win32") == "Windows game"
              && LibraryPackageFormatLabel.help(format: "MSIXVC").contains("MSIXVC"),
              "COR186 minor 7: Package type uses plain words; the technical name stays in the tooltip")
    }

    // MARK: Rendering

    @discardableResult
    static func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String) -> [String] {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        save(bitmap, name: name)
        guard let image = bitmap.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func save(_ bitmap: NSBitmapImageRep, name: String) {
        guard let renderDirectory, let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: renderDirectory.appendingPathComponent(name + ".png"))
    }
}
#endif
