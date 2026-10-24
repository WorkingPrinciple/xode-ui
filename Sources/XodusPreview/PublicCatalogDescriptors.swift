// SPDX-License-Identifier: GPL-3.0-only
import Foundation
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
    }
    private struct Pending {
        let task: Task<Data?, Error>
        let network: Bool
    }
    private let transport: any PCGamesTransport
    private let now: @Sendable () -> Date
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
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
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
        generation = UUID()
        entries = [:]
        errors = [:]
        pending = [:]
        bytes = 0
    }

    func failures(ids: [String], market: String, language: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Set(ids).compactMap { id in
            errors[Key(id: id, market: PCGamesClient.market(market),
                       language: PCGamesClient.language(language).lowercased())].map { (id, $0) }
        })
    }

    func expirations(ids: [String], market: String, language: String) -> [String: Date] {
        let market = PCGamesClient.market(market)
        let language = PCGamesClient.language(language).lowercased()
        return Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            entries[Key(id: id, market: market, language: language)].map { (id, $0.expiresAt) }
        })
    }

    func load(ids: [String], market: String, language: String, refresh: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard !ids.isEmpty, ids.count <= 20, Set(ids).count == ids.count,
              ids.allSatisfy(PCGamesClient.validProductID) else { throw PCGamesError.invalidResponse }
        let market = PCGamesClient.market(market)
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
            let client = client
            let batch = Task { () throws -> Batch in
                if let client {
                    return try await managed(ids: missing.map(\.id), market: market,
                                             language: wireLanguage, client: client, refresh: refresh)
                }
                return try await direct(ids: missing.map(\.id), market: market, language: language)
            }
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

    private func direct(ids: [String], market: String, language: String) async throws -> Batch {
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
        let oversized = response.failures.filter { $0.error.code == "LIMIT_EXCEEDED" }.map(\.productID)
        if !oversized.isEmpty, ids.count > 1 {
            let size = max(1, ids.count / 2)
            for start in stride(from: 0, to: oversized.count, by: size) {
                let ids = Array(oversized[start..<min(start + size, oversized.count)])
                do {
                    let smaller = try await managed(ids: ids, market: market, language: language,
                                                    client: client, refresh: refresh)
                    result.entries.merge(smaller.entries, uniquingKeysWith: { _, new in new })
                    result.failures.merge(smaller.failures, uniquingKeysWith: { _, new in new })
                } catch let error as ManagementError {
                    for id in ids { result.failures[id] = error.localizedDescription }
                }
            }
        }
        for failure in response.failures where failure.error.code != "LIMIT_EXCEEDED" || ids.count == 1 {
            result.failures[failure.productID] = failure.error.code == "LIMIT_EXCEEDED"
                ? "This game's public details exceed the safe response size."
                : "Some public game details couldn't be loaded. Try again."
        }
        return result
    }

    private func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { bytes -= entry.bytes.count }
    }
}
