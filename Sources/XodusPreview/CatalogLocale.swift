// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum CatalogLocale {
    static func preferred(region: String?, languages: [String]) -> (market: String, language: String) {
        let market = PCGamesClient.market(region) ?? ""
        let valid = languages.filter { PCGamesClient.language($0) == $0 }
        return (market, valid.first ?? "en-US")
    }
}
