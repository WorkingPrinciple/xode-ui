// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum RecentLibraryPlatform: String, Codable, Sendable {
    case pc, console, mixed, unknown

    public var label: String {
        switch self {
        case .pc: "PC"
        case .console: "Console"
        case .mixed: "PC and console"
        case .unknown: "Platform not reported"
        }
    }
}

public struct RecentLibraryTitle: Codable, Equatable, Sendable, Identifiable {
    public let titleID: String
    public let name: String
    public let lastPlayedAt: String?
    public let devices: [String]
    public let platform: RecentLibraryPlatform
    public let artwork: [CatalogArtworkReference]
    public let artworkStatus: CatalogArtworkStatus
    public let productID: String?
    public var id: String { titleID }
}

public struct RecentLibrarySnapshot: Codable, Equatable, Sendable {
    public let scope: String
    public let source: String
    public let checkedAt: String
    public let freshness: String
    public let completeness: String
    public let nextCursor: String?
    public let titles: [RecentLibraryTitle]

    public func validate(limit: Int) throws {
        guard (1...100).contains(limit), titles.count <= limit,
              scope == "recentlyPlayed", source == "XboxTitleHub:v2",
              freshness == "live", completeness == "partial", nextCursor == nil,
              Set(titles.map(\.id)).count == titles.count else { throw ManagementError.invalidPayload }
        for title in titles {
            guard let identifier = UInt32(title.titleID), identifier > 0,
                  String(identifier) == title.titleID, title.productID == nil else {
                throw ManagementError.invalidPayload
            }
            try CatalogArtworkReference.validate(title.artwork, status: title.artworkStatus)
            guard title.artwork.allSatisfy({ $0.source == .titleHub && $0.role == .tile }) else {
                throw ManagementError.invalidPayload
            }
        }
    }
}

public enum RecentLibraryFailure: String, CaseIterable, Equatable, Sendable {
    case credentialUnavailable, profileChanged, authExchangeFailed, authRejected
    case transportFailed, responseInvalid

    public var code: String {
        switch self {
        case .credentialUnavailable, .profileChanged, .authExchangeFailed: "AUTH_INVALID"
        case .authRejected: "ACCESS_REVOKED"
        case .transportFailed: "NETWORK_UNAVAILABLE"
        case .responseInvalid: "INTEGRITY_FAILED"
        }
    }

    public var retryable: Bool { self == .authExchangeFailed || self == .transportFailed }
    public var message: String { "Recent library read failed: \(rawValue)." }
    public var details: JSONValue {
        .object(["category": .string("recentLibraryFailure"), "stage": .string(rawValue)])
    }

    public init?(error: JSONValue) {
        guard let object = error.object, Set(object.keys) == ["code", "message", "retryable", "details"],
              let details = object["details"]?.object, Set(details.keys) == ["category", "stage"],
              details["category"]?.string == "recentLibraryFailure",
              let stage = details["stage"]?.string, let failure = Self(rawValue: stage),
              object["code"]?.string == failure.code, object["message"]?.string == failure.message,
              object["retryable"]?.boolean == failure.retryable else { return nil }
        self = failure
    }
}
