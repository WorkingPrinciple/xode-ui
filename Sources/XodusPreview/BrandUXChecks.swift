// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import AppKit
import SwiftUI
import CryptoKit
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
        heroInstallControl(check: check)
        toolbarAccessibility(check: check)
        welcome(check: check)
        readiness(check: check)
        support(check: check)
        acknowledgments(check: check)
        permissions(check: check)
        jargon(check: check)
    }

    // MARK: Brand

    static func brand(check: (Bool, String) -> Void) {
        check(AppBrand.displayName == "X Ode" && AppBrand.wordmark == "Ode" && AppBrand.company == "Working Principle"
              && AppBrand.website == "xode.win" && AppBrand.nameWithChannel == "X Ode Beta"
              && AppBrand.supportTitle == "X Ode Beta Support"
              && AppBrand.copyright == "© Working Principle" && !AppBrand.copyright.contains(AppBrand.website),
              "COR186/L1: One AppBrand defines X Ode and Working Principle; the unresolved domain stays out of the copyright line")
        let packaged = AppVersion(info: ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "412",
                                         "XodeReleaseChannel": "Beta"])
        check(packaged.label == "0.2.0 (Beta)" && packaged.aboutVersion == "0.2.0 Beta" && packaged.build == "412"
              && AppVersion(info: ["CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "413"]).label == "0.2.1 (Beta)"
              && AppVersion(info: nil).label == "Development build"
              && AppVersion(info: ["CFBundleShortVersionString": "0.2.0-beta.1", "CFBundleVersion": "4b"]).version == nil
              && AppVersion(info: ["CFBundleShortVersionString": "0.2.0-beta.1", "CFBundleVersion": "4b"]).build == nil,
              "COR198: The version, build and channel come only from the bundle, as 0.2.0 (Beta); invalid values fall back honestly")
        let about = AppBrandPresentation.aboutPanelOptions(packaged)
        check(about[.applicationName] as? String == "X Ode"
              && about[.applicationVersion] as? String == "0.2.0 Beta" && about[.version] as? String == "412"
              && (about[.credits] as? NSAttributedString)?.string == "© Working Principle"
              && AppBrandPresentation.aboutPanelOptions(AppVersion(info: nil))[.applicationVersion] as? String
                == "Development build",
              "COR186/COR198/L1: About shows X Ode, Version 0.2.0 Beta (412) and © Working Principle, without xode.win")
        let session = LiveSession()
        let copy = [WelcomeCopy.technology, WelcomeCopy.signIn, WelcomeCopy.keychain,
                    EnginesCopy.lead, EnginesCopy.crossOver, EnginesCopy.crossOverLicense,
                    session.accountLabel, LiveSession.signOutConfirmationMessage, session.libraryMessage,
                    ManagementError.stateLocked.errorDescription ?? "", ManagementError.startFailed.errorDescription ?? "",
                    AppLegalCopy.acknowledgment, AppLegalCopy.trademarks,
                    LibraryPackageFormatLabel.help(format: "MSIXVC")]
            + GameSupportPolicy.issues(packageFormat: "EAppx", antiCheat: "BattlEye").map(\.detail)
        let retired = copy.filter { text in
            AppBrand.retiredNames.contains { text.contains($0) }
                || text.range(of: #"(?<!X )\bOde\b"#, options: .regularExpression) != nil
                || text.contains("Xodus returned") || text.contains("Xodus engine")
        }
        check(retired.isEmpty && session.accountLabel == "Connect X Ode"
              && LiveSession.signOutConfirmationMessage.contains("from X Ode on this Mac")
              && AppLegalCopy.acknowledgment.contains("Xodus"),
              "COR186: User-visible copy names X Ode only, keeping the upstream Xodus credit: \(retired)")
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
        let pendingRelease: CalimochoAvailability? = nil
        check(CalimochoAvailability.from(choices: [], checking: false, release: pendingRelease) == .notChecked
              && CalimochoAvailability.from(choices: [failed], checking: false, release: nil) == .notChecked
              && CalimochoAvailability.from(choices: [failed], checking: false, release: .notChecked) == .notChecked
              && CalimochoAvailability.from(choices: [], checking: true, release: nil) == .checking
              && CalimochoAvailability.from(choices: [], checking: false, release: .checking) == .checking,
              "REVIEW H2c: Until an engine check has actually completed, Calimocho is Not Checked (or Checking), never Missing")
        check(CalimochoAvailability.from(choices: [failed], checking: false, release: .ready) == .pendingVerification
              && CalimochoAvailability.from(choices: [], checking: false, release: .ready) == .pendingVerification
              && !CalimochoAvailability.pendingVerification.needsDownload
              && CalimochoAvailability.pendingVerification.message?.contains("Reinstall") == false
              && CalimochoAvailability.pendingVerification.message?.contains("installed") == true,
              "REVIEW H2b: A present, verified release engine that isn't admitted yet stays neutral, never Invalid or Reinstall")
        check(CalimochoAvailability.from(choices: [failed], checking: false, release: .missing) == .missing
              && CalimochoAvailability.from(choices: [], checking: false, release: .invalid("Damaged.")) == .invalid("Damaged.")
              && CalimochoAvailability.from(choices: [failed, ready], checking: true, release: .missing) == .ready
              && CalimochoAvailability.missing.message == "Calimocho isn't installed. X Ode needs Calimocho to play games."
              && CalimochoAvailability.invalid("Signature changed.").message == "Calimocho couldn't be verified. Signature changed."
              && CalimochoAvailability.missing.needsDownload && CalimochoAvailability.invalid("x").needsDownload
              && !CalimochoAvailability.ready.needsDownload && CalimochoAvailability.notChecked.message == nil
              && CalimochoAvailability.notChecked.emptyListMessage != nil,
              "REQ-114(4): A completed check renders Ready, Missing or Invalid (reason); an admitted engine is Ready")
        let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("XodusNoEngines-\(UUID().uuidString)")
        check(CalimochoAvailability.verifiedRelease(root: emptyRoot, admission: nil) == .missing
              && CalimochoAvailability.from(choices: [failed], checking: false,
                    release: CalimochoAvailability.verifiedRelease(root: emptyRoot, admission: nil)) == .missing
              && CalimochoAvailability.neutralizingAdmission(.invalid(CalimochoAvailability.notAdmittedReason),
                                                             rejected: false) == .pendingVerification
              && CalimochoAvailability.neutralizingAdmission(.invalid("Damaged."), rejected: false) == .invalid("Damaged."),
              "REQ-115: The Engines pane maps 135c's release verification of an empty Engines folder to Missing")
        let rejected = CalimochoAvailability.neutralizingAdmission(.invalid(CalimochoAvailability.notAdmittedReason),
                                                                    rejected: true)
        check(rejected == .invalid(CalimochoAvailability.rejectedReason) && rejected.needsDownload
              && rejected.message?.contains("Check Again") == true && rejected.message?.contains("will be ready") == false
              && CalimochoAvailability.from(choices: [failed], checking: false, release: rejected) == rejected,
              "REVIEW M2: Check completed and the pin failed → Invalid with Check Again/reinstall, never pending")
        // Review L1: the real status path, driven through EngineCheckResults.
        let notAdmitted = CalimochoAvailability.invalid(CalimochoAvailability.notAdmittedReason)
        let failedCheck = FakeEngineCheck(failed: [CalimochoRelease.engineID])
        let recheckedClean = FakeEngineCheck(failed: [])
        check(CalimochoAvailability.rejected(in: failedCheck) && !CalimochoAvailability.rejected(in: recheckedClean)
              && CalimochoAvailability.status(results: failedCheck, verification: notAdmitted)
                == .invalid(CalimochoAvailability.rejectedReason)
              && CalimochoAvailability.status(results: recheckedClean, verification: notAdmitted) == .pendingVerification
              && CalimochoAvailability.status(results: FakeEngineCheck(failed: [], checking: true), verification: notAdmitted)
                == .checking
              && CalimochoAvailability.status(results: recheckedClean, verification: nil) == .notChecked,
              "REVIEW L1: A failed engine check makes readiness Invalid; a clean re-check returns it to pending")
        let release = EngineDisplayName.presentation(for: CalimochoRelease.engineID)
        let pinned = CalimochoReleasePin.all.last!.engineName
        check(CalimochoRelease.engineID == pinned && CalimochoReleasePin.named(CalimochoRelease.engineID) != nil
              && release.name == "Calimocho \(EngineDisplayName.releaseVersion(pinned)!.version)"
              && release.detail == "Wine 11.20 · GPTK 4.0 beta 3" && !release.titleSpecific
              && EngineDisplayName.releaseVersion("calimocho-11.20-4.0b3-03")?.version == "0.1120.4.3"
              && EngineDisplayName.releaseVersion("calimocho-11.21-4.0b4-03")?.version == "0.1121.4.3"
              && EngineDisplayName.releaseVersion("calimocho-11.20-4.0b3-00") == nil
              && CalimochoRelease.displayName == release.name
              && CalimochoRelease.getTitle == "Get Calimocho (beta)"
              && CalimochoRelease.downloadURL.absoluteString
                == "https://github.com/WorkingPrinciple/calimocho/releases/tag/engine-"
                    + EngineDisplayName.releaseVersion(pinned)!.version
              && !CalimochoRelease.downloadPublished
              && CalimochoRelease.unpublishedNotice
                == "Calimocho isn't available for download yet — ask the person who invited you to the beta.",
              "REVIEW H2a: The release keeps one URL constant but shows no download control until the asset is published")
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
            ("missing", [failed], .missing),
            ("invalid", [failed], .invalid("The installed Calimocho engine isn't signed by its publisher. Reinstall it from the official release, then check again.")),
            ("pending", [failed], .pendingVerification),
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
                let noDownloadControl = !joined.contains("Get Calimocho")
                switch scenario {
                case "missing":
                    check(joined.contains("Calimocho isn't installed") && joined.contains("isn't available for download yet")
                          && joined.contains("Check Again") && noDownloadControl,
                          "REVIEW H2a: Missing Calimocho says so, explains the download isn't available yet and offers no dead-end button (\(scheme))")
                case "invalid":
                    check(joined.contains("couldn't be verified") && joined.contains("isn't available for download yet")
                          && joined.contains("Not Verified") && !labels.contains("Default") && noDownloadControl,
                          "REQ-114(4): Invalid Calimocho gives the verification reason and marks the engine Not Verified (\(scheme))")
                case "pending":
                    check(joined.contains("will be ready once") && !joined.contains("isn't available for download")
                          && !joined.contains("Reinstall") && noDownloadControl,
                          "REVIEW H2b: A verified but not yet admitted release is neutral, with no reinstall or download prompt (\(scheme))")
                default:
                    check(noDownloadControl && joined.contains("Calimocho for DIRT 5")
                          && joined.contains(EngineDisplayName.name(CalimochoRelease.engineID)),
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

    // MARK: Hero install control (review H1)

    static func heroInstallControl(check: (Bool, String) -> Void) {
        let reason = "Installation is not available yet."
        check(HeroInstallReplacement.reason(unavailable: reason, active: false, preparing: false,
                                            checking: false, prechecking: false) == reason
              && HeroInstallReplacement.reason(unavailable: nil, active: false, preparing: false,
                                               checking: false, prechecking: false) == nil,
              "REVIEW H1: A statically unavailable Download is replaced by View Details with its reason")
        let busy = [(true, false, false, false), (false, true, false, false),
                    (false, false, true, false), (false, false, false, true)]
        check(busy.allSatisfy { state in
                  HeroInstallReplacement.reason(unavailable: reason, active: state.0, preparing: state.1,
                                                checking: state.2, prechecking: state.3) == nil
              },
              "REVIEW H1: While this game is installing, preparing, checking or prechecking, the hero keeps its in-place progress and Cancel")
        let installed = InstalledGamesController()
        let operations = GameOperationsController(installed: installed)
        let game = PCGame(id: "FIXTURE00009", title: "Hero fixture", artwork: nil)
        let disabled = GameInstallAction(game: game, operations: operations, enabled: false,
                                         showsDiagnostics: false, disabledReason: "Static reason.")
        let checking = operations.checkingExistingInstallation(productID: game.id)
            || (operations.installationCheckRequired(for: game) && operations.existingInstallationError(productID: game.id) == nil)
        check(!disabled.active && !disabled.preparing && operations.precheckingProductID == nil
              && disabled.heroReplacementReason == (checking ? nil : disabled.unavailableReason)
              && (checking || disabled.heroReplacementReason != nil),
              "REVIEW H1: A real idle install control derives the hero replacement from the controller's own state")
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
        check(ToolbarAccountButton.title("Connect X Ode") != NativeToolbarImportButton.title
              && !ToolbarAccountButton.title("Sign in with Microsoft").localizedCaseInsensitiveContains("Import"),
              "COR186 M6: The account item's name can never be the Import item's name")
        check(DownloadQueueRow.progressLabel("Pentiment") == "Download progress for Pentiment",
              "COR186 minor 6: Queue progress bars name their game")
    }

    // MARK: Welcome, readiness and support

    static func welcome(check: (Bool, String) -> Void) {
        check(WelcomeCopy.signIn == "Sign in with Microsoft"
              && WelcomeCopy.technology == "X Ode runs Windows games with Wine and other open-source libraries."
              && WelcomeCopy.keychain.contains("Keychain") && XOdeLockup.accessibilityName == "X Ode",
              "COR186 M7: The login screen is the X Ode lockup, Sign in with Microsoft and the Wine/open-source line")
        for scheme in [ColorScheme.light, .dark] {
            let view = LiveWelcomeView(session: LiveSession(), runtime: RuntimeProviderSettings(),
                operations: GameOperationsController(installed: InstalledGamesController()))
                .environmentObject(AppState())
            let labels = render(view, size: CGSize(width: 560, height: 620), scheme: scheme,
                                name: "welcome-\(scheme == .dark ? "dark" : "light")")
            let joined = labels.joined(separator: " ")
            check(labels.contains("Ode") && joined.contains("Sign in with Microsoft")
                  && joined.contains("Wine") && joined.contains("Acknowledgments")
                  && !joined.contains("Keychain") && !joined.contains("PC Game Pass") && !joined.contains("Beta")
                  && !joined.contains("Xbox Live") && !joined.contains("Xode") && !joined.contains("Welcome"),
                  "COR186 M7: Rendered login (\(scheme)) keeps only the lockup, Microsoft sign-in, state notices and the Wine line: \(labels)")
        }
        for scheme in [ColorScheme.light, .dark] {
            let lockup = XOdeLockup(markSize: 48, markStyle: AnyShapeStyle(XboxBrand.lightGreen),
                                    wordmarkFont: .title2.weight(.medium),
                                    markBackground: AnyShapeStyle(Color(red: 12 / 255, green: 40 / 255, blue: 25 / 255)))
            let labels = render(lockup, size: CGSize(width: 200, height: 160), scheme: scheme,
                                name: "account-lockup-\(scheme == .dark ? "dark" : "light")")
            check(labels == ["Ode"],
                  "COR186: The account popup lockup is the X mark with 'Ode' beneath, with no second X in text (\(scheme)): \(labels)")
        }
    }

    static func readiness(check: (Bool, String) -> Void) {
        check(ReadinessChecklistView.engineStatus(.ready).0 == .done
              && ReadinessChecklistView.engineStatus(.notChecked).0 == .waiting
              && ReadinessChecklistView.engineStatus(.pendingVerification).0 == .waiting
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
            check(joined.contains("X Ode Beta Support") && joined.contains(AppBrand.versionLabel)
                  && !joined.contains("0.11.4")
                  && joined.contains("Diagnostic Summary") && !joined.contains("http") && !joined.contains("xode.win"),
                  "COR186 menu: Help ▸ X Ode Beta Support (\(scheme)) explains feedback without an unverified link: \(labels)")
        }
    }

    // MARK: Acknowledgments (REQ-117)

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func acknowledgments(check: (Bool, String) -> Void) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("XodusAcknowledgments-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let producer = root.appendingPathComponent("ProducerNotices")
        let engine = root.appendingPathComponent("Engines/\(CalimochoRelease.engineID)")
        do {
            try fileManager.createDirectory(at: producer.appendingPathComponent("texts"), withIntermediateDirectories: true)
            let good = Data("MIT License\nCopyright synthetic".utf8), tampered = Data("tampered".utf8)
            try good.write(to: producer.appendingPathComponent("texts/\(sha256(good)).txt"))
            let claimed = sha256(Data("original".utf8))
            try tampered.write(to: producer.appendingPathComponent("texts/\(claimed).txt"))
            let inventory: [String: Any] = ["version": 1, "unresolved": ["xodus@0.1.0: no package-level licence declaration"],
                "packages": [
                    ["name": "xodus", "version": "0.1.0", "declaredLicense": NSNull(), "notices": []],
                    ["name": "adler2", "version": "2.0.1", "declaredLicense": "MIT",
                     "notices": [["originalPath": "adler2-2.0.1/LICENSE-MIT", "path": "texts/\(sha256(good)).txt", "sha256": sha256(good)]]],
                    ["name": "tampered-crate", "version": "1.0.0", "declaredLicense": "MIT",
                     "notices": [["originalPath": "x/LICENSE", "path": "texts/\(claimed).txt", "sha256": claimed],
                                 ["originalPath": "y/LICENSE", "path": "../../etc/passwd", "sha256": claimed]]]]]
            try JSONSerialization.data(withJSONObject: inventory).write(to: producer.appendingPathComponent("inventory.json"))
            for (path, text) in [("calimocho-engine.json", "{}"), ("VERSION", CalimochoRelease.engineID), ("NOTICE", "Calimocho notice"),
                                 ("licenses/wine/LICENSE", "LGPL"), ("licenses/wine/libs/vkd3d/COPYING", "LGPL"),
                                 ("licenses/moltenvk/LICENSE", "Apache"), ("licenses/apple-gptk/License.rtf", "{\\rtf1 Apple licence}")] {
                let url = engine.appendingPathComponent(path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        } catch {
            check(false, "REQ-117: Synthetic acknowledgments fixtures are written")
            return
        }
        let loaded = AcknowledgmentsInventory.load(.init(producer: producer, engine: engine))
        let service = loaded.components.filter { $0.origin == .gameService }
        check(service.map(\.name) == ["xodus", "adler2", "tampered-crate"]
              && ["xodus", "adler2", "tampered-crate"].allSatisfy { name in loaded.filtered(name).contains { $0.name == name } }
              && service.first { $0.name == "xodus" }?.license == "No package-level licence declared"
              && loaded.unresolved.count == 1,
              "REQ-117: Every producer inventory package appears and is searchable, including ones without a declared licence")
        let tampered = service.first { $0.name == "tampered-crate" }
        check(tampered?.notices.count == 1
              && tampered.map { AcknowledgmentsInventory.text(of: $0.notices[0]) } == AcknowledgmentsInventory.checksumMismatch
              && service.first { $0.name == "adler2" }.map { AcknowledgmentsInventory.text(of: $0.notices[0]) }?
                .hasPrefix("MIT License") == true,
              "REQ-117: Notice texts are shown only when they match their recorded SHA-256; paths outside texts/ are dropped")
        let engineNames = loaded.components.filter { $0.origin == .engine }.map(\.name)
        let projects = KeyOpenSourceProjects.projects(shipping: loaded.markers).map(\.name)
        check(engineNames.contains("Calimocho") && engineNames.contains("moltenvk")
              && engineNames.contains("Apple D3DMetal (Game Porting Toolkit)")
              && loaded.components.first { $0.name == "Calimocho" }?.version
                == EngineDisplayName.releaseVersion(CalimochoRelease.engineID)?.version
              && projects == ["Xodus", "Calimocho", "Wine, with CodeWeavers' Wine patches", "vkd3d", "MoltenVK"]
              && KeyOpenSourceProjects.separate(shipping: loaded.markers)?.license.contains("not open source") == true
              && !KeyOpenSourceProjects.catalog.contains { $0.project.name == "DXVK" },
              "REQ-117: Key projects list only what ships (\(projects)); D3DMetal is separate and proprietary; DXVK isn't claimed")
        let rtf = loaded.components.first { $0.name.hasPrefix("Apple D3DMetal") }?.notices.first
        check(rtf.map { AcknowledgmentsInventory.text(of: $0).contains("Apple licence") } == true,
              "REQ-117: RTF licences are shown as plain text")
        // Review L: links, pipes and oversized files are never read as notices.
        let fifo = engine.appendingPathComponent("licenses/moltenvk/FIFO")
        mkfifo(fifo.path, 0o600)
        try? fileManager.createSymbolicLink(at: engine.appendingPathComponent("TRADEMARKS.md"),
                                            withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        let hostile = AcknowledgmentsInventory.load(.init(producer: producer, engine: engine))
        let calimochoNotices = hostile.components.first { $0.name == "Calimocho" }?.notices.map(\.title) ?? []
        let moltenNotices = hostile.components.first { $0.name == "moltenvk" }?.notices.map(\.title) ?? []
        check(calimochoNotices == ["NOTICE"] && moltenNotices == ["LICENSE"]
              && !AcknowledgmentsInventory.isRegularNotice(fifo)
              && !AcknowledgmentsInventory.isRegularNotice(URL(fileURLWithPath: "/dev/zero"))
              && AcknowledgmentsInventory.text(of: .init(title: "fifo", url: fifo, sha256: nil)) == "This notice couldn't be read.",
              "REVIEW L: Symlinks, FIFOs and devices are skipped and never read; notices use a bounded regular-file read")
        // installedNames refuses symlinked paths (the temp directory sits under /var → /private/var).
        let releaseRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/XodusReleaseRoot-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: releaseRoot) }
        for name in [CalimochoRelease.engineID, "calimocho-not-pinned"] {
            try? fileManager.createDirectory(at: releaseRoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        check(AcknowledgmentsInventory.installedReleaseEngine(root: releaseRoot)?.lastPathComponent == CalimochoRelease.engineID
              && AcknowledgmentsInventory.installedReleaseEngine(root: releaseRoot.appendingPathComponent("none")) == nil,
              "REVIEW M: Acknowledgments reads the installed pinned release, the same engine the Engines pane verifies")
        let bundledNotice = root.appendingPathComponent("EngineNotices/NOTICE.txt")
        try? fileManager.createDirectory(at: bundledNotice.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("Calimocho bundled notice".utf8).write(to: bundledNotice)
        let noEngine = AcknowledgmentsInventory.load(.init(producer: nil,
            engine: root.appendingPathComponent("missing"), engineNotice: bundledNotice))
        check(noEngine.components.contains { $0.origin == .engine && $0.name == "Calimocho" }
              && noEngine.issues.contains(AcknowledgmentsInventory.engineDownloadNote)
              && KeyOpenSourceProjects.projects(shipping: noEngine.markers) == [KeyOpenSourceProjects.catalog[1].project]
              && AcknowledgmentsInventory.load(.init(engine: root.appendingPathComponent("missing")))
                .issues.contains(AcknowledgmentsInventory.engineDownloadNote),
              "REQ-117: Without an installed engine, the bundled Calimocho NOTICE shows and full notices point to the download")
        if let manifest = try? String(contentsOfFile: "Package.swift", encoding: .utf8) {
            check(!manifest.contains(".package(") && !fileManager.fileExists(atPath: "Package.resolved"),
                  "REQ-117: The app has no third-party Swift packages, so the 'Apple frameworks only' line stays true")
        }
        if let directory = ProcessInfo.processInfo.environment["XODUS_PRODUCER_NOTICES_DIRECTORY"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            let data = (try? Data(contentsOf: url.appendingPathComponent("inventory.json"))) ?? Data()
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let packages = (raw?["packages"] as? [[String: Any]]) ?? []
            let real = AcknowledgmentsInventory.load(.init(producer: url))
            let shown = Set(real.components.filter { $0.origin == .gameService }.map { "\($0.name)@\($0.version ?? "")" })
            let expected = Set(packages.map { "\($0["name"] as? String ?? "")@\($0["version"] as? String ?? "")" })
            let notices = real.components.flatMap(\.notices).filter { $0.sha256 != nil }
            check(sha256(data) == AcknowledgmentsInventory.pinnedProducerInventorySHA256 && !packages.isEmpty
                  && shown == expected
                  && packages.allSatisfy { package in
                      real.filtered(package["name"] as? String ?? "").contains { $0.name == package["name"] as? String }
                  }
                  && notices.allSatisfy { AcknowledgmentsInventory.text(of: $0) != AcknowledgmentsInventory.checksumMismatch },
                  "REQ-117: The pinned producer inventory (\(packages.count) packages, \(notices.count) notices) all appear, are searchable and verify")
        }
        var opened = false
        let welcome = LiveWelcomeView(session: LiveSession(), runtime: RuntimeProviderSettings(),
            operations: GameOperationsController(installed: InstalledGamesController()), openAcknowledgments: { opened = true })
        welcome.openAcknowledgmentsAction()
        check(opened && WelcomeCopy.acknowledgmentsAccessibility == "Open-source acknowledgments"
              && AppAcknowledgmentsView.windowID == "acknowledgments",
              "REQ-117: The login screen's Acknowledgments link opens the Acknowledgments window")
        for scheme in [ColorScheme.light, .dark] {
            let labels = render(AppAcknowledgmentsView(inventory: loaded), size: CGSize(width: 860, height: 600),
                                scheme: scheme, name: "acknowledgments-\(scheme == .dark ? "dark" : "light")")
            let joined = labels.joined(separator: " ")
            check(joined.contains("Built on open source") && joined.contains("Key projects") && joined.contains("MoltenVK")
                  && joined.contains("Apple D3DMetal") && !joined.contains("DXVK"),
                  "REQ-117: The Acknowledgments window (\(scheme)) leads with the derived key projects and the separate D3DMetal note: \(labels)")
        }
    }

    // MARK: Permissions (REQ-118)

    static func permissions(check: (Bool, String) -> Void) {
        let usage = PrivacyPermission.allCases.compactMap(\.usageDescription)
        check(usage.map(\.key) == ["NSLocalNetworkUsageDescription", "NSRemovableVolumesUsageDescription",
                                    "NSNetworkVolumesUsageDescription", "NSDocumentsFolderUsageDescription",
                                    "NSDownloadsFolderUsageDescription", "NSDesktopFolderUsageDescription"]
              && usage.allSatisfy { $0.text.contains("X Ode") && !$0.text.contains("Xode") && $0.text.hasSuffix(".") }
              && PrivacyPermission.keychain.usageDescription == nil,
              "REQ-118: Every privacy prompt X Ode can trigger has a clear 'X Ode' usage string (Keychain uses macOS's own prompt)")
        check(PrivacyPermission.allCases.allSatisfy { $0.settingsURL.scheme == "x-apple.systempreferences" }
              && PrivacyPermission.localNetwork.settingsURL.absoluteString.hasSuffix("Privacy_LocalNetwork")
              && PrivacyPermission.removableVolumes.settingsURL.absoluteString.hasSuffix("Privacy_FilesAndFolders"),
              "REQ-118: Each denial opens its own Privacy & Security pane")
        let discovery = LocalNetworkDiscovery()
        discovery.didNotSearch(code: -65570)
        let other = LocalNetworkDiscovery()
        other.didNotSearch(code: -72000)
        check(discovery.denied && discovery.status == LocalNetworkDiscovery.deniedStatus
              && discovery.status.contains("System Settings") && !other.denied,
              "REQ-118: A local-network privacy denial is recognised and explained with a way to fix it; other errors aren't called denials")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        check(PrivacyDenial.isFolderDenial(CocoaError(.fileReadNoPermission))
              && PrivacyDenial.isFolderDenial(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)))
              && !PrivacyDenial.isFolderDenial(CocoaError(.fileNoSuchFile))
              && PrivacyDenial.folderPermission(for: home + "/Documents/Games") == .documents
              && PrivacyDenial.folderPermission(for: home + "/Desktop") == .desktop
              && PrivacyDenial.folderPermission(for: "/Volumes/Games/Xode") != .documents
              && InstalledGameError.folderPermission.localizedDescription.contains("Files and Folders"),
              "REQ-118: Folder denials are told apart from other errors and point to Files and Folders")
        // Notifications are requested only when an install or repair finishes (GameReadyNotifier.post), never at launch.
        let sources = (try? FileManager.default.subpathsOfDirectory(atPath: "Sources")) ?? []
        let requesters = sources.filter { $0.hasSuffix(".swift") && !$0.hasSuffix("BrandUXChecks.swift") }.filter {
            ((try? String(contentsOfFile: "Sources/" + $0, encoding: .utf8)) ?? "").contains("requestAuthorization")
        }
        let notifier = (try? String(contentsOfFile: "Sources/XodusPreview/GameReadyNotifier.swift", encoding: .utf8)) ?? ""
        let postBody = notifier.range(of: "func post(").map { String(notifier[$0.lowerBound...]) } ?? ""
        let beforePost = notifier.range(of: "func post(").map { String(notifier[..<$0.lowerBound]) } ?? notifier
        check(!sources.isEmpty && requesters == ["XodusPreview/GameReadyNotifier.swift"]
              && postBody.contains("requestAuthorization") && !beforePost.contains("requestAuthorization")
              && PrivacyPermission.notifications.usageDescription == nil,
              "REQ-118: Notification permission is asked only when a finished install posts its ready notice, never at launch")
        if let readme = try? String(contentsOfFile: "README.md", encoding: .utf8) {
            check(readme.contains("## " + PrivacyPermission.installNotesTitle)
                  && PrivacyPermission.allCases.allSatisfy { readme.contains("| \($0.title) | \($0.reason) |") }
                  && readme.contains(PrivacyPermission.microphoneKnownIssue)
                  && !readme.contains("| Microphone |"),
                  "REQ-118: The install notes list every permission with the same words the app uses")
        }
        for scheme in [ColorScheme.light, .dark] {
            let labels = render(Form { PrivacyPermissionsSection() }.formStyle(.grouped),
                                size: CGSize(width: 600, height: 760), scheme: scheme,
                                name: "permissions-\(scheme == .dark ? "dark" : "light")")
            let joined = labels.joined(separator: " ")
            check(joined.contains("Permissions") && joined.contains("Local network") && joined.contains("Open Privacy"),
                  "REQ-118: Settings ▸ General lists permissions with a way to change them (\(scheme)): \(labels)")
        }
    }

    // MARK: Jargon

    static func jargon(check: (Bool, String) -> Void) {
        let package = GameSupportPolicy.issues(packageFormat: "EAppx", antiCheat: nil)
        let antiCheat = GameSupportPolicy.issues(packageFormat: "MSIXVC", antiCheat: "BattlEye")
        check(package.first?.detail == "This game comes as a EAPPX package, which X Ode can't install yet."
              && antiCheat.first?.detail == "Games that use BattlEye can't run in X Ode yet."
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
@MainActor
private struct FakeEngineCheck: EngineCheckResults {
    var availableEngineOverrides: [AdmittedEngineSelection] = []
    var failedEngineOverrides: Set<String>
    var checkingEngineOverrides = false

    init(failed: Set<String>, checking: Bool = false) {
        failedEngineOverrides = failed
        checkingEngineOverrides = checking
    }
}
#endif
