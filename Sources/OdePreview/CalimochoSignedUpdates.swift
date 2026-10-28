// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

enum CalimochoSignedUpdates {
    static var enabled: Bool {
        #if ODE_SIGNED_ENGINE_INDEX_QUALIFICATION
        true
        #else
        false
        #endif
    }

    static let indexURL = URL(string:
        "https://github.com/WorkingPrinciple/calimocho/releases/download/engine-index/calimocho-engine-index.json")!

    static func permitsRedirect(_ url: URL?, hop: Int) -> Bool {
        (1...5).contains(hop) && url?.scheme == "https"
    }

    // Public anchors from reviewed Calimocho fc996c3b; no RFC test key is trusted.
    static let trust = Data("""
    {"schema":"calimocho-engine-index-trust/1","keys":[{
    "keyid":"b2906316227f06803851b23824ed2ff3a93fd590c0c497752387713fff70dcee",
    "public_key":"5ZrgTETTbLPowbB7xfPzaXTd34x6yHVSjU6jy0BbeTA=",
    "epoch":1,"status":"active","created":"2026-10-26"}],
    "revoked_keyids":[],"floor":{"epoch":1,"index_version":1},"revoked_engines":[]}
    """.utf8)

    static func client() -> CalimochoSignedUpdateClient? {
        guard enabled else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ode to X/State/EngineUpdates", isDirectory: true)
        return CalimochoSignedUpdateClient(stateURL: root.appendingPathComponent("index-state-v1.json"))
    }

    static func fetch(configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        let delegate = CalimochoIndexRedirects()
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: indexURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("X-Ode-Calimocho-Signed-Update-Check", forHTTPHeaderField: "User-Agent")
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw CalimochoUpdateError.invalidResponse
            }
            if response.statusCode == 403 || response.statusCode == 429 {
                throw CalimochoUpdateError.rateLimited
            }
            guard response.statusCode == 200, response.url?.scheme == "https",
                  response.expectedContentLength <= 1_572_864 else {
                throw CalimochoUpdateError.invalidResponse
            }
            var bytes = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard bytes.count < 1_572_864 else { throw CalimochoIndexError.invalid("envelope size") }
                bytes.append(byte)
            }
            try Task.checkCancellation()
            return bytes
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost,
            .cannotFindHost, .cannotConnectToHost, .timedOut].contains(error.code) {
            throw CalimochoUpdateError.offline
        }
    }
}

private final class CalimochoIndexRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let allowed = CalimochoSignedUpdates.permitsRedirect(request.url, hop: redirects)
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }
}

actor CalimochoSignedUpdateClient {
    let stateURL: URL
    private let trust: Data
    private let fetch: @Sendable () async throws -> Data
    private var checking = false

    init(stateURL: URL, trust: Data = CalimochoSignedUpdates.trust,
         fetch: @escaping @Sendable () async throws -> Data = { try await CalimochoSignedUpdates.fetch() }) {
        self.stateURL = stateURL
        self.trust = trust
        self.fetch = fetch
    }

    struct Result: Sendable {
        /// Engines this app version may accept.
        let eligible: [CalimochoIndexVerifier.Engine]
        /// Newer unrevoked engines, including those that need a newer app (release information only).
        let announced: [CalimochoIndexVerifier.Engine]
    }

    func check(appVersion: String, installedVersion: String?, now: Date) async throws -> Result {
        guard !checking else { throw CalimochoUpdateError.busy }
        checking = true
        defer { checking = false }
        let parent = try prepareDirectory()
        let lockURL = parent.appendingPathComponent(".index-state.lock")
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else { throw GameScriptError.storage }
        defer { close(lockFD) }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw GameScriptError.storage
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw CalimochoUpdateError.busy }
            throw GameScriptError.storage
        }
        let prior = try readState()
        let envelope = try await fetch()
        try Task.checkCancellation()
        let accepted = try CalimochoIndexVerifier.verify(envelope: envelope, trust: trust, state: prior, now: now)
        let eligible = try accepted.eligible(appVersion: appVersion, installedVersion: installedVersion)
        let announced = try accepted.announced(installedVersion: installedVersion)
        try Task.checkCancellation()
        try persist(accepted.state)
        return Result(eligible: eligible, announced: announced)
    }

    private func readState() throws -> Data? {
        try GameScriptFiles.checkPath(stateURL, allowMissing: true)
        var info = stat()
        guard lstat(stateURL.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw GameScriptError.storage
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw GameScriptError.storage }
        return try InstalledGameFiles.readRegular(stateURL, maximumBytes: 8_388_608)
    }

    private func persist(_ state: CalimochoIndexVerifier.State) throws {
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= 8_388_608 else { throw CalimochoIndexError.invalid("state size") }
        let parent = try prepareDirectory()
        let temporary = parent.appendingPathComponent(".index-state-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GameScriptError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: bytes)
            guard fsync(fd) == 0 else { throw GameScriptError.storage }
            try handle.close()
            guard rename(temporary.path, stateURL.path) == 0 else { throw GameScriptError.storage }
        } catch {
            handle.closeFile()
            if unlink(temporary.path) != 0 && errno != ENOENT { throw GameScriptError.storage }
            throw error
        }
    }

    private func prepareDirectory() throws -> URL {
        let parent = stateURL.deletingLastPathComponent()
        try GameScriptFiles.checkPath(parent, allowMissing: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try GameScriptFiles.checkPath(parent)
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw GameScriptError.storage }
        return parent
    }
}
