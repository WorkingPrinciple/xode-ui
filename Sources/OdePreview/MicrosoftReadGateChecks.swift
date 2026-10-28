// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OdeManagement

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
        try await reconcileNegatives(check: check)
        lateLibraryAnswer(check: check)
        try await playJoinsAutomaticOperation(check: check)
        try await provisionalCountryVersusPlay(check: check)
    }

    /// 908606e9 n2: a library read for the previous account that answers late (throttled) leaves the gate alone.
    private static func lateLibraryAnswer(check: (Bool, String) -> Void) {
        let library = PCGamesController()
        let previous = String(repeating: "c", count: 64)
        library.recordThrottle(after: ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: previous)
        let ignored = library.readGate.account == nil && library.readGate.throttledUntil == nil
        library.recordThrottle(after: ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90))
        let currentRecorded = library.readGate.throttledUntil != nil
        check(ignored && currentRecorded,
              "908606e9 n2: a late library answer for another account leaves the gate untouched; the current account's answer feeds it")
    }

    /// 2bf5e681 m2: what must NOT clear the licence store's sign-in rejection; then the one thing that does.
    private static func reconcileNegatives(check: (Bool, String) -> Void) async throws {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let product = "9NREJECT0001"
        func rejectedStore(_ gate: MicrosoftReadGate) async -> InstalledProductAccess {
            let store = InstalledProductAccess()
            store.bindSignInCount { gate.signIns(for: $0) }
            await store.refresh(account: a, installedIDs: [product], force: true, selectedProductID: product) { _ in
                gate.record(ManagementError.authenticatedReadFailed(.authExchangeFailed), account: a)
                throw ManagementError.authenticatedReadFailed(.authExchangeFailed)
            }
            return store
        }
        var lines: [String] = []
        var allHeld = true
        func expectHeld(_ name: String, _ store: InstalledProductAccess) {
            let held = store.signInRejected && store.pausedNotice() != nil
            allHeld = allHeld && held
            lines.append("\(name) \(held ? "held" : "CLEARED")")
        }
        do { // gate signed in for a different account
            let gate = MicrosoftReadGate(); let store = await rejectedStore(gate)
            gate.signedIn(account: b)
            store.reconcileSignIn(gate: gate, account: a); store.reconcileSignIn(gate: gate, account: b)
            expectHeld("different account", store)
        }
        do { // gate still rejected
            let gate = MicrosoftReadGate(); let store = await rejectedStore(gate)
            store.reconcileSignIn(gate: gate, account: a)
            expectHeld("gate still rejected", store)
        }
        do { // gate signed out
            let gate = MicrosoftReadGate(); let store = await rejectedStore(gate)
            gate.signedOut()
            store.reconcileSignIn(gate: gate, account: a)
            expectHeld("gate signed out", store)
        }
        do { // gate rebound by throttle records (B, then A again): rejection gone from the gate, no sign-in
            let gate = MicrosoftReadGate(); let store = await rejectedStore(gate)
            gate.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: b)
            gate.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: a)
            let gateCleared = gate.account == a && !gate.signInRejected
            store.reconcileSignIn(gate: gate, account: a)
            expectHeld("gate rebound by throttle (gate rejection gone \(gateCleared))", store)
        }
        do { // a sign-in completed BEFORE the rejection doesn't count
            let gate = MicrosoftReadGate(); gate.signedIn(account: a)
            let store = await rejectedStore(gate)
            gate.recordSuccess(account: a)
            store.reconcileSignIn(gate: gate, account: a)
            expectHeld("earlier sign-in only", store)
        }
        let gate = MicrosoftReadGate(); let store = await rejectedStore(gate)
        gate.signedIn(account: a)
        store.reconcileSignIn(gate: gate, account: a)
        let clears = !store.signInRejected && store.pausedNotice() == nil
        check(allHeld && clears,
              "2bf5e681 m2: the store's sign-in rejection survives another account's sign-in, a still-rejected gate, a sign-out, a rebind by throttle records and an earlier sign-in; only a sign-in completed after the rejection for that account clears it (\(lines.joined(separator: ", ")); after sign-in \(clears ? "cleared" : "held"))")
    }

    /// c71aada6 minor-4: a Play that joins a running automatic licence operation reads as an explicit action, even
    /// after the gate is held; the operation's own automatic reads are refused at the boundary.
    private static func playJoinsAutomaticOperation(check: (Bool, String) -> Void) async throws {
        let account = String(repeating: "a", count: 64)
        let gate = MicrosoftReadGate()
        let installed = (0..<4).map { String(format: "9GATE%07d", $0) }
        let played = installed[3]
        var sent: [String] = [], refused: [String] = []
        let read: @MainActor (String) async throws -> OdeAccountRead = { id in
            do { try gate.admit(account: account) } catch { refused.append(id); throw error }
            sent.append(id)
            try await Task.sleep(for: .milliseconds(200))
            let payload: [String: Any] = ["section": "license", "accountHash": account,
                "checkedAt": "2030-01-01T00:00:00Z",
                "payload": ["productID": id, "access": "permitted", "reason": NSNull(), "expiresAt": NSNull()]]
            return try JSONDecoder().decode(OdeAccountRead.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let store = InstalledProductAccess()
        // An automatic operation (no explicit context) checks the installed games one by one.
        let sweep = Task { @MainActor in
            await MicrosoftReadContext.automatic {
                Task { @MainActor in await store.refresh(account: account, installedIDs: installed, read: read) }
            }.value
        }
        try await Task.sleep(for: .milliseconds(60))
        let firstInFlight = store.inFlightID == installed[0]
        gate.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: account)
        // Play joins the running operation once (the production Play path is explicit).
        await MicrosoftReadContext.explicit {
            await store.prioritize(played, account: account, installedIDs: installed, read: read)
        }
        let joined = sent == [installed[0]]
        await sweep.value
        check(firstInFlight && joined && store.facts[played] != nil && sent == [installed[0], played]
              && Set(refused) == Set(installed[1...2]),
              "c71aada6 minor-4: Play joining an automatic licence operation reads as Play (explicit) while the gate is held; the operation's automatic reads are refused (sent \(sent), refused \(refused))")
    }

    /// c71aada6 minor-5: the provisional country re-check never fails a Play licence read.
    private static func provisionalCountryVersusPlay(check: (Bool, String) -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ode-gate-country-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = BackendConfiguration(executable: URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("OdeManagementChecks"),
            stateDirectory: root.appendingPathComponent("odeslow"))
        let suite = "ode-gate-country-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "Country defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = String(repeating: "a", count: 64)
        defaults.set("US", forKey: LiveSession.lastVerifiedCountryKey(account))
        let session = LiveSession(configuration: config, countryDefaults: defaults)
#if !ODE_SHIPPING
        session.checksAdmitLifecycleExecutable = true
#endif
        await session.connect()
        await session.refreshAccount()
        session.applyProvisionalAccountCountry()
        // Wait until the provisional re-check's profile read (0.3 s on this child) holds the account operation.
        for _ in 0..<100 where !session.accountCountryChecking || !session.accountBusy {
            try await Task.sleep(for: .milliseconds(5))
        }
        let recheckInFlight = session.accountCountryChecking && session.accountBusy
        // Play's licence read, entering directly while the re-check holds the account operation.
        var direct: Result<OdeAccountRead, Error>?
        do {
            direct = .success(try await MicrosoftReadContext.explicit {
                try await session.readUnifiedAccount(.license, productID: "9NBLGGH4R315")
            })
        } catch { direct = .failure(error) }
        let directOK = (try? direct?.get())?.section == .license
        // And through the production Play path while another re-check runs.
        let access = InstalledProductAccess()
        let countryRecheck = Task { @MainActor in await session.refreshAccountCountry() }
        try await Task.sleep(for: .milliseconds(20))
        await MicrosoftReadContext.explicit {
            await access.prioritize("9NBLGGH4R316", session: session, installedIDs: ["9NBLGGH4R316"])
        }
        for _ in 0..<200 where access.checking { try await Task.sleep(for: .milliseconds(10)) }
        await countryRecheck.value
        check(recheckInFlight && directOK && access.facts["9NBLGGH4R316"] != nil && access.errors.isEmpty
              && session.accountCountryVerified,
              "c71aada6 minor-5: a provisional country re-check in flight never fails a Play licence read; the licence read waits and succeeds, and the country is still confirmed (re-check in flight \(recheckInFlight), direct \(directOK), facts \(access.facts.count), errors \(access.errors), verified \(session.accountCountryVerified), ready \(session.accountCountryReady), lifecycle \(session.nativeLifecycleConfiguration != nil))")
        check(await session.disconnect(), "c71aada6 minor-5: country/Play management child is joined")
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
        // 63685916 Nit-B: after A→B, a late answer for A (throttled or success) leaves B's gate untouched.
        let switched = MicrosoftReadGate()
        switched.clock = { now }
        switched.record(ManagementError.authenticatedReadFailed(.authExchangeFailed), account: a, current: a)
        switched.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 90), account: b, current: b)
        let bUntil = switched.throttledUntil
        switched.record(ManagementError.authenticatedReadThrottled(retryAfterSeconds: 900), account: a, current: b)
        switched.record(ManagementError.authenticatedReadFailed(.authExchangeFailed), account: a, current: b)
        switched.recordSuccess(account: a, current: b)
        check(switched.account == b && switched.throttledUntil == bUntil && bUntil != nil && !switched.signInRejected
              && !switched.allowsAutomaticRead(account: b) && switched.allowsAutomaticRead(account: a),
              "63685916 Nit-B: after switching A→B, a late throttle, rejection or success for A leaves B's gate untouched (LiveSession feeds the gate through record(_:account:current:))")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ode-read-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = BackendConfiguration(executable: URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("OdeManagementChecks"),
            stateDirectory: root.appendingPathComponent(scenario))
        let suite = "ode-read-gate-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { check(false, "Read-gate defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = LiveSession(configuration: config, countryDefaults: defaults)
        // The product-page row needs the native lifecycle; the synthetic child is admitted for checks only.
