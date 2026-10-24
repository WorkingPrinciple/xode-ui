// SPDX-License-Identifier: GPL-3.0-only
import Foundation

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
    private let transport: any PCGamesTransport
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Task<Data?, Error>] = [:]
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

    func expirations(ids: [String], market: String, language: String) -> [String: Date] {
        let market = PCGamesClient.market(market)
        let language = PCGamesClient.language(language).lowercased()
        return Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            entries[Key(id: id, market: market, language: language)].map { (id, $0.expiresAt) }
        })
    }

    func load(ids: [String], market: String, language: String) async throws -> Data {
        try Task.checkCancellation()
        guard !ids.isEmpty, ids.count <= 20, Set(ids).count == ids.count,
              ids.allSatisfy(PCGamesClient.validProductID) else { throw PCGamesError.invalidResponse }
        let market = PCGamesClient.market(market)
        let language = PCGamesClient.language(language).lowercased()
        let keys = ids.map { Key(id: $0, market: market, language: language) }
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
            } else if let task = pending[key] {
                waiting[key] = task
            } else { missing.append(key) }
        }
        if !missing.isEmpty {
            requests += 1
            let transport = transport
            let requested = missing.map(\.id)
            let batch = Task { () throws -> [String: Data] in
                var url = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/products")
                url?.queryItems = [
                    URLQueryItem(name: "bigIds", value: requested.joined(separator: ",")),
                    URLQueryItem(name: "market", value: market),
                    URLQueryItem(name: "languages", value: language)
                ]
                guard let endpoint = url?.url else { throw PCGamesError.invalidResponse }
                var request = URLRequest(url: endpoint, timeoutInterval: 30)
                request.httpShouldHandleCookies = false
                let response = try await transport.send(request)
                guard response.status == 200 else { throw PCGamesError.http(response.status) }
                guard response.data.count <= PCGamesHTTP.maximumBytes else { throw PCGamesError.responseTooLarge }
                guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                      let products = object["Products"] as? [[String: Any]],
                      products.count <= requested.count else { throw PCGamesError.invalidResponse }
                var values: [String: Data] = [:]
                for product in products {
                    guard let id = product["ProductId"] as? String, requested.contains(id),
                          values[id] == nil else { throw PCGamesError.invalidResponse }
                    values[id] = try JSONSerialization.data(withJSONObject: product, options: [.sortedKeys])
                }
                // Validate identity/platform decoding before sharing a response between consumers.
                _ = try JSONDecoder().decode(PCGamesCatalog.self, from: response.data)
                return values
            }
            for key in missing {
                let task = Task { () throws -> Data? in
                    defer { pending[key] = nil }
                    let value = try await batch.value[key.id]
                    if let value {
                        let time = now()
                        remove(key)
                        entries[key] = Entry(bytes: value, expiresAt: time.addingTimeInterval(300), usedAt: time)
                        bytes += value.count
                        while entries.count > 512 || bytes > 32 * 1024 * 1024 {
                            guard let oldest = entries.min(by: { $0.value.usedAt < $1.value.usedAt })?.key else { break }
                            remove(oldest)
                        }
                    }
                    return value
                }
                pending[key] = task
                waiting[key] = task
            }
        }
        for key in keys where result[key] == nil {
            if let task = waiting[key], let value = try await task.value { result[key] = value }
        }
        try Task.checkCancellation()
        let products = try keys.compactMap { key in
            try result[key].map { try JSONSerialization.jsonObject(with: $0) }
        }
        let data = try JSONSerialization.data(withJSONObject: ["Products": products], options: [.sortedKeys])
        guard data.count <= PCGamesHTTP.maximumBytes else { throw PCGamesError.responseTooLarge }
        return data
    }

    private func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { bytes -= entry.bytes.count }
    }
}
