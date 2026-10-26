// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OSLog
import XodusManagement

actor PublicCatalogDescriptors {
    static let shared = PublicCatalogDescriptors(persistence: PublicDescriptorDiskCache.production())
    /// Direct public HTTP has no producer limit; managed reads stay inside the producer's four operations.
    static let directNetworkLimit = 4
    /// A consumer shown a saved descriptor asks again after this long if its revalidation failed.
    static let staleRetryDelay: TimeInterval = 60

    /// What a revalidation learned about saved descriptors: products whose details changed, and products the
    /// network no longer returned (delisted or unavailable), whose saved copies were deleted.
    struct Revalidated: Sendable {
        var changed = Set<String>()
        var withdrawn = Set<String>()
    }
    /// A read's products, which of them came from the saved copy, and their background revalidation.
    struct Read: Sendable {
        let data: Data
        let staleIDs: Set<String>
        let revalidation: Task<Revalidated, Never>?
    }
    private struct Key: Hashable {
        let id: String
        let market: String
        let language: String
        var saved: PublicDescriptorDiskCache.Key { .init(id: id, market: market, language: language) }
    }
    private struct Revalidation {
        let id: UUID
        let stale: Data
        let task: Task<Revalidated, Never>
    }
    private struct Waiter {
        let id: UUID
        let background: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct Entry {
        let bytes: Data
        let expiresAt: Date
        var usedAt: Date
    }
    private struct Batch {
        var entries: [String: Entry] = [:]
        var failures: [String: String] = [:]
        var retryable = Set<String>()
    }
    private struct TransientFailure: Error {
        let status: Int
        let retryAfter: TimeInterval?
    }
    private struct Pending {
        let task: Task<Data?, Error>
        let network: Bool
    }
    private let transport: any PCGamesTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var batches: [UUID: Task<Batch, Error>] = [:]
    private var retryNotBefore: Date?
    private var client: ManagementClient?
    private var owner: UUID?
    private var generation = UUID()
    private var entries: [Key: Entry] = [:]
    private var errors: [Key: String] = [:]
    private var pending: [Key: Pending] = [:]
    private var revalidating: [Key: Revalidation] = [:]
    private var revalidations: [UUID: Task<Revalidated, Never>] = [:]
    private var writes: [UUID: Task<Void, Never>] = [:]
    private var networkActive = 0
    private var waiters: [Waiter] = []
    private let persistence: PublicDescriptorDiskCache?
    private var bytes = 0
    private(set) var requests = 0
    private(set) var hits = 0
    private(set) var staleHits = 0
    private(set) var peakNetwork = 0
    var queuedNetwork: (foreground: Int, background: Int) {
        (waiters.filter { !$0.background }.count, waiters.filter(\.background).count)
    }
    var cachedCount: Int { entries.count }
    var cachedBytes: Int { bytes }
    private let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "pc-library")

    init(transport: any PCGamesTransport = PCGamesHTTP(),
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         persistence: PublicDescriptorDiskCache? = nil) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
        self.persistence = persistence
    }

    func bind(_ client: ManagementClient?, owner: UUID) {
        guard self.owner != owner || self.client !== client else { return }
        self.owner = owner
        self.client = client
        reset()
    }

    func unbind(owner: UUID) {
        guard self.owner == owner else { return }
        client = nil
        self.owner = nil
        reset()
    }

    private func reset() {
        for task in batches.values { task.cancel() }
        for read in pending.values { read.task.cancel() }
        for task in revalidations.values { task.cancel() }
        batches = [:]
        generation = UUID()
        entries = [:]
        errors = [:]
        pending = [:]
        revalidating = [:]
        revalidations = [:]
        bytes = 0
    }

    /// Waits for saved-copy writes, so a check can reopen the cache like a restart.
    func flushPersistence() async {
        while let task = writes.values.first { await task.value }
    }

    /// Removes saved public descriptors from disk; in-memory copies and active reads are unchanged.
    func clearPersisted() async throws {
        await flushPersistence()
        try await persistence?.clear()
    }

    func failures(ids: [String], market: String, language: String) -> [String: String] {
        guard let market = PCGamesClient.market(market) else {
            return Dictionary(uniqueKeysWithValues: Set(ids).map { ($0, "Confirm your account country before loading game details.") })
        }
        return Dictionary(uniqueKeysWithValues: Set(ids).compactMap { id in
            errors[Key(id: id, market: market,
                       language: PCGamesClient.language(language).lowercased())].map { (id, $0) }
        })
    }

    func expirations(ids: [String], market: String, language: String) -> [String: Date] {
        guard let market = PCGamesClient.market(market) else { return [:] }
        let language = PCGamesClient.language(language).lowercased()
        return Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            entries[Key(id: id, market: market, language: language)].map { (id, $0.expiresAt) }
        })
    }

    func load(ids: [String], market: String, language: String, refresh: Bool = false) async throws -> Data {
        try await read(ids: ids, market: market, language: language, refresh: refresh).data
    }

    /// Fresh in-memory descriptors are hits; with persistence, a saved descriptor is served at once and
    /// revalidated in the background (stale-while-revalidate); anything else is read from the network.
    /// `refresh` always reads the network.
    func read(ids: [String], market: String, language: String, refresh: Bool = false) async throws -> Read {
        let signpost = LoadSignposts.signposter.beginInterval("DescriptorBatch",
            id: LoadSignposts.signposter.makeSignpostID(), "ids=\(ids.count) refresh=\(refresh)")
        var outcome = "failed"
        var counts = (hit: 0, stale: 0, network: 0)
        defer {
            LoadSignposts.signposter.endInterval("DescriptorBatch", signpost,
                "outcome=\(outcome, privacy: .public) hit=\(counts.hit) stale=\(counts.stale) network=\(counts.network)")
        }
        try Task.checkCancellation()
        guard !ids.isEmpty, ids.count <= 20, Set(ids).count == ids.count,
              ids.allSatisfy(PCGamesClient.validProductID) else { throw PCGamesError.invalidResponse }
        guard let market = PCGamesClient.market(market) else { throw PCGamesError.invalidResponse }
        let parts = PCGamesClient.language(language).split(separator: "-")
        let wireLanguage = parts.count == 2 && parts[1].count == 2
            ? parts[0].lowercased() + "-" + parts[1].uppercased()
            : PCGamesClient.language(language)
        let language = wireLanguage.lowercased()
        let keys = ids.map { Key(id: $0, market: market, language: language) }
        let epoch = generation
        if refresh {
            for key in keys {
                if let read = pending[key], !read.network { _ = await read.task.result }
                try Task.checkCancellation()
                guard generation == epoch else { throw CancellationError() }
                remove(key)
            }
        }
        var time = now()
        for key in entries.keys.filter({ entries[$0]!.expiresAt <= time }) { remove(key) }
        var result: [Key: Data] = [:]
        var waiting: [Key: Task<Data?, Error>] = [:]
        var stale: [Key: Data] = [:]
        var following: [Task<Revalidated, Never>] = []
        var missing: [Key] = []
        func classify(_ key: Key, saved: Data? = nil) -> Bool {
            if var entry = entries[key], entry.expiresAt > time {
                hits += 1
                entry.usedAt = time
                entries[key] = entry
                result[key] = entry.bytes
            } else if let read = pending[key] {
                waiting[key] = read.task
            } else if !refresh, let revalidation = revalidating[key] {
                stale[key] = revalidation.stale
                if !following.contains(revalidation.task) { following.append(revalidation.task) }
            } else if let saved {
                stale[key] = saved
            } else { return false }
            return true
        }
        for key in keys where !classify(key) { missing.append(key) }
        if !refresh, !missing.isEmpty, let persistence {
            let saved = await persistence.read(missing.map(\.saved))
            try Task.checkCancellation()
            guard generation == epoch else { throw CancellationError() }
            time = now()
            let candidates = missing
            missing = []
            var revalidate: [Key] = []
            for key in candidates {
                let known = revalidating[key] != nil
                if !classify(key, saved: saved[key.saved]?.bytes) { missing.append(key) }
                else if !known, stale[key] != nil, revalidating[key] == nil { revalidate.append(key) }
            }
            if !revalidate.isEmpty {
                following.append(startRevalidation(revalidate, stale: stale, market: market, language: language,
                                                   wireLanguage: wireLanguage, epoch: epoch))
            }
        }
        staleHits += stale.count
        if !missing.isEmpty {
            if client == nil, let retryNotBefore, retryNotBefore > now() {
                throw PCGamesError.http(429)
            }
            let client = client
            let batchID = UUID()
            let batch = Task { () throws -> Batch in
                defer { batches[batchID] = nil }
                let batch = try await recovering(ids: missing.map(\.id), market: market,
                    language: client == nil ? language : wireLanguage, client: client, refresh: refresh,
                    epoch: epoch, background: false)
                if generation == epoch { persist(batch.entries, market: market, language: language) }
                return batch
            }
            batches[batchID] = batch
            for key in missing {
                let task = Task { () throws -> Data? in
                    defer { if generation == epoch { pending[key] = nil } }
                    let batch = try await batch.value
                    guard generation == epoch else { throw CancellationError() }
                    errors[key] = batch.failures[key.id]
                    trimErrors()
                    if let value = batch.entries[key.id] { insert(value, for: key) }
                    return batch.entries[key.id]?.bytes
                }
                pending[key] = Pending(task: task, network: refresh)
                waiting[key] = task
            }
        }
        counts = (hit: result.count, stale: stale.count, network: waiting.count)
        for key in keys where result[key] == nil {
            if let value = stale[key] { result[key] = value }
            else if let task = waiting[key], let value = try await task.value { result[key] = value }
        }
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        let products = try keys.compactMap { key in
            try result[key].map { try JSONSerialization.jsonObject(with: $0) }
        }
        let data = try JSONSerialization.data(withJSONObject: ["Products": products], options: [.sortedKeys])
        guard data.count <= PCGamesHTTP.maximumBytes else { throw PCGamesError.responseTooLarge }
        outcome = counts.network > 0 ? "miss" : counts.stale > 0 ? "stale" : "hit"
        let staleIDs = Set(stale.keys.map(\.id))
        let tasks = following
        let revalidation: Task<Revalidated, Never>? = tasks.isEmpty ? nil : Task.detached {
            var result = Revalidated()
            for task in tasks {
                let next = await task.value
                result.changed.formUnion(next.changed.intersection(staleIDs))
                result.withdrawn.formUnion(next.withdrawn.intersection(staleIDs))
            }
            return result
        }
        return Read(data: data, staleIDs: staleIDs, revalidation: revalidation)
    }

    /// Refreshes saved descriptors behind foreground reads. A failure keeps the saved copy on screen and
    /// publishes no error; success replaces it in memory and on disk. A product the response omits without an
    /// error (delisted or unavailable) loses its saved copy, so a restart can't keep serving it.
    private func startRevalidation(_ keys: [Key], stale: [Key: Data], market: String, language: String,
                                   wireLanguage: String, epoch: UUID) -> Task<Revalidated, Never> {
        let client = client
        let id = UUID()
        let task = Task { () -> Revalidated in
            defer {
                revalidations[id] = nil
                for key in keys where revalidating[key]?.id == id { revalidating[key] = nil }
            }
            do {
                let batch = try await recovering(ids: keys.map(\.id), market: market,
                    language: client == nil ? language : wireLanguage, client: client, refresh: false,
                    epoch: epoch, background: true)
                guard generation == epoch else { return Revalidated() }
                var result = Revalidated()
                for key in keys {
                    guard let value = batch.entries[key.id] else {
                        if batch.failures[key.id] == nil { result.withdrawn.insert(key.id) }
                        continue
                    }
                    errors[key] = nil
                    insert(value, for: key)
                    if value.bytes != stale[key] { result.changed.insert(key.id) }
                }
                persist(batch.entries, market: market, language: language)
                if !result.withdrawn.isEmpty, let persistence {
                    do {
                        try await persistence.remove(keys.filter { result.withdrawn.contains($0.id) }.map(\.saved))
                    } catch {
                        logger.warning("stage=descriptorCacheRemoveFailed; a withdrawn product's saved details remain until they age out")
                    }
                }
                return result
            } catch is CancellationError {
                return Revalidated()
            } catch {
                logger.notice("stage=descriptorRevalidationFailed; showing saved public details")
                return Revalidated()
            }
        }
        revalidations[id] = task
        for key in keys {
            if let saved = stale[key] { revalidating[key] = Revalidation(id: id, stale: saved, task: task) }
        }
        return task
    }

    private func insert(_ value: Entry, for key: Key) {
        remove(key)
        entries[key] = value
        bytes += value.bytes.count
        while entries.count > 512 || bytes > 32 * 1024 * 1024 {
            guard let oldest = entries.min(by: { $0.value.usedAt < $1.value.usedAt })?.key else { break }
            remove(oldest)
        }
    }

    private func trimErrors() {
        if errors.count > 512 {
            for old in Array(errors.keys.prefix(errors.count - 512)) { errors[old] = nil }
        }
    }

    private func persist(_ values: [String: Entry], market: String, language: String) {
        guard let persistence, !values.isEmpty else { return }
        let records = Dictionary(uniqueKeysWithValues: values.map {
            (PublicDescriptorDiskCache.Key(id: $0.key, market: market, language: language), $0.value.bytes)
        })
        let fetchedAt = now()
        let id = UUID()
        let logger = logger
        writes[id] = Task {
            do { try await persistence.store(records, fetchedAt: fetchedAt) }
            catch { logger.warning("stage=descriptorCacheWriteFailed; public details stay memory-only") }
            writes[id] = nil
        }
    }

    /// Caps concurrent descriptor network reads across every consumer; foreground reads go before revalidation.
    private func acquireNetwork(background: Bool) async throws {
        try Task.checkCancellation()
        let limit = client == nil ? Self.directNetworkLimit : PCGamesClient.descriptorConcurrency
        let queued = background ? !waiters.isEmpty : waiters.contains { !$0.background }
        if networkActive < limit, !queued {
            networkActive += 1
            peakNetwork = max(peakNetwork, networkActive)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, background: background, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        peakNetwork = max(peakNetwork, networkActive)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseNetwork() {
        let limit = client == nil ? Self.directNetworkLimit : PCGamesClient.descriptorConcurrency
        if networkActive <= limit,
           let index = waiters.firstIndex(where: { !$0.background }) ?? (waiters.isEmpty ? nil : 0) {
            waiters.remove(at: index).continuation.resume()
        } else { networkActive -= 1 }
    }

    private func recovering(ids: [String], market: String, language: String,
                            client: ManagementClient?, refresh: Bool, epoch: UUID,
                            background: Bool) async throws -> Batch {
        var remaining = ids
        var result = Batch()
        for attempt in 0...3 {
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            var delay: TimeInterval = pow(2, Double(attempt))
            do {
                try await acquireNetwork(background: background)
                guard epoch == generation else {
                    releaseNetwork()
                    throw CancellationError()
                }
                let signpost = LoadSignposts.signposter.beginInterval("DescriptorFetch",
                    id: LoadSignposts.signposter.makeSignpostID(),
                    "ids=\(remaining.count) background=\(background) attempt=\(attempt)")
                let fetched: Result<Batch, any Error>
                do {
                    if let client {
                        fetched = .success(try await managed(ids: remaining, market: market, language: language,
                                                             client: client, refresh: refresh || attempt > 0))
                    } else {
                        fetched = .success(try await direct(ids: remaining, market: market, language: language))
                    }
                } catch { fetched = .failure(error) }
                releaseNetwork()
                LoadSignposts.signposter.endInterval("DescriptorFetch", signpost,
                    "succeeded=\((try? fetched.get()) != nil)")
                let next = try fetched.get()
                result.entries.merge(next.entries, uniquingKeysWith: { _, new in new })
                for id in remaining { result.failures[id] = next.failures[id] }
                remaining = remaining.filter { next.retryable.contains($0) }
                if remaining.isEmpty { return result }
            } catch is CancellationError { throw CancellationError() }
            catch {
                let retry: Bool
                if let failure = error as? TransientFailure {
                    // Do not shorten a server's cooldown to fit the automatic retry budget.
                    if let after = failure.retryAfter {
                        guard after <= 30 else { throw PCGamesError.http(failure.status) }
                        delay = max(delay, after)
                    }
                    retry = true
                } else {
                    if case let ManagementError.backendError(code, retryable) = error {
                        retry = retryable && ["NETWORK_UNAVAILABLE", "LIMIT_EXCEEDED"].contains(code)
                    } else {
                        retry = error as? PCGamesError == .transport
                    }
                }
                guard retry, attempt < 3 else {
                    if !result.entries.isEmpty {
                        for id in remaining { result.failures[id] = "Game details are temporarily unavailable. Try again." }
                        return result
                    }
                    if let failure = error as? TransientFailure { throw PCGamesError.http(failure.status) }
                    throw error
                }
            }
            guard attempt < 3 else { return result }
            Logger(subsystem: "io.github.dragoshont.xodus", category: "pc-library")
                .notice("Retrying transient public details read; attempt \(attempt + 1), products \(remaining.count)")
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            try await sleep(.seconds(delay))
        }
        return result
    }

    private func retryAfter(_ text: String?) -> TimeInterval? {
        guard let text else { return nil }
        if let seconds = TimeInterval(text), seconds.isFinite, seconds >= 0 { return seconds }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return parser.date(from: text).map { max(0, $0.timeIntervalSince(now())) }
    }

    private func direct(ids: [String], market: String, language: String) async throws -> Batch {
        try Task.checkCancellation()
        if let retryNotBefore, retryNotBefore > now() {
            let remaining = retryNotBefore.timeIntervalSince(now())
            guard remaining <= 30 else { throw PCGamesError.http(429) }
            try await sleep(.seconds(remaining))
            try Task.checkCancellation()
            if let current = self.retryNotBefore, current > now() {
                throw PCGamesError.http(429)
            }
        }
        var url = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/products")
        url?.queryItems = [
            URLQueryItem(name: "bigIds", value: ids.joined(separator: ",")),
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "languages", value: language)
        ]
        guard let endpoint = url?.url else { throw PCGamesError.invalidResponse }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        requests += 1
        let response = try await transport.send(request)
        if [408, 429, 500, 502, 503, 504].contains(response.status) {
            let after = retryAfter(response.retryAfter)
            if let after { retryNotBefore = max(retryNotBefore ?? .distantPast, now().addingTimeInterval(after)) }
            throw TransientFailure(status: response.status, retryAfter: after)
        }
        guard response.status == 200 else { throw PCGamesError.http(response.status) }
        guard response.data.count <= PCGamesHTTP.maximumBytes else { throw PCGamesError.responseTooLarge }
        guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let products = object["Products"] as? [[String: Any]], products.count <= ids.count else {
            throw PCGamesError.invalidResponse
        }
        _ = try JSONDecoder().decode(PCGamesCatalog.self, from: response.data)
        var result = Batch()
        let time = now()
        for product in products {
            guard let id = product["ProductId"] as? String, ids.contains(id),
                  result.entries[id] == nil else { throw PCGamesError.invalidResponse }
            result.entries[id] = Entry(
                bytes: try JSONSerialization.data(withJSONObject: product, options: [.sortedKeys]),
                expiresAt: time.addingTimeInterval(300), usedAt: time)
        }
        return result
    }

    private func managed(ids: [String], market: String, language: String,
                         client: ManagementClient, refresh: Bool) async throws -> Batch {
        requests += 1
        let value = try await client.request(.descriptors, params: [
            "productIDs": .array(ids.map(JSONValue.string)), "market": .string(market),
            "language": .string(language), "refresh": .string(refresh ? "network" : "cache")
        ])
        let response = try value.decode(CatalogDescriptors.self)
        try response.validate(ids: ids, market: market, language: language, now: now())
        var result = Batch()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for record in response.descriptors {
            let bytes = try encoder.encode(record.product)
            let wrapped = try JSONEncoder().encode(JSONValue.object(["Products": .array([record.product])]))
            _ = try JSONDecoder().decode(PCGamesCatalog.self, from: wrapped)
            result.entries[record.productID] = Entry(bytes: bytes,
                expiresAt: try record.expiration(), usedAt: now())
        }
        let oversized = response.failures.filter {
            $0.error.code == "LIMIT_EXCEEDED" && !$0.error.retryable
        }.map(\.productID)
        if !oversized.isEmpty, ids.count > 1 {
            let size = max(1, ids.count / 2)
            for start in stride(from: 0, to: oversized.count, by: size) {
                let ids = Array(oversized[start..<min(start + size, oversized.count)])
                do {
                    let smaller = try await managed(ids: ids, market: market, language: language,
                                                    client: client, refresh: refresh)
                    result.entries.merge(smaller.entries, uniquingKeysWith: { _, new in new })
                    result.failures.merge(smaller.failures, uniquingKeysWith: { _, new in new })
                    result.retryable.formUnion(smaller.retryable)
                } catch let error as ManagementError {
                    for id in ids { result.failures[id] = error.localizedDescription }
                }
            }
        }
        for failure in response.failures where failure.error.code != "LIMIT_EXCEEDED"
            || failure.error.retryable || ids.count == 1 {
            guard failure.error.code != "PACKAGE_UNAVAILABLE" || failure.error.retryable else { continue }
            result.failures[failure.productID] = failure.error.code == "LIMIT_EXCEEDED" && !failure.error.retryable
                ? "This game's public details exceed the safe response size."
                : "Some public game details couldn't be loaded. Try again."
            if failure.error.retryable,
               ["NETWORK_UNAVAILABLE", "LIMIT_EXCEEDED"].contains(failure.error.code) {
                result.retryable.insert(failure.productID)
            }
        }
        return result
    }

    private func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { bytes -= entry.bytes.count }
    }
}
