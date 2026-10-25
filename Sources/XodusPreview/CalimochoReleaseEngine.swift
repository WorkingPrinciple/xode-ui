// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import Security

/// REQ-115/B3: a signed Calimocho release engine installed by the user under
/// `~/Library/Application Support/Xode/Engines/<engine_id>/`. Xode never bundles or
/// redistributes it; it only discovers, verifies and renders a local registry for it.
struct CalimochoReleasePin: Equatable, Sendable {
    let engineName: String
    let wineSha256: String
    let wineserverSha256: String
    let engineJSONSha256: String
    let manifestSha256: String
    let teamID: String
    let renderer: String
    let attestation: String

    static let release01 = Self(
        engineName: "calimocho-11.20-4.0b3-01",
        wineSha256: "c2eb2810540eb32e1d99df0279a05868bf36c562cbeb71ec37be31d1bb153437",
        wineserverSha256: "05a3193d0bce401bdcba653161e54824ea8924951ff0ecb80f6f8ba0a0539639",
        engineJSONSha256: "fb6c79da22153aaa70810fa1349663ebd6cf48f4130dc9c9ba57c930a5689fe8",
        manifestSha256: "7c9e08a9154e04f23a979d53b9c4b28f0c0487b175aa44374cdf55e2b7dd33c5",
        teamID: "M62Z4M5EUY",
        renderer: "apple-4.0b3",
        attestation: "Calimocho release engine-11.20-4.0b3-01 (REQ-115 release smoke run)")

    static let all: [Self] = [.release01]
    static func named(_ name: String) -> Self? { all.first { $0.engineName == name } }
}

enum CalimochoReleaseError: LocalizedError, Equatable {
    case notInstalled
    case damaged(String)
    case untrusted

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Calimocho isn't installed."
        case .damaged(let detail): "The installed Calimocho engine couldn't be verified: \(detail) Reinstall it, then check again."
        case .untrusted: "The installed Calimocho engine isn't signed by its publisher. Reinstall it from the official release, then check again."
        }
    }
}

struct CalimochoReleaseManifest: Decodable, Equatable {
    struct Provider: Decodable, Equatable { let id: String; let contract_version: Int }
    struct Paths: Decodable, Equatable { let wine: String; let wineserver: String }
    struct Signing: Decodable, Equatable { let team_id: String }
    let schema: String
    let engine_id: String
    let version: String
    let provider: Provider
    let paths: Paths
    let environment: [String: String]
    let signing: Signing
}

struct VerifiedCalimochoEngine: Equatable {
    let pin: CalimochoReleasePin
    let root: URL
    let manifest: CalimochoReleaseManifest
    let wine: URL
    let wineserver: URL
    let environment: [String: String]
}

enum CalimochoReleaseEngines {
    static let maximumEntries = 32
    /// Code requirement for the publisher's Developer ID; ad-hoc or other-team builds are refused.
    static func requirement(team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    static var defaultEnginesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Xode/Engines", isDirectory: true)
    }

