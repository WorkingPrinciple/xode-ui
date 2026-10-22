// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum CatalogLocale {
    static func preferred(region: String?, languages: [String]) -> (market: String, language: String) {
        let market = PCGamesClient.market(region)
        let valid = languages.filter { PCGamesClient.language($0) == $0 }
        let matching = valid.first { Locale(identifier: $0).region?.identifier == market }
        return (market, matching ?? valid.first ?? "en-US")
    }
}

enum XboxProductLink {
    static func canonical(_ url: URL, productID: String, language: String) -> Bool {
        let parts = url.path.split(separator: "/")
        return url.scheme == "https" && url.host == "www.xbox.com"
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil
            && parts.count == 5
            && parts[0].lowercased() == language.lowercased()
            && parts[1] == "games" && parts[2] == "store"
            && !parts[3].isEmpty && parts[3] != "." && parts[3] != ".."
            && parts[4].uppercased() == productID.uppercased()
    }

    static func resolve(productID: String, market: String, language: String,
                        transport: any PCGamesTransport = PCGamesHTTP()) async throws -> URL {
        guard PCGamesClient.validProductID(productID),
              PCGamesClient.market(market) == market,
              PCGamesClient.language(language) == language,
              language.split(separator: "-").last?.uppercased() == market else {
            throw PCGamesError.invalidResponse
        }
        var components = URLComponents(string: "https://www.microsoft.com/store/productId/\(productID)")!
        components.queryItems = [URLQueryItem(name: "market", value: market),
                                 URLQueryItem(name: "locale", value: language)]
        guard var endpoint = components.url else { throw PCGamesError.invalidResponse }
        // Ask Microsoft's product-ID resolver for the slug; never synthesize one from a title.
        for _ in 0..<6 {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint)
            request.httpShouldHandleCookies = false
            let response = try await transport.send(request)
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard let location = response.location,
                      let next = URL(string: location, relativeTo: endpoint)?.absoluteURL,
                      allowedRedirect(next, productID: productID, language: language) else {
                    throw PCGamesError.invalidResponse
                }
                endpoint = next
                continue
            }
            guard response.status == 200 else { throw PCGamesError.http(response.status) }
            guard canonical(endpoint, productID: productID, language: language),
                  let html = String(data: response.data, encoding: .utf8) else {
                throw PCGamesError.invalidResponse
            }
            let links = try NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
            let attribute = try NSRegularExpression(
                pattern: #"\b(rel|href)\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive])
            for match in links.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range, in: html) else { continue }
                let tag = String(html[range])
                var values: [String: String] = [:]
                for item in attribute.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                    guard let key = Range(item.range(at: 1), in: tag),
                          let value = Range(item.range(at: 2), in: tag) else { continue }
                    values[tag[key].lowercased()] = String(tag[value])
                }
                if values["rel"]?.lowercased() == "canonical",
                   let value = values["href"], let url = URL(string: value),
                   canonical(url, productID: productID, language: language),
                   url.path.lowercased() == endpoint.path.lowercased() {
                    return url
                }
            }
            throw PCGamesError.invalidResponse
        }
        throw PCGamesError.invalidResponse
    }

    private static func allowedRedirect(_ url: URL, productID: String, language: String) -> Bool {
        if canonical(url, productID: productID, language: language) { return true }
        if url.host == "xbox.com", var normalized = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            normalized.host = "www.xbox.com"
            if let target = normalized.url, canonical(target, productID: productID, language: language) {
                return true
            }
        }
        let parts = url.path.split(separator: "/")
        let productRoute = Array(parts.suffix(3)).map(String.init)
        return url.scheme == "https" && url.host == "www.microsoft.com"
            && url.user == nil && url.password == nil && url.port == nil && url.fragment == nil
            && (parts.count == 3 || (parts.count == 4 && parts[0].lowercased() == language.lowercased()))
            && productRoute == ["store", "productId", productID]
    }
}
