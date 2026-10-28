// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum OdeAccountSection: String, Codable, Sendable {
  case library, profile, achievements, runtime, license
}

public struct OdeAccountRead: Decodable, Sendable {
  public let section: OdeAccountSection
  public let accountHash: String
  public let checkedAt: String
  public let payload: JSONValue

  public func validate(section: OdeAccountSection, accountHash: String) throws {
    guard self.section == section, self.accountHash == accountHash,
      ContractValidator.validDate(checkedAt)
    else { throw ManagementError.invalidPayload }
  }
}

public struct OdeAccountCollection: Decodable, Sendable {
  public struct Item: Decodable, Sendable {
    public let productID: String
    public let acquisitionKind: PCGameAcquisitionKind
  }

  public let items: [Item]
  /// REQ-7: active, current Game Pass plan product IDs from the same licence read. Absent from older
  /// producers. Game Pass-licensed titles are not collection rows, so this is their access evidence.
  public let activeSubscriptions: [String]?

  public init(items: [Item], activeSubscriptions: [String]? = nil) {
    self.items = items
    self.activeSubscriptions = activeSubscriptions
  }

  public func validate() throws {
    let plans = activeSubscriptions ?? []
    guard plans.count <= 32, Set(plans).count == plans.count,
      plans.allSatisfy({ plan in
        plan.utf8.count == 12
          && plan.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
      }),
      items.count <= 10_000,
      Set(items.map(\.productID)).count == items.count,
      items.allSatisfy({ item in
        item.productID.utf8.count == 12
          && item.productID.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
      })
    else { throw ManagementError.invalidPayload }
  }
}

public struct OdeProductAccess: Decodable, Sendable {
  public enum Access: String, Decodable, Sendable {
    case permitted, denied, unknown
  }

  public enum Reason: String, Decodable, Sendable {
    case providerDenied, productNotListed, validityUnavailable, grantExpired, grantNotStarted
  }

  public let productID: String
  public let access: Access
  public let expiresAt: String?
  public let reason: Reason?
  public var expiryDate: Date? { expiresAt.flatMap(Self.date) }

  public func validate(productID expected: String, checkedAt: String) throws {
    guard productID == expected, productID.utf8.count == 12,
      productID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
      let checked = Self.date(checkedAt)
    else { throw ManagementError.invalidPayload }
    let expiry: Date?
    if let expiresAt {
      guard let parsed = Self.date(expiresAt) else { throw ManagementError.invalidPayload }
      expiry = parsed
    } else {
      expiry = nil
    }
    switch access {
    case .permitted:
      guard reason == nil, expiry.map({ $0 > checked }) ?? true else {
        throw ManagementError.invalidPayload
      }
    case .denied:
      guard reason == .providerDenied, expiry == nil else { throw ManagementError.invalidPayload }
    case .unknown:
      guard let reason, reason != .providerDenied, expiry == nil else {
        throw ManagementError.invalidPayload
      }
    }
  }

  public func permitsAccess(at now: Date) -> Bool {
    guard access == .permitted, reason == nil else { return false }
    guard let expiresAt else { return true }
    return Self.date(expiresAt).map { $0 > now } ?? false
  }

  private static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
