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

    static let notSupportedTitle = "Not available on Mac yet"
    static let notSupportedReason = "There's no tested launch setup for this game yet, so Play isn't offered."

    var canPlay: Bool { self == .supported }
    var reason: String? {
        switch self {
        case .supported: nil
        case .notSupported(let reason), .engineMissing(let reason): reason
        }
    }
    var offersEngines: Bool { if case .engineMissing = self { true } else { false } }

    /// Admitted per-title launch setup (bundled or local profile), independent of engine state.
    static func hasLaunchProfile(productID: String, defaults: UserDefaults = .standard,
                                 evidence: MacGameEvidence.Game? = nil) -> Bool {
        (try? NativeTitleLaunchProfile.read(productID: productID, defaults: defaults,
                                            provider: .calimocho, evidence: evidence)) != nil
    }

    static func evaluate(productID: String, defaults: UserDefaults = .standard,
                         evidence: MacGameEvidence.Game? = nil, hasEngineOverride: Bool = false,
                         engineDefaults: () throws -> NativeEngineDefaults = NativeEngineDefaults.read,
                         registryDigest: (String) -> String? = Self.fileDigest,
                         releaseStatus: (CalimochoReleasePin) -> CalimochoReleaseError? = Self.releaseManifestStatus) -> Self {
        let profile: NativeTitleLaunchProfile?
        do {
            profile = try NativeTitleLaunchProfile.read(productID: productID, defaults: defaults,
                                                        provider: .calimocho, evidence: evidence)
        } catch let failure as NativeLaunchError {
            return .notSupported(failure.localizedDescription)
        } catch {
            return .notSupported(NativeLaunchError.invalidProfile.localizedDescription)
        }
        guard let profile else { return .notSupported(notSupportedReason) }
        // An explicit per-game engine choice is re-verified at launch; it is never substituted here.
        if hasEngineOverride { return .supported }
        if profile.engine == nil, defaults.data(forKey: NativeEngineDefaults.preferenceKey) != nil { return .supported }
        guard let catalog = try? engineDefaults() else { return .engineMissing(engineMissingReason(profile.engine)) }
        let engine = profile.engine ?? catalog.defaultEngine
        guard let binding = catalog.bindings.first(where: { $0.engineName == engine }),
              profile.registrySHA256.map({ $0 == binding.registrySha256 }) ?? true else {
            return .engineMissing(engineMissingReason(engine))
        }
        if let pin = binding.release {
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

/// User-facing engine names; identifiers are never renamed.
enum EngineDisplayName {
    static func label(_ engine: String) -> String {
        let lowered = engine.lowercased()
        if lowered.hasPrefix("calimocho") {
            let version = engine.range(of: #"wine(\d+(?:\.\d+)?)"#, options: [.regularExpression, .caseInsensitive])
                .map { String(engine[$0].dropFirst(4)) }
            return version.map { "Calimocho (Wine \($0))" } ?? "Calimocho"
        }
        if lowered.contains("gptk") || lowered.hasPrefix("apple-") { return "Apple Game Porting Toolkit" }
        if lowered.contains("crossover") { return "CrossOver" }
        return engine
    }
}
