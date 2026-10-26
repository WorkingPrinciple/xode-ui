// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

private final class CalimochoInstallerFixtureState: @unchecked Sendable {
    struct Reply {
        let payload: Data
        let declaredLength: Int
        let chunkDelay: TimeInterval
        let chunkSize: Int
    }
    private let lock = NSLock()
    private var reply: Reply?
    private var requestCount = 0

    func reset(_ reply: Reply) {
        lock.lock()
        self.reply = reply
        requestCount = 0
        lock.unlock()
    }

    func take() -> Reply? {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        return reply
    }

    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }
}

private final class CalimochoInstallerURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = CalimochoInstallerFixtureState()
    private let stateLock = NSLock()
    private var stopped = false

    static func configure(_ data: Data, declaredLength: Int? = nil,
                          chunkSize: Int = 65_536, delay: TimeInterval = 0) {
        state.reset(.init(payload: data, declaredLength: declaredLength ?? data.count,
                          chunkDelay: delay, chunkSize: chunkSize))
    }

    static var requests: Int { state.requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.state.take(),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": String(reply.declaredLength)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let deliver: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < reply.payload.count {
                guard !isStopped else { return }
                let end = min(reply.payload.count, offset + max(1, reply.chunkSize))
                client?.urlProtocol(self, didLoad: reply.payload.subdata(in: offset..<end))
                offset = end
                if reply.chunkDelay > 0 { Thread.sleep(forTimeInterval: reply.chunkDelay) }
            }
            guard !isStopped else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.chunkDelay > 0 { DispatchQueue.global(qos: .utility).async(execute: deliver) }
        else { deliver() }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }
}

