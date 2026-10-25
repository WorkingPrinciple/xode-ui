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
    var nonPC = Set<String>()
    var foreign = false
    var failureStatus = 400
    var retryAfter: String?

    func configure(blocked: Set<Int> = [], failures: Set<Int> = [], omitted: Set<String> = [], foreign: Bool = false,
                   failureStatus: Int = 400, retryAfter: String? = nil, nonPC: Set<String> = []) {
        self.blocked = blocked; self.failures = failures; self.omitted = omitted
        self.foreign = foreign
        self.failureStatus = failureStatus
        self.retryAfter = retryAfter
        self.nonPC = nonPC
    }

    func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }

    func send(_ request: URLRequest) async throws -> PCGamesHTTPResponse {
        let index = requests.count
        requests.append(request)
        if blocked.contains(index) { await withCheckedContinuation { continuations[index] = $0 } }
        if failures.contains(index) {
            return PCGamesHTTPResponse(status: failureStatus, data: Data(), retryAfter: retryAfter)
        }
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let ids = items.first { $0.name == "bigIds" }!.value!.split(separator: ",").map(String.init)
        let products: [[String: Any]] = ids.filter { !omitted.contains($0) }.map {
            ["ProductId": foreign ? "FIXTURE99999" : $0, "ProductType": "Game", "ProductKind": "Game",
             "LocalizedProperties": [["ProductTitle": "Game \($0)", "Images": [],
                                      "ProductDescription": "Synthetic descriptor"]],
             "DisplaySkuAvailabilities": [["Sku": ["Properties": ["Packages": [
                ["PlatformDependencies": [["PlatformName": nonPC.contains($0) ? "Windows.Xbox" : "Windows.Desktop"]]]
             ]]]]]]
        }
        return PCGamesHTTPResponse(status: 200,
            data: try JSONSerialization.data(withJSONObject: ["Products": products]))
    }
}

private actor DescriptorRetryClock {
    private(set) var delays: [Duration] = []
    let block: Bool
    init(block: Bool = false) { self.block = block }
    func sleep(_ duration: Duration) async throws {
        delays.append(duration)
        if block { try await Task.sleep(for: .seconds(3_600)) }
        try Task.checkCancellation()
    }
}

