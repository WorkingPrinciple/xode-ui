// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation
import Security

/// The publisher's release stays separate from Ode's app bundle.
struct CalimochoReleasePin: Equatable, Sendable {
    let engineName: String
    let wineSha256: String
    let wineserverSha256: String
    let engineJSONSha256: String
    let manifestSha256: String
    let teamID: String
    let renderer: String
    let downloadURL: URL?
    let archiveSha256: String?
    let archiveByteCount: Int64?
    let expandedByteCount: Int64?
    let attestation: String

    static let release06 = Self(
        engineName: "calimocho-11.20-4.0b3-06",
        wineSha256: "803a62d101303bb3160da4aa8a506857c3d1e1146aa4a0c9ee8250357ef12505",
        wineserverSha256: "7102d70405e7667acf143e710723f58fb24d32eee81468b1f0f02279343601d0",
        engineJSONSha256: "d3ca32d8d706be0ca948f661f76e68c4a735b78362c6fb95fe50c12eb5db18ff",
        manifestSha256: "db1b642e1d1a93cf50a3620a994ca049e34ce2352dc25fc34617a651302528bf",
        teamID: "M62Z4M5EUY",
        renderer: "apple-4.0b3",
        downloadURL: URL(string: "https://github.com/WorkingPrinciple/calimocho/releases/download/engine-0.1120.4.6/calimocho-11.20-4.0b3-06-macos.zip"),
        archiveSha256: "3fc4467b466b6f8f0855c1934b2fe6a3d1c02b0c5ca85037860b735e4e419ee5",
        archiveByteCount: 200_075_043,
        expandedByteCount: 695_625_804,
        attestation: "Calimocho engine-0.1120.4.6 published release; game qualification is separate")

    static func named(_ name: String) -> Self? { name == release06.engineName ? .release06 : nil }
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

struct CalimochoReleaseManifest: Decodable, Equatable, Sendable {
    struct Provider: Decodable, Equatable, Sendable { let id: String; let contract_version: Int }
    struct Paths: Decodable, Equatable, Sendable { let wine: String; let wineserver: String }
    struct Signing: Decodable, Equatable, Sendable { let team_id: String }
    let schema: String
    let engine_id: String
    let version: String
    let provider: Provider
    let paths: Paths
    let environment: [String: String]
    let signing: Signing
}

struct VerifiedCalimochoEngine: Equatable, Sendable {
    let pin: CalimochoReleasePin
    let root: URL
    let manifest: CalimochoReleaseManifest
    let wine: URL
    let wineserver: URL
    let environment: [String: String]
}

enum CalimochoReleaseEngines {
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

    static func verify(_ pin: CalimochoReleasePin,
                       root: URL = defaultEnginesRoot,
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> VerifiedCalimochoEngine {
        try checkCancellation()
        let engineRoot = root.appendingPathComponent(pin.engineName, isDirectory: true)
        var info = stat()
        guard lstat(engineRoot.path, &info) == 0 else {
            if errno == ENOENT { throw CalimochoReleaseError.notInstalled }
            throw CalimochoReleaseError.damaged("its folder couldn't be inspected.")
        }
        guard info.st_mode & S_IFMT == S_IFDIR, (try? GameScriptFiles.checkPath(engineRoot)) != nil else {
            throw CalimochoReleaseError.damaged("its folder is a link or not a folder.")
        }
        let manifestURL = engineRoot.appendingPathComponent("calimocho-engine.json")
        guard let bytes = try? InstalledGameFiles.readRegular(manifestURL, maximumBytes: 65_536) else {
            throw CalimochoReleaseError.damaged("calimocho-engine.json is missing.")
        }
        try checkCancellation()
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
        try checkCancellation()
        let wine = try confined(manifest.paths.wine, in: engineRoot)
        let wineserver = try confined(manifest.paths.wineserver, in: engineRoot)
        guard try fileDigest(wine, checkCancellation: checkCancellation) == pin.wineSha256,
              try fileDigest(wineserver, checkCancellation: checkCancellation) == pin.wineserverSha256 else {
            throw CalimochoReleaseError.damaged("its Wine files don't match the release.")
        }
        try checkCancellation()
        guard codeSignatureValid(wine, requirement: requirement(team: pin.teamID)),
              codeSignatureValid(wineserver, requirement: requirement(team: pin.teamID)) else {
            throw CalimochoReleaseError.untrusted
        }
        try checkCancellation()
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
        let url = registries.appendingPathComponent("\(engine.pin.engineName)-ode-default-v2-\(digest(data)).json")
        try GameScriptFiles.checkPath(registries, allowMissing: true)
        try FileManager.default.createDirectory(at: registries, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try GameScriptFiles.checkPath(registries)
        var directory = stat()
        guard lstat(registries.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == getuid() else {
            throw CalimochoReleaseError.damaged("the registry folder is unsafe.")
        }
        func matchesExisting() throws -> Bool {
            let existing = try InstalledGameFiles.readRegular(url, maximumBytes: 65_536, privateFile: true)
            guard existing == data else {
                throw CalimochoReleaseError.damaged("an existing registry differs and wasn't replaced.")
            }
            return true
        }
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            _ = try matchesExisting()
            return (url, digest(data))
        }
        guard errno == ENOENT else { throw GameScriptError.storage }
        let temporary = registries.appendingPathComponent(".calimocho-registry-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GameScriptError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0 else { throw GameScriptError.storage }
            try handle.close()
            if renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) != 0 {
                let failure = errno
                guard unlink(temporary.path) == 0 else { throw GameScriptError.storage }
                guard failure == EEXIST, try matchesExisting() else { throw GameScriptError.storage }
            }
        } catch {
            handle.closeFile()
            if unlink(temporary.path) != 0 && errno != ENOENT { throw GameScriptError.storage }
            throw error
        }
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

    static func fileDigest(_ url: URL,
                           checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> String {
        try checkCancellation()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CalimochoReleaseError.damaged("\(url.lastPathComponent) couldn't be read.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var hasher = SHA256()
        var total = 0
        while true {
            try checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            try checkCancellation()
            total += chunk.count
            guard total <= 1_073_741_824 else { throw CalimochoReleaseError.damaged("\(url.lastPathComponent) is too large.") }
            hasher.update(data: chunk)
        }
        try checkCancellation()
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