private final class InstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<URL, Error>?
    private var cancellationRequested = false

    func register(_ task: Task<URL, Error>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private actor InstallProgressCapture {
    private(set) var values: [CalimochoInstallProgress] = []
    func append(_ value: CalimochoInstallProgress) { values.append(value) }
}

@MainActor
enum CalimochoReleaseInstallerChecks {
    private struct FixtureEntry {
        let name: String
        let data: Data
        let mode: UInt32
    }

    static func run(check: (Bool, String) -> Void) async throws {
        guard let canonicalTemporary = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CalimochoInstallError.invalidArchive("The temporary test folder couldn't be resolved.")
        }
        let root = URL(fileURLWithPath: String(cString: canonicalTemporary), isDirectory: true)
            .appendingPathComponent("xode-calimocho-installer-\(UUID().uuidString)", isDirectory: true)
        free(canonicalTemporary)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "REQ115 removes only its temporary installer fixture") }
        }
        let engines = root.appendingPathComponent("Engines", isDirectory: true)
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: false)
        let stale = engines.appendingPathComponent(".calimocho-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("interrupted download".utf8).write(to: stale.appendingPathComponent("release.zip"))
        let preserved = engines.appendingPathComponent(".calimocho-install-not-an-owned-uuid")
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: false)
        let staleLink = engines.appendingPathComponent(".calimocho-install-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: staleLink, withDestinationURL: preserved)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let verifierParent = root.appendingPathComponent("verifier-fixture", isDirectory: true)
        let verifierEngine = verifierParent.appendingPathComponent(CalimochoReleasePin.release04.engineName,
                                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: verifierEngine, withIntermediateDirectories: true)
        let releaseVerifier = CalimochoReleaseInstallService(pin: .release04, root: engines, session: session,
                                                              availableSpace: { _ in Int64.max })
        do {
            try releaseVerifier.verifyEngine(.release04, verifierEngine)
            check(false, "REQ115: the release verifier resolves the extracted engine folder once")
        } catch let error as CalimochoReleaseError {
            if case .damaged = error {
                check(true, "REQ115: the release verifier resolves the extracted engine folder once")
            } else {
                check(false, "REQ115: the release verifier resolves the extracted engine folder once")
            }
        }

        let valid = fixture()
        CalimochoInstallerURLProtocol.configure(valid.archive)
        let successful = service(archive: valid, root: engines, session: session)
        let progress = InstallProgressCapture()
        let installResult: URL
        do { installResult = try await successful.install { await progress.append($0) } }
        catch {
            throw NSError(domain: "Calimocho installer fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Initial install failed: \(error.localizedDescription)"])
        }
        check(!FileManager.default.fileExists(atPath: stale.path)
              && FileManager.default.fileExists(atPath: preserved.path)
              && (try? FileManager.default.destinationOfSymbolicLink(atPath: staleLink.path)) == preserved.path,
              "REQ115: stale private UUID staging is reclaimed without following links or deleting unrelated folders")
        try FileManager.default.removeItem(at: staleLink)
        try FileManager.default.removeItem(at: preserved)
        let verified = FileManager.default.fileExists(atPath: installResult.appendingPathComponent("engine.bin").path)
        let byteProgress = await progress.values.compactMap { value -> Int64? in
            if case .downloading(let received, let total) = value, total == Int64(valid.archive.count) {
                return received
            }
            return nil
        }
        check(verified && CalimochoInstallerURLProtocol.requests == 1
              && !byteProgress.isEmpty && byteProgress == byteProgress.sorted()
              && byteProgress.last == Int64(valid.archive.count)
              && CalimochoReleaseEngines.installedNames(root: engines) == [valid.pin.engineName]
              && tryNoStaging(in: engines),
              "REQ115: the pinned archive downloads through the injected URL protocol, verifies, extracts and installs atomically")

        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        do {
            _ = try successful.removalTarget(isBusy: true)
            check(false, "REQ115: removing Calimocho is refused while a game or operation is running")
        } catch {
            check(error as? CalimochoInstallError == .engineBusy,
                  "REQ115: removing Calimocho is refused while a game or operation is running")
        }
        let removalTarget = try successful.removalTarget(isBusy: false)
        try FileManager.default.moveItem(at: removalTarget, to: trash.appendingPathComponent(removalTarget.lastPathComponent))
        CalimochoInstallerURLProtocol.configure(valid.archive)
        _ = try await successful.install { _ in }
        check(CalimochoReleaseEngines.installedNames(root: engines) == [valid.pin.engineName]
              && FileManager.default.fileExists(atPath: trash.appendingPathComponent(valid.pin.engineName).path),
              "REQ115: removing only the pinned engine to a test Trash allows a clean download and install again")

        let folder = successful.engineURL
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        CalimochoInstallerURLProtocol.configure(valid.archive)
        do {
            _ = try await successful.install { _ in }
            check(false, "REQ115: an existing engine folder is never overwritten")
        } catch {
            check(error as? CalimochoInstallError == .engineAlreadyExists
                  && CalimochoInstallerURLProtocol.requests == 0,
                  "REQ115: an existing engine folder is never overwritten")
        }
        try FileManager.default.removeItem(at: folder)

        let lowSpace = service(archive: valid, root: engines, session: session,
                              availableSpace: { _ in Int64(valid.archive.count + valid.expandedBytes) - 1 })
        CalimochoInstallerURLProtocol.configure(valid.archive)
        do {
            _ = try await lowSpace.install { _ in }
            check(false, "REQ115: insufficient space refuses before downloading")
        } catch {
            check(error as? CalimochoInstallError == .insufficientSpace(
                    required: Int64(valid.archive.count + valid.expandedBytes),
                    available: Int64(valid.archive.count + valid.expandedBytes) - 1)
                  && CalimochoInstallerURLProtocol.requests == 0,
                  "REQ115: insufficient space refuses before downloading")
        }

        let wrongHashPin = valid.pin.replacingArchiveHash(String(repeating: "0", count: 64))
        let wrongHash = CalimochoReleaseInstallService(pin: wrongHashPin, root: engines, session: session,
            availableSpace: { _ in Int64.max }, verifyEngine: { _, _ in })
        CalimochoInstallerURLProtocol.configure(valid.archive)
        do {
            _ = try await wrongHash.install { _ in }
            check(false, "REQ115: SHA-256 mismatch fails closed before extraction")
        } catch {
            check(error as? CalimochoInstallError == .archiveDigest && tryNoStaging(in: engines),
                  "REQ115: SHA-256 mismatch fails closed before extraction")
        }

        CalimochoInstallerURLProtocol.configure(valid.archive.dropLast(12), declaredLength: valid.archive.count)
        do {
            _ = try await successful.install { _ in }
            check(false, "REQ115: truncated responses fail the pinned byte-count check")
        } catch {
            check(error as? CalimochoInstallError == .archiveSize(expected: Int64(valid.archive.count),
                                                                  actual: Int64(valid.archive.count - 12))
                  && tryNoStaging(in: engines),
                  "REQ115: truncated responses fail the pinned byte-count check")
        }

        for (label, invalidArchive) in [
            ("wrong top-level folder", fixture(topLevel: "wrong")),
            ("path traversal entry", fixture(includeTraversal: true)),
            ("escaping symlink", fixture(includeEscapingSymlink: true))
        ] {
            CalimochoInstallerURLProtocol.configure(invalidArchive.archive)
            let invalidService = service(archive: invalidArchive, root: engines, session: session)
            do {
                _ = try await invalidService.install { _ in }
                check(false, "REQ115: \(label) is refused and staging is cleaned")
            } catch {
                check(error is CalimochoInstallError && tryNoStaging(in: engines)
                      && CalimochoReleaseEngines.installedNames(root: engines).isEmpty,
                      "REQ115: \(label) is refused and staging is cleaned")
            }
        }

        let cancellation = InstallCancellation()
        CalimochoInstallerURLProtocol.configure(valid.archive, chunkSize: 65_536, delay: 0.01)
        let cancelService = service(archive: valid, root: engines, session: session)
        let task = Task {
            try await cancelService.install { progress in
                if case .downloading(let received, _) = progress, received > 0 {
                    cancellation.cancel()
                }
            }
        }
        cancellation.register(task)
        do {
            _ = try await task.value
            check(false, "REQ115: cancel interrupts the download and removes staging")
        } catch {
            check(task.isCancelled && tryNoStaging(in: engines)
                  && CalimochoReleaseEngines.installedNames(root: engines).isEmpty,
                  "REQ115: cancel interrupts the download and removes staging")
        }

        let chainRoot = root.appendingPathComponent("chain")
        let chainEngine = chainRoot.appendingPathComponent(valid.pin.engineName)
        try FileManager.default.createDirectory(at: chainEngine.appendingPathComponent("a/b"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: chainEngine.appendingPathComponent("a/b/L").path,
                                                   withDestinationPath: "..")
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(atPath: chainEngine.appendingPathComponent("M").path,
                                                   withDestinationPath: "a/b/L/../../../outside")
        do {
            try CalimochoReleaseInstallService.verifyExtractedEntries([
                .init(path: "\(valid.pin.engineName)/M", kind: .symlink, uncompressedSize: 0)
            ], under: chainRoot, engineName: valid.pin.engineName)
            check(false, "REQ115: a symlink chain cannot escape by changing how dot-dot resolves")
        } catch {
            check(error is CalimochoInstallError,
                  "REQ115: a symlink chain cannot escape by changing how dot-dot resolves")
        }

        let extractionStarted = InstallProgressCapture()
        let shutdownService = CalimochoReleaseInstallService(pin: valid.pin, root: engines, session: session,
            availableSpace: { _ in Int64.max },
            extractArchive: { _, _ in
                await extractionStarted.append(.extracting)
                try await Task.sleep(for: .seconds(30))
            }, verifyEngine: { _, _ in })
        CalimochoInstallerURLProtocol.configure(valid.archive)
        let controller = CalimochoReleaseInstallController(service: shutdownService)
        controller.install { false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await extractionStarted.values.isEmpty {
            guard ContinuousClock.now < deadline else { throw CalimochoInstallError.extraction }
            try await Task.sleep(for: .milliseconds(5))
        }
        let closed = await ApplicationTerminationCoordinator().shutdown(
            session: nil, runtime: nil, calimochoInstaller: controller)
        check(closed && !controller.isWorking && tryNoStaging(in: engines),
              "REQ115: normal quit cancels extraction and waits for staging cleanup")

        let archiveURL = root.appendingPathComponent("ditto.zip")
        try valid.archive.write(to: archiveURL)
        let extractionURL = root.appendingPathComponent("ditto-output")
        let cancelDitto = InstallCancellation()
        let dittoTask = Task {
            try await CalimochoReleaseInstallService.dittoExtract(archiveURL, extractionURL,
                                                                  didStart: { _ in cancelDitto.cancel() })
            return extractionURL
        }
        cancelDitto.register(dittoTask)
        do {
            _ = try await dittoTask.value
            check(false, "REQ115: cancellation terminates and reaps the actual ditto process")
        } catch {
            check(error is CancellationError && dittoTask.isCancelled,
                  "REQ115: cancellation terminates and reaps the actual ditto process")
        }

        let installed = InstalledGamesController()
        var releaseFirst: CheckedContinuation<Void, Never>?
        var inspectionOrder: [Int] = []
        let firstInspection = Task {
            await installed.withEngineOverrideCheck {
                inspectionOrder.append(1)
                await withCheckedContinuation { releaseFirst = $0 }
                inspectionOrder.append(2)
            }
        }
        while releaseFirst == nil { await Task.yield() }
        let forcedInspection = Task {
            await installed.withEngineOverrideCheck { inspectionOrder.append(3) }
        }
        await Task.yield()
        check(installed.checkingEngineOverrides && inspectionOrder == [1],
              "REQ115: post-install admission waits for an in-flight engine inspection")
        releaseFirst?.resume()
        await firstInspection.value
        await forcedInspection.value
        check(inspectionOrder == [1, 2, 3] && !installed.checkingEngineOverrides,
              "REQ115: queued admission runs a fresh inspection rather than skipping it")
    }

    private struct ArchiveFixture: Sendable {
        let archive: Data
        let pin: CalimochoReleasePin
        let expandedBytes: Int
    }

    private static func fixture(topLevel: String = CalimochoReleasePin.release04.engineName,
                                includeTraversal: Bool = false,
                                includeEscapingSymlink: Bool = false) -> ArchiveFixture {
        let files: [(String, Data, UInt32)] = [
            ("\(topLevel)/", Data(), 0x41ed),
            ("\(topLevel)/bin/", Data(), 0x41ed),
            ("\(topLevel)/bin/wine", Data("wine".utf8), 0x81ed),
            ("\(topLevel)/bin/wineserver", Data("server".utf8), 0x81ed),
            ("\(topLevel)/engine.bin", Data("verified engine payload".utf8), 0x81a4)
        ]
        var entries = files.map { FixtureEntry(name: $0.0, data: $0.1, mode: $0.2) }
        if includeTraversal {
            entries.append(FixtureEntry(name: "\(topLevel)/../escape", data: Data("x".utf8), mode: 0x81a4))
        }
        if includeEscapingSymlink {
            entries.append(FixtureEntry(name: "\(topLevel)/escape", data: Data("../../outside".utf8), mode: 0xa1ff))
        }
        let archive = zip(entries)
        let expanded = entries.reduce(0) { $0 + $1.data.count }
        let hash = CalimochoReleaseEngines.digest(archive)
        let pin = CalimochoReleasePin(engineName: CalimochoReleasePin.release04.engineName,
            wineSha256: CalimochoReleasePin.release04.wineSha256,
            wineserverSha256: CalimochoReleasePin.release04.wineserverSha256,
            engineJSONSha256: CalimochoReleasePin.release04.engineJSONSha256,
            manifestSha256: CalimochoReleasePin.release04.manifestSha256,
            teamID: CalimochoReleasePin.release04.teamID, renderer: CalimochoReleasePin.release04.renderer,
            downloadURL: URL(string: "https://github.com/WorkingPrinciple/calimocho/releases/download/test/release.zip"),
            archiveSha256: hash, archiveByteCount: Int64(archive.count),
            expandedByteCount: Int64(max(1, expanded)), attestation: "fixture")
        return ArchiveFixture(archive: archive, pin: pin, expandedBytes: expanded)
    }

    private static func service(archive: ArchiveFixture, root: URL, session: URLSession,
                                availableSpace: (@Sendable (URL) throws -> Int64?)? = nil) -> CalimochoReleaseInstallService {
        CalimochoReleaseInstallService(pin: archive.pin, root: root, session: session,
            availableSpace: availableSpace ?? { _ in Int64(archive.archive.count + archive.expandedBytes) },
            verifyEngine: { _, engine in
                guard FileManager.default.fileExists(atPath: engine.appendingPathComponent("engine.bin").path) else {
                    throw CalimochoInstallError.invalidArchive("fixture verifier couldn't find engine.bin.")
                }
            })
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalimochoInstallerURLProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func tryNoStaging(in root: URL) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return false }
        return children.allSatisfy {
            !$0.hasPrefix(".calimocho-install-")
                || UUID(uuidString: String($0.dropFirst(".calimocho-install-".count))) == nil
        }
    }

    private static func zip(_ entries: [FixtureEntry]) -> Data {
        var output = Data()
        var central = Data()
        var offsets: [Int] = []
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            offsets.append(output.count)
            output.append32(0x04034b50)
            output.append16(20)
            output.append16(0x0800)
            output.append16(0)
            output.append16(0)
            output.append16(0)
            output.append32(crc)
            output.append32(UInt32(entry.data.count))
            output.append32(UInt32(entry.data.count))
            output.append16(UInt16(name.count))
            output.append16(0)
            output.append(name)
            output.append(entry.data)
        }
        let centralOffset = output.count
        for (index, entry) in entries.enumerated() {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            central.append32(0x02014b50)
            central.append16(UInt16((3 << 8) | 20))
            central.append16(20)
            central.append16(0x0800)
            central.append16(0)
            central.append16(0)
            central.append16(0)
            central.append32(crc)
            central.append32(UInt32(entry.data.count))
            central.append32(UInt32(entry.data.count))
            central.append16(UInt16(name.count))
            central.append16(0)
            central.append16(0)
            central.append16(0)
            central.append16(0)
            central.append32(entry.mode << 16)
            central.append32(UInt32(offsets[index]))
            central.append(name)
        }
        output.append(central)
        output.append32(0x06054b50)
        output.append16(0)
        output.append16(0)
        output.append16(UInt16(entries.count))
        output.append16(UInt16(entries.count))
        output.append32(UInt32(central.count))
        output.append32(UInt32(centralOffset))
        output.append16(0)
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1
            }
        }
        return value ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func append32(_ value: UInt32) {
        append16(UInt16(truncatingIfNeeded: value))
        append16(UInt16(truncatingIfNeeded: value >> 16))
    }
}

private extension CalimochoReleasePin {
    func replacingArchiveHash(_ value: String) -> Self {
        Self(engineName: engineName, wineSha256: wineSha256, wineserverSha256: wineserverSha256,
             engineJSONSha256: engineJSONSha256, manifestSha256: manifestSha256, teamID: teamID,
             renderer: renderer, downloadURL: downloadURL, archiveSha256: value,
             archiveByteCount: archiveByteCount, expandedByteCount: expandedByteCount,
             attestation: attestation)
    }
}
