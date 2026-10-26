// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusCore

/// Launch preferences are independent of the management backend selection.
enum EngineDefaults {
    static let defaultEngineKey = "Xodus.defaultEngine"
    static let crossOverApplicationKey = "Xodus.runtime.crossOverApplication"

    static func crossOverApplication(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: crossOverApplicationKey)
    }

    static func setCrossOverApplication(_ path: String?, defaults: UserDefaults = .standard) {
        if let path { defaults.set(path, forKey: crossOverApplicationKey) }
        else { defaults.removeObject(forKey: crossOverApplicationKey) }
    }

    static func prefixPath(_ kind: RuntimeProviderKind, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: "Xodus.runner.\(kind.rawValue).prefix")
    }

    static func setPrefixPath(_ path: String?, for kind: RuntimeProviderKind,
                              defaults: UserDefaults = .standard) {
        let key = "Xodus.runner.\(kind.rawValue).prefix"
        if let path { defaults.set(path, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

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
        for kind in RuntimeProviderKind.allCases where kind != .crossover && kind != .calimocho {
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
    static func executable(in selection: URL) -> URL? {
        if isExecutable(selection) { return selection }
        for relative in ["bin/wine64", "bin/wine", "wine/bin/wine64", "wine/bin/wine",
                         "Contents/Resources/wine/bin/wine64", "Contents/Resources/wine/bin/wine"] {
            let candidate = selection.appendingPathComponent(relative)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    static func isPrefix(_ folder: URL) -> Bool {
        let root = folder.standardizedFileURL
        guard root.isFileURL, root == root.resolvingSymlinksInPath() else { return false }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("drive_c").path,
                                            isDirectory: &directory), directory.boolValue else { return false }
        return ["system.reg", "cxbottle.conf"].contains {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    static func detect(
        crossOver: CrossOverDependencyState = CrossOverDetector.detect(),
        runnerPaths: [RuntimeProviderKind: String] = EngineDefaults.runnerPaths(),
        probe: (URL) -> Bool = RunnerAvailabilityDetector.isExecutable
    ) -> RunnerAvailability {
        var installed: Set<RuntimeProviderKind> = []
        if crossOver.isVerified { installed.insert(.crossover) }
        for kind in RuntimeProviderKind.allCases where kind != .crossover && kind != .calimocho {
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
