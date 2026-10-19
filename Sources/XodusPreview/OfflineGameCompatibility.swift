// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

struct OfflineGameCompatibility: Codable {
    struct Entry: Codable {
        let title: String?
        let packageFormat: String?
        let pcPackageIdentified: Bool
        let antiCheat: String
        let technologyReferences: [String]
        let referencePlatforms: [String]
    }
    let version: Int
    let checkedAt: String
    let market: String
    let packageSource: String
    let antiCheatReference: String
    let products: [String: Entry]

    static let loaded: Result<Self, Error> = Result {
        let url = try CompatibilityResources.catalogueURL()
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else { throw PCGamesError.responseTooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, GameCompatibilityResult.parseDate(value.checkedAt) != nil,
              value.products.count <= 4096, value.products.keys.allSatisfy(PCGamesClient.validProductID),
              value.products.values.allSatisfy({ $0.antiCheat == "unknown" && $0.technologyReferences.count <= 16 }) else {
            throw PCGamesError.invalidResponse
        }
        return value
    }

    static var snapshot: Self? {
        switch loaded {
        case .success(let database): database
        case .failure: nil
        }
    }
    static var unavailable: Bool {
        if case .failure = loaded { return true }
        return false
    }
}
