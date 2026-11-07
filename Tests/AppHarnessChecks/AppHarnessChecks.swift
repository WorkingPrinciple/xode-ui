// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import XodusCredentials
import XodusManagement
@testable import XodusPreview

final class AppHarnessChecks: XCTestCase {
    @MainActor
    private func withSignInSession(
        _ scenario: String,
        bindUnifiedAccount: Bool = true,
        operation: (LiveSession, AppState, BackendConfiguration) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("REQ234-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "REQ234-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("XodusManagementChecks")
        let configuration = BackendConfiguration(
            executable: executable, stateDirectory: root.appendingPathComponent(scenario))
        let session = LiveSession(configuration: configuration, countryDefaults: defaults)
        let installed = InstalledGamesController(
            store: InstalledGameStore(file: root.appendingPathComponent("installed.json")))
        await installed.load()
        let library = PCGamesController()
        if bindUnifiedAccount { library.useUnifiedAccount(session) }
        let paths = GameScriptPaths(
            scripts: root.appendingPathComponent("scripts"), processed: root.appendingPathComponent("processed"),
            logs: root.appendingPathComponent("logs"), games: root.appendingPathComponent("games"),
            journal: root.appendingPathComponent("operation.json"))
        let state = AppState(installedGames: installed, pcGames: library, gameScriptPaths: paths)
        if bindUnifiedAccount { state.gameOperations.useUnifiedAccount(session) }
        await session.connect()
        await session.refreshAccount()
        do {
            try await operation(session, state, configuration)
        } catch {
            guard await session.disconnect() else { throw ManagementError.shutdownFailed }
            try FileManager.default.removeItem(at: root)
            throw error
        }
        guard await session.disconnect() else { throw ManagementError.shutdownFailed }
        try FileManager.default.removeItem(at: root)
    }

    private func authTrace(_ configuration: BackendConfiguration) throws -> [String] {
        try String(contentsOf: configuration.stateDirectory.appendingPathComponent("lifecycle.log"),
                   encoding: .utf8).split(separator: "\n").map(String.init).filter { $0.hasPrefix("auth.") }
    }

    @MainActor
    private func waitForAccountOperation(_ session: LiveSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !session.accountBusy {
            guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func testREQ234ExplicitRecoveryCleansSignedOutBeforeBeginning() async throws {
        try await withSignInSession("authgate") { session, state, configuration in
            XCTAssertEqual(session.currentCredentialState, .signedOut)
            XCTAssertFalse(session.needsAccountDisconnect)
            let recovery = Task { await state.recoverUnifiedSignIn(session: session) }
            try await self.waitForAccountOperation(session)
            await state.recoverUnifiedSignIn(session: session)
            await recovery.value
            XCTAssertEqual(try self.authTrace(configuration), ["auth.status", "auth.logout", "auth.begin"])
            XCTAssertTrue(session.signInPending)
            XCTAssertFalse(MicrosoftSignInGate.shared.available)
            let firstFlow = session.authentication?.flow?.flowID
            await state.cancelUnifiedSignIn(session: session)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
            await state.recoverUnifiedSignIn(session: session)
            XCTAssertNotEqual(session.authentication?.flow?.flowID, firstFlow)
            XCTAssertEqual(try self.authTrace(configuration),
                           ["auth.status", "auth.logout", "auth.begin", "auth.cancel", "auth.logout", "auth.begin"])
            await state.cancelUnifiedSignIn(session: session)
        }
    }

    @MainActor
    func testREQ234SignedOutStillRequiresLogoutAcknowledgement() async throws {
        try await withSignInSession("authgate") { session, _, configuration in
            let removed = await session.signOut()
            XCTAssertTrue(removed)
            XCTAssertEqual(try self.authTrace(configuration), ["auth.status", "auth.logout"])
            XCTAssertTrue(session.accountStatusCurrent)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
        }
    }

    @MainActor
    func testREQ234CleanupFailureBlocksRecovery() async throws {
        try await withSignInSession("uifailures") { session, state, configuration in
            await state.recoverUnifiedSignIn(session: session)
            XCTAssertEqual(try self.authTrace(configuration), ["auth.status", "auth.logout"])
            XCTAssertNotNil(session.accountError)
            XCTAssertFalse(session.accountStatusCurrent)
            XCTAssertFalse(state.unifiedSignInRequested)
            XCTAssertFalse(session.appSignOutComplete)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
        }
    }

    @MainActor
    func testREQ234BlockedCleanupIsVisibleAndDoesNotMutateAccount() async throws {
        try await withSignInSession("authgate") { session, state, configuration in
            try state.installedGames.reserveMutation(gameID: nil)
            defer { state.installedGames.releaseMutation() }
            await state.recoverUnifiedSignIn(session: session)
            XCTAssertEqual(try self.authTrace(configuration), ["auth.status"])
            XCTAssertNotNil(session.accountError)
            XCTAssertEqual(session.welcomeNotice, session.accountError)
            XCTAssertFalse(state.unifiedSignInRequested)
            XCTAssertEqual(session.currentCredentialState, .signedOut)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
        }
    }

    @MainActor
    func testREQ234BeginRequestErrorReleasesConsentGate() async throws {
        try await withSignInSession("beginfail") { session, _, _ in
            XCTAssertTrue(session.canSignIn)
            await session.beginSignIn()
            XCTAssertNotNil(session.accountError)
            XCTAssertFalse(session.accountBusy)
            XCTAssertFalse(session.accountStatusCurrent)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
            await session.refreshAccount()
            let removed = await session.signOut()
            XCTAssertTrue(removed, "Failed begin must not block explicit cleanup after a fresh status read")
        }
    }

    @MainActor
    func testREQ234TerminalBeginReleasesConsentGate() async throws {
        try await withSignInSession("failedflow") { session, _, _ in
            await session.beginSignIn()
            XCTAssertEqual(session.authentication?.flow?.state, .failed)
            XCTAssertFalse(session.accountBusy)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
        }
    }

    @MainActor
    func testREQ234RetiredBeginCannotPublishIntoReplacementConnection() async throws {
        try await withSignInSession("authgate") { session, _, _ in
            let beginning = Task { await session.beginSignIn() }
            try await self.waitForAccountOperation(session)
            let disconnected = await session.disconnect()
            XCTAssertTrue(disconnected)
            await session.connect()
            await session.refreshAccount()
            await beginning.value
            XCTAssertEqual(session.currentCredentialState, .signedOut)
            XCTAssertNil(session.authentication?.flow)
            XCTAssertFalse(session.accountBusy)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
        }
    }

    @MainActor
    func testREQ234OrdinaryReconnectPreservesSavedAccountWithoutLogout() async throws {
        try await withSignInSession("savedpermission") { session, _, configuration in
            XCTAssertTrue(session.hasConfirmedSignIn)
            let account = session.accountHash
            let disconnected = await session.disconnect()
            XCTAssertTrue(disconnected)
            await session.connect()
            await session.refreshAccount()
            XCTAssertTrue(session.hasConfirmedSignIn)
            XCTAssertEqual(session.accountHash, account)
            XCTAssertEqual(try self.authTrace(configuration), ["auth.status", "auth.status"])
        }
    }

    @MainActor
    func testREQ234RecoveryRefreshPreservesNewlyResolvedSavedAccount() async throws {
        try await withSignInSession("savedpermission") { session, state, configuration in
            let account = session.accountHash
            await session.refreshAccount()
            XCTAssertFalse(session.accountStatusCurrent)
            XCTAssertEqual(session.accountStatusError, .credentialStoreUnavailable)
            XCTAssertFalse(session.hasConfirmedSignIn)
            await state.recoverUnifiedSignIn(session: session)
            XCTAssertTrue(session.hasConfirmedSignIn)
            XCTAssertEqual(session.accountHash, account)
            XCTAssertEqual(try self.authTrace(configuration), ["auth.status", "auth.status", "auth.status"])
            XCTAssertFalse(state.unifiedSignInRequested)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
        }
    }

    @MainActor
    func testREQ234ExpiredRecoveryStillCleansBeforeBeginning() async throws {
        try await withSignInSession("expiredpermission") { session, state, configuration in
            XCTAssertEqual(session.currentCredentialState, .expired)
            await session.refreshAccount()
            XCTAssertFalse(session.accountStatusCurrent)
            await state.recoverUnifiedSignIn(session: session)
            XCTAssertEqual(try self.authTrace(configuration),
                           ["auth.status", "auth.status", "auth.status", "auth.logout", "auth.begin"])
            XCTAssertTrue(session.signInPending)
            await state.cancelUnifiedSignIn(session: session)
        }
    }

    @MainActor
    func testREQ234NegotiatedUnifiedRecoveryDoesNotRequireLegacySignOut() async throws {
        try await withSignInSession("odeempty", bindUnifiedAccount: false) { session, state, configuration in
            XCTAssertTrue(session.supports(.odeAccountRead))
            XCTAssertFalse(state.pcGames.usesUnifiedAccount)
            let removed = await session.signOut()
            XCTAssertTrue(removed)
            await state.recoverUnifiedSignIn(session: session)
            XCTAssertTrue(state.pcGames.usesUnifiedAccount)
            XCTAssertTrue(state.gameOperations.usesUnifiedAccount)
            XCTAssertTrue(session.appSignOutComplete)
            XCTAssertNil(state.gameOperations.serviceError)
            XCTAssertEqual(try self.authTrace(configuration), ["auth.status", "auth.logout", "auth.logout"])
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
        }
    }

    @MainActor
    func testREQ234NonUnifiedCleanupRefusalIdentifiesMissingLegacyHelper() async throws {
        try await withSignInSession("authgate", bindUnifiedAccount: false) { session, state, configuration in
            XCTAssertFalse(session.supports(.odeAccountRead))
            await state.recoverUnifiedSignIn(session: session)
            XCTAssertFalse(state.pcGames.usesUnifiedAccount)
            XCTAssertFalse(state.gameOperations.usesUnifiedAccount)
            XCTAssertEqual(try self.authTrace(configuration), ["auth.status"])
            XCTAssertEqual(session.accountError, state.gameOperations.serviceError)
            XCTAssertTrue(session.accountError?.contains("game-service sign-out helper") == true)
            XCTAssertFalse(session.appSignOutComplete)
            XCTAssertFalse(state.unifiedSignInRequested)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
        }
    }

    @MainActor
    func testREQ234AmbiguousBeginReplyRetainsGateUntilJoinedRetirement() async throws {
        try await withSignInSession("humanwait") { session, _, _ in
            XCTAssertTrue(session.canSignIn)
            await session.beginSignIn()
            XCTAssertFalse(session.signInPending)
            XCTAssertFalse(session.accountStatusCurrent)
            XCTAssertFalse(session.accountBusy)
            XCTAssertFalse(MicrosoftSignInGate.shared.available)
            XCTAssertTrue(session.signInOutcomeUnresolved)
            XCTAssertTrue(session.welcomeMessage.contains("Check status"))
            XCTAssertTrue(session.welcomeMessage.contains("reset the sign-in connection"))
            XCTAssertNotNil(session.accountError)
            await session.refreshAccount()
            XCTAssertFalse(MicrosoftSignInGate.shared.available,
                           "A status with no matching flow cannot resolve an ambiguous begin")
            await session.resetUnresolvedSignInConnection()
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
            XCTAssertFalse(session.signInOutcomeUnresolved)
            XCTAssertEqual(session.currentCredentialState, .signedOut)
            XCTAssertFalse(session.appSignOutComplete)
        }
    }

    @MainActor
    func testREQ234ExpiredFlowRequiresStopAcknowledgementBeforeGateRelease() async throws {
        try await withSignInSession("failedstage-expirycode") { session, _, _ in
            await session.beginSignIn()
            XCTAssertEqual(session.authentication?.flow?.error?.code, "AUTH_EXPIRED")
            XCTAssertFalse(MicrosoftSignInGate.shared.available)
            XCTAssertTrue(session.signInOutcomeUnresolved)
            await session.cancelSignIn()
            XCTAssertNotNil(session.accountError)
            XCTAssertFalse(MicrosoftSignInGate.shared.available,
                           "A cancellation response without the matching flow cannot establish stop acknowledgement")
            let retired = await session.disconnect()
            XCTAssertTrue(retired)
            XCTAssertTrue(MicrosoftSignInGate.shared.available)
        }
    }

    func testREQ234ForcedManagementExitDoesNotConfirmConsentCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("REQ234-forced-\(UUID().uuidString)")
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("XodusManagementChecks")
        let client = try ManagementClient()
        _ = try await client.connect(BackendConfiguration(
            executable: executable, stateDirectory: root.appendingPathComponent("retirefailed")))
        let exited = await client.close()
        XCTAssertTrue(exited)
        let orderly = await client.orderlyShutdownConfirmed
        XCTAssertFalse(orderly, "Forced direct-process exit cannot prove consent-worker cleanup")
        guard exited else { throw ManagementError.shutdownFailed }
        try FileManager.default.removeItem(at: root)
    }

    func testSandboxBrokerIssuesRotatesAndDeletesThroughAdapter() async throws {
        let broker = SandboxCredentialBroker()
        let direct = PCGamesMockStore("SYNTHETIC_DIRECT_MUST_NOT_BE_READ")
        let adapter = PCGamesCredentialStore(sandboxBroker: { try await broker.send($0) }, direct: direct)
        let initiallyPresent = try await adapter.contains()
        XCTAssertFalse(initiallyPresent)
        try await adapter.save("SYNTHETIC_INITIAL_REFRESH_TOKEN")
        let issued = try await adapter.read()
        XCTAssertEqual(issued, "SYNTHETIC_INITIAL_REFRESH_TOKEN")
        try await adapter.save("SYNTHETIC_ROTATED_REFRESH_TOKEN")
        let rotated = try await adapter.read()
        XCTAssertEqual(rotated, "SYNTHETIC_ROTATED_REFRESH_TOKEN")
        do {
            try await adapter.save("not-a-synthetic-token")
            XCTFail("Sandbox must refuse non-synthetic credentials")
        } catch {
            XCTAssertEqual(error as? PCGamesError, .credentialBrokerUnavailable)
        }
        try await adapter.delete()
        let remaining = try await adapter.read()
        XCTAssertNil(remaining)
        let reads = await direct.reads
        let writes = await direct.saved
        let deletions = await direct.deletions
        let presence = await direct.presenceChecks
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(deletions, 0)
        XCTAssertEqual(presence, 0)
    }

    func testSandboxBrokerAdapterFailsClosed() async throws {
        let direct = PCGamesMockStore("SYNTHETIC_DIRECT_MUST_NOT_BE_READ")
        let adapter = PCGamesCredentialStore(sandboxBroker: { _ in
            throw CredentialFailure.unavailable
        }, direct: direct)
        do {
            _ = try await adapter.read()
            XCTFail("Rejected sandbox broker must not fall back to direct storage")
        } catch {
            XCTAssertEqual(error as? PCGamesError, .credentialBrokerUnavailable)
        }
        let reads = await direct.reads
        let saves = await direct.saved
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(saves.isEmpty)
    }

    @MainActor
    func testSyntheticAuthenticatedScenariosWithoutApplicationStartup() async throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("XodusManagementChecks")
        let passed = try await AuthenticatedScenarioChecks.run(managementExecutable: executable)
        XCTAssertTrue(passed)
    }

    func testScenarioArgumentsFailClosed() {
        for mode in ["--authenticated-scenario-runner", "--settings-accessibility-check",
                     "--real-account-scenario-runner"] {
            XCTAssertTrue(DevelopmentArguments.accepts([mode]))
            XCTAssertFalse(DevelopmentArguments.accepts([mode, "--fixture"]))
            XCTAssertFalse(DevelopmentArguments.accepts(["--fixture", mode]))
        }
    }

    func testOperatorAvailabilityFailsClosed() {
        var reads = 0
        var warnings = 0
        for (input, output) in [(false, false), (false, true), (true, false)] {
            XCTAssertFalse(OperatorAvailabilityGate.confirm(
                stdinInteractive: input, stderrInteractive: output,
                warn: { warnings += 1 }, readResponse: { reads += 1; return "YES" }))
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(warnings, 0)
        for response in [nil, Optional(""), Optional("no"), Optional("yes later")] {
            XCTAssertFalse(OperatorAvailabilityGate.confirm(
                stdinInteractive: true, stderrInteractive: true,
                warn: { warnings += 1 }, readResponse: { response }))
        }
        XCTAssertTrue(OperatorAvailabilityGate.confirm(
            stdinInteractive: true, stderrInteractive: true,
            warn: { warnings += 1 }, readResponse: { " YES\n" }))
        XCTAssertEqual(warnings, 5)
    }
}
