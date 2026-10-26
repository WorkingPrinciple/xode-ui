// SPDX-License-Identifier: GPL-3.0-only
#if !XODUS_SHIPPING
import CryptoKit
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
    var sharedTitle: String?
    private(set) var inFlight = 0
    private(set) var peakInFlight = 0
    var revision = ""
    var failingIDs = Set<String>()
    var heldIDs = Set<String>()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldReleased = false

    func configure(blocked: Set<Int> = [], failures: Set<Int> = [], omitted: Set<String> = [], foreign: Bool = false,
                   failureStatus: Int = 400, retryAfter: String? = nil, nonPC: Set<String> = [], revision: String = "",
                   failingIDs: Set<String> = [], heldIDs: Set<String> = []) {
        self.blocked = blocked; self.failures = failures; self.omitted = omitted
        self.foreign = foreign
        self.failureStatus = failureStatus
        self.retryAfter = retryAfter
        self.nonPC = nonPC
        self.revision = revision
        self.failingIDs = failingIDs
        self.heldIDs = heldIDs
        heldReleased = false
    }

    /// Releases requests held by product ID, independent of arrival order.
    func releaseHeld() {
        heldReleased = true
        for continuation in held { continuation.resume() }
        held = []
    }

    func requestedIDs(_ index: Int) -> [String] {
        guard index < requests.count, let url = requests[index].url,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "bigIds" })?.value else { return [] }
        return value.split(separator: ",").map(String.init)
    }

    func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }
    func useSharedTitle(_ title: String?) { sharedTitle = title }

    func send(_ request: URLRequest) async throws -> PCGamesHTTPResponse {
        let index = requests.count
        requests.append(request)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }
        if blocked.contains(index) { await withCheckedContinuation { continuations[index] = $0 } }
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let ids = items.first { $0.name == "bigIds" }!.value!.split(separator: ",").map(String.init)
        if !heldReleased, !heldIDs.isDisjoint(with: ids) { await withCheckedContinuation { held.append($0) } }
        if failures.contains(index) || !failingIDs.isDisjoint(with: ids) {
            return PCGamesHTTPResponse(status: failureStatus, data: Data(), retryAfter: retryAfter)
        }
        let products: [[String: Any]] = ids.filter { !omitted.contains($0) }.map {
            ["ProductId": foreign ? "FIXTURE99999" : $0, "ProductType": "Game", "ProductKind": "Game",
             "LocalizedProperties": [["ProductTitle": sharedTitle ?? "Game \($0)\(revision)", "Images": [],
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
        try await persistence(check: check)
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

        let priorityTransport = DescriptorTransport()
        await priorityTransport.configure(blocked: [0])
        let priorityStore = PublicCatalogDescriptors(transport: priorityTransport)
        let priorityArtwork = LibraryCatalogArtwork(descriptors: priorityStore)
        let warmupIDs = ids(16, offset: 6_000)
        let foregroundID = ids(1, offset: 7_000)[0]
        let warmup = Task {
            await priorityArtwork.load(ids: warmupIDs, market: "US", language: "en-US", priority: .background)
        }
        try await wait(priorityTransport, count: 1)
        let foreground = Task {
            await priorityArtwork.load(ids: [foregroundID], market: "US", language: "en-US")
        }
        try await wait(priorityTransport, count: 2)
        await foreground.value
        let foregroundIDs = await priorityTransport.requestedIDs(1)
        let warmupStillBlocked = await priorityTransport.inFlight == 1
        let foregroundPublished = priorityArtwork.images[foregroundID] != nil
        await priorityTransport.release(0)
        await warmup.value
        check(foregroundIDs == [foregroundID] && warmupStillBlocked && foregroundPublished,
              "REQ-121: Foreground artwork completes while the 16-ID background warmup remains blocked")

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
        let many = ids(21)
        // Parallel batches arrive in either order, so the failing second batch is chosen and held by product ID.
        await partialTransport.configure(failingIDs: [many[20]], heldIDs: [many[20]])
        let partialClient = PCGamesClient(transport: partialTransport)
        let progressLog = DescriptorProgressLog()
        let partialRun = Task {
            try await partialClient.resolveCollection(ids: many, kinds: [many[20]: .subscription], candidateCount: 21,
                market: "US", language: "en-US", accountHash: "account-a", progress: { progressLog.snapshots.append($0) })
        }
        for _ in 0..<2_000 where !progressLog.snapshots.contains(where: { $0.games.count == 20 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let publishedBeforeLast = progressLog.snapshots.count
        await partialTransport.releaseHeld()
        let partial = try await partialRun.value
        let progress = progressLog.snapshots
        check(partial.games.count == 20 && partial.unresolvedIDs == [many[20]]
              && partial.unresolvedCount == 1 && partial.excludedCount == 0 && !partial.isComplete,
              "Failed second batch preserves twenty useful PC records and one explicit unresolved candidate")
        check(progress.count == 3 && publishedBeforeLast == 2 && progress[1].games.count == 20
              && progress[1].unresolvedCount == 1,
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
        check(missing.games.count == 2 && missing.unresolvedIDs == [sample[1]] && missing.excludedCount == 0
              && missing.detailFailureCount == 0,
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
                         "descriptorscommandpermanent", "descriptorscommandmalformed", "descriptorsunavailable"] {
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
            case "descriptorsunavailable":
                expected = products.count == 2 && requests == 1 && delays.isEmpty && failures.isEmpty
                let client = PCGamesClient(transport: DescriptorTransport(), descriptors: recovery)
                let snapshot = try await client.resolveCollection(ids: sample, kinds: [:], candidateCount: 3,
                                                                  market: "US", language: "en-US")
                check(snapshot.unresolvedIDs == [sample[2]] && snapshot.detailFailureCount == 0
                      && snapshot.games.count == 2,
                      "COR152: Permanent per-product package rejection stays unresolved without a catalogue failure banner")
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

        func rejection(_ field: String?, _ value: JSONValue? = nil, now: Date? = nil) throws -> String? {
            var record = validRecord
            if let field, let value { record[field] = value }
            let decoded = try JSONValue.object(record).decode(CatalogDescriptors.Record.self)
            return CatalogDescriptors.rejection(decoded, market: "GB", language: "en-GB",
                                               now: now ?? wireTime.addingTimeInterval(1))
        }
        let reasons = [
            try rejection(nil), try rejection("market", .string("US")), try rejection("language", .string("en-US")),
            try rejection("product", .object(["ProductId": .string(sample[1])])),
            try rejection("freshness", .string("stale")),
            try rejection("expiresAt", .string(formatter.string(from: wireTime.addingTimeInterval(301)))),
            try rejection(nil, now: wireTime.addingTimeInterval(300)), try rejection(nil, now: wireTime.addingTimeInterval(-31))
        ]
        check(reasons == [nil, "market", "language", "productIdentity", "freshness", "lifetime", "expired", "checkedInFuture"],
              "REQ-121 diagnosis: each managed descriptor rejection is named without product identifiers: \(reasons)")

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
              && failedController.resolutionNotice == nil
              && failedController.detailRetriesLeft == PCGamesController.detailRetryDelays.count
              && !failedController.accessIsCurrent,
              "Total public metadata failure reports incomplete Library details, never a last-complete or genuine-zero claim; P0: it retries silently before any notice")
        let retryScheduled = failedController.detailRetryPending
            && failedController.detailRetriesLeft == PCGamesController.detailRetryDelays.count
        check(retryScheduled && failedController.surfacedError == nil && failedController.error != nil,
              "Review M2/P0: While a silent retry is scheduled the library error stays quiet")
        failedController.scheduleDetailRetry(account: "another-account")
        let staleRetryPending = failedController.detailRetryPending
        try await Task.sleep(for: PCGamesController.detailRetryDelays[0] + .milliseconds(400))
        check(staleRetryPending && !failedController.detailRetryPending
              && failedController.detailRetriesLeft == PCGamesController.detailRetryDelays.count
              && failedController.surfacedError == failedController.error,
              "Review M1: A retry that wakes for another account doesn't fire, stops counting as pending, and lets the error surface")
        await failedController.retireUnifiedAccount()
        check(retryScheduled && !failedController.detailRetryPending
              && failedController.detailRetriesLeft == PCGamesController.detailRetryDelays.count,
              "Review Low: A failed library read schedules one bounded silent retry, and sign-out cancels it and restores the budget")
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

        let concurrencyTransport = DescriptorTransport()
        await concurrencyTransport.configure(blocked: Set(0..<5))
        let boundedIDs = ids(100, offset: 9_000)
        let concurrentResolution = Task {
            try await PCGamesClient(transport: concurrencyTransport, descriptors: PublicCatalogDescriptors(transport: concurrencyTransport))
                .resolveCollection(ids: boundedIDs, kinds: [:], candidateCount: 100, market: "US", language: "en-US")
        }
        try await wait(concurrencyTransport, count: PCGamesClient.descriptorConcurrency)
        try await Task.sleep(for: .milliseconds(50))
        let inFlight = await concurrencyTransport.requests.count
        await concurrencyTransport.release(1)
        try await wait(concurrencyTransport, count: 3)
        try await Task.sleep(for: .milliseconds(30))
        let afterOne = await concurrencyTransport.requests.count
        for index in [0, 2, 3, 4] {
            await concurrencyTransport.release(index)
            try await Task.sleep(for: .milliseconds(10))
        }
        let boundedResult = try await concurrentResolution.value
        let totalRequests = await concurrencyTransport.requests.count
        check(PCGamesClient.descriptorConcurrency == 2 && inFlight == 2 && afterOne == 3
              && boundedResult.games.count == 100 && boundedResult.isComplete
              && totalRequests == 5,
              "REQ-119: Collection resolution reads two descriptor batches at a time, inside the producer's four-operation limit, and merges out-of-order results completely")

        // REQ-119 review L4: collection resolution plus a concurrent artwork read stay inside the
        // producer's four-operation limit with one license read alongside, and equal titles keep a stable order.
        let limitTransport = DescriptorTransport()
        await limitTransport.configure(blocked: [0, 1])
        let limitStore = PublicCatalogDescriptors(transport: limitTransport)
        let limitResolution = Task {
            try await PCGamesClient(transport: limitTransport, descriptors: limitStore)
                .resolveCollection(ids: ids(100, offset: 20_000), kinds: [:], candidateCount: 100, market: "US", language: "en-US")
        }
        try await wait(limitTransport, count: 2)
        let limitArtwork = LibraryCatalogArtwork(descriptors: limitStore)
        let artworkRead = Task { await limitArtwork.load(ids: ids(20, offset: 30_000), market: "US", language: "en-US") }
        try await wait(limitTransport, count: 3)
        try await Task.sleep(for: .milliseconds(30))
        let licenseReads = 1
        let peakWithBlocked = await limitTransport.peakInFlight
        await limitTransport.release(0)
        await limitTransport.release(1)
        _ = try await limitResolution.value
        await artworkRead.value
        let peak = await limitTransport.peakInFlight
        check(peakWithBlocked == 3 && peak + licenseReads <= 4,
              "REQ-119 review L4: Two collection batches, an artwork read and a license read never exceed the producer's four operations (peak \(peak) + \(licenseReads))")
        var orders: [[String]] = []
        for reversed in [false, true] {
            let tieTransport = DescriptorTransport()
            await tieTransport.useSharedTitle("Same Title")
            await tieTransport.configure(blocked: [0, 1])
            let tieIDs = ids(40, offset: 40_000)
            let resolution = Task {
                try await PCGamesClient(transport: tieTransport, descriptors: PublicCatalogDescriptors(transport: tieTransport))
                    .resolveCollection(ids: tieIDs, kinds: [:], candidateCount: 40, market: "US", language: "en-US")
            }
            try await wait(tieTransport, count: 2)
            for index in reversed ? [1, 0] : [0, 1] {
                await tieTransport.release(index)
                try await Task.sleep(for: .milliseconds(20))
            }
            orders.append(try await resolution.value.games.map(\.id))
        }
        check(orders.count == 2 && orders[0] == orders[1] && orders[0] == orders[0].sorted(),
              "REQ-119 review L4: Games with equal titles keep the same display order whichever batch finishes first")

        let tolerantIDs = ids(3, offset: 50_000)
        func product(_ id: String) -> [String: Any] {
            ["ProductId": id, "ProductType": "Game", "LocalizedProperties": [["ProductTitle": "Game \(id)"]]]
        }
        let mixed = try JSONSerialization.data(withJSONObject: ["Products": [
            product(tolerantIDs[0]), ["ProductId": 42, "LocalizedProperties": "broken"],
            product("FIXTURE99999"), product(tolerantIDs[0]), product(tolerantIDs[2])]])
        let tolerant = try PCGamesClient.tolerantProducts(mixed, batch: tolerantIDs)
        check(tolerant.products.map(\.ProductId) == [tolerantIDs[0], tolerantIDs[2]] && tolerant.dropped.isEmpty,
              "P0: One unreadable, foreign or duplicate product is dropped on its own; the rest of the batch still resolves")
        let brokenOne = try JSONSerialization.data(withJSONObject: ["Products": [
            product(tolerantIDs[0]), ["ProductId": tolerantIDs[1], "LocalizedProperties": "broken"]]])
        let partialBatch = try PCGamesClient.tolerantProducts(brokenOne, batch: tolerantIDs)
        let allBroken = try JSONSerialization.data(withJSONObject: ["Products": tolerantIDs.map {
            ["ProductId": $0, "LocalizedProperties": "broken"] as [String: Any] }])
        var allBrokenThrows = false
        do { _ = try PCGamesClient.tolerantProducts(allBroken, batch: tolerantIDs) } catch { allBrokenThrows = true }
        check(partialBatch.products.map(\.ProductId) == [tolerantIDs[0]] && partialBatch.dropped == [tolerantIDs[1]]
              && allBrokenThrows,
              "Review H: An unreadable item is reported as a failure to retry (not silently dropped), and an all-unreadable batch fails instead of counting as complete")

        struct UnreadableTransport: PCGamesTransport {
            let broken: @Sendable (String) -> Bool
            func send(_ request: URLRequest) async throws -> PCGamesHTTPResponse {
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let ids = items.first { $0.name == "bigIds" }!.value!.split(separator: ",").map(String.init)
                let products: [[String: Any]] = ids.map { id in
                    broken(id) ? ["ProductId": id, "LocalizedProperties": "broken"] : [
                        "ProductId": id, "ProductType": "Game", "ProductKind": "Game",
                        "LocalizedProperties": [["ProductTitle": "Game \(id)", "Images": []]],
                        "DisplaySkuAvailabilities": [["Sku": ["Properties": ["Packages": [
                            ["PlatformDependencies": [["PlatformName": "Windows.Desktop"]]]]]]]]]
                }
                return PCGamesHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: ["Products": products]))
            }
        }
        func unreadableClient(_ broken: @escaping @Sendable (String) -> Bool) -> PCGamesClient {
            let transport = UnreadableTransport(broken: broken)
            return PCGamesClient(transport: transport, descriptors: PublicCatalogDescriptors(transport: transport))
        }
        var unreadableFailures = -1
        do {
            let all = try await unreadableClient { _ in true }.resolveCollection(ids: ids(3, offset: 60_000), kinds: [:],
                candidateCount: 3, market: "US", language: "en-US")
            unreadableFailures = all.games.isEmpty ? all.detailFailureCount : -2
        } catch { unreadableFailures = 3 }
        let mixedIDs = ids(25, offset: 61_000)
        let brokenSet = Set(mixedIDs.prefix(20).suffix(2))
        let mixedResult = try await unreadableClient { brokenSet.contains($0) }.resolveCollection(ids: mixedIDs, kinds: [:],
            candidateCount: 25, market: "US", language: "en-US")
        print("REVIEW-H mixed games \(mixedResult.games.count) failures \(mixedResult.detailFailureCount) unreadable \(unreadableFailures)")
        check(unreadableFailures == 3 && mixedResult.games.count == 23 && mixedResult.detailFailureCount == 2
              && brokenSet.isSubset(of: mixedResult.unresolvedIDs),
              "Review H: Unreadable items are counted as detail failures (so the library retries them); an all-unreadable library counts every item as failed instead of a clean zero-game library")
        let artTransport = UnreadableTransport { brokenSet.contains($0) }
        let skipArtwork = LibraryCatalogArtwork(transport: artTransport)
        await skipArtwork.load(ids: Array(mixedIDs.prefix(20)), market: "US", language: "en-US")
        check(skipArtwork.error != nil && brokenSet.allSatisfy { skipArtwork.detailErrors[$0] != nil && skipArtwork.images[$0] == nil }
              && skipArtwork.images.count == 18,
              "Review M2: Unreadable artwork/details items are recorded as retryable failures, so the Library's silent retry runs")
        let budget = PCGamesController(store: UnavailableDescriptorCredentials(), client: PCGamesClient(transport: DescriptorTransport()))
        let full = budget.detailRetriesLeft
        budget.resetDetailRetries()
        check(full == PCGamesController.detailRetryDelays.count && budget.detailRetriesLeft == full,
              "Review M3: The silent-retry budget starts full and is restored by a user, explicit or foreground refresh")

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

@MainActor
private final class DescriptorProgressLog {
    var snapshots: [PCGamesSnapshot] = []
}

private final class DescriptorURLState: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var offline = false
    private var revision = ""
    func reset(offline: Bool, revision: String = "") {
        lock.withLock { urls = []; self.offline = offline; self.revision = revision }
    }
    func record(_ url: URL) -> (offline: Bool, revision: String) {
        lock.withLock { urls.append(url); return (offline, revision) }
    }
    var count: Int { lock.withLock { urls.count } }
}

/// Answers public display-catalog requests through the real `PCGamesHTTP` session, or fails them as offline.
private final class DescriptorURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = DescriptorURLState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (offline, revision) = Self.state.record(url)
        let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "bigIds" }?.value?.split(separator: ",").map(String.init) ?? []
        let products: [[String: Any]] = ids.map {
            ["ProductId": $0, "ProductType": "Game", "ProductKind": "Game",
             "LocalizedProperties": [["ProductTitle": "Game \($0)\(revision)", "Images": [],
                                      "ProductDescription": "Synthetic descriptor"]],
             "DisplaySkuAvailabilities": [["Sku": ["Properties": ["Packages": [
                ["PlatformDependencies": [["PlatformName": "Windows.Desktop"]]]]]]]]]
        }
        guard !offline, !ids.isEmpty,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]),
              let data = try? JSONSerialization.data(withJSONObject: ["Products": products]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension PublicDescriptorChecks {
    /// REQ-121: saved public descriptors across restarts, stale-while-revalidate, corruption and the network cap.
    static func persistence(check: (Bool, String) -> Void) async throws {
        func ids(_ count: Int, offset: Int) -> [String] {
            (offset..<offset + count).map { String(format: "9DESC%07d", $0) }
        }
        func wait(_ transport: DescriptorTransport, count: Int) async throws {
            for _ in 0..<2_000 {
                if await transport.requests.count >= count { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw PCGamesError.transport
        }
        func queued(_ store: PublicCatalogDescriptors, foreground: Int, background: Int) async throws {
            for _ in 0..<2_000 {
                let queued = await store.queuedNetwork
                if queued.foreground == foreground, queued.background == background { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw PCGamesError.transport
        }
        /// Releases blocked requests in arrival order, waiting for each to arrive first.
        func drain(_ transport: DescriptorTransport, from start: Int = 0, through end: Int) async throws {
            for index in start..<end {
                try await wait(transport, count: index + 1)
                await transport.release(index)
            }
        }
        func titles(_ data: Data) throws -> [String] {
            try JSONDecoder().decode(PCGamesCatalog.self, from: data).Products
                .map { $0.LocalizedProperties?.first?.ProductTitle ?? "" }
        }
        guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CatalogMediaCacheError.storage
        }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("DescriptorPersistence-\(UUID().uuidString)")
        free(canonical)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "REQ-121: Synthetic descriptor cache files are cleaned") }
        }
        let clock = DescriptorClock()
        let directory = root.appendingPathComponent("descriptors")
        func disk(_ path: URL = directory, maximumBytes: Int64 = PublicDescriptorDiskCache.maximumBytes) -> PublicDescriptorDiskCache {
            PublicDescriptorDiskCache(directory: path, maximumBytes: maximumBytes, now: { clock.now() })
        }
        func store(_ transport: any PCGamesTransport, _ persistence: PublicDescriptorDiskCache? = nil) -> PublicCatalogDescriptors {
            PublicCatalogDescriptors(transport: transport, now: { clock.now() }, sleep: { _ in }, persistence: persistence)
        }
        check(PublicDescriptorDiskCache.production(arguments: ["--library-access-check"]) == nil
              && PublicDescriptorDiskCache.production(arguments: ["--live-check"]) == nil
              && PublicDescriptorDiskCache.production(arguments: []) != nil,
              "REQ-121: Checks and previews never read or write the app's saved public descriptors")

        let sample = ids(3, offset: 7_000)
        let http = PCGamesHTTP(protocolClasses: [DescriptorURLProtocol.self])
        DescriptorURLProtocol.state.reset(offline: false)
        let firstRun = store(http, disk())
        let original = try await firstRun.load(ids: sample, market: "US", language: "en-US")
        await firstRun.flushPersistence()
        let saved = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".descriptor") }
        check(DescriptorURLProtocol.state.count == 1 && saved.count == 3,
              "REQ-121: A network descriptor read saves each public product once, keyed by product, market and language")

        clock.advance(600)
        DescriptorURLProtocol.state.reset(offline: true)
        let restarted = store(http, disk())
        let start = ContinuousClock.now
        let restartRead = try await restarted.read(ids: sample, market: "US", language: "en-US")
        let restartElapsed = start.duration(to: .now)
        _ = await restartRead.revalidation?.value
        let restartExpiry = await restarted.expirations(ids: sample, market: "US", language: "en-US")
        let restartFailures = await restarted.failures(ids: sample, market: "US", language: "en-US")
        check(try titles(restartRead.data) == titles(original) && restartRead.staleIDs == Set(sample)
              && restartExpiry.isEmpty && restartFailures.isEmpty,
              "REQ-121: After a restart past the 300-second lease, saved descriptors serve offline without becoming fresh or showing an error")
        let offlineControl = store(http)
        do {
            _ = try await offlineControl.load(ids: sample, market: "US", language: "en-US")
            check(false, "REQ-121: Without the saved copy the same offline read fails")
        } catch {
            check(true, "REQ-121: Without the saved copy the same offline read fails")
        }
        let offlineClient = PCGamesClient(transport: http, descriptors: store(http, disk()))
        let offlineLibrary = try await offlineClient.resolveCollection(ids: sample, kinds: [:], candidateCount: 3,
            market: "US", language: "en-US", accountHash: "account-a")
        let offlineArtwork = LibraryCatalogArtwork(descriptors: store(http, disk()), now: { clock.now() })
        await offlineArtwork.load(ids: sample, market: "US", language: "en-US")
        await offlineArtwork.waitForRevalidations()
        check(offlineLibrary.games.count == 3 && offlineLibrary.isComplete
              && offlineArtwork.images.count == 3 && offlineArtwork.error == nil,
              "REQ-121: Restart library resolution and tiles draw from saved descriptors with no network")
        let otherScope = try? await restarted.load(ids: sample, market: "GB", language: "en-GB")
        check(otherScope == nil, "REQ-121: Saved descriptors never answer another market or language")
        print("DESCRIPTOR_RESTART titles=3 elapsed=\(restartElapsed) network=offline synthetic_url_protocol=true")

        let swrTransport = DescriptorTransport()
        await swrTransport.configure(blocked: [0], revision: " v2")
        let swrStore = store(swrTransport, disk())
        let swrArtwork = LibraryCatalogArtwork(descriptors: swrStore, now: { clock.now() })
        await swrArtwork.load(ids: sample, market: "US", language: "en-US")
        try await wait(swrTransport, count: 1)
        let staleTitles = sample.compactMap { swrArtwork.images[$0]?.product.title }
        check(staleTitles == sample.map { "Game \($0)" } && swrArtwork.pendingIDs.isEmpty,
              "REQ-121: Saved tiles show at once while their revalidation is still on the network")
        let swrClient = PCGamesClient(transport: swrTransport, descriptors: swrStore)
        let swrProgress = DescriptorProgressLog()
        let swrLibrary = Task {
            try await swrClient.resolveCollection(ids: sample, kinds: [:], candidateCount: 3, market: "US",
                language: "en-US", accountHash: "account-a", progress: { swrProgress.snapshots.append($0) })
        }
        for _ in 0..<2_000 where !swrProgress.snapshots.contains(where: { $0.games.count == 3 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let staleLibrary = swrProgress.snapshots.last
        let sharedRefresh = await swrTransport.requests.count
        check(staleLibrary?.games.map(\.title).sorted() == sample.map { "Game \($0)" }.sorted()
              && staleLibrary?.isComplete == true && sharedRefresh == 1,
              "REQ-121: The library publishes saved PC games before revalidation, sharing one in-flight refresh")
        await swrTransport.release(0)
        await swrArtwork.waitForRevalidations()
        let library = try await swrLibrary.value
        let freshTitles = sample.compactMap { swrArtwork.images[$0]?.product.title }
        let freshExpiry = await swrStore.expirations(ids: sample, market: "US", language: "en-US")
        let swrRequests = await swrTransport.requests.count
        check(freshTitles == sample.map { "Game \($0) v2" } && freshExpiry.count == 3,
              "REQ-121: A landed revalidation updates the tiles in place and is fresh for the normal lease")
        check(library.games.map(\.title).sorted() == sample.map { "Game \($0) v2" }.sorted()
              && swrProgress.snapshots.last?.games.map(\.title).sorted() == library.games.map(\.title).sorted()
              && swrRequests == 1,
              "REQ-121: The final library snapshot reflects revalidated descriptors without a second request")
        await swrStore.flushPersistence()
        DescriptorURLProtocol.state.reset(offline: true)
        let afterUpdate = try await store(http, disk())
            .load(ids: sample, market: "US", language: "en-US")
        check(try titles(afterUpdate) == sample.map { "Game \($0) v2" },
              "REQ-121: Revalidated details replace the saved copy for the next restart")

        clock.advance(600)
        let failedTransport = DescriptorTransport()
        await failedTransport.configure(failures: [0, 1, 2, 3], failureStatus: 404)
        let failedStore = store(failedTransport, disk())
        let failedArtwork = LibraryCatalogArtwork(descriptors: failedStore, now: { clock.now() })
        await failedArtwork.load(ids: sample, market: "US", language: "en-US")
        await failedArtwork.waitForRevalidations()
        await failedArtwork.load(ids: sample, market: "US", language: "en-US")
        let failedRequests = await failedTransport.requests.count
        check(failedArtwork.images.count == 3 && failedArtwork.error == nil
              && sample.allSatisfy { failedArtwork.images[$0]?.product.title == "Game \($0) v2" } && failedRequests == 1,
              "REQ-121: A failed revalidation keeps saved tiles without an error and waits before asking again")

        let delistedDirectory = root.appendingPathComponent("delisted")
        let delistedIDs = ids(3, offset: 7_300)
        let delistedSeed = store(DescriptorTransport(), disk(delistedDirectory))
        _ = try await delistedSeed.load(ids: delistedIDs, market: "US", language: "en-US")
        await delistedSeed.flushPersistence()
        clock.advance(600)
        let delistTransport = DescriptorTransport()
        await delistTransport.configure(omitted: [delistedIDs[2]])
        let delistStore = store(delistTransport, disk(delistedDirectory))
        let delistLibrary = try await PCGamesClient(transport: delistTransport, descriptors: delistStore)
            .resolveCollection(ids: delistedIDs, kinds: [:], candidateCount: 3, market: "US", language: "en-US")
        await delistStore.flushPersistence()
        let delistedFile = delistedDirectory.appendingPathComponent(PublicDescriptorDiskCache.fileName(
            .init(id: delistedIDs[2], market: "US", language: "en-us")))
        DescriptorURLProtocol.state.reset(offline: true)
        let keptSaved = try await store(http, disk(delistedDirectory))
            .read(ids: Array(delistedIDs.prefix(2)), market: "US", language: "en-US")
        var delistedServed = true
        do { _ = try await store(http, disk(delistedDirectory)).read(ids: [delistedIDs[2]], market: "US", language: "en-US") }
        catch { delistedServed = false }
        check(delistLibrary.games.count == 2 && delistLibrary.unresolvedIDs == [delistedIDs[2]]
              && !FileManager.default.fileExists(atPath: delistedFile.path) && keptSaved.staleIDs.count == 2 && !delistedServed,
              "REQ-121: A product its revalidation no longer returns loses its saved copy and stays unresolved")

        let capTransport = DescriptorTransport()
        await capTransport.configure(blocked: Set(0..<16))
        let capStore = store(capTransport, disk())
        var foreground: [Task<Data, Error>] = []
        for batch in 0..<5 {
            let batchIDs = ids(20, offset: 8_000 + batch * 20)
            foreground.append(Task { try await capStore.load(ids: batchIDs, market: "US", language: "en-US") })
            if batch < 4 { try await wait(capTransport, count: batch + 1) }
        }
        try await queued(capStore, foreground: 1, background: 0)
        let capped = await capTransport.requests.count
        let staleRead = try await capStore.read(ids: sample, market: "US", language: "en-US")
        try await queued(capStore, foreground: 1, background: 1)
        let urgent = ids(20, offset: 9_500)
        let urgentRead = Task { try await capStore.load(ids: urgent, market: "US", language: "en-US") }
        try await queued(capStore, foreground: 2, background: 1)
        let queuedRequests = await capTransport.requests.count
        try await drain(capTransport, through: 1)
        try await wait(capTransport, count: 5)
        let fifth = await capTransport.requestedIDs(4)
        try await drain(capTransport, from: 1, through: 2)
        try await wait(capTransport, count: 6)
        let sixth = await capTransport.requestedIDs(5)
        try await drain(capTransport, from: 2, through: 7)
        for task in foreground { _ = try await task.value }
        _ = try await urgentRead.value
        _ = await staleRead.revalidation?.value
        let seventh = await capTransport.requestedIDs(6), peak = await capStore.peakNetwork
        let total = await capTransport.requests.count
        check(capped == 4 && queuedRequests == 4 && peak == PublicCatalogDescriptors.directNetworkLimit && total == 7
              && staleRead.staleIDs == Set(sample),
              "REQ-121: Descriptor network reads from every consumer stay within the cap of four direct requests")
        check(fifth == ids(20, offset: 8_080) && sixth == urgent && Set(seventh) == Set(sample),
              "REQ-121: Queued foreground reads are admitted in order and before saved-copy revalidation")

        let promoteTransport = DescriptorTransport()
        await promoteTransport.configure(blocked: Set(0..<8))
        let promoteStore = store(promoteTransport)
        var promoteFill: [Task<Data, Error>] = []
        for batch in 0..<4 {
            let batchIDs = ids(20, offset: 12_000 + batch * 20)
            promoteFill.append(Task { try await promoteStore.load(ids: batchIDs, market: "US", language: "en-US") })
            try await wait(promoteTransport, count: batch + 1)
        }
        let sharedIDs = ids(4, offset: 12_500)
        let warmupRead = Task {
            try await promoteStore.read(ids: sharedIDs, market: "US", language: "en-US", background: true)
        }
        try await queued(promoteStore, foreground: 0, background: 1)
        let firstScreenRead = Task { try await promoteStore.read(ids: sharedIDs, market: "US", language: "en-US") }
        try await queued(promoteStore, foreground: 1, background: 0)
        try await drain(promoteTransport, through: 5)
        for task in promoteFill { _ = try await task.value }
        let joined = try await firstScreenRead.value, warmed = try await warmupRead.value
        let promoteRequests = await promoteTransport.requests.count, promotedIDs = await promoteTransport.requestedIDs(4)
        check(promoteRequests == 5 && promotedIDs == sharedIDs
              && !joined.data.isEmpty && !warmed.data.isEmpty,
              "REQ-121 review L6: A first-screen read joining a queued background warmup promotes it ahead of other background work, with one shared request")

        // Each defect below is planted in an otherwise valid, in-age record, so each check stands alone.
        let corruptDirectory = root.appendingPathComponent("corrupt")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        func digestOf(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func body(_ id: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["ProductId": id, "ProductType": "Game"], options: [.sortedKeys])
        }
        func record(_ id: String, schema: Int = PublicDescriptorDiskCache.schemaVersion, productID: String? = nil,
                    market: String = "US", language: String = "en-us", fetchedAt: Date? = nil,
                    product: Data? = nil, digest: String? = nil) throws -> Data {
            let product = try product ?? body(id)
            return try encoder.encode(PublicDescriptorRecord(schema: schema, productID: productID ?? id, market: market,
                language: language, fetchedAt: fetchedAt ?? clock.now(), digest: digest ?? digestOf(product),
                product: product))
        }
        let other = "9DESC0007999"
        let defects: [(label: String, make: (String) throws -> Data)] = [
            ("unreadable bytes", { _ in Data("not a descriptor".utf8) }),
            ("a foreign schema version", { try record($0, schema: PublicDescriptorDiskCache.schemaVersion + 1) }),
            ("another product's ID", { try record($0, productID: other) }),
            ("another market", { try record($0, market: "GB") }),
            ("another language", { try record($0, language: "en-gb") }),
            ("a digest that doesn't match", { try record($0, digest: digestOf(try body(other))) }),
            ("a product body for another ID", { try record($0, product: try body(other)) }),
            ("an age over seven days", {
                try record($0, fetchedAt: clock.now().addingTimeInterval(-PublicDescriptorDiskCache.maximumAge - 1)) }),
            ("a fetch time in the future", { try record($0, fetchedAt: clock.now().addingTimeInterval(3_600)) })
        ]
        let controlID = "9DESC0007100"
        let controlKey = PublicDescriptorDiskCache.Key(id: controlID, market: "US", language: "en-us")
        let corruptDisk = disk(corruptDirectory)
        try await corruptDisk.store([controlKey: try body(controlID)], fetchedAt: clock.now())
        func defectID(_ offset: Int) -> String { String(format: "9DESC%07d", 7_101 + offset) }
        func file(_ id: String) -> URL {
            corruptDirectory.appendingPathComponent(PublicDescriptorDiskCache.fileName(.init(id: id, market: "US", language: "en-us")))
        }
        func plant() throws {
            for (offset, defect) in defects.enumerated() {
                let id = defectID(offset)
                try defect.make(id).write(to: file(id))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id).path)
            }
        }
        try plant()
        let control = await corruptDisk.read([controlKey])
        check(control[controlKey] != nil, "REQ-121: A valid in-age saved descriptor planted beside the damaged ones is served")
        for (offset, defect) in defects.enumerated() {
            let id = defectID(offset)
            let key = PublicDescriptorDiskCache.Key(id: id, market: "US", language: "en-us")
            let before = await corruptDisk.rejected
            let found = await corruptDisk.read([key])
            let after = await corruptDisk.rejected
            check(found.isEmpty && after == before + 1 && !FileManager.default.fileExists(atPath: file(id).path),
                  "REQ-121: A saved descriptor with \(defect.label) is rejected and deleted")
        }
        try plant()
        let corruptTransport = DescriptorTransport()
        let corruptStore = PublicCatalogDescriptors(transport: corruptTransport, now: { clock.now() },
                                                    persistence: disk(corruptDirectory))
        let damaged = defects.indices.map(defectID)
        let recovered = try await corruptStore.read(ids: damaged + [controlID], market: "US", language: "en-US")
        _ = await recovered.revalidation?.value
        let corruptRequests = await corruptTransport.requests.count
        let firstRequest = await corruptTransport.requestedIDs(0), secondRequest = await corruptTransport.requestedIDs(1)
        check(try titles(recovered.data) == damaged.map { "Game \($0)" } + [""]
              && recovered.staleIDs == [controlID] && corruptRequests == 2
              && (firstRequest == damaged || secondRequest == damaged),
              "REQ-121: Damaged saved descriptors are refetched in one request while the valid saved one is served")
        let digest = digestOf(try body(sample[0]))
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: directory)
        let linkedRead = try await store(DescriptorTransport(), disk(linked))
            .read(ids: sample, market: "US", language: "en-US")
        check(linkedRead.staleIDs.isEmpty, "REQ-121: A symlinked descriptor cache root is never trusted")

        let boundedDirectory = root.appendingPathComponent("bounded")
        let one = try encoder.encode(PublicDescriptorRecord(schema: PublicDescriptorDiskCache.schemaVersion,
            productID: sample[0], market: "US", language: "en-us", fetchedAt: clock.now(),
            digest: digest, product: try JSONSerialization.data(withJSONObject: [
                "ProductId": sample[0], "Pad": String(repeating: "x", count: 4096)]))).count
        let boundedDisk = disk(boundedDirectory, maximumBytes: Int64(one * 2 + one / 2))
        for id in ids(5, offset: 7_200) {
            clock.advance(1)
            try await boundedDisk.store([.init(id: id, market: "US", language: "en-us"): try JSONSerialization.data(
                withJSONObject: ["ProductId": id, "Pad": String(repeating: "x", count: 4096)])], fetchedAt: clock.now())
        }
        let bounded = try FileManager.default.contentsOfDirectory(atPath: boundedDirectory.path)
            .filter { $0.hasSuffix(".descriptor") }.count
        let boundedSweeps = await boundedDisk.sweeps
        check(bounded == 2 && boundedSweeps == 4,
              "REQ-121: The descriptor disk cache stays inside its byte budget, sweeping only when a save passes it")

        // Restart-shaped fixture: the owner's warm launch re-read 137 descriptors from the network.
        let fixtureDirectory = root.appendingPathComponent("restart-fixture")
        let fixtureIDs = ids(140, offset: 10_000)
        let warmup = store(DescriptorTransport(), disk(fixtureDirectory))
        _ = try await PCGamesClient(transport: DescriptorTransport(), descriptors: warmup).resolveCollection(
            ids: fixtureIDs, kinds: [:], candidateCount: 140, market: "US", language: "en-US")
        await warmup.flushPersistence()
        clock.advance(600)
        let offlineFixture = DescriptorTransport()
        await offlineFixture.configure(failures: Set(0..<64), failureStatus: 404)
        let fixtureStore = store(offlineFixture, disk(fixtureDirectory))
        let fixtureStart = ContinuousClock.now
        let fixtureArtwork = LibraryCatalogArtwork(descriptors: fixtureStore, now: { clock.now() })
        await fixtureArtwork.load(ids: Array(fixtureIDs.prefix(12)), market: "US", language: "en-US")
        let firstScreen = fixtureStart.duration(to: .now)
        let fixtureLibrary = try await PCGamesClient(transport: offlineFixture, descriptors: fixtureStore)
            .resolveCollection(ids: fixtureIDs, kinds: [:], candidateCount: 140, market: "US", language: "en-US")
        let resolved = fixtureStart.duration(to: .now)
        let fixtureStale = await fixtureStore.staleHits
        check(fixtureArtwork.images.count == 12 && fixtureLibrary.games.count == 140 && fixtureStale >= 140,
              "REQ-121: A 140-title restart resolves the library and first screen from saved descriptors")
        print("DESCRIPTOR_RESTART_FIXTURE titles=140 first_screen_descriptors=\(firstScreen) library_resolved=\(resolved) network_before_display=0 synthetic_transport=true")

        let signOutDirectory = root.appendingPathComponent("sign-out")
        let signOutDisk = disk(signOutDirectory)
        let signOutTransport = DescriptorTransport()
        let signOutDescriptors = store(signOutTransport, signOutDisk)
        let warmID = ids(1, offset: 11_000)[0]
        let pendingID = ids(1, offset: 11_001)[0]
        _ = try await signOutDescriptors.load(ids: [warmID], market: "US", language: "en-US")
        await signOutDescriptors.flushPersistence()
        let memoryBeforeSignOut = await signOutDescriptors.cachedCount
        let keySet = [
            PublicDescriptorDiskCache.Key(id: warmID, market: "US", language: "en-us"),
            PublicDescriptorDiskCache.Key(id: pendingID, market: "US", language: "en-us")
        ]
        let diskBeforeSignOut = await signOutDisk.read(keySet)
        check(memoryBeforeSignOut == 1 && diskBeforeSignOut.count == 1,
              "REQ-82: The sign-out regression starts with one in-memory and persisted public descriptor")
        await signOutTransport.configure(blocked: [1])
        let pendingRead = Task {
            try await signOutDescriptors.load(ids: [pendingID], market: "US", language: "en-US")
        }
        try await wait(signOutTransport, count: 2)
        let signOutArtwork = CatalogArtworkStore(diskCache: nil, descriptors: signOutDescriptors)
        try await signOutArtwork.clearForSignOut()
        let memoryAfterSignOut = await signOutDescriptors.cachedCount
        let diskAfterSignOut = await signOutDisk.read(keySet)
        await signOutTransport.release(1)
        let cancelledRead: Bool
        do {
            _ = try await pendingRead.value
            cancelledRead = false
        } catch is CancellationError {
            cancelledRead = true
        } catch {
            cancelledRead = false
        }
        await signOutDescriptors.flushPersistence()
        let diskAfterLateRead = await signOutDisk.read(keySet)
        check(memoryAfterSignOut == 0 && diskAfterSignOut.isEmpty && cancelledRead && diskAfterLateRead.isEmpty,
              "REQ-82: Sign-out clears public descriptors in memory and on disk, cancels in-flight reads, and fences late writes")
    }
}
#endif
