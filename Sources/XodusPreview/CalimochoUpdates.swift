// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct CalimochoVersion: Comparable, Equatable, Codable, Sendable, CustomStringConvertible {
    let revision: Int
    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.prefix(3).joined(separator: ".") == "0.1120.4",
              !parts[3].isEmpty, parts[3].utf8.allSatisfy({ (48...57).contains($0) }),
              let revision = Int(parts[3]), revision > 0 else { return nil }
        self.revision = revision
    }
    var description: String { "0.1120.4.\(revision)" }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.revision < rhs.revision }
}

extension CalimochoReleasePin {
    var releaseVersion: CalimochoVersion? {
        downloadURL?.pathComponents.first(where: { $0.hasPrefix("engine-") })
            .flatMap { CalimochoVersion(String($0.dropFirst("engine-".count))) }
    }
}

struct LocalCalimochoRelease: Equatable, Codable, Sendable {
    let engineName: String
    let version: CalimochoVersion

    static func installed(root: URL) throws -> [Self] {
        try GameScriptFiles.checkPath(root, allowMissing: true)
        var info = stat()
        if lstat(root.path, &info) != 0 {
            if errno == ENOENT { return [] }
            throw GameScriptError.storage
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard names.count <= 1024 else { throw CalimochoUpdateError.invalidResponse }
        return try names.compactMap { name in
            guard name.hasPrefix("calimocho-"), !name.contains("/") else { return nil }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid() else { return nil }
            let descriptor = folder.appendingPathComponent("calimocho-engine.json")
            let bytes = try InstalledGameFiles.readRegular(descriptor, maximumBytes: 65_536)
            let manifest = try JSONDecoder().decode(CalimochoReleaseManifest.self, from: bytes)
            guard manifest.schema == "calimocho-engine/1", manifest.engine_id == name,
                  manifest.provider.id == "calimocho", manifest.provider.contract_version == 1,
                  let version = CalimochoVersion(manifest.version) else {
                throw CalimochoUpdateError.invalidResponse
            }
            // Discovery is display-only. It does not admit this engine for launch.
            return Self(engineName: name, version: version)
        }.sorted { $0.version > $1.version }
    }
}

enum CalimochoUpdateError: LocalizedError {
    case offline, rateLimited, invalidResponse, failed(Int), admission, busy
    var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Check for Calimocho updates when you're connected."
        case .rateLimited: "GitHub is limiting update checks. Try again later."
        case .invalidResponse: "Calimocho update information couldn't be read. Try again later."
        case .failed(let status): "GitHub couldn't check for updates (HTTP \(status)). Try again later."
        case .admission: "The new engine wasn't admitted. The previous engine and default were kept."
        case .busy: "Finish the running game or operation before updating Calimocho."
        }
    }
}

struct CalimochoReleaseCheck: Sendable {
    let session: URLSession
    init(session: URLSession = Self.publicSession()) { self.session = session }

    private static func publicSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    func latest() async throws -> CalimochoVersion {
        struct Release: Decodable { let tag_name: String; let draft: Bool }
        var latest: CalimochoVersion?
        for page in 1...10 {
            let url = URL(string: "https://api.github.com/repos/WorkingPrinciple/calimocho/releases?per_page=100&page=\(page)")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("X-Ode-Calimocho-Update-Check", forHTTPHeaderField: "User-Agent")
            do {
                let (stream, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw CalimochoUpdateError.invalidResponse }
                if response.statusCode == 403 || response.statusCode == 429 { throw CalimochoUpdateError.rateLimited }
                guard response.statusCode == 200 else { throw CalimochoUpdateError.failed(response.statusCode) }
                var bytes = Data()
                for try await byte in stream {
                    try Task.checkCancellation()
                    guard bytes.count < 2_097_152 else { throw CalimochoUpdateError.invalidResponse }
                    bytes.append(byte)
                }
                let releases = try JSONDecoder().decode([Release].self, from: bytes)
                for release in releases where !release.draft && release.tag_name.hasPrefix("engine-") {
                    if let version = CalimochoVersion(String(release.tag_name.dropFirst(7))),
                       latest == nil || version > latest! { latest = version }
                }
                if !(response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") ?? false) {
                    guard let latest else { throw CalimochoUpdateError.invalidResponse }
                    return latest
                }
            } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                                  .cannotConnectToHost, .timedOut].contains(error.code) {
                throw CalimochoUpdateError.offline
            }
        }
        throw CalimochoUpdateError.invalidResponse
    }
}

enum CalimochoUpdateOutcome: Equatable {
    case upToDate
    case pinnedUpdate(LocalCalimochoRelease)
    case finishUpdate(LocalCalimochoRelease)
    case appUpdate(CalimochoVersion)
    case notInstalled

    static func decide(installed: [LocalCalimochoRelease], pinned: CalimochoVersion,
                       latest: CalimochoVersion) -> Self {
        if let old = installed.first, old.version < pinned { return .pinnedUpdate(old) }
        if latest > pinned { return .appUpdate(latest) }
        return installed.isEmpty ? .notInstalled : .upToDate
    }

    var message: String {
        switch self {
        case .upToDate: "Calimocho is up to date."
        case .pinnedUpdate: "This \(AppBrand.displayName) version includes a newer pinned Calimocho release. The old engine is kept until the update is verified."
        case .finishUpdate: "The pinned Calimocho release is downloaded. Finish the update to verify and activate it."
        case .appUpdate(let version): "Calimocho \(version) is available and will come with the next \(AppBrand.displayName) update."
        case .notInstalled: "Calimocho isn't installed. Get the release pinned by this \(AppBrand.displayName) version."
        }
    }
    var releaseNotes: URL? {
        guard case .appUpdate(let version) = self else { return nil }
        return URL(string: "https://github.com/WorkingPrinciple/calimocho/releases/tag/engine-\(version)")
    }
}
