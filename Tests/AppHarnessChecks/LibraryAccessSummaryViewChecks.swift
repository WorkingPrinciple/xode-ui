// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SwiftUI
import AppKit
import CoreGraphics
import XodusManagement
@testable import XodusPreview

final class LibraryAccessSummaryViewChecks: XCTestCase {
    private let readinessTextRegion = CGRect(x: 52, y: 0, width: 460, height: 100)

    @MainActor
    func testReadinessDoesNotPresentUnknownLibraryAsEmpty() async throws {
        let library = PCGamesController(store: PCGamesMockStore(),
                                        client: PCGamesClient(transport: PCGamesMockTransport([])))
        let image = try await renderSetupRow(ReadinessLibraryRow(library: library))
        // REQ-185: Unknown provider data is not displayed as zero ownership or subscription.
        try assertRenderedLabels(image, [
            .init("PC library unavailable", .bodyMedium),
            .init("Check your sign-in in Account settings, then rescan.", .caption)
        ], textRegion: readinessTextRegion)
    }

    @MainActor
    func testReadinessRescanRetriesFailedLegacyLoad() async throws {
        let store = PCGamesMockStore("existing-neutral-value")
        let transport = PCGamesMockTransport([])
        let library = PCGamesController(store: store, client: PCGamesClient(transport: transport))
        await library.loadOnAppear()
        await library.waitForLoad()
        XCTAssertNotNil(library.error)
        let readsBefore = await store.reads
        XCTAssertEqual(readsBefore, 1)
        let row = ReadinessLibraryRow(library: library)
        XCTAssertEqual(row.statusTitle, "PC library unavailable")
        XCTAssertEqual(row.statusDetail, library.error)
        XCTAssertTrue(row.canRescan)

        row.rescan()
        for _ in 0..<100 {
            if await store.reads >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await library.waitForLoad()
        let readsAfter = await store.reads
        XCTAssertEqual(readsAfter, 2, "A user-requested rescan must retry after the automatic attempt fails")
    }

    @MainActor
    func testReadinessShowsRequiredKeychainApprovalWithoutStartingIt() async {
        let store = PCGamesMockStore("existing-neutral-value")
        await store.requireApproval()
        let library = PCGamesController(store: store, client: PCGamesClient(transport: PCGamesMockTransport([])))
        await library.restorePresence()
        let row = ReadinessLibraryRow(library: library)
        XCTAssertTrue(library.needsKeychainApproval)
        XCTAssertFalse(row.canRescan)
        XCTAssertEqual(row.statusDetail, "Approve Keychain access in Account settings, then rescan.")
        let approvals = await store.approvals
        XCTAssertEqual(approvals, 0)
    }

    @MainActor
    func testReadinessRescanRefreshesUnifiedLibraryWithinAutomaticThrottle() async throws {
        try await checkReadinessUnifiedRescan(scenario: "odelibraryempty")
    }

    @MainActor
    func testReadinessRescanLabelsRetainedResultsAfterFailure() async throws {
        try await checkReadinessUnifiedRescan(scenario: "odelibraryfailure")
    }

    @MainActor
    func testReadinessWithExistingPartialLibraryScenario() async throws {
        let library = try await PCGamesChecks.partialLibraryController()
        XCTAssertEqual(library.snapshot?.unresolvedCount, 1)
        XCTAssertTrue(library.accountAccessIsCurrent)
        XCTAssertFalse(library.accessIsCurrent)
        let row = ReadinessLibraryRow(library: library)
        // REQ-185: Distinguish reported records from verified current status, without inferring payment, tier, renewal or complete Library coverage.
        XCTAssertEqual(row.statusTitle, "1 PC game found")
        XCTAssertTrue(row.statusDetail.contains("Some game details are unavailable"))
        XCTAssertTrue(row.statusDetail.contains("Saved items may be included"))
        let image = try await renderSetupRow(row)
        try assertRenderedLabels(image, [
            .init("1 PC game found", .bodyMedium),
            .init("Some game details are unavailable. Saved items may be included.", .caption)
        ], textRegion: readinessTextRegion)
    }

    @MainActor
    func testExistingRetainedQueueScenarios() async throws {
        try await DownloadQueueChecks.run { condition, name in
            XCTAssertTrue(condition, name)
        }
    }

    @MainActor
    func testLibraryHeadingUsesSingularAndPluralCounts() async throws {
        for (count, expected) in [(1, "1 game in your library"), (2, "2 games in your library")] {
            let games = (0..<count).map { PCGame(id: String($0), title: "Game", artwork: nil) }
            let image = try await render(games: games)
            try assertRenderedLabels(image, [
                .init(expected, .calloutMedium),
                .init("Purchase or subscription source unavailable for \(count)", .callout),
                .init("Game Pass membership status unavailable", .callout)
            ])
        }
    }

    @MainActor
    func testUnknownAcquisitionDoesNotClaimZeroOwnershipOrSubscription() async throws {
        let games = (0..<13).map { PCGame(id: String($0), title: "Game", artwork: nil) }
        let image = try await render(games: games)
        try assertRenderedLabels(image, [
            .init("13 games in your library", .calloutMedium),
            .init("Purchase or subscription source unavailable for 13", .callout),
            .init("Game Pass membership status unavailable", .callout)
        ])
    }

    @MainActor
    func testPartialAcquisitionPreservesKnownTitlesWithoutClaimingAccountTotals() async throws {
        let games = [
            PCGame(id: "1", title: "Purchased", artwork: nil, acquisitionKind: .purchased),
            PCGame(id: "2", title: "Subscription", artwork: nil, acquisitionKind: .subscription),
            PCGame(id: "3", title: "Unknown", artwork: nil)
        ]
        let image = try await render(games: games)
        try assertRenderedLabels(image, [
            .init("3 games in your library", .calloutMedium),
            .init("1 owned game", .callout),
            .init("1 subscription-sourced", .callout),
            .init("Purchase or subscription source unavailable for 1", .callout),
            .init("Game Pass membership status unavailable", .callout)
        ])
    }

    @MainActor
    func testPositiveTitleProbeDoesNotEstablishAccountMembership() async throws {
        let status = try GamePassStatusResult.parse(Data(#"{"active":true}"#.utf8))
        let image = try await render(games: [
            PCGame(id: "1", title: "Game", artwork: nil, acquisitionKind: .purchased)
        ], status: status)
        try assertRenderedLabels(image, [
            .init("1 game in your library", .calloutMedium),
            .init("1 owned game", .callout),
            .init("Game Pass membership status unavailable", .callout),
            .init("A title access check does not establish account membership.", .caption)
        ])
    }

    @MainActor
    func testUnavailableAndNegativeTitleProbeDoNotEstablishAccountMembership() async throws {
        let unknown = try GamePassStatusResult.parse(Data(#"{"active":null}"#.utf8))
        let unavailable = try await render(games: [], status: unknown)
        try assertRenderedLabels(unavailable, [
            .init("Library ownership and acquisition unavailable", .callout),
            .init("Game Pass membership status unavailable", .callout),
            .init("A title access check does not establish account membership.", .caption)
        ])
        let inactive = try GamePassStatusResult.parse(Data(#"{"active":false}"#.utf8))
        let known = try await render(games: [], status: inactive)
        try assertRenderedLabels(known, [
            .init("Library ownership and acquisition unavailable", .callout),
            .init("Game Pass membership status unavailable", .callout),
            .init("A title access check does not establish account membership.", .caption)
        ])
    }

    @MainActor
    func testSavedLegacyMembershipDoesNotClaimCurrentStatus() async throws {
        for active in [true, false] {
            let status = try GamePassStatusResult.parse(Data("{\"active\":\(active)}".utf8))
            let image = try await render(games: [], status: status, current: false)
            try assertRenderedLabels(image, [
                .init("Library ownership and acquisition unavailable", .callout),
                .init("Game Pass membership status unavailable", .callout),
                .init("Saved title access check - current status not verified", .caption)
            ])
        }
    }

    @MainActor
    func testCompletedLegacyPresenceFailureIsRetiredByUnifiedMode() async throws {
        let store = PCGamesMockStore("existing-neutral-value")
        await store.failPresence(at: 0, delayed: false)
        let library = PCGamesController(store: store)
        await library.restorePresence()
        XCTAssertTrue(library.presenceUnavailable)
        library.useUnifiedAccount(LiveSession())
        XCTAssertFalse(library.presenceUnavailable)
        XCTAssertNil(library.error)
        XCTAssertFalse(library.restoringPresence)
    }

    @MainActor
    func testUnifiedEntitlementReportDoesNotClaimMembershipOrPayment() async throws {
        let games = [
            PCGame(id: "1", title: "Purchased", artwork: nil, acquisitionKind: .purchased),
            PCGame(id: "2", title: "Redeemed", artwork: nil, acquisitionKind: .purchased),
            PCGame(id: "3", title: "Recurring", artwork: nil, acquisitionKind: .subscription)
        ]
        let legacy = try GamePassStatusResult.parse(Data(#"{"active":true,"plan":"ultimate"}"#.utf8))
        for plans in [Optional<[String]>.none, [], ["CFQ7TTC0KHS0", "CFQ7TTC0P85B"]] {
            let image = try await render(games: games, status: legacy, unified: true, plans: plans)
            var labels: [RenderedLabel] = [
                .init("3 games in your library", .calloutMedium),
                .init("2 owned games", .callout),
                .init("1 subscription-sourced", .callout),
                .init(plans?.isEmpty == false
                      ? "Game Pass record reported" : "Game Pass membership not reported", .callout)
            ]
            if plans?.isEmpty == false {
                labels.append(.init("Subscription status not verified.", .caption))
            }
            labels.append(.init("Some Game Pass games may not be included in this library.", .caption))
            try assertRenderedLabels(image, labels)
        }
    }

    func testLibraryContractStrictEntitlementReportsAndAcquisition() throws {
        func decode(_ text: String) throws -> OdeAccountCollection {
            try JSONDecoder().decode(OdeAccountCollection.self, from: Data(text.utf8))
        }
        let old = try decode(#"{"items":[{"productID":"GAME00000001","acquisitionKind":"unknown"}]}"#)
        XCTAssertNil(old.reportedGamePassEntitlements)
        let unsorted = try decode(#"{"items":[],"reportedGamePassEntitlements":["CFQ7TTC0P85B","CFQ7TTC0KHS0"]}"#)
        XCTAssertEqual(unsorted.reportedGamePassEntitlements?.count, 2)
        let current = try decode(#"{"items":[{"productID":"GAME00000001","acquisitionKind":"purchased"}],"reportedGamePassEntitlements":["CFQ7TTC0KHS0","CFQ7TTC0P85B"]}"#)
        XCTAssertEqual(current.items.first?.acquisitionKind, .purchased)
        XCTAssertThrowsError(try decode(#"{"items":[{"productID":"GAME00000001","acquisitionKind":"owned"}]}"#))
        XCTAssertThrowsError(try decode(#"{"items":[],"activeSubscriptions":[]}"#))
        for plans in ["null", #"["bad"]"#, #"["CFQ7TTC0KHS0","CFQ7TTC0KHS0"]"#,
                      "true",
                      "[" + (0..<33).map { String(format: "\"%012d\"", $0) }.joined(separator: ",") + "]"] {
            XCTAssertThrowsError(try decode("{\"items\":[],\"reportedGamePassEntitlements\":\(plans)}"))
        }
        XCTAssertEqual(PCGameAcquisitionKind.merged(.unknown, .purchased), .purchased)
        XCTAssertEqual(PCGameAcquisitionKind.merged(.unknown, .subscription), .subscription)
        XCTAssertEqual(PCGameAcquisitionKind.merged(.subscription, .purchased), .purchased)
        XCTAssertEqual(LibraryEligibility.evaluate(entitlement: .purchased, accessIsCurrent: true,
                                                   verifiedGamePassAccess: false, installed: false), .owned)
        XCTAssertTrue(AccountEntitlements.derive(signedIn: true, held: [.purchased],
                                                 gamePassActive: nil, accessIsCurrent: true).ownsGames)
        let snapshot = PCGamesSnapshot(games: [], excludedCount: 0, updatedAt: Date(),
                                       reportedGamePassEntitlements: current.reportedGamePassEntitlements)
        XCTAssertEqual(snapshot.retainingUnresolved(from: snapshot).reportedGamePassEntitlements, current.reportedGamePassEntitlements)
        XCTAssertNil(snapshot.withReportedGamePassEntitlements(nil).retainingUnresolved(from: snapshot).reportedGamePassEntitlements)
        XCTAssertEqual(AccountEntitlements.derive(signedIn: true, held: [.subscription],
                                                  gamePassActive: nil, accessIsCurrent: true).gamePass, .unknown)
        let plansOnly = AccountEntitlements.derive(signedIn: true, held: [], gamePassActive: nil,
                                                   accessIsCurrent: true, reportedGamePassEntitlement: true)
        XCTAssertEqual(plansOnly.summary, "Game Pass record reported")
        XCTAssertEqual(plansOnly.gamePass, .unknown)
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = snapshot.withReportedGamePassEntitlements(current.reportedGamePassEntitlements, checkedAt: checkedAt)
        XCTAssertEqual(timed.retainingUnresolved(from: snapshot).reportedGamePassCheckedAt, checkedAt)
        XCTAssertNil(timed.withReportedGamePassEntitlements(nil).reportedGamePassCheckedAt)
    }

    @MainActor
    func testSingleGrantUsesOwnedBadgeWithoutPaymentClaim() {
        let facts = GameFacts(pc: PCGame(id: "GAME00000001", title: "Game", artwork: nil,
                                         acquisitionKind: .purchased),
                              gamePass: false, accessIsCurrent: true)
        XCTAssertEqual(facts.badgeLabels(), ["Owned"])
        XCTAssertFalse(facts.subscriptionAcquisition)
        let retained = PCGame(id: "GAME00000002", title: "Retained", artwork: nil, acquisitionKind: .purchased)
        let current = PCGame(id: "GAME00000001", title: "Current", artwork: nil, acquisitionKind: .purchased)
        let rows = LibraryGame.collection(installed: [], owned: [current, retained], products: [], gamePass: [],
                                           active: false, accessIsCurrent: false,
                                           currentAcquisitionIDs: [current.id])
        XCTAssertEqual(rows.first { $0.id == current.id }?.facts.badgeLabels(), ["Owned"])
        XCTAssertEqual(rows.first { $0.id == retained.id }?.facts.badgeLabels(), [])
        let unified = PCGamesSnapshot(games: [current], excludedCount: 0, updatedAt: Date())
            .withReportedGamePassEntitlements(nil)
        let record = unified.games[0]
        XCTAssertEqual(record.acquisitionKind, .purchased)
        XCTAssertEqual(record.presentationAcquisitionKind, .unknown)
        XCTAssertEqual(GameFacts(pc: record, gamePass: false, accessIsCurrent: true).badgeLabels(),
                       ["In your library"])
        let unifiedRows = LibraryGame.collection(installed: [], owned: unified.games, products: [],
                                                  gamePass: [], active: false)
        XCTAssertFalse(unifiedRows[0].owned)
        XCTAssertEqual(unifiedRows[0].eligibility, .library)
        XCTAssertEqual(LibraryEligibility.evaluate(entitlement: .subscription, accessIsCurrent: true,
                                                   verifiedGamePassAccess: false, installed: false), .library)
        XCTAssertEqual(LibraryEligibility.evaluate(entitlement: .subscription, accessIsCurrent: true,
                                                   verifiedGamePassAccess: true, installed: false), .gamePass)
    }

    @MainActor
    func testUnifiedSingleRecordDoesNotClaimOwnership() async throws {
        let snapshot = PCGamesSnapshot(games: [
            PCGame(id: "GAME00000001", title: "Record", artwork: nil, acquisitionKind: .purchased)
        ], excludedCount: 0, updatedAt: Date()).withReportedGamePassEntitlements(nil)
        let image = try await render(games: snapshot.games, unified: true)
        try assertRenderedLabels(image, [
            .init("1 game in your library", .calloutMedium),
            .init("Purchase or subscription source unavailable for 1", .callout),
            .init("Game Pass membership not reported", .callout),
            .init("Some Game Pass games may not be included in this library.", .caption)
        ])
        XCTAssertFalse(AccountEntitlements.derive(signedIn: true,
            held: snapshot.games.map(\.presentationAcquisitionKind),
            gamePassActive: nil, accessIsCurrent: true).ownsGames)
    }

    @MainActor
    func testPartialAndSavedLibraryTruthAndPlanCheckTime() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let games = [PCGame(id: "GAME00000001", title: "Owned", artwork: nil, acquisitionKind: .purchased)]
        let partial = try await render(games: games, unified: true, plans: ["CFQ7TTC0KHS0"],
                                       checkedAt: checkedAt, complete: false)
        try assertRenderedLabels(partial, [
            .init("1 game in your library", .calloutMedium),
            .init("Partial library - some game details are unavailable", .caption),
            .init("1 owned game", .callout),
            .init("Game Pass record reported", .callout),
            .init("As of \(checkedAt.formatted(date: .abbreviated, time: .shortened))", .caption),
            .init("Subscription status not verified.", .caption),
            .init("Some Game Pass games may not be included in this library.", .caption)
        ])
        let saved = try await render(games: games, unified: true, plans: ["CFQ7TTC0KHS0"],
                                     checkedAt: checkedAt, current: false)
        try assertRenderedLabels(saved, [
            .init("1 game in your library", .calloutMedium),
            .init("Saved library details - current access not verified", .caption),
            .init("1 owned game", .callout),
            .init("Game Pass membership not reported", .callout),
            .init("Some Game Pass games may not be included in this library.", .caption)
        ])
        let empty = try await render(games: [], unified: true)
        try assertRenderedLabels(empty, [
            .init("Library ownership and acquisition unavailable", .callout),
            .init("Game Pass membership not reported", .callout),
            .init("Some Game Pass games may not be included in this library.", .caption)
        ])
        let failedCatalog = try await render(games: [], unified: true, plans: ["CFQ7TTC0KHS0"],
                                              checkedAt: checkedAt, current: false, complete: false,
                                              reportCurrent: true)
        try assertRenderedLabels(failedCatalog, [
            .init("Library ownership and acquisition unavailable", .callout),
            .init("Game Pass record reported", .callout),
            .init("As of \(checkedAt.formatted(date: .abbreviated, time: .shortened))", .caption),
            .init("Subscription status not verified.", .caption),
            .init("Some Game Pass games may not be included in this library.", .caption)
        ])
        let report = PCGamesController.GamePassReport(account: "current-account", scope: "current-scope",
                                                      checkedAt: checkedAt, productIDs: ["CFQ7TTC0KHS0"])
        XCTAssertTrue(report.matches(account: "current-account", scope: "current-scope"))
        XCTAssertFalse(report.matches(account: nil, scope: "current-scope"))
        XCTAssertFalse(report.matches(account: "other-account", scope: "current-scope"))
        XCTAssertFalse(report.matches(account: "current-account", scope: "other-scope"))
    }

    @MainActor
    func testUnifiedModeAdoptsWhileLegacyPresenceReadIsBusy() async throws {
        let store = PCGamesMockStore("existing-neutral-value")
        await store.failPresence(at: 0, delayed: true)
        let library = PCGamesController(store: store)
        let session = LiveSession()
        let restoration = Task { await library.restorePresence() }
        while !library.restoringPresence { await Task.yield() }
        library.useUnifiedAccount(session)
        XCTAssertTrue(library.usesUnifiedAccount)
        await restoration.value
        await library.waitForOperation()
        XCTAssertNil(library.error)
        XCTAssertFalse(library.presenceUnavailable)
        XCTAssertNil(library.snapshot)
        XCTAssertFalse(library.busy)
        XCTAssertFalse(library.hasSavedSignIn)
        XCTAssertNil(library.currentReportedGamePassEntitlements)
    }

    @MainActor
    private func renderSetupRow(_ row: ReadinessLibraryRow) async throws -> CGImage {
        let host = NSHostingView(rootView: row.padding(20).frame(width: 600, height: 100).background(.white))
        host.appearance = NSAppearance(named: .aqua)
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        return try await renderSetupHost(host)
    }

    @MainActor
    private func renderSetupHost(_ host: NSView) async throws -> CGImage {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.cgImage)
    }

    @MainActor
    private func checkReadinessUnifiedRescan(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readiness-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("XodusManagementChecks")
        let configuration = BackendConfiguration(executable: executable,
                                                  stateDirectory: root.appendingPathComponent(scenario))
        let session = LiveSession(configuration: configuration)
        let store = PCGamesMockStore("legacy-must-not-be-read")
        let catalog = PCGamesHTTPResponse(status: 200, data: Data("""
            {"Products":[{"ProductId":"FIXTURE00001","ProductType":"Game","ProductKind":"Game","LocalizedProperties":[{"ProductTitle":"Held fixture"}],
             "DisplaySkuAvailabilities":[{"Sku":{"Properties":{"Packages":[
             {"PlatformDependencies":[{"PlatformName":"Windows.Desktop"}]}]}}}]}]}
            """.utf8))
        let transport = PCGamesMockTransport([catalog])
        let library = PCGamesController(store: store, client: PCGamesClient(transport: transport))
        await session.connect()
        do {
            await session.refreshAccount()
            XCTAssertTrue(session.hasConfirmedSignIn)
            library.useUnifiedAccount(session)
            await library.loadOnAppear()
            XCTAssertTrue(library.accessIsCurrent)
            XCTAssertEqual(library.representedGames.count, 1)

            let row = ReadinessLibraryRow(library: library)
            let host = NSHostingView(rootView: row.padding(20).frame(width: 600, height: 100).background(.white))
            host.appearance = NSAppearance(named: .aqua)
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: 600, height: 100)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            let initial = try await renderSetupHost(host)
            try assertRenderedLabels(initial, [.init("1 PC game found", .bodyMedium)], allowOtherInk: true)

            row.rescan()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !library.busy && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(library.busy, "An explicit rescan must not use the automatic 60-second throttle")
            XCTAssertEqual(row.statusTitle, "Checking your PC library...")
            XCTAssertFalse(row.canRescan)
            await library.waitForLoad()
            let trace = try String(contentsOf: configuration.stateDirectory.appendingPathComponent("lifecycle.log"),
                                   encoding: .utf8)
            XCTAssertEqual(trace.split(separator: "\n").filter { $0.hasPrefix("library:") }.count, 2)

            let image = try await renderSetupHost(host)
            if scenario == "odelibraryempty" {
                XCTAssertTrue(library.accessIsCurrent)
                XCTAssertTrue(library.representedGames.isEmpty)
                XCTAssertEqual(row.statusTitle, "No PC games found")
                try assertRenderedLabels(image, [.init("No PC games found", .bodyMedium)], allowOtherInk: true)
            } else {
                XCTAssertNotNil(library.error)
                XCTAssertFalse(library.accountAccessIsCurrent)
                XCTAssertEqual(row.statusTitle, "1 saved PC game")
                XCTAssertTrue(row.statusDetail.contains("current access is not verified"))
                try assertRenderedLabels(image, [.init("1 saved PC game", .bodyMedium)], allowOtherInk: true)
            }
            let legacyReads = await store.reads
            let legacyPresence = await store.presenceChecks
            XCTAssertEqual(legacyReads, 0)
            XCTAssertEqual(legacyPresence, 0)
            let disconnected = await session.disconnect()
            XCTAssertTrue(disconnected)
        } catch {
            _ = await session.disconnect()
            throw error
        }
    }

    @MainActor
    private func render(games: [PCGame], status: GamePassStatusResult? = nil,
                        unified: Bool = false, plans: [String]? = nil, checkedAt: Date? = nil,
                        current: Bool = true, complete: Bool = true, reportCurrent: Bool? = nil) async throws -> CGImage {
        let host = NSHostingView(rootView:
            XboxLibraryAccessSummary(games: games, status: status, gamePassCatalogCount: 0,
                                     unifiedAccount: unified, reportedGamePassEntitlements: plans,
                                     entitlementsCheckedAt: checkedAt,
                                     reportedGamePassIsCurrent: reportCurrent,
                                     accessIsCurrent: current, libraryIsComplete: complete)
                .padding(20).frame(width: 600, height: 320)
                .environment(\.colorScheme, .light).background(.white))
        host.appearance = NSAppearance(named: .aqua)
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.cgImage)
    }
}
