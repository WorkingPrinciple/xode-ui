// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import XodusManagement

@MainActor
enum RecentLibraryChecks {
    static func imageChecks(check: (Bool, String) -> Void) throws {
        for (width, height) in [(4096, 4096), (8192, 2048), (1, 1)] {
            try CatalogImagePolicy.validatePixels(width: width, height: height)
            check(true, "Decoded image policy admits exact sixteen-megapixel and axis boundaries")
        }
        for (width, height) in [(4096, 4097), (8192, 2049), (8193, 1), (0, 1), (1, -1)] {
            do {
                try CatalogImagePolicy.validatePixels(width: width, height: height)
                check(false, "Decoded dimensions reject one-pixel overflow and invalid axes before allocation")
            } catch { check(error as? ArtworkLoadError == .oversized,
                            "Decoded dimensions reject one-pixel overflow and invalid axes before allocation") }
        }
        do {
            _ = try CatalogImagePolicy.decode(Data(repeating: 0, count: CatalogImagePolicy.maximumBytes + 1))
            check(false, "Image bytes over eight MiB are rejected before ImageIO")
        } catch { check(error as? ArtworkLoadError == .oversized,
                        "Image bytes over eight MiB are rejected before ImageIO") }
        do {
            _ = try CatalogImagePolicy.decode(Data("not an image".utf8))
            check(false, "Malformed image bytes fail explicitly instead of producing a successful placeholder")
        } catch { check(error as? ArtworkLoadError == .invalidImage,
                        "Malformed image bytes fail explicitly instead of producing a successful placeholder") }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let pixels = bitmap.bitmapData else {
            throw ArtworkLoadError.invalidImage
        }
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else {
            throw ArtworkLoadError.invalidImage
        }
        let decoded = try CatalogImagePolicy.decode(bytes)
        check(decoded.width == 32 && decoded.height == 16,
              "The actual ImageIO thumbnail path decodes a local synthetic PNG without network access")
    }

