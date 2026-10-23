// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Which concrete runners are actually installed on this Mac. This is observed
/// evidence from `RunnerAvailabilityDetector`, not a declared configuration.
public struct RunnerAvailability: Equatable, Codable, Sendable {
    public var installed: Set<RuntimeProviderKind>

    public init(_ installed: Set<RuntimeProviderKind> = []) { self.installed = installed }
    public init(_ installed: [RuntimeProviderKind]) { self.installed = Set(installed) }

    public func contains(_ kind: RuntimeProviderKind) -> Bool { installed.contains(kind) }

    enum CodingKeys: String, CodingKey { case installed }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        installed = Set(try values.decode([RuntimeProviderKind].self, forKey: .installed))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // Encode a stable, order-independent array for deterministic fixtures.
        try values.encode(installed.sorted { $0.rawValue < $1.rawValue }, forKey: .installed)
    }
}

/// The inputs to the pure launch-routing decision for one game.
public struct EngineRoutingRequest: Equatable, Sendable {
    public var packageType: PackageType
    public var override: RuntimeProviderKind?
    public var defaultEngine: RuntimeProviderKind?
    public var availability: RunnerAvailability

    public init(packageType: PackageType, override: RuntimeProviderKind? = nil,
                defaultEngine: RuntimeProviderKind? = nil, availability: RunnerAvailability) {
        self.packageType = packageType
        self.override = override
        self.defaultEngine = defaultEngine
        self.availability = availability
    }
}

/// Why a runner was chosen, for honest surfacing and evidence.
public enum EngineRoutingReason: String, Equatable, Codable, Sendable {
    case perGameOverride, configuredDefault, installedFallback
}

/// Why no runner could be chosen. A chosen-but-missing engine never silently
/// substitutes another; the launch is refused and explained.
public enum EngineRoutingUnavailable: Equatable, Sendable {
    case overrideNotInstalled(RuntimeProviderKind)
    case defaultNotInstalled(RuntimeProviderKind)
    case noRunnerInstalled
}

public enum EngineRoutingOutcome: Equatable, Sendable {
    case routed(RuntimeProviderKind, EngineRoutingReason)
    case unavailable(EngineRoutingUnavailable)

    public var runner: RuntimeProviderKind? {
        if case .routed(let kind, _) = self { return kind }
        return nil
    }
}

public enum EngineRouting {
    /// Ordered fallback preference used only when neither a per-game override nor a
    /// configured default applies. CrossOver is the first-release runner; the others
    /// remain Experimental and are tried in descending preference.
    public static let fallbackOrder: [RuntimeProviderKind] = [.crossover, .gptk4, .gptk3, .standaloneWine]

    /// Pure routing decision. Precedence:
    /// 1. A per-game override must be installed, else the launch fails explicitly
    ///    (never substituted by another runner).
    /// 2. Otherwise a configured default engine must be installed, else fail explicitly.
    /// 3. Otherwise the first installed runner in `fallbackOrder`, else no runner.
    /// Format is retained as request context, not an invented compatibility policy:
    /// no package-specific runner certification exists in this contract.
    public static func decide(_ request: EngineRoutingRequest) -> EngineRoutingOutcome {
        if let override = request.override {
            return request.availability.contains(override)
                ? .routed(override, .perGameOverride)
                : .unavailable(.overrideNotInstalled(override))
        }
        if let preferred = request.defaultEngine {
            return request.availability.contains(preferred)
                ? .routed(preferred, .configuredDefault)
                : .unavailable(.defaultNotInstalled(preferred))
        }
        for candidate in fallbackOrder where request.availability.contains(candidate) {
            return .routed(candidate, .installedFallback)
        }
        return .unavailable(.noRunnerInstalled)
    }
}
