// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum OdeAccountSection: String, Codable, Sendable {
    case library, profile, achievements, runtime
}

public struct OdeAccountRead: Decodable, Sendable {
    public let section: OdeAccountSection
    public let accountHash: String
    public let checkedAt: String
    public let payload: JSONValue

    public func validate(section: OdeAccountSection, accountHash: String) throws {
        guard self.section == section, self.accountHash == accountHash,
              ContractValidator.validDate(checkedAt) else { throw ManagementError.invalidPayload }
    }
}

public struct OdeAccountCollection: Decodable, Sendable {
    public struct Item: Decodable, Sendable {
        public let productID: String
        public let acquisitionKind: PCGameAcquisitionKind
    }
    public let items: [Item]

    public func validate() throws {
        guard items.count <= 10_000,
              Set(items.map(\.productID)).count == items.count,
              items.allSatisfy({ item in
                  item.productID.utf8.count == 12 &&
                      item.productID.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
              }) else { throw ManagementError.invalidPayload }
    }
}
