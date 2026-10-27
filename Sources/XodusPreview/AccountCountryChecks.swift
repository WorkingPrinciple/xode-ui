// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

private actor CountryRequestProbe: PCGamesTransport {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) throws -> PCGamesHTTPResponse {
        requests.append(request)
        throw PCGamesError.transport
    }
}

private actor LibraryFreeToPlayTransport: PCGamesTransport {
    private(set) var requests = 0
    func send(_ request: URLRequest) throws -> PCGamesHTTPResponse {
        requests += 1
        let body: String
        switch request.url?.host {
        case "www.xbox.com":
            if request.url?.path.hasSuffix(".js") == true {
                body = #"var guidAmpt = {"ftpbenefitspc":"00000000-0000-4000-8000-000000000011"};"#
            } else {
                body = """
                    <script src="/en-US/xbox-game-pass/games/js/xgpcatPopulate-test.js"></script>
                    <span class="colgroup collections-pc hidden">
                    <a data-col="ftpbenefitspc"><span>Free to play</span></a>
                    """
            }
        case "catalog.gamepass.com":
            body = #"[{"siglId":"00000000-0000-4000-8000-000000000011"},{"id":"BT5P2X999VH2"}]"#
        default: throw PCGamesError.invalidResponse
        }
        return PCGamesHTTPResponse(status: 200, data: Data(body.utf8))
    }
}

