// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

struct GamePassCollection: Identifiable {
    let key: String
    let feedID: String
    let title: String
    var productIDs: [String] = []
    var products: [CatalogProduct] = []
    var loadedCount = 0
    var loading = false
    var error: String?
    var id: String { key }
    var isBenefits: Bool { key.lowercased().contains("benefit") || key.lowercased().contains("riot") }
    var isUpcoming: Bool { key.lowercased().contains("comingsoon") }
    var hasMore: Bool { loadedCount < productIDs.count }
}

enum GamePassCollectionSource {
    static let page = URL(string: "https://www.xbox.com/ro-RO/xbox-game-pass/games")!

    static func captures(_ pattern: String, in text: String) throws -> [[String]] {
        let expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map {
                Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    static func scriptURL(in html: String) throws -> URL {
        let paths = try captures(#"<script\b[^>]*\bsrc=["']([^"']+/xgpcatPopulate[^"']*\.js)["']"#, in: html)
        guard let path = paths.first?.first, let url = URL(string: path, relativeTo: page)?.absoluteURL,
              url.scheme == "https", url.host == "www.xbox.com", url.user == nil,
              url.password == nil, url.port == nil, url.query == nil else { throw PCGamesError.invalidResponse }
        return url
    }

    static func definitions(html: String, script: String) throws -> [GamePassCollection] {
        guard let mapping = try captures(#"\bguidAmpt\s*=\s*(\{[^;]+?\})\s*(?:;|\n)"#, in: script).first?.first,
              let data = mapping.data(using: .utf8) else { throw PCGamesError.invalidResponse }
        let feeds = try JSONDecoder().decode([String: String].self, from: data)
        guard !feeds.isEmpty, feeds.count <= 128 else { throw PCGamesError.invalidResponse }
        guard let start = html.range(of: #"<span class="colgroup collections-pc"#) else {
            throw PCGamesError.invalidResponse
        }
        let tail = String(html[start.lowerBound...])
        let end = tail.range(of: #"<span class="colgroup collections-"#, range: tail.index(after: tail.startIndex)..<tail.endIndex)
        let section = end.map { String(tail[..<$0.lowerBound]) } ?? tail
        let rows = try captures(#"<a\b([^>]*\bdata-col="([^"]+)"[^>]*)>\s*<span>([^<]+)</span>\s*</a>"#, in: section)
        var definitions: [GamePassCollection] = []
        for row in rows where !row[0].contains("permaHide") {
            guard let feed = feeds[row[1]], UUID(uuidString: feed) != nil else { continue }
            definitions.append(.init(key: row[1], feedID: feed, title: row[2]))
        }
        // The official script adds publisher/benefit collections using a bounded data literal.
        // Parse that literal as data only; never evaluate downloaded JavaScript.
        if let addition = try captures(#"\bvar\s+globalAdd\s*=\s*(\{.*?\})\s*var\s+newListIds"#, in: script).first?.first {
            let comments = try NSRegularExpression(pattern: #"//[^\n]*"#)
                .stringByReplacingMatches(in: addition, range: NSRange(addition.startIndex..., in: addition), withTemplate: "")
            let quoted = try NSRegularExpression(pattern: #"([,{]\s*)([A-Za-z][A-Za-z0-9]*)\s*:"#)
                .stringByReplacingMatches(in: comments, range: NSRange(comments.startIndex..., in: comments), withTemplate: "$1\"$2\":")
            struct Addition: Decodable { let colname: String; let plat: String; let title: String; let spot: Int }
            let additions = try JSONDecoder().decode([String: Addition].self, from: Data(quoted.utf8))
            guard additions.count <= 64 else { throw PCGamesError.invalidResponse }
            for (feed, value) in additions.sorted(by: {
                $0.value.spot == $1.value.spot ? $0.value.colname < $1.value.colname : $0.value.spot < $1.value.spot
            }) where value.plat == "pc" {
                guard UUID(uuidString: feed) != nil else { throw PCGamesError.invalidResponse }
                definitions.removeAll { $0.key == value.colname }
                definitions.insert(.init(key: value.colname, feedID: feed,
                    title: value.title.trimmingCharacters(in: CharacterSet(charactersIn: "%")).components(separatedBy: "**").first ?? value.colname),
                    at: min(max(0, value.spot - 1), definitions.count))
            }
        }
        if let recent = feeds["XGPPMPRecentlyAdded"], UUID(uuidString: recent) != nil {
            definitions.append(.init(key: "XGPPMPRecentlyAdded", feedID: recent, title: "Recently added"))
        }
        var seen = Set<String>()
        definitions = definitions.filter { seen.insert($0.key).inserted }
        guard !definitions.isEmpty, definitions.count <= 24 else { throw PCGamesError.invalidResponse }
        return definitions.sorted {
            let left = $0.key == "pdoPC" ? 0 : $0.key == "XGPPMPRecentlyAdded" ? 1 : 2
            let right = $1.key == "pdoPC" ? 0 : $1.key == "XGPPMPRecentlyAdded" ? 1 : 2
            return left < right
        }
    }

    static func productIDs(_ data: Data, feedID: String) throws -> [String] {
        struct Row: Decodable { let siglId: String?; let id: String? }
        guard data.count <= 512 * 1024 else { throw PCGamesError.responseTooLarge }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        guard !rows.isEmpty, rows.count <= 2049, rows.first?.siglId == feedID else {
            throw PCGamesError.invalidResponse
        }
        let ids = rows.dropFirst().compactMap(\.id)
        guard ids.count == rows.count - 1, ids.allSatisfy(PCGamesClient.validProductID),
              Set(ids).count == ids.count else { throw PCGamesError.invalidResponse }
        return ids
    }
}

@MainActor
final class GamePassCollections: ObservableObject {
    @Published private(set) var collections: [GamePassCollection] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var scope: String?
    private var revision = UUID()
    private let transport: any PCGamesTransport
    private let artwork: LibraryCatalogArtwork
    init(transport: any PCGamesTransport = PCGamesHTTP()) {
        self.transport = transport
        artwork = LibraryCatalogArtwork(transport: transport)
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let response = try await transport.send(request)
        guard response.status == 200 else { throw PCGamesError.http(response.status) }
        return response.data
    }

    func load(market: String, language: String, refresh: Bool = false) async {
        let nextScope = "\(PCGamesClient.market(market)):\(PCGamesClient.language(language))"
        guard refresh || scope != nextScope else { return }
        let owner = UUID()
        revision = owner
        scope = nextScope
        collections = []
        loading = true
        error = nil
        defer { if revision == owner { loading = false } }
        do {
            let page = try await fetch(GamePassCollectionSource.page)
            guard let html = String(data: page, encoding: .utf8) else { throw PCGamesError.invalidResponse }
            let script = try await fetch(GamePassCollectionSource.scriptURL(in: html))
            guard let source = String(data: script, encoding: .utf8) else { throw PCGamesError.invalidResponse }
            let definitions = try GamePassCollectionSource.definitions(html: html, script: source)
            try Task.checkCancellation()
            guard revision == owner else { return }
            collections = definitions
            for definition in definitions {
                try Task.checkCancellation()
                guard revision == owner else { return }
                await loadCollection(definition.key, market: market, language: language)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            if revision == owner { scope = nil }
        } catch {
            guard revision == owner else { return }
            self.error = "Game Pass collections couldn't be loaded from Xbox. Try again."
        }
    }

    func loadCollection(_ key: String, market: String, language: String, more: Bool = false) async {
        guard let index = collections.firstIndex(where: { $0.key == key }), !collections[index].loading else { return }
        let owner = revision
        let definition = collections[index]
        collections[index].loading = true
        collections[index].error = nil
        defer {
            if revision == owner, collections.indices.contains(index) { collections[index].loading = false }
        }
        do {
            var ids = definition.productIDs
            if ids.isEmpty {
                var url = URLComponents(string: "https://catalog.gamepass.com/sigls/v3")!
                url.queryItems = [
                    .init(name: "id", value: definition.feedID), .init(name: "market", value: PCGamesClient.market(market)),
                    .init(name: "language", value: PCGamesClient.language(language)),
                    .init(name: "platformContext", value: "pc"), .init(name: "subscriptionContext", value: "cfq7ttc0kgq8")
                ]
                guard let endpoint = url.url else { throw PCGamesError.invalidResponse }
                ids = try GamePassCollectionSource.productIDs(await fetch(endpoint), feedID: definition.feedID)
            }
            let limit = min(ids.count, more ? definition.loadedCount + 24 : 12)
            await artwork.load(ids: Array(ids.prefix(limit)), market: market, language: language)
            try Task.checkCancellation()
            guard revision == owner else { return }
            guard artwork.error == nil else { throw PCGamesError.invalidResponse }
            collections[index].productIDs = ids
            collections[index].products = ids.prefix(limit).compactMap { artwork.images[$0]?.product }
            collections[index].loadedCount = limit
        } catch is CancellationError {
        } catch {
            guard revision == owner else { return }
            collections[index].error = "This Game Pass collection couldn't be loaded. Try again."
        }
    }

#if !XODUS_SHIPPING
    func exportCompatibility(to destination: URL, market: String) async throws {
        guard !collections.isEmpty, error == nil, collections.allSatisfy({ $0.error == nil }) else {
            throw PCGamesError.invalidResponse
        }
        let ids = Set(collections.flatMap(\.productIDs)).sorted()
        await artwork.load(ids: ids, market: market, language: "en-US")
        guard artwork.error == nil else { throw PCGamesError.invalidResponse }
        let revision = "d876c32d21c69067406e3db44a12ae6633fb5fa7"
        let source = "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/\(revision)/games.json"
        let reference = try await fetch(URL(string: source)!)
        struct AntiCheatReference: Decodable {
            let name: String
            let anticheats: [String]
            let storeIds: [String: XodusManagement.JSONValue]?
        }
        let references = try JSONDecoder().decode([AntiCheatReference].self, from: reference)
        guard references.count <= 4096 else { throw PCGamesError.invalidResponse }
        let byName = Dictionary(references.map { ($0.name.lowercased(), $0) },
                                uniquingKeysWith: { first, _ in first })
        var entries: [String: OfflineGameCompatibility.Entry] = [:]
        for id in ids {
            let image = artwork.images[id]
            let match = image.flatMap { byName[$0.product.title.lowercased()] }
            entries[id] = .init(title: image?.product.title, packageFormat: image?.facts.packageFormat,
                pcPackageIdentified: image?.product.pcCatalogCandidate == true,
                antiCheat: "unknown", technologyReferences: match?.anticheats ?? [],
                referencePlatforms: match?.storeIds?.keys.sorted() ?? [])
        }
        let snapshot = OfflineGameCompatibility(version: 1,
            checkedAt: ISO8601DateFormatter().string(from: Date()), market: market,
            packageSource: "https://displaycatalog.mp.microsoft.com/v7.0/products",
            antiCheatReference: source, products: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(snapshot).write(to: destination, options: .atomic)
        print("Exported \(entries.count) public catalogue records; \(entries.values.filter { $0.packageFormat != nil }.count) package formats; \(entries.values.filter { !$0.technologyReferences.isEmpty }.count) non-Store technology references. Store anti-cheat clearance remains unverified.")
    }
#endif
}
