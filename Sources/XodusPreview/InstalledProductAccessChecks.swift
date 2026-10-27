// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

@MainActor
enum InstalledProductAccessChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let account = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        let product = "9NGLST31DG26"
        let denied = "9TESTDENIED0"
        let unknown = "9TESTUNKNOWN"
        let now = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
        func response(_ id: String, accountHash: String = account, access: String = "permitted",
                      reason: String? = nil, expiry: String? = nil,
                      checkedAt: String = "2030-01-01T00:00:00Z") throws -> OdeAccountRead {
            let payload: [String: Any] = [
                "section": "license", "accountHash": accountHash, "checkedAt": checkedAt,
                "payload": ["productID": id, "access": access,
                            "reason": reason as Any? ?? NSNull(), "expiresAt": expiry as Any? ?? NSNull()]
            ]
            return try JSONDecoder().decode(OdeAccountRead.self,
                from: JSONSerialization.data(withJSONObject: payload))
        }
        let pendingAccess = InstalledProductAccess()
        let pendingIDs = (0..<20).map { String(format: "9PEND%07d", $0) }
        let unchecked = pendingAccess.pending(product, account: account) && !pendingAccess.pending(product, account: nil)
        let started = ContinuousClock.now
        await pendingAccess.refresh(account: account, installedIDs: pendingIDs + [product], now: now) { id in
            if id == product { return try response(id) }
            throw ManagementError.disconnected
        }
        let elapsed = started.duration(to: .now)
        check(unchecked && !pendingAccess.pending(product, account: account)
              && pendingAccess.permits(product, account: account, now: now)
              && !pendingAccess.pending(pendingIDs[0], account: account)
              && !pendingAccess.permits(pendingIDs[0], account: account, now: now)
              && !pendingAccess.pending(product, account: other),
              "REQ-119 F1: An installed game is pending only until its own check answers; a failed check isn't pending or permitted, and another account never inherits it")
        check(elapsed < .milliseconds(1_500),
              "REQ-119 F1: Access checks run back to back with no fixed 100 ms gap (21 synthetic checks took \(elapsed))")
        pendingAccess.retire()

        let sweep = InstalledProductAccess()
        let sweepIDs = (0..<12).map { String(format: "9SWEEP%06d", $0) }
        let urgent = "9URGENT00001"
        var order: [String] = []
        let slowReader: @MainActor (String) async throws -> OdeAccountRead = { id in
            order.append(id)
            try await Task.sleep(for: .milliseconds(30))
            return try response(id)
        }
        let running = Task { @MainActor in
            await sweep.refresh(account: account, installedIDs: sweepIDs, now: now, read: slowReader)
        }
        for _ in 0..<100 where order.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await sweep.prioritize(urgent, account: account, installedIDs: sweepIDs + [urgent], read: slowReader)
        await running.value
        let urgentIndex = order.firstIndex(of: urgent)
        check(urgentIndex.map { $0 <= 3 } == true && order.count == sweepIDs.count + 1
              && sweep.permits(urgent, account: account, now: now),
              "L8 e2e: a deep link's newly registered game is checked next inside a running access sweep, not after it (position \(urgentIndex.map(String.init) ?? "none") of \(order.count))")
        sweep.retire()

        let controller = InstalledProductAccess()
        defer { controller.retire() }
        var requests: [String] = []
        let reader: @MainActor (String) async throws -> OdeAccountRead = { id in
            requests.append(id)
            if id == denied { return try response(id, access: "denied", reason: "providerDenied") }
            if id == unknown { return try response(id, access: "unknown", reason: "productNotListed") }
            return try response(id, expiry: "2030-01-01T00:02:00Z")
        }
        await controller.refresh(account: account,
            installedIDs: [product, product, denied, unknown, "invalid"], now: now, read: reader)
        check(requests == [product, denied, unknown].sorted(),
              "Installed access checks only deduplicated valid installed StoreIDs, sequentially")
        check(controller.facts.count == 3 && !controller.checking && controller.errors.isEmpty,
              "Typed access facts retain permitted, denied and unknown independently")
        check(controller.permitsReview(product, account: account, pcCandidate: true, now: now)
              && controller.reviewNotice(for: product, account: account, now: now) == nil
              && !controller.permitsReview(denied, account: account, pcCandidate: true, now: now)
              && controller.reviewNotice(for: denied, account: account, now: now)?.contains("didn't grant access") == true
              && !controller.permitsReview(unknown, account: account, pcCandidate: true, now: now)
              && controller.reviewNotice(for: unknown, account: account, now: now) == InstalledProductAccess.notIncludedNotice,
              "COR89: Selected account access permits review only; denial/unknown explain exact outcome without inventing ownership")
        let settledNotice = controller.reviewNotice(for: unknown, account: account, publicGamePassExcludes: true, now: now) ?? ""
        check(settledNotice == "Not included with your account. This game isn't in your Microsoft account's games or your PC Game Pass plan. If you own it, check that you're signed in with the right account."
              && controller.notIncluded(unknown, account: account, publicGamePassExcludes: true, now: now)
              && controller.notIncluded(unknown, account: account, publicGamePassExcludes: false, now: now)
              && !settledNotice.contains("account response") && !settledNotice.contains("unconfirmed")
              && !settledNotice.localizedCaseInsensitiveContains("store") && !settledNotice.localizedCaseInsensitiveContains("buy"),
              "QA A1: A settled answer without this game says plainly it isn't included with the account, with no internal wording and no store or purchase link")
        check(controller.notIncluded(unknown, account: account, publicGamePassExcludes: false, now: now)
              && !controller.notIncluded(denied, account: account, publicGamePassExcludes: true, now: now)
              && !controller.notIncluded(product, account: account, publicGamePassExcludes: true, now: now)
              && !controller.notIncluded(unknown, account: other, publicGamePassExcludes: true, now: now)
              && !controller.notIncluded(unknown, account: account, publicGamePassExcludes: true,
                                         now: now.addingTimeInterval(301)),
              "COR186 A1: Without a complete exclusion, a denial, a permit, another account or a stale fact never claims 'not included'")
        check(controller.permits(product, account: account, now: now)
              && !controller.permits(denied, account: account, now: now)
              && !controller.permits(unknown, account: account, now: now),
              "Only an exact permitted fact grants account-access filtering and Play")
        check(!controller.permits(product, account: other, now: now)
              && !controller.permits(product, account: nil, now: now),
              "Different or absent account cannot borrow an installed access fact")
        let selected = InstalledProductAccess()
        defer { selected.retire() }
        await selected.refresh(account: account, installedIDs: [product, denied, unknown], now: now) { id in
            try response(id, access: id == product ? "permitted" : "unknown",
                         reason: id == product ? nil : "productNotListed")
        }
        let preservedFact = selected.facts[product]?.checkedAt
        var selectedRequests: [String] = []
        await selected.refresh(account: account, installedIDs: [product, denied, unknown], now: now,
            force: true, selectedProductID: unknown) { id in
                selectedRequests.append(id)
                return try response(id, access: "unknown", reason: "productNotListed")
            }
        check(selectedRequests == [unknown] && selected.facts.count == 3
              && selected.facts[product]?.checkedAt == preservedFact
              && !selected.permits(unknown, account: account, now: now)
              && !selected.permits(product, account: other, now: now),
              "COR171 native: Exact-product access Retry preserves unrelated facts and cannot borrow another edition or account permission")
        check(!controller.permitsReview(product, account: other, pcCandidate: true, now: now)
              && !controller.permitsReview(product, account: nil, pcCandidate: true, now: now)
              && !controller.permitsReview(product, account: account, pcCandidate: true, now: now.addingTimeInterval(120)),
              "COR89: Exact account binding and actual grant expiry revoke selected-title review")
        check(!controller.permits(product, account: account, now: now.addingTimeInterval(120)),
              "Actual license expiry withdraws permission at the boundary")
        let purchased = PCGame(id: product, title: "Purchased installed fixture", artwork: nil,
                               acquisitionKind: .purchased)
        let installedFact = InstalledGame(id: UUID(), title: purchased.title, identityName: "Fixture.Permit",
            version: "1.0.0.0", storeId: product, folder: "/synthetic/permit",
            launcher: "/synthetic/never-run", importedAt: now)
        let purchaseFacts = GameFacts(pc: purchased, gamePass: true, installed: installedFact, accessIsCurrent: true)
        check(purchaseFacts.badgeLabels() == ["Owned", "Game Pass"]
              && purchaseFacts.installation == .installed(installedFact.folder)
              && controller.permits(product, account: account, now: now.addingTimeInterval(119))
              && !controller.permits(product, account: account, now: now.addingTimeInterval(120)),
              "REQ-50: Expired Play permit withdraws action eligibility without erasing purchase, membership or installation facts")
        await controller.refresh(account: account, installedIDs: [product, denied, unknown],
            now: now.addingTimeInterval(30), read: reader)
        check(requests.count == 3, "Warm account access is cached without repeated provider calls")
        await controller.refresh(account: account, installedIDs: [product, denied, unknown],
            now: now.addingTimeInterval(61), read: reader)
        check(requests.count == 6, "Unknown and denied facts retry after cooldown; short grants renew before actual expiry")
        await controller.refresh(account: account, installedIDs: [product], now: now.addingTimeInterval(301)) { _ in
            throw ManagementError.requestTimedOut
        }
        check(controller.errors[product] != nil && !controller.permits(product, account: account,
            now: now.addingTimeInterval(301)), "Transport failure cannot extend a stale permission or become denial")
        check(!controller.permitsReview(product, account: account, pcCandidate: true, now: now.addingTimeInterval(301))
              && controller.reviewNotice(for: product, account: account, now: now.addingTimeInterval(301))
                == InstalledProductAccess.unavailableNotice
              && controller.reviewNotice(for: product, account: account, publicGamePassExcludes: true,
                                         now: now.addingTimeInterval(301)) == "Couldn't confirm access right now. Try again."
              && InstalledProductAccess.tryAgainTitle == "Try Again",
              "QA A1: A failed or timed-out access read says \"Couldn't confirm access right now. Try again.\" with Try Again, never 'not included', a denial or a successful review")
        check(controller.facts[denied] == nil && controller.facts[unknown] == nil,
              "Removed installed IDs leave the access cache")
        await controller.refresh(account: other, installedIDs: [product], now: now) { id in
            try response(id)
        }
        check(controller.facts.isEmpty && controller.errors[product] != nil,
              "Account switch clears old facts and rejects a mismatched response envelope")
        controller.retire()
        let pending = Task {
            await controller.refresh(account: account, installedIDs: [product], now: now) { id in
                try? await Task.sleep(for: .milliseconds(100))
                return try response(id)
            }
        }
        await Task.yield()
        controller.retire()
        await pending.value
        check(controller.accountHash == nil && controller.facts.isEmpty && !controller.checking,
              "Retirement fences a late response even when its reader ignores cancellation")
        await controller.refresh(account: account, installedIDs: [product], now: now) { id in
            try response(id)
        }
        check(controller.permits(product, account: account, now: now.addingTimeInterval(299))
              && !controller.permits(product, account: account, now: now.addingTimeInterval(300)),
              "Perpetual grants still have a finite five-minute account cache")
        var explicitRetries = 0
        await controller.refresh(account: account, installedIDs: [product], now: now, force: true) { id in
            explicitRetries += 1
            return try response(id)
        }
        check(explicitRetries == 1
              && !controller.permitsReview(product, account: account, pcCandidate: true, now: now.addingTimeInterval(300)),
              "COR89: Explicit exact-ID retry bypasses cooldown once, never bypassing finite account-cache expiry")
        var renewals = 0
        var preservedDuringRenewal = false
        await controller.refresh(account: account, installedIDs: [product], now: now.addingTimeInterval(121)) { id in
            renewals += 1
            preservedDuringRenewal = controller.permits(product, account: account, now: now.addingTimeInterval(121))
            return try response(id, checkedAt: "2030-01-01T00:02:01Z")
        }
        check(preservedDuringRenewal,
              "Proactive refresh preserves a still-valid same-account fact while its request runs")
        check(renewals == 1 && controller.permits(product, account: account, now: now.addingTimeInterval(301)),
              "Background renewal starts before cache expiry instead of flickering Library and Play off at five minutes")
        let short = InstalledProductAccess()
        defer { short.retire() }
        await short.refresh(account: account, installedIDs: [product], now: now) { id in
            try response(id, expiry: "2030-01-01T00:02:00Z")
        }
        await short.refresh(account: account, installedIDs: [product], now: now.addingTimeInterval(61)) { _ in
            throw ManagementError.requestTimedOut
        }
        check(short.errors[product] != nil
              && short.permits(product, account: account, now: now.addingTimeInterval(100))
              && !short.permits(product, account: account, now: now.addingTimeInterval(120)),
              "Failed renewal preserves only still-valid evidence and never extends a short grant past actual expiry")
        let batch = InstalledProductAccess()
        defer { batch.retire() }
        let ids = (0..<36).map { String(format: "9TEST%07d", $0) }
        var clock = now
        var batchReads = 0
        let batchReader: @MainActor (String) async throws -> OdeAccountRead = { id in
            batchReads += 1
            clock = clock.addingTimeInterval(2)
            return try response(id, checkedAt: ISO8601DateFormatter().string(from: clock))
        }
        await batch.refresh(account: account, installedIDs: ids, now: now, read: batchReader)
        clock = now.addingTimeInterval(132)
        await batch.refresh(account: account, installedIDs: ids, now: clock, read: batchReader)
        clock = now.addingTimeInterval(204)
        await batch.refresh(account: account, installedIDs: ids, now: clock, read: batchReader)
        check(batchReads == 72 && ids.allSatisfy {
            batch.permits($0, account: account, now: now.addingTimeInterval(373))
        }, "Two-minute renewal threshold covers a 72-second sequential batch plus 60-second ticks without crossing the original cache boundary")
        let local = InstalledGamesController()
        local.useUnifiedAccount(LiveSession())
        local.setAccountAccessAllowed(true)
        check(!local.canRequestPlay(product), "Installed presence and confirmed sign-in alone never enable Play")
        let waitStarted = ContinuousClock.now
        let unsettled = InstalledGame(id: UUID(), title: "Synthetic pending title", identityName: "Synthetic",
            version: "1.0.0.0", storeId: product, folder: "/synthetic/never-read",
            launcher: "/synthetic/never-executed", importedAt: now)
        let pendingMessage = await local.playFromLaunchRequest(unsettled, engine: nil, timeout: .milliseconds(400))
        let waited = waitStarted.duration(to: .now)
        check(!local.productAccessSettled(product) && waited >= .milliseconds(400) && waited < .seconds(3)
              && pendingMessage?.contains("wasn't confirmed within") == true && !local.launchStarted
              && local.runningGameID == nil,
              "L7: A deep-link Play waits (bounded) for a pending access check instead of failing at once, then reports it truthfully without launching (\(waited))")
        var flag = false
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(100)); flag = true }
        let became = await InstalledGamesController.waitUntil(timeout: .seconds(2), interval: .milliseconds(20)) { flag }
        let never = await InstalledGamesController.waitUntil(timeout: .milliseconds(100), interval: .milliseconds(20)) { false }
        check(became && !never, "L7: The deep-link wait returns as soon as access settles and gives up at its bound")
        let direct = InstalledGamesController()
        direct.setAccountAccessAllowed(true)
        let wrongEngine = await direct.playFromLaunchRequest(unsettled, engine: "highball-x64-crossover26.3-r27",
                                                              timeout: .milliseconds(200))
        check(wrongEngine?.contains("isn't available for Synthetic pending title") == true
              && wrongEngine?.contains("No other engine was used") == true
              && direct.runningGameID == nil && !direct.launchStarted && unsettled.engineOverrideV2 == nil,
              "L8: A deep-link engine outside the title's verified Engine menu is refused, never substituted or launched")
        let game = InstalledGame(id: UUID(), title: "Synthetic installed title", identityName: "Synthetic",
            version: "1.0.0.0", storeId: product, folder: "/synthetic/never-read",
            launcher: "/synthetic/never-executed", importedAt: now)
        let importedFacts = GameFacts(pc: nil, gamePass: false, installed: game, accessIsCurrent: false)
        check(importedFacts.badgeLabels().isEmpty && importedFacts.installation == .installed(game.folder)
              && !local.canRequestPlay(product) && !local.launchStarted,
              "REQ-50: Imported installation stays installed and manageable without ownership badges or a Play permit")
        let unqualified = LibraryGame.collection(installed: [game], owned: [], products: [],
            gamePass: [], active: true)
        check(unqualified.isEmpty && LibraryGame.localRecords(installed: [game], qualified: unqualified,
            query: "", sort: .title).count == 1,
              "Pending installed records remain manageable, without entering account-qualified Your Games")
        let qualified = LibraryGame.collection(installed: [game], owned: [], products: [],
            gamePass: [], active: true, permittedInstalledIDs: [product])
        check(qualified.map(\.id) == [product] && qualified.first?.installed == game,
              "Exact permitted installed fact joins the real StoreID into Your Games")
        check(LibraryGame.visible(qualified, query: "", filter: .owned, sort: .title).isEmpty
              && LibraryGame.visible(qualified, query: "", filter: .gamePass, sort: .title).isEmpty,
              "License permission alone never invents ownership or subscription acquisition")
        check(LibraryGame.localRecords(installed: [game], qualified: qualified, query: "", sort: .title).isEmpty,
              "Qualified installation is not duplicated in the separate installed inventory")
        check(LibraryGame.collection(installed: [], owned: [], products: [], gamePass: [],
            active: true, permittedInstalledIDs: [product]).isEmpty,
              "Installed-product grant cannot fan out into uninstalled catalogue entitlement")
        let switched = InstalledProductAccess()
        defer { switched.retire() }
        func waitForSwitch(_ predicate: () -> Bool) async throws -> Bool {
            for _ in 0..<200 {
                if predicate() { return true }
                try await Task.sleep(for: .milliseconds(5))
            }
            return predicate()
        }
        var releaseOld: CheckedContinuation<OdeAccountRead, Never>?
        var releaseNew: CheckedContinuation<OdeAccountRead, Never>?
        let oldRead = Task {
            await switched.refresh(account: account, installedIDs: [product], now: now) { _ in
                await withCheckedContinuation { releaseOld = $0 }
            }
        }
        let oldStarted = try await waitForSwitch { releaseOld != nil }
        check(oldStarted, "REQ-50: Old-account allowed reader explicitly starts before switching")
        guard let oldCompletion = releaseOld else { throw ManagementError.requestTimedOut }
        let newRead = Task {
            await switched.refresh(account: other, installedIDs: [product], now: now) { _ in
                await withCheckedContinuation { releaseNew = $0 }
            }
        }
        let retired = try await waitForSwitch { switched.accountHash == nil }
        check(retired && switched.facts.isEmpty && releaseNew == nil,
              "REQ-50: Account switch explicitly retires old facts and joins old reader before starting the new reader")
        oldCompletion.resume(returning: try response(product))
        await oldRead.value
        let newStarted = try await waitForSwitch { releaseNew != nil }
        check(newStarted && switched.accountHash == other,
              "REQ-50: New-account reader explicitly starts and holds its response after old completion joins")
        guard let newCompletion = releaseNew else {
            newRead.cancel()
            await newRead.value
            throw ManagementError.requestTimedOut
        }
        let pendingCollection = LibraryGame.collection(installed: [game], owned: [], products: [],
            gamePass: [], active: true,
            permittedInstalledIDs: switched.permits(product, account: other, now: now) ? [product] : [])
        let pendingDisplay = LibraryGame.displayCollection(installed: [game], account: pendingCollection)
        check(switched.checking && releaseNew != nil && !pendingDisplay.isEmpty
              && !LibraryLoadingPresentation.showsAccessProgress(
                checking: switched.checking, hasUsableContent: !pendingDisplay.isEmpty)
              && !switched.permits(product, account: other, now: now),
              "COR83: Populated Library omits access-progress row while real background reader continues and admission stays fenced")
        check(LibraryLoadingPresentation.showsAccessProgress(checking: true, hasUsableContent: false)
              && !LibraryLoadingPresentation.showsAccessProgress(checking: false, hasUsableContent: false)
              && !LibraryLoadingPresentation.showsAccessProgress(checking: false, hasUsableContent: true),
              "COR83: Empty initial access loading remains distinct; idle Library reserves no access-status row")
        check(retired && newStarted && switched.checking && switched.facts.isEmpty
              && !switched.permits(product, account: account, now: now)
              && !switched.permits(product, account: other, now: now)
              && pendingCollection.isEmpty && pendingDisplay.first?.facts.badgeLabels().isEmpty == true
              && pendingDisplay.first?.facts.installation == .installed(game.folder),
              "REQ-50: Joined old allowed completion cannot transiently restore permission or shared qualification while new denial is still held")
        newCompletion.resume(returning: try response(product, accountHash: other,
                                                      access: "denied", reason: "providerDenied"))
        await newRead.value
        let switchedCollection = LibraryGame.collection(installed: [game], owned: [], products: [],
            gamePass: [], active: true,
            permittedInstalledIDs: switched.permits(product, account: other, now: now) ? [product] : [])
        let switchedDisplay = LibraryGame.displayCollection(installed: [game], account: switchedCollection)
        check(switched.accountHash == other && switched.facts[product]?.value.access == .denied
              && !switched.permits(product, account: account, now: now)
              && !switched.permits(product, account: other, now: now)
              && switchedCollection.isEmpty && switchedDisplay.first?.facts.badgeLabels().isEmpty == true
              && switchedDisplay.first?.facts.installation == .installed(game.folder),
              "REQ-50: Account-switch late completion cannot restore old access; current UI retains only unqualified installed facts")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InstalledAccessChecks-\(UUID().uuidString)")
        let config = BackendConfiguration(executable: URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("XodusManagementChecks"),
            stateDirectory: root.appendingPathComponent("odeslow"))
        let session = LiveSession(configuration: config)
        await session.connect()
        await session.refreshAccount()
        await session.refreshAccountCountry()
        let license = Task { try await session.readUnifiedAccount(.license, productID: product) }
        try await Task.sleep(for: .milliseconds(40))
        let profile = try await session.readUnifiedAccount(.profile)
        let wire = try await license.value
        try wire.payload.decode(OdeProductAccess.self).validate(productID: product, checkedAt: wire.checkedAt)
        check(profile.section == .profile && wire.section == .license && !session.accountBusy,
              "Real Swift wire validator accepts license facts; profile waits instead of failing behind a background read")
        for (section, id) in [(OdeAccountSection.library, product), (.license, "invalid")] {
            do {
                _ = try await session.readUnifiedAccount(section, productID: id)
                check(false, "Invalid or cross-section product identity is rejected before management dispatch")
            } catch {
                check(true, "Invalid or cross-section product identity is rejected before management dispatch")
            }
        }
        check(await session.disconnect(), "Synthetic license wire child is joined")
        try FileManager.default.removeItem(at: root)
        await postInstallChecks(check: check)
    }

    static func postInstallChecks(check: (Bool, String) -> Void) async {
        let account = String(repeating: "a", count: 64)
        let existing = "9NGLST31DG26"
        let installed = "9NX6K9HN4F4K"
        let now = Date()
        let access = InstalledProductAccess()
        defer { access.retire() }
        var requests: [String] = []
        let reader: @MainActor (String) async throws -> OdeAccountRead = { id in
            requests.append(id)
            try await Task.sleep(for: .milliseconds(150))
            let payload: [String: Any] = [
                "section": "license", "accountHash": account,
                "checkedAt": ISO8601DateFormatter().string(from: now),
                "payload": ["productID": id, "access": "permitted", "reason": NSNull(), "expiresAt": NSNull()]
            ]
            return try JSONDecoder().decode(OdeAccountRead.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let scan = Task { await access.refresh(account: account, installedIDs: [existing], now: now, read: reader) }
        try? await Task.sleep(for: .milliseconds(40))
        // Library publishes the freshly installed title while the earlier scan is still running.
        await access.refresh(account: account, installedIDs: [existing, installed], now: now, read: reader)
        await scan.value
        check(requests == [existing, installed] && access.permits(installed, account: account, now: now),
              "REQ114 post-install: a title installed during an access scan is checked automatically, so Play enables without Retry")
    }
}
