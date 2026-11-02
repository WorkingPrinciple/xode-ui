// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import XodusManagement
import XodusCredentials

actor SandboxCredentialBroker {
    private var token: String?
    private(set) var writes: [String] = []
    private(set) var reads = 0

    func send(_ request: CredentialRequest) throws -> CredentialResponse {
        let decoded = try CredentialRequest(data: request.encoded())
        switch decoded.operation {
        case .write:
            guard let value = decoded.value, value.hasPrefix("SYNTHETIC_") else {
                throw CredentialFailure.invalid
            }
            token = value
            writes.append(value)
        case .read:
            if !decoded.presenceOnly { reads += 1 }
        case .delete:
            token = nil
        case .migrate:
            throw CredentialFailure.unavailable
        }
        let response = CredentialResponse(id: decoded.id, present: token != nil,
            value: decoded.operation == .read && !decoded.presenceOnly ? token : nil)
        return try CredentialResponse(data: response.encoded(), request: request)
    }
}

@MainActor
enum AuthenticatedScenarioChecks {
    private static let productID = "SYNTHETIC001"
    private static let xuid = "1234567890"

    static func launch() -> Never {
        print("Synthetic authenticated scenario runner: no browser, real network, real credential store, or persistent artwork cache.")
        Task { @MainActor in
            do {
                exit(try await run() ? 0 : 1)
            } catch {
                FileHandle.standardError.write(
                    Data("FAIL: Authenticated scenario runner: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        CFRunLoopRun()
        fatalError("Authenticated scenario runner returned without exiting.")
    }

    private static func check(_ condition: Bool, _ message: String, failures: inout Int) {
        if condition {
            print("PASS: \(message)")
        } else {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        }
    }

    private static func response(_ value: [String: Any]) throws -> PCGamesHTTPResponse {
        PCGamesHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: value))
    }

    private static func withScenarioRoot(
        _ root: URL,
        removeRoot: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        operation: (URL) async throws -> Bool
    ) async throws -> Bool {
        var cleanupFailure: Error?
        let result: Result<Bool, Error>
        do {
            let passed = try await {
                defer {
                    do {
                        try removeRoot(root)
                        if FileManager.default.fileExists(atPath: root.path) {
                            cleanupFailure = NSError(domain: "AuthenticatedScenarioCleanup", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Isolated scenario root still exists after cleanup."])
                        }
                    } catch {
                        cleanupFailure = error
                    }
                }
                return try await operation(root)
            }()
            result = .success(passed)
        } catch {
            result = .failure(error)
        }
        if let cleanupFailure {
            let scenarioFailure: String
            if case .failure(let error) = result {
                scenarioFailure = "; scenario also failed: \(error.localizedDescription)"
            } else {
                scenarioFailure = ""
            }
            throw NSError(domain: "AuthenticatedScenarioCleanup", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not remove isolated scenario data: \(cleanupFailure.localizedDescription)\(scenarioFailure)"])
        }
        return try result.get()
    }

    private static func makeScenarioRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OdeAuthenticatedScenario-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    private static func cleanupChecks() async -> [(Bool, String)] {
        var outcomes: [(Bool, String)] = []
        func rootExists(_ root: URL) -> Bool {
            FileManager.default.fileExists(atPath: root.path)
        }

        do {
            let root = try makeScenarioRoot()
            let passed = try await withScenarioRoot(root) { _ in true }
            outcomes.append((passed && !rootExists(root), "Successful synthetic scenario removes its isolated root"))
        } catch {
            outcomes.append((false, "Successful synthetic scenario cleanup failed: \(error.localizedDescription)"))
        }

        do {
            let root = try makeScenarioRoot()
            do {
                _ = try await withScenarioRoot(root) { _ in
                    throw NSError(domain: "AuthenticatedScenarioCleanupChecks", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Synthetic scenario failure."])
                }
                outcomes.append((false, "Failed synthetic scenario propagates its failure after cleanup"))
            } catch {
                outcomes.append((error.localizedDescription.contains("Synthetic scenario failure.")
                                 && !rootExists(root),
                                 "Failed synthetic scenario propagates its failure after cleanup"))
            }
        } catch {
            outcomes.append((false, "Failed synthetic scenario cleanup could not prepare its root: \(error.localizedDescription)"))
        }

        do {
            let root = try makeScenarioRoot()
            do {
                _ = try await withScenarioRoot(root, removeRoot: { _ in
                    throw NSError(domain: "AuthenticatedScenarioCleanupChecks", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Synthetic removal rejection."])
                }, operation: { _ in true })
                outcomes.append((false, "Failed root removal makes the synthetic scenario fail"))
            } catch {
                outcomes.append((error.localizedDescription.contains("Synthetic removal rejection.")
                                 && rootExists(root),
                                 "Failed root removal makes the synthetic scenario fail"))
            }
            do {
                try FileManager.default.removeItem(at: root)
                outcomes.append((!rootExists(root), "Cleanup self-check removes its intentionally retained root"))
            } catch {
                outcomes.append((false, "Cleanup self-check could not remove its retained root: \(error.localizedDescription)"))
            }
        } catch {
            outcomes.append((false, "Removal-failure check could not prepare its root: \(error.localizedDescription)"))
        }
        return outcomes
    }

    private static func catalogProduct() -> [String: Any] {
        [
            "ProductId": productID, "ProductType": "Game", "ProductKind": "Game",
            "LocalizedProperties": [["ProductTitle": "Synthetic Game"]],
            "DisplaySkuAvailabilities": [[
                "Sku": ["Properties": ["Packages": [[
                    "PlatformDependencies": [["PlatformName": "Windows.Desktop"]]
                ]]]]
            ]]
        ]
    }

    private static func legacyLibraryScenario() async throws -> (PCGamesController, SandboxCredentialBroker, PCGamesMockStore, PCGamesMockTransport) {
        let broker = SandboxCredentialBroker()
        let direct = PCGamesMockStore("SYNTHETIC_DIRECT_MUST_NOT_BE_READ")
        let store = PCGamesCredentialStore(sandboxBroker: { try await broker.send($0) }, direct: direct)
        try await store.save("SYNTHETIC_INITIAL_REFRESH_TOKEN")
        let transport = PCGamesMockTransport(try [
            response(["access_token": "SYNTHETIC_ACCESS_TOKEN",
                      "refresh_token": "SYNTHETIC_ROTATED_REFRESH_TOKEN"]),
            response(["Token": "SYNTHETIC_USER_TOKEN",
                      "DisplayClaims": ["xui": [["uhs": "123"]]]]),
            response(["Token": "SYNTHETIC_XBOX_TOKEN",
                      "DisplayClaims": ["xui": [["uhs": "123", "xid": xuid]]]]),
            response(["Token": "SYNTHETIC_STORE_TOKEN",
                      "DisplayClaims": ["xui": [["uhs": "123"]]]]),
            response(["items": [[
                "productId": productID, "productKind": "Game", "status": "Active",
                "isTrial": false, "acquisitionType": "Recurring"
            ]]]),
            response(["Products": [catalogProduct()]])
        ])
        let library = PCGamesController(
            store: store, client: PCGamesClient(transport: transport),
            market: "US", language: "en-US")
        await library.restorePresence()
        library.refresh()
        await library.waitForOperation()
        return (library, broker, direct, transport)
    }

    private static func unifiedAccountScenario(root: URL, expectedAccountHash: String?,
                                               executable: URL) async throws -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(domain: "AuthenticatedScenarioChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Missing synthetic management fixture executable at \(executable.path). Build XodusManagementChecks first."])
        }
        let suiteName = "io.github.dragoshont.xodus.authenticated-scenario.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "AuthenticatedScenarioChecks", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create isolated scenario preferences."])
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = BackendConfiguration(
            executable: executable,
            stateDirectory: root.appendingPathComponent("recentodeauthscenario"))
        let session = LiveSession(configuration: configuration, countryDefaults: defaults)
        let paths = GameScriptPaths(
            scripts: root.appendingPathComponent("scripts"),
            processed: root.appendingPathComponent("processed"),
            logs: root.appendingPathComponent("logs"),
            games: root.appendingPathComponent("games"),
            journal: root.appendingPathComponent("operation.json"))
        let companion = XboxCompanionController(paths: paths)
        await session.connect()
        await session.refreshAccount()
        var failures = 0
        check(session.isReady && session.hasConfirmedSignIn
              && expectedAccountHash != nil && session.accountHash == expectedAccountHash,
              "Synthetic management fixture confirms the same XUID-derived identity as the library",
              failures: &failures)
        let unifiedStore = PCGamesMockStore()
        let unifiedTransport = PCGamesMockTransport(try [
            response(["Products": [catalogProduct()]])
        ])
        let unifiedLibrary = PCGamesController(
            store: unifiedStore, client: PCGamesClient(transport: unifiedTransport))
        unifiedLibrary.useUnifiedAccount(session)
        await unifiedLibrary.refreshInBackground()
        let unifiedRequests = await unifiedTransport.requests
        let unifiedReads = await unifiedStore.reads
        let unifiedSaves = await unifiedStore.saved
        check(unifiedLibrary.accessIsCurrent(for: productID)
              && unifiedLibrary.accountHash == expectedAccountHash
              && unifiedLibrary.snapshot?.games.first?.title == "Synthetic Game"
              && unifiedLibrary.snapshot?.games.first?.acquisitionKind == .subscription
              && unifiedRequests.count == 1
              && unifiedRequests.first?.url?.host == "displaycatalog.mp.microsoft.com"
              && unifiedReads == 0 && unifiedSaves.isEmpty,
              "Unified-account library reads fixture subscription grants and resolves catalogue metadata without legacy credential access",
              failures: &failures)
        companion.useUnifiedAccount(session)
        await companion.refresh(for: nil, force: true)
        check(companion.cache?.profile.value?.gamertag == "SyntheticFixture"
              && companion.cache?.profile.value?.gamerscore == 420
              && XboxCompanionArtwork.reference(companion.cache?.profile.value?.avatarURL) != nil,
              "Production profile path enriches the synthetic profile and validates its gamerpic", failures: &failures)
        if let reference = XboxCompanionArtwork.reference(companion.cache?.profile.value?.avatarURL) {
            do {
                let (image, requests) = try await CatalogMediaChecks.fetchSyntheticGamerpic(reference)
                let decoded = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                let expectedHost = try reference.validatedURL().host
                check(decoded?.width == 24 && decoded?.height == 24
                      && requests.count == 1
                      && requests.first?.url?.host == expectedHost,
                      "Production CatalogArtworkStore retrieves and decodes synthetic gamerpic bytes through fixture-only URLSession with no disk cache",
                      failures: &failures)
            } catch {
                check(false, "Production CatalogArtworkStore decodes the synthetic gamerpic: \(error.localizedDescription)",
                      failures: &failures)
            }
        } else {
            check(false, "Synthetic profile supplies a validated gamerpic artwork reference", failures: &failures)
        }
        guard let title = session.recentLibrary?.titles.first else {
            check(false, "Synthetic recent-library fixture supplies an achievement-history title", failures: &failures)
            await companion.shutdown()
            check(await session.disconnect(), "Synthetic management fixture process is joined", failures: &failures)
            return failures == 0
        }
        await companion.loadAchievements(titleID: title.titleID, status: nil, force: true)
        if companion.achievements[title.titleID]?.complete != true
            || companion.achievements[title.titleID]?.achievements.first?.name != "Synthetic achievement" {
            print("Synthetic achievement diagnostics: title=\(title.titleID), "
                  + "cache=\(companion.achievements[title.titleID] != nil), "
                  + "error=\(companion.achievementErrors[title.titleID] ?? "none")")
        }
        check(companion.achievements[title.titleID]?.complete == true
              && companion.achievements[title.titleID]?.achievements.first?.name == "Synthetic achievement",
              "Production achievement-history path decodes its recorded synthetic response", failures: &failures)
        let traceURL = configuration.stateDirectory.appendingPathComponent("lifecycle.log")
        do {
            let trace = try String(contentsOf: traceURL, encoding: .utf8).split(separator: "\n")
            check(trace.contains("profile:US") && trace.contains("library.recent") && trace.contains("library:US")
                  && trace.contains("achievements:US") && !trace.contains("auth.begin"),
                  "Profile, recent history and achievements use only the mock management process without interactive sign-in",
                  failures: &failures)
        } catch {
            check(false, "Synthetic lifecycle trace is readable: \(error.localizedDescription)", failures: &failures)
        }
        await companion.shutdown()
        check(await session.disconnect(), "Synthetic management fixture process is joined", failures: &failures)
        return failures == 0
    }

    static func run(managementExecutable: URL? = nil) async throws -> Bool {
        var failures = 0
        for (passed, message) in await cleanupChecks() {
            check(passed, message, failures: &failures)
        }
        let (library, broker, direct, transport) = try await legacyLibraryScenario()
        let snapshot = library.snapshot
        let savedTokens = await broker.writes
        let tokenReads = await broker.reads
        let directReads = await direct.reads
        let directSaves = await direct.saved
        let requests = await transport.requests
        let requestHosts = Set(requests.compactMap { $0.url?.host })
        let expectedHosts: Set<String> = [
            "login.microsoftonline.com", "user.auth.xboxlive.com", "xsts.auth.xboxlive.com",
            "collections.mp.microsoft.com", "displaycatalog.mp.microsoft.com"
        ]
        check(library.accessIsCurrent(for: productID)
              && library.gamePassCheckNotice == nil
              && snapshot?.accountID == xuid
              && snapshot?.games.first?.id == productID
              && snapshot?.games.first?.title == "Synthetic Game"
              && snapshot?.games.first?.acquisitionKind == .subscription,
              "Synthetic Game Pass library sync enriches the product and confirms current subscription access",
              failures: &failures)
        if savedTokens != ["SYNTHETIC_INITIAL_REFRESH_TOKEN", "SYNTHETIC_ROTATED_REFRESH_TOKEN"] || tokenReads != 1
            || requests.count != 6 || requestHosts != expectedHosts {
            print("Synthetic transport diagnostics: reads=\(tokenReads), saves=\(savedTokens.count), "
                  + "requests=\(requests.count), hosts=\(requestHosts.sorted())")
        }
        check(savedTokens == ["SYNTHETIC_INITIAL_REFRESH_TOKEN", "SYNTHETIC_ROTATED_REFRESH_TOKEN"]
              && tokenReads == 1
              && directReads == 0 && directSaves.isEmpty
              && requests.count == 6
              && requestHosts == expectedHosts,
              "Synthetic credential issuance, consumption and rotation use the production store adapter and sandbox broker wire with no direct-store access",
              failures: &failures)

        let rejectedStore = PCGamesMockStore("SYNTHETIC_REJECTED_REFRESH_TOKEN")
        let rejectedTransport = PCGamesMockTransport([
            PCGamesHTTPResponse(status: 401, data: Data())
        ])
        let rejected = PCGamesController(
            store: rejectedStore, client: PCGamesClient(transport: rejectedTransport))
        await rejected.restorePresence()
        rejected.refresh()
        await rejected.waitForOperation()
        let rejectedRequests = await rejectedTransport.requests
        let rejectedSaves = await rejectedStore.saved
        check(rejected.snapshot == nil && !rejected.accessIsCurrent(for: productID)
              && rejectedRequests.count == 1 && rejectedSaves.isEmpty,
              "Synthetic authentication rejection grants no library access or saved rotated token",
              failures: &failures)
        do {
            _ = try await rejectedTransport.send(URLRequest(url: URL(string: "https://example.invalid")!))
            check(false, "Exhausted fixture transport rejects without a network fallback", failures: &failures)
        } catch {
            check(true, "Exhausted fixture transport rejects without a network fallback", failures: &failures)
        }

        let executable = managementExecutable ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("XodusManagementChecks")
        let root = try makeScenarioRoot()
        do {
            if try await withScenarioRoot(root, operation: {
                try await unifiedAccountScenario(root: $0, expectedAccountHash: library.accountHash,
                                                 executable: executable)
            }) == false {
                failures += 1
            }
        } catch {
            check(false, "Synthetic management scenario and root cleanup complete: \(error.localizedDescription)",
                  failures: &failures)
        }
        print("\(failures == 0 ? "All authenticated synthetic scenarios passed." : "\(failures) authenticated synthetic scenario checks failed.")")
        return failures == 0
    }
}
