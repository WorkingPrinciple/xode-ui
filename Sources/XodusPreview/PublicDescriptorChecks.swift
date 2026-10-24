// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import Darwin
import Foundation
import XodusManagement

private final class DescriptorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 2_000_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private struct UnavailableDescriptorCredentials: PCGamesRefreshStore {
    func contains() throws -> Bool { throw PCGamesError.credentialBrokerUnavailable }
    func read() throws -> String? { throw PCGamesError.credentialBrokerUnavailable }
    func save(_ refreshToken: String) throws { throw PCGamesError.credentialBrokerUnavailable }
    func delete() throws { throw PCGamesError.credentialBrokerUnavailable }
}

private actor DescriptorTransport: PCGamesTransport {
    private(set) var requests: [URLRequest] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    var blocked = Set<Int>()
    var failures = Set<Int>()
    var omitted = Set<String>()
    var foreign = false

    func configure(blocked: Set<Int> = [], failures: Set<Int> = [], omitted: Set<String> = [], foreign: Bool = false) {
        self.blocked = blocked; self.failures = failures; self.omitted = omitted
        self.foreign = foreign
    }

    func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }

    func send(_ request: URLRequest) async throws -> PCGamesHTTPResponse {
        let index = requests.count
        requests.append(request)
        if blocked.contains(index) { await withCheckedContinuation { continuations[index] = $0 } }
        if failures.contains(index) { return PCGamesHTTPResponse(status: 503, data: Data()) }
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let ids = items.first { $0.name == "bigIds" }!.value!.split(separator: ",").map(String.init)
        let products: [[String: Any]] = ids.filter { !omitted.contains($0) }.map {
            ["ProductId": foreign ? "FIXTURE99999" : $0, "ProductType": "Game", "ProductKind": "Game",
             "LocalizedProperties": [["ProductTitle": "Game \($0)", "Images": [],
                                      "ProductDescription": "Synthetic descriptor"]],
             "DisplaySkuAvailabilities": [["Sku": ["Properties": ["Packages": [
                ["PlatformDependencies": [["PlatformName": "Windows.Desktop"]]]
             ]]]]]]
        }
        return PCGamesHTTPResponse(status: 200,
            data: try JSONSerialization.data(withJSONObject: ["Products": products]))
    }
}

