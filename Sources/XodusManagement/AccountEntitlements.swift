// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum PCGameAcquisitionKind: String, Codable, Sendable {
    case unknown, purchased, subscription

    public static func merged(_ current: Self?, _ next: Self) -> Self {
        guard let current else { return next }
        if current == .purchased || next == .purchased { return .purchased }
        return current == .subscription || next == .subscription ? .subscription : .unknown
    }
}

public enum GamePassPlan: String, Codable, Sendable, CaseIterable {
    case pc, console, ultimate, undetermined

    public var label: String {
        switch self {
        case .pc: "PC Game Pass"
        case .console: "Console Game Pass"
        case .ultimate: "Game Pass Ultimate"
        case .undetermined: "Subscription (plan unknown)"
        }
    }
}

public enum GamePassAccess: Equatable, Sendable {
    case unknown, inactive
    case active(GamePassPlan)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
    public var plan: GamePassPlan? {
        if case let .active(plan) = self { return plan }
        return nil
    }
}

public enum AccountTier: Equatable, Sendable {
    case unknown, free, owned
    case gamePass(GamePassPlan)

    public var label: String {
        switch self {
        case .unknown: "Access not verified"
        case .free: "Free"
        case .owned: "Owned library"
        case let .gamePass(plan): plan.label
        }
    }

    public var symbol: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .free: "person.crop.circle"
        case .owned: "checkmark.seal"
        case .gamePass: "ticket"
        }
    }
}

public struct AccountEntitlements: Equatable, Sendable {
    public let signedIn: Bool
    public let accessIsCurrent: Bool
    public let ownsGames: Bool
    public let gamePass: GamePassAccess

    public static let signedOut = Self(signedIn: false, accessIsCurrent: false,
                                      ownsGames: false, gamePass: .unknown)

    // The optional probe must be current and bound to the PC-library account.
    // A saved credential, stale snapshot or a different game-service account is not evidence.
    public static func derive(signedIn: Bool, held: [PCGameAcquisitionKind],
                              gamePassActive: Bool?, accessIsCurrent: Bool) -> Self {
        guard signedIn else { return .signedOut }
        guard accessIsCurrent else {
            return Self(signedIn: true, accessIsCurrent: false, ownsGames: false, gamePass: .unknown)
        }
        let owns = held.contains { $0 != .subscription }
        let access: GamePassAccess
        if gamePassActive == true { access = .active(.pc) }
        else if held.contains(.subscription) {
            // Recurring proves a current title grant, not the subscription brand or plan.
            access = .active(.undetermined)
        } else if gamePassActive == false { access = .inactive }
        else { access = .unknown }
        return Self(signedIn: true, accessIsCurrent: true, ownsGames: owns, gamePass: access)
    }

    public var tiers: [AccountTier] {
        guard signedIn else { return [] }
        guard accessIsCurrent else { return [.unknown] }
        var result: [AccountTier] = []
        if ownsGames { result.append(.owned) }
        if case let .active(plan) = gamePass { result.append(.gamePass(plan)) }
        if result.isEmpty { result.append(gamePass == .inactive ? .free : .unknown) }
        return result
    }

    public var summary: String {
        guard signedIn else { return "Not signed in" }
        return tiers.map(\.label).joined(separator: " + ")
    }

    public var gamePassPlanUndetermined: Bool { gamePass.plan == .undetermined }
}

public enum LibraryEligibility: String, Codable, Sendable {
    case owned, gamePass, installedUnknown

    public static func evaluate(entitlement: PCGameAcquisitionKind?, accessIsCurrent: Bool,
                                verifiedGamePassAccess: Bool, installed: Bool) -> Self? {
        if accessIsCurrent, let entitlement {
            return entitlement == .subscription ? .gamePass : .owned
        }
        if verifiedGamePassAccess { return .gamePass }
        return installed ? .installedUnknown : nil
    }
}
