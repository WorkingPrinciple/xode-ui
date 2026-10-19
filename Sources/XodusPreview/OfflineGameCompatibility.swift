// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

struct OfflineGameCompatibility: Codable {
    struct PublisherEvidence: Decodable {
        let title: String
        let technologies: [String]
        let scope: String
        let source: URL
        let checkedAt: String
    }
    private struct PublisherCatalogue: Decodable {
        let version: Int
        let products: [String: PublisherEvidence]
    }
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

    static let publisherEvidence: Result<[String: PublisherEvidence], Error> = Result {
        let data = try Data(contentsOf: CompatibilityResources.publisherEvidenceURL())
        guard data.count <= 256 * 1024 else { throw PCGamesError.responseTooLarge }
        let value = try JSONDecoder().decode(PublisherCatalogue.self, from: data)
        guard value.version == 1, value.products.count <= 4096,
              value.products.keys.allSatisfy(PCGamesClient.validProductID),
              value.products.allSatisfy({ id, evidence in
                  snapshot?.products[id]?.title == evidence.title
                    && !evidence.technologies.isEmpty && evidence.technologies.count <= 16
                    && evidence.technologies.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }
                    && !evidence.scope.isEmpty && evidence.scope.utf8.count <= 4096
                    && evidence.source.scheme == "https"
                    && evidence.source.user == nil && evidence.source.password == nil && evidence.source.port == nil
                    && ["support.riotgames.com", "support.halowaypoint.com"].contains(evidence.source.host)
                    && GameCompatibilityResult.parseDate(evidence.checkedAt) != nil
              }) else { throw PCGamesError.invalidResponse }
        return value.products
    }

    static func publisherEvidence(for id: String) -> PublisherEvidence? {
        guard case .success(let records) = publisherEvidence else { return nil }
        return records[id]
    }

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