    static func run(check: (Bool, String) -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecentLibraryChecks-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Neutral recent-history trace files are cleaned") }
        }
        func configuration(_ scenario: String) -> BackendConfiguration {
            BackendConfiguration(executable: URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("XodusManagementChecks"),
                stateDirectory: root.appendingPathComponent(scenario))
        }
        func trace(_ scenario: String) throws -> [String] {
            try String(contentsOf: root.appendingPathComponent(scenario).appendingPathComponent("lifecycle.log"),
                       encoding: .utf8).split(separator: "\n").map(String.init)
        }
        func waitForRead(_ scenario: String, count: Int = 1) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (try trace(scenario)).filter({ $0 == "library.recent" }).count < count {
                guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        for platform in ["pc", "console", "mixed", "unknown"] {
            let scenario = "recentsemantics\(platform)"
            let value = LiveSession(configuration: configuration(scenario))
            let state = AppState()
            await value.connect()
            let connected = try trace(scenario)
            await state.loadRecentActivityIfVisible(session: value)
            check(try trace(scenario) == connected && value.authentication == nil
                  && value.recentLibrary == nil && !state.showsRecentActivity,
                  "Main PC Library does not check saved sign-in or collect TitleHub history")
            state.query = "old Library search"
            state.openRecentActivity()
            check(state.showsRecentActivity && state.destination == .library && state.query.isEmpty,
                  "Recent activity is an explicit separate scope, not an owned-game shelf")
            await state.loadRecentActivityIfVisible(session: value)
            guard let history = value.recentLibrary, let title = history.titles.first else {
                throw ManagementError.invalidPayload
            }
            let loaded = try trace(scenario)
            check(title.platform.rawValue == platform && title.productID == nil
                  && value.libraryTitle == "Your PC library isn't available yet"
                  && value.libraryMessage == "Xodus can't yet verify which PC games you own.",
                  "Every reported activity platform, including PC, leaves owned-PC inventory unavailable")
            check(loaded.filter { $0 == "auth.status" }.count == 1
                  && loaded.filter { $0 == "library.recent" }.count == 1,
                  "Explicit activity entry performs only the existing saved-status then bounded history read")
            NativeUIChecks.checkMainLibraryWithHistory(session: value, check: check)
            await state.loadRecentActivityIfVisible(session: value)
            state.navigate(.library)
            await state.loadRecentActivityIfVisible(session: value)
            check(try !state.showsRecentActivity && state.query == "old Library search"
                  && value.recentLibrary == history && trace(scenario) == loaded,
                  "Back to main Library hides all activity without clearing it or making another request")
            state.openRecentActivity()
            await state.loadRecentActivityIfVisible(session: value)
            check(try trace(scenario) == loaded && value.recentLibrary == history,
                  "Activity rebuild and return reuse retained history without polling")
            state.query = title.name
            state.findInStore(title.name, session: value)
            await state.loadRecentActivityIfVisible(session: value)
            check(try state.destination == .discover && !state.showsRecentActivity
                  && state.query == title.name && value.selectedProduct == nil && trace(scenario) == loaded,
                  "Explicit activity Store action remains only navigation until user-directed catalog searching")
            for destination in Destination.allCases {
                state.openRecentActivity()
                state.query = "previous activity filter"
                state.navigate(destination)
                await state.loadRecentActivityIfVisible(session: value)
                let expectedQuery = destination == .library ? "old Library search"
                    : destination == .discover ? title.name : ""
                check(try !state.showsRecentActivity && state.query == expectedQuery && trace(scenario) == loaded,
                      "Toolbar navigation restores destination search, not activity search or ownership evidence")
            }
            check(await value.disconnect(), "Neutral Library-semantics owner closes")
        }
        for scenario in ["recentstorecandidates", "recentstoreempty", "recentstorefailure"] {
            let value = LiveSession(configuration: configuration(scenario))
            await value.connect()
            await value.loadRecentLibraryOnEntry()
            guard let history = value.recentLibrary, let title = history.titles.first else {
                throw ManagementError.invalidPayload
            }
            let account = value.authentication
            let before = try trace(scenario)
            let state = AppState()
            state.query = "previous Library filter"
            state.findInStore(title.name, session: value)
            check(try state.destination == .discover && state.query == title.name
                  && value.selectedProduct == nil && trace(scenario) == before,
                  "Explicit Find in Store routes only the actual title name, without product selection or immediate RPC")
            await value.refreshCatalog(state.query)
            check(value.recentLibrary == history && value.recentLibraryCurrent
                  && value.authentication == account && value.accountStatusCurrent
                  && title.productID == nil,
                  "Store search preserves personal history and account fences without inferring a Store mapping")
            check(try trace(scenario).filter { $0 == "auth.status" }.count == 1
                  && trace(scenario).filter { $0 == "library.recent" }.count == 1
                  && trace(scenario).filter { $0 == "catalog.query" }.count == 1,
                  "Only the existing user-directed catalog search runs; no extra status or personal read")
            if scenario == "recentstorecandidates" {
                guard let candidate = value.products.first else { throw ManagementError.invalidPayload }
                check(value.selectedProduct == nil && value.catalogError == nil,
                      "Matching catalog candidates never automatically become a mapped game detail")
                value.selectedProduct = candidate
                check(value.selectedProduct == candidate,
                      "The existing catalog candidate can be explicitly selected for its own product detail")
                state.findInStore(title.name, session: value)
                check(value.selectedProduct == nil && state.query == title.name,
                      "Another explicit title-name route dismisses stale product selection")
                state.navigate(.library)
                check(state.query == "previous Library filter" && !state.showsRecentActivity && value.recentLibrary == history,
                      "Returning to Library hides retained activity without clearing or rereading it")
            } else if scenario == "recentstoreempty" {
                check(value.products.isEmpty && value.catalogError == nil && value.discoveryFailures.isEmpty
                      && value.catalogEmptyTitle == "No Store matches" && value.selectedProduct == nil,
                      "A genuine zero-candidate search stays the existing honest empty result")
            } else {
                check(value.products.isEmpty && value.catalogError != nil && !value.discoveryFailures.isEmpty
                      && value.catalogEmptyTitle != "No Store matches" && value.selectedProduct == nil,
                      "Failed catalog candidate checking stays a visible partial/error state, not a false empty match")
            }
            check(await value.disconnect(), "Neutral title-name Store navigation owner closes")
        }

        let bootstrap = LiveSession(configuration: configuration("recentbootstrapstatusslow"))
        let activityState = AppState()
        activityState.openRecentActivity()
        await bootstrap.connect()
        let entering = Task { await activityState.loadRecentActivityIfVisible(session: bootstrap) }
        let bootstrapDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try trace("recentbootstrapstatusslow").filter({ $0 == "auth.status" }).isEmpty {
            guard ContinuousClock.now < bootstrapDeadline else { throw ManagementError.requestTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(bootstrap.recentLibraryBootstrapRunning && bootstrap.accountBusy
              && bootstrap.accountStatusChecking && !bootstrap.canLoadRecentLibrary
              && bootstrap.recentLibraryLoadingTitle == "Checking saved sign-in",
              "Explicit recent-activity loading exposes pending saved-status and leases account actions")
        let rebuilt = Task { await activityState.loadRecentActivityIfVisible(session: bootstrap) }
        entering.cancel()
        await bootstrap.refreshAccount()
        await rebuilt.value
        await entering.value
        let bootstrapTrace = try trace("recentbootstrapstatusslow")
        check(bootstrapTrace.filter { $0 == "auth.status" }.count == 1
              && bootstrapTrace.filter { $0 == "library.recent" }.count == 1
              && bootstrapTrace.firstIndex(of: "auth.status")! < bootstrapTrace.firstIndex(of: "library.recent")!
              && !bootstrapTrace.contains("auth.begin"),
              "One explicit activity load survives view cancellation and orders status before one history read")
        check(bootstrap.recentLibraryCurrent && bootstrap.recentLibrary?.titles.count == 1
              && !bootstrap.recentLibraryBootstrapRunning && !bootstrap.accountBusy,
              "The same live session retains its published real-shaped list after bootstrap")
        await activityState.loadRecentActivityIfVisible(session: bootstrap)
        check(try trace("recentbootstrapstatusslow") == bootstrapTrace,
              "View rebuild and repeated activity entry never poll a completed scoped load")
        await bootstrap.refreshAccount()
        await activityState.loadRecentActivityIfVisible(session: bootstrap)
        check(try bootstrap.recentLibrary == nil
              && trace("recentbootstrapstatusslow").filter { $0 == "library.recent" }.count == 1,
              "An explicit Account check still clears personal history without an automatic reread")
        await bootstrap.reloadRecentLibrary()
        check((try trace("recentbootstrapstatusslow")).filter { $0 == "auth.status" }.count == 2
              && bootstrap.recentLibraryCurrent,
              "Manual Library loading reuses the already fresh credential-present status")
        check(await bootstrap.disconnect(), "Neutral automatic Library owner closes")

        for scenario in ["recentbootstrapstatusfailure", "recentbootstraptransport", "recentbootstrapsignedout",
                         "recentbootstrapexpired", "recentbootstrapinvalid"] {
            let value = LiveSession(configuration: configuration(scenario))
            await value.connect()
            await value.loadRecentLibraryOnEntry()
            let failedTrace = try trace(scenario)
            await value.loadRecentLibraryOnEntry()
            check(try trace(scenario) == failedTrace && !value.recentLibraryBootstrapRunning,
                  "A failed or signed-out automatic load stops once with no appearance-triggered retry")
            if scenario == "recentbootstrapstatusfailure" {
                check(value.accountStatusError == .credentialStoreUnavailable
                      && value.recentLibraryMessage == ManagementError.credentialStoreUnavailable.localizedDescription
                      && !failedTrace.contains("library.recent") && value.canLoadRecentLibrary,
                      "Saved-access failure stays specific and retryable without requesting personal history")
            } else if ["recentbootstrapsignedout", "recentbootstrapexpired", "recentbootstrapinvalid"].contains(scenario) {
                let expected: CredentialState = scenario == "recentbootstrapsignedout" ? .signedOut
                    : scenario == "recentbootstrapexpired" ? .expired : .invalid
                check(value.currentCredentialState == expected && value.recentLibrary == nil
                      && !value.canLoadRecentLibrary && !failedTrace.contains("library.recent")
                      && !failedTrace.contains("auth.begin") && !value.recentLibraryMessage.isEmpty,
                      "A confirmed unavailable sign-in offers Account without starting login or history")
            } else {
                check(value.recentLibraryError?.contains("couldn't connect") == true && value.canLoadRecentLibrary,
                      "History transport failure remains a visible safe product error with explicit retry")
            }
            if ["recentbootstrapstatusfailure", "recentbootstraptransport"].contains(scenario) {
                await value.reloadRecentLibrary()
                let retried = try trace(scenario)
                check(value.recentLibraryCurrent && value.recentLibrary?.titles.count == 1
                      && retried.filter { $0 == "auth.status" }.count == (scenario == "recentbootstrapstatusfailure" ? 2 : 1),
                      "Explicit retry checks status only if access is unconfirmed, never when it is already fresh")
            }
            check(await value.disconnect(), "Neutral failed-bootstrap owner closes")
        }

        let freshBootstrap = LiveSession(configuration: configuration("recentbootstrapfresh"))
        await freshBootstrap.connect()
        await freshBootstrap.refreshAccount()
        await freshBootstrap.loadRecentLibraryOnEntry()
        check((try trace("recentbootstrapfresh")).filter { $0 == "auth.status" }.count == 1
              && freshBootstrap.recentLibraryCurrent,
              "Automatic foreground Library entry reuses an existing fresh saved-status result")
        check(await freshBootstrap.disconnect(), "Neutral fresh-status bootstrap owner closes")

        let zeroBootstrap = LiveSession(configuration: configuration("recentbootstrapzero"))
        await zeroBootstrap.connect()
        await zeroBootstrap.loadRecentLibraryOnEntry()
        check(zeroBootstrap.recentLibraryCurrent && zeroBootstrap.recentLibrary?.titles.isEmpty == true
              && zeroBootstrap.recentLibraryError == nil,
              "Automatic loading keeps a valid empty personal window empty without fixture filling")
        check(await zeroBootstrap.disconnect(), "Neutral zero-history bootstrap owner closes")

        let retiringBootstrap = LiveSession(configuration: configuration("recentbootstrapretire"))
        await retiringBootstrap.connect()
        let retiringLoad = Task { await retiringBootstrap.loadRecentLibraryOnEntry() }
        try await waitForRead("recentbootstrapretire")
        check(await retiringBootstrap.disconnect(), "A connection change retires its owned Library bootstrap")
        await retiringLoad.value
        check(retiringBootstrap.recentLibrary == nil && !retiringBootstrap.recentLibraryBootstrapRunning
              && !retiringBootstrap.accountBusy,
              "A retired bootstrap cannot publish into the next connection generation")

        let session = LiveSession(configuration: configuration("recentslow"))
        await session.connect()
        await session.refreshRecentLibrary()
        let uncheckedTrace = try trace("recentslow")
        check(session.recentLibrary == nil && !session.canRefreshRecentLibrary
              && !uncheckedTrace.contains("auth.status")
              && !uncheckedTrace.contains("library.recent"),
              "Anonymous startup and an unchecked Library never read credentials or personal history")
        await session.refreshAccount()
        let confirmedTrace = try trace("recentslow")
        check(session.canRefreshRecentLibrary && session.recentLibrary == nil
              && !confirmedTrace.contains("library.recent"),
              "Foreground Account confirmation enables an explicit history read, not automatic collection")
        let reading = Task { await session.refreshRecentLibrary() }
        try await waitForRead("recentslow")
        check(session.recentLibraryLoading && session.accountBusy && !session.canDisconnectAccount,
              "A personal-history request leases account mutations until its actual result")
        await session.refreshRecentLibrary()
        await session.refreshAccount()
        await session.beginSignIn()
        await session.refreshCatalog("neutral")
        check(session.products.count == 1 && session.recentLibraryLoading,
              "Public catalog work remains responsive during the single personal-history read")
        await reading.value
        check(try trace("recentslow").filter { $0 == "library.recent" }.count == 1
              && trace("recentslow").filter { $0 == "auth.status" }.count == 1
              && !trace("recentslow").contains("auth.begin"),
              "Repeated Library/Account clicks cannot redispatch or initiate login while reading")
        check(session.recentLibrary?.titles.count == 1 && session.recentLibraryCurrent
              && !session.recentLibraryLoading && !session.accountBusy
              && session.recentLibrary?.titles.first?.productID == nil,
              "Real-shaped history publishes separately from public product and installed evidence")
        await session.refreshAccount()
        let clearedTrace = try trace("recentslow")
        check(session.recentLibrary == nil && !session.recentLibraryCurrent
              && clearedTrace.filter { $0 == "library.recent" }.count == 1,
              "Explicit Account refresh clears identity-unbound personal history without rereading it")
        await session.refreshRecentLibrary()
        await session.signOut()
        check(session.recentLibrary == nil && !session.recentLibraryCurrent
              && session.currentCredentialState == .signedOut,
              "Sign-out clears personal history and does not reload it")
        check(await session.disconnect(), "Neutral history owner closes")

        let uncertain = LiveSession(configuration: configuration("recentstatusslow"))
        await uncertain.connect()
        await uncertain.refreshAccount()
        await uncertain.refreshRecentLibrary()
        let statusRead = Task { await uncertain.refreshAccount() }
        let statusDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try trace("recentstatusslow").filter({ $0 == "auth.status" }).count < 2 {
            guard ContinuousClock.now < statusDeadline else { throw ManagementError.requestTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(uncertain.recentLibrary == nil && !uncertain.recentLibraryCurrent
              && uncertain.accountStatusChecking && uncertain.accountBusy,
              "Identity-unbound history disappears before a new foreground saved-status read returns")
        await statusRead.value
        check(try trace("recentstatusslow").filter { $0 == "library.recent" }.count == 1
              && uncertain.recentLibrary == nil,
              "Credential-present status never silently rereads or rebinds earlier personal history")
        check(await uncertain.disconnect(), "Neutral foreground privacy-check owner closes")

        for scenario in ["recentstale", "recentprofilechanged", "recentzero"] {
            let value = LiveSession(configuration: configuration(scenario))
            await value.connect()
            await value.refreshAccount()
            await value.refreshRecentLibrary()
            if scenario == "recentzero" {
                check(value.recentLibrary?.titles.isEmpty == true && value.recentLibraryCurrent
                      && value.recentLibraryError == nil,
                      "An actual zero-title result is distinct from unsupported, unchecked and failed history")
            } else {
                await value.refreshRecentLibrary()
                check(value.recentLibraryError != nil && !value.recentLibraryCurrent,
                      "A failed personal read surfaces an actionable error, never successful empty history")
                check(scenario == "recentstale"
                      ? value.recentLibrary?.titles.count == 1 && value.accountStatusCurrent
                        && value.recentLibraryNotice?.contains("previously checked") == true
                      : value.recentLibrary == nil && !value.accountStatusCurrent,
                      "Transport failure retains explicitly stale history; a changed profile clears it")
            }
            check(await value.disconnect(), "Neutral failure/empty history owner closes")
        }
        let retired = LiveSession(configuration: configuration("recentslow"))
        await retired.connect()
        await retired.refreshAccount()
        let previousReads = try trace("recentslow").filter { $0 == "library.recent" }.count
        let late = Task { await retired.refreshRecentLibrary() }
        try await waitForRead("recentslow", count: previousReads + 1)
        check(await retired.disconnect(), "In-flight history owner retires without a second profile owner")
        await late.value
        check(retired.recentLibrary == nil && !retired.recentLibraryCurrent && !retired.accountBusy,
              "Retired generations cannot publish late personal results")
        check(!RecentPlatformFilter.pc.includes(.console) && !RecentPlatformFilter.pc.includes(.unknown)
              && RecentPlatformFilter.pc.includes(.mixed) && RecentPlatformFilter.pc.includes(.pc),
              "PC filtering uses reported platform evidence, never all Xbox history")
    }
}
