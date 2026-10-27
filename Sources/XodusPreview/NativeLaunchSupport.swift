// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

/// Whether Xode can offer Play for a title, decided from its admitted launch profile and the
/// engine that profile is bound to. Read-only: it never selects, substitutes or installs an engine.
enum NativeLaunchSupport: Equatable {
    case supported
    /// No admitted launch setup exists for this title. Play is not offered.
    case notSupported(String)
    /// The title has an admitted setup, but its engine isn't usable on this Mac.
    case engineMissing(String)
    /// Owner decision (REQ-150): an installed title with no tested launch setup still offers Play
    /// through the generic Calimocho launch and the user's chosen engine, labelled honestly.
    case untested

    static let notSupportedTitle = "Not available on Mac yet"
    /// REQ-139: a title gated to the test build has played on this Mac, so it isn't "not available".
    static let inTestingTitle = "In testing on Mac"
    static let inTestingReason = "This game runs in the X Ode test build while it's being qualified, so Play isn't offered in this build yet."

    /// The heading shown when Play isn't offered.
    var unavailableTitle: String {
        if offersEngines { return "Engine needed" }
        return reason == Self.inTestingReason ? Self.inTestingTitle : Self.notSupportedTitle
    }
    static let notSupportedReason = "There's no tested launch setup for this game yet, so Play isn't offered."
    static let untestedTitle = "Not tested on Mac yet"
    static let untestedReason = "This game hasn't been tested with X Ode. It may not start or run well."
    static let untestedEngineMissingReason = "No engine is set up on this Mac yet. Open Engines to set one up, or choose one for this game from its … menu."

    var canPlay: Bool { self == .supported || self == .untested }
    var isUntested: Bool { self == .untested }
    var reason: String? {
        switch self {
        case .supported, .untested: nil
        case .notSupported(let reason), .engineMissing(let reason): reason
        }
    }
    var offersEngines: Bool { if case .engineMissing = self { true } else { false } }

    /// Admitted per-title launch setup (bundled or local profile), independent of engine state.
    static func hasLaunchProfile(productID: String, defaults: UserDefaults = .standard,
                                 evidence: MacGameEvidence.Game? = nil) -> Bool {
        guard productID != NativeFH6Recipe.productID || NativeFH6Recipe.enabled else { return false }
        return (try? NativeTitleLaunchProfile.read(productID: productID, defaults: defaults,
                                            provider: .calimocho, evidence: evidence)) != nil
    }

    static func evaluate(productID: String, defaults: UserDefaults = .standard,
                         evidence: MacGameEvidence.Game? = nil, hasEngineOverride: Bool = false,
                         engineDefaults: () throws -> NativeEngineDefaults = NativeEngineDefaults.read,
                         registryDigest: (String) -> String? = Self.fileDigest,
                         releaseStatus: (CalimochoReleasePin) -> CalimochoReleaseError? = Self.releaseManifestStatus) -> Self {
        guard productID != NativeFH6Recipe.productID || NativeFH6Recipe.enabled else {
            return .notSupported(inTestingReason)
        }
        let profile: NativeTitleLaunchProfile?
        do {
            profile = try NativeTitleLaunchProfile.read(productID: productID, defaults: defaults,
                                                        provider: .calimocho, evidence: evidence)
        } catch let failure as NativeLaunchError {
            return .notSupported(failure.localizedDescription)
        } catch {
            return .notSupported(NativeLaunchError.invalidProfile.localizedDescription)
        }
        guard let profile else {
            // No tested setup: the generic launch uses the user's per-game or default engine, so Play is
            // offered (labelled untested) only when that engine is actually usable here.
            let status = engineStatus(engine: nil, registrySHA256: nil, hasEngineOverride: hasEngineOverride,
                                      defaults: defaults, engineDefaults: engineDefaults,
                                      registryDigest: registryDigest, releaseStatus: releaseStatus)
            switch status {
            case .supported: return .untested
            case .engineMissing(let reason) where reason.hasPrefix("The engine this game was tested with"):
                return .engineMissing(untestedEngineMissingReason)
            default: return status
            }
        }
        return engineStatus(engine: profile.engine, registrySHA256: profile.registrySHA256,
                            hasEngineOverride: hasEngineOverride, defaults: defaults, engineDefaults: engineDefaults,
                            registryDigest: registryDigest, releaseStatus: releaseStatus)
    }

