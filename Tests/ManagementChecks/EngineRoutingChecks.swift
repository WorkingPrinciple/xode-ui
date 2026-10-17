// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusCore
import XodusManagement

extension Checks {
    /// M3: the pure launch-routing decision. Every case pins (package type x
    /// per-game override x configured default x installed-runner availability) to
    /// the exact routed runner or explicit unavailability. A missing selected
    /// engine must refuse launch, never silently substitute another runner.
    func engineRoutingChecks() throws {
        let cases = try fixture("engine-routing-v1")["cases"]?.array ?? []
        check(cases.count >= 10, "Engine-routing corpus pins type x override x default x availability")
        for value in cases {
            guard let name = value["name"]?.string, let request = value["request"],
                  let expected = value["expected"] else {
                check(false, "Engine-routing case is well formed")
                continue
            }
            guard let packageType = request["packageType"]?.string.flatMap(PackageType.init(rawValue:)),
                  let available = request["availability"] else { throw ManagementError.invalidPayload }
            let override = try fixtureKind(request["override"])
            let defaultEngine = try fixtureKind(request["defaultEngine"])
            let availability = try available.decode(RunnerAvailability.self)
            let outcome = EngineRouting.decide(.init(packageType: packageType, override: override,
                defaultEngine: defaultEngine, availability: availability))
            check(try outcome == expectedOutcome(expected),
                  "Engine routing: \(name)")
        }
        // Explicit invariant: an override wins over an installed default.
        check(EngineRouting.decide(.init(packageType: .win32, override: .gptk4, defaultEngine: .crossover,
            availability: RunnerAvailability([.crossover, .gptk4]))) == .routed(.gptk4, .perGameOverride),
              "A per-game override takes precedence over an installed configured default")
        // Explicit invariant: an uninstalled override never falls back to an installed runner.
        check(EngineRouting.decide(.init(packageType: .win32, override: .standaloneWine,
            defaultEngine: .crossover, availability: RunnerAvailability([.crossover]))) ==
            .unavailable(.overrideNotInstalled(.standaloneWine)),
              "An uninstalled override refuses launch instead of substituting the installed default")
        let kinds: [RuntimeProviderKind] = [.crossover, .gptk4, .gptk3, .standaloneWine]
        let choices: [RuntimeProviderKind?] = [nil] + kinds.map { Optional($0) }
        for type in PackageType.allCases {
            for mask in 0..<16 {
                let installed = kinds.enumerated().compactMap { (mask & (1 << $0.offset)) != 0 ? $0.element : nil }
                for override in choices {
                    for preferred in choices {
                        let expected: EngineRoutingOutcome
                        if let override {
                            expected = installed.contains(override) ? .routed(override, .perGameOverride)
                                : .unavailable(.overrideNotInstalled(override))
                        } else if let preferred {
                            expected = installed.contains(preferred) ? .routed(preferred, .configuredDefault)
                                : .unavailable(.defaultNotInstalled(preferred))
                        } else if let first = installed.first {
                            expected = .routed(first, .installedFallback)
                        } else { expected = .unavailable(.noRunnerInstalled) }
                        check(EngineRouting.decide(.init(packageType: type, override: override,
                            defaultEngine: preferred, availability: RunnerAvailability(installed))) == expected,
                            "Routing matrix \(type.rawValue)/\(mask)/\(String(describing: override))/\(String(describing: preferred))")
                    }
                }
            }
        }
    }

    private func fixtureKind(_ value: JSONValue?) throws -> RuntimeProviderKind? {
        if value == .null { return nil }
        guard let kind = value?.string.flatMap(RuntimeProviderKind.init(rawValue:)) else {
            throw ManagementError.invalidPayload
        }
        return kind
    }

    private func expectedOutcome(_ value: JSONValue) throws -> EngineRoutingOutcome {
        if value["outcome"]?.string == "routed",
           let runner = value["runner"]?.string.flatMap(RuntimeProviderKind.init(rawValue:)),
           let reason = value["reason"]?.string.flatMap(EngineRoutingReason.init(rawValue:)) {
            return .routed(runner, reason)
        }
        guard value["outcome"]?.string == "unavailable" else { throw ManagementError.invalidPayload }
        let kind = value["kind"]?.string.flatMap(RuntimeProviderKind.init(rawValue:))
        switch value["unavailable"]?.string {
        case "overrideNotInstalled":
            guard let kind else { throw ManagementError.invalidPayload }
            return .unavailable(.overrideNotInstalled(kind))
        case "defaultNotInstalled":
            guard let kind else { throw ManagementError.invalidPayload }
            return .unavailable(.defaultNotInstalled(kind))
        case "noRunnerInstalled": return .unavailable(.noRunnerInstalled)
        default: throw ManagementError.invalidPayload
        }
    }
}