@MainActor
enum AccountCountryChecks {
    static func run(configuration: (String) -> BackendConfiguration,
                    check: (Bool, String) -> Void) async throws {
        let freeTransport = LibraryFreeToPlayTransport()
        let freeArtwork = LibraryCatalogArtwork(transport: freeTransport)
        let freeCollection = GamePassCollections(transport: freeTransport, artwork: freeArtwork,
            keys: [DiscoverGamePassShelf.freeToPlay.rawValue], loadsProductDetails: false)
        await freeCollection.load(market: "US", language: "en-US")
        let firstRequests = await freeTransport.requests
        check(freeArtwork.freeToPlayIDs == ["BT5P2X999VH2"] && freeArtwork.images.isEmpty
              && firstRequests == 3 && freeCollection.error == nil,
              "REQ-162 L3: Library-first startup learns free-to-play IDs without Discover, artwork or licence reads")
        await freeCollection.load(market: "US", language: "en-US")
        let reusedRequests = await freeTransport.requests
        check(reusedRequests == firstRequests,
              "REQ-162 L3: repeated Library startup in the same scope reuses the loaded public list")
        let verified: JSONValue = .object([
            "status": .string("verified"), "countryCode": .string("UK"),
            "locale": .string("en-GB"), "source": .string("xboxAccount.legalCountry"), "reason": .null
        ])
        check(try verified.decode(XboxAccountCountry.self).countryCode == "GB",
              "REQ101 provider UK normalizes to API GB independently of language")
        for (key, bad) in [("status", JSONValue.string("guessed")), ("countryCode", .string("gb")),
                           ("source", .string("profile.Location")), ("reason", .string("providerUnavailable")),
                           ("locale", .string("en GB"))] {
            var fields = verified.object ?? [:]
            fields[key] = bad
            do {
                _ = try JSONValue.object(fields).decode(XboxAccountCountry.self)
                check(false, "REQ101 invalid country field \(key) refuses verification")
            } catch { check(true, "REQ101 invalid country field \(key) refuses verification") }
        }
        var extra = verified.object ?? [:]
        extra["inferred"] = .bool(true)
        do {
            _ = try JSONValue.object(extra).decode(XboxAccountCountry.self)
            check(false, "REQ101 extra country claims are rejected")
        } catch { check(true, "REQ101 extra country claims are rejected") }
        let suite = "XodusCountryChecks-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ManagementError.invalidPayload }
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = configuration("odecountry")
        defer {
            do { try FileManager.default.removeItem(at: config.stateDirectory.deletingLastPathComponent()) }
            catch { check(false, "REQ101 synthetic management state is cleaned") }
        }
        let session = LiveSession(configuration: config, countryDefaults: defaults)
        await session.connect()
        await session.refreshAccount()
        check(session.hasConfirmedSignIn,
              "REQ101 fixture has a confirmed account (status \(session.authentication?.state.rawValue ?? "none"), error \(session.accountError ?? session.errorMessage ?? "none"))")
        try NativeUIChecks.checkSignedInSettingsAccountPane(session: session, check: check)
        session.market = "RO"
        let before = session.catalogRequestVersion
        await session.refreshAccountCountry()
        check(session.accountCountryReady && session.accountCountryVerified && session.market == "GB"
              && session.language == "en-US" && session.catalogRequestVersion > before,
              "REQ101 provider country overrides a Romanian device scope without conflating language (market \(session.market), error \(session.accountCountryError ?? "none"))")
        try NativeUIChecks.checkAccountCountry(session: session, confirmationRequired: false, check: check)
        let library = PCGamesController(market: "RO")
        library.useUnifiedAccount(session)
        await library.refreshInBackground()
        let trace = try String(contentsOf: config.stateDirectory.appendingPathComponent("lifecycle.log"), encoding: .utf8)
        check(trace.contains("library:GB") && !trace.contains("library:RO"),
              "REQ101 PC library uses the session country rather than its legacy controller market")
        let scope = session.accountCatalogScope
        session.applyAccountCountry(nil, account: String(repeating: "b", count: 64))
        check(session.accountCatalogScope == scope && session.accountCountryVerified,
              "REQ101 another account cannot publish a country into this session")
        session.applyAccountCountry(nil, account: session.accountHash ?? "")
        check(!session.accountCountryReady && session.market.isEmpty && session.accountCountryNeedsConfirmation,
              "REQ101 unavailable provider country does not fall back to device or US")
        session.confirmAccountCountry("UK")
        check(session.market == "GB" && session.accountCountryReady && !session.accountCountryVerified
              && session.accountCountryLabel.contains("confirmed by you"),
              "COR127 explicit confirmation is normalized and never labelled provider-verified")
        let account = session.accountHash ?? ""
        check(defaults.string(forKey: "Xodus.accountCountry.\(account)") == "GB"
              && defaults.string(forKey: "Xodus.accountCountry.\(String(repeating: "b", count: 64))") == nil,
              "COR127 confirmed country is stored for only its exact account")
        let revision = session.catalogRequestVersion
        session.confirmAccountCountry("DE")
        check(session.market == "DE" && session.catalogRequestVersion > revision
              && !library.accessIsCurrent && library.representedGames.isEmpty,
              "REQ101 country change invalidates prior library eligibility and catalogue publication immediately")
        session.applyAccountCountry(try verified.decode(XboxAccountCountry.self), account: account)
        check(session.market == "GB" && session.accountCountryVerified,
              "REQ101 a fresh verified provider country takes precedence over saved user confirmation")
        check(await session.disconnect(), "REQ101 closes only its synthetic management child")
        check(!session.accountCountryReady && session.market.isEmpty && !session.accountCountryVerified,
              "REQ101 disconnect retires the account country instead of leaking it into a new session")

        for scenario in ["odecountryunknown", "odemismatch", "odecountryslow"] {
            let next = configuration(scenario)
            // These scenarios start without a last verified country, so no provisional re-check races them.
            defaults.removeObject(forKey: LiveSession.lastVerifiedCountryKey(account))
            let nextSession = LiveSession(configuration: next, countryDefaults: defaults)
            await nextSession.connect()
            await nextSession.refreshAccount()
            nextSession.market = ""
            await nextSession.refreshAccountCountry()
            if scenario == "odecountryunknown" {
                check(nextSession.accountCountryReady && !nextSession.accountCountryVerified
                      && nextSession.market == "DE" && nextSession.accountCountryNeedsConfirmation,
                      "COR127 a genuine provider-unavailable read restores only this account's saved confirmation")
                defaults.removeObject(forKey: "Xodus.accountCountry.\(account)")
                await nextSession.refreshAccountCountry()
                check(!nextSession.accountCountryReady && nextSession.market.isEmpty
                      && nextSession.accountCountryNeedsConfirmation,
                      "COR127 provider-unavailable response without saved confirmation keeps country unknown")
                let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/CountryLibrary-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let game = InstalledGame(id: UUID(), title: "Country-independent local game",
                    identityName: "Fixture.CountryLocal", version: "1.0.0.0", storeId: "FIXTURE00001",
                    folder: root.path, launcher: "", importedAt: Date(), usesNativeLifecycle: true)
                let store = InstalledGameStore(file: root.appendingPathComponent("registry/installed.json"))
                try await store.save([game])
                let installed = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc })
                await installed.load()
                NativeUIChecks.checkCountryPendingLibrary(session: nextSession, installed: installed, check: check)
                try FileManager.default.removeItem(at: root)
                let transport = CountryRequestProbe()
                let artwork = LibraryCatalogArtwork(transport: transport)
                await LiveActivityView.loadArtwork(productID: "FIXTURE00001", session: nextSession, artwork: artwork)
                check(await transport.requests.isEmpty && artwork.images.isEmpty,
                      "REQ101 Downloads with unresolved country issues zero catalogue requests")
                await artwork.load(ids: ["FIXTURE00001"], market: "", language: "en-US")
                await artwork.loadDetail(id: "FIXTURE00001", market: "", language: "en-US")
                let collections = GamePassCollections(transport: transport)
                await collections.load(market: "", language: "en-US")
                check(await transport.requests.isEmpty && artwork.error != nil && collections.error != nil,
                      "REQ101 catalogue consumers explicitly reject missing country instead of silently using US")
                try NativeUIChecks.checkAccountCountry(session: nextSession, confirmationRequired: true, check: check)
            } else if scenario == "odemismatch" {
                check(!nextSession.accountCountryReady && !nextSession.accountCountryNeedsConfirmation
                      && nextSession.accountCountryError != nil && nextSession.market.isEmpty,
                      "REQ101 a foreign-account profile response cannot authorize country fallback")
            } else {
                let pending = PCGamesController(market: "RO")
                pending.useUnifiedAccount(nextSession)
                let read = Task { await pending.refreshInBackground() }
                let traceURL = next.stateDirectory.appendingPathComponent("lifecycle.log")
                for _ in 0..<100 {
                    if try String(contentsOf: traceURL, encoding: .utf8).contains("library:GB") { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                check(try String(contentsOf: traceURL, encoding: .utf8).contains("library:GB") && pending.busy,
                      "REQ101 old-country collection is genuinely suspended before changing country")
                nextSession.applyAccountCountry(nil, account: nextSession.accountHash ?? "")
                nextSession.confirmAccountCountry("DE")
                await read.value
                check(nextSession.market == "DE" && pending.snapshot == nil && pending.representedGames.isEmpty
                      && !pending.busy && pending.error == nil,
                      "REQ101 a suspended old-country completion cannot publish or demand another sign-in")
            }
            check(await nextSession.disconnect(), "REQ101 country fixture child closes")
            try FileManager.default.removeItem(at: next.stateDirectory.deletingLastPathComponent())
        }
    }
}