private actor DescriptorRetryBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func sleep(_ duration: Duration) async throws {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }
    func release() { continuation?.resume(); continuation = nil }
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
        let seasonalTransport = DescriptorTransport()
        let seasonalArtwork = LibraryCatalogArtwork(transport: seasonalTransport)
        let seasonal = HalloweenCatalog(artwork: seasonalArtwork)
        await seasonal.load(scope: nil, market: "GB", language: "en-US")
        check(await seasonalTransport.requests.isEmpty,
              "REQ89: Inactive season or unconfirmed country sends no seasonal requests")
        await seasonal.load(scope: "account:GB:2026", market: "GB", language: "en-US")
        let seasonalRequests = await seasonalTransport.requests
        check(seasonal.products.map(\.id) == HalloweenShelf.editorialIDs
              && seasonalRequests.count == 1 && HalloweenShelf.editorialIDs.count <= 12,
              "REQ89: Independent bounded editorial descriptors populate a shelf without loaded Discover pages")
        await seasonal.load(scope: "account:GB:2026", market: "GB", language: "en-US")
        check(await seasonalTransport.requests.count == 1,
              "REQ89: Seasonal scope reentry reuses verified selection without duplicate requests")
        await seasonal.load(scope: nil, market: "GB", language: "en-US")
        check(seasonal.products.isEmpty && seasonal.facts.isEmpty && seasonal.error == nil,
              "REQ89: Season end or account retirement removes cached seasonal presentation")
        let failedSeasonalTransport = DescriptorTransport()
        await failedSeasonalTransport.configure(failures: [0])
        let failedSeasonal = HalloweenCatalog(artwork: LibraryCatalogArtwork(transport: failedSeasonalTransport))
        await failedSeasonal.load(scope: "GB", market: "GB", language: "en-US")
        check(failedSeasonal.products.isEmpty && failedSeasonal.error != nil,
              "REQ89: Failed seasonal reads expose an error instead of a successful empty shelf")
        await failedSeasonal.load(scope: "GB", market: "GB", language: "en-US", refresh: true)
        check(failedSeasonal.products.count == HalloweenShelf.editorialIDs.count && failedSeasonal.error == nil,
              "REQ89: Explicit seasonal retry recovers verified products without replacing Discover results")
        let emptySeasonalTransport = DescriptorTransport()
        await emptySeasonalTransport.configure(nonPC: Set(HalloweenShelf.editorialIDs))
        let emptySeasonal = HalloweenCatalog(artwork: LibraryCatalogArtwork(transport: emptySeasonalTransport))
        await emptySeasonal.load(scope: "GB", market: "GB", language: "en-US")
        check(emptySeasonal.products.isEmpty && emptySeasonal.error == nil,
              "REQ89: A verified console-only selection is omitted, not promoted to PC or treated as a read failure")
        let delayedSeasonalTransport = DescriptorTransport()
        await delayedSeasonalTransport.configure(blocked: [0])
        let delayedSeasonal = HalloweenCatalog(artwork: LibraryCatalogArtwork(transport: delayedSeasonalTransport))
        let retiredSeasonalRead = Task { await delayedSeasonal.load(scope: "old:GB", market: "GB", language: "en-US") }
        try await wait(delayedSeasonalTransport, count: 1)
        await delayedSeasonal.load(scope: nil, market: "GB", language: "en-US")
        await delayedSeasonalTransport.release(0)
        await retiredSeasonalRead.value
        check(delayedSeasonal.products.isEmpty && !delayedSeasonal.loading,
              "REQ89: Late seasonal completion cannot republish after account or season retirement")
        let sample = ids(3)
        for status in [503, 429] {
            let transient = DescriptorTransport()
            await transient.configure(failures: [0, 1], failureStatus: status,
                                      retryAfter: status == 429 ? "3" : nil)
            let delay = DescriptorRetryClock()
            let time = DescriptorClock()
            let recovery = PublicCatalogDescriptors(transport: transient, now: { time.now() }, sleep: {
                try await delay.sleep($0)
                time.advance(Double($0.components.seconds))
            })
            let data = try await recovery.load(ids: sample, market: "US", language: "en-US")
            check(try JSONDecoder().decode(PCGamesCatalog.self, from: data).Products.count == 3,
                  "REQ98 transient descriptor reads eventually recover without losing games")
            let requests = await transient.requests.count, delays = await delay.delays
            check(requests == 3
                  && delays == (status == 429 ? [.seconds(3), .seconds(3)] : [.seconds(1), .seconds(2)]),
                  "REQ98 deterministic exponential backoff honors exposed Retry-After")
        }
        let exhausted = DescriptorTransport()
        await exhausted.configure(failures: [0, 1, 2, 3, 4], failureStatus: 503)
        let capClock = DescriptorRetryClock()
        let capped = PublicCatalogDescriptors(transport: exhausted, sleep: { try await capClock.sleep($0) })
        do {
            _ = try await capped.load(ids: sample, market: "US", language: "en-US")
            check(false, "REQ98 exhausted retries must report failure")
        } catch PCGamesError.http(503) {
            let requests = await exhausted.requests.count, delays = await capClock.delays
            check(requests == 4 && delays == [.seconds(1), .seconds(2), .seconds(4)],
                  "REQ98 automatic recovery stops after three retries with bounded delays")
        }
        for status in [401, 403, 404, 429] {
            let permanent = DescriptorTransport()
            await permanent.configure(failures: [0, 1], failureStatus: status, retryAfter: "120")
            let delay = DescriptorRetryClock()
            let noRetry = PublicCatalogDescriptors(transport: permanent, sleep: { try await delay.sleep($0) })
            do {
                _ = try await noRetry.load(ids: sample, market: "US", language: "en-US")
                check(false, "REQ98 permanent failures cannot appear successful")
            } catch PCGamesError.http {
                let requests = await permanent.requests.count, delays = await delay.delays
                check(requests == 1 && delays.isEmpty,
                      "REQ98 no auth/permanent retry or shortened server cooldown for HTTP \(status)")
            }
            if status == 429 {
                do {
                    _ = try await noRetry.load(ids: sample, market: "US", language: "en-US")
                    check(false, "REQ98 manual Retry cannot bypass server cooldown")
                } catch PCGamesError.http(429) {
                    check(await permanent.requests.count == 1, "REQ98 manual Retry honors retained server cooldown without network")
                }
            }
        }
        let datedTransport = DescriptorTransport()
        let serverClock = DescriptorClock()
        let retryDateFormatter = DateFormatter()
        retryDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        retryDateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        retryDateFormatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        await datedTransport.configure(failures: [0], failureStatus: 429,
            retryAfter: retryDateFormatter.string(from: serverClock.now().addingTimeInterval(5)))
        let datedDelay = DescriptorRetryClock()
        let datedStore = PublicCatalogDescriptors(transport: datedTransport, now: { serverClock.now() },
            sleep: { duration in
                try await datedDelay.sleep(duration)
                serverClock.advance(5)
            })
        _ = try await datedStore.load(ids: sample, market: "US", language: "en-US")
        check(await datedDelay.delays == [.seconds(5)], "REQ98 HTTP-date Retry-After uses the injected current clock")
        let overlappingTransport = DescriptorTransport()
        await overlappingTransport.configure(failures: [0], failureStatus: 503)
        let barrier = DescriptorRetryBarrier()
        let overlapping = PublicCatalogDescriptors(transport: overlappingTransport,
            sleep: { try await barrier.sleep($0) })
        let earlier = Task { try await overlapping.load(ids: [sample[0]], market: "US", language: "en-US") }
        for _ in 0..<200 {
            if await barrier.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await overlappingTransport.configure(failures: [1], failureStatus: 429, retryAfter: "120")
        do { _ = try await overlapping.load(ids: [sample[1]], market: "US", language: "en-US") }
        catch PCGamesError.http(429) { }
        await barrier.release()
        do {
            _ = try await earlier.value
            check(false, "REQ98 existing retry loop cannot bypass another batch's server cooldown")
        } catch PCGamesError.http(429) {
            check(await overlappingTransport.requests.count == 2,
                  "REQ98 overlapping direct batches honor newly published shared cooldown before every request")
        }
        let retiringTransport = DescriptorTransport()
        await retiringTransport.configure(failures: [0], failureStatus: 503)
        let waitingDelay = DescriptorRetryClock(block: true)
        let retiringStore = PublicCatalogDescriptors(transport: retiringTransport,
            sleep: { try await waitingDelay.sleep($0) })
        let scope = UUID()
        await retiringStore.bind(nil, owner: scope)
        let firstWaiter = Task { try await retiringStore.load(ids: sample, market: "US", language: "en-US") }
        for _ in 0..<200 {
            if await !waitingDelay.delays.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let secondWaiter = Task { try await retiringStore.load(ids: sample, market: "US", language: "en-US") }
        for _ in 0..<10 { await Task.yield() }
        await retiringStore.unbind(owner: scope)
        for waiter in [firstWaiter, secondWaiter] {
            do { _ = try await waiter.value; check(false, "REQ98 retired read cannot publish") }
            catch is CancellationError { check(true, "REQ98 session retirement cancels coalesced retry waiters") }
        }
        let retiredRequests = await retiringTransport.requests.count, retiredCache = await retiringStore.cachedCount
        check(retiredRequests == 1 && retiredCache == 0,
              "REQ98 coalesced consumers issue no stale-account retry or cache publication after retirement")
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
        for scenario in ["descriptorsretry", "descriptorscapacity", "descriptorsauth", "descriptorsretryexhausted",
                         "descriptorscommandretry", "descriptorscommandexhausted", "descriptorscommandauth",
                         "descriptorscommandpermanent", "descriptorscommandmalformed"] {
            let backend = try ManagementClient()
            _ = try await backend.connect(BackendConfiguration(executable: helper,
                stateDirectory: root.appendingPathComponent(scenario)))
            let clock = DescriptorRetryClock()
            let recovery = PublicCatalogDescriptors(transport: DescriptorTransport(),
                sleep: { try await clock.sleep($0) })
            await recovery.bind(backend, owner: UUID())
            let data: Data
            do {
                data = try await recovery.load(ids: sample, market: "US", language: "en-US")
            } catch {
                let requests = await recovery.requests, delays = await clock.delays
                let expected: Bool
                switch scenario {
                case "descriptorscommandexhausted":
                    expected = error as? ManagementError == .backendError("NETWORK_UNAVAILABLE", retryable: true)
                        && requests == 4 && delays == [.seconds(1), .seconds(2), .seconds(4)]
                case "descriptorscommandauth":
                    expected = error as? ManagementError == .backendError("AUTH_INVALID", retryable: true)
                        && requests == 1 && delays.isEmpty
                case "descriptorscommandpermanent":
                    expected = error as? ManagementError == .backendError("NETWORK_UNAVAILABLE", retryable: false)
                        && requests == 1 && delays.isEmpty
                case "descriptorscommandmalformed":
                    expected = (error as? ManagementError == .invalidPayload || error as? ManagementError == .invalidFrame)
                        && requests == 1 && delays.isEmpty
                default: expected = false
                }
                check(expected, "REQ98 typed command failure \(scenario) has exact bounded retry/refusal behavior (\(error), requests \(requests), delays \(delays))")
                check(await backend.close(), "REQ98 command failure fixture closes its synthetic backend")
                continue
            }
            let products = try JSONDecoder().decode(PCGamesCatalog.self, from: data).Products
            let delays = await clock.delays, requests = await recovery.requests
            let failures = await recovery.failures(ids: sample, market: "US", language: "en-US")
            let expected: Bool
            switch scenario {
            case "descriptorscommandretry":
                expected = products.count == 3 && requests == 3
                    && delays == [.seconds(1), .seconds(2)] && failures.isEmpty
            case "descriptorsauth":
                expected = products.count == 2 && requests == 1 && delays.isEmpty && failures.count == 1
            case "descriptorsretryexhausted":
                expected = products.count == 2 && requests == 4
                    && delays == [.seconds(1), .seconds(2), .seconds(4)] && failures.count == 1
            default:
                expected = products.count == 3 && requests == 3
                    && delays == [.seconds(1), .seconds(2)] && failures.isEmpty
            }
            check(expected,
                  "REQ98 managed \(scenario) retries only transient failed IDs, preserving successful peers and refusing auth retry")
            check(await backend.close(), "REQ98 managed retry fixture closes its synthetic backend")
        }
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
              && failedController.resolutionNotice?.contains("available games are still here") == true
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
