// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum Entitlement: String, CaseIterable, Codable, Sendable {
    case purchase, subscription, none, unknown

    public var label: String {
        switch self {
        case .purchase: "Purchased"
        case .subscription: "Subscription access"
        case .none: "No access"
        case .unknown: "Access unverified"
        }
    }
}

public enum Installability: String, Codable, Sendable {
    case downloadable, blocked, unknown

    public var label: String {
        switch self {
        case .downloadable: "PC package available"
        case .blocked: "Download unavailable"
        case .unknown: "Download unverified"
        }
    }
}

public enum Compatibility: String, Codable, Sendable {
    case verified, experimental, unsupported, unknown

    public var label: String { rawValue.capitalized }
}

public struct RuntimeFingerprint: Equatable, Codable, Sendable {
    public let os: String
    public let architecture: String
    public let runtime: String

    public init(os: String, architecture: String, runtime: String) {
        self.os = os
        self.architecture = architecture
        self.runtime = runtime
    }
}

public struct Evidence: Equatable, Codable, Sendable {
    public let source: String
    public let checkedAt: Date
    public let expiresAt: Date?
    public let fingerprint: RuntimeFingerprint?

    public init(source: String, checkedAt: Date, expiresAt: Date? = nil,
                fingerprint: RuntimeFingerprint? = nil) {
        self.source = source
        self.checkedAt = checkedAt
        self.expiresAt = expiresAt
        self.fingerprint = fingerprint
    }
}

public struct PackageIdentity: Equatable, Codable, Sendable {
    public let id: String
    public let version: String
    public let language: String
    public let architecture: String

    public init(id: String, version: String, language: String, architecture: String) {
        self.id = id
        self.version = version
        self.language = language
        self.architecture = architecture
    }
}

public struct Game: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let editionID: String
    public let title: String
    public let subtitle: String
    public let summary: String
    public let art: String
    public let entitlement: Entitlement
    public let accessEvidence: Evidence
    public let installability: Installability
    public let package: PackageIdentity?
    public let downloadReason: String
    public let compatibility: Compatibility
    public let compatibilityEvidence: Evidence
    public let downloadBytes: Int64
    public let expandedBytes: Int64
    public let initiallyInstalled: Bool
}

public enum InventoryState: String, CaseIterable, Sendable {
    case complete, partial, stale, offline, empty, failed

    public var label: String { rawValue.capitalized }

#if !XODUS_SHIPPING
    public var notice: String? {
        switch self {
        case .complete: nil
        case .partial: "Partial library: one fixture page is unavailable. Other games may be missing."
        case .stale: "Library out of date. Refresh access before a new installation."
        case .offline: "Offline fixture: cached titles are visible, but new installations are blocked."
        case .empty: nil
        case .failed: "Library could not be loaded. This is a simulated inventory error, not an empty account."
        }
    }
#endif
}

#if !XODUS_SHIPPING
public struct InstallPlan: Equatable, Sendable {
    public let editionID: String
    public let package: PackageIdentity
    public let runtime: RuntimeFingerprint
    public let downloadBytes: Int64
    public let expandedBytes: Int64
    public let stagingBytes: Int64
    public let reserveBytes: Int64
    public let availableBytes: Int64
    public let destination: String

    public var requiredFreeBytes: Int64 { expandedBytes + stagingBytes + reserveBytes }
    public var hasEnoughSpace: Bool { availableBytes >= requiredFreeBytes }

    public init(game: Game, package: PackageIdentity, availableBytes: Int64) {
        editionID = game.editionID
        self.package = package
        runtime = Fixtures.fingerprint
        downloadBytes = game.downloadBytes
        expandedBytes = game.expandedBytes
        stagingBytes = game.downloadBytes
        reserveBytes = 2 * Fixtures.gigabyte
        self.availableBytes = availableBytes
        destination = "Demo storage / Games (not written)"
    }
}
#endif

public enum InstallDecision: Equatable, Sendable {
    case allowed
    case blocked(String)

    public var reason: String? {
        if case let .blocked(reason) = self { return reason }
        return nil
    }
}

public enum ActionPolicy {
    public static func evaluate(_ game: Game, inventory: InventoryState,
                                now: Date, fingerprint: RuntimeFingerprint) -> InstallDecision {
        if inventory == .stale || inventory == .offline || inventory == .failed || inventory == .empty {
            return .blocked("Refresh authoritative access before installing.")
        }
        guard game.entitlement == .purchase || game.entitlement == .subscription else {
            return .blocked(game.entitlement == .none
                ? "This title is not in your entitled library." : "Access has not been verified.")
        }
        if let expiry = game.accessEvidence.expiresAt, expiry <= now {
            return .blocked("Subscription access has expired.")
        }
        let age = now.timeIntervalSince(game.accessEvidence.checkedAt)
        guard age >= 0 && age <= 24 * 60 * 60 else {
            return .blocked("Access evidence is out of date.")
        }
        guard game.installability == .downloadable, let package = game.package else {
            return .blocked(game.downloadReason)
        }
        guard package.architecture == fingerprint.architecture else {
            return .blocked("This package architecture does not match the current configuration.")
        }
        guard game.compatibility == .verified || game.compatibility == .experimental else {
            return .blocked(game.compatibility == .unsupported
                ? "This configuration is unsupported." : "Compatibility has not been checked.")
        }
        guard game.compatibilityEvidence.fingerprint == fingerprint else {
            return .blocked("Compatibility evidence belongs to a different OS or runtime.")
        }
        return .allowed
    }
}

#if !XODUS_SHIPPING
public enum JobPhase: String, Sendable {
    case queued, downloading, paused, verifying, extracting, committing, completed, cancelled, failed

    public var label: String { rawValue.capitalized }
    public var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }
    public var progress: Double {
        switch self {
        case .queued: 0
        case .downloading, .paused, .failed: 0.35
        case .verifying: 0.65
        case .extracting: 0.8
        case .committing: 0.95
        case .completed: 1
        case .cancelled: 0
        }
    }
}

public struct FixtureJob: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let gameID: String
    public var phase: JobPhase

    public init(gameID: String, phase: JobPhase = .queued) {
        id = UUID()
        self.gameID = gameID
        self.phase = phase
    }

    public mutating func advance() {
        switch phase {
        case .queued: phase = .downloading
        case .downloading: phase = .verifying
        case .verifying: phase = .extracting
        case .extracting: phase = .committing
        case .committing: phase = .completed
        case .paused, .completed, .cancelled, .failed: break
        }
    }

    public mutating func cancel() {
        guard !phase.isTerminal else { return }
        phase = .cancelled
    }

    public mutating func togglePause() {
        if phase == .downloading { phase = .paused }
        else if phase == .paused { phase = .downloading }
    }

    public mutating func fail() {
        guard !phase.isTerminal else { return }
        phase = .failed
    }

    public mutating func retry() {
        guard phase == .failed else { return }
        phase = .queued
    }
}
#endif

public enum DisplayFormat {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
