// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OdeManagement

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

        private enum CodingKeys: String, CodingKey {
            case title, packageFormat, pcPackageIdentified, antiCheat, technologyReferences, referencePlatforms
        }

        init(title: String?, packageFormat: String?, pcPackageIdentified: Bool,
             antiCheat: String = "unknown", technologyReferences: [String], referencePlatforms: [String]) {
            self.title = title
            self.packageFormat = packageFormat
            self.pcPackageIdentified = pcPackageIdentified
            self.antiCheat = antiCheat
            self.technologyReferences = technologyReferences
            self.referencePlatforms = referencePlatforms
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try values.decodeIfPresent(String.self, forKey: .title)
            packageFormat = try values.decodeIfPresent(String.self, forKey: .packageFormat)
            pcPackageIdentified = try values.decode(Bool.self, forKey: .pcPackageIdentified)
            antiCheat = try values.decodeIfPresent(String.self, forKey: .antiCheat) ?? "unknown"
            technologyReferences = try values.decode([String].self, forKey: .technologyReferences)
            referencePlatforms = try values.decode([String].self, forKey: .referencePlatforms)
        }

        var supported01: Bool {
            packageFormat?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "MSIXVC"
                && antiCheat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
                && GameSupportPolicy.issues(packageFormat: packageFormat, antiCheat: antiCheat).isEmpty
        }
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
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw PCGamesError.responseTooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, GameCompatibilityResult.parseDate(value.checkedAt) != nil,
              value.products.count <= 4096, value.products.keys.allSatisfy(PCGamesClient.validProductID),
              value.products.values.allSatisfy({
                  !$0.antiCheat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.antiCheat.utf8.count <= 512
                    && !$0.antiCheat.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    && $0.technologyReferences.count <= 16
              }) else {
            throw PCGamesError.invalidResponse
        }
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let products = raw?["products"] as? [String: [String: Any]] ?? [:]
        guard value.products.allSatisfy({ id, entry in
            !entry.supported01 || validClearance(productID: id, product: products[id] ?? [:])
        }) else { throw PCGamesError.invalidResponse }
        return value
    }

    static func validClearance(productID: String, product: [String: Any]) -> Bool {
        func validSource(_ evidence: [String: Any]) -> Bool {
            guard let source = evidence["source"] as? String, let url = URL(string: source),
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  let date = evidence["checkedAt"] as? String,
                  date.range(of: #"^\d{4}-\d{2}-\d{2}(T.*Z)?$"#, options: .regularExpression) != nil else { return false }
            return true
        }
        guard product["packageFormat"] as? String == "MSIXVC",
              (product["antiCheat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none",
              product["supported01"] as? Bool == true,
              product["pcPackageIdentified"] as? Bool == true,
              let package = product["packageFormatEvidence"] as? [String: Any], validSource(package),
              (package["method"] as? String)?.isEmpty == false,
              let formats = package["observedFormats"] as? [String], !formats.isEmpty,
              let antiCheat = product["antiCheatEvidence"] as? [String: Any], validSource(antiCheat),
              (antiCheat["method"] as? String)?.isEmpty == false,
              let checks = antiCheat["publicChecks"] as? [[String: Any]], checks.count == 3,
              Set(checks.compactMap { $0["sourceType"] as? String }) == ["awacy", "pcgamingwiki", "publisher"],
              checks.allSatisfy({ validSource($0) && ($0["result"] as? String)?.isEmpty == false }) else { return false }
        if antiCheat["type"] as? String == "public-source" {
            return antiCheat["mode"] as? String == "user-directed-correction"
                && (antiCheat["method"] as? String)?.hasPrefix("User-directed classification: ") == true
                && antiCheat["packageScan"] == nil
        }
        guard
              antiCheat["type"] as? String == "package-scan",
              let scan = antiCheat["packageScan"] as? [String: Any],
              scan["complete"] as? Bool == true, (scan["fileCount"] as? Int ?? 0) > 0,
              scan["result"] as? String == "no-known-signature",
              let digest = scan["fileListSha256"] as? String,
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let matches = scan["matches"] as? [String: Any], matches.isEmpty,
              scan["symlinkCount"] as? Int == 0,
              let signature = scan["signatureSet"] as? String, !signature.isEmpty,
              (scan["signatureVersion"] as? Int ?? 0) > 0,
              let identity = scan["packageIdentity"] as? [String: Any],
              identity["storeId"] as? String == productID else { return false }
        return true
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