    private static func engineStatus(engine titleEngine: String?, registrySHA256: String?, hasEngineOverride: Bool,
                                     defaults: UserDefaults, engineDefaults: () throws -> NativeEngineDefaults,
                                     registryDigest: (String) -> String?,
                                     releaseStatus: (CalimochoReleasePin) -> CalimochoReleaseError?) -> Self {
        // An explicit per-game engine choice is re-verified at launch; it is never substituted here.
        if hasEngineOverride { return .supported }
        if titleEngine == nil {
            do {
                if try NativeEngineDefaults.savedAdmission(defaults: defaults) != nil { return .supported }
            } catch {
                return .engineMissing(NativeLaunchError.selectionChanged.localizedDescription)
            }
        }
        guard let catalog = try? engineDefaults() else { return .engineMissing(engineMissingReason(titleEngine)) }
        let engine = titleEngine ?? catalog.defaultEngine
        guard let binding = catalog.bindings.first(where: { $0.engineName == engine }),
              registrySHA256.map({ $0 == binding.registrySha256 }) ?? true else {
            return .engineMissing(engineMissingReason(engine))
        }
        if let pin = binding.release ?? (binding.isFH6Recipe ? .release06 : nil) {
            // Cheap presence check; the full hash and signature verification runs before launch.
            switch releaseStatus(pin) {
            case .none: return .supported
            case .some(.notInstalled): return .engineMissing(CalimochoReleaseError.notInstalled.localizedDescription
                + " Open Engines to get it. No other engine was substituted.")
            case .some(let failure): return .engineMissing(failure.localizedDescription)
            }
        }
        guard let path = binding.registryPath,
              registryDigest(NativeTitleLaunchProfile.expand(path)) == binding.registrySha256 else {
            return .engineMissing(engineMissingReason(engine))
        }
        return .supported
    }

    static func engineMissingReason(_ engine: String?) -> String {
        let name = engine.map(EngineDisplayName.label) ?? "Calimocho"
        return "The engine this game was tested with (\(name)) isn't installed on this Mac. Open Engines to set it up. No other engine was substituted."
    }

    static func releaseManifestStatus(_ pin: CalimochoReleasePin) -> CalimochoReleaseError? {
        releaseManifestStatus(pin, root: CalimochoReleaseEngines.defaultEnginesRoot)
    }

    static func releaseManifestStatus(_ pin: CalimochoReleasePin, root: URL) -> CalimochoReleaseError? {
        let folder = root.appendingPathComponent(pin.engineName, isDirectory: true)
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { return .notInstalled }
        guard info.st_mode & S_IFMT == S_IFDIR,
              fileDigest(folder.appendingPathComponent("calimocho-engine.json").path) == pin.engineJSONSha256 else {
            return .damaged("calimocho-engine.json doesn't match the release.")
        }
        return nil
    }

    static func fileDigest(_ path: String) -> String? {
        guard path.hasPrefix("/"),
              let bytes = try? InstalledGameFiles.readRegular(URL(fileURLWithPath: path), maximumBytes: 2_097_152) else {
            return nil
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

extension EngineDisplayName {
    /// Launch-support wording: Calimocho names come from the shared presentation; identifiers are never renamed.
    static func label(_ engine: String) -> String {
        let lowered = engine.lowercased()
        if lowered.hasPrefix("calimocho") { return name(engine) }
        if lowered.contains("gptk") || lowered.hasPrefix("apple-") { return "Apple Game Porting Toolkit" }
        if lowered.contains("crossover") { return "CrossOver" }
        return engine
    }
}
