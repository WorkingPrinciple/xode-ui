// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
import SwiftUI
import XodusManagement
import XodusCredentials

private actor PCGamesMockTransport: PCGamesTransport {
    var responses: [PCGamesHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [PCGamesHTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) throws -> PCGamesHTTPResponse {
        try Task.checkCancellation()
        requests.append(request)
        guard !responses.isEmpty else { throw PCGamesError.transport }
        return responses.removeFirst()
    }

    func append(_ more: [PCGamesHTTPResponse]) { responses += more }
}

private actor PCGamesMockStore: PCGamesRefreshStore {
    var token: String?
    private(set) var saved: [String] = []
    private(set) var reads = 0
    private(set) var deletions = 0
    var deletionFails = false
    var deletionWaits = false
    var requiresApproval = false
    var approvalFails = false
    var approvalWaits = false
    var retainsLegacy = false
    var legacyWasRetained = false
    private(set) var approvals = 0
    private(set) var presenceChecks = 0
    var presenceFailureStage: Int?
    var presenceDelay = false

    init(_ token: String? = nil) { self.token = token }
    func failPresence(at stage: Int, delayed: Bool = false) {
        presenceFailureStage = stage
        presenceDelay = delayed
    }
    func contains() async throws -> Bool {
        presenceChecks += 1
        if presenceDelay { try await Task.sleep(for: .milliseconds(100)) }
        if presenceFailureStage == 0 {
            presenceFailureStage = nil
            throw PCGamesError.credentialBrokerUnavailable
        }
        return token != nil
    }
    func read() -> String? { reads += 1; return token }
    func save(_ refreshToken: String) throws {
        try Task.checkCancellation()
        token = refreshToken
        saved.append(refreshToken)
    }
    func delete() async throws {
        deletions += 1
        if deletionWaits { try await Task.sleep(for: .milliseconds(150)) }
        if deletionFails { throw PCGamesError.keychain(-1) }
        token = nil
    }
    func delayDeletion() { deletionWaits = true }
    func refuseDeletion() { deletionFails = true }
    func allowDeletion() { deletionFails = false }
    func requireApproval(fails: Bool = false, waits: Bool = false, retainsLegacy: Bool = false) {
        requiresApproval = true
        approvalFails = fails
        approvalWaits = waits
        self.retainsLegacy = retainsLegacy
    }
    func migrationRequired() throws -> Bool {
        if presenceFailureStage == 1 {
            presenceFailureStage = nil
            throw PCGamesError.credentialBrokerUnavailable
        }
        return requiresApproval
    }
    func migrate() async throws {
        approvals += 1
        if approvalWaits { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        if approvalFails { throw PCGamesError.keychainApprovalCancelled }
        requiresApproval = false
        legacyWasRetained = retainsLegacy
    }
    func legacyRetained() throws -> Bool {
        if presenceFailureStage == 2 {
            presenceFailureStage = nil
            throw PCGamesError.credentialBrokerUnavailable
        }
        return legacyWasRetained
    }
}

private actor PCGamesMockSleeper {
    private(set) var intervals: [Duration] = []
    func sleep(_ value: Duration) { intervals.append(value) }
}

@MainActor
enum PCGamesChecks {
    static func checkAppSignOut(session: LiveSession, launcherAlreadySignedOut: Bool = false,
                               check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".xodus-app-signout-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PCGamesMockStore("neutral-app-sign-out")
        let library = PCGamesController(store: store, client: PCGamesClient(transport: PCGamesMockTransport([])))
        await library.restorePresence()
        let installed = InstalledGamesController(store: InstalledGameStore(file: root.appendingPathComponent("installed.json")))
        await installed.load()
        let paths = GameScriptPaths(scripts: root.appendingPathComponent("scripts"),
            processed: root.appendingPathComponent("processed"), logs: root.appendingPathComponent("logs"),
            games: root.appendingPathComponent("games"), journal: root.appendingPathComponent("operation.json"))
        for directory in [paths.scripts, paths.processed, paths.logs, paths.games] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        func signOutScript(_ receipt: String, command: GameScriptCommand = .serviceSignOut) throws {
            let script = paths.scripts.appendingPathComponent(command.file)
            let body = """
            #!/bin/bash
            umask 077
            printf '%s\\n' '\(receipt)' > '\(paths.processed.path)'/"$1.result.json"
            printf '0\\n' > '\(paths.processed.path)'/"$1.status"
            """
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            _ = try GameScriptFiles.script(command, paths: paths)
        }
        let state = AppState(installedGames: installed, pcGames: library, gameScriptPaths: paths)
        if launcherAlreadySignedOut {
            try signOutScript(
                #"{"serviceRunning":true,"signedIn":true,"accountHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
                command: .serviceStatus)
            state.gameOperations.refreshService()
            await state.gameOperations.waitForService()
            check(session.currentCredentialState == .signedOut && library.hasSavedSignIn
                  && state.gameOperations.serviceStatus?.signedIn == true && state.canSignOut(session: session),
                  "Confirmed signed-out launcher with saved library and game sign-ins admits the UI's consolidated removal action")
            check(session.accountJourneyTitle == "Not signed in to Xbox Live",
                  "App-only signed-out copy does not claim remaining Xbox and library sign-ins were removed")
        }
        try installed.reserveMutation(gameID: nil)
        let heldResult = await state.signOut(session: session)
        let heldDeletions = await store.deletions
        check(!heldResult && heldDeletions == 0 && session.hasConfirmedSignIn == !launcherAlreadySignedOut,
              "App sign-out refuses active game mutation before touching either credential owner")
        installed.releaseMutation()
        let unsupported = await state.signOut(session: session)
        let unsupportedDeletions = await store.deletions
        check(!unsupported && unsupportedDeletions == 0 && !session.appSignOutComplete
              && session.accountError?.contains("sign-out support is required") == true,
              "An older runtime without the admitted helper cannot claim logout or remove downstream sign-ins")
        await session.refreshAccount()
        try signOutScript(#"{"serviceRunning":false,"signedIn":false,"credentialsRemoved":false}"#)
        let indeterminate = await state.signOut(session: session)
        let indeterminateDeletions = await store.deletions
        check(!indeterminate && indeterminateDeletions == 0 && !session.appSignOutComplete
              && session.accountError?.contains("credential removal isn't confirmed") == true,
              "A stopped service without confirmed removal never clears the broker or launcher or claims full sign-out")
        await session.refreshAccount()
        try signOutScript(#"{"serviceRunning":false,"signedIn":false,"credentialsRemoved":true}"#)
        await store.refuseDeletion()
        let failed = await state.signOut(session: session)
        let retained = await store.token
        check(!failed && retained != nil && library.hasSavedSignIn
              && state.gameOperations.serviceSignOutConfirmed
              && session.accountError?.contains("launcher profile was not disconnected") == true
              && !installed.accountDisconnecting && !session.signingOut,
              "Broker deletion failure never claims launcher logout and releases joined sign-out holds")
        check(session.accountJourneyMessage.contains("Sign-out didn't finish")
              && session.accountJourneyMessage.contains("Some Xbox Live details may remain")
              && session.accountJourneyMessage.contains("Choose Sign in with Xbox Live")
              && session.accountError?.contains("launcher profile was not disconnected") == true,
              "Plain-language partial sign-out keeps its next action while retaining exact failure detail")
        await session.refreshAccount()
        check(session.hasConfirmedSignIn == !launcherAlreadySignedOut && state.canSignOut(session: session),
              "A failed app sign-out requires fresh status rather than pretending the launcher profile was removed")
        await store.allowDeletion()
        await store.delayDeletion()
        let signingOut = Task { await state.signOut(session: session) }
        for _ in 0..<100 {
            if session.signingOut { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(session.signingOut && installed.accountDisconnecting && !session.hasConfirmedSignIn
              && library.accountDisconnecting
              && !state.gameOperations.canStartMutation && !state.gameOperations.canSignIn
              && !state.gameOperations.canQuit && !state.canSignOut(session: session),
              "Awaited sign-out holds account, install, Play and Quit admission until both credential operations settle")
        library.refresh()
        library.signIn()
        check(!library.sheetPresented && library.accountDisconnecting,
              "The held library gate refuses refresh and sign-in before credential removal settles")
        for _ in 0..<100 {
            if await store.deletions == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let competing = PCGamesController(store: PCGamesMockStore(),
            client: PCGamesClient(transport: PCGamesMockTransport([])))
        competing.signIn()
        state.gameOperations.signInForGames()
        state.gameOperations.refreshService()
        check(!competing.sheetPresented && competing.error != nil && !state.gameOperations.serviceBusy,
              "Sign-out's shared gate prevents another Microsoft prompt or game-service request during awaited removal")
        do {
            try installed.reserveMutation(gameID: nil)
            check(false, "An installation cannot reserve mutation while account disconnect is held")
        } catch { check(true, "An installation cannot reserve mutation while account disconnect is held") }
        let duplicate = await state.signOut(session: session)
        let duplicateLauncher = await session.signOut()
        let result = await signingOut.value
        let deletions = await store.deletions
        let removed = await store.token
        check(result && !duplicate && !duplicateLauncher && deletions == 2 && removed == nil
              && !library.hasSavedSignIn && !session.hasConfirmedSignIn && session.accountError == nil
              && session.appSignOutComplete && state.gameOperations.serviceSignOutConfirmed
              && !installed.accountDisconnecting && !library.accountDisconnecting
              && MicrosoftSignInGate.shared.available,
              "One explicit app sign-out coordinates broker then launcher removal; duplicate requests neither delete twice nor restore auth")
        let reopenedLibrary = PCGamesController(store: store, client: PCGamesClient(transport: PCGamesMockTransport([])))
        await reopenedLibrary.loadOnAppear()
        await session.revalidateAccountOnForeground()
        check(!reopenedLibrary.hasSavedSignIn && !reopenedLibrary.busy
              && session.currentCredentialState == .signedOut && !session.hasConfirmedSignIn
              && session.welcomeMessage.contains("signed out of Xbox Live on this Mac"),
              "Recreated library and fresh launcher status remain signed out after all three confirmed removals")
        check(session.accountJourneyTitle == "Signed out of Xbox Live"
              && session.accountJourneyMessage == "You're signed out of Xbox Live on this Mac. Your installed games and saves remain."
              && LiveSession.signOutConfirmationMessage.contains("other apps and Microsoft browser sessions stay unchanged"),
              "Confirmed sign-out copy is concise and keeps the before-action privacy boundary explicit")
    }

    private static func unifiedAccountChecks(check: (Bool, String) -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OdeAccountChecks-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Unified-account synthetic traces are cleaned") }
        }
        for scenario in ["odeempty", "odemismatch", "odefailure", "odeslow"] {
            let config = BackendConfiguration(executable: URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("XodusManagementChecks"),
                stateDirectory: root.appendingPathComponent(scenario))
            let session = LiveSession(configuration: config)
            let store = PCGamesMockStore("legacy-must-not-be-read")
            let transport = PCGamesMockTransport([])
            let library = PCGamesController(store: store, client: PCGamesClient(transport: transport))
            await session.connect()
            await session.refreshAccount()
            check(session.hasConfirmedSignIn && session.supports(.odeAccountRead),
                  "Unified account negotiates a saved backend identity without starting consent")
            library.useUnifiedAccount(session)
            await library.loadOnAppear()
            if scenario == "odeslow" {
                try await Task.sleep(for: .milliseconds(40))
                await library.retireUnifiedAccount()
                try await Task.sleep(for: .milliseconds(350))
                check(library.snapshot == nil && !library.busy && !library.hasSavedSignIn,
                      "Retiring a unified account joins its load and fences late results")
            } else {
                await library.waitForLoad()
                if scenario == "odeempty" {
                    check(library.accessIsCurrent && library.snapshot?.games.isEmpty == true
                          && library.accountHash == session.accountHash,
                          "A complete empty backend collection is current and identity-bound without a library login")
                    let traceFile = config.stateDirectory.appendingPathComponent("lifecycle.log")
                    let loadedTrace = try String(contentsOf: traceFile, encoding: .utf8)
                    await library.loadOnAppear()
                    check(try String(contentsOf: traceFile, encoding: .utf8) == loadedTrace,
                          "Automatically loaded empty results stay loaded on view re-entry without a manual load or duplicate API call")
                    let companion = XboxCompanionController()
                    companion.useUnifiedAccount(session)
                    await companion.refresh(for: nil)
                    check(companion.cache?.profile.value?.gamertag == "Fixture"
                          && companion.cache?.accountHash == library.accountHash,
                          "Profile loads from the same management account without a game-service session")
                    await companion.shutdown()
                    check(await library.signOut() == false,
                          "Unified library cannot independently remove legacy credentials or claim account logout")
                    check(await store.deletions == 0,
                          "Unified library sign-out leaves the unused legacy vault untouched")
                    let operations = GameOperationsController(installed: InstalledGamesController())
                    operations.useUnifiedAccount()
                    operations.signInForGames()
                    check(!operations.canSignIn && !operations.canStartMutation && !operations.serviceSigningIn,
                          "An unpaired runtime cannot trigger legacy consent or authorize game mutations")
                    let state = AppState(pcGames: library)
                    state.gameOperations.useUnifiedAccount()
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        let host = NSHostingView(rootView: LiveAccountView(refreshStatusOnAppear: false)
                            .environmentObject(state).environmentObject(session))
                        host.sizingOptions = []
                        host.appearance = NSAppearance(named: appearance)
                        host.frame = CGRect(x: 0, y: 0, width: 480, height: 480)
                        host.layoutSubtreeIfNeeded()
                        check(host.window == nil && !state.gameOperations.serviceBusy
                              && !session.accountBusy && !library.sheetPresented,
                              "The 480-point unified Account lays out without startup, legacy login or a detached window")
                    }
                } else {
                    check(library.snapshot == nil && library.error != nil && !library.accessIsCurrent,
                          "Rejected or mismatched unified data cannot become a successful empty library")
                    if scenario == "odefailure" {
                        check(library.error?.contains("Microsoft rejected access") == true,
                              "Unified authorization failure preserves its specific stage instead of becoming a generic login error")
                    }
                }
            }
            let reads = await store.reads
            let presence = await store.presenceChecks
            let writes = await store.saved
            let network = await transport.requests
            check(reads == 0 && presence == 0 && writes.isEmpty && network.isEmpty,
                  "Unified library never accesses the legacy vault, OAuth endpoints or public metadata for an empty result")
            let trace = try String(contentsOf: config.stateDirectory.appendingPathComponent("lifecycle.log"),
                                   encoding: .utf8).split(separator: "\n").map(String.init)
            check(!trace.contains("auth.begin") && trace.contains("ode.account.read.v1"),
                  "Unified account data reads never launch another interactive Microsoft login")
            check(await session.disconnect(), "Unified-account synthetic management child is joined")
        }
    }

    static func run(check: (Bool, String) -> Void) async throws {
        try await unifiedAccountChecks(check: check)
        func response(_ value: [String: Any], status: Int = 200) throws -> PCGamesHTTPResponse {
            PCGamesHTTPResponse(status: status, data: try JSONSerialization.data(withJSONObject: value))
        }
        func item(_ id: String, kind: String = "Game", status: String = "Active", trial: Bool = false) -> [String: Any] {
            ["productId": id, "productKind": kind, "status": status, "isTrial": trial,
             "ignoredProviderField": "not an entitlement"]
        }
        func page(_ items: [[String: Any]], cursor: String? = nil) throws -> PCGamesHTTPResponse {
            var value: [String: Any] = ["items": items]
            if let cursor { value["continuationToken"] = cursor }
            return try response(value)
        }
        func catalogProduct(_ id: String, platform: String = "Windows.Desktop", title: String = "Neutral Game") -> [String: Any] {
            ["ProductId": id,
             "LocalizedProperties": [["ProductTitle": title, "Images": [
                ["ImagePurpose": "Poster", "Uri": "//store-images.s-microsoft.com/image/poster", "Width": 100, "Height": 200],
                ["ImagePurpose": "BoxArt", "Uri": "//store-images.s-microsoft.com/image/square", "Width": 100, "Height": 100]]]],
             "DisplaySkuAvailabilities": [["Sku": ["Properties": ["Packages": [
                ["PlatformDependencies": [["PlatformName": platform]]]]]]]]]
        }
        func authResponses(uhs: String = "123", storeUHS: String = "123",
                           xid: String = "456") throws -> [PCGamesHTTPResponse] {
            [try response(["Token": "neutral-user", "DisplayClaims": ["xui": [["uhs": uhs]]]]),
             try response(["Token": "neutral-xbox", "DisplayClaims": ["xui": [["uhs": uhs, "xid": xid]]]]),
             try response(["Token": "neutral-store", "DisplayClaims": ["xui": [["uhs": storeUHS]]]])]
        }
        let first = "FIXTURE00001", second = "FIXTURE00002", third = "FIXTURE00003"
        let fixturePage = try page([item(first), item(first), item(second, status: "Expired"), item(third, trial: true)])
        let parsed = try JSONDecoder().decode(PCGamesCollectionPage.self, from: fixturePage.data)
        check(parsed.items.filter(\.isCandidate).map(\.productId) == [first, first],
              "S4: Only exact Game/Active/non-trial rows are candidates; dedupe happens across pages")
        let missingTrial = try response(["items": [["productId": first, "productKind": "Game", "status": "Active"]]])
        check(try JSONDecoder().decode(PCGamesCollectionPage.self, from: missingTrial.data).items.first?.isCandidate == true,
              "S4: Absent isTrial is not invented trial evidence")
        let alternateID = try response(["items": [["ProductId": first, "productKind": "Game", "status": "Active"]]])
        check(try JSONDecoder().decode(PCGamesCollectionPage.self, from: alternateID.data).items.first?.productId == first,
              "S4: Approved ProductId fallback preserves exact ID without guessing")
        for invalid: [String: Any] in [
            [:], ["items": NSNull()], ["items": "unexpected"],
            ["items": [], "continuationToken": 1]
        ] {
            do {
                _ = try JSONDecoder().decode(PCGamesCollectionPage.self, from: response(invalid).data)
                check(false, "S4: Malformed page structure is rejected")
            } catch { check(true, "S4: Malformed page structure is rejected") }
        }
        let incompleteItems = try response(["items": [
            ["productId": first, "productKind": "Game"],
            ["productId": first, "status": "Active"],
            ["productKind": "Game", "status": "Active"],
            ["productId": first, "productKind": 3, "status": "Active"],
            ["productId": first, "productKind": "Game", "status": false],
            ["productId": false, "productKind": "Game", "status": "Active"],
            ["productId": first, "productKind": "Game", "status": "Active", "isTrial": "false"],
            item(first)]])
        let lenient = try JSONDecoder().decode(PCGamesCollectionPage.self, from: incompleteItems.data)
        check(lenient.items.count == 8 && lenient.items.filter(\.isCandidate).count == 1,
              "S4: Missing/odd third-party item fields are not candidates; one row cannot fail a valid page")
        let transport = PCGamesMockTransport(try authResponses() + [
            page([item(first), item(second, kind: "Application"), item(third, trial: true)], cursor: "neutral-next"),
            page([item(first), item("FIXTURE00004"), item("FIXTURE00005"), item("FIXTURE00006")]),
            response(["Products": [catalogProduct(first),
                                   catalogProduct("FIXTURE00004", platform: "Xbox.One"),
                                   catalogProduct("FIXTURE00005", platform: "windows.desktop")]])])
        let snapshot = try await PCGamesClient(transport: transport).library(
            accessToken: "neutral-access", market: "GB", language: "en-GB")
        check(snapshot.games.map(\.id) == [first] && snapshot.excludedCount == 3,
              "S4: Hidden count includes only active non-trial Game candidates, never other products or trials")
        check(snapshot.games.first?.artwork?.url == "https://store-images.s-microsoft.com/image/square",
              "S4: Square BoxArt is preferred and protocol-relative approved art uses the existing validator")
        let requests = await transport.requests
        check(requests.count == 6 && requests.allSatisfy { $0.timeoutInterval == 30 && !$0.httpShouldHandleCookies },
              "S4: Exact bounded request chain uses no cookies or invented endpoint")
        let userBody = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data()) as? [String: Any]
        check((userBody?["Properties"] as? [String: String])?["RpsTicket"] == "d=neutral-access"
              && requests[0].value(forHTTPHeaderField: "x-xbl-contract-version") == "1",
              "S4: Xbox user auth uses the observed RPS d= access ticket and contract1")
        let xboxBody = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: Any]
        let storeBody = try JSONSerialization.jsonObject(with: requests[2].httpBody ?? Data()) as? [String: Any]
        check(xboxBody?["RelyingParty"] as? String == "http://xboxlive.com"
              && storeBody?["RelyingParty"] as? String == "http://mp.microsoft.com/",
              "S4: XSTS uses both exact relying parties including Store trailing slash")
        let collectionBody = try JSONSerialization.jsonObject(with: requests[3].httpBody ?? Data()) as? [String: Any]
        let nextBody = try JSONSerialization.jsonObject(with: requests[4].httpBody ?? Data()) as? [String: Any]
        check(collectionBody?["maxPageSize"] as? Int == 100 && collectionBody?["validityType"] as? String == "All"
              && collectionBody?["market"] as? String == "GB" && nextBody?["continuationToken"] as? String == "neutral-next"
              && requests[3].value(forHTTPHeaderField: "Authorization") == "XBL3.0 x=123;neutral-store"
              && requests[3].value(forHTTPHeaderField: "x-xbl-contract-version") == "2",
              "S4: Collections preserves query/page contract, bound account ticket and next continuation")
        let beneficiaries = collectionBody?["beneficiaries"] as? [[String: String]]
        check(beneficiaries?.first == ["identityType": "xuid", "identityValue": "456", "localTicketReference": "xodus"],
              "S4: Collection beneficiary comes only from the matched Xbox identity")
        check(requests[5].value(forHTTPHeaderField: "Authorization") == nil
              && requests[5].url?.host == "displaycatalog.mp.microsoft.com",
              "S4: Private token is never sent with public catalog or image requests")
        let mismatch = PCGamesMockTransport(try authResponses(storeUHS: "999"))
        do {
            _ = try await PCGamesClient(transport: mismatch).library(accessToken: "neutral", market: "US", language: "en-US")
            check(false, "S4: Identity mismatch prevents all collections reads")
        } catch {
            let requestCount = await mismatch.requests.count
            check(error as? PCGamesError == .identityMismatch && requestCount == 3,
                  "S4: Identity mismatch prevents all collections reads")
        }
        check(PCGamesError.xbox(2148916233) == .noXboxProfile
              && PCGamesError.xbox(2148916235) == .regionUnavailable
              && PCGamesError.xbox(2148916238) == .childAccount
              && PCGamesError.xbox(1) == .xboxSignIn,
              "S4: Xbox error codes map to specific safe product guidance")
        let xerr = PCGamesMockTransport([try response(["XErr": 2148916233, "Message": "secret provider text"], status: 401)])
        do {
            _ = try await PCGamesClient(transport: xerr).library(accessToken: "neutral", market: "US", language: "en-US")
            check(false, "S4: XErr is not raw provider text or successful empty Library")
        } catch { check(error as? PCGamesError == .noXboxProfile, "S4: XErr is not raw provider text or successful empty Library") }
        let partial = PCGamesMockTransport(try authResponses() + [page([item(first)], cursor: "next")])
        do {
            _ = try await PCGamesClient(transport: partial).library(accessToken: "neutral", market: "US", language: "en-US")
            check(false, "S4: Failed page never publishes an empty or partial successful Library")
        } catch {
            check(error as? PCGamesError == .incompleteCollection(1),
                  "S4: Failed page never publishes an empty or partial successful Library")
        }
        let repeated = PCGamesMockTransport(try authResponses() + [
            page([item(first)], cursor: "loop"), page([item(first)], cursor: "loop")])
        do {
            _ = try await PCGamesClient(transport: repeated).library(accessToken: "neutral", market: "US", language: "en-US")
            check(false, "S4: Repeated continuation is a failure, not a duplicate loop")
        } catch {
            check(error as? PCGamesError == .incompleteCollection(1), "S4: Repeated continuation is a failure, not a duplicate loop")
        }
        let capped = PCGamesMockTransport(try authResponses() + (0..<20).map { try page([], cursor: "next-\($0)") })
        do {
            _ = try await PCGamesClient(transport: capped).library(accessToken: "neutral", market: "US", language: "en-US")
            check(false, "S4: The complete-page ceiling is exactly20 and continuation cannot become empty success")
        } catch {
            let requestCount = await capped.requests.count
            check(error as? PCGamesError == .incompleteCollection(20) && requestCount == 23,
                  "S4: The complete-page ceiling is exactly20 and continuation cannot become empty success")
        }
        let ids = (0..<21).map { String(format: "FIXTURE%05d", $0) }
        let batches = PCGamesMockTransport(try authResponses() + [
            page(ids.map { item($0) }),
            response(["Products": ids.sorted().prefix(20).map { catalogProduct($0) }]),
            response(["Products": ids.sorted().suffix(1).map { catalogProduct($0) }])])
        let many = try await PCGamesClient(transport: batches).library(accessToken: "neutral", market: "US", language: "en-US")
        let batchRequests = await batches.requests.filter { $0.url?.host == "displaycatalog.mp.microsoft.com" }
        let batchSizes = batchRequests.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "bigIds" })?.value?.split(separator: ",").count
        }
        check(many.games.count == 21 && batchSizes == [20, 1], "S4: Catalog batches never exceed20 exact product IDs")
        let catalogFailure = PCGamesMockTransport(try authResponses() + [page([item(first)])])
        do {
            _ = try await PCGamesClient(transport: catalogFailure).library(accessToken: "neutral", market: "US", language: "en-US")
            check(false, "S4: Catalog failure cannot report a successful empty Library")
        } catch {
            check(error as? PCGamesError == .incompleteCatalog(0), "S4: Catalog failure cannot report a successful empty Library")
        }
        let completeEmpty = PCGamesMockTransport(try authResponses() + [page([])])
        let empty = try await PCGamesClient(transport: completeEmpty).library(accessToken: "neutral", market: "US", language: "en-US")
        let emptyRequestCount = await completeEmpty.requests.count
        check(empty.games.isEmpty && empty.excludedCount == 0 && emptyRequestCount == 4,
              "S4: Only a complete genuinely empty collection supplies an empty Library")
        let unresolved = PCGamesMockTransport(try authResponses() + [page([item("legacy-unresolved-id")])])
        let unresolvedLibrary = try await PCGamesClient(transport: unresolved).library(
            accessToken: "neutral", market: "US", language: "en-US")
        let unresolvedRequests = await unresolved.requests
        check(unresolvedLibrary.games.isEmpty && unresolvedLibrary.excludedCount == 1 && unresolvedRequests.count == 4,
              "S4: Non-catalog Game IDs are counted unresolved; they never enter guessed catalog calls")
        let incompleteTransport = PCGamesMockTransport(try authResponses() + [
            incompleteItems, response(["Products": [catalogProduct(first)]])])
        let incompleteShelf = try await PCGamesClient(transport: incompleteTransport).library(
            accessToken: "neutral", market: "US", language: "en-US")
        check(incompleteShelf.games.map(\.id) == [first] && incompleteShelf.excludedCount == 0,
              "S4: Incomplete unrelated rows do not fail the joined shelf or inflate hidden-game count")
        for uri in ["//evil.invalid/image/square", "http://store-images.s-microsoft.com/image/square",
                    "//store-images.s-microsoft.com/image/a?token=secret", "//store-images.s-microsoft.com/image/../file",
                    "//store-images.s-microsoft.com@evil.invalid/image/a"] {
            check(PCGamesClient.artwork(uri: uri, width: 100, height: 100, role: .boxArt) == nil,
                  "S4: Artwork rejects unapproved host/grammar without broadening the shared loader")
        }
        check(PCGamesClient.market(nil) == "US" && PCGamesClient.market("GB") == "GB"
              && PCGamesClient.market("gb&token=x") == "US"
              && PCGamesClient.language("en-GB") == "en-GB"
              && PCGamesClient.language("en-US&token=x") == "en-US",
              "S4: Locale query values are bounded; absent region usesUS")
        let deviceResponse = try response(["device_code": "neutral-device", "user_code": "ABCD-EFGH",
            "verification_uri": "https://www.microsoft.com/link", "expires_in": 900, "interval": 5])
        let tokenResponse = try response(["access_token": "neutral-access", "refresh_token": "neutral-refresh-rotated"])
        let completeResponses = [tokenResponse] + (try authResponses()) + [
            try page([item(first)]), try response(["Products": [catalogProduct(first)]])]
        for mode in ["accountChange", "revoked", "partial", "removed"] {
            let tail: [PCGamesHTTPResponse]
            switch mode {
            case "accountChange": tail = [tokenResponse] + (try authResponses(xid: "999"))
            case "revoked": tail = [try response(["error": "invalid_grant"], status: 400)]
            case "partial": tail = [tokenResponse] + (try authResponses()) + [
                try page([item(first)], cursor: "incomplete"), try response([:], status: 503)]
            default: tail = [tokenResponse] + (try authResponses()) + [try page([])]
            }
            let transport = PCGamesMockTransport(completeResponses + tail)
            let controller = PCGamesController(store: PCGamesMockStore("neutral-refresh"),
                                               client: PCGamesClient(transport: transport))
            await controller.restorePresence()
            controller.refresh()
            await controller.waitForOperation()
            check(controller.accessIsCurrent && controller.representedGames.map(\.id) == [first],
                  "SDD-LIB-06: complete account snapshot is the live qualified source before \(mode)")
            controller.refresh()
            check(!controller.accessIsCurrent,
                  "SDD-LIB-06: refresh in flight cannot authorize new installs")
            await controller.waitForOperation()
            if mode == "partial" {
                check(controller.snapshot?.games.map(\.id) == [first] && !controller.accessIsCurrent
                      && controller.error != nil && !controller.needsSignIn,
                      "SDD-LIB-06: failed paging retains last-complete representation with stale access")
            } else if mode == "removed" {
                check(controller.representedGames.isEmpty && controller.error == nil
                      && controller.snapshot?.games.isEmpty == true,
                      "SDD-LIB-03/06: completed removal replaces old access, not a failed empty refresh")
            } else {
                check(controller.needsSignIn && controller.snapshot == nil && controller.representedGames.isEmpty,
                      "SDD-LIB-03/06: \(mode) retires account A access rather than showing it as current")
            }
        }
        let pollingTransport = PCGamesMockTransport([
            deviceResponse, try response(["error": "authorization_pending"], status: 400),
            try response(["error": "slow_down"], status: 400), tokenResponse])
        let sleeper = PCGamesMockSleeper()
        let pollClient = PCGamesClient(transport: pollingTransport, sleep: { await sleeper.sleep($0) })
        let device = try await pollClient.deviceCode()
        let tokens = try await pollClient.poll(device)
        let intervals = await sleeper.intervals
        check(device.userCode == "ABCD-EFGH" && tokens.refresh == "neutral-refresh-rotated"
              && intervals == [.seconds(5), .seconds(5), .seconds(10)],
              "S4: Device-code polling handles pending and adds exactly5sec on slow_down")
        let oauthRequests = await pollingTransport.requests
        check(String(data: oauthRequests[0].httpBody ?? Data(), encoding: .utf8)?.contains(PCGamesClient.clientID) == true
              && oauthRequests.allSatisfy { $0.url?.host == "login.microsoftonline.com" && $0.url?.query == nil },
              "S4: OAuth credentials are form bodies, never argv/URL/query/log payloads")
        for (name, expected) in [("expired_token", PCGamesError.signInExpired), ("authorization_declined", .signInDeclined)] {
            let client = PCGamesClient(transport: PCGamesMockTransport([try response(["error": name], status: 400)]),
                                       sleep: { _ in })
            do { _ = try await client.poll(device); check(false, "S4: Device-code expiry/decline is explicit") }
            catch { check(error as? PCGamesError == expected, "S4: Device-code expiry/decline is explicit") }
        }
        let maliciousDevice = PCGamesMockTransport([try response(["device_code": "neutral", "user_code": "ABCD",
            "verification_uri": "https://evil.invalid/link", "expires_in": 900])])
        do {
            _ = try await PCGamesClient(transport: maliciousDevice).deviceCode()
            check(false, "S4: Browser verification target is an exact Microsoft link")
        } catch { check(error as? PCGamesError == .invalidResponse, "S4: Browser verification target is an exact Microsoft link") }
        let tooBig = PCGamesMockTransport([PCGamesHTTPResponse(status: 200, data: Data(repeating: 0, count: 4 * 1024 * 1024 + 1))])
        do {
            _ = try await PCGamesClient(transport: tooBig).deviceCode()
            check(false, "S4: Mock responses also enforce the4MiB ceiling")
        } catch { check(error as? PCGamesError == .responseTooLarge, "S4: Mock responses also enforce the4MiB ceiling") }
        let saved = PCGamesMockStore("neutral-refresh-old")
        let controllerTransport = PCGamesMockTransport([tokenResponse] + (try authResponses()) + [
            try page([item(first)]), try response(["Products": [catalogProduct(first)]])])
        let controller = PCGamesController(store: saved, client: PCGamesClient(transport: controllerTransport))
        let tierOperations = GameOperationsController(installed: InstalledGamesController())
        await controller.restorePresence()
        check(tierOperations.accountEntitlements(library: controller).tiers == [.unknown],
              "M10: saved credential presence without a current snapshot cannot claim Free or Owned")
        let readsBeforeRefresh = await saved.reads
        let requestsBeforeRefresh = await controllerTransport.requests
        check(controller.hasSavedSignIn && readsBeforeRefresh == 0 && requestsBeforeRefresh.isEmpty,
              "S4: Library entry checks only item presence; it does not read credentials or auto-query")
        let autoStore = PCGamesMockStore("neutral-auto-load")
        let autoTransport = PCGamesMockTransport([tokenResponse] + (try authResponses()) + [
            try page([item(first)]), try response(["Products": [catalogProduct(first)]])])
        let automatic = PCGamesController(store: autoStore, client: PCGamesClient(transport: autoTransport))
        await automatic.loadOnAppear()
        await automatic.waitForOperation()
        await automatic.loadOnAppear()
        let automaticReads = await autoStore.reads
        check(automatic.snapshot?.games.map(\.id) == [first] && automaticReads == 1 && !automatic.busy,
              "Library refresh loads known saved PC games once on appearance, without repeated account refresh")
        for stage in 0...2 {
            let retryStore = PCGamesMockStore("neutral-preserved-sign-in")
            await retryStore.failPresence(at: stage, delayed: true)
            let retryTransport = PCGamesMockTransport([tokenResponse] + (try authResponses()) + [
                try page([item(first)]), try response(["Products": [catalogProduct(first)]])])
            let retry = PCGamesController(store: retryStore, client: PCGamesClient(transport: retryTransport))
            let restoration = Task { await retry.loadOnAppear() }
            while !retry.restoringPresence { await Task.yield() }
            await retry.restorePresence()
            retry.signIn()
            retry.refresh()
            check(!retry.busy && !retry.accessIsCurrent,
                  "F3: Presence restoration deduplicates reentry and fences sign-in/library work")
            await restoration.value
            let failedChecks = await retryStore.presenceChecks
            let failedReads = await retryStore.reads
            let failedRequests = await retryTransport.requests
            check(retry.presenceUnavailable && !retry.hasSavedSignIn && !retry.needsSignIn
                  && retry.error == PCGamesError.credentialBrokerUnavailable.localizedDescription
                  && failedChecks == 1 && failedReads == 0 && failedRequests.isEmpty,
                  "F3: Failed presence/metadata stage \(stage) is unavailable, not signed out or partially admitted")
            retry.signIn()
            retry.refresh()
            check(!retry.busy, "F3: Unavailable presence cannot start OAuth or read a saved token")
            if stage == 0 { await retry.retryLibraryLoad() }
            else { await retry.loadOnAppear() }
            await retry.waitForOperation()
            let recoveredChecks = await retryStore.presenceChecks
            let recoveredReads = await retryStore.reads
            let removed = await retryStore.deletions
            check(!retry.presenceUnavailable && retry.error == nil && retry.accessIsCurrent
                  && retry.snapshot?.games.map(\.id) == [first] && recoveredChecks == 2
                  && recoveredReads == 1 && removed == 0,
                  "F3: Explicit retry or revisit recovers through the same store without deleting credentials")
            await retry.loadOnAppear()
            check(await retryStore.reads == 1, "F3: A recovered library is not automatically loaded twice")
        }
        let emptyStore = PCGamesMockStore()
        let emptyTransport = PCGamesMockTransport([])
        let emptyLibrary = PCGamesController(store: emptyStore, client: PCGamesClient(transport: emptyTransport))
        await emptyLibrary.retryLibraryLoad()
        let emptyRequests = await emptyTransport.requests
        check(!emptyLibrary.presenceUnavailable && !emptyLibrary.hasSavedSignIn && emptyLibrary.error == nil
              && !emptyLibrary.busy && emptyRequests.isEmpty,
              "F3: Confirmed absence remains distinct from unavailable pairing and makes no Microsoft requests")
        let migrationStore = PCGamesMockStore("neutral-legacy-retained")
        await migrationStore.requireApproval()
        let migrationTransport = PCGamesMockTransport([])
        let migrating = PCGamesController(store: migrationStore, client: PCGamesClient(transport: migrationTransport))
        await migrating.restorePresence()
        await migrating.loadOnAppear()
        migrating.refresh()
        migrating.signIn()
        let beforeApproval = await migrationStore.approvals
        let beforeMigrationReads = await migrationStore.reads
        let beforeMigrationRequests = await migrationTransport.requests
        check(migrating.hasSavedSignIn && migrating.needsKeychainApproval && !migrating.busy
              && beforeApproval == 0 && beforeMigrationReads == 0 && beforeMigrationRequests.isEmpty,
              "B6: Migration presence gates sign-in/refresh without reading a token or prompting at startup")
        migrating.approveKeychain()
        migrating.approveKeychain()
        await migrating.waitForOperation()
        let migrationCount = await migrationStore.approvals
        let migrationValue = await migrationStore.token
        let migrationRequests = await migrationTransport.requests
        check(!migrating.needsKeychainApproval && !migrating.approvingKeychain && !migrating.busy
              && migrating.hasSavedSignIn && migrationCount == 1 && migrationValue == "neutral-legacy-retained"
              && migrationRequests.isEmpty,
              "B6: One explicit approval preserves saved sign-in and does not automatically refresh Microsoft")
        let refusedStore = PCGamesMockStore("neutral-denied-retained")
        await refusedStore.requireApproval(fails: true)
        let refused = PCGamesController(store: refusedStore, client: PCGamesClient(transport: PCGamesMockTransport([])))
        await refused.restorePresence()
        refused.approveKeychain()
        await refused.waitForOperation()
        let refusedValue = await refusedStore.token
        check(refused.needsKeychainApproval && !refused.busy && !refused.approvingKeychain
              && refused.error == PCGamesError.keychainApprovalCancelled.localizedDescription
              && refusedValue == "neutral-denied-retained",
              "B6: Native approval refusal is visible and leaves the sign-in available for a later attempt")
        let waitingStore = PCGamesMockStore("neutral-cancel-retained")
        await waitingStore.requireApproval(waits: true)
        let waiting = PCGamesController(store: waitingStore, client: PCGamesClient(transport: PCGamesMockTransport([])))
        await waiting.restorePresence()
        waiting.approveKeychain()
        await waiting.cancelKeychainApproval()
        let waitingValue = await waitingStore.token
        check(waiting.needsKeychainApproval && !waiting.busy && !waiting.approvingKeychain
              && waiting.error != nil && waitingValue == "neutral-cancel-retained",
              "B6: Cancelling the owned migration fences late publication and preserves at least one saved copy")
        let retainedStore = PCGamesMockStore("neutral-broker-copy")
        await retainedStore.requireApproval(retainsLegacy: true)
        let retainedMigration = PCGamesController(store: retainedStore,
            client: PCGamesClient(transport: PCGamesMockTransport([])))
        await retainedMigration.restorePresence()
        retainedMigration.approveKeychain()
        await retainedMigration.waitForOperation()
        let retainedApprovals = await retainedStore.approvals
        check(retainedMigration.hasSavedSignIn && !retainedMigration.needsKeychainApproval
              && retainedMigration.legacyKeychainRetained && retainedMigration.error == nil && retainedApprovals == 1,
              "B6: A verified broker copy completes migration with an explicit retained-legacy notice, without retrying removal")
        let brokerRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("XodusCredentialRouteChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: brokerRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: brokerRoot) }
        let brokerPath = brokerRoot.appendingPathComponent("helper")
        let manifestPath = brokerRoot.appendingPathComponent("pin.json")
        let directStore = PCGamesMockStore("neutral-direct-only")
        let absentBroker = PCGamesCredentialStore(direct: directStore, executable: brokerPath, manifest: manifestPath)
        let directPresence = try await absentBroker.contains()
        let directRead = try await absentBroker.read()
        let absentMigration = try await absentBroker.migrationRequired()
        check(directPresence && directRead == "neutral-direct-only" && !absentMigration,
              "B6: Only a genuinely absent helper permits the existing direct refresh store")
        try Data("Neutral, nonexecutable helper fixture.".utf8).write(to: brokerPath)
        let rejectedDirect = PCGamesMockStore("neutral-must-not-fallback")
        let presentBroker = PCGamesCredentialStore(direct: rejectedDirect, executable: brokerPath, manifest: manifestPath)
        for operation in 0..<3 {
            do {
                if operation == 0 { _ = try await presentBroker.read() }
                if operation == 1 { try await presentBroker.save("neutral-not-saved") }
                if operation == 2 { try await presentBroker.delete() }
                check(false, "B6: An existing helper without approved metadata fails closed")
            } catch {
                check(error as? PCGamesError == .credentialBrokerUnavailable,
                      "B6: An existing helper without approved metadata fails closed")
            }
        }
        let rejectedReads = await rejectedDirect.reads
        let rejectedWrites = await rejectedDirect.saved
        let rejectedDeletes = await rejectedDirect.deletions
        check(rejectedReads == 0 && rejectedWrites.isEmpty && rejectedDeletes == 0,
              "B6: A rejected installed helper never reads, rotates or deletes via direct fallback")
        let rejectedLibrary = PCGamesController(store: presentBroker,
            client: PCGamesClient(transport: PCGamesMockTransport([])))
        await rejectedLibrary.loadOnAppear()
        await rejectedLibrary.retryLibraryLoad()
        let retryRejectedReads = await rejectedDirect.reads
        let retryRejectedWrites = await rejectedDirect.saved
        let retryRejectedDeletes = await rejectedDirect.deletions
        check(rejectedLibrary.presenceUnavailable && rejectedLibrary.error != nil
              && retryRejectedReads == 0 && retryRejectedWrites.isEmpty && retryRejectedDeletes == 0,
              "F3: Retrying rejected caller/pair metadata never repairs the broker or bypasses it")
        try JSONEncoder().encode(CredentialBrokerPin(sha256: String(repeating: "0", count: 64),
                                                    bytes: 1)).write(to: manifestPath)
        do {
            _ = try await presentBroker.contains()
            check(false, "B6: A mismatched frozen helper pin cannot start a child or become saved-sign-in evidence")
        } catch {
            check(error as? PCGamesError == .credentialBrokerUnavailable,
                  "B6: A mismatched frozen helper pin cannot start a child or become saved-sign-in evidence")
        }
        controller.refresh()
        await controller.waitForOperation()
        let savedRotations = await saved.saved
        check(controller.snapshot?.games.map(\.id) == [first] && controller.error == nil
              && savedRotations == ["neutral-refresh-rotated"],
              "S4: Only refresh tokens rotate into the mocked Keychain; access/XSTS remain memory-only")
        check(tierOperations.accountEntitlements(library: controller).tiers == [.owned],
              "M10: current held PC snapshot supplies the account's Owned tier")
        controller.refresh()
        check(tierOperations.accountEntitlements(library: controller).tiers == [.unknown],
              "M10: in-flight refresh cannot extend current account access")
        await controller.waitForOperation()
        check(controller.snapshot?.games.map(\.id) == [first] && controller.error != nil,
              "S4: Refresh failure retains the last complete snapshot with an explicit stale notice")
        check(tierOperations.accountEntitlements(library: controller).tiers == [.unknown],
              "M10: failed refresh preserves metadata but withdraws the current tier claim")
        await controller.signOut()
        let signedOutToken = await saved.token
        check(!controller.hasSavedSignIn && controller.snapshot == nil && signedOutToken == nil,
              "S4: Sign out removes the one app-owned refresh item and clears the account shelf")
        check(tierOperations.accountEntitlements(library: controller) == .signedOut,
              "M10: sign-out clears all account entitlement tiers")
        let deletionStore = PCGamesMockStore("neutral-retained-refresh")
        await deletionStore.refuseDeletion()
        let deletionController = PCGamesController(store: deletionStore, client: PCGamesClient(transport: PCGamesMockTransport([])))
        await deletionController.restorePresence()
        await deletionController.signOut()
        let retainedToken = await deletionStore.token
        check(deletionController.hasSavedSignIn && deletionController.error != nil && retainedToken != nil,
              "S4: Keychain deletion failure is visible and never claims a successful sign out")
        let newStore = PCGamesMockStore()
        let signInTransport = PCGamesMockTransport([deviceResponse, tokenResponse] + (try authResponses()) + [
            try page([item(first)]), try response(["Products": [catalogProduct(first)]])])
        let signing = PCGamesController(store: newStore,
            client: PCGamesClient(transport: signInTransport, sleep: { _ in }))
        signing.signIn()
        signing.signIn()
        await signing.waitForOperation()
        let newRotations = await newStore.saved
        let signInRequestCount = await signInTransport.requests.count
        check(signing.hasSavedSignIn && !signing.sheetPresented && signing.snapshot?.games.count == 1
              && newRotations == ["neutral-refresh-rotated"] && signInRequestCount == 7,
              "S4: One sign-in operation publishes an account-correct complete shelf and ignores duplicate starts")
        let cancelStore = PCGamesMockStore()
        let cancelledTransport = PCGamesMockTransport([deviceResponse, tokenResponse])
        let cancelled = PCGamesController(store: cancelStore,
            client: PCGamesClient(transport: cancelledTransport, sleep: { _ in try await Task.sleep(for: .seconds(60)) }))
        cancelled.signIn()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while cancelled.deviceCode == nil, cancelled.busy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        await cancelled.cancelSignIn()
        let cancelledSaves = await cancelStore.saved
        let cancelledRequestCount = await cancelledTransport.requests.count
        check(!cancelled.busy && !cancelled.sheetPresented && !cancelled.hasSavedSignIn
              && cancelledSaves.isEmpty && cancelledRequestCount == 1,
              "S4: Cancel stops polling and never commits a token or late shelf")
        let revokedStore = PCGamesMockStore("neutral-revoked-refresh")
        let revoked = PCGamesController(store: revokedStore, client: PCGamesClient(transport:
            PCGamesMockTransport([try response(["error": "invalid_grant", "error_description": "secret-shaped text"], status: 400)])))
        await revoked.restorePresence()
        revoked.refresh()
        await revoked.waitForOperation()
        check(revoked.needsSignIn && revoked.snapshot == nil
              && revoked.error == PCGamesError.signInRequired.localizedDescription,
              "S4: Revoked refresh requests fresh sign-in without exposing provider text or pretending empty Library")
        let terminatingStore = PCGamesMockStore()
        let terminating = PCGamesController(store: terminatingStore, client: PCGamesClient(
            transport: PCGamesMockTransport([deviceResponse, tokenResponse]),
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }))
        terminating.signIn()
        terminating.beginTermination()
        await terminating.waitForOperation()
        let terminatingSaves = await terminatingStore.saved
        check(!terminating.busy && !terminating.sheetPresented && terminatingSaves.isEmpty && terminating.snapshot == nil,
              "S4: Normal app termination fences sign-in and discards late personal publication without killing games")
        let imported = InstalledGame(id: UUID(), title: "Different local display name", identityName: "Neutral.Identity",
                                     version: "1.0.0.0", storeId: first, folder: "/neutral", launcher: "/neutral/script",
                                     importedAt: Date())
        check(PCGamesController.installedMatch(snapshot.games[0], in: [imported])?.id == imported.id
              && PCGamesController.installedMatch(PCGame(id: second, title: imported.title, artwork: nil), in: [imported]) == nil,
              "S4: Installed Play matches exact StoreId, never title/history/platform guesses")
        let harbor = PCGame(id: first, title: "Neutral Harbor", artwork: nil)
        let ridge = PCGame(id: second, title: "Neutral Ridge", artwork: nil)
        func publicProduct(_ id: String, title: String) throws -> CatalogProduct {
            try JSONDecoder().decode(CatalogProduct.self, from: response([
                "productID": id, "title": title, "market": "US", "language": "en-US",
                "source": "syntheticPublicSource", "checkedAt": "2026-01-01T00:00:00Z",
                "freshness": "live", "editions": [], "pcCatalogCandidate": true,
                "artwork": [], "artworkStatus": "absent"]).data)
        }
        let duplicate = try publicProduct(first, title: "Neutral Harbor Store")
        let storeOnly = try publicProduct(third, title: "Neutral Harbor Sequel")
        let joined = CatalogSearchResults(query: "  hArBoR  ", ownedGames: [harbor, ridge],
            storeProducts: [duplicate, storeOnly], gamePassProductIDs: [first, third])
        check(joined.ownedMatches.map(\.id) == [harbor.id] && joined.storeProducts.map(\.id) == [third],
              "B2: Case-insensitive owned title substring matches come first; exact Store duplicates are removed")
        check(joined.badge(for: first) == .owned && joined.badge(for: third) == .gamePass
              && joined.badge(for: "FIXTURE00004") == nil,
              "B2: Owned takes precedence; Game Pass requires loaded feed membership; unknown access has no badge")
        check(joined.ownedGame(for: first)?.id == harbor.id
              && PCGamesController.installedMatch(harbor, in: [imported])?.id == imported.id
              && PCGamesController.installedMatch(ridge, in: [imported]) == nil,
              "B2: Search-owned controls use the same exact Installed match as PC tiles")
        let absentOwned = CatalogSearchResults(query: "harbor", ownedGames: [],
            storeProducts: [duplicate], gamePassProductIDs: [])
        check(absentOwned.ownedMatches.isEmpty && absentOwned.badge(for: first) == nil,
              "B2: Unloaded or signed-out PC Library never invents Owned evidence")
        let emptySearch = CatalogSearchResults(query: "  ", ownedGames: [harbor],
            storeProducts: [duplicate], gamePassProductIDs: [])
        check(emptySearch.ownedMatches.isEmpty && emptySearch.storeProducts.count == 1
              && emptySearch.ownedGame(for: first)?.id == harbor.id,
              "B2: Empty-query discovery keeps its own shelf and can reuse an owned game's actions")
        let noStore = CatalogSearchResults(query: "ridge", ownedGames: [ridge],
            storeProducts: [], gamePassProductIDs: [])
        check(noStore.ownedMatches.map(\.id) == [ridge.id], "B2: Store failure/omission cannot hide a loaded owned title")
        let mortis = try publicProduct("9P861V1542BL", title: "Valor Mortis")
        let global = CatalogSearchResults(query: "mortis", ownedGames: [],
            storeProducts: [mortis], gamePassProductIDs: [mortis.id],
            gamePassProducts: [mortis, storeOnly])
        check(global.storeProducts.map(\.id) == ["9P861V1542BL"]
              && global.badge(for: mortis.id) == .gamePass && global.ownedMatches.isEmpty,
              "#40: mortis finds Valor Mortis once across Store and Game Pass without requiring library ownership")
        let passOnly = CatalogSearchResults(query: "MORTIS", ownedGames: [],
            storeProducts: [], gamePassProductIDs: [mortis.id], gamePassProducts: [mortis])
        check(passOnly.storeProducts.map(\.id) == [mortis.id],
              "#40: Loaded Game Pass matches survive a missing Store page without broadening unrelated results")
        let canonicalMortis = "https://www.xbox.com/ro-RO/games/store/valor-mortis/9p861v1542bl"
        let romanianScope = CatalogLocale.preferred(region: "RO", languages: ["en-US", "ro-RO"])
        let americanScope = CatalogLocale.preferred(region: "US", languages: ["en-US", "ro-RO"])
        check(romanianScope.market == "RO" && romanianScope.language == "ro-RO"
              && americanScope.market == "US" && americanScope.language == "en-US",
              "#40/#42: Live catalogue uses the device market and a matching preferred language, not hardcoded US prices or links")
        let offerNow = GameCompatibilityResult.parseDate("2026-10-22T12:00:00Z")!
        func commerceProduct(amount: String, sku: String = "full", action: String = "Purchase",
                             market: String = "RO", platform: String = "Windows.Desktop",
                             remediation: Bool = false, piRequired: Bool = false,
                             end: String = "2026-12-01T00:00:00Z") throws -> CatalogCommerce.Product {
            try JSONDecoder().decode(CatalogCommerce.Product.self, from: response([
                "ProductId": mortis.id,
                "DisplaySkuAvailabilities": [[
                    "Sku": ["SkuType": sku, "Properties": [
                        "Packages": [["PlatformDependencies": [["PlatformName": "Windows.Desktop"]]]]]],
                    "Availabilities": [[
                        "Actions": [action], "Markets": [market], "RemediationRequired": remediation,
                        "Conditions": ["StartDate": "2026-01-01T00:00:00Z", "EndDate": end,
                                       "ClientConditions": ["AllowedPlatforms": [["PlatformName": platform]]]],
                        "OrderManagementData": ["Price": [
                            "ListPrice": NSDecimalNumber(string: amount), "CurrencyCode": "RON", "IsPIRequired": piRequired]]
                    ]]
                ]]
            ]).data)
        }
        let paidPrice = CatalogCommerce.price(try commerceProduct(amount: "199.99"), market: "RO", now: offerNow)
        let freePrice = CatalogCommerce.price(try commerceProduct(amount: "0"), market: "RO", now: offerNow)
        let mixedOffers = CatalogCommerce.Product(ProductId: mortis.id, DisplaySkuAvailabilities:
            (try commerceProduct(amount: "199.99").DisplaySkuAvailabilities ?? [])
            + (try commerceProduct(amount: "0", sku: "trial").DisplaySkuAvailabilities ?? [])
            + (try commerceProduct(amount: "0", remediation: true).DisplaySkuAvailabilities ?? [])
            + (try commerceProduct(amount: "0", action: "License").DisplaySkuAvailabilities ?? []))
        check(CatalogCommerce.price(mixedOffers, market: "RO", now: offerNow)?.amount == Decimal(string: "199.99"),
              "#41: Mortis-style paid full offer plus trial, upsell and zero licensing rows remains paid, never free")
        check(paidPrice?.amount == Decimal(string: "199.99") && paidPrice?.currency == "RON"
              && paidPrice?.isFree(now: offerNow) == false && freePrice?.isFree(now: offerNow) == true,
              "#40/#41: Current full-PC public purchase offers preserve exact amount/currency; only a zero price is free")
        for product in [
            try commerceProduct(amount: "0", sku: "trial"),
            try commerceProduct(amount: "0", action: "License"),
            try commerceProduct(amount: "0", market: "US"),
            try commerceProduct(amount: "0", platform: "Windows.Xbox"),
            try commerceProduct(amount: "0", remediation: true),
            try commerceProduct(amount: "0", piRequired: true),
            try commerceProduct(amount: "-1"),
            try commerceProduct(amount: "0", end: "2026-10-21T00:00:00Z")
        ] {
            check(CatalogCommerce.price(product, market: "RO", now: offerNow) == nil,
                  "#41: Trial/licensing-only/wrong-market/console/upsell/payment/negative/expired offers cannot become a free full PC claim")
        }
        check(CatalogAcquisition.kind(licensed: false, gamePass: false, commerce: freePrice, now: offerNow) == .free
              && CatalogAcquisition.kind(licensed: false, gamePass: false, commerce: paidPrice, now: offerNow) == nil
              && CatalogAcquisition.kind(licensed: false, gamePass: false, commerce: nil, now: offerNow) == nil
              && CatalogAcquisition.kind(licensed: true, gamePass: true, commerce: freePrice, now: offerNow) == nil
              && CatalogAcquisition.kind(licensed: false, gamePass: true, commerce: paidPrice, now: offerNow) == .gamePass
              && CatalogAcquisition.kind(licensed: false, gamePass: false, commerce: freePrice,
                                         now: offerNow.addingTimeInterval(901)) == nil,
              "#41: Only unlicensed free/explicit Game Pass members offer external acquisition; paid/unknown/owned/stale free offers cannot purchase or claim")
        var consent = CatalogAcquisitionConsent()
        consent.confirm()
        check(consent.authorization == nil && !consent.isPresented,
              "#41: Unrequested confirmation cannot authorize a browser action")
        consent.request()
        check(consent.isPresented && consent.authorization == nil,
              "#41: Get first presents consent; it cannot resolve or open a page")
        consent.cancel()
        consent.confirm()
        check(consent.authorization == nil,
              "#41: Cancelled consent cannot authorize acquisition or browser opening")
        consent.request()
        consent.confirm()
        check(!consent.isPresented && consent.authorization != nil,
              "#41: Only explicit confirmation releases a single external-page authorization")
        consent.finish()
        consent.confirm()
        check(consent.authorization == nil,
              "#41: A finished external-page request cannot replay old consent or invent an entitlement")
        let linkTransport = PCGamesMockTransport([
            .init(status: 302, data: Data(), location: "https://www.microsoft.com/ro-ro/store/productId/9P861V1542BL?market=RO&locale=ro-RO"),
            .init(status: 302, data: Data(), location: canonicalMortis.replacingOccurrences(of: "www.xbox.com", with: "xbox.com")),
            .init(status: 301, data: Data(), location: canonicalMortis),
            .init(status: 200, data: Data("<link rel=\"canonical\" href=\"\(canonicalMortis)\">".utf8))
        ])
        let resolvedMortis = try await XboxProductLink.resolve(
            productID: mortis.id, market: "RO", language: "ro-RO", transport: linkTransport)
        let linkRequests = await linkTransport.requests
        check(resolvedMortis.absoluteString == canonicalMortis
              && linkRequests.count == 4
              && linkRequests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == nil }
              && linkRequests.first?.url?.query?.contains("locale=ro-RO") == true,
              "#42: Microsoft's ID resolver supplies the canonical slug/ID in the requested locale without credentials or title guessing")
        let englishRO = CatalogLocale.preferred(region: "RO", languages: ["en-US"])
        let englishTransport = PCGamesMockTransport([
            .init(status: 302, data: Data(), location: "https://www.microsoft.com/ro-ro/store/productId/9P861V1542BL?market=RO&locale=en-US"),
            .init(status: 302, data: Data(), location: canonicalMortis),
            .init(status: 200, data: Data("<link rel=\"canonical\" href=\"\(canonicalMortis)\">".utf8))
        ])
        let englishResolved = try await XboxProductLink.resolve(productID: mortis.id, market: englishRO.market,
            language: englishRO.language, transport: englishTransport)
        check(englishRO.market == "RO" && englishRO.language == "en-US"
              && englishResolved.absoluteString == canonicalMortis,
              "#42: English-only Romanian Macs accept Microsoft's actual market-correct ro-RO redirect, without fabricating a locale or switching price market")
        check(XboxProductLink.canonical(URL(string: canonicalMortis.lowercased())!,
              productID: mortis.id, market: "RO", language: "en-US")
              && !XboxProductLink.canonical(URL(string: canonicalMortis.replacingOccurrences(of: "ro-RO", with: "en-US"))!,
                  productID: mortis.id, market: "RO", language: "en-US"),
              "#42: Resolver-selected locale comparison ignores URL casing but still rejects a foreign price market for English-only Romanian Macs")
        for target in [
            "https://www.xbox.com/en-US/games/store/valor-mortis/9P861V1542BL",
            "https://www.xbox.com/ro-RO/games/store",
            "https://www.xbox.com/ro-RO/games/store/valor-mortis/FIXTURE00001",
            "https://www.xbox.com.evil.invalid/ro-RO/games/store/valor-mortis/9P861V1542BL"
        ] {
            let transport = PCGamesMockTransport([.init(status: 302, data: Data(), location: target)])
            do {
                _ = try await XboxProductLink.resolve(productID: mortis.id, market: "RO",
                                                      language: "ro-RO", transport: transport)
                check(false, "#42: Wrong-locale/product/host/store-root redirect must fail")
            } catch {
                check(error as? PCGamesError == .invalidResponse,
                      "#42: Wrong-locale/product/host/store-root redirect is rejected, not opened")
            }
        }
        let windows = NSApplication.shared.windows.count
        let neutralInstalled = InstalledGamesController()
        let neutralOperations = GameOperationsController(installed: neutralInstalled)
        for width in [CGFloat(700), CGFloat(1100)] {
            for approvalState in [refused, retainedMigration] {
                let approvalHost = NSHostingView(rootView: PCGamesView(
                    library: approvalState, installed: neutralInstalled, operations: neutralOperations,
                    query: "", allowsStartupTasks: false, browse: {}, recentActivity: {}))
                approvalHost.sizingOptions = []
                approvalHost.frame = CGRect(x: 0, y: 0, width: width, height: 600)
                approvalHost.layoutSubtreeIfNeeded()
                check(approvalHost.window == nil && approvalHost.frame.width == width
                      && NSApplication.shared.windows.count == windows,
                      "B6: Native approval and retained-legacy states lay out at Mac widths without windows or startup work")
            }
            let host = NSHostingView(rootView: LiveCatalogView(library: controller, installed: neutralInstalled,
                operations: neutralOperations, query: "neutral", allowsArtworkLoading: false, clearSearch: {})
                .environmentObject(LiveSession()))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            host.layoutSubtreeIfNeeded()
            check(host.window == nil && host.frame.width == width && NSApplication.shared.windows.count == windows
                  && !neutralOperations.checkingCompatibility && neutralOperations.compatibility.isEmpty,
                  "B2/B3: Owned-first search lays out at Mac widths without windows, network, cache reads or checks")
        }
    }
}