@MainActor
enum PublicDescriptorChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        func wait(_ transport: DescriptorTransport, count: Int) async throws {
            for _ in 0..<200 {
                if await transport.requests.count >= count { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw PCGamesError.transport
        }
        func ids(_ count: Int, offset: Int = 0) -> [String] {
            (offset..<offset + count).map { String(format: "9DESC%07d", $0) }
        }
        let clock = DescriptorClock()
        let transport = DescriptorTransport()
        let shared = PublicCatalogDescriptors(transport: transport, now: { clock.now() })
        let client = PCGamesClient(transport: transport, descriptors: shared)
        let sample = ids(3)
        let collection = try await client.resolveCollection(ids: sample, kinds: [:], candidateCount: 3,
            market: "US", language: "en-US", accountHash: "account-a")
        let artwork = LibraryCatalogArtwork(descriptors: shared, now: { clock.now() })
        await artwork.load(ids: sample, market: "US", language: "en-us")
        check(collection.games.count == 3 && artwork.images.count == 3,
              "Shared public descriptors serve collection PC identity and artwork independently")
        let reuseRequests = await transport.requests.count
        let reuseHits = await shared.hits
        check(reuseRequests == 1 && reuseHits == 3,
              "Collection followed by artwork reuses one request across normalized language casing")
        clock.advance(299)
        _ = try await shared.load(ids: sample, market: "US", language: "en-US")
        let nearExpiry = LibraryCatalogArtwork(descriptors: shared, now: { clock.now() })
        await nearExpiry.load(ids: sample, market: "US", language: "en-US")
        check(await transport.requests.count == 1, "Public descriptors remain reusable strictly before 300 seconds")
        clock.advance(1)
        await nearExpiry.load(ids: sample, market: "US", language: "en-US")
        await artwork.load(ids: sample, market: "US", language: "en-US")
        check(await transport.requests.count == 2, "Near-expiry artwork reuse cannot extend public descriptor freshness past 300 seconds")
        _ = try await shared.load(ids: sample, market: "GB", language: "en-GB")
        check(await transport.requests.count == 3, "Region/language descriptor scopes never share wrong-key bytes")
        clock.advance(300)
        await transport.configure(failures: [3])
        await artwork.load(ids: sample, market: "US", language: "en-US")
        check(artwork.images.count == 3 && artwork.error != nil,
              "An expired public metadata refresh failure retains useful artwork with an explicit failure")

        let delayedTransport = DescriptorTransport()
        await delayedTransport.configure(blocked: [0])
        let delayed = PublicCatalogDescriptors(transport: delayedTransport)
        let cancelled = Task { try await delayed.load(ids: sample, market: "US", language: "en-US") }
        try await wait(delayedTransport, count: 1)
        let joined = Task { try await delayed.load(ids: [sample[1]], market: "US", language: "en-us") }
        cancelled.cancel()
        for _ in 0..<10 { await Task.yield() }
        await delayedTransport.release(0)
        let joinedData = try await joined.value
        do { _ = try await cancelled.value; check(false, "Cancelled descriptor consumer stops publication") }
        catch is CancellationError { check(true, "Cancelled descriptor consumer stops publication") }
        let delayedRequests = await delayedTransport.requests.count
        check(try JSONDecoder().decode(PCGamesCatalog.self, from: joinedData).Products.map(\.ProductId) == [sample[1]]
              && delayedRequests == 1,
              "A cancelled consumer cannot cancel another consumer's same-ID shared public read")

        let refreshTransport = DescriptorTransport()
        await refreshTransport.configure(blocked: [0])
        let refreshStore = PublicCatalogDescriptors(transport: refreshTransport)
        let cacheRead = Task { try await refreshStore.load(ids: sample, market: "US", language: "en-US") }
        try await wait(refreshTransport, count: 1)
        let forcedRead = Task {
            try await refreshStore.load(ids: sample, market: "US", language: "en-US", refresh: true)
        }
        for _ in 0..<10 { await Task.yield() }
        await refreshTransport.release(0)
        _ = try await cacheRead.value
        _ = try await forcedRead.value
        check(await refreshTransport.requests.count == 2,
              "REQ-82: Explicit Network refresh waits for a pending Cache read, then actually refreshes instead of borrowing its result")

        let partialTransport = DescriptorTransport()
        await partialTransport.configure(failures: [1])
        let partialClient = PCGamesClient(transport: partialTransport)
        let many = ids(21)
        var progress: [PCGamesSnapshot] = []
        let partial = try await partialClient.resolveCollection(ids: many, kinds: [many[20]: .subscription], candidateCount: 21,
            market: "US", language: "en-US", accountHash: "account-a", progress: { progress.append($0) })
        check(partial.games.count == 20 && partial.unresolvedIDs == [many[20]]
              && partial.unresolvedCount == 1 && partial.excludedCount == 0 && !partial.isComplete,
              "Failed second batch preserves twenty useful PC records and one explicit unresolved candidate")
        check(progress.count == 3 && progress[1].games.count == 20 && progress[1].unresolvedCount == 1,
              "Useful collection metadata publishes after its first batch, before all batches finish")
        let previous = PCGamesSnapshot(games: [PCGame(id: many[20], title: "Prior verified PC",
            artwork: nil, acquisitionKind: .purchased), PCGame(id: "FIXTURE00001", title: "No longer held", artwork: nil)],
            excludedCount: 0, updatedAt: .distantPast, boundAccountHash: "account-a")
        let retained = partial.retainingUnresolved(from: previous)
        check(retained.games.count == 21 && !retained.games.contains { $0.id == "FIXTURE00001" }
              && retained.unresolvedCount == 1 && retained.games.first { $0.id == many[20] }?.acquisitionKind == .subscription,
              "Partial metadata preserves prior PC facts only for current authoritative collection IDs")
        check(retained.hasResolvedGame(many[0]) && !retained.hasResolvedGame(many[20])
              && !retained.hasResolvedGame("FIXTURE00001"),
              "REQ88: Retained unresolved metadata never establishes current title resolution or restores removed membership")
        let other = PCGamesSnapshot(games: previous.games, excludedCount: 0, updatedAt: .distantPast,
            boundAccountHash: "account-b")
        check(partial.retainingUnresolved(from: other).games.count == 20,
              "An account replacement cannot borrow prior account descriptors as collection membership")
        await partialTransport.configure()
        let retried = try await partialClient.resolveCollection(ids: many, kinds: [:], candidateCount: 21,
            market: "US", language: "en-US", accountHash: "account-a")
        let retryRequests = await partialTransport.requests.count
        check(retried.games.count == 21 && retried.isComplete && retryRequests == 3,
              "Partial retry fetches only unresolved descriptors; successful prior batches stay warm")

        let missingTransport = DescriptorTransport()
        await missingTransport.configure(omitted: [sample[1]])
        let missingClient = PCGamesClient(transport: missingTransport)
        let missing = try await missingClient.resolveCollection(ids: sample,
            kinds: [:], candidateCount: 3, market: "US", language: "en-US")
        check(missing.games.count == 2 && missing.unresolvedIDs == [sample[1]] && missing.excludedCount == 0,
              "A partial response's omission is unresolved, not non-PC classification or authoritative removal")
        await missingTransport.configure()
        let recovered = try await missingClient.resolveCollection(ids: sample, kinds: [:], candidateCount: 3,
            market: "US", language: "en-US")
        let recoveredRequests = await missingTransport.requests
        check(recovered.isComplete && recovered.games.count == 3 && recoveredRequests.count == 2
              && recoveredRequests[1].url?.query?.contains(sample[1]) == true,
              "Omitted descriptors are not cached as absence; retry fetches the missing ID only")

        let boundedTransport = DescriptorTransport()
        await boundedTransport.configure(blocked: [0])
        let bounded = PublicCatalogDescriptors(transport: boundedTransport)
        let active = Task { try await bounded.load(ids: ids(1, offset: 1000), market: "US", language: "en-US") }
        try await wait(boundedTransport, count: 1)
        for start in stride(from: 0, to: 520, by: 20) {
            _ = try await bounded.load(ids: ids(20, offset: start), market: "US", language: "en-US")
        }
        let boundedCount = await bounded.cachedCount
        let boundedBytes = await bounded.cachedBytes
        check(boundedCount == 512 && boundedBytes <= 32 * 1024 * 1024,
              "Public memory reuse evicts safely at 512 entries and 32 MiB without raising wire limits")
        _ = try await bounded.load(ids: ids(20), market: "US", language: "en-US")
        check(await boundedTransport.requests.count == 28,
              "Eviction means fetch again, never fabricated absence")
        await boundedTransport.release(0)
        let activeData = try await active.value
        check(try JSONDecoder().decode(PCGamesCatalog.self, from: activeData).Products.count == 1,
              "Reusable-entry eviction under pressure does not discard a still-active waiter")

        let helper = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("XodusManagementChecks")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            check(false, "Descriptor retirement requires `swift build --product XodusManagementChecks --jobs 1` before focused checks")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DescriptorRetirement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Descriptor retirement fixture is cleaned") }
        }
        let managedConfiguration = BackendConfiguration(executable: helper,
            stateDirectory: root.appendingPathComponent("descriptors"))
        let management = try ManagementClient()
        let hello = try await management.connect(managedConfiguration)
        check(hello.supports(.descriptors), "REQ-82: Shared public reads are explicitly capability-negotiated")
        let fallbackTransport = DescriptorTransport()
        let managedStore = PublicCatalogDescriptors(transport: fallbackTransport)
        let owner = UUID()
        await managedStore.bind(management, owner: owner)
        _ = try await managedStore.load(ids: sample, market: "US", language: "en-US")
        let managedArtwork = LibraryCatalogArtwork(descriptors: managedStore)
        await managedArtwork.load(ids: sample, market: "US", language: "en-US")
        let managedRequests = await managedStore.requests
        let fallbackRequests = await fallbackTransport.requests.count
        check(managedRequests == 1 && managedArtwork.images.count == sample.count
              && managedArtwork.images.values.allSatisfy { $0.detail?.description == "Managed public descriptor." }
              && fallbackRequests == 0,
              "REQ-82: Library/Discover rich public metadata shares one management read with no independent HTTP request")
        let originalExpiry = await managedStore.expirations(ids: sample, market: "US", language: "en-US")
        check(originalExpiry.count == 3 && originalExpiry.values.allSatisfy { $0 < Date().addingTimeInterval(61) },
              "REQ-82: Four-minute-old backend descriptors keep only their original remaining minute")
        _ = try await managedStore.load(ids: sample, market: "US", language: "en-US")
        check(await managedStore.expirations(ids: sample, market: "US", language: "en-US") == originalExpiry,
              "REQ-82: Warm app reuse retains original backend expiry, not a new five-minute lease")
        await managedArtwork.retry(id: sample[0], market: "US", language: "en-US")
        check(await managedStore.requests == 2,
              "REQ-82: Explicit detail retry forces one fresh management read even inside the app freshness window")
        _ = try await managedStore.load(ids: sample, market: "GB", language: "en-GB")
        check(await managedStore.requests == 3,
              "REQ-82: Shared management reads cannot reuse another market/language key")
        await managedStore.unbind(owner: owner)
        _ = try await managedStore.load(ids: sample, market: "US", language: "en-US")
        check(await fallbackTransport.requests.count == 1,
              "REQ-82: Retired capability binding releases cached source and falls back honestly to public HTTP")
        _ = await management.close()

