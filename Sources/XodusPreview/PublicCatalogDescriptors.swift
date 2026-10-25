// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OSLog
import XodusManagement

actor PublicCatalogDescriptors {
    static let shared = PublicCatalogDescriptors()
    private struct Key: Hashable {
        let id: String
        let market: String
        let language: String
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
    private var bytes = 0
    private(set) var requests = 0
    private(set) var hits = 0
    var cachedCount: Int { entries.count }
    var cachedBytes: Int { bytes }

    init(transport: any PCGamesTransport = PCGamesHTTP(),
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
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
        batches = [:]
        generation = UUID()
        entries = [:]
        errors = [:]
        pending = [:]
        bytes = 0
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
        let time = now()
        for key in entries.keys.filter({ entries[$0]!.expiresAt <= time }) { remove(key) }
        var result: [Key: Data] = [:]
        var waiting: [Key: Task<Data?, Error>] = [:]
        var missing: [Key] = []
        for key in keys {
            if var entry = entries[key] {
                hits += 1
                entry.usedAt = time
                entries[key] = entry
                result[key] = entry.bytes
            } else if let read = pending[key] {
                waiting[key] = read.task
            } else { missing.append(key) }
        }
        if !missing.isEmpty {
            if client == nil, let retryNotBefore, retryNotBefore > now() {
                throw PCGamesError.http(429)
            }
            let client = client
            let batchID = UUID()
            let batch = Task { () throws -> Batch in
                defer { batches[batchID] = nil }
                return try await recovering(ids: missing.map(\.id), market: market,
                    language: client == nil ? language : wireLanguage, client: client, refresh: refresh,
                    epoch: epoch)
            }
            batches[batchID] = batch
            for key in missing {
                let task = Task { () throws -> Data? in
                    defer { if generation == epoch { pending[key] = nil } }
                    let batch = try await batch.value
                    guard generation == epoch else { throw CancellationError() }
                    errors[key] = batch.failures[key.id]
                    if errors.count > 512 {
                        for old in Array(errors.keys.prefix(errors.count - 512)) { errors[old] = nil }
                    }
                    if let value = batch.entries[key.id] {
                        remove(key)
                        entries[key] = value
                        bytes += value.bytes.count
                        while entries.count > 512 || bytes > 32 * 1024 * 1024 {
                            guard let oldest = entries.min(by: { $0.value.usedAt < $1.value.usedAt })?.key else { break }
                            remove(oldest)
                        }
                    }
                    return batch.entries[key.id]?.bytes
                }
                pending[key] = Pending(task: task, network: refresh)
                waiting[key] = task
            }
        }
        for key in keys where result[key] == nil {
            if let task = waiting[key], let value = try await task.value { result[key] = value }
        }
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        let products = try keys.compactMap { key in
            try result[key].map { try JSONSerialization.jsonObject(with: $0) }
        }
        let data = try JSONSerialization.data(withJSONObject: ["Products": products], options: [.sortedKeys])
        guard data.count <= PCGamesHTTP.maximumBytes else { throw PCGamesError.responseTooLarge }
        return data
    }

    private func recovering(ids: [String], market: String, language: String,
                            client: ManagementClient?, refresh: Bool, epoch: UUID) async throws -> Batch {
        var remaining = ids
        var result = Batch()
        for attempt in 0...3 {
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            var delay: TimeInterval = pow(2, Double(attempt))
            do {
                let next: Batch
                if let client {
                    next = try await managed(ids: remaining, market: market, language: language,
                                             client: client, refresh: refresh || attempt > 0)
                } else {
                    next = try await direct(ids: remaining, market: market, language: language)
                }
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
        for record in response.descriptors {
            let bytes = try JSONEncoder().encode(record.product)
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