    static var defaultRegistriesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Xodus/EngineRegistries", isDirectory: true)
    }

    /// Bounded, non-following scan: only real directories whose name is a pinned release engine.
    static func installedNames(root: URL = defaultEnginesRoot) -> [String] {
        guard (try? GameScriptFiles.checkPath(root)) != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path),
              names.count <= 1024 else { return [] }
        return names.sorted().prefix(maximumEntries).filter { name in
            guard CalimochoReleasePin.named(name) != nil else { return false }
            var info = stat()
            return lstat(root.appendingPathComponent(name).path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }
    }

    static func verify(_ pin: CalimochoReleasePin, root: URL = defaultEnginesRoot,
                       signature: (URL, String) -> Bool = codeSignatureValid) throws -> VerifiedCalimochoEngine {
        let engineRoot = root.appendingPathComponent(pin.engineName, isDirectory: true)
        var info = stat()
        guard lstat(engineRoot.path, &info) == 0 else { throw CalimochoReleaseError.notInstalled }
        guard info.st_mode & S_IFMT == S_IFDIR, (try? GameScriptFiles.checkPath(engineRoot)) != nil else {
            throw CalimochoReleaseError.damaged("its folder is a link or not a folder.")
        }
        let manifestURL = engineRoot.appendingPathComponent("calimocho-engine.json")
        guard let bytes = try? InstalledGameFiles.readRegular(manifestURL, maximumBytes: 65_536) else {
            throw CalimochoReleaseError.damaged("calimocho-engine.json is missing.")
        }
        guard digest(bytes) == pin.engineJSONSha256 else {
            throw CalimochoReleaseError.damaged("calimocho-engine.json doesn't match the release.")
        }
        guard let manifest = try? JSONDecoder().decode(CalimochoReleaseManifest.self, from: bytes),
              manifest.schema == "calimocho-engine/1", manifest.engine_id == pin.engineName,
              manifest.provider.id == "calimocho", manifest.provider.contract_version == 1,
              manifest.signing.team_id == pin.teamID else {
            throw CalimochoReleaseError.damaged("calimocho-engine.json isn't a valid release description.")
        }
        guard let listing = try? InstalledGameFiles.readRegular(engineRoot.appendingPathComponent("MANIFEST.sha256"),
                                                                 maximumBytes: 16_777_216),
              digest(listing) == pin.manifestSha256 else {
            throw CalimochoReleaseError.damaged("MANIFEST.sha256 doesn't match the release.")
        }
        let wine = try confined(manifest.paths.wine, in: engineRoot)
        let wineserver = try confined(manifest.paths.wineserver, in: engineRoot)
        guard try fileDigest(wine) == pin.wineSha256, try fileDigest(wineserver) == pin.wineserverSha256 else {
            throw CalimochoReleaseError.damaged("its Wine files don't match the release.")
        }
        guard signature(wine, requirement(team: pin.teamID)),
              signature(wineserver, requirement(team: pin.teamID)) else { throw CalimochoReleaseError.untrusted }
        return VerifiedCalimochoEngine(pin: pin, root: engineRoot, manifest: manifest, wine: wine,
                                       wineserver: wineserver,
                                       environment: try environment(manifest.environment, root: engineRoot))
    }

    /// The manifest environment is used as published, with only `${ENGINE_ROOT}` expanded.
    static func environment(_ values: [String: String], root: URL) throws -> [String: String] {
        guard values.count <= 64 else { throw CalimochoReleaseError.damaged("its environment is too large.") }
        var expanded: [String: String] = [:]
        for (key, value) in values {
            let upper = key.uppercased()
            guard !key.isEmpty, key.utf8.count <= 128,
                  key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }),
                  !upper.hasPrefix("DYLD_"), !upper.hasPrefix("MTL_HUD"), upper != "PATH", upper != "HOME",
                  value.utf8.count <= 4096 else {
                throw CalimochoReleaseError.damaged("its environment sets \(key), which isn't allowed.")
            }
            let resolved = value.replacingOccurrences(of: "${ENGINE_ROOT}", with: root.path)
            guard !resolved.contains("${") else {
                throw CalimochoReleaseError.damaged("its environment uses an unknown variable.")
            }
            expanded[key] = resolved
        }
        return expanded
    }

    static func confined(_ relative: String, in root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), relative.utf8.count <= 256,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CalimochoReleaseError.damaged("a path in calimocho-engine.json leaves the engine folder.")
        }
        let url = root.appendingPathComponent(relative)
        var info = stat()
        guard (try? GameScriptFiles.checkPath(url)) != nil, lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0 else {
            throw CalimochoReleaseError.damaged("\(relative) is missing or isn't a program.")
        }
        return url
    }

    /// Writes the registry for this Mac. Paths are absolute here only; nothing user-specific is shipped.
    static func renderRegistry(_ engine: VerifiedCalimochoEngine,
                               registries: URL = defaultRegistriesRoot) throws -> (url: URL, digest: String) {
        let data = try registryData(engine)
        let url = registries.appendingPathComponent("\(engine.pin.engineName).json")
        if let existing = try? InstalledGameFiles.readRegular(url, maximumBytes: 65_536), existing == data {
            return (url, digest(data))
        }
        try GameScriptFiles.writePrivate(data, to: url)
        return (url, digest(data))
    }

    static func registryData(_ engine: VerifiedCalimochoEngine) throws -> Data {
        struct Registry: Encodable {
            struct SmokeTest: Encodable { let status: String; let evidence: String }
            struct Provider: Encodable { let id: String; let contract_version: Int }
            struct Entry: Encodable {
                let name, kind, version, install_path, wine, wineserver, sha256, wineserver_sha256: String
                let environment: [String: String]
                let provider: Provider
                let renderer: String
                let smoke_test: SmokeTest
                let local_only: Bool
            }
            let schema_version = 1
            let blocked: [String] = []
            let engines: [Entry]
        }
        let pin = engine.pin
        let registry = Registry(engines: [.init(
            name: pin.engineName, kind: "free", version: "Calimocho \(engine.manifest.version)",
            install_path: engine.root.path, wine: engine.wine.path, wineserver: engine.wineserver.path,
            sha256: pin.wineSha256, wineserver_sha256: pin.wineserverSha256,
            environment: engine.environment, provider: .init(id: "calimocho", contract_version: 1),
            renderer: pin.renderer, smoke_test: .init(status: "pass", evidence: pin.attestation), local_only: false)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(registry)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileDigest(_ url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CalimochoReleaseError.damaged("\(url.lastPathComponent) couldn't be read.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            total += chunk.count
            guard total <= 1_073_741_824 else { throw CalimochoReleaseError.damaged("\(url.lastPathComponent) is too large.") }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func codeSignatureValid(_ url: URL, requirement text: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

extension CalimochoAvailability {
    static let notAdmittedReason = "The engine check didn't confirm this Calimocho engine, so it can't be used. Reinstall it from the official release, then check again."

    /// Ready only when the fast local pre-filter (descriptor, MANIFEST.sha256 file, Wine digests, Team ID) passes
    /// AND backend `engine-inspect` admitted this exact engine. The backend verifies every manifest entry and the
    /// tree; the app does not. Reads and hashes the engine, so call it off the main actor.
    static func verifiedRelease(_ pin: CalimochoReleasePin = .release01,
                                root: URL = CalimochoReleaseEngines.defaultEnginesRoot,
                                signature: (URL, String) -> Bool = CalimochoReleaseEngines.codeSignatureValid,
                                admission: EngineInspection?) -> Self {
        do {
            let engine = try CalimochoReleaseEngines.verify(pin, root: root, signature: signature)
            return CalimochoReleaseEngines.admits(admission, engine: engine) ? .ready : .invalid(notAdmittedReason)
        } catch CalimochoReleaseError.notInstalled {
            return .missing
        } catch {
            return .invalid(error.localizedDescription)
        }
    }
}

extension CalimochoReleaseEngines {
    /// Backend admission for this exact release engine: identity and integrity only, never title qualification.
    static func admits(_ inspection: EngineInspection?, engine: VerifiedCalimochoEngine) -> Bool {
        guard let inspection else { return false }
        return inspection.error == nil && inspection.ready && inspection.admission == "admitted"
            && inspection.admittedProvider == "calimocho" && inspection.declaredProvider == "calimocho"
            && inspection.engineName == engine.pin.engineName
            && inspection.wineSha256 == engine.pin.wineSha256
            && inspection.wineserverSha256 == engine.pin.wineserverSha256
    }
}