        let oversizedConfiguration = BackendConfiguration(executable: helper,
            stateDirectory: root.appendingPathComponent("descriptorsoversized"))
        let oversizedManagement = try ManagementClient()
        _ = try await oversizedManagement.connect(oversizedConfiguration)
        let oversized = PublicCatalogDescriptors(transport: fallbackTransport)
        await oversized.bind(oversizedManagement, owner: UUID())
        let oversizedArtwork = LibraryCatalogArtwork(descriptors: oversized)
        await oversizedArtwork.load(ids: sample, market: "US", language: "en-US")
        let oversizedRequests = await oversized.requests
        check(oversizedRequests == 4 && oversizedArtwork.images.isEmpty
              && oversizedArtwork.detailErrors.count == 3 && oversizedArtwork.error != nil,
              "REQ-82: Oversized response splits once to single IDs and terminates with explicit errors, never an automatic retry loop")
        _ = await oversizedManagement.close()

        let splitManagement = try ManagementClient()
        _ = try await splitManagement.connect(BackendConfiguration(executable: helper,
            stateDirectory: root.appendingPathComponent("descriptorssplitfailure")))
        let splitStore = PublicCatalogDescriptors(transport: DescriptorTransport())
        await splitStore.bind(splitManagement, owner: UUID())
        let splitData = try await splitStore.load(ids: sample, market: "GB", language: "en-GB")
        let splitFailures = await splitStore.failures(ids: sample, market: "GB", language: "en-GB")
        let splitRequests = await splitStore.requests
        check(try JSONDecoder().decode(PCGamesCatalog.self, from: splitData).Products.map(\.ProductId) == Array(sample.prefix(2))
              && splitFailures.keys.sorted() == [sample[2]] && splitRequests == 3,
              "REQ-82: A failed smaller-batch retry preserves both successful raw peers and an explicit unresolved error")
        _ = await splitManagement.close()

