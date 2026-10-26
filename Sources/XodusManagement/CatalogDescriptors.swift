// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct CatalogDescriptors: Decodable, Sendable {
    public struct Record: Decodable, Sendable {
        public let productID: String
        public let market: String
        public let language: String
        public let checkedAt: String
        public let expiresAt: String
        public let freshness: String
        public let product: JSONValue

        public func expiration() throws -> Date { try CatalogDescriptors.date(expiresAt) }
    }
    public struct Failure: Decodable, Sendable {
        public struct Detail: Decodable, Sendable {
            public let code: String
            public let message: String
            public let retryable: Bool
        }
        public let productID: String
        public let error: Detail
    }
    public let descriptors: [Record]
    public let failures: [Failure]

    /// Envelope checks stay strict; each record is checked on its own, so one bad record (or a few seconds
    /// of clock skew between the app and the backend) never rejects the whole batch. Returns invalid IDs.
    public func validRecords(ids: [String], market: String, language: String, now: Date,
                             skew: TimeInterval = 30) throws -> (valid: [Record], invalid: Set<String>) {
        let received = descriptors.map(\.productID) + failures.map(\.productID)
        guard (1...20).contains(ids.count), Set(ids).count == ids.count,
              received.count == ids.count, Set(received) == Set(ids) else {
            throw ManagementError.invalidPayload
        }
        var valid: [Record] = [], invalid = Set<String>()
        for record in descriptors {
            guard let checked = try? Self.date(record.checkedAt), let expiry = try? record.expiration(),
                  record.market == market, record.language == language,
                  record.product.object != nil, record.product["ProductId"]?.string == record.productID,
                  ["live", "cached"].contains(record.freshness),
                  checked <= now.addingTimeInterval(skew), expiry > now,
                  expiry.timeIntervalSince(checked) == 300 else {
                invalid.insert(record.productID)
                continue
            }
            valid.append(record)
        }
        return (valid, invalid)
    }

    public func validate(ids: [String], market: String, language: String, now: Date) throws {
        let received = descriptors.map(\.productID) + failures.map(\.productID)
        guard (1...20).contains(ids.count), Set(ids).count == ids.count,
              received.count == ids.count, Set(received) == Set(ids) else {
            throw ManagementError.invalidPayload
        }
        for record in descriptors {
            let checked = try Self.date(record.checkedAt), expiry = try record.expiration()
            guard record.market == market, record.language == language,
                  record.product.object != nil, record.product["ProductId"]?.string == record.productID,
                  ["live", "cached"].contains(record.freshness),
                  checked <= now, expiry > now,
                  expiry.timeIntervalSince(checked) == 300 else {
                throw ManagementError.invalidPayload
            }
        }
        for failure in failures {
            guard !failure.error.code.isEmpty, failure.error.code.utf8.count <= 128,
                  !failure.error.message.isEmpty, failure.error.message.utf8.count <= 1024 else {
                throw ManagementError.invalidPayload
            }
        }
    }

    private static func date(_ text: String) throws -> Date {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: text) else { throw ManagementError.invalidPayload }
        return date
    }
}
