// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusCore

/// Launch preferences are independent of the management backend selection.
enum EngineDefaults {
    static let defaultEngineKey = "Xodus.defaultEngine"

    static func defaultEngine(_ defaults: UserDefaults = .standard) -> RuntimeProviderKind? {
        defaults.string(forKey: defaultEngineKey).flatMap(RuntimeProviderKind.init(rawValue:))
    }

    static func setDefaultEngine(_ kind: RuntimeProviderKind?, _ defaults: UserDefaults = .standard) {
        if let kind { defaults.set(kind.rawValue, forKey: defaultEngineKey) }
        else { defaults.removeObject(forKey: defaultEngineKey) }
    }

    static func runnerPathKey(_ kind: RuntimeProviderKind) -> String {
        "Xodus.runner.\(kind.rawValue).executable"
    }

    static func runnerPaths(_ defaults: UserDefaults = .standard) -> [RuntimeProviderKind: String] {
        var paths: [RuntimeProviderKind: String] = [:]
        for kind in RuntimeProviderKind.allCases where kind != .crossover {
            if let path = defaults.string(forKey: runnerPathKey(kind)), !path.isEmpty { paths[kind] = path }
        }
        return paths
    }

    static func setRunnerPath(_ path: String, for kind: RuntimeProviderKind,
                              defaults: UserDefaults = .standard) {
        if path.isEmpty { defaults.removeObject(forKey: runnerPathKey(kind)) }
        else { defaults.set(path, forKey: runnerPathKey(kind)) }
    }
}

/// CrossOver is signature-verified. Experimental providers use their own explicit
/// runner registrations, never the management binary or the default preference.
/// The executable's presence is observed; toolkit provenance/version remain the
/// user's declarations, not a verified compatibility or gameplay claim.
enum RunnerAvailabilityDetector {
    static func detect(
        crossOver: CrossOverDependencyState = CrossOverDetector.detect(),
        runnerPaths: [RuntimeProviderKind: String] = EngineDefaults.runnerPaths(),
        probe: (URL) -> Bool = RunnerAvailabilityDetector.isExecutable
    ) -> RunnerAvailability {
        var installed: Set<RuntimeProviderKind> = []
        if crossOver.isVerified { installed.insert(.crossover) }
        for kind in RuntimeProviderKind.allCases where kind != .crossover {
            if let path = runnerPaths[kind], path.hasPrefix("/"),
               probe(URL(fileURLWithPath: path)) {
                installed.insert(kind)
            }
        }
        return RunnerAvailability(installed)
    }

    static func isExecutable(_ url: URL) -> Bool {
        (try? InstalledGameFiles.checkLauncher(url)) != nil
    }
}