        let wireTime = Date(timeIntervalSince1970: 2_000_000_000)
        let formatter = ISO8601DateFormatter()
        let validRecord: [String: JSONValue] = [
            "productID": .string(sample[0]), "market": .string("GB"), "language": .string("en-GB"),
            "checkedAt": .string(formatter.string(from: wireTime)),
            "expiresAt": .string(formatter.string(from: wireTime.addingTimeInterval(300))),
            "freshness": .string("cached"), "product": .object(["ProductId": .string(sample[0])])
        ]
        func validateRecord(_ record: [String: JSONValue], now: Date? = nil) throws {
            let response = try JSONValue.object([
                "descriptors": .array([.object(record)]), "failures": .array([])
            ]).decode(CatalogDescriptors.self)
            try response.validate(ids: [sample[0]], market: "GB", language: "en-GB",
                                  now: now ?? wireTime.addingTimeInterval(1))
        }
        try validateRecord(validRecord)
        for (label, field, value) in [
            ("market", "market", JSONValue.string("US")),
            ("language", "language", .string("en-gb")),
            ("identity", "product", .object(["ProductId": .string(sample[1])])),
            ("extended freshness", "expiresAt", .string(formatter.string(from: wireTime.addingTimeInterval(301))))
        ] {
            var record = validRecord
            record[field] = value
            do {
                try validateRecord(record)
                check(false, "REQ-82: Managed descriptor rejects wrong \(label)")
            } catch ManagementError.invalidPayload {
                check(true, "REQ-82: Managed descriptor rejects wrong \(label)")
            }
        }
        for (label, now) in [
            ("expired freshness", wireTime.addingTimeInterval(300)),
            ("future fetch", wireTime.addingTimeInterval(-1))
        ] {
            do {
                try validateRecord(validRecord, now: now)
                check(false, "REQ-82: Managed descriptor rejects \(label) despite a valid 300-second lease")
            } catch ManagementError.invalidPayload {
                check(true, "REQ-82: Managed descriptor rejects \(label) despite a valid 300-second lease")
            }
        }