#if !ODE_SHIPPING
        session.checksAdmitLifecycleExecutable = true
#endif
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
        // Bound to this account and scope as after earlier use (no product given, so no read).
        let beforeBinding = outbound()
        await access.refresh(session: session, installedIDs: [])
        check(outbound() == beforeBinding, "d270a2c5 \(scenario): binding the licence store reads nothing")
        let product = "9NBLGGH4R315", title = "1915865634"
        var lifecycleNote = ""
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
                await access.checkProduct(product, session: session)
                lifecycleNote = "ready \(session.accountCountryReady) lifecycle \(session.nativeLifecycleConfiguration != nil) checking \(access.checking) facts \(access.facts.count) errors \(access.errors) paused \(access.pausedNotice() ?? "-")" },
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
            // c71aada6 minor-1: no dead rows; each trigger reads exactly once after the window.
            allAfter = allAfter && after == 1
            lines.append("\(row.trigger) [\(row.source)]: held \(during), after \(after)\(row.trigger.hasPrefix("licence product") ? " (\(lifecycleNote))" : "")")
        }
        check(allHeld && allAfter,
              "d270a2c5 \(scenario) matrix: 0 outbound Microsoft reads per automatic trigger while held, exactly 1 after — " + lines.joined(separator: "; "))

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
        // c71aada6 minor-2: the licence store sees the scope change while confirmation is lost and again after it
        // returns; its own pause (and rejection) for this account survive both.
        let storePausedBefore = access.pausedNotice() != nil
        await access.refresh(session: session, installedIDs: [])
        await session.connect()
        await session.refreshAccount()
        let reconnected = session.hasConfirmedSignIn && session.accountHash == account
        await access.refresh(session: session, installedIDs: [])
        let storePauseKept = storePausedBefore && access.pausedNotice() != nil && access.signInRejected == rejected
        check(storePauseKept,
              "c71aada6 minor-2 \(scenario): the licence store's pause\(rejected ? " and sign-in rejection" : "") survive the scope changes of a lost and regained confirmation")
        if rejected {
            // 63685916 Minor-A: once the session reports a completed sign-in for this account, the store's own
            // rejection and its pause clear at its next use; Play no longer shows "sign in again".
            session.readGate.signedIn(account: account)
            await access.refresh(session: session, installedIDs: [])
            check(!access.signInRejected && access.pausedNotice() == nil && access.tryAgainTitle() != "Sign in again in Account",
                  "63685916 Minor-A: a completed sign-in for the same account clears the licence store's sign-in rejection and pause (rejected \(access.signInRejected), notice \(access.pausedNotice() ?? "nil"))")
            session.readGate.record(ManagementError.authenticatedReadFailed(.authExchangeFailed), account: account)
        }
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
        // c71aada6 minor-1: positive control on the reconnected child; with the gate open each trigger reads once.
        let freshAccess = InstalledProductAccess()
        await freshAccess.refresh(session: session, installedIDs: [])
        let controls: [(String, @MainActor () async -> Void)] = [
            ("recent library for the new connection", { await session.loadRecentLibraryOnEntry() }),
            ("library appear", { await library.loadOnAppear() }),
            ("companion profile", { await companion.refresh(for: nil) }),
            ("licence product page", { await freshAccess.checkProduct(product, session: session) }),
            ("runtime prepare", { await session.prepareUnifiedRuntime() }),
        ]
        var controlLines: [String] = [], controlsRead = true
        for (name, trigger) in controls {
            openGate()
            let before = outbound()
            await trigger()
            await settle()
            let reads = outbound() - before
            controlsRead = controlsRead && reads == 1
            controlLines.append("\(name) \(reads)")
        }
        check(controlsRead,
              "c71aada6 minor-1 \(scenario): after the restart, with the gate open, each trigger reads exactly once (" + controlLines.joined(separator: ", ") + ")")
        check(await session.disconnect(), "d270a2c5 \(scenario): read-gate management child is joined")
    }
}
