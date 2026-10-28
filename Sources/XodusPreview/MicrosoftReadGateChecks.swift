// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

/// d270a2c5: the Microsoft read gate. Its rules, then every automatic trigger from the review's table, driven
/// through the real production entry points against a management child that answers every Microsoft read
/// throttled (or with a rejected sign-in). Outbound reads are counted from the child's own request log.
@MainActor
enum MicrosoftReadGateChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        rules(check: check)
        for scenario in ["odegate", "odegaterejected"] {
            try await matrix(scenario: scenario, check: check)
        }
    }

    private static func rules(check: (Bool, String) -> Void) {
        let gate = MicrosoftReadGate()
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        gate.clock = { now }
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        gate.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: a)
        gate.record(ManagementError.recentLibraryThrottled(retryAfterSeconds: 30), account: a)
        let largest = gate.throttledUntil == now.addingTimeInterval(90)
        gate.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: nil), account: a)
        let defaulted = gate.throttledUntil == now.addingTimeInterval(600)
        let otherAccountFree = gate.allowsAutomaticRead(account: b) && !gate.allowsAutomaticRead(account: a)
        check(largest && defaulted && otherAccountFree,
              "d270a2c5: the gate keeps the largest throttle (Microsoft's delay, or 10 min without one), keyed to one account; another account is never blocked")
        now = now.addingTimeInterval(601)
        let throttleExpired = gate.allowsAutomaticRead(account: a) && gate.throttledUntil == nil
        gate.record(ManagementError.authenticatedReadFailed(.authExchangeFailed), account: a)
        gate.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 5), account: a)
        now = now.addingTimeInterval(6)
        let rejectionOutlivesThrottle = !gate.allowsAutomaticRead(account: a) && gate.signInRejected
        gate.recordSuccess(account: a)
        let successKeepsRejection = gate.signInRejected
        gate.signedIn(account: a)
        let signInClears = !gate.signInRejected && gate.allowsAutomaticRead(account: a)
        gate.record(ManagementError.recentLibraryFailed(.authExchangeFailed), account: a)
        gate.record(ManagementError.authenticatedReadFailed(.authExchangeFailed), account: b)
        let accountChangeResets = gate.account == b && gate.allowsAutomaticRead(account: a) && !gate.allowsAutomaticRead(account: b)
        gate.record(ManagementError.recentLibraryThrottled(retryAfterSeconds: 90), account: b)
        gate.signedOut()
        let signOutClears = gate.account == nil && gate.allowsAutomaticRead(account: b) && !gate.signInRejected
        check(throttleExpired && rejectionOutlivesThrottle && successKeepsRejection && signInClears
              && accountChangeResets && signOutClears,
              "d270a2c5: throttle and sign-in rejection are separate; expiry clears only the throttle; the rejection clears only on sign-in, sign-out or another account")
        gate.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: a)
        var refusedAutomatic = false, explicitPassed = false, explicitTask = false
        do { try gate.admit(account: a) } catch { refusedAutomatic = error is MicrosoftReadsPaused }
        do { try MicrosoftReadContext.explicit { try gate.admit(account: a) }; explicitPassed = true } catch {}
        MicrosoftReadContext.explicit { explicitTask = MicrosoftReadContext.explicit }
        check(refusedAutomatic && explicitPassed && explicitTask && gate.refusedAutomaticReads == 1
              && LiveSession.describe(MicrosoftReadsPaused(message: gate.pauseMessage() ?? "")).hasPrefix("Microsoft is limiting requests"),
              "d270a2c5: the boundary refuses an automatic read while held and shows the pause copy; an explicit action passes")
        check(!PCGamesController.automaticRetryAllowed(after: MicrosoftReadsPaused(message: ""))
              && InstalledProductAccess.isLocalServiceFailure(MicrosoftReadsPaused(message: "")),
              "d270a2c5: a read refused by the gate never left this Mac: no Microsoft pause, no automatic retry")
    }

    private struct Row {
        let trigger: String
        let source: String
        let run: @MainActor () async -> Void
    }

    private static func matrix(scenario: String, check: (Bool, String) -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xodus-read-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = BackendConfiguration(executable: URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("XodusManagementChecks"),
            stateDirectory: root.appendingPathComponent(scenario))
        let suite = "xodus-read-gate-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "Read-gate defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = LiveSession(configuration: config, countryDefaults: defaults)
        await session.connect()
        await session.refreshAccount()
        guard session.hasConfirmedSignIn, let account = session.accountHash else {
            check(false, "d270a2c5 \(scenario): the synthetic account is signed in")
            return
        }
        let rejected = scenario == "odegaterejected"
        let traceURL = config.stateDirectory.appendingPathComponent("lifecycle.log")
        let microsoftCommands: Set<String> = ["ode.account.read.v1", "ode.runtime.verify.v1", "library.recent"]
        func outbound() -> Int {
            ((try? String(contentsOf: traceURL, encoding: .utf8)) ?? "").split(separator: "\n")
                .filter { microsoftCommands.contains(String($0)) }.count
        }
        var now = Date()
        session.readGate.clock = { now }
        func openGate() {
            if rejected { session.readGate.signedIn(account: account) }
            else { now = (session.readGate.throttledUntil ?? now).addingTimeInterval(1) }
            // Past the library's 60 s automatic de-duplication too.
            now = now.addingTimeInterval(61)
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

        // Armed by a real answer: the automatic provisional-country re-check (gate open) reads the profile once.
        defaults.set("US", forKey: LiveSession.lastVerifiedCountryKey(account))
        session.provisionalCountryRetryDelay = 1.2
        session.applyProvisionalAccountCountry()
        for _ in 0..<60 where session.readGate.allowsAutomaticRead(account: account) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let armedOutbound = outbound()
        let armed = !session.readGate.allowsAutomaticRead(account: account)
            && (rejected ? session.readGate.signInRejected : session.readGate.throttledUntil.map {
                abs($0.timeIntervalSince(now) - 90) < 1 } == true)
        check(armed && armedOutbound == 1 && session.accountCountryReady,
              "d270a2c5 \(scenario): a real \(rejected ? "rejected sign-in" : "throttled (90 s)") answer arms the gate (outbound \(armedOutbound))")
        // Its 60 s re-check timer fires while held.
        try await Task.sleep(for: .milliseconds(1400))
        check(outbound() == armedOutbound,
              "d270a2c5 \(scenario): the provisional country 60 s re-check timer makes no read while the gate is held (LiveSession.applyProvisionalAccountCountry)")

        let library = PCGamesController()
        library.useUnifiedAccount(session)
        let companion = XboxCompanionController()
        companion.useUnifiedAccount(session)
        let access = InstalledProductAccess()
        let product = "9NBLGGH4R315", title = "1915865634"
        let rows: [Row] = [
            Row(trigger: "library scene active", source: "LiveRootView .task(scenePhase) → refreshInBackground") {
                await library.refreshInBackground() },
            Row(trigger: "library on appear / account recovery", source: "LiveRootView → PCGamesController.loadOnAppear") {
                await library.loadOnAppear() },
            Row(trigger: "library account-scope change", source: "LiveRootView .task(accountCatalogScope)") {
                await library.retireUnifiedAccount(); await library.refreshInBackground() },
            Row(trigger: "companion profile on scene active / recovery", source: "LiveRootView → XboxCompanionController.refresh(for:)") {
                await companion.refresh(for: nil) },
            Row(trigger: "Account view appear (profile)", source: "LiveAccountView .task → companion.refresh(for:)") {
                await companion.refresh(for: nil) },
            Row(trigger: "recent library on entry", source: "XboxCompanion / AppState → loadRecentLibraryOnEntry") {
                await session.loadRecentLibraryOnEntry() },
            Row(trigger: "achievements on the title view", source: "XboxCompanionViews → loadAchievements(titleID:status:)") {
                await companion.loadAchievements(titleID: title, status: nil) },
            Row(trigger: "licence product page appear", source: "LiveProductView .task → checkProduct(_:session:)") {
                await access.checkProduct(product, session: session) },
            Row(trigger: "licence read reaching the boundary unmarked", source: "LiveSession.readUnifiedAccount(.license)") {
                _ = try? await session.readUnifiedAccount(.license, productID: product) },
            Row(trigger: "runtime verify (automatic prepare)", source: "LiveRootView → prepareUnifiedRuntime") {
                await session.prepareUnifiedRuntime() },
        ]
        var lines: [String] = []
        var allHeld = true, allAfter = true
        for row in rows {
            let before = outbound()
            await row.run()
            await settle()
            let during = outbound() - before
            openGate()
            let opened = outbound()
            await row.run()
            await settle()
            let after = outbound() - opened
            // A read after the window gets the same answer, which re-arms the gate for the next row.
            if session.readGate.allowsAutomaticRead(account: account) {
                session.readGate.record(rejected ? ManagementError.authenticatedReadFailed(.authExchangeFailed)
                    : ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: account)
            }
            allHeld = allHeld && during == 0
            allAfter = allAfter && after <= 1
            lines.append("\(row.trigger) [\(row.source)]: held \(during), after \(after)")
        }
        check(allHeld && allAfter,
              "d270a2c5 \(scenario) matrix: 0 outbound Microsoft reads per automatic trigger while held, at most 1 after — " + lines.joined(separator: "; "))

        if !rejected {
            // minor-2: a detail retry scheduled while open re-checks the gate when it fires.
            openGate()
            await library.refreshInBackground()
            await settle()
            session.readGate.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: account)
            openGate()
            library.scheduleDetailRetry(account: account)
            let scheduled = library.detailRetryPending
            session.readGate.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: account)
            let beforeFire = outbound()
            try await Task.sleep(for: .seconds(4.4))
            let fired = outbound() - beforeFire
            check(scheduled && fired == 0,
                  "d270a2c5 minor-2: a library detail retry that fires inside a new throttle window makes no read (scheduled \(scheduled), reads \(fired), retries left \(library.detailRetriesLeft), busy \(library.busy))")
        }

        // Explicit actions read once while held; their answer re-arms the gate.
        let beforeExplicit = outbound()
        let heldUntil = session.readGate.throttledUntil
        library.refresh()
        await library.waitForLoad()
        await session.reloadRecentLibrary()
        let explicitReads = outbound() - beforeExplicit
        let rearmed = !session.readGate.allowsAutomaticRead(account: account)
            && (rejected || session.readGate.throttledUntil.map { until in heldUntil.map { until >= $0 } ?? true } == true)
        check(explicitReads == 2 && rearmed && (library.error ?? "").contains(rejected ? "sign" : "limiting"),
              "d270a2c5 \(scenario): explicit Refresh and recent-activity Refresh each read once while held, show the pause copy, and re-arm the gate (reads \(explicitReads), library \(library.error ?? "nil"))")

        // MAJOR-1: a management restart (confirmed sign-in lost and regained) keeps the gate.
        let beforeRestart = outbound()
        let disconnected = await session.disconnect()
        let heldWhileDisconnected = !session.readGate.allowsAutomaticRead(account: account)
        await library.retireUnifiedAccount()
        access.retire(keepingPause: true)
        await session.connect()
        await session.refreshAccount()
        let reconnected = session.hasConfirmedSignIn && session.accountHash == account
        let restartBaseline = outbound()
        await session.loadRecentLibraryOnEntry()
        await library.loadOnAppear()
        await library.refreshInBackground()
        await companion.refresh(for: nil)
        await access.checkProduct(product, session: session)
        await session.prepareUnifiedRuntime()
        await settle()
        let afterRestart = outbound() - restartBaseline
        check(disconnected && heldWhileDisconnected && reconnected && afterRestart == 0
              && beforeRestart == restartBaseline && !session.readGate.allowsAutomaticRead(account: account),
              "d270a2c5 MAJOR-1 \(scenario): restarting the management child keeps the gate; recent library for the new connection, library appear/foreground, profile, product page and runtime make 0 reads (\(afterRestart))")
        check(await session.disconnect(), "d270a2c5 \(scenario): read-gate management child is joined")
    }
}