        if let path = ProcessInfo.processInfo.environment["XODUS_DESCRIPTOR_CHECK_CLI"] {
            let state = root.appendingPathComponent("source-descriptor-envelope")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            guard let canonical = realpath(state.path, nil) else { throw PCGamesError.transport }
            let directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            free(canonical)
            let timestamp = ISO8601DateFormatter()
            let checked = Date(), expiry = checked.addingTimeInterval(300)
            let raw: [String: Any] = [
                "ProductId": "FIXTURE00001", "ProductType": "Game", "ProductKind": "Game",
                "Properties": ["Category": "Games"],
                "LocalizedProperties": [[
                    "ProductTitle": "Neutral source fixture", "Language": "en-GB", "Images": [],
                    "ProductDescription": "Preserved neutral rich detail"
                ]],
                "DisplaySkuAvailabilities": [[
                    "Sku": ["SkuId": "fixture-edition", "Properties": ["Packages": [[
                        "PackageId": "fixture-package", "Version": "1.0.0.0",
                        "PlatformDependencies": [["PlatformName": "Windows.Desktop"]]
                    ]]]],
                    "Availabilities": []
                ]]
            ]
            let record: [String: Any] = [
                "productID": "FIXTURE00001", "market": "GB", "language": "en-GB",
                "checkedAt": timestamp.string(from: checked), "expiresAt": timestamp.string(from: expiry),
                "freshness": "live", "product": raw
            ]
            let file = directory.appendingPathComponent("public-descriptors-v1.json")
            try JSONSerialization.data(withJSONObject: [
                "version": 1, "records": ["FIXTURE00001:GB:en-gb": record]
            ], options: [.sortedKeys]).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let sourceClient = try ManagementClient()
            do {
                let sourceHello = try await sourceClient.connect(BackendConfiguration(
                    executable: URL(fileURLWithPath: path), stateDirectory: directory))
                check(sourceHello.supports(.descriptors),
                      "REQ-82 SOURCE CLI: Real hello negotiates catalog.descriptors with the app schema")
                let sourceFallback = DescriptorTransport()
                let sourceStore = PublicCatalogDescriptors(transport: sourceFallback)
                await sourceStore.bind(sourceClient, owner: UUID())
                let sourceData = try await sourceStore.load(ids: ["FIXTURE00001"], market: "GB", language: "en-GB")
                let sourceArtwork = LibraryCatalogArtwork(descriptors: sourceStore)
                await sourceArtwork.load(ids: ["FIXTURE00001"], market: "GB", language: "en-GB")
                let sourceRequests = await sourceStore.requests
                let sourceHTTP = await sourceFallback.requests.count
                let original = await sourceStore.expirations(ids: ["FIXTURE00001"], market: "GB", language: "en-GB")
                check(sourceRequests == 1 && sourceHTTP == 0
                      && sourceArtwork.images["FIXTURE00001"]?.detail?.description == "Preserved neutral rich detail"
                      && sourceArtwork.images["FIXTURE00001"]?.facts.isBaseGame == true
                      && abs((original["FIXTURE00001"] ?? .distantPast).timeIntervalSince(expiry)) < 1
                      && !sourceData.isEmpty,
                      "REQ-82 SOURCE CLI: Actual app consumer decodes persisted raw identity/rich fields and original expiry without independent HTTP")
                _ = try await sourceStore.load(ids: ["FIXTURE00001"], market: "GB", language: "en-GB")
                let warmRequests = await sourceStore.requests, warmHits = await sourceStore.hits
                check(warmRequests == 1 && warmHits == 2,
                      "REQ-82 SOURCE CLI: Shared Library/Discover warm consumers record two hits and one management request total")
                check(await sourceClient.close(),
                      "REQ-82 SOURCE CLI: Neutral source-only management process retires without account operations")
            } catch {
                _ = await sourceClient.close()
                throw error
            }
        }

