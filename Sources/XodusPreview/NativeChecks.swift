// SPDX-License-Identifier: GPL-3.0-only
import CoreFoundation
import CryptoKit
import Foundation
import XodusManagement

@MainActor
enum NativeChecks {
    static func launch(gameOperationsOnly: Bool = false, mediaOnly: Bool = false, statsOnly: Bool = false,
                       libraryAccessOnly: Bool = false, accountPresentationOnly: Bool = false,
                       engineSelectionOnly: Bool = false, settingsOnly: Bool = false) -> Never {
        Task { exit(await run(gameOperationsOnly: gameOperationsOnly, mediaOnly: mediaOnly, statsOnly: statsOnly,
                              libraryAccessOnly: libraryAccessOnly, accountPresentationOnly: accountPresentationOnly,
                              engineSelectionOnly: engineSelectionOnly, settingsOnly: settingsOnly) ? 0 : 1) }
        CFRunLoopRun()
        fatalError("The native check run loop ended before completion.")
    }

    static func run(gameOperationsOnly: Bool = false, mediaOnly: Bool = false, statsOnly: Bool = false,
                    libraryAccessOnly: Bool = false, accountPresentationOnly: Bool = false,
                    engineSelectionOnly: Bool = false, settingsOnly: Bool = false) async -> Bool {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if condition { print("PASS: \(name)") }
            else {
                failures += 1
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
            }
            fflush(stdout)
        }
        func configuration(_ scenario: String) -> BackendConfiguration {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("XodusManagementChecks")
            let state = FileManager.default.temporaryDirectory
                .appendingPathComponent("XodusNativeChecks-\(UUID().uuidString)").appendingPathComponent(scenario)
            return BackendConfiguration(executable: executable, stateDirectory: state)
        }
        func session(_ scenario: String) -> LiveSession { LiveSession(configuration: configuration(scenario)) }
        func trace(_ configuration: BackendConfiguration) throws -> [String] {
            try String(contentsOf: configuration.stateDirectory.appendingPathComponent("lifecycle.log"),
                       encoding: .utf8).split(separator: "\n").map(String.init)
        }
        func cleanLifecycle(_ configuration: BackendConfiguration) throws {
            try FileManager.default.removeItem(at: configuration.stateDirectory.deletingLastPathComponent())
        }
        func waitForTrace(_ marker: String, _ configuration: BackendConfiguration) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while true {
                if FileManager.default.fileExists(atPath: configuration.stateDirectory.appendingPathComponent("lifecycle.log").path),
                   try trace(configuration).contains(marker) { return }
                guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        do {
            if settingsOnly {
                try NativeUIChecks.checkSettingsLayouts(check: check)
                BrandUXChecks.run(check: check)
                print("\(count) Settings layout checks, \(failures) failures. Detached views; isolated preferences; no sign-in or network requests.")
                return failures == 0
            }
            if engineSelectionOnly {
                try NativeLifecycleChecks.launchOutcomeChecks(check: check)
                try await NativeLifecycleChecks.run(check: check)
                let signedOutConfiguration = configuration("odeunifiedsignedout")
                let signedOut = LiveSession(configuration: signedOutConfiguration)
                await signedOut.connect()
                let settingsSuite = "XodusUnifiedSignedOut-\(UUID().uuidString)"
                guard let settingsDefaults = UserDefaults(suiteName: settingsSuite) else {
                    check(false, "COR174 signed-out unified routing uses isolated preferences")
                    return failures == 0
                }
                defer { settingsDefaults.removePersistentDomain(forName: settingsSuite) }
                let accountState = AppState(settingsDefaults: settingsDefaults)
                let configured = accountState.configureUnifiedAccountMode(session: signedOut)
                let signedOutTraceURL = signedOutConfiguration.stateDirectory.appendingPathComponent("lifecycle.log")
                let signedOutTrace = FileManager.default.fileExists(atPath: signedOutTraceURL.path)
                    ? try trace(signedOutConfiguration) : []
                check(signedOut.isReady && signedOut.supports(.odeAccountRead)
                      && signedOut.authentication == nil && !signedOut.hasConfirmedSignIn
                      && signedOutTrace.filter { $0.hasPrefix("auth.") }.isEmpty,
                      "COR174 signed-out unified backend is identified by capability without auth requests (ready \(signedOut.isReady), capability \(signedOut.supports(.odeAccountRead)), auth \(signedOut.authentication != nil), phase \(signedOut.phase), error \(signedOut.errorMessage ?? "none"))")
                check(configured && accountState.gameOperations.usesUnifiedAccount
                      && accountState.pcGames.usesUnifiedAccount
                      && accountState.gameOperations.serviceSignInActionTitle == nil
                      && accountState.gameOperations.serviceLabel == "Check Xbox account connection",
                      "COR174 signed-out unified mode suppresses the legacy Microsoft sign-in and reports the connection honestly (configured \(configured), service sign-in \(accountState.gameOperations.serviceSignInActionTitle ?? "none"), label \(accountState.gameOperations.serviceLabel))")
                var openedOdeAccount = false
                let signedOutAccess = GameServiceSignInActions(
                    operations: accountState.gameOperations, statusText: "",
                    statusIdentifier: "test.status", checkIdentifier: "test.check",
                    signInIdentifier: "test.signIn", errorIdentifier: "test.error",
                    logIdentifier: "test.log", verifyIdentifier: "test.verify",
                    onOpenOdeAccount: { accountState.openAccount(); openedOdeAccount = true })
                signedOutAccess.openOdeAccount()
                check(openedOdeAccount && accountState.showingAccount,
                      "COR174 unified Xbox access recovery opens the existing Ode account flow")
                check(await signedOut.disconnect(), "COR174 closes only its signed-out mock backend")
                if FileManager.default.fileExists(atPath: signedOutTraceURL.path) {
                    try cleanLifecycle(signedOutConfiguration)
                }
                try await EngineManagementChecks.routingOnly(check: check)
                try await EngineConfiguratorChecks.run(check: check)
                try await InstalledGameChecks.legacyNativeReadiness(check: check)
                try await InstalledGameChecks.externalDiscoveryChecks(check: check)
                try await InstalledGameChecks.discoveryIsolationChecks(check: check)
                InstalledGameChecks.descriptionChecks(check: check)
                print("\(count) non-UI engine selection checks, \(failures) failures. No windows, account or game launches.")
                return failures == 0
            }
            if accountPresentationOnly {
                try await AccountCountryChecks.run(configuration: configuration, check: check)
                let pendingConfiguration = configuration("statuspermission")
                let pending = LiveSession(configuration: pendingConfiguration)
                await pending.connect()
                await pending.refreshAccount()
                let reading = Task { await pending.revalidateAccountOnForeground() }
                try await wait { pending.accountStatusChecking }
                try await NativeUIChecks.checkAccountDismissalWhileLoading(session: pending, check: check)
                await reading.value
                check(pending.hasConfirmedSignIn && !pending.accountBusy,
                      "COR95: The unrelated account read completes normally after dismissal")
                check(try trace(pendingConfiguration).filter { $0.hasPrefix("auth.") } == ["auth.status", "auth.status"],
                      "COR95: Dismissal issues no sign-in, cancellation, logout or replacement read")
                check(await pending.disconnect(), "COR95: The check retires only its synthetic management child")
                try cleanLifecycle(pendingConfiguration)
                print("\(count) Account presentation checks, \(failures) failures. Detached views and mock child only.")
                return failures == 0
            }
            let navigation = AppState()
            navigation.query = "Library search"
            navigation.navigate(.discover)
            navigation.query = "Store search"
            navigation.navigate(.library)
            check(navigation.query == "Library search", "Library query survives tab navigation")
            navigation.navigate(.discover)
            check(navigation.query == "Store search", "Discover query survives tab navigation")
            navigation.librarySelection.filter = .installed
            navigation.librarySelection.sort = .recentlyPlayed
            navigation.librarySelection.heroID = "library-hero"
            navigation.librarySelection.scrollID = "library-card-fixture"
            navigation.discoverSelection.genre = "Adventure"
            navigation.discoverSelection.scope = .installed
            navigation.discoverSelection.featuredID = "discover-hero"
            navigation.discoverSelection.scrollID = "discover-card-fixture"
            navigation.navigate(.library)
            navigation.navigate(.discover)
            check(navigation.librarySelection.filter == .installed
                  && navigation.librarySelection.sort == .recentlyPlayed
                  && navigation.librarySelection.heroID == "library-hero"
                  && navigation.librarySelection.scrollID == "library-card-fixture"
                  && navigation.discoverSelection.genre == "Adventure"
                  && navigation.discoverSelection.scope == .installed
                  && navigation.discoverSelection.featuredID == "discover-hero"
                  && navigation.discoverSelection.scrollID == "discover-card-fixture",
                  "REQ-8: Warm tab navigation retains filter/sort/query/genre/search scope/hero/position without retaining hidden views")
            let position = LibrarySelection()
            position.scrollID = "library-card-fixture"
            position.collectionViewportFrame = CGRect(x: 0, y: 100, width: 1000, height: 700)
            position.collectionHeaderFrame = CGRect(x: 0, y: 300, width: 1000, height: 40)
            check(position.collectionTarget(remaining: []) == nil,
                  "Scope changes clear removed targets without commanding a header reveal")
            position.collectionHeaderFrame.origin.y = 850
            check(position.collectionTarget(remaining: []) == nil,
                  "Top viewport clears a removed card without revealing collection")
            check(position.collectionTarget(remaining: ["library-card-fixture"]) == "library-card-fixture",
                  "Surviving card target remains retained outside header viewport")
            position.collectionHeaderFrame.origin.y = 0
            check(position.collectionTarget(remaining: []) == nil,
                  "Removed offscreen cards never force another target position")
            position.collectionHeaderFrame = .zero
            check(position.collectionTarget(remaining: []) == nil,
                  "Unavailable geometry never invents header visibility")
            position.collectionHeaderFrame = CGRect(x: 0, y: 300, width: 1000, height: 40)
            position.collectionScrollFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)
            position.measureScroll(LibraryScrollMeasurement(offsetY: 789.5, contentHeight: 3729.5,
                containerHeight: 700, containerWidth: 1000, insetTop: 24, insetBottom: 12,
                visibleY: 789.5, visibleMaxY: 1489.5, visibleHeight: 700))
            position.prepareScopeExtent()
            check(position.actionExtent?.minimumHeight(viewport: CGSize(width: 1000, height: 700)) == 1477.5,
                  "Visible-controls extent retains only offset plus container minus native bottom inset")
            check(position.actionExtent?.minimumHeight(viewport: CGSize(width: 1000, height: 897)) == 1674.5,
                  "Height resize recalculates finite extent from current viewport, not old document height")
            check(position.actionExtent?.minimumHeight(viewport: CGSize(width: 900, height: 700)) == nil,
                  "Width reflow drops obsolete action extent")
            let underlappingExtent = LibraryActionExtent(offsetY: 727.5, insetBottom: 0, viewportWidth: 1619)
            check(underlappingExtent.minimumHeight(viewport: CGSize(width: 1619, height: 1231)) == 1958.5
                  && underlappingExtent.minimumHeight(viewport: CGSize(width: 1619, height: 1179)) == 1906.5,
                  "Underlapping scroll reserves the measured native container, not the shorter safe-area parent")
            func resizeMeasurement(width: CGFloat) -> LibraryScrollMeasurement {
                LibraryScrollMeasurement(offsetY: 599.5, contentHeight: 1830.5,
                    containerHeight: 1231, containerWidth: width, insetTop: 0, insetBottom: 0,
                    visibleY: 599.5, visibleMaxY: 1830.5, visibleHeight: 1231)
            }
            position.measureScroll(resizeMeasurement(width: 1619.0000000000002))
            position.prepareScopeExtent()
            position.measureScrollFrame(CGRect(x: 0, y: 0, width: 1619, height: 1231))
            position.measureScroll(resizeMeasurement(width: 1619))
            check(position.scopeMinimumHeight(viewport: CGSize(width: 1619, height: 1231)) == 1830.5,
                  "Observed 1619.0000000000002 to 1619 representation noise preserves exact required extent")
            position.measureScroll(resizeMeasurement(width: 1619.0000000000002))
            check(position.scopeMinimumHeight(viewport: CGSize(width: 1619.0000000000002, height: 897)) == 1496.5,
                  "Width representation noise in reverse preserves current-height semantics")
            position.measureScroll(resizeMeasurement(width: 1500))
            position.measureScroll(resizeMeasurement(width: 1619))
            check(position.scopeMinimumHeight(viewport: CGSize(width: 1619, height: 1231)) == nil,
                  "Real native width reflow permanently invalidates extent despite returning to old width")
            check(position.scopeMinimumHeight(viewport: CGSize(width: 1000, height: 700)) == nil,
                  "Returning to an earlier width cannot resurrect its obsolete scope extent")
            position.collectionHeaderFrame.origin.y = 850
            position.prepareScopeExtent()
            check(position.actionExtent == nil, "Hero/top scope action does not reserve stale grid extent")
            position.collectionHeaderFrame.origin.y = 300
            position.prepareScopeExtent()
            position.clearScopeExtent()
            check(position.actionExtent == nil, "See All explicitly releases the filter extent")
            position.prepareScopeExtent()
            position.measureScroll(LibraryScrollMeasurement(offsetY: -24, contentHeight: 1477.5,
                containerHeight: 700, containerWidth: 1000, insetTop: 24, insetBottom: 12,
                visibleY: 0, visibleMaxY: 700, visibleHeight: 700))
            position.finishedUserScroll()
            check(position.actionExtent == nil, "Deliberate user scroll to native top releases filter extent")
            position.prepareScopeExtent()
            check(position.actionExtent == nil, "Native top never reserves extra document extent")
            let filteredHistory = LibrarySelection()
            filteredHistory.scrollID = "library-card-filtered-out"
            filteredHistory.collectionViewportFrame = CGRect(x: 0, y: 100, width: 1000, height: 700)
            filteredHistory.collectionHeaderFrame = CGRect(x: 0, y: 300, width: 1000, height: 40)
            filteredHistory.measureScroll(LibraryScrollMeasurement(offsetY: 789.5, contentHeight: 3729.5,
                containerHeight: 700, containerWidth: 1000, insetTop: 24, insetBottom: 12,
                visibleY: 789.5, visibleMaxY: 1489.5, visibleHeight: 700))
            filteredHistory.beginScopeMeasurement(filter: .owned, target: nil)
            filteredHistory.prepareScopeExtent()
            check(filteredHistory.collectionTarget(remaining: []) == nil
                  && filteredHistory.actionExtent?.minimumHeight(viewport: CGSize(width: 1000, height: 700)) == 1477.5
                  && filteredHistory.actionExtent?.minimumHeight(viewport: CGSize(width: 1000, height: 897)) == 1674.5,
                  "REQ-4: Filtering away the scrolled-to title clears its target but reserves the measured history at current height")
            filteredHistory.measureScroll(resizeMeasurement(width: 1500))
            check(filteredHistory.scopeMinimumHeight(viewport: CGSize(width: 1500, height: 897)) == nil,
                  "REQ-4: A real width reflow retires the filtered-history reservation")
            let playbackArguments = (true, true, false, false, true, true, true)
            check(HeroMotionPolicy.permitsPlayback(allowed: playbackArguments.0, enabled: playbackArguments.1,
                    reduceMotion: playbackArguments.2, lowPower: playbackArguments.3,
                    active: playbackArguments.4, visible: playbackArguments.5, hasTrailer: playbackArguments.6),
                  "Visible active hero can stream muted artwork")
            for fence in 0..<8 {
                check(!HeroMotionPolicy.permitsPlayback(allowed: fence != 0, enabled: fence != 1,
                        reduceMotion: fence == 2, lowPower: fence == 3,
                        active: fence != 4, visible: fence != 5, hasTrailer: fence != 6,
                        supportsViewportVisibility: fence != 7),
                      "Hero playback respects lifecycle fence \(fence)")
            }
            try LibraryAccessChecks.run(check: check)
            try PresentationPerformanceChecks.correctness(check: check)
            try await PublicDescriptorChecks.run(check: check)
            try await OdeRuntimeChecks.run(check: check)
            if libraryAccessOnly {
                try await SearchPerformanceChecks.queryCache(configuration: configuration, check: check)
                do {
                    let config = configuration("queryforzareal")
                    try FileManager.default.createDirectory(at: config.stateDirectory, withIntermediateDirectories: true)
                    let consumer = LiveSession(configuration: config)
                    await consumer.connect()
                    consumer.market = "RO"
                    consumer.language = "en-US"
                    await consumer.refreshCatalog("Forza")
                    let baseIDs = Set(consumer.products.map(\.id))
                    check(baseIDs.count == 7 && consumer.discoveryFailures.count == 16
                          && !consumer.catalogHasQueryWarning,
                          "REQ100 captured Forza first page retains seven PC games without warnings for rejected non-PC candidates")
                    let selection = DiscoverSelection()
                    await selection.loadMoreSearch(session: consumer, query: "Forza") {
                        Set(consumer.products.map(\.id)).intersection(baseIDs)
                    }
                    check(consumer.products.count == 15 && consumer.discoveryFailures.count == 57
                          && consumer.catalogError == nil && consumer.nextCursor != nil,
                          "REQ100 captured Forza DLC-only pages and failed-page details advance exactly four bounded requests (products \(consumer.products.count), failures \(consumer.discoveryFailures.count), error \(consumer.catalogError ?? "none"))")
                    check(selection.continuationNotice(session: consumer, query: "Forza")
                          == "No additional games found in the next four result pages." && !selection.pagingSearch,
                          "REQ100 no-new-visible-games bound replaces the no-op More control without falsely claiming source exhaustion")
                    check(selection.canSearchFurther(session: consumer, query: "Forza"),
                          "REQ100 retained cursor offers explicit Search further after the bounded no-match pass")
                    selection.scope = .installed
                    check(selection.continuationNotice(session: consumer, query: "Forza") == nil,
                          "REQ100 bounded continuation stop belongs only to its active search scope")
                    selection.scope = .allGames
                    await consumer.refreshCatalog("Forza", more: true)
                    check(consumer.products.count == 15 && consumer.discoveryFailures.count == 73
                          && consumer.catalogError == nil && consumer.nextCursor != nil
                          && selection.continuationNotice(session: consumer, query: "Forza") == nil,
                          "REQ100 captured sixth all-rejected page still preserves its advanced details cursor")
                    await selection.loadMoreSearch(session: consumer, query: "Forza") {
                        Set(consumer.products.map(\.id)).intersection(baseIDs)
                    }
                    check(consumer.nextCursor == nil
                          && selection.continuationNotice(session: consumer, query: "Forza") == "No more games in this search scope."
                          && !selection.canSearchFurther(session: consumer, query: "Forza"),
                          "REQ100 only actual source exhaustion removes the explicit continuation action")
                    check(await consumer.disconnect(), "REQ100 real-order fixture closes its synthetic backend")
                    try cleanLifecycle(config)
                    let progressConfig = configuration("queryforzareal")
                    try FileManager.default.createDirectory(at: progressConfig.stateDirectory, withIntermediateDirectories: true)
                    let progress = LiveSession(configuration: progressConfig)
                    await progress.connect()
                    progress.market = "RO"
                    progress.language = "en-US"
                    await progress.refreshCatalog("Forza")
                    let progressSelection = DiscoverSelection()
                    await progressSelection.loadMoreSearch(session: progress, query: "Forza") {
                        Set(progress.products.map(\.id))
                    }
                    check(progress.products.count == 9 && progress.discoveryFailures.count == 24
                          && progressSelection.continuationNotice(session: progress, query: "Forza") == nil,
                          "REQ100 paging stops after one page when that active scope gains real results")
                    if let alreadyOwned = progress.products.last {
                        let key = CatalogProjectionKey(accountHash: progress.accountHash, query: "Forza",
                            owned: [PCGame(id: alreadyOwned.id, title: alreadyOwned.title, artwork: nil)],
                            products: progress.products, gamePass: [], gamePassIDs: [],
                            installed: [], accessIsCurrent: false, metadataRevision: 0,
                            compatibility: [:], genre: nil, showsUnsupported: false)
                        let facts = Dictionary(uniqueKeysWithValues: progress.products.map {
                            ($0.id, LibraryCatalogFacts(genres: [], isBaseGame: true))
                        })
                        let current = CatalogProjection(key: key, facts: facts, isVisible: { _ in true })
                        check(current.visible.count == 8 && !current.visible.contains { $0.id == alreadyOwned.id },
                              "REQ100 exact paging projection does not count an already-visible Library identity as a new public game")
                        var incompleteFacts = facts
                        incompleteFacts.removeValue(forKey: progress.products[0].id)
                        let incomplete = CatalogProjection(key: key, facts: incompleteFacts, isVisible: { _ in true })
                        check(incomplete.unresolvedClassificationCount == 1 && incomplete.visible.count == 7,
                              "REQ100 one missing descriptor leaves other classified games visible")
                    }
                    let beforeMissingDetails = progress.catalogRequestVersion
                    await progressSelection.loadMoreSearch(session: progress, query: "Forza") { nil }
                    check(progress.catalogRequestVersion == beforeMissingDetails + 4
                          && progressSelection.continuationNotice(session: progress, query: "Forza")
                            == "No additional games found in the next four result pages."
                          && progress.nextCursor != nil
                          && progressSelection.canSearchFurther(session: progress, query: "Forza"),
                          "REQ100 unavailable classification still advances four bounded pages and keeps Search further reachable")
                    await progressSelection.loadMoreSearch(session: progress, query: "Forza") { nil }
                    check(progress.nextCursor == nil && !progressSelection.canSearchFurther(session: progress, query: "Forza"),
                          "REQ100 Search further after unavailable classification reaches actual source exhaustion")
                    check(await progress.disconnect(), "REQ100 progress fixture closes its synthetic backend")
                    try cleanLifecycle(progressConfig)
                    let scopeConfig = configuration("queryforzareal")
                    try FileManager.default.createDirectory(at: scopeConfig.stateDirectory, withIntermediateDirectories: true)
                    let scoped = LiveSession(configuration: scopeConfig)
                    await scoped.connect()
                    scoped.market = "RO"
                    scoped.language = "en-US"
                    await scoped.refreshCatalog("Forza")
                    let scopedSelection = DiscoverSelection()
                    let version = scoped.catalogRequestVersion
                    await scopedSelection.loadMoreSearch(session: scoped, query: "Forza") {
                        scoped.market = "GB"
                        return []
                    }
                    check(scoped.catalogRequestVersion == version + 1 && !scopedSelection.pagingSearch
                          && scopedSelection.continuationNotice(session: scoped, query: "Forza") == nil,
                          "REQ100 scope withdrawal during metadata loading cannot request or publish stale continuation")
                    check(await scoped.disconnect(), "REQ100 scope fixture closes its synthetic backend")
                    try cleanLifecycle(scopeConfig)
                }
                for scenario in ["querybudget", "querysourceretry", "querysourcewarning", "querysourcefailed"] {
                    let config = configuration(scenario)
                    try FileManager.default.createDirectory(at: config.stateDirectory, withIntermediateDirectories: true)
                    let consumer = LiveSession(configuration: config)
                    await consumer.connect()
                    await consumer.refreshCatalog("Forza")
                    if scenario == "querybudget" {
                        check(!consumer.catalogHasQueryWarning && !consumer.catalogCanRetryQueryWarning,
                              "REQ100 expected non-PC candidate rejections do not produce a generic search warning or Retry")
                        check(consumer.discoveryFailures.count == 16 && consumer.nextCursor == "q1-aa"
                              && consumer.canLoadMoreCatalog && consumer.catalogError == nil && consumer.products.isEmpty,
                              "REQ100 16 rejected candidates preserve real More continuation, not global search unavailable")
                        await consumer.refreshCatalog("Forza", more: true)
                        check(consumer.products.count == 1 && consumer.nextCursor == nil
                              && consumer.discoveryFailures.count == 16 && consumer.catalogError == nil,
                              "REQ100 More resumes exact cursor and appends useful PC results without restarting")
                    } else {
                        check(consumer.catalogHasQueryWarning
                              && consumer.catalogCanRetryQueryWarning == (scenario == "querysourceretry"),
                              "REQ100 source degradation is disclosed with Retry only when the source is retryable")
                        check(consumer.catalogSourceFailure?.code == (scenario == "querysourceretry" ? .networkUnavailable : .packageUnavailable)
                              && consumer.catalogEmptyTitle != "No Store matches"
                              && (scenario != "querysourcefailed"
                                  ? consumer.products.count == 1 && consumer.catalogError == nil
                                  : consumer.products.isEmpty && consumer.discoveryFailures.count == 1),
                              "REQ100 optional source warning survives actual \(scenario) decode and consumer presentation")
                        if scenario == "querysourcewarning" {
                            await consumer.refreshCatalog("Halo")
                            check(consumer.catalogSourceFailure == nil && consumer.products.count == 1,
                                  "REQ100 a new complete query retires the earlier source warning")
                            check(!consumer.catalogHasQueryWarning,
                                  "REQ100 normal partial public search has no default warning")
                            let stopped = Task { await consumer.refreshCatalog("Halo") }
                            for _ in 0..<1_000 where !consumer.searching { await Task.yield() }
                            check(consumer.searching, "REQ100 stopped-query fixture reached its owned read")
                            consumer.stopCatalogSearch()
                            await stopped.value
                            await consumer.refreshCatalog("Halo")
                            check(consumer.gamePassCatalogError != nil && !consumer.catalogHasQueryWarning,
                                  "REQ100 stale browse-catalog failure cannot brand a normal query as partial failure")
                            await consumer.refreshCatalog("Forza")
                            check(consumer.catalogSourceFailure != nil, "REQ100 source warning binds to its new query")
                        }
                        consumer.market = "GB"
                        check(consumer.catalogSourceFailure == nil,
                              "REQ100 source warning retires with its query scope")
                    }
                    check(await consumer.disconnect(), "REQ100 synthetic query consumer closes owned backend")
                    check(consumer.catalogSourceFailure == nil, "REQ100 disconnected account retains no query source warning")
                    try cleanLifecycle(config)
                }
                try await CatalogDetailLoadingChecks.run(check: check)
                try await InstalledProductAccessChecks.run(check: check)
                try await PCGamesChecks.run(check: check)
                print("\(count) Library access checks, \(failures) failures. Synthetic data only.")
                return failures == 0
            }
            if statsOnly {
                do { try await LibraryStatsChecks.run(check: check) }
                catch { check(false, "Stats fixture failed: \(error.localizedDescription)") }
                print("\(count) Xbox stats checks, \(failures) failures. Synthetic scripts only.")
                return failures == 0
            }
            if mediaOnly {
                do { try await CatalogMediaChecks.run(check: check) }
                catch {
                    check(false, "Public-media fixture failed: \(error.localizedDescription)")
                }
                let source = ProcessInfo.processInfo.environment["XODUS_DESCRIPTOR_CHECK_CLI"] == nil
                    ? "Synthetic transport only." : "Synthetic fixtures plus neutral source CLI envelope; no account operations."
                print("\(count) public-media checks, \(failures) failures. \(source)")
                return failures == 0
            }
            if gameOperationsOnly {
                try await ApplicationTerminationChecks.run(check: check)
                try await NativeLifecycleChecks.run(check: check)
                try await EngineManagementChecks.run(check: check)
                try await GameOperationChecks.run(check: check)
                print("\(count) game operation checks, \(failures) failures. Synthetic scripts only.")
                return failures == 0
            }
            try await InstalledGameChecks.run(check: check)
            try await NativeLifecycleChecks.run(check: check)
            try await CatalogDetailLoadingChecks.run(check: check)
            try await InstalledProductAccessChecks.run(check: check)
            try await PCGamesChecks.run(check: check)
            try await GameOperationChecks.run(check: check)
            try await DownloadQueueChecks.run(check: check)
            try await InstalledGameUpdateChecks.run(check: check)
            func observationFailure(_ message: String, code: String = "AUTH_INVALID",
                                    reason: String = "pipelineFailed") throws -> WireFailure {
                let value = JSONValue.object([
                    "code": .string(code), "message": .string(message), "retryable": .bool(false),
                    "details": .object(["category": .string("nativeConsentFailure"),
                                       "stage": .string("nativeSignIn"), "reason": .string(reason)])
                ])
                return try JSONDecoder().decode(WireFailure.self, from: JSONEncoder().encode(value))
            }
            for reason in ["helper.invalidFrame", "helper.invalidNavigation", "helper.navigationFailed",
                           "helper.popupUnsupported", "helper.contentTerminated", "helper.javaScriptFailed",
                           "helper.bridgeInvalid", "helper.deadlineExpired", "helper.parentUnavailable",
                           "channelEOF", "unclassified", "tokenExchangeFailed", "helperCompletionFailed",
                           "tokenExchange.requestBuild", "tokenExchange.requestSerialization",
                           "tokenExchange.requestTransport", "tokenExchange.requestTimeout",
                           "tokenExchange.httpClientError", "tokenExchange.httpServerError",
                           "tokenExchange.httpStatusRejected", "tokenExchange.responseParsing",
                           "tokenExchange.responseSignature", "tokenExchange.responseCryptography",
                           "tokenExchange.responseEncoding", "tokenExchange.continuationRequired",
                           "tokenExchange.faultWithoutContinuation", "tokenExchange.continuationRejected",
                           "exchangeRetentionFailed"] {
                let message = "Native sign-in failed: \(reason)."
                check(try LiveSession.validatedNativeSignInObservation(observationFailure(message)) == message,
                      "Exact approved \(reason) observation is available under Account Details")
                let snapshot = try LiveSession.SignInFailureSnapshot(observationFailure(message))
                check(snapshot.code == .invalid && snapshot.diagnostic == .pipelineFailed
                      && snapshot.observation == message,
                      "Latest-failure snapshot keeps only the closed \(reason) diagnostic")
            }
            for message in ["Native sign-in failed: helper.unknown.", "Native sign-in failed: channelEOF. secret",
                            " Native sign-in failed: helper.bridgeInvalid.", "Native sign-in failed: channelEOF.\n",
                            "secret raw provider text", "Native sign-in failed: helper.navigationFailed",
                            "Native sign-in failed: helper.navigationFailed. https://provider.invalid/?token=secret",
                            "Native sign-in failed: helper.tokenExchangeFailed.",
                            "Native sign-in failed: tokenExchangeFailed. extra",
                            "Native sign-in failed: helperCompletionFailed.\n",
                            "Native sign-in failed: helperCompletionFailed",
                            "Native sign-in failed: tokenExchange.unknown.",
                            "Native sign-in failed: tokenExchange.requestTransport. extra",
                            "Native sign-in failed: tokenExchange.requestTimeout.\n",
                            "Native sign-in failed: tokenExchange.responseParsing. https://provider.invalid/",
                            "Native sign-in failed: exchangeRetentionFailed. extra",
                            "Native sign-in failed: exchangeRetentionFailed"] {
                check(try LiveSession.validatedNativeSignInObservation(observationFailure(message)) == nil,
                      "Unapproved or extended engine wording never enters the displayed native observation")
            }
            check(try LiveSession.validatedNativeSignInObservation(
                observationFailure("Native sign-in failed: helper.bridgeInvalid.", code: "INTERNAL")) == nil
                  && LiveSession.validatedNativeSignInObservation(
                    observationFailure("Native sign-in failed: helper.bridgeInvalid.", reason: "unexpected")) == nil,
                  "An exact observation is rejected without the agreed AUTH_INVALID/nativeSignIn/pipelineFailed tuple")
            let unknownSnapshot = try LiveSession.SignInFailureSnapshot(
                observationFailure("Secret-shaped upstream token=value", code: "UNKNOWN_token=value", reason: "unexpected"))
            let unknownRequest = LiveSession.SignInFailureSnapshot(
                requestError: ManagementError.backendError("UNKNOWN_token=value", retryable: false))
            check(unknownSnapshot.code == nil && unknownSnapshot.diagnostic == nil && unknownSnapshot.observation == nil
                  && unknownRequest.code == nil && unknownRequest.diagnostic == nil && unknownRequest.observation == nil,
                  "Unclassified helper/exchange/commit errors retain no raw code, details or secret-shaped message")
            for reason in ["tokenExchangeFailed", "helperCompletionFailed",
                           "tokenExchange.requestBuild", "tokenExchange.requestSerialization",
                           "tokenExchange.requestTransport", "tokenExchange.requestTimeout",
                           "tokenExchange.httpClientError", "tokenExchange.httpServerError",
                           "tokenExchange.httpStatusRejected", "tokenExchange.responseParsing",
                           "tokenExchange.responseSignature", "tokenExchange.responseCryptography",
                           "tokenExchange.responseEncoding", "tokenExchange.continuationRequired",
                           "tokenExchange.faultWithoutContinuation", "tokenExchange.continuationRejected",
                           "exchangeRetentionFailed"] {
                let message = "Native sign-in failed: \(reason)."
                check(try LiveSession.validatedNativeSignInObservation(
                    observationFailure(message, code: "INTERNAL")) == nil
                      && LiveSession.validatedNativeSignInObservation(
                        observationFailure(message, reason: "unexpected")) == nil,
                      "Exact \(reason) boundary wording requires the unchanged approved failure tuple")
            }
            try await CrossOverDependencyChecks.run(check: check)
            try await EngineManagementChecks.run(check: check)
            try await ApplicationTerminationChecks.run(check: check)
            try await RecentLibraryChecks.run(check: check)
            try await CatalogMediaChecks.run(check: check)
            try await LibraryStatsChecks.run(check: check)
            let boundAccount = String(repeating: "a", count: 64)
            let otherAccount = String(repeating: "b", count: 64)
            let boundService = GameServiceStatus(serviceRunning: true, signedIn: true, accountHash: boundAccount)
            check(XboxAccountBinding.matching(application: boundAccount, library: boundAccount,
                  service: boundService) == boundAccount,
                  "Matching application, library and service identities admit profile bootstrap without an existing profile")
            check(XboxAccountBinding.matching(application: boundAccount, library: otherAccount,
                  service: boundService) == nil
                  && XboxAccountBinding.matching(application: nil, library: boundAccount, service: boundService) == nil
                  && XboxAccountBinding.matching(application: boundAccount, library: nil, service: boundService) == nil
                  && XboxAccountBinding.matching(application: boundAccount, library: boundAccount, service: nil) == nil
                  && XboxAccountBinding.matching(application: boundAccount, library: boundAccount,
                    service: GameServiceStatus(serviceRunning: true, signedIn: true, accountHash: otherAccount)) == nil
                  && XboxAccountBinding.matching(application: boundAccount, library: boundAccount,
                    service: GameServiceStatus(serviceRunning: false, signedIn: false, accountHash: nil)) == nil,
                  "Missing, signed-out or mismatched identities cannot bootstrap another Xbox profile")
            let expired = session("expired")
            await expired.connect()
            check(expired.isReady && !expired.canSignIn, "Unchecked account cannot blindly retry a mutation")
            check(!expired.hasConfirmedSignIn && !expired.nativeSignInHostAdmitted
                  && !expired.canStartWelcomeSignIn,
                  "HELLO alone cannot unlock welcome or enable sign-in without an admitted helper")
            check(expired.authentication == nil && !expired.accountStatusCurrent
                  && expired.currentCredentialState == nil && expired.accountSymbol == "person.crop.circle"
                  && expired.accountLabel == "Account status not checked"
                  && expired.accountLibraryTitle == expired.accountLabel
                  && expired.accountExplanation.contains("engine is connected")
                  && expired.accountExplanation.contains("has not been checked"),
                  "HELLO and advertised auth support display connected-but-unchecked, never saved account evidence")
            check(expired.accountJourneyTitle == "Sign-in hasn't been checked"
                  && expired.accountJourneyMessage.contains("Sign in with Microsoft"),
                  "Unchecked account copy names the next action without presenting saved sign-in")
            await expired.refreshAccount()
            check(!expired.hasConfirmedSignIn, "Expired credentials keep games behind welcome")
            check(expired.authentication?.state == .expired && expired.needsAccountDisconnect
                  && expired.canDisconnectAccount && !expired.canSignIn,
                  "Expired profile exposes confirmed disconnect recovery, not rejected sign-in")
            check(expired.accountJourneyTitle == "Sign-in needs reconnecting"
                  && expired.accountJourneyMessage == "Your saved Xbox Live sign-in needs to be refreshed. Choose Sign in with Microsoft.",
                  "Expired account copy explains the existing sign-out then sign-in recovery in plain language")
            await expired.signOut()
            check(!expired.hasConfirmedSignIn && !expired.canStartWelcomeSignIn,
                  "Signed-out status and advertised capabilities cannot bypass missing helper admission")
            check(expired.authentication?.state == .signedOut && expired.canSignIn,
                  "Confirmed launcher logout establishes signed-out state before sign-in")
            await expired.beginSignIn()
            check(!expired.hasConfirmedSignIn, "A pending sign-in cannot dismiss welcome")
            try await wait { expired.authentication?.flow?.state == .completed }
            check(expired.hasConfirmedSignIn, "Only confirmed completion unlocks the existing game surfaces")
            check(expired.authentication?.state == .credentialPresent && !expired.signInPending,
                  "Expired-profile recovery completes through actual mocked native session requests")
            check(expired.currentCredentialState == .credentialPresent
                  && expired.accountLabel == "Microsoft sign-in saved"
                  && expired.accountSymbol == "person.crop.circle.fill"
                  && expired.accountExplanation.contains("not proof of PC ownership")
                  && expired.accountLibraryTitle == "PC library access is not available yet",
                  "Fresh saved sign-in displays only credential evidence, not an owned or playable library")
            await expired.disconnect()
            check(!expired.hasConfirmedSignIn, "Disconnect immediately hides retained game surfaces")

            let savedBase = configuration("savedpermission")
            let neutralHelper = savedBase.stateDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent("neutral-helper")
            try FileManager.default.createDirectory(at: neutralHelper.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let helperBytes = Data("#!/bin/sh\nexit 90\n".utf8)
            try helperBytes.write(to: neutralHelper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: neutralHelper.path)
            let neutralBinding = NativeAuthHostBinding(executable: neutralHelper,
                sha256: SHA256.hash(data: helperBytes).map { String(format: "%02x", $0) }.joined())
            let unpairedMessage = "Sign-in is unavailable in this copy of X Ode. A matching app and sign-in service are required."
            let serviceMessage = "X Ode couldn't connect to its sign-in service. Choose Sign in with Microsoft to reconnect."
            let retryBase = configuration("welcomeretry")
            let retryConfiguration = BackendConfiguration(executable: retryBase.executable,
                stateDirectory: retryBase.stateDirectory, nativeAuthHost: neutralBinding)
            let retryWelcome = LiveSession(configuration: retryConfiguration)
            await retryWelcome.prepareWelcome()
            check(retryWelcome.phase == .failed && retryWelcome.welcomeMessage == serviceMessage
                  && retryWelcome.welcomeNotice == serviceMessage
                  && retryWelcome.errorMessage == ManagementError.invalidFrame.localizedDescription
                  && !retryWelcome.hasConfirmedSignIn && !retryWelcome.nativeSignInHostAdmitted
                  && !retryWelcome.canStartWelcomeSignIn,
                  "Admitted-helper hello failure offers service retry, not missing-pair advice or unlocked sign-in")
            await retryWelcome.prepareWelcome()
            check(retryWelcome.isReady && retryWelcome.nativeSignInHostAdmitted
                  && retryWelcome.accountStatusCurrent && retryWelcome.welcomeMessage != serviceMessage,
                  "The same admitted pair retries through real hello/status and clears the stale connection guidance")
            await retryWelcome.disconnect()
            check(retryWelcome.welcomeMessage == unpairedMessage && !retryWelcome.canStartWelcomeSignIn,
                  "Disconnect clears historical admission failure evidence without enabling sign-in")
            try cleanLifecycle(retryConfiguration)

            let invalidEngine = neutralHelper.deletingLastPathComponent().appendingPathComponent("invalid-engine")
            try Data("#!/nonexistent/xodus-neutral-interpreter\nexit 90\n".utf8).write(to: invalidEngine)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: invalidEngine.path)
            let startupFailure = LiveSession(configuration: BackendConfiguration(
                executable: invalidEngine, stateDirectory: retryBase.stateDirectory, nativeAuthHost: neutralBinding))
            await startupFailure.prepareWelcome()
            check(startupFailure.phase == .failed && startupFailure.welcomeMessage == serviceMessage
                  && startupFailure.errorMessage == ManagementError.startFailed.localizedDescription
                  && !startupFailure.hasConfirmedSignIn && !startupFailure.canStartWelcomeSignIn,
                  "Validated-helper process-start failure uses retry guidance while readiness remains locked")
            await startupFailure.disconnect()

            let invalidBinding = NativeAuthHostBinding(executable: neutralHelper, sha256: String(repeating: "0", count: 64))
            let rejectedPair = LiveSession(configuration: BackendConfiguration(executable: retryBase.executable,
                stateDirectory: retryBase.stateDirectory, nativeAuthHost: invalidBinding))
            await rejectedPair.prepareWelcome()
            check(rejectedPair.phase == .failed && rejectedPair.welcomeMessage == unpairedMessage
                  && rejectedPair.errorMessage == ManagementError.nativeAuthHostUnavailable.localizedDescription
                  && !rejectedPair.nativeSignInHostAdmitted && !rejectedPair.canStartWelcomeSignIn
                  && !FileManager.default.fileExists(atPath: retryBase.stateDirectory.path),
                  "Invalid helper hash keeps missing-pair guidance and cannot start a backend or sign-in")
            await rejectedPair.disconnect()

            let savedConfiguration = BackendConfiguration(
                executable: savedBase.executable, stateDirectory: savedBase.stateDirectory,
                nativeAuthHost: NativeAuthHostBinding(executable: neutralHelper,
                    sha256: SHA256.hash(data: helperBytes).map { String(format: "%02x", $0) }.joined()))
            let saved = LiveSession(configuration: savedConfiguration)
            await saved.prepareWelcome()
            check(saved.hasConfirmedSignIn && saved.nativeSignInHostAdmitted,
                  "Welcome preparation restores only confirmed saved status through the admitted neutral pair")
            check(saved.accountJourneyTitle == "Signed in with Xbox Live"
                  && saved.accountJourneyMessage == "Your Xbox Live sign-in is saved.",
                  "Login shows only saved identity, without download or gameplay claims")
            check(saved.currentCredentialState == .credentialPresent
                  && saved.accountSymbol == "person.crop.circle.fill" && saved.canDisconnectAccount,
                  "Neutral saved profile initially displays the current credential result")
            await saved.revalidateAccountOnForeground()
            check(!saved.hasConfirmedSignIn && !saved.canStartWelcomeSignIn,
                  "F5: Failed foreground status locks retained cached data instead of trusting a saved snapshot")
            check(saved.isReady && saved.authentication?.state == .credentialPresent
                  && !saved.accountStatusCurrent && saved.currentCredentialState == nil
                  && saved.accountLabel == "Account status needs checking"
                  && saved.accountSymbol == "person.crop.circle"
                  && saved.accountLibraryTitle == saved.accountLabel
                  && !saved.accountLibraryExplanation.contains("sign-in is saved")
                  && saved.accountExplanation.contains("earlier result is not current")
                  && !saved.canSignIn && !saved.canDisconnectAccount,
                  "Failed status read retains the safe snapshot but removes saved-account claims across all live surfaces")
            check(saved.accountStatusError == .credentialStoreUnavailable
                  && saved.accountMessage.contains("cannot access Keychain")
                  && saved.accountMessage.contains("Sign-in stays disabled")
                  && saved.accountError == ManagementError.credentialStoreUnavailable.localizedDescription,
                  "Blocked Keychain status has a typed cause and visible recovery, not an unexplained gray sign-in")
            await saved.refreshAccount()
            check(saved.hasConfirmedSignIn, "A successful status retry restores access without fabricated ownership")
            check(saved.accountStatusCurrent && saved.currentCredentialState == .credentialPresent
                  && saved.accountLabel == "Microsoft sign-in saved" && saved.canDisconnectAccount
                  && saved.authentication?.entitlementAuthorized == false,
                  "Fresh status restores credential display without promoting PC access")
            check(saved.accountStatusError == nil,
                  "A successful fresh status clears the earlier typed Keychain-access failure")
            check(try trace(savedConfiguration).filter { $0.hasPrefix("auth.") } ==
                  ["auth.status", "auth.status", "auth.status"],
                  "Account display recovery performs only neutral requested status reads, no sign-in or logout mutation")
            try await PCGamesChecks.checkAppSignOut(session: saved, check: check)
            check(!saved.hasConfirmedSignIn && saved.canStartWelcomeSignIn,
                  "Explicit sign-out returns to welcome and admits a new sign-in only with the bound helper")
            await saved.beginSignIn()
            check(saved.accountJourneyTitle == "Finish signing in"
                  && saved.accountJourneyMessage == "Continue in the Microsoft window, or choose Cancel sign-in.",
                  "Pending account copy directs the user to the real Microsoft window and cancellation")
            check(!saved.hasConfirmedSignIn && !saved.canStartWelcomeSignIn,
                  "Welcome sign-in immediately fences duplicate activation and keeps games hidden")
            try await wait { saved.authentication?.flow?.state == .completed }
            check(saved.hasConfirmedSignIn && saved.authentication?.entitlementAuthorized == false,
                  "Welcome completion unlocks navigation without claiming game entitlement")
            check(await saved.disconnect(), "Account presentation regression retires its owned neutral child")
            check(saved.currentCredentialState == nil && saved.accountSymbol == "person.crop.circle"
                  && saved.accountLabel == "Connect X Ode" && saved.accountStatusError == nil,
                  "Disconnect removes current account presentation evidence")
            let mixedBase = configuration("recentbootstrapsignedout")
            let mixedConfiguration = BackendConfiguration(executable: mixedBase.executable,
                stateDirectory: mixedBase.stateDirectory, nativeAuthHost: neutralBinding)
            let mixed = LiveSession(configuration: mixedConfiguration)
            await mixed.connect()
            check(!mixed.canDisconnectAccount,
                  "Mixed-state cleanup remains disabled until launcher status is current")
            await mixed.refreshAccount()
            try await PCGamesChecks.checkAppSignOut(session: mixed, launcherAlreadySignedOut: true, check: check)
            let mixedAuthTrace = try trace(mixedConfiguration).filter { $0.hasPrefix("auth.") }
            check(!mixedAuthTrace.isEmpty && mixedAuthTrace.allSatisfy { $0 == "auth.status" },
                  "Mixed-state cleanup uses confirmed signed-out launcher status without auth.begin or redundant auth.logout")
            check(await mixed.disconnect(), "Mixed-state cleanup retires only its synthetic management child")
            check(!mixed.canDisconnectAccount, "Disconnected launcher cannot admit further mixed-state cleanup")
            try cleanLifecycle(mixedConfiguration)
            try cleanLifecycle(savedConfiguration)

            let permissionConfiguration = configuration("statuspermission")
            let permission = LiveSession(configuration: permissionConfiguration)
            await permission.connect()
            let readingPermission = Task { await permission.revalidateAccountOnForeground() }
            try await wait { permission.accountStatusChecking }
            check(permission.accountBusy && !permission.accountStatusCurrent
                  && !permission.canSignIn && !permission.canDisconnectAccount
                  && permission.accountNoticeTitle == "Checking saved sign-in"
                  && permission.accountMessage.contains("macOS asks for Keychain access"),
                  "Foreground Keychain check shows native permission guidance and fences account actions")
            await permission.refreshAccount()
            await permission.revalidateAccountOnForeground()
            await permission.beginSignIn()
            await permission.signOut()
            await readingPermission.value
            check(try trace(permissionConfiguration).filter { $0.hasPrefix("auth.") } == ["auth.status"],
                  "F5: Concurrent foreground/status checks and gated mutations issue only one status request")
            check(permission.currentCredentialState == .credentialPresent && !permission.accountBusy
                  && !permission.accountStatusChecking && permission.accountStatusCurrent,
                  "Actual status alone restores saved-state presentation after the bounded permission wait")
            let retiringRead = Task { await permission.revalidateAccountOnForeground() }
            try await wait { permission.accountStatusChecking }
            check(permission.hasConfirmedSignIn,
                  "F5: Foreground revalidation preserves confirmed UI only while its bounded read is in flight")
            await permission.revalidateAccountOnForeground()
            await permission.disconnect()
            await retiringRead.value
            check(permission.authentication == nil && !permission.accountStatusCurrent
                  && !permission.accountBusy && !permission.accountStatusChecking,
                  "A retired generation's status completion cannot restore credentials or checking state")
            try cleanLifecycle(permissionConfiguration)

            let foregroundConfiguration = configuration("foregroundexpired")
            let foreground = LiveSession(configuration: foregroundConfiguration)
            await foreground.revalidateAccountOnForeground()
            check(foreground.phase == .disconnected && !foreground.accountBusy,
                  "F5: Foreground revalidation cannot connect an unpaired or disconnected session")
            await foreground.connect()
            await foreground.revalidateAccountOnForeground()
            check(foreground.hasConfirmedSignIn, "F5: Fresh foreground credential status can confirm the account")
            await foreground.revalidateAccountOnForeground()
            check(!foreground.hasConfirmedSignIn && foreground.currentCredentialState == .expired
                  && foreground.accountStatusCurrent,
                  "F5: A confirmed account that expires on foreground relocks without treating expiry as a read failure")
            check(try trace(foregroundConfiguration).filter { $0.hasPrefix("auth.") } ==
                  ["auth.status", "auth.status"],
                  "F5: Foreground checks use only bounded management status, never PC/game sign-in")
            await foreground.disconnect()
            try cleanLifecycle(foregroundConfiguration)

            let denied = session("expiredpermission")
            await denied.connect()
            await denied.refreshAccount()
            check(denied.currentCredentialState == .expired
                  && denied.accountExplanation.hasPrefix("Disconnect this saved launcher sign-in first"),
                  "Only a current expired result displays saved-profile recovery advice")
            await denied.refreshAccount()
            check(denied.authentication?.state == .expired && !denied.canDisconnectAccount,
                  "An inaccessible-store error disables disconnect of an earlier expired snapshot")
            check(denied.currentCredentialState == nil
                  && denied.accountLabel == "Account status needs checking"
                  && !denied.accountExplanation.contains("Disconnect this saved")
                  && denied.accountLibraryTitle == denied.accountLabel,
                  "Unconfirmed expired snapshot does not display current expiry or recommend credential removal")
            await denied.signOut()
            await denied.refreshAccount()
            check(denied.authentication?.state == .expired,
                  "Unavailable-store recovery preserves the existing profile without a deletion request")
            await denied.disconnect()

            let uncertain = session("beginfail")
            await uncertain.connect()
            await uncertain.refreshAccount()
            await uncertain.beginSignIn()
            check(!uncertain.accountStatusCurrent && !uncertain.canSignIn,
                  "Failed sign-in preparation invalidates pre-mutation status before another attempt")
            check(uncertain.accountLabel == "Account status needs checking"
                  && uncertain.currentCredentialState == nil,
                  "Failed sign-in preparation does not leave a current signed-out display")
            let preparationSummary = uncertain.errorMessage ?? ""
            check(preparationSummary.hasPrefix("Microsoft sign-in could not start.")
                  && preparationSummary.contains("Check account status")
                  && !preparationSummary.contains("AUTH_INVALID") && !preparationSummary.contains("stageUnavailable")
                  && !preparationSummary.contains("disconnect") && !preparationSummary.contains("saved sign-in")
                  && !preparationSummary.contains("Original preparation upstream sentinel"),
                  "Request-level sign-in failure never implies invalid saved credentials or deletion advice")
            let preparationFailure = uncertain.lastSignInFailure
            check(preparationFailure?.code == .invalid && preparationFailure?.diagnostic == nil
                  && preparationFailure?.observation == nil
                  && uncertain.accountFailureDetails?.contains("AUTH_INVALID") == true
                  && uncertain.accountFailureDetails?.contains("Stage: Not reported") == true,
                  "A terminal request error latches only its closed code and an unavailable stage")
            await uncertain.refreshAccount()
            check(uncertain.accountStatusCurrent && uncertain.canSignIn,
                  "A fresh status read is required to recover from failed sign-in preparation")
            await uncertain.disconnect()
            check(uncertain.lastSignInFailure == preparationFailure,
                  "Terminal request diagnostics survive no-flow status and client retirement")

            for scenario in ["failedflow", "failedflownocode"] {
                let failed = session(scenario)
                await failed.connect()
                await failed.refreshAccount()
                await failed.beginSignIn()
                let summary = failed.accountFailureDetails ?? ""
                let visibleSummary = failed.accountFailureSummary ?? ""
                check(!visibleSummary.isEmpty && !visibleSummary.contains("AUTH_INVALID")
                      && !visibleSummary.contains("stageUnavailable") && !visibleSummary.contains("Stage:"),
                      "Primary Account failure copy is human-readable; raw code and missing-stage facts stay in disclosure details")
                check(failed.authentication?.flow?.state == .failed && failed.isReady && !failed.signInPending
                      && !summary.isEmpty && !summary.contains("Original synthetic upstream wording")
                      && !summary.contains("disconnect") && !summary.contains("saved sign-in"),
                      "Failed auth flow surfaces a local safe reason without raw upstream message or success")
                check(scenario == "failedflow" ? summary.contains("AUTH_INVALID")
                      : summary.contains("Stage: Not reported") && !summary.contains("AUTH_INVALID"),
                      "Auth summary preserves the validated failure code and never invents a missing cause")
                check(failed.canSignIn && !failed.accountBusy,
                      "Terminal failure preserves the explicit user retry gate without an automatic retry")
                let snapshot = failed.lastSignInFailure
                await failed.refreshAccount()
                check(failed.authentication?.state == .signedOut && failed.authentication?.flow == nil
                      && failed.lastSignInFailure == snapshot && failed.accountFailureDetails == summary,
                      "Fresh signed-out/no-flow status cannot erase the last terminal failure")
                await failed.disconnect()
                check(failed.authentication == nil && failed.lastSignInFailure == snapshot
                      && failed.accountFailureDetails == summary,
                      "Disconnect preserves only the fixed terminal diagnostic for observation")
            }

            for diagnostic in NativeConsentFailure.allCases {
                let failed = session("failedstage-\(diagnostic.rawValue)")
                await failed.connect()
                await failed.refreshAccount()
                await failed.beginSignIn()
                let summary = failed.accountFailureDetails ?? ""
                let visibleSummary = failed.accountFailureSummary ?? ""
                check(!visibleSummary.isEmpty && !visibleSummary.contains(diagnostic.rawValue)
                      && !visibleSummary.contains("AUTH_INVALID") && !visibleSummary.contains("Stage:"),
                      "Known sign-in diagnostics retain specific safe details without exposing machine states as primary copy")
                check(failed.authentication?.flow?.error?.nativeConsentFailure == diagnostic
                      && summary.contains("Stage: \(diagnostic.stage)") && summary.contains("Reason: \(diagnostic.rawValue)")
                      && !summary.contains("Original synthetic upstream wording") && failed.isReady
                      && failed.authentication?.entitlementAuthorized == false && !failed.signInPending
                      && (diagnostic.stage != "devicePreparation"
                          || failed.accountFailureTitle == "Microsoft sign-in could not start."),
                      "Known closed auth stage/reason is locally mapped without upstream text or entitlement promotion")
                if diagnostic == .pipelineFailed {
                    check(summary.contains("does not establish that a browser appeared or consent completed"),
                          "Native pipeline diagnostic never invents observed Microsoft UI or successful consent")
                }
                if diagnostic == .providerProofInvalid {
                    check(summary.contains("did not provide a valid sign-in proof")
                          && !summary.contains("cryptograph") && !summary.contains("signature")
                          && !summary.contains("disconnect") && !summary.contains("delete"),
                          "Device-proof shape or missing-proof failure never invents a cryptographic cause or credential deletion")
                }
                let subsiteCopy: String?
                switch diagnostic {
                case .tokenKindInvalid:
                    subsiteCopy = "The device sign-in token uses a format this launcher cannot accept."
                case .tokenAudienceInvalid:
                    subsiteCopy = "The device sign-in token did not match the required context."
                case .tokenCipherInvalid:
                    subsiteCopy = "The device sign-in token payload could not be processed."
                case .tokenSecretInvalid:
                    subsiteCopy = "The device sign-in proof was missing or invalid."
                case .tokenXmlBoundInvalid:
                    subsiteCopy = "The device sign-in payload exceeded the supported processing limit."
                case .tokenXmlParseInvalid:
                    subsiteCopy = "The device sign-in payload could not be read in the required format."
                case .tokenCipherEncodingInvalid:
                    subsiteCopy = "The device sign-in payload encoding could not be processed."
                default:
                    subsiteCopy = nil
                }
                if let subsiteCopy {
                    check(summary.contains(subsiteCopy) && failed.accountFailureTitle == "Microsoft sign-in could not start."
                          && !summary.contains("cryptograph") && !summary.contains("signature")
                          && !summary.contains("Microsoft rejected") && !summary.contains("disconnect")
                          && !summary.contains("delete") && !summary.contains("4096")
                          && !summary.contains("version4") && !summary.contains("base64") && !summary.contains("STS")
                          && !summary.contains("64KiB") && !summary.contains("65536")
                          && !summary.contains("offset") && !summary.contains("your fault"),
                          "Static token subsite copy reports only the agreed guard category, not values or a guessed cause")
                }
                await failed.disconnect()
            }
            for diagnostic in [NativeConsentFailure.tokenKindInvalid, .tokenAudienceInvalid,
                               .tokenCipherInvalid, .tokenSecretInvalid,
                               .tokenXmlBoundInvalid, .tokenXmlParseInvalid, .tokenCipherEncodingInvalid] {
                var suffixes = ["extra", "unknown", "mismatched", "cancelcode", "expirycode", "internalcode"]
                if [.tokenXmlBoundInvalid, .tokenXmlParseInvalid, .tokenCipherEncodingInvalid].contains(diagnostic) {
                    suffixes += ["malformed", "category", "missing"]
                }
                for suffix in suffixes {
                    let failed = session("failedstage-\(diagnostic.rawValue)-\(suffix)")
                    await failed.connect()
                    await failed.refreshAccount()
                    await failed.beginSignIn()
                    let summary = failed.accountFailureDetails ?? ""
                    check(failed.isReady && failed.authentication?.flow?.error?.nativeConsentFailure == nil
                          && failed.authentication?.entitlementAuthorized == false && !failed.signInPending
                          && summary.contains("Stage: Not reported") && !summary.contains("Reason:")
                          && !summary.contains("Original extra-field sentinel")
                          && !summary.contains("Original synthetic upstream wording")
                          && failed.accountFailureTitle != "Microsoft sign-in could not start.",
                          "Actual mock-child subsite rejects malformed/extra/unknown/stage/non-AUTH details without secret retention or guessed preparation")
                    await failed.disconnect()
                }
            }
            for suffix in ["extra", "unknown", "mismatched", "cancelcode", "expirycode"] {
                let failed = session("failedstage-\(suffix)")
                await failed.connect()
                await failed.refreshAccount()
                await failed.beginSignIn()
                let summary = failed.accountFailureDetails ?? ""
                check(failed.isReady && failed.authentication?.flow?.error?.nativeConsentFailure == nil
                      && summary.contains("Stage: Not reported") && !summary.contains("Reason:")
                      && !summary.contains("Original extra-field sentinel") && !summary.contains("Original synthetic upstream wording"),
                      "Malformed/extra/unknown/incompatible diagnostics yield honest unavailable stage without secret sentinel")
                await failed.disconnect()
            }
            let gateConfiguration = configuration("authgate")
            let gated = LiveSession(configuration: gateConfiguration)
            await gated.connect()
            await gated.refreshAccount()
            let otherConsent = UUID()
            check(MicrosoftSignInGate.shared.acquire(otherConsent),
                  "A separate Microsoft consent owner can reserve the interactive slot")
            await gated.beginSignIn()
            check(try !gated.signInPending && !gated.accountBusy && gated.accountError != nil
                  && trace(gateConfiguration).filter { $0 == "auth.begin" }.isEmpty,
                  "Management sign-in cannot start while another service owns interactive consent")
            MicrosoftSignInGate.shared.release(otherConsent)
            let beginning = Task { await gated.beginSignIn() }
            try await wait { gated.accountBusy }
            await gated.beginSignIn()
            await beginning.value
            await gated.beginSignIn()
            check(try gated.signInPending && !gated.canSignIn && gated.accountFailureSummary == nil
                  && trace(gateConfiguration).filter { $0 == "auth.begin" }.count == 1,
                  "Busy and pending state reject duplicate native sign-in activation before any second mutation")
            let competingLibrary = PCGamesController()
            competingLibrary.signIn()
            check(!competingLibrary.sheetPresented && competingLibrary.error != nil
                  && !MicrosoftSignInGate.shared.available,
                  "A pending native flow retains the shared consent slot against the PC-library entry point")
            check(gated.accountLabel == "Sign-in pending" && gated.currentCredentialState == nil
                  && gated.accountSymbol == "person.crop.circle"
                  && gated.accountExplanation.contains("If Microsoft has opened a sign-in window")
                  && gated.accountLibraryTitle == "Sign-in pending",
                  "Pending contract state does not assert an observed provider window or completed account connection")
            let cancelling = Task { await gated.cancelSignIn() }
            try await wait { gated.accountBusy }
            await gated.cancelSignIn()
            await cancelling.value
            check(try gated.authentication?.flow?.state == .cancelled && !gated.signInPending
                  && gated.accountFailureSummary == nil
                  && trace(gateConfiguration).filter { $0 == "auth.cancel" }.count == 1,
                  "Busy cancellation gate sends one request and does not invent failure-stage diagnostics")
            check(gated.currentCredentialState == .signedOut && gated.accountSymbol == "person.crop.circle"
                  && gated.accountLabel == "Sign in with Microsoft"
                  && gated.accountExplanation.contains("no saved launcher sign-in"),
                  "Confirmed cancellation returns signed-out presentation without a saved-account badge")
            check(!gated.hasConfirmedSignIn, "Confirmed cancellation keeps welcome locked without deleting games")
            check(MicrosoftSignInGate.shared.available,
                  "Only confirmed management cancellation releases the shared Microsoft consent slot")
            let cancelledFlow = gated.authentication?.flow?.flowID
            check(gated.canSignIn && !gated.accountBusy,
                  "Confirmed cancellation enables an explicit next sign-in without deleting credentials")
            await gated.beginSignIn()
            check(try gated.signInPending && !gated.canSignIn
                  && gated.authentication?.flow?.flowID != cancelledFlow
                  && trace(gateConfiguration).filter { $0 == "auth.begin" }.count == 2,
                  "A user retry starts one distinct flow and immediately fences duplicate sign-in")
            let closedFlow = gated.authentication?.flow?.flowID
            try Data().write(to: gateConfiguration.stateDirectory.appendingPathComponent("native-window-closed"))
            try await wait { gated.authentication?.flow?.state == .cancelled && gated.canSignIn }
            check(try !gated.signInPending && gated.currentCredentialState == .signedOut
                  && gated.authentication?.flow?.flowID == closedFlow
                  && gated.authentication?.entitlementAuthorized == false
                  && trace(gateConfiguration).filter { $0 == "auth.cancel" }.count == 1,
                  "Observed helper-close cancellation clears pending via polling without an app cancel or saved badge")
            await gated.beginSignIn()
            check(try gated.signInPending && gated.authentication?.flow?.flowID != closedFlow
                  && trace(gateConfiguration).filter { $0 == "auth.begin" }.count == 3,
                  "An automatically closed attempt permits exactly one fresh user retry")
            await gated.cancelSignIn()
            await gated.disconnect()
            try cleanLifecycle(gateConfiguration)

            for scenario in ["authgate", "deadlinecompleted"] {
                let deadlineConfiguration = configuration(scenario)
                let deadlineSession = LiveSession(configuration: deadlineConfiguration,
                                                  signInPollingBudget: .milliseconds(1))
                await deadlineSession.connect()
                await deadlineSession.refreshAccount()
                await deadlineSession.beginSignIn()
                if scenario == "authgate" {
                    try await wait { deadlineSession.accountError != nil && !deadlineSession.accountBusy }
                    check(deadlineSession.signInPending && !deadlineSession.accountStatusCurrent
                          && !deadlineSession.canSignIn && !deadlineSession.canDisconnectAccount,
                          "Final deadline read retains unknown pending outcome and invalidates freshness without cancellation")
                    check(try trace(deadlineConfiguration).filter { $0 == "auth.status" }.count == 2
                          && trace(deadlineConfiguration).filter { $0 == "auth.cancel" }.isEmpty,
                          "Deadline performs exactly one final live status read, not another flow or cancellation")
                } else {
                    try await wait { deadlineSession.currentCredentialState == .credentialPresent }
                    check(!deadlineSession.signInPending && deadlineSession.accountStatusCurrent
                          && deadlineSession.authentication?.flow?.state == .completed,
                          "Final deadline read accepts a real completion instead of leaving the old pending snapshot")
                }
                await deadlineSession.disconnect()
                try cleanLifecycle(deadlineConfiguration)
            }

            let unavailable = session("transientauth")
            await unavailable.connect()
            await unavailable.refreshAccount()
            await unavailable.beginSignIn()
            try await wait { unavailable.accountStatusError == .credentialStoreUnavailable
                && !unavailable.accountBusy && unavailable.signInPending }
            check(!unavailable.canSignIn && !unavailable.canDisconnectAccount,
                  "Transient inaccessible store never permits deletion or new sign-in")
            check(unavailable.accountLabel == "Sign-in status needs checking"
                  && unavailable.currentCredentialState == nil && unavailable.signInPending
                  && unavailable.accountExplanation.contains("current outcome could not be confirmed")
                  && unavailable.accountLibraryTitle == unavailable.accountLabel,
                  "Unconfirmed pending flow remains cancellation-fenced and displays an unknown outcome")
            await unavailable.refreshAccount()
            try await wait { unavailable.authentication?.flow?.state == .completed }
            check(unavailable.isReady && unavailable.authentication?.state == .credentialPresent,
                  "Explicit status reconciles after denied Keychain access without automatically repeating a prompt")
            await unavailable.disconnect()

            let committing = session("latecancel")
            await committing.connect()
            await committing.refreshAccount()
            await committing.beginSignIn()
            await committing.refreshAccount()
            check(committing.signInPending, "Safe status remains usable while a sign-in is pending")
            await committing.cancelSignIn()
            check(committing.signInPending && committing.authentication?.flow?.state != .cancelled,
                  "Rejected commit cancellation never reports false cancellation")
            try await wait { committing.authentication?.flow?.state == .completed }
            check(committing.authentication?.state == .credentialPresent && committing.isReady,
                  "Late INVALID_TRANSITION cancellation resumes reconciliation to completion")
            await committing.disconnect()

            let discovery = session("discoveryrecover")
            await discovery.connect()
            await discovery.refreshCatalog("")
            let failedIDs = Set(discovery.discoveryFailures.map(\.id))
            check(discovery.products.isEmpty && !failedIDs.isEmpty && discovery.canLoadMoreCatalog
                  && discovery.catalogError != nil,
                  "All-failure initial page exposes valid continuation without hiding failures")
            await discovery.refreshCatalog("", more: true)
            check(!discovery.products.isEmpty && Set(discovery.discoveryFailures.map(\.id)) == failedIDs
                  && discovery.products.flatMap(\.editions).allSatisfy { $0.entitlement.kind == .unknown },
                  "Successful continuation retains earlier failures without ownership promotion")
            check(!discovery.gamePassCatalogComplete() && discovery.gamePassCatalogCompletedAt == nil,
                  "REVIEW M1: A Game Pass list whose first page failed is never complete, even after a clean continuation")
            await discovery.disconnect()

            let hundredsConfiguration = configuration("discoveryhundreds")
            let hundreds = LiveSession(configuration: hundredsConfiguration)
            await hundreds.connect()
            await hundreds.loadGamePassCatalog()
            check(hundreds.products.count == 16 && hundreds.nextCursor != nil,
                  "REQ-81: First useful Discover load resolves one sixteen-game page, not the 300-game catalogue")
            check(!hundreds.gamePassCatalogComplete(),
                  "REVIEW M1: One clean page of a longer Game Pass list is not a complete list")
            check(try trace(hundredsConfiguration).filter { $0 == "catalog.discover" }.count == 1,
                  "REQ-81: First view has exactly one catalogue request")
            await hundreds.loadCatalogOnEntry("")
            check(try trace(hundredsConfiguration).filter { $0 == "catalog.discover" }.count == 1,
                  "REQ-81: Warm Discover entry performs zero additional catalogue requests")
            for _ in 0..<18 { await hundreds.loadGamePassCatalog() }
            check(hundreds.gamePassProducts.count == 300
                  && hundreds.gamePassProductIDs.count == 300
                  && hundreds.nextCursor == nil && !hundreds.gamePassCatalogHasMore
                  && hundreds.gamePassCatalogExhausted && !hundreds.gamePassCatalogPaging
                  && hundreds.catalogError == nil,
                  "Game Pass selection follows every existing continuation page to hundreds of unique PC games")
            check(hundreds.gamePassCatalogComplete() && hundreds.discoveryFailures.isEmpty
                  && !hundreds.gamePassCatalogComplete(now: Date().addingTimeInterval(LiveSession.gamePassCatalogMaximumAge + 1)),
                  "REVIEW M1: Every clean page to the last makes the list complete, and only for a bounded time")
            let retainedIDs = hundreds.products.map(\.id)
            await hundreds.loadCatalogOnEntry("")
            check(hundreds.products.map(\.id) == retainedIDs && hundreds.products.count == 300,
                  "Revisiting Discover retains the entire paged catalogue")
            let catalogueRows = LibraryGame.gamePassCatalog(installed: [], owned: [],
                                                            products: hundreds.gamePassProducts)
            check(catalogueRows.count == 300 && catalogueRows.allSatisfy { !$0.owned && $0.gamePass }
                  && LibraryGame.collection(installed: [], owned: [], products: [],
                    gamePass: hundreds.gamePassProducts, active: true).isEmpty,
                  "Full Game Pass browsing does not invent ownership or promote unresolved grants into personal access")
            await hundreds.loadGamePassCatalog()
            check(hundreds.gamePassProducts.count == 300 && !hundreds.gamePassCatalogPaging,
                  "Completed Game Pass paging is reused without render-triggered reload or duplicate games")
            await hundreds.refreshCatalog("")
            check(hundreds.products.count == 300 && Set(hundreds.products.map(\.id)) == Set(retainedIDs),
                  "REQ-81: Retry of page one preserves later-page successes needed by the selected genre")
            check(!hundreds.gamePassCatalogComplete(),
                  "REVIEW M1: Refreshing page one clears completeness until the list is followed to the end again")
            await hundreds.refreshCatalog("", more: true)
            check(hundreds.products.count == 300 && hundreds.catalogError == nil,
                  "REQ-81: Continuation after retry deduplicates retained games instead of a false revision error")
            await hundreds.disconnect()
            check(!hundreds.gamePassCatalogPaging && !hundreds.gamePassCatalogHasMore
                  && !hundreds.gamePassCatalogExhausted && hundreds.gamePassProducts.isEmpty
                  && !hundreds.gamePassCatalogComplete() && hundreds.gamePassCatalogCompletedAt == nil,
                  "Disconnect retires the full catalogue scope, paging state and completeness")
            try cleanLifecycle(hundredsConfiguration)

            let repeatedPage = session("discoveryrepeatedpage")
            await repeatedPage.connect()
            await repeatedPage.loadGamePassCatalog()
            await repeatedPage.loadGamePassCatalog()
            check(repeatedPage.gamePassProducts.count == 16
                  && repeatedPage.gamePassCatalogError != nil && !repeatedPage.gamePassCatalogPaging,
                  "Repeated catalogue cursors stop with explicit partial coverage instead of looping or duplicating games")
            check(!repeatedPage.gamePassCatalogComplete(),
                  "REVIEW M1: A Game Pass list that stopped on an error is never complete")
            await repeatedPage.disconnect()

            let boundedConfiguration = configuration("discoverybounded")
            let boundedCatalogue = LiveSession(configuration: boundedConfiguration)
            await boundedCatalogue.connect()
            for _ in 0..<32 { await boundedCatalogue.loadGamePassCatalog() }
            check(boundedCatalogue.gamePassProducts.count == 512
                  && boundedCatalogue.nextCursor != nil && !boundedCatalogue.gamePassCatalogHasMore
                  && boundedCatalogue.gamePassCatalogError?.contains("limit") == true,
                  "Catalogue limit preserves partial coverage and stops offering an impossible Load remaining action")
            check(!boundedCatalogue.canLoadMoreCatalog && !boundedCatalogue.gamePassCatalogComplete(),
                  "Discover does not offer More games when the catalogue bound prevents another page, and the bounded list isn't complete")
            let readsAtLimit = try trace(boundedConfiguration).filter { $0 == "catalog.discover" }.count
            check(readsAtLimit == 32, "REQ-81: Reaching the 512 bound requires exactly 32 individually demanded pages")
            await boundedCatalogue.refreshCatalog("", more: true)
            check(try trace(boundedConfiguration).filter { $0 == "catalog.discover" }.count == readsAtLimit
                  && boundedCatalogue.catalogError == nil,
                  "Explicit continuation at capacity preserves content without a request or false service error")
            await boundedCatalogue.loadGamePassCatalog()
            check(try trace(boundedConfiguration).filter { $0 == "catalog.discover" }.count == readsAtLimit,
                  "Repeated requests at the catalogue bound make no additional producer calls")
            await boundedCatalogue.disconnect()
            try cleanLifecycle(boundedConfiguration)

            let partialFeed = session("discoveryrefresh")
            await partialFeed.connect()
            await partialFeed.refreshCatalog("")
            let retainedFeedIDs = partialFeed.gamePassProductIDs
            check(partialFeed.gamePassBadgeProductIDs == retainedFeedIDs && !retainedFeedIDs.isEmpty,
                  "COR101: Fresh validated PC catalog membership supplies exact-title cover badges without an account grant")
            let retainedVisibleIDs = Set(partialFeed.products.map(\.id))
            check(!retainedFeedIDs.isEmpty && partialFeed.gamePassCatalogError == nil,
                  "SDD-LIB-06: partial PC discovery records remain metadata, not a personal access grant")
            await partialFeed.refreshCatalog("")
            check(partialFeed.gamePassProductIDs == retainedFeedIDs
                  && Set(partialFeed.products.map(\.id)) == retainedVisibleIDs
                  && Set(partialFeed.gamePassProducts.map(\.id)) == retainedFeedIDs
                  && partialFeed.gamePassCatalogError != nil
                  && partialFeed.gamePassLibraryNotice.contains("retained")
                  && !partialFeed.gamePassCatalogLoading,
                  "SDD-LIB-06: all-failure partial refresh retains bounded catalog records with explicit stale/error state")
            check(partialFeed.gamePassBadgeProductIDs.isEmpty,
                  "COR101: Failed refresh retains browse records but removes unconfirmed cover membership badges")
            partialFeed.market = "GB"
            check(partialFeed.gamePassBadgeProductIDs.isEmpty,
                  "COR101: Market invalidation clears cover membership evidence")
            await partialFeed.disconnect()
            check(partialFeed.gamePassProductIDs.isEmpty && partialFeed.gamePassProducts.isEmpty
                  && partialFeed.gamePassCatalogError == nil && !partialFeed.gamePassCatalogLoading,
                  "SDD-LIB-06: disconnect retires prior catalog scope and transient refresh state")

            let partialRetry = session("discoverypartialretry")
            await partialRetry.connect()
            await partialRetry.refreshCatalog("")
            let classics = partialRetry.products
            let classicsFacts = Dictionary(uniqueKeysWithValues: classics.map {
                ($0.id, LibraryCatalogFacts(genres: ["Classics"], isBaseGame: true))
            })
            let genreSelection = DiscoverSelection()
            genreSelection.genre = "Classics"
            check(classics.count == 6 && !partialRetry.discoveryFailures.isEmpty,
                  "REQ-81: Reproduce six useful games plus partial-results Retry")
            await partialRetry.refreshCatalog("")
            let retryKey = CatalogProjectionKey(accountHash: nil, query: "", owned: [],
                products: partialRetry.products, gamePass: partialRetry.gamePassProducts,
                gamePassIDs: partialRetry.gamePassProductIDs, installed: [], accessIsCurrent: false,
                metadataRevision: 1, compatibility: [:], genre: genreSelection.genre, showsUnsupported: true)
            let retryProjection = CatalogProjection(key: retryKey, facts: classicsFacts, isVisible: { _ in true })
            check(partialRetry.products.count == 7 && retryProjection.visible.count == 6
                  && genreSelection.genre == "Classics" && partialRetry.nextCursor != nil
                  && !partialRetry.discoveryFailures.isEmpty,
                  "REQ-81: Partial Retry retains all six Classics, genre intent and continuation instead of false Games(0)")
            await partialRetry.disconnect()

            let failedRetry = session("discoveryretryfailure")
            await failedRetry.connect()
            await failedRetry.refreshCatalog("")
            await failedRetry.refreshCatalog("", more: true)
            let loadedBeforeRetry = failedRetry.products
            let cursorBeforeRetry = failedRetry.nextCursor
            let retryGenre = DiscoverSelection()
            retryGenre.genre = "Classics"
            let retryFacts = Dictionary(uniqueKeysWithValues: loadedBeforeRetry.map {
                ($0.id, LibraryCatalogFacts(genres: ["Classics"], isBaseGame: true))
            })
            check(loadedBeforeRetry.count == 32 && cursorBeforeRetry != nil,
                  "REQ-81: Failed page-one Retry fixture first admits two pages and a continuation")
            await failedRetry.refreshCatalog("")
            let failedRetryKey = CatalogProjectionKey(accountHash: nil, query: "", owned: [],
                products: failedRetry.products, gamePass: failedRetry.gamePassProducts,
                gamePassIDs: failedRetry.gamePassProductIDs, installed: [], accessIsCurrent: false,
                metadataRevision: 1, compatibility: [:], genre: retryGenre.genre, showsUnsupported: true)
            let failedRetryProjection = CatalogProjection(key: failedRetryKey, facts: retryFacts, isVisible: { _ in true })
            check(failedRetry.products.map(\.id) == loadedBeforeRetry.map(\.id)
                  && failedRetry.nextCursor == cursorBeforeRetry && failedRetry.canLoadMoreCatalog
                  && failedRetry.catalogError != nil && failedRetryProjection.visible.count == 32
                  && retryGenre.genre == "Classics",
                  "REQ-81: Retry failure without page details preserves loaded games, genre and usable continuation")
            await failedRetry.refreshCatalog("", more: true)
            check(failedRetry.products.count == 48 && failedRetry.catalogError == nil
                  && failedRetry.nextCursor != cursorBeforeRetry,
                  "REQ-81: Continuation after detail-free Retry failure uses retained revision and cursor")
            await failedRetry.disconnect()

            let feed = session("discoverypcflag")
            await feed.connect()
            await feed.refreshCatalog("")
            let feedIDs = Set(feed.products.map(\.id))
            check(!feedIDs.isEmpty && feed.catalogError == nil
                  && feed.products.allSatisfy { !$0.pcCatalogCandidate }
                  && feed.gamePassProductIDs.isEmpty && feed.gamePassProducts.isEmpty,
                  "SDD-LIB-03: public discovery may retain console candidates but the PC Game Pass shelf excludes them")
            await feed.refreshCatalog("neutral")
            check(feed.gamePassProductIDs.isEmpty && feed.gamePassProducts.isEmpty
                  && feed.catalogCorpus == "publicMicrosoftStoreSearch"
                  && feed.catalogError == nil,
                  "B2: Searching Store preserves loaded Game Pass IDs without promoting failures or ownership")
            feed.market = "GB"
            check(feed.gamePassProductIDs.isEmpty && feed.gamePassProducts.isEmpty,
                  "B2/B5: Market/language scope changes clear Game Pass IDs and shelf products")
            await feed.disconnect()
            check(feed.gamePassProductIDs.isEmpty && feed.gamePassProducts.isEmpty,
                  "B2/B5: Disconnection discards the in-memory feed and shelf evidence")
            check(feed.gamePassBadgeProductIDs.isEmpty,
                  "COR101: Unknown/console-only and disconnected catalog cannot advertise PC Game Pass")

            let publicCatalog = session("publiccapture")
            await publicCatalog.connect()
            await publicCatalog.refreshCatalog("Halo")
            check(publicCatalog.products.count == 1 && publicCatalog.products.first?.title == "Halo Infinite"
                  && publicCatalog.discoveryFailures.count == 4
                  && publicCatalog.catalogNotice == "Some results couldn't be checked.",
                  "Partial public metadata has one concise notice and keeps the checked real product")
            check(publicCatalog.authentication == nil && !publicCatalog.accountStatusCurrent
                  && publicCatalog.products.flatMap(\.editions).allSatisfy { $0.entitlement.kind == .unknown },
                  "Browsing and presenting games performs no credential read or ownership promotion")
            guard let product = publicCatalog.products.first,
                  let edition = product.editions.first else {
                throw ManagementError.invalidPayload
            }
            check(edition.installation.kind == "notInstalled"
                  && publicCatalog.libraryTitle == "Your PC library isn't available yet"
                  && publicCatalog.installedSnapshot?.installations.isEmpty == true,
                  "Catalog notInstalled and a constant-empty response never become a Mac inventory claim")
            check(publicCatalog.productSummary(product) ==
                  "Catalog metadata doesn't verify access or Mac compatibility. Use Library or Discover for Install and Play.",
                  "Multi-edition public detail separates catalog evidence from eligible Library and Discover actions")
            NativeUIChecks.checkLiveLayouts(session: publicCatalog, check: check)
            await publicCatalog.disconnect()

            let localEmpty = session("registryempty")
            await localEmpty.connect()
            check(localEmpty.installedSnapshot?.installations.isEmpty == true
                  && localEmpty.libraryTitle == "Your PC library isn't available yet"
                  && localEmpty.libraryMessage == "X Ode can't yet verify which PC games you own.",
                  "A constant-empty registry response never advertises an implemented registry or an empty Mac")
            await localEmpty.disconnect()
            let localUnavailable = session("registryunavailable")
            await localUnavailable.connect()
            check(localUnavailable.installedSnapshot == nil && localUnavailable.installedError != nil
                  && localUnavailable.libraryTitle == "Your PC library isn't available yet",
                  "An unavailable registry response never changes the real unsupported-library boundary")
            await localUnavailable.disconnect()

            let failureConfiguration = configuration("uifailures")
            let visibleFailures = LiveSession(configuration: failureConfiguration)
            await visibleFailures.connect()
            await visibleFailures.refreshAccount()
            await visibleFailures.refreshCatalog("Synthetic query")
            let catalogFailure = visibleFailures.catalogError
            check(catalogFailure != nil && visibleFailures.accountError == nil
                  && visibleFailures.accountMessage == "Your game library isn't available yet."
                  && visibleFailures.catalogNotice == "Games couldn't be loaded. Choose Refresh to try again.",
                  "A catalog failure has visible catalog recovery and never contaminates Account")
            await visibleFailures.refreshAccount()
            check(visibleFailures.accountError != nil && !visibleFailures.accountStatusCurrent
                  && visibleFailures.authentication?.state == .credentialPresent
                  && visibleFailures.currentCredentialState == nil
                  && visibleFailures.accountStatusError == .credentialStoreUnavailable
                  && visibleFailures.accountMessage.contains("cannot access Keychain")
                  && visibleFailures.accountMessage.contains("choose Check status.")
                  && !visibleFailures.canSignIn && !visibleFailures.canDisconnectAccount,
                  "Blocked Account read names Keychain access and Check status while retaining only an unconfirmed saved snapshot")
            await visibleFailures.refreshAccount()
            check(visibleFailures.accountError == nil && visibleFailures.currentCredentialState == .credentialPresent
                  && visibleFailures.catalogError == catalogFailure,
                  "Account recovery restores only credential evidence and never erases a catalog failure")
            var signOutPreparationFinished = false
            await visibleFailures.signOut {
                signOutPreparationFinished = true
                return nil
            }
            check(visibleFailures.authentication?.state == .credentialPresent
                  && !visibleFailures.accountStatusCurrent && visibleFailures.currentCredentialState == nil
                  && !visibleFailures.canSignIn && !visibleFailures.canDisconnectAccount
                  && signOutPreparationFinished && !visibleFailures.appSignOutComplete
                  && visibleFailures.accountError?.contains("Some app sign-in data may already have been removed") == true
                  && visibleFailures.accountMessage == "Sign-out couldn't be confirmed. Check status before trying again.",
                  "Failed logout preserves the previous snapshot but never presents signed-out or current-saved success")
            await visibleFailures.refreshAccount()
            await visibleFailures.refreshActivity()
            check(visibleFailures.activityError != nil && visibleFailures.activity.needsSnapshot
                  && !visibleFailures.activity.isReconciling && visibleFailures.activityNotice != nil
                  && visibleFailures.accountError == nil && visibleFailures.currentCredentialState == .credentialPresent,
                  "Failed activity refresh exposes its retry and does not become an account failure or stranded spinner")
            await visibleFailures.refreshActivity()
            check(visibleFailures.activityError == nil && visibleFailures.activityNotice == nil
                  && !visibleFailures.activity.needsSnapshot,
                  "An explicit successful activity refresh clears only its own failure")
            let previousSnapshot = visibleFailures.installedSnapshot
            await visibleFailures.refreshInstalled()
            check(visibleFailures.installedSnapshot == previousSnapshot && !visibleFailures.installedSnapshotCurrent
                  && visibleFailures.installedError != nil
                  && visibleFailures.libraryTitle == "Your PC library isn't available yet",
                  "Failed registry refresh retains a stale wire snapshot without claiming installation or a populated registry")
            check(try trace(failureConfiguration).filter { $0.hasPrefix("auth.") } ==
                  ["auth.status", "auth.status", "auth.status", "auth.logout", "auth.status"],
                  "Error presentation adds no automatic auth read, sign-in, verification or logout retry")
            check(await visibleFailures.disconnect(), "Visible-error regression retires its owned neutral child")
            try cleanLifecycle(failureConfiguration)

            let empty = session("queryempty")
            await empty.connect()
            await empty.refreshCatalog("XodusNoMatch9F4A12C7")
            check(empty.isReady && empty.products.isEmpty && empty.discoveryFailures.isEmpty
                  && empty.catalogError == nil && empty.catalogCorpus == "publicMicrosoftStoreSearch"
                  && empty.nextCursor == nil && empty.discoveryCheckedAt != nil,
                  "Genuine empty query remains live, scoped and distinct from all-failure pages")
            check(empty.catalogEmptyTitle == "No Store matches"
                  && empty.catalogEmptyExplanation(query: "No match", canRefresh: true).contains("no matching games"),
                  "Only a confirmed zero-result Store response displays the no-match message")
            await empty.refreshAccount()
            check(empty.isReady && empty.accountStatusCurrent,
                  "Native status reconciliation still works after a genuine empty query")
            await empty.disconnect()

            let stopped = session("queryslow")
            await stopped.connect()
            let late = Task { await stopped.refreshCatalog("XodusNoMatch9F4A12C7") }
            try await wait { stopped.searching }
            check(stopped.products.isEmpty && stopped.catalogEmptyTitle == "Finding games"
                  && stopped.discoveryCheckedAt == nil
                  && stopped.catalogEmptyExplanation(query: "Pending", canRefresh: true).contains("not available yet")
                  && !stopped.catalogEmptyExplanation(query: "Pending", canRefresh: true).contains("no matching"),
                  "Pending empty catalog shows loading, never a premature no-match result")
            stopped.stopCatalogSearch()
            await late.value
            check(stopped.isReady && stopped.catalogStopped && stopped.discoveryCheckedAt == nil,
                  "Stopped search discards later bounded results without pretending HTTP was cancelled")
            check(stopped.catalogEmptyTitle == "Search stopped"
                  && stopped.catalogEmptyExplanation(query: "Stopped", canRefresh: true).contains("new search"),
                  "Cancelled catalog UI remains distinct from a confirmed empty result")
            await stopped.disconnect()

            let staleScope = session("queryslow")
            await staleScope.connect()
            let staleRequest = Task { await staleScope.refreshCatalog("Old market query") }
            try await wait { staleScope.searching }
            staleScope.market = "FR"
            check(staleScope.products.isEmpty && !staleScope.searching
                  && staleScope.catalogCorpus == "observedPublicProducts"
                  && staleScope.catalogError == nil,
                  "REQ-9: Changing market immediately retires the old query, cursor and loading state")
            await staleRequest.value
            check(staleScope.products.isEmpty && staleScope.catalogCorpus == "observedPublicProducts"
                  && staleScope.catalogError == nil && !staleScope.searching,
                  "REQ-9: A late old-market completion cannot repopulate the retired catalogue scope")
            await staleScope.disconnect()

            let refreshRecovery = session("queryrefreshfailure")
            await refreshRecovery.connect()
            await refreshRecovery.refreshCatalog("Recovery title")
            let retainedProducts = refreshRecovery.products
            check(!retainedProducts.isEmpty && refreshRecovery.catalogError == nil,
                  "REQ-12: A successful same-scope query establishes truthful content before refresh")
            await refreshRecovery.refreshCatalog("Recovery title")
            check(refreshRecovery.products == retainedProducts && refreshRecovery.catalogError != nil
                  && !refreshRecovery.searching
                  && refreshRecovery.catalogNotice == "Games couldn't be loaded. Choose Refresh to try again."
                  && refreshRecovery.catalogEmptyTitle != "No Store matches",
                  "REQ-12: Same-scope transport failure retains prior results with explicit actionable error")
            await refreshRecovery.refreshCatalog("Recovery title")
            check(refreshRecovery.products.map(\.id) == retainedProducts.map(\.id)
                  && refreshRecovery.catalogError == nil && !refreshRecovery.searching,
                  "REQ-12: Explicit retry clears only the recovered catalog error and restores current results")
            await refreshRecovery.disconnect()

            let startupConfiguration = configuration("startupquery")
            let startup = LiveSession(configuration: startupConfiguration)
            for attempt in 1...2 {
                let connecting = Task { await startup.connect() }
                try await wait { startup.isReady }
                await startup.refreshCatalog("Latest startup query \(attempt)")
                let products = startup.products, cursor = startup.nextCursor
                await connecting.value
                check(startup.products == products && startup.products.first?.title == "Latest startup query \(attempt)"
                      && startup.catalogCorpus == "publicMicrosoftStoreSearch" && startup.nextCursor == cursor,
                      "Post-ready user query survives delayed startup reconciliation and reconnect")
                check(await startup.disconnect(), "Startup query regression retires its owned neutral child")
            }
            check(try !trace(startupConfiguration).contains("catalog.search"),
                  "Superseded startup never seeds an empty cache search over the user's Store query")
            try cleanLifecycle(startupConfiguration)

            let sourceFailure = session("querynodetails")
            await sourceFailure.connect()
            await sourceFailure.refreshCatalog("Original source query")
            check(sourceFailure.isReady && sourceFailure.catalogError != nil,
                  "Source-level PACKAGE_UNAVAILABLE without batch details is a recoverable catalog error")
            try await sourceFailure.reconcileActivity()
            check(sourceFailure.isReady && !sourceFailure.activity.needsSnapshot,
                  "Native snapshot still succeeds on the same connection after a source-level query error")
            await sourceFailure.disconnect()

            let coalesced = session("querycoalesce")
            await coalesced.connect()
            var edits: [Task<Void, Never>] = []
            for index in 1...5 {
                if index == 5 { coalesced.market = "FR"; coalesced.language = "fr-FR" }
                edits.last?.cancel()
                edits.append(Task { await coalesced.refreshCatalog("Original query \(index)") })
                if index < 5 { try await Task.sleep(for: .milliseconds(300)) }
            }
            for edit in edits { await edit.value }
            check(coalesced.isReady && coalesced.catalogError == nil
                  && coalesced.products.first?.title == "Original query 5 [requests=2,max=1]",
                  "Five delayed edits issue only one in-flight and one latest query, never producer capacity failure")
            check(coalesced.products.first?.market == "FR" && coalesced.products.first?.language == "fr-FR",
                  "Latest queued query retains its captured market/language instead of old request scope")
            await coalesced.disconnect()

            try await SearchPerformanceChecks.queryCache(configuration: configuration, check: check)
            let dropped = session("querycoalesce")
            await dropped.connect()
            let active = Task { await dropped.refreshCatalog("Active original query") }
            try await wait { dropped.searching }
            let queued = Task { await dropped.refreshCatalog("Queued original query") }
            try await Task.sleep(for: .milliseconds(300))
            dropped.stopCatalogSearch()
            await active.value
            await queued.value
            check(dropped.catalogStopped && dropped.discoveryCheckedAt == nil,
                  "Stop clears the queued latest request while fencing the active bounded result")
            await dropped.refreshCatalog("After stopped queue")
            check(dropped.products.first?.title == "After stopped queue [requests=2,max=1]",
                  "A stopped queued query was never sent; the next explicit search remains usable")
            check(await dropped.disconnect(), "Stopped-query worker releases its owned process without an unbounded wait")
            for _ in 0..<3 {
                await dropped.connect()
                await dropped.refreshCatalog("Reconnected original query")
                let ready = dropped.isReady
                let closed = await dropped.disconnect()
                check(ready && closed,
                      "Repeated catalog-worker reconnect waits for owned-child exit and stays usable")
            }

            let selected = URL(fileURLWithPath: "/synthetic/selected/game")
            let inspected = session("inspection")
            await inspected.connect()
            await inspected.inspectInstallation(at: selected)
            check(inspected.inspection?.directory == selected.path
                  && inspected.inspection?.assessment.registered == false
                  && inspected.inspection?.assessment.launchable == false
                  && inspected.installedSnapshot == nil,
                  "Selected-folder inspection remains separate from registry, entitlement and launch")
            await inspected.disconnect()
            check(inspected.inspection == nil, "Inspection evidence clears when its engine disconnects")

            for scenario in ["inspectionmissing", "inspectionmismatch"] {
                let rejected = session(scenario)
                await rejected.connect()
                await rejected.inspectInstallation(at: selected)
                check(rejected.inspection == nil && rejected.inspectionError != nil,
                      "Missing or differently scoped inspection is an explicit error, never empty installed success")
                await rejected.disconnect()
            }

            let slowConfiguration = configuration("retireslow")
            let retiring = LiveSession(configuration: slowConfiguration)
            await retiring.connect()
            var firstFinished = false, secondFinished = false, fixtureAllowed = false, quitAllowed = false
            let firstClose = Task { let result = await retiring.disconnect(); firstFinished = true; return result }
            try await wait { retiring.phase == .disconnecting }
            let secondClose = Task { let result = await retiring.disconnect(); secondFinished = true; return result }
            let fixtureClose = Task { let result = await retiring.disconnect(); fixtureAllowed = result; return result }
            let quitClose = Task { let result = await retiring.disconnect(); quitAllowed = result; return result }
            let overlappingReconnect = Task { await retiring.connect() }
            try await Task.sleep(for: .milliseconds(150))
            let heldTrace = try trace(slowConfiguration)
            check(!firstFinished && !secondFinished && !fixtureAllowed && !quitAllowed
                  && retiring.connectionTransitioning && heldTrace.contains("stdin.closed") && !heldTrace.contains("exiting"),
                  "Actual child held after stdin EOF prevents early disconnect, fixture or quit success")
            await overlappingReconnect.value
            check(try trace(slowConfiguration).filter { $0 == "started" }.count == 1,
                  "Reconnect during shared retirement cannot start a second engine")
            let sharedResults = await [firstClose.value, secondClose.value, fixtureClose.value, quitClose.value]
            check(sharedResults.allSatisfy { $0 } && !retiring.connectionTransitioning,
                  "All overlapping disconnect callers observe the same completed child exit")
            await retiring.connect()
            let reconnectA = Task { await retiring.connect() }
            try await wait { retiring.phase == .disconnecting }
            let reconnectB = Task { await retiring.connect() }
            await reconnectA.value
            await reconnectB.value
            check(try retiring.isReady && trace(slowConfiguration).filter { $0 == "started" }.count == 3,
                  "Overlapping complete reconnect transitions spawn exactly one replacement, not two post-close engines")
            let superseded = Task { await retiring.connect() }
            try await wait { retiring.phase == .disconnecting }
            let supersedingClose = Task { await retiring.disconnect() }
            await superseded.value
            let supersedingResult = await supersedingClose.value
            check(try supersedingResult && retiring.phase == .disconnected
                  && trace(slowConfiguration).filter { $0 == "started" }.count == 3,
                  "Disconnect supersedes an entire pending reconnect before its post-close spawn")
            try cleanLifecycle(slowConfiguration)

            let failedConfiguration = configuration("retirefailed")
            let observer = ShutdownCheckObserver()
            let unobserved = LiveSession(configuration: failedConfiguration,
                                        shutdownClient: { await observer.close($0) })
            await unobserved.connect()
            let failedA = Task { await unobserved.disconnect() }
            try await wait { unobserved.phase == .disconnecting }
            let failedB = Task { await unobserved.disconnect() }
            let failedFixture = Task { await unobserved.disconnect() }
            let quitRuntime = RuntimeProviderSettings()
            let quitCoordinator = ApplicationTerminationCoordinator()
            let failedQuit = Task { await quitCoordinator.shutdown(session: unobserved, runtime: quitRuntime) }
            await unobserved.connect()
            try await wait { unobserved.retiringDisconnectWaiterCount == 4 }
            await observer.beginShortObservation()
            let failedResults = await [failedA.value, failedB.value, failedFixture.value, failedQuit.value]
            let observedAttempts = await observer.attempts
            try await waitForTrace("retirement.held", failedConfiguration)
            check(failedResults.allSatisfy { !$0 },
                  "Actual short observation failure blocks every admitted disconnect, fixture and Quit caller")
            check(observedAttempts == 1,
                  "All four admitted callers share exactly one actual short exit observation")
            check(unobserved.phase == .failed && unobserved.errorMessage != nil,
                  "A failed actual exit observation retains an actionable failed lifecycle state")
            check(try !trace(failedConfiguration).contains("exiting"),
                  "The actual neutral child remains held until explicit release, not an arbitrary sleep")
            check(!quitRuntime.applicationTerminating && !unobserved.applicationTerminating,
                  "Refused normal termination restores interactions only after both cleanup attempts finish")
            await unobserved.connect()
            check(try !unobserved.isReady && trace(failedConfiguration).filter { $0 == "started" }.count == 1,
                  "A retry cannot overwrite an unobserved retiring child with a new engine")
            try Data("Release only this owned neutral retirement child.\n".utf8)
                .write(to: failedConfiguration.stateDirectory.appendingPathComponent("retirement.release"))
            await observer.useDefaultBudget()
            check(await quitCoordinator.shutdown(session: unobserved, runtime: quitRuntime),
                  "Retry through the normal termination coordinator reconciles the retained child's eventual exit")
            unobserved.applicationTerminating = false
            await unobserved.connect()
            check(try unobserved.isReady && trace(failedConfiguration).filter { $0 == "started" }.count == 2,
                  "A new engine is allowed only after the retained child's exit is actually observed")
            check(await unobserved.disconnect(), "Recovered lifecycle test releases its last actual child")
            try cleanLifecycle(failedConfiguration)

            for scenario in ["retirehello", "retiresnapshot"] {
                let startupConfiguration = configuration(scenario)
                let starting = LiveSession(configuration: startupConfiguration)
                let startup = Task { await starting.connect() }
                try await waitForTrace(scenario == "retirehello" ? "hello.wait" : "snapshot.wait", startupConfiguration)
                let duplicate = Task { await starting.connect() }
                let interruption = Task { await starting.disconnect() }
                await duplicate.value
                let interrupted = await interruption.value
                await startup.value
                check(try interrupted && starting.phase == .disconnected && starting.hello == nil
                      && !starting.connectionTransitioning
                      && trace(startupConfiguration).filter { $0 == "started" }.count == 1,
                      "Disconnect fences suspended negotiation/snapshot continuations without stale startup or second spawn")
                await starting.connect()
                check(starting.isReady && !starting.connectionTransitioning,
                      "A fenced startup does not strand future explicit connection attempts")
                await starting.disconnect()
                try cleanLifecycle(startupConfiguration)
            }

            let diagnostics = session("diagnostics")
            await diagnostics.connect()
            let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("XodusDiagnosticChecks-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer {
                do { try FileManager.default.removeItem(at: exportRoot) }
                catch { check(false, "Owned synthetic diagnostic export cleanup failed") }
            }

            let output = exportRoot.appendingPathComponent("summary.txt")
            await diagnostics.saveDiagnosticSummary(to: output)
            check(diagnostics.diagnosticExportError != nil && !FileManager.default.fileExists(atPath: output.path),
                  "Diagnostic export requires a current reviewed preview and creates no unreviewed file")
            await diagnostics.previewDiagnostics()
            check(diagnostics.descriptorMetricCounts == nil && !diagnostics.descriptorMetricIntervalCompleted,
                  "Ordinary diagnostic preview keeps opt-in descriptor measurement disabled")
            guard let reviewed = diagnostics.diagnosticPreview else { throw ManagementError.invalidPayload }
            await diagnostics.saveDiagnosticSummary(to: output)
            check(try String(contentsOf: output, encoding: .utf8) == reviewed && diagnostics.diagnosticSaved,
                  "Export saves exactly the reviewed counts-only summary, without raw backend data")
            await diagnostics.saveDiagnosticSummary(to: exportRoot.appendingPathComponent("missing/summary.txt"))
            check(diagnostics.diagnosticExportError != nil && !diagnostics.diagnosticSaved
                  && diagnostics.diagnosticPreview == reviewed,
                  "Filesystem export failure is visible, never success, and preserves the reviewed summary for retry")
            guard let remote = URL(string: "https://example.invalid/diagnostics") else { throw ManagementError.invalidPayload }
            await diagnostics.saveDiagnosticSummary(to: remote)
            check(diagnostics.diagnosticExportError != nil && !diagnostics.diagnosticSaved,
                  "Diagnostic export rejects nonlocal destinations without writing")

            for scenario in ["metricsearly", "metricsmissing"] {
                let measured = session(scenario)
                let previous = ProcessInfo.processInfo.environment["XODUS_DESCRIPTOR_METRICS"]
                setenv("XODUS_DESCRIPTOR_METRICS", "1", 1)
                await measured.connect()
                if let previous { setenv("XODUS_DESCRIPTOR_METRICS", previous, 1) }
                else { unsetenv("XODUS_DESCRIPTOR_METRICS") }
                await measured.previewDiagnostics()
                check(measured.descriptorMetricCounts?.checkpoint == 2
                      && !measured.descriptorMetricIntervalCompleted
                      && measured.diagnosticPreview != nil && !measured.diagnosticSaved,
                      "Existing diagnostic preview captures baseline on the same opted-in app-owned session without file export")
                let priorPreview = measured.diagnosticPreview
                let priorAccount = measured.accountHash
                if scenario == "metricsmissing" { measured.errorMessage = "Retained synthetic status" }
                await measured.loadCatalogOnEntry("")
                await measured.previewDiagnostics()
                if scenario == "metricsmissing" {
                    check(measured.descriptorMetricCounts == nil && !measured.descriptorMetricIntervalCompleted
                          && measured.errorMessage == "Retained synthetic status"
                          && measured.diagnosticPreview == priorPreview && measured.accountHash == priorAccount,
                          "Missing session end marker reports incomplete proof without corrupting the redacted summary or error state")
                } else {
                    check(measured.descriptorMetricCounts?.checkpoint == 3
                          && measured.descriptorMetricIntervalCompleted && measured.diagnosticPreview != nil,
                          "Second existing preview certifies a bounded interval on the original Library/Discover manager")
                }
                await measured.disconnect()
                check(measured.descriptorMetricCounts == nil && !measured.descriptorMetricIntervalCompleted,
                      "Session retirement clears descriptor interval ownership")
            }
            await diagnostics.disconnect()
            await diagnostics.saveDiagnosticSummary(to: output)
            check(diagnostics.diagnosticExportError != nil && !diagnostics.diagnosticSaved,
                  "Disconnect invalidates diagnostic preview before another export")
        } catch {
            check(false, (error as? LocalizedError)?.errorDescription
                  ?? "Native fixture regression did not complete: \(String(describing: error))")
        }
        let source = ProcessInfo.processInfo.environment["XODUS_DESCRIPTOR_CHECK_CLI"] == nil
            ? "Mock children only; no Keychain or Microsoft operation."
            : "Mock fixtures plus neutral source CLI envelope; no account operations."
        print("\(count) native session checks, \(failures) failures. \(source)")
        return failures == 0
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private actor ShutdownCheckObserver {
    private(set) var attempts = 0
    private var budget: Duration = .milliseconds(200)
    private var shortObservationReleased = false
    private var admission: CheckedContinuation<Void, Never>?

    func close(_ client: ManagementClient) async -> Bool {
        attempts += 1
        if !shortObservationReleased {
            await withCheckedContinuation { admission = $0 }
        }
        return await client.close(observationTimeout: budget)
    }

    func beginShortObservation() {
        shortObservationReleased = true
        admission?.resume()
        admission = nil
    }

    func useDefaultBudget() { budget = .seconds(6) }
}
