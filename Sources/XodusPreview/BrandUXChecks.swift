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
        NativeCheckOCR.checks(check)
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
        firstLoad(check: check)
        support(check: check)
        acknowledgments(check: check)
        credits(check: check)
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
              && (about[.credits] as? NSAttributedString)?.string
                == "Runs Windows games with Wine and is built on Xodus. Thank you to both projects.\n© Working Principle"
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
              && CalimochoAvailability.missing.message
                == "Calimocho isn't installed. Get it to use games pinned to this release."
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
        check(CalimochoRelease.engineID == "calimocho-11.20-4.0b3-06"
              && EngineDisplayName.releaseVersion(CalimochoRelease.engineID)?.version == "0.1120.4.6"
              && CalimochoReleasePin.all == [.release04, .release06]
              && CalimochoReleasePin.release06.wineSha256
                == "803a62d101303bb3160da4aa8a506857c3d1e1146aa4a0c9ee8250357ef12505"
              && CalimochoReleasePin.release06.wineserverSha256
                == "7102d70405e7667acf143e710723f58fb24d32eee81468b1f0f02279343601d0"
              && CalimochoReleasePin.release06.engineJSONSha256
                == "d3ca32d8d706be0ca948f661f76e68c4a735b78362c6fb95fe50c12eb5db18ff"
              && CalimochoReleasePin.release06.manifestSha256
                == "db1b642e1d1a93cf50a3620a994ca049e34ce2352dc25fc34617a651302528bf"
              && CalimochoReleasePin.release06.teamID == "M62Z4M5EUY"
              && CalimochoRelease.engineID == pinned && CalimochoReleasePin.named(CalimochoRelease.engineID) != nil
              && release.name == "Calimocho \(EngineDisplayName.releaseVersion(pinned)!.version)"
              && release.detail == "Wine 11.20 · GPTK 4.0 beta 3" && !release.titleSpecific
              && EngineDisplayName.releaseVersion("calimocho-11.20-4.0b3-03")?.version == "0.1120.4.3"
              && EngineDisplayName.releaseVersion("calimocho-11.21-4.0b4-03")?.version == "0.1121.4.3"
              && EngineDisplayName.releaseVersion("calimocho-11.20-4.0b3-00") == nil
              && CalimochoRelease.displayName == release.name
              && CalimochoRelease.getTitle == "Get Calimocho"
              && CalimochoReleasePin.release06.downloadURL?.absoluteString
                == "https://github.com/WorkingPrinciple/calimocho/releases/download/engine-0.1120.4.6/calimocho-11.20-4.0b3-06-macos.zip"
              && CalimochoReleasePin.release06.archiveSha256
                == "3fc4467b466b6f8f0855c1934b2fe6a3d1c02b0c5ca85037860b735e4e419ee5"
              && CalimochoRelease.downloadURL == CalimochoReleasePin.release06.downloadURL
              && CalimochoRelease.downloadPublished,
              "REQ-115: The active -06 pin retains -04 and exposes only its exact archive-hash-pinned asset")
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
            let installerRoot = emptyRoot.appendingPathComponent("scenario-\(scenario)", isDirectory: true)
            if ["invalid", "pending", "ready"].contains(scenario) {
                try? FileManager.default.createDirectory(
                    at: installerRoot.appendingPathComponent(CalimochoRelease.engineID, isDirectory: true),
                    withIntermediateDirectories: true)
            }
            let installer = CalimochoReleaseInstallController(
                service: CalimochoReleaseInstallService(root: installerRoot))
            for scheme in [ColorScheme.light, .dark] {
                let form = EngineConfiguratorForm(choices: choices, defaultID: ready.id, defaultName: ready.name,
                    checking: false, error: nil, settings: settings, allowsFileReads: false,
                    userEngineStore: store, setDefault: { _ in }, refresh: {}, showsAdvanced: false,
                    calimochoStatus: status, calimochoInstaller: installer) { EmptyView() }
                let labels = render(form, size: CGSize(width: 600, height: 900), scheme: scheme,
                                    name: "engines-\(scenario)-\(scheme == .dark ? "dark" : "light")")
                let joined = labels.joined(separator: " ")
                check(labels.filter { $0 == "Check Again" }.count == 1
                      && joined.contains("Engines run Windows games")
                      && joined.contains("Play currently uses Calimocho")
                      && !joined.contains("Private") && !joined.contains("Use App"),
                      "COR186 M8/U2: \(scenario) Engines (\(scheme)) leads with an explanation, one Check Again, plain names and honest CrossOver copy: \(labels)")
                let hasDownloadControl = joined.contains("Get Calimocho")
                switch scenario {
                case "missing":
                    check(joined.contains("Calimocho isn't installed") && !joined.contains("install the engine folder")
                          && joined.contains("Check Again") && hasDownloadControl,
                          "REQ-115: Missing Calimocho offers in-app installation without manual folder instructions (\(scheme))")
                case "invalid":
                    check(joined.contains("couldn't be verified") && joined.contains("Not Verified")
                          && !labels.contains("Default") && !hasDownloadControl
                          && joined.contains("Remove Calimocho"),
                          "REQ-114(4): Invalid Calimocho gives the verification reason, marks it Not Verified, and offers safe removal (\(scheme))")
                case "pending":
                    check(joined.contains("will be ready once") && !joined.contains("isn't available for download")
                          && !joined.contains("Reinstall") && !hasDownloadControl,
                          "REVIEW H2b: A verified but not yet admitted release is neutral, with no reinstall or download prompt (\(scheme))")
                default:
                    check(!hasDownloadControl && joined.contains("Calimocho for DIRT 5")
                          && joined.contains(EngineDisplayName.name(CalimochoRelease.engineID)),
                          "COR186 U2: Ready engines show no download prompt and name release and game-specific builds (\(scheme))")
                }
            }
        }
        let installedRoot = emptyRoot.appendingPathComponent("installed-controls", isDirectory: true)
        let installedEngine = installedRoot.appendingPathComponent(CalimochoRelease.engineID, isDirectory: true)
        if (try? FileManager.default.createDirectory(at: installedEngine, withIntermediateDirectories: true)) != nil {
            defer { try? FileManager.default.removeItem(at: installedRoot) }
            let installedControls = CalimochoReleaseInstallControls(
                installer: CalimochoReleaseInstallController(
                    service: CalimochoReleaseInstallService(root: installedRoot)),
                isBusy: { false }, refreshAdmission: { false })
            let labels = render(installedControls, size: CGSize(width: 520, height: 220), scheme: .light,
                                name: "calimocho-installed-controls")
            let joined = labels.joined(separator: " ")
            check(joined.contains("Show in Finder") && joined.contains("Remove Calimocho")
                  && !joined.contains("Get Calimocho"),
                  "REQ-115: An installed release exposes its location actions rather than another Get action: \(labels)")
        } else {
            check(false, "REQ-115: Installed engine controls render from a temporary Engines root")
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
              && WelcomeCopy.technology == "X Ode runs Windows games with Wine and is built on Xodus."
              && "\(WelcomeCopy.acknowledgments) \(WelcomeCopy.credits)" == "Acknowledgments and licences are also in the X Ode menu."
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
                  && joined.contains("Wine") && joined.contains("Acknowledgments") && joined.contains("Xodus")
                  && joined.contains("menu") && joined.contains("licences")
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
            let readinessRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("XodusReadinessEngines-\(UUID().uuidString)")
            let installer = CalimochoReleaseInstallController(
                service: CalimochoReleaseInstallService(root: readinessRoot))
            let view = ReadinessChecklistView(session: LiveSession(), installed: InstalledGamesController(),
                                              allowsStatusReads: false, calimochoInstaller: installer)
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
        check(opened && WelcomeCopy.acknowledgmentsAccessibility == "Open-source acknowledgments and licences"
              && AppAcknowledgmentsView.windowID == "acknowledgments",
              "REQ-117: The login screen's Acknowledgments link opens the Acknowledgments window")
        for scheme in [ColorScheme.light, .dark] {
            let labels = render(AppAcknowledgmentsView(inventory: loaded), size: CGSize(width: 860, height: 1200),
                                scheme: scheme, name: "acknowledgments-\(scheme == .dark ? "dark" : "light")")
            let joined = labels.joined(separator: " ")
            check(joined.contains("Built on open source") && joined.contains("Key projects") && joined.contains("MoltenVK")
                  && joined.contains(FeaturedCredits.sectionTitle) && joined.contains("winehq.org")
                  && joined.contains("github.com/xodus-gaming/xodus") && joined.contains("CodeWeavers")
                  && (joined.range(of: FeaturedCredits.sectionTitle)?.lowerBound ?? joined.endIndex)
                    < (joined.range(of: "Key projects")?.lowerBound ?? joined.startIndex)
                  && joined.contains("Apple D3DMetal") && !joined.contains("DXVK"),
                  "REQ-117: The Acknowledgments window (\(scheme)) leads with the derived key projects and the separate D3DMetal note: \(labels)")
        }
    }

    // MARK: Wine and Xodus credits (REQ-122, COR-209)

    static func credits(check: (Bool, String) -> Void) {
        let wine = FeaturedCredits.wine, xodus = FeaturedCredits.xodus
        check(FeaturedCredits.sectionTitle == "Built on Wine and Xodus"
              && wine.url.absoluteString == "https://www.winehq.org" && wine.organisation == "WineHQ"
              && wine.license == "LGPL-2.1-or-later" && wine.role == "Runs Windows games on your Mac"
              && wine.thanks.contains("Wine authors") && wine.thanks.contains("CodeWeavers")
              && xodus.url.absoluteString == "https://github.com/xodus-gaming/xodus" && xodus.license == "GPL-3.0"
              && xodus.role.contains("Xbox library and install engine") && xodus.thanks.contains("Xodus contributors"),
              "REQ-122: Wine (WineHQ, LGPL-2.1-or-later) and Xodus (xodus-gaming, GPL-3.0) each have a role, a thank-you and a working link")
        let about = (AppBrandPresentation.aboutPanelOptions()[.credits] as? NSAttributedString)?.string ?? ""
        check(about.components(separatedBy: "\n").first == FeaturedCredits.aboutLine
              && FeaturedCredits.aboutLine.contains("Wine") && FeaturedCredits.aboutLine.contains("Xodus"),
              "REQ-122: About X Ode credits Wine and Xodus in one line above the copyright")
        let line = WelcomeCopy.technology
        check(line.hasPrefix("X Ode runs Windows games with Wine") && line.contains("Xodus")
              && "\(WelcomeCopy.acknowledgments) \(WelcomeCopy.credits)".contains("X Ode menu") && line.count <= 70
              && "\(WelcomeCopy.acknowledgments) \(WelcomeCopy.credits)".count <= 70
              && !FeaturedCredits.xodus.role.lowercased().contains("backend is built on")
              && FeaturedCredits.xodus.role.components(separatedBy: "backend").count == 2,
              "COR-209: The sign-in window names Wine first, then Xodus, and says where credits and licences are, in two short lines")
        let readme = (try? String(contentsOfFile: "README.md", encoding: .utf8)) ?? ""
        check(readme.contains(FeaturedCredits.readmeLine) && readme.contains(FeaturedCredits.helpMenu),
              "REQ-122: README's credits use the app's exact Wine and Xodus line (fails if README.md is missing)")
        check(AcknowledgmentsNavigation.appMenu.map(\.title) == ["Acknowledgments…", "Open-Source Licences…"]
              && AcknowledgmentsNavigation.appMenu.map(\.focus) == [.overview, .licences]
              && AcknowledgmentsNavigation.helpMenu.map(\.title) == ["Acknowledgments and Licences"],
              "COR-209: The X Ode menu has Acknowledgments… and Open-Source Licences…; Help has Acknowledgments and Licences")
        let navigation = AcknowledgmentsNavigation()
        var windows: [String] = []
        var focuses: [AcknowledgmentsNavigation.Focus?] = []
        for item in AcknowledgmentsNavigation.appMenu + AcknowledgmentsNavigation.helpMenu {
            navigation.open(item.focus) { windows.append($0) }
            focuses.append(navigation.request)
        }
        check(windows == Array(repeating: AppAcknowledgmentsView.windowID, count: 3)
              && focuses == [.overview, .licences, .overview],
              "COR-209: Each menu item opens the Acknowledgments window; Open-Source Licences asks for the licence list")
        check(AppAcknowledgmentsView.selection(for: .licences) == .licences
              && AppAcknowledgmentsView.selection(for: .overview) == .overview,
              "REQ-122 review L5: Open-Source Licences opens its own All components and licences page, so it never depends on scrolling before layout")
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let navigation = AcknowledgmentsNavigation()
            navigation.request = .licences
            let page = render(AppAcknowledgmentsView(inventory: AcknowledgmentsInventory(), navigation: navigation),
                              size: CGSize(width: 860, height: 600), scheme: scheme,
                              name: "req122-licences-\(suffix)").joined(separator: " ")
            check(page.contains(AppAcknowledgmentsView.licencesTitle) && page.contains("Choose one to read")
                  && !page.contains(FeaturedCredits.sectionTitle),
                  "REQ-122 review L5 render (\(suffix)): The licences request opens on the component and licence list: \(page.prefix(240))")
        }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let labels = render(AppAcknowledgmentsView(inventory: AcknowledgmentsInventory()),
                                size: CGSize(width: 860, height: 1100), scheme: scheme,
                                name: "req122-acknowledgments-\(suffix)").joined(separator: " ")
            check(labels.contains(FeaturedCredits.sectionTitle) && labels.contains("winehq.org")
                  // OCR can misread the small dark-mode link ("xodus-aaming"); the exact URL is asserted above.
                  && labels.contains("github.com/xodus-") && labels.contains("All components and licences"),
                  "REQ-122 render (\(suffix)): Built on Wine and Xodus leads Acknowledgments with both links, offline and signed out: \(labels)")
        }
    }

    // MARK: Permissions (REQ-118)

    static func permissions(check: (Bool, String) -> Void) {
        let usage = PrivacyPermission.allCases.compactMap(\.usageDescription)
        check(usage.map(\.key) == ["NSLocalNetworkUsageDescription", "NSRemovableVolumesUsageDescription",
                                    "NSNetworkVolumesUsageDescription", "NSDocumentsFolderUsageDescription",
                                    "NSDownloadsFolderUsageDescription", "NSDesktopFolderUsageDescription"]
              && usage.allSatisfy { $0.text.hasPrefix("X Ode") && $0.text.contains("games it runs") && !$0.text.contains("Xode") }
              && PrivacyPermission.localNetwork.usageDescription?.text.contains("multiplayer") == true
              && !(PrivacyPermission.localNetwork.usageDescription?.text.contains("Find consoles") ?? true)
              && PrivacyPermission.notifications.usageDescription == nil && PrivacyPermission.keychain.usageDescription == nil,
              "REQ-118 M3: Every usage string names X Ode and covers the games it runs; local network covers multiplayer")
        // Review H: the packaged Info.plist must carry every catalog usage string exactly.
        if let data = FileManager.default.contents(atPath: "tools/Info.plist"),
           let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            let missing = usage.filter { plist[$0.key] as? String != $0.text }
            func strings(_ value: Any) -> [String] {
                if let string = value as? String { return [string] }
                if let array = value as? [Any] { return array.flatMap(strings) }
                if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(strings) }
                return []
            }
            let retired = strings(plist).filter { $0.contains("Ode to X") || $0.contains("Xode") }
            check(missing.isEmpty && retired.isEmpty
                  && plist["NSMicrophoneUsageDescription"] == nil && plist["NSCameraUsageDescription"] == nil,
                  "REQ-118 review H: tools/Info.plist carries every catalog usage string exactly, no retired names, no microphone/camera (missing \(missing.map(\.key)), retired \(retired))")
        } else {
            check(false, "REQ-118 review H: tools/Info.plist is readable")
        }
        check(PrivacyPermission.localNetwork.settingsURL?.absoluteString.hasSuffix("Privacy_LocalNetwork") == true
              && PrivacyPermission.documents.settingsURL?.absoluteString.hasSuffix("Privacy_FilesAndFolders") == true
              && PrivacyPermission.notifications.settingsURL?.absoluteString.contains("Notifications-Settings") == true
              && PrivacyPermission.notifications.settingsLocation == "System Settings ▸ Notifications"
              && PrivacyPermission.keychain.settingsURL == nil && PrivacyPermission.keychainNote.contains("no System Settings switch"),
              "REQ-118 M4: Notifications open the Notifications pane; Keychain has no pane and is explained in text")
        // M2: an early policy error waits and retries; only a repeated one after the retry, while active, is "off".
        var allowedLater = LocalNetworkPermissionTracker()
        allowedLater.start()
        let firstRetry = allowedLater.searchFailed(code: LocalNetworkPermissionTracker.policyDenied, appActive: true)
        let waiting = allowedLater.state
        allowedLater.retrying()
        allowedLater.searchSucceeded()
        var deniedLater = LocalNetworkPermissionTracker()
        deniedLater.start()
        _ = deniedLater.searchFailed(code: LocalNetworkPermissionTracker.policyDenied, appActive: true)
        deniedLater.retrying()
        let inactive = deniedLater.searchFailed(code: LocalNetworkPermissionTracker.policyDenied, appActive: false)
        let stillWaiting = deniedLater.state
        _ = deniedLater.searchFailed(code: LocalNetworkPermissionTracker.policyDenied, appActive: true)
        check(firstRetry && waiting == .waitingForAnswer && allowedLater.state == .allowed
              && inactive && stillWaiting == .waitingForAnswer && deniedLater.state == .denied,
              "REQ-118 M2: An initial -65570 waits and retries (allowed afterwards stays allowed); only a repeat after a retry while active is a denial")
        let discovery = LocalNetworkDiscovery()
        discovery.isAppActive = { true }
        discovery.didNotSearch(code: LocalNetworkPermissionTracker.policyDenied)
        let firstStatus = discovery.status
        discovery.retryNow()
        discovery.didFind()
        let other = LocalNetworkDiscovery()
        other.didNotSearch(code: -72000)
        check(firstStatus == LocalNetworkDiscovery.waitingStatus && !discovery.denied
              && discovery.status.contains("Found") && !other.denied,
              "REQ-118 M2: Discovery shows a neutral wait after the first policy error and is allowed once the retry finds a console")
        let denying = LocalNetworkDiscovery()
        denying.isAppActive = { true }
        denying.didNotSearch(code: LocalNetworkPermissionTracker.policyDenied)
        denying.retryNow()
        denying.didNotSearch(code: LocalNetworkPermissionTracker.policyDenied)
        check(denying.denied && denying.status == LocalNetworkDiscovery.deniedStatus
              && denying.status.contains("Privacy & Security ▸ Local Network"),
              "REQ-118 M2: A policy error that persists after the retry is reported as off, with where to turn it on")
        // M1: privacy (EPERM) vs folder permissions (EACCES), component-safe locations, volume traits.
        let home = "/Users/example"
        let internalDisk: (String) -> (removable: Bool, local: Bool)? = { _ in (false, true) }
        check(PrivacyDenial.folderPermission(for: home + "/Documents", home: home, volume: internalDisk) == .documents
              && PrivacyDenial.folderPermission(for: home + "/Documents/Games", home: home, volume: internalDisk) == .documents
              && PrivacyDenial.folderPermission(for: home + "/DocumentsOld", home: home, volume: internalDisk) == nil
              && PrivacyDenial.folderPermission(for: home + "/Desktopper/x", home: home, volume: internalDisk) == nil
              && PrivacyDenial.folderPermission(for: home + "/Games/Xode", home: home, volume: internalDisk) == nil
              && PrivacyDenial.folderPermission(for: "/Volumes/USB/Games", home: home, volume: { _ in (true, true) }) == .removableVolumes
              && PrivacyDenial.folderPermission(for: "/Volumes/NAS/Games", home: home, volume: { _ in (false, false) }) == .networkVolumes,
              "REQ-118 M1: Locations match whole path components; unprotected internal folders get no privacy pane")
        let eperm = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let documents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Games").path
        check(PrivacyDenial.classify(eperm, path: documents) == .privacyDenied(.documents)
              && PrivacyDenial.classify(eacces, path: documents) == .notPermitted
              && PrivacyDenial.classify(CocoaError(.fileNoSuchFile), path: documents) == .other,
              "REQ-118 M1: EPERM is a privacy denial, EACCES is ordinary folder permissions")
        let cause = InstalledGameError.folderPermission
        let privacy = GameInstallLocationSettings.problem(for: cause, access: .privacyDenied(.documents))
        let ordinary = GameInstallLocationSettings.problem(for: cause, access: .notPermitted)
        let unprotected = GameInstallLocationSettings.problem(for: cause, access: .privacyDenied(nil))
        check(privacy.permission == .documents && privacy.message.contains("Files and Folders")
              && ordinary.permission == nil && !ordinary.message.contains("Files and Folders") && ordinary.message.contains("Get Info")
              && unprotected.permission == nil && !unprotected.message.contains("Files and Folders")
              && !cause.localizedDescription.contains("Files and Folders"),
              "REQ-118 M1: The games-folder error path offers Files and Folders only for a privacy denial in a protected place")
        let locked = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/XodusLockedFolder-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o000)
        let lockedAccess = PrivacyDenial.probe(locked)
        chmod(locked.path, 0o700)
        try? FileManager.default.removeItem(at: locked)
        check(lockedAccess == .notPermitted
              && GameInstallLocationSettings.problem(for: cause, access: lockedAccess).permission == nil,
              "REQ-118 L1: A real folder without read permission (EACCES) is ordinary permissions end to end, with no privacy button")
        let readme = (try? String(contentsOfFile: "README.md", encoding: .utf8)) ?? ""
        // Round 3 M: installed games (relaunch, discard) get the same EPERM/EACCES split as the chooser.
        let protectedPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Games/Halls").path
        let installedPrivacy = InstalledGameFiles.folderReadError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
                                                                  path: protectedPath)
        let installedOrdinary = InstalledGameFiles.folderReadError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                                                                   path: protectedPath)
        let installedUnprotected = InstalledGameFiles.folderReadError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
                                                                      path: "/opt/Games/Halls")
        let privacyMessage = installedPrivacy.localizedDescription
        check(installedPrivacy == .folderPrivacy(.documents)
              && privacyMessage.contains("Files and Folders") && !privacyMessage.contains("Finder")
              && PrivacyDenial.permission(inMessage: "The partial download wasn't deleted. " + privacyMessage) == .documents
              && installedOrdinary == .folderPermission && installedUnprotected == .folderPermission
              && !installedOrdinary.localizedDescription.contains("Files and Folders")
              && PrivacyDenial.permission(inMessage: installedOrdinary.localizedDescription) == nil
              && InstalledGameFiles.folderReadError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)) == .folderPermission,
              "REQ-118 round 3 M: Installed-game EPERM in a protected place explains Files and Folders and offers its button; EACCES stays plain")
        let deepMissing = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("XodusDoesNotExist-\(UUID().uuidString)/denied/child").path
        check(PrivacyDenial.volumeTraits(deepMissing) != nil
              && PrivacyPermission.notifications.settingsURL?.absoluteString.hasSuffix("?id=" + (Bundle.main.bundleIdentifier ?? PrivacyPermission.bundleIdentifier)) == true
              && readme.contains(PrivacyPermission.localNetworkPromptNote),
              "REQ-118 round 3 L2/L4: Volume traits come from the nearest readable ancestor; Notifications opens X Ode's own row; the prompt-focus note is in the install notes")
        // Notifications are requested only when an install or repair finishes (GameReadyNotifier.post), never at launch.
        let sources = (try? FileManager.default.subpathsOfDirectory(atPath: "Sources")) ?? []
        let requesters = sources.filter { $0.hasSuffix(".swift") && !$0.hasSuffix("BrandUXChecks.swift") }.filter {
            ((try? String(contentsOfFile: "Sources/" + $0, encoding: .utf8)) ?? "").contains("requestAuthorization")
        }
        let notifier = (try? String(contentsOfFile: "Sources/XodusPreview/GameReadyNotifier.swift", encoding: .utf8)) ?? ""
        let postBody = notifier.range(of: "func post(").map { String(notifier[$0.lowerBound...]) } ?? ""
        let beforePost = notifier.range(of: "func post(").map { String(notifier[..<$0.lowerBound]) } ?? notifier
        check(!sources.isEmpty && requesters == ["XodusPreview/GameReadyNotifier.swift"]
              && postBody.contains("requestAuthorization") && !beforePost.contains("requestAuthorization"),
              "REQ-118: Notification permission is asked only when a finished install posts its ready notice, never at launch")
        check(readme.contains("## " + PrivacyPermission.installNotesTitle)
              && PrivacyPermission.allCases.allSatisfy { readme.contains("| \($0.title) | \($0.reason) |") }
              && readme.contains(PrivacyPermission.gamesNote) && readme.contains(PrivacyPermission.keychainNote)
              && readme.contains(PrivacyPermission.microphoneKnownIssue)
              && readme.contains("System Settings ▸ Notifications") && readme.contains("Developer ID")
              && !readme.contains("| Microphone |"),
              "REQ-118 L1: The install notes exist and list every permission with the app's exact words (fails if README.md is missing)")
        for scheme in [ColorScheme.light, .dark] {
            let labels = render(Form { PrivacyPermissionsSection() }.formStyle(.grouped),
                                size: CGSize(width: 600, height: 860), scheme: scheme,
                                name: "permissions-\(scheme == .dark ? "dark" : "light")")
            let joined = labels.joined(separator: " ")
            check(joined.contains("Permissions") && joined.contains("Local network") && joined.contains("Open Notifications")
                  && joined.contains("Open Local Network Settings") && !joined.contains("Open Privacy"),
                  "REQ-118 round 3 L3: Settings ▸ General lists permissions with buttons named for where they go (\(scheme)): \(labels)")
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

    // MARK: First library load (REQ-119, COR-213)

    static func firstLoad(check: (Bool, String) -> Void) {
        typealias Inputs = LibraryFirstLoadInputs
        let t0 = ContinuousClock.now
        let grace = LibraryFirstLoad.graceDelay
        func begun() -> LibraryFirstLoad { var value = LibraryFirstLoad(); value.begin(at: t0); return value }

        var fast = begun()
        let pendingFirst = fast.phase == .pending && !fast.covers && fast.active
        fast.update(Inputs(loading: true, gamesFound: 3), now: t0 + .milliseconds(200))
        let stillHidden = fast.phase == .pending && !fast.covers
        fast.update(Inputs(gamesFound: 3, libraryComplete: true, artworkTotal: 4, artworkReady: 4, artworkSettled: true),
                    now: t0 + .milliseconds(350))
        var slowStart = begun()
        slowStart.update(Inputs(loading: true), now: t0 + grace - .milliseconds(1))
        let notYet = !slowStart.covers
        slowStart.update(Inputs(loading: true), now: t0 + grace)
        check(LibraryFirstLoad.shouldBegin(signedIn: true) && !LibraryFirstLoad.shouldBegin(signedIn: false)
              && pendingFirst && stillHidden && fast.phase == .finished(.ready) && !fast.covers
              && LibraryFirstLoad.announcement(from: begun(), to: fast) == nil
              && notYet && slowStart.covers && slowStart.step == .findingGames,
              "REQ-119 COR-213: Every launch waits \(grace) before covering; a fast library never shows the setup view, a slow one covers instead of showing placeholders")

        var cold = begun()
        cold.update(Inputs(loading: true), now: t0 + grace)
        let started = cold
        let finding = cold.covers && cold.step == .findingGames && !cold.offersShowNow
        cold.update(Inputs(loading: true, gamesFound: 5), now: t0 + .seconds(2))
        let stillFinding = cold.covers && cold.step == .findingGames
        cold.update(Inputs(loading: true, gamesFound: 8, artworkTotal: 9, artworkReady: 3), now: t0 + .seconds(4))
        let fetching = cold.covers && cold.step == .fetchingArtwork
        let artworkStep = cold
        cold.update(Inputs(loading: true, gamesFound: 40, artworkTotal: 9, artworkReady: 9, artworkSettled: true),
                    now: t0 + .seconds(5))
        check(finding && stillFinding && fetching && cold.phase == .finished(.ready) && !cold.covers,
              "REQ-119: Signed in, then finding games with a live count, then the first viewport's artwork; hands over then, while the rest still loads")
        var small = begun()
        small.update(Inputs(gamesFound: 3, libraryComplete: true, artworkTotal: 4, artworkReady: 1, artworkSettled: true), now: t0 + grace)
        var empty = begun()
        empty.update(Inputs(libraryComplete: true), now: t0 + grace)
        check(small.phase == .finished(.ready) && empty.phase == .finished(.ready),
              "REQ-119: A small library hands over once its artwork settles, even with failed covers; an empty library opens straight away")

        var slow = begun()
        slow.update(Inputs(loading: true, gamesFound: 2), now: t0 + .seconds(19))
        let notSlow = slow.phase == .loading && !slow.offersShowNow
        slow.update(Inputs(loading: true, gamesFound: 2), now: t0 + LibraryFirstLoad.slowAfter)
        let offered = slow.phase == .slow && slow.offersShowNow && slow.covers
        var readyLate = slow
        readyLate.update(Inputs(loading: true, gamesFound: 8, artworkTotal: 9, artworkReady: 9, artworkSettled: true), now: t0 + .seconds(25))
        slow.showLibraryNow()
        check(notSlow && offered && slow.phase == .finished(.showNow) && !slow.covers
              && readyLate.phase == .finished(.ready),
              "REQ-119 slow: After 20 s it offers Show library now and never blocks; reaching the first screen later still hands over")

        var failing = begun()
        failing.update(Inputs(loading: true), now: t0 + grace)
        failing.update(Inputs(error: "Your PC library couldn't load. The request timed out."), now: t0 + .seconds(3))
        let failed = failing.failure == "Your PC library couldn't load. The request timed out." && failing.covers
            && failing.offersShowNow
        var retried = failing
        retried.retry(at: t0 + .seconds(4))
        retried.update(Inputs(error: "Your PC library couldn't load. The request timed out."), now: t0 + .seconds(4))
        let waitsForRetry = retried.phase == .loading
        var stuck = retried
        stuck.update(Inputs(error: "Your PC library couldn't load. The request timed out."), now: t0 + .seconds(25))
        retried.update(Inputs(loading: true), now: t0 + .seconds(5))
        let reloading = retried.phase == .loading
        retried.update(Inputs(gamesFound: 3, libraryComplete: true, artworkSettled: true), now: t0 + .seconds(7))
        var partial = begun()
        partial.update(Inputs(gamesFound: 4, libraryComplete: true, error: "Some games didn't load.",
                              artworkSettled: true), now: t0 + grace)
        check(failed && waitsForRetry && reloading && retried.phase == .finished(.ready)
              && partial.phase == .finished(.ready),
              "REQ-119 failure: A load error shows its specific message with Try Again; Try Again ignores the stale error until the reload starts; a partial library still opens")
        check(stuck.phase == .slow && stuck.offersShowNow,
              "REQ-119 review L1: Try Again whose reload never starts still reaches Show library now after 20 s")

        var account = begun()
        account.update(Inputs(error: "Confirm your account country to load your PC library.", needsAccountAction: true), now: t0)
        var signedOut = begun()
        signedOut.update(Inputs(signedIn: false, loading: true), now: t0 + grace)
        check(account.phase == .finished(.accountAction) && !signedOut.active && signedOut.phase == .inactive,
              "REQ-119: Account country, sign-in or Keychain actions hand over to the library that asks for them; signing out removes the overlay")

        // M1: the first viewport is tracked per image, in display order, across out-of-order batches.
        func ref(_ name: String) -> CatalogArtworkReference {
            let json = #"{"role":"boxArt","url":"https://store-images.s-microsoft.com/image/"# + name
                + #"","width":600,"height":900,"source":"MicrosoftDisplayCatalog:v7.0"}"#
            return try! JSONDecoder().decode(CatalogArtworkReference.self, from: Data(json.utf8))
        }
        typealias Item = FirstScreenArtwork.Item
        let hero = Item(kind: .hero, id: "9HERO0000001", reference: ref("hero"))
        let a = Item(kind: .cover, id: "9AAAA0000001", reference: ref("a"))
        let b = Item(kind: .cover, id: "9BBBB0000001", reference: ref("b"))
        let pendingC = Item(kind: .cover, id: "9CCCC0000001", reference: nil, resolved: false)
        var artwork = FirstScreenArtwork()
        let first = artwork.target([hero, a, b, pendingC])
        artwork.settle(a, generation: first)
        let partialFirst = artwork.ready == 1 && artwork.total == 4 && !artwork.settled
        let aaa = Item(kind: .cover, id: "9AAA00000000", reference: ref("aaa"))
        let second = artwork.target([hero, aaa, a, b])
        let cancelledCounted = artwork.settle(b, generation: first)
        let keptA = artwork.ready == 1 && artwork.pending == [hero, aaa, b]
        for item in [hero, aaa] { artwork.settle(item, generation: second) }
        let missingHero = !artwork.settled
        artwork.settle(b, generation: second)
        var unresolved = FirstScreenArtwork()
        _ = unresolved.target([pendingC])
        check(partialFirst && !cancelledCounted && keptA && missingHero && artwork.settled
              && !unresolved.settled && unresolved.ready == 0,
              "REQ-119 review M1: First-screen artwork includes the hero, keeps settled images when a later batch reorders the grid, ignores a superseded run, and never treats an unread descriptor as ready")

        let appSource = (try? String(contentsOfFile: "Sources/XodusPreview/XodusPreviewApp.swift", encoding: .utf8)) ?? ""
        check(appSource.contains("TextEditingCommands()") && !appSource.contains("replacing: .textEditing")
              && !appSource.contains("replacing: .textFormatting"),
              "QA U1: The Edit menu keeps the system Spelling and Grammar, Substitutions, Transformations and Speech submenus (TextEditingCommands, nothing replaces .textEditing); fails if the source is missing")
        let custom = EngineChoice.named("wine-custom-11", ready: true,
                                        playable: EngineChoice.playsInBeta(admittedProvider: "wine"))
        let release = EngineChoice.named(CalimochoRelease.engineID, ready: true,
                                         playable: EngineChoice.playsInBeta(admittedProvider: "calimocho"))
        check(!custom.playable && release.playable && RuntimeProviderSettings.providerChoices == [.calimocho]
              && EnginesCopy.lead.contains("for testing; in this beta, games play with Calimocho")
              && EnginesCopy.testingOnly.contains("Calimocho")
              && NativeLaunchError.providerPolicy.localizedDescription.contains("Calimocho"),
              "COR-201 E7: Added engines are kept for testing: the default and per-game choices offer only Calimocho, other engines say testing only, and Play refuses anything else with a clear message")
        let chrome = AppState()
        let chromeWindow = UUID()
        chrome.setFirstLoadCovering(true, window: chromeWindow)
        chrome.openAccount()
        let accountBlocked = !chrome.showingAccount
        chrome.setFirstLoadCovering(false, window: chromeWindow)
        chrome.openAccount()
        check(accountBlocked && chrome.showingAccount,
              "REQ-119 review M2: While the setup view covers the window, Account (and the toolbar, Navigate and Import, which share the flag) wait; afterwards they work")

        let lines = FirstLoadCopy.lines
        let failureText = FirstLoadCopy.failedTitle + " " + "Your PC library couldn't load. The request timed out."
        check(lines.count == 8 && Set(lines).count == 8
              && lines.allSatisfy { $0.hasSuffix("…") && $0.count <= 30 && !$0.contains("!") && !$0.contains("—") }
              && !lines.contains("Polishing the cover art…")
              && failureText.components(separatedBy: "couldn't load").count == 2
              && !(lines + [FirstLoadCopy.title, FirstLoadCopy.slow, FirstLoadCopy.failedTitle]).contains { text in
                  AppBrand.retiredNames.contains { text.contains($0) } },
              "REQ-119 copy: Eight distinct short lines without near-duplicates; the failure screen says \"couldn't load\" once: \(lines)")

        let priority = LiveSession()
        priority.beginLibraryReadPriority()
        let yields = priority.yieldsToLibraryRead && !priority.canLoadRecentLibrary
        priority.endLibraryReadPriority()
        priority.endLibraryReadPriority()
        check(yields && !priority.yieldsToLibraryRead && priority.libraryReadsWaiting == 0,
              "REQ-119 quick win: Recent-activity and license reads hold back while the cold library read waits to dispatch, and the hold always clears")

        func restoring(settled: Bool, expected: Bool = true, for wait: TimeInterval? = 0.5,
                       _ state: CredentialState?, hash: Bool, unverified: TimeInterval? = nil) -> Bool {
            LiveSession.signInRestoring(statusSettled: settled, restoreExpected: expected, restoringFor: wait,
                                        state: state, hashValid: hash, unverifiedFor: unverified)
        }
        let restoringPath = restoring(settled: false, nil, hash: false)
            && restoring(settled: true, .credentialPresent, hash: false, unverified: 0.7)
            && restoring(settled: true, .credentialPresent, hash: false, unverified: 2.9)
        let confirmed = !restoring(settled: true, .credentialPresent, hash: true)
        let realFailures = [CredentialState.expired, .invalid, .signedOut].allSatisfy {
            !restoring(settled: true, $0, hash: false)
        } && !restoring(settled: true, .credentialPresent, hash: false, unverified: LiveSession.restoreGrace)
        check(restoringPath && confirmed && realFailures && !WelcomeCopy.restoring.contains("reconnect")
              && WelcomeCopy.restoring == "Checking your sign-in…",
              "REQ-119 restore: Launch → first status → identity verification → signed in stays on \"Checking your sign-in…\" and never passes through \"needs to be reconnected\"; that copy appears only for expired or invalid sign-ins, or after a \(Int(LiveSession.restoreGrace)) s unverified wait")
        check(!restoring(settled: false, expected: false, nil, hash: false)
              && !restoring(settled: false, for: LiveSession.restoreGrace, nil, hash: false),
              "REQ-119 review M-A: A plain Reconnect that reads no status is never \"restoring\", and an unanswered launch read stops restoring (and re-enables Sign in) after \(Int(LiveSession.restoreGrace)) s")
        check(LiveSession.rereadsStatusAtGrace(state: .credentialPresent, hashValid: false, alreadyReread: false)
              && !LiveSession.rereadsStatusAtGrace(state: .credentialPresent, hashValid: false, alreadyReread: true)
              && !LiveSession.rereadsStatusAtGrace(state: .credentialPresent, hashValid: true, alreadyReread: false)
              && !LiveSession.rereadsStatusAtGrace(state: .expired, hashValid: false, alreadyReread: false),
              "REQ-119 review M-A: At the end of the wait an unverified sign-in is read once more before reconnect copy shows")
        let restoringSession = LiveSession()
        check(!restoringSession.restoringSignIn,
              "REQ-119 restore: A session that can't read sign-in status never sits in the restoring state")

        var immediate = LibraryFirstLoad()
        immediate.begin(at: t0, immediate: true)
        check(immediate.covers && immediate.phase == .loading && begun().phase == .pending,
              "REQ-119 review L1: Right after this run's own sign-in the setup view covers at once; only restored launches wait the grace delay")
        let dropped = FirstScreenArtwork.resolved(loaded: false, failed: false, requested: true, pending: false)
        let inFlight = FirstScreenArtwork.resolved(loaded: false, failed: false, requested: true, pending: true)
        let unasked = FirstScreenArtwork.resolved(loaded: false, failed: false, requested: false, pending: false)
        var droppedHero = FirstScreenArtwork()
        _ = droppedHero.target([.init(kind: .hero, id: "9HERO0000002", reference: nil, resolved: dropped)])
        check(dropped && !inFlight && !unasked && droppedHero.settled,
              "REQ-119 review L2: A dropped hero descriptor (e.g. PACKAGE_UNAVAILABLE) counts as resolved with fallback art, so hand-over doesn't wait 20 s")
        let countryStore = UserDefaults(suiteName: "req121.country.\(UUID().uuidString)")!
        let countryAccount = String(repeating: "c", count: 64)
        countryStore.set("GB", forKey: LiveSession.lastVerifiedCountryKey(countryAccount))
        countryStore.set("FR", forKey: "Xodus.accountCountry.\(countryAccount)")
        let countrySession = LiveSession(countryDefaults: countryStore)
        countrySession.applyProvisionalAccountCountry()
        let ignoredSignedOut = !countrySession.accountCountryReady && !countrySession.accountCountryProvisional
        countrySession.forgetAccountCountry(countryAccount)
        check(ignoredSignedOut && LiveSession.lastVerifiedCountryKey(countryAccount).hasSuffix(countryAccount)
              && countryStore.string(forKey: LiveSession.lastVerifiedCountryKey(countryAccount)) == nil
              && countryStore.string(forKey: "Xodus.accountCountry.\(countryAccount)") == nil,
              "REQ-121 hook: The provisional launch country is only a country code keyed by the account hash, never applied without a confirmed sign-in, and removed on sign-out")
        check(LibraryFirstLoad.gamesReady(Inputs(loading: true, gamesFound: 3, libraryComplete: true))
              && !LibraryFirstLoad.gamesReady(Inputs(loading: true, gamesFound: 3, libraryComplete: false)),
              "REQ-121 hook: A complete library counts as ready even while a background revalidation keeps it busy")
        let installedFixtures = (0..<3).map {
            InstalledGame(id: UUID(), title: "Installed \($0)", identityName: "Fixture.Installed\($0)", version: "1.0.0.0",
                          storeId: String(format: "FIXTURE%05d", $0 + 10), folder: "/tmp/installed-\($0)", launcher: "",
                          importedAt: Date(), usesNativeLifecycle: true)
        }
        let localFixtures = LibraryGame.localRecords(installed: installedFixtures, qualified: [], query: "", sort: .title)
        let missingLauncher = NativeMinecraftInstallation(state: .missing)
        let readyLauncher = NativeMinecraftInstallation(state: .ready)
        check(missingLauncher.appears(in: .all, query: "")
              && LibraryGame.installedCount(local: localFixtures, native: missingLauncher.countsAsInstalled) == 3
              && LibraryGame.installedCount(local: localFixtures, native: readyLauncher.countsAsInstalled) == 4
              && !NativeMinecraftInstallation(state: .checking).countsAsInstalled,
              "QA REQ-64: \"Installed games\" counts only completed installs; the Minecraft card offered in All while its launcher is missing or still checking isn't counted, and partial downloads stay in the resume journal")
        let windowState = AppState()
        let windowA = UUID(), windowB = UUID()
        windowState.setFirstLoadCovering(true, window: windowA)
        windowState.setFirstLoadCovering(true, window: windowB)
        windowState.setFirstLoadCovering(false, window: windowB)
        let stillCovered = windowState.firstLoadCovering
        windowState.setFirstLoadCovering(false, window: windowA)
        windowState.openAccount()
        check(stillCovered && !windowState.firstLoadCovering && windowState.showingAccount,
              "REQ-119 review M-B: Closing a window during setup ends only its own covering; once none cover, Account, Navigate and Import work in a reopened window")
        check(LiveSession.countrySource(verified: false, provisional: true) == "last confirmed by Xbox"
              && LiveSession.countrySource(verified: true, provisional: false) == "verified by Xbox"
              && LiveSession.countrySource(verified: false, provisional: false) == "confirmed by you"
              && LiveSession.provisionalCountryRetry > 0,
              "REQ-121 review L2: A provisional country reads \"last confirmed by Xbox\", never \"confirmed by you\", and the failed re-check is retried once later")

        let still = LibraryFirstLoadMotion(reduceMotion: true)
        let moving = LibraryFirstLoadMotion(reduceMotion: false)
        check(still.lineChange == .crossfade && !still.showsSpinner && moving.lineChange == .slide && moving.showsSpinner,
              "REQ-119 Reduce Motion: No spinner or sliding text, at most a crossfade between lines")

        let announced = [LibraryFirstLoad.announcement(from: begun(), to: started),
                         LibraryFirstLoad.announcement(from: started, to: artworkStep),
                         LibraryFirstLoad.announcement(from: artworkStep, to: cold)]
        var counted = started
        counted.update(Inputs(loading: true, gamesFound: 7), now: t0 + grace)
        var slowAgain = begun()
        slowAgain.update(Inputs(loading: true), now: t0 + grace)
        let beforeSlow = slowAgain
        slowAgain.update(Inputs(loading: true), now: t0 + .seconds(21))
        check(announced == [FirstLoadCopy.findingGames, FirstLoadCopy.fetchingArtwork, FirstLoadCopy.ready]
              && LibraryFirstLoad.announcement(from: started, to: counted) == nil
              && LibraryFirstLoad.announcement(from: beforeSlow, to: slowAgain) == FirstLoadCopy.slow
              && LibraryFirstLoad.announcement(from: started, to: failing)?.hasPrefix(FirstLoadCopy.failedTitle) == true
              && LibraryFirstLoad.announcement(from: failing, to: retried) == FirstLoadCopy.ready,
              "REQ-119 VoiceOver: Step and state changes are announced; count changes, the grace delay and the rotating lines are not")

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let loading = render(LibraryFirstLoadView(state: artworkStep,
                    inputs: Inputs(loading: true, gamesFound: 13, artworkTotal: 9, artworkReady: 5),
                    showNow: {}, tryAgain: {}, lineIndex: 0),
                size: CGSize(width: 900, height: 620), scheme: scheme, name: "req119-first-load-\(suffix)")
            let joined = loading.joined(separator: " ")
            check(joined.contains(FirstLoadCopy.title) && joined.contains("Signed in") && joined.contains("Found 13 games")
                  && joined.contains("Fetching artwork") && joined.contains("5 of 9")
                  && joined.contains("Unboxing your games") && !joined.contains(FirstLoadCopy.showNow),
                  "REQ-119 render (\(suffix)): Setting up your library shows the three steps, the live count and a line, with no placeholder tiles: \(loading)")
            var slowState = begun()
            slowState.update(Inputs(loading: true, gamesFound: 4), now: t0 + .seconds(21))
            let slowText = render(LibraryFirstLoadView(state: slowState, inputs: Inputs(loading: true, gamesFound: 4),
                    showNow: {}, tryAgain: {}, lineIndex: 1),
                size: CGSize(width: 900, height: 620), scheme: scheme, name: "req119-first-load-slow-\(suffix)")
                .joined(separator: " ")
            check(slowText.contains(FirstLoadCopy.showNow) && slowText.contains("Found 4 games"),
                  "REQ-119 render (\(suffix)): After the wait, Show library now appears under the live progress")
            let failure = render(LibraryFirstLoadView(state: failing, inputs: Inputs(error: failing.failure),
                    showNow: {}, tryAgain: {}, lineIndex: 2),
                size: CGSize(width: 900, height: 620), scheme: scheme, name: "req119-first-load-failed-\(suffix)")
                .joined(separator: " ")
            check(failure.contains(FirstLoadCopy.failedTitle) && failure.contains("request timed out")
                  && failure.contains(FirstLoadCopy.tryAgain) && failure.contains(FirstLoadCopy.showNow),
                  "REQ-119 render (\(suffix)): A failure shows its specific error with Try Again and Show library now")
        }
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
        do { return try NativeCheckOCR.recognize(image) }
        catch { return [error.localizedDescription] }
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