        let config = BackendConfiguration(executable: helper,
            stateDirectory: root.appendingPathComponent("odelibrarywarm"))
        let session = LiveSession(configuration: config)
        await session.connect()
        await session.refreshAccount()
        let retiredTransport = DescriptorTransport()
        await retiredTransport.configure(blocked: [0])
        let controller = PCGamesController(store: UnavailableDescriptorCredentials(),
            client: PCGamesClient(transport: retiredTransport))
        controller.useUnifiedAccount(session)
        let loading = Task { await controller.loadOnAppear() }
        try await wait(retiredTransport, count: 1)
        check(controller.snapshot?.unresolvedCount == 1 && controller.resolutionNotice == nil
              && !controller.accessIsCurrent, "Pending collection details expose partial state without current access")
        let retiring = Task { await controller.retireUnifiedAccount() }
        for _ in 0..<10 { await Task.yield() }
        check(controller.snapshot == nil && controller.representedGames.isEmpty,
              "Account retirement immediately withdraws partial personal publication")
        await retiredTransport.release(0)
        await loading.value
        await retiring.value
        check(controller.snapshot == nil && !controller.hasSavedSignIn && !controller.accessIsCurrent,
              "Late shared descriptor completion cannot republish a retired collection generation")
        await controller.loadOnAppear()
        check(controller.representedGames.count == 1 && controller.accessIsCurrent,
              "Same-account reentry admits the new collection generation, not the retired completion")
        let failedTransport = DescriptorTransport()
        await failedTransport.configure(failures: [0])
        let failedController = PCGamesController(store: UnavailableDescriptorCredentials(),
            client: PCGamesClient(transport: failedTransport))
        failedController.useUnifiedAccount(session)
        await failedController.loadOnAppear()
        check(failedController.error != nil && failedController.snapshot?.isComplete == false
              && failedController.retainedLibraryNotice == "Showing available details from an incomplete library."
              && failedController.resolutionNotice?.contains("Refresh your library") == true
              && failedController.resolutionNotice?.contains("classification") == false
              && !failedController.accessIsCurrent,
              "Total public metadata failure reports incomplete Library details, never a last-complete or genuine-zero claim")
        check(await session.disconnect(), "Descriptor retirement check joins its isolated management child")

        let invalidTransport = DescriptorTransport()
        await invalidTransport.configure(foreign: true)
        let validated = PublicCatalogDescriptors(transport: invalidTransport)
        do {
            _ = try await validated.load(ids: [sample[0]], market: "US", language: "en-US")
            check(false, "Public descriptor cache rejects a response with another product identity")
        } catch PCGamesError.invalidResponse {
            check(true, "Public descriptor cache rejects a response with another product identity")
        }
        await invalidTransport.configure()
        _ = try await validated.load(ids: [sample[0]], market: "US", language: "en-US")
        check(await invalidTransport.requests.count == 2, "Rejected shared responses are retryable, never cached as absence")
        do {
            _ = try await validated.load(ids: ids(21), market: "US", language: "en-US")
            check(false, "Public descriptor reuse cannot bypass the 20-product transport batch bound")
        } catch PCGamesError.invalidResponse {
            check(true, "Public descriptor reuse cannot bypass the 20-product transport batch bound")
        }

        for count in [36, 300, 512] {
            let baselineTransport = DescriptorTransport()
            let baselineSnapshot = try await PCGamesClient(transport: baselineTransport)
                .resolveCollection(ids: ids(count), kinds: [:], candidateCount: count, market: "US", language: "en-US")
            let baselineMedia = LibraryCatalogArtwork(transport: baselineTransport)
            await baselineMedia.load(ids: ids(count), market: "US", language: "en-US")
            let originalRequests = await baselineTransport.requests.count
            let measuredTransport = DescriptorTransport()
            let measuredStore = PublicCatalogDescriptors(transport: measuredTransport)
            let start = ContinuousClock.now
            let snapshot = try await PCGamesClient(transport: measuredTransport, descriptors: measuredStore)
                .resolveCollection(ids: ids(count), kinds: [:], candidateCount: count, market: "US", language: "en-US")
            let media = LibraryCatalogArtwork(descriptors: measuredStore)
            await media.load(ids: ids(count), market: "US", language: "en-US")
            let requests = await measuredTransport.requests.count
            let retained = await measuredStore.cachedCount
            check(snapshot.games.count == count && media.images.count == count && requests == (count + 19) / 20
                  && baselineSnapshot.games == snapshot.games && baselineMedia.images.count == count
                  && originalRequests == 2 * requests,
                  "\(count)-title fixture shares each public response across collection and artwork without a duplicate fetch")
            print("DESCRIPTOR_FIXTURE titles=\(count) independent_requests=\(originalRequests) shared_requests=\(requests) retained=\(retained) elapsed=\(start.duration(to: .now)) synthetic_transport=true")
        }
    }
}
#endif
