// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import XodusCore
import XodusManagement
import AppKit
import SwiftUI

private final class CalimochoInstallerFixtureState: @unchecked Sendable {
    struct Reply {
        let payload: Data
        let declaredLength: Int
        let chunkDelay: TimeInterval
        let chunkSize: Int
        let status: Int
        let error: URLError?
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
                          chunkSize: Int = 65_536, delay: TimeInterval = 0,
                          status: Int = 200, error: URLError? = nil) {
        state.reset(.init(payload: data, declaredLength: declaredLength ?? data.count,
                          chunkDelay: delay, chunkSize: chunkSize, status: status, error: error))
    }

    static var requests: Int { state.requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.state.take(),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": String(reply.declaredLength)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
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
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-660)],
                                               ofItemAtPath: stale.path)
        let youngStage = engines.appendingPathComponent(".calimocho-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: youngStage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let preserved = engines.appendingPathComponent(".calimocho-install-not-an-owned-uuid")
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: false)
        let staleLink = engines.appendingPathComponent(".calimocho-install-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: staleLink, withDestinationURL: preserved)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let verifierParent = root.appendingPathComponent("verifier-fixture", isDirectory: true)
        let verifierEngine = verifierParent.appendingPathComponent(CalimochoReleasePin.release06.engineName,
                                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: verifierEngine, withIntermediateDirectories: true)
        let releaseVerifier = CalimochoReleaseInstallService(pin: .release06, root: engines, session: session,
                                                              availableSpace: { _ in Int64.max })
        do {
            try releaseVerifier.verifyEngine(.release06, verifierEngine)
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
              && FileManager.default.fileExists(atPath: youngStage.path)
              && (try? FileManager.default.destinationOfSymbolicLink(atPath: staleLink.path)) == preserved.path,
              "REQ115: old private UUID staging is reclaimed, preserving young stages, links and unrelated folders")
        try FileManager.default.removeItem(at: youngStage)
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

        let heldLock = open(engines.appendingPathComponent(".calimocho-install.lock").path, O_RDWR | O_CLOEXEC)
        guard heldLock >= 0, flock(heldLock, LOCK_EX | LOCK_NB) == 0 else { throw GameScriptError.storage }
        do {
            _ = try await successful.install { _ in }
            check(false, "REQ115: a held install lock reports another install in progress")
        } catch {
            check(error as? CalimochoInstallError == .installInProgress,
                  "REQ115: a held install lock reports another install in progress")
        }
        close(heldLock)

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
        let readyMarker = root.appendingPathComponent("stubborn-extractor-ready")
        let stubbornTask = Task {
            try await CalimochoReleaseInstallService.runExtractionProcess(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; /usr/bin/touch '\(readyMarker.path)'; exec /bin/sleep 30"],
                didStart: { _ in })
        }
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: readyMarker.path) {
            guard ContinuousClock.now < readyDeadline else {
                stubbornTask.cancel()
                _ = try? await stubbornTask.value
                throw CalimochoInstallError.extraction
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let canceledAt = ContinuousClock.now
        stubbornTask.cancel()
        do {
            try await stubbornTask.value
            check(false, "REQ115: SIGTERM-ignoring extraction is killed and reaped within the shutdown budget")
        } catch {
            check(error is CancellationError && canceledAt.duration(to: .now) < .seconds(5),
                  "REQ115: SIGTERM-ignoring extraction is killed and reaped within the shutdown budget")
        }
        let linked = fixture(includeInternalSymlink: true)
        let canonicalLinksRoot = root.appendingPathComponent("SymlinkEngines")
        try FileManager.default.createDirectory(at: canonicalLinksRoot, withIntermediateDirectories: false)
        let caseVariant = root.appendingPathComponent("sYMLINKeNGINES")
        let linksRoot = FileManager.default.fileExists(atPath: caseVariant.path) ? caseVariant : canonicalLinksRoot
        CalimochoInstallerURLProtocol.configure(linked.archive)
        let linkedEngine = try await service(archive: linked, root: linksRoot, session: session).install { _ in }
        check((try FileManager.default.destinationOfSymbolicLink(atPath:
                    linkedEngine.appendingPathComponent("bin/wine-link").path)) == "wine",
              "REQ115: a real ditto install accepts valid internal links, including a case-variant root where supported")

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
        @MainActor final class ExtractorLiveness { var alive = true }
        let extractor = ExtractorLiveness()
        let stuckService = CalimochoReleaseInstallService(pin: valid.pin, root: engines, session: session,
            availableSpace: { _ in Int64.max }, extractArchive: { _, _ in
                throw CalimochoInstallError.extractionShutdownFailed
            }, verifyEngine: { _, _ in })
        let stuck = CalimochoReleaseInstallController(service: stuckService, extractionStillRunning: { extractor.alive })
        CalimochoInstallerURLProtocol.configure(valid.archive)
        stuck.install { false }
        try await finish(stuck)
        check(!(await stuck.shutdownForApplicationTermination()),
              "REQ123: quit refuses while the failed extractor is still alive")
        stuck.resumeAfterTerminationRefusal()
        extractor.alive = false
        check(await stuck.shutdownForApplicationTermination(),
              "REQ123: a later quit succeeds once the failed extractor exits")
        try await updateChecks(root: root.appendingPathComponent("updates"), session: session, check: check)
    }

    private struct ArchiveFixture: Sendable {
        let archive: Data
        let pin: CalimochoReleasePin
        let expandedBytes: Int
    }

    private static func fixture(topLevel: String = CalimochoReleasePin.release06.engineName,
                                includeTraversal: Bool = false,
                                includeEscapingSymlink: Bool = false,
                                includeInternalSymlink: Bool = false) -> ArchiveFixture {
        let files: [(String, Data, UInt32)] = [
            ("\(topLevel)/", Data(), 0x41ed),
            ("\(topLevel)/bin/", Data(), 0x41ed),
            ("\(topLevel)/bin/wine", Data("wine".utf8), 0x81ed),
            ("\(topLevel)/bin/wineserver", Data("server".utf8), 0x81ed),
            ("\(topLevel)/calimocho-engine.json", descriptor(name: topLevel, version: "0.1120.4.6"), 0x81a4),
            ("\(topLevel)/engine.bin", Data("verified engine payload".utf8), 0x81a4)
        ]
        var entries = files.map { FixtureEntry(name: $0.0, data: $0.1, mode: $0.2) }
        if includeTraversal {
            entries.append(FixtureEntry(name: "\(topLevel)/../escape", data: Data("x".utf8), mode: 0x81a4))
        }
        if includeEscapingSymlink {
            entries.append(FixtureEntry(name: "\(topLevel)/escape", data: Data("../../outside".utf8), mode: 0xa1ff))
        }
        if includeInternalSymlink {
            entries.append(FixtureEntry(name: "\(topLevel)/bin/wine-link", data: Data("wine".utf8), mode: 0xa1ff))
        }
        let archive = zip(entries)
        let expanded = entries.reduce(0) { $0 + $1.data.count }
        let hash = CalimochoReleaseEngines.digest(archive)
        let pin = CalimochoReleasePin(engineName: CalimochoReleasePin.release06.engineName,
            wineSha256: CalimochoReleasePin.release06.wineSha256,
            wineserverSha256: CalimochoReleasePin.release06.wineserverSha256,
            engineJSONSha256: CalimochoReleasePin.release06.engineJSONSha256,
            manifestSha256: CalimochoReleasePin.release06.manifestSha256,
            teamID: CalimochoReleasePin.release06.teamID, renderer: CalimochoReleasePin.release06.renderer,
            downloadURL: CalimochoReleasePin.release06.downloadURL,
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

    private static func descriptor(name: String, version: String) -> Data {
        Data("""
        {"schema":"calimocho-engine/1","engine_id":"\(name)","version":"\(version)",
         "provider":{"id":"calimocho","contract_version":1},
         "paths":{"wine":"bin/wine","wineserver":"bin/wineserver"},
         "environment":{},"signing":{"team_id":"M62Z4M5EUY"}}
        """.utf8)
    }

    private static func updateChecks(root: URL, session: URLSession,
                                      check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let old = LocalCalimochoRelease(engineName: CalimochoReleasePin.release04.engineName,
                                        version: CalimochoReleasePin.release04.releaseVersion!)
        let oldFolder = root.appendingPathComponent(old.engineName)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: false)
        try descriptor(name: old.engineName, version: old.version.description)
            .write(to: oldFolder.appendingPathComponent("calimocho-engine.json"))
        let suite = "REQ123-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = fixture()
        let titleFolder = root.appendingPathComponent("calimocho-11.20-4.0b3-01-fh6")
        try FileManager.default.createDirectory(at: titleFolder, withIntermediateDirectories: false)
        try descriptor(name: titleFolder.lastPathComponent, version: "0.1120.4.1-fh6")
            .write(to: titleFolder.appendingPathComponent("calimocho-engine.json"))
        check(try LocalCalimochoRelease.installed(root: root) == [old],
              "REQ123: a title-specific -01-fh6 folder cannot break release discovery")
        let mismatchedFolder = root.appendingPathComponent("calimocho-11.20-4.0b3-02")
        try FileManager.default.createDirectory(at: mismatchedFolder, withIntermediateDirectories: false)
        try descriptor(name: mismatchedFolder.lastPathComponent, version: "0.1120.4.3")
            .write(to: mismatchedFolder.appendingPathComponent("calimocho-engine.json"))
        check(try LocalCalimochoRelease.installed(root: root) == [old],
              "REQ123: a release folder with a mismatched descriptor version cannot break update discovery")
        check(AcknowledgmentsInventory.installedReleaseEngine(root: root)?.lastPathComponent == old.engineName,
              "REQ123: Acknowledgments falls back to the older compiled pin, never the FH6 folder")
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        CalimochoInstallerURLProtocol.configure(Data())
        let controller = CalimochoReleaseInstallController(
            service: service(archive: valid, root: root, session: session),
            releaseCheck: CalimochoReleaseCheck(session: session), updateDefaults: defaults, now: { date })
        check(CalimochoInstallerURLProtocol.requests == 0,
              "REQ123: constructing the shared installer at app launch makes no update request")
        let pinned = CalimochoVersion("0.1120.4.6")!
        check(CalimochoUpdateOutcome.decide(installed: [.init(engineName: "current", version: pinned)],
                    pinned: pinned, latest: pinned) == .upToDate,
              "REQ123: an installed current pin reports up to date")
        check(CalimochoUpdateOutcome.decide(installed: [old], pinned: pinned, latest: pinned) == .pinnedUpdate(old),
              "REQ123: retained -04 offers the compiled -06 update alongside, not an unpinned release")
        let future = CalimochoVersion("0.1120.4.10")!
        let unsupported = CalimochoUpdateOutcome.decide(installed: [.init(engineName: "current", version: pinned)],
                                                       pinned: pinned, latest: future)
        check(unsupported == .appUpdate(future) && unsupported.releaseNotes?.lastPathComponent == "engine-0.1120.4.10",
              "REQ123: unpinned newer releases offer app-update guidance and release notes, not installation")
        let api = Data("""
        [{"tag_name":"unrelated","draft":false},{"tag_name":"engine-0.1120.4.3","draft":false},
         {"tag_name":"engine-0.1120.4.10","draft":false,"prerelease":true},
         {"tag_name":"engine-0.1120.4.99","draft":true}]
        """.utf8)
        CalimochoInstallerURLProtocol.configure(api)
        check(try await CalimochoReleaseCheck(session: session).latest() == future,
              "REQ123: public release checks include prereleases and compare revisions numerically")
        CalimochoInstallerURLProtocol.configure(api)
        await controller.checkForUpdates(automatic: true)
        await controller.checkForUpdates(automatic: true)
        check(CalimochoInstallerURLProtocol.requests == 1 && controller.updateOutcome == .pinnedUpdate(old),
              "REQ123: pane-open checks run at most once per day")
        let reopened = CalimochoReleaseInstallController(
            service: service(archive: valid, root: root, session: session),
            releaseCheck: CalimochoReleaseCheck(session: session), updateDefaults: defaults, now: { date })
        await reopened.checkForUpdates(automatic: true)
        check(CalimochoInstallerURLProtocol.requests == 1 && reopened.updateOutcome == .pinnedUpdate(old),
              "REQ123: daily scheduling and the checked version survive controller recreation")
        try renderUpdateControls(controller, name: "pinned-update", check: check)
        date = date.addingTimeInterval(86_400)
        await controller.checkForUpdates(automatic: true)
        check(CalimochoInstallerURLProtocol.requests == 2,
              "REQ123: opening the pane on the next day permits another check")
        defaults.set(date.addingTimeInterval(86_400), forKey: CalimochoReleaseInstallController.lastUpdateCheckKey)
        await controller.checkForUpdates(automatic: true)
        check(CalimochoInstallerURLProtocol.requests == 3,
              "REQ123: a future-dated timestamp is stale and cannot suppress an automatic check")
        CalimochoInstallerURLProtocol.configure(Data(), error: URLError(.notConnectedToInternet))
        await controller.checkForUpdates(automatic: false)
        check(controller.updateMessage == CalimochoUpdateError.offline.localizedDescription,
              "REQ123: offline checks give a specific calm message")
        CalimochoInstallerURLProtocol.configure(Data(), status: 403)
        await controller.checkForUpdates(automatic: false)
        check(controller.updateMessage == CalimochoUpdateError.rateLimited.localizedDescription,
              "REQ123: unauthenticated 403 rate limits give a specific calm message")

        var oldDefault = old.engineName
        var reserved = false
        CalimochoInstallerURLProtocol.configure(valid.archive)
        controller.update(from: old, isBusy: { true }, reserve: { reserved = true },
                          release: { reserved = false }, admit: { true }, activate: { oldDefault = valid.pin.engineName })
        check(!controller.isWorking && !reserved && CalimochoInstallerURLProtocol.requests == 0,
              "REQ123: a running game or operation refuses the update before reservation or download")
        controller.update(from: old, isBusy: { false }, reserve: { reserved = true },
                          release: { reserved = false }, admit: { false }, activate: { oldDefault = valid.pin.engineName })
        try await finish(controller)
        check(oldDefault == old.engineName && !reserved && !controller.hasEngineFolder
              && FileManager.default.fileExists(atPath: oldFolder.path) && tryNoStaging(in: root)
              && controller.errorMessage == CalimochoUpdateError.admission.localizedDescription,
              "REQ123: admission failure removes the new release and preserves the old engine and default")

        CalimochoInstallerURLProtocol.configure(valid.archive, chunkSize: 64, delay: 0.01)
        controller.update(from: old, isBusy: { false }, reserve: { reserved = true },
                          release: { reserved = false }, admit: { true }, activate: { oldDefault = valid.pin.engineName })
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while CalimochoInstallerURLProtocol.requests == 0 {
            guard ContinuousClock.now < deadline else { throw CalimochoInstallError.extraction }
            try await Task.sleep(for: .milliseconds(5))
        }
        controller.cancel()
        try await finish(controller)
        check(oldDefault == old.engineName && !reserved && !controller.hasEngineFolder && tryNoStaging(in: root),
              "REQ123: cancel mid-update preserves the old engine/default and removes staging")

        let oldInspection = EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1",
            registrySha256: String(repeating: "b", count: 64), engineName: old.engineName,
            declaredProvider: "calimocho", admittedProvider: "calimocho", admission: "admitted",
            ready: true, qualified: false, wineSha256: CalimochoReleasePin.release04.wineSha256,
            wineserverSha256: CalimochoReleasePin.release04.wineserverSha256, error: nil)
        let oldSelection = AdmittedEngineSelection(registryPath: root.appendingPathComponent("old-registry.json").path,
                                                   inspection: oldInspection)
        defaults.set(try JSONEncoder().encode(oldSelection), forKey: NativeEngineDefaults.preferenceKey)
        EngineDefaults.setDefaultEngine(.calimocho, defaults)
        CalimochoInstallerURLProtocol.configure(valid.archive)
        _ = try await service(archive: valid, root: root, session: session).install { _ in }
        let recovery = CalimochoReleaseInstallController(
            service: service(archive: valid, root: root, session: session),
            releaseCheck: CalimochoReleaseCheck(session: session), updateDefaults: defaults, now: { date })
        await recovery.checkForUpdates(automatic: true)
        check(recovery.updateOutcome == .finishUpdate(old),
              "REQ123: pane-open detects an installed pinned release whose default still points to the old engine")
        CalimochoInstallerURLProtocol.configure(Data())
        var refusedUpdateActivated = false
        recovery.update(from: old, isBusy: { false }, reserve: {}, release: {}, admit: { false }, activate: {
            refusedUpdateActivated = true
        })
        try await finish(recovery)
        check(recovery.hasEngineFolder && recovery.updateOutcome == .finishUpdate(old)
              && defaults.data(forKey: CalimochoReleaseInstallController.pendingUpdateKey) != nil
              && CalimochoInstallerURLProtocol.requests == 0 && !refusedUpdateActivated,
              "REQ123: refused Finish Update preserves the existing folder and recovery offer without downloading")
        recovery.update(from: old, isBusy: { false }, reserve: {}, release: {}, admit: { true }, activate: {
            defaults.removeObject(forKey: NativeEngineDefaults.preferenceKey)
        })
        try await finish(recovery)
        check(CalimochoInstallerURLProtocol.requests == 0 && recovery.removableOldRelease == old,
              "REQ123: Finish Update admits and activates the existing folder without downloading it again")
        let relaunched = CalimochoReleaseInstallController(
            service: service(archive: valid, root: root, session: session),
            releaseCheck: CalimochoReleaseCheck(session: session), updateDefaults: defaults, now: { date })
        await relaunched.checkForUpdates(automatic: true)
        check(relaunched.removableOldRelease == old,
              "REQ123: the old-engine Trash offer survives controller recreation")
        try FileManager.default.removeItem(at: controller.engineURL)
        defaults.removeObject(forKey: CalimochoReleaseInstallController.pendingRemovalKey)

        CalimochoInstallerURLProtocol.configure(valid.archive)
        var sawOldBeforeAdmission = false
        controller.update(from: old, isBusy: { false }, reserve: { reserved = true },
                          release: { reserved = false }, admit: {
                              sawOldBeforeAdmission = oldDefault == old.engineName && controller.hasEngineFolder
                              return true
                          }, activate: { oldDefault = valid.pin.engineName })
        try await finish(controller)
        check(sawOldBeforeAdmission && oldDefault == valid.pin.engineName && controller.hasEngineFolder
              && FileManager.default.fileExists(atPath: oldFolder.path) && controller.removableOldRelease == old,
              "REQ123: pinned update installs alongside, waits for admission, then activates and offers old-engine removal")
        try renderUpdateControls(controller, name: "newer-unpinned", check: check)
        CalimochoInstallerURLProtocol.configure(Data("""
        [{"tag_name":"engine-0.1120.4.6","draft":false,"prerelease":true}]
        """.utf8))
        await controller.checkForUpdates(automatic: false)
        check(controller.updateOutcome == .upToDate,
              "REQ123: the real check reports up to date when installed, pinned and latest versions agree")
        let fakeTrash = root.appendingPathComponent("test-trash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: false)
        controller.removeOld(isBusy: { false }, reserve: { reserved = true }, release: { reserved = false },
                             recycle: { target in
                                 try FileManager.default.moveItem(at: target, to: fakeTrash.appendingPathComponent(target.lastPathComponent))
                             })
        try await finish(controller)
        check(!reserved && !FileManager.default.fileExists(atPath: oldFolder.path)
              && controller.hasEngineFolder && controller.removableOldRelease == nil,
              "REQ123: confirmed old-engine removal targets only the retained version using a temporary Trash")

        let gameStore = InstalledGameStore(file: root.appendingPathComponent("games/installed.json"))
        try await gameStore.save([])
        let library = InstalledGamesController(store: gameStore, detectAvailability: { RunnerAvailability([]) },
                                               mountedStorageRoots: { [] })
        await library.load()
        let games = ["9P9VNSQK1W3K", "9NMNMS626R59", "9P7XZ2FW2B39"].map { product in
            InstalledGame(id: UUID(), title: product, identityName: product, version: "1.0.0.0",
                          storeId: product, folder: root.appendingPathComponent(product).path,
                          launcher: "", importedAt: date, engineOverride: .calimocho,
                          engineSelection: oldSelection, engineOverrideV2: GameEngineOverride(selection: oldSelection),
                          usesNativeLifecycle: true)
        }
        try await gameStore.save(games)
        let activePin = CalimochoReleasePin.release06
        let inspection = EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1",
            registrySha256: String(repeating: "a", count: 64), engineName: activePin.engineName,
            declaredProvider: "calimocho", admittedProvider: "calimocho", admission: "admitted",
            ready: true, qualified: false, wineSha256: activePin.wineSha256,
            wineserverSha256: activePin.wineserverSha256, error: nil)
        let selection = AdmittedEngineSelection(registryPath: root.appendingPathComponent("registry.json").path,
                                                 inspection: inspection)
        try prefixContinuityCheck(root: root.appendingPathComponent("bundled-default"), selection: selection,
                                  label: "bundled -04 to -06 default switch", check: check)
        defaults.set(try JSONEncoder().encode(oldSelection), forKey: NativeEngineDefaults.preferenceKey)
        try library.reserveMutation(gameID: nil)
        try await library.activateCalimochoUpdate(selection, replacing: old.engineName, defaults: defaults)
        library.releaseMutation()
        let savedGames = try await gameStore.load()
        let savedDefault = try JSONDecoder().decode(AdmittedEngineSelection.self,
                            from: defaults.data(forKey: NativeEngineDefaults.preferenceKey)!)
        check(savedDefault == selection && savedGames.prefix(2).allSatisfy { $0.engineOverrideV2?.selection == selection }
              && savedGames.last?.engineOverrideV2?.selection == oldSelection,
              "REQ123: admitted activation switches the default and only Brotato/Halls stored profiles")
        try prefixContinuityCheck(root: root.appendingPathComponent("update-activation"), selection: savedDefault,
                                  label: "REQ123 update activation", check: check)
        try await reinstallPrefixCheck(root: root.appendingPathComponent("reinstall-prefix"), selection: savedDefault,
                                       check: check)
        var customGames = games
        customGames[0].engineOverride = .crossover
        let customInspection = EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1",
            registrySha256: String(repeating: "e", count: 64), engineName: "custom-calimocho",
            declaredProvider: "calimocho", admittedProvider: "calimocho", admission: "admitted",
            ready: true, qualified: false, wineSha256: String(repeating: "f", count: 64),
            wineserverSha256: String(repeating: "a", count: 64), error: nil)
        let customSelection = AdmittedEngineSelection(registryPath: root.appendingPathComponent("custom.json").path,
                                                      inspection: customInspection)
        customGames[1].engineSelection = customSelection
        customGames[1].engineOverrideV2 = GameEngineOverride(selection: customSelection)
        try await gameStore.save(customGames)
        let previousDefault = try JSONEncoder().encode(oldSelection)
        defaults.set(previousDefault, forKey: NativeEngineDefaults.preferenceKey)
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        try library.reserveMutation(gameID: nil)
        try await library.activateCalimochoUpdate(selection, replacing: old.engineName, defaults: defaults)
        library.releaseMutation()
        check(try await gameStore.load() == customGames
              && defaults.data(forKey: NativeEngineDefaults.preferenceKey) == previousDefault
              && EngineDefaults.defaultEngine(defaults) == .crossover,
              "REQ123: activation preserves CrossOver defaults/overrides and unrelated custom Calimocho choices")
        let oldPreference = try JSONEncoder().encode(oldSelection)
        defaults.set(oldPreference, forKey: NativeEngineDefaults.preferenceKey)
        EngineDefaults.setDefaultEngine(.calimocho, defaults)
        try Data("invalid registry".utf8).write(to: root.appendingPathComponent("games/installed.json"))
        try library.reserveMutation(gameID: nil)
        do {
            try await library.activateCalimochoUpdate(selection, replacing: old.engineName, defaults: defaults)
            check(false, "REQ123: a failed title-selection save restores the previous default")
        } catch {
            check(defaults.data(forKey: NativeEngineDefaults.preferenceKey) == oldPreference,
                  "REQ123: a failed title-selection save restores the previous default")
        }
        library.releaseMutation()
    }

    private static func prefixContinuityCheck(root: URL, selection: AdmittedEngineSelection,
                                             label: String, check: (Bool, String) -> Void) throws {
        let id = UUID()
        let parent = root.appendingPathComponent(id.uuidString)
        let old = parent.appendingPathComponent(CalimochoReleasePin.release04.engineName)
        let product = "9NMNMS626R59"
        let target = CalimochoPrefixContinuity.location(productID: product, installationID: id,
            engine: selection.inspection.engineName!, root: root)
        let save = "drive_c/users/player/AppData/Local/game/save.dat"
        try FileManager.default.createDirectory(at: old.appendingPathComponent(save).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bytes = Data("retained progress".utf8)
        try bytes.write(to: old.appendingPathComponent(save))
        try FileManager.default.createSymbolicLink(atPath: old.appendingPathComponent("z:").path,
                                                  withDestinationPath: "/")
        let markerBytes = try JSONSerialization.data(withJSONObject: [
            "version": 1, "engine": CalimochoReleasePin.release04.engineName,
            "wine_sha256": CalimochoReleasePin.release04.wineSha256
        ])
        try Data("{}".utf8).write(to: CalimochoPrefixContinuity.marker(for: old))
        do {
            try CalimochoPrefixContinuity.prepare(prefix: target, selection: selection, productID: product, legacyIDs: [id])
            check(false, "S9: invalid legacy ownership refuses adoption")
        } catch NativeLaunchError.prefixConflict {
            check(!FileManager.default.fileExists(atPath: target.path),
                  "S9: invalid legacy ownership refuses adoption without creating a stable prefix")
        }
        try markerBytes.write(to: CalimochoPrefixContinuity.marker(for: old))
        let secondID = UUID()
        let second = root.appendingPathComponent(secondID.uuidString).appendingPathComponent(CalimochoReleasePin.release04.engineName)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        do {
            try CalimochoPrefixContinuity.prepare(prefix: target, selection: selection,
                                                  productID: product, legacyIDs: [id, secondID])
            check(false, "S9: ambiguous legacy installations refuse adoption")
        } catch NativeLaunchError.prefixConflict {
            check(!FileManager.default.fileExists(atPath: target.path),
                  "S9: ambiguous legacy installations refuse adoption without selecting arbitrary saves")
        }
        try FileManager.default.removeItem(at: second.deletingLastPathComponent())
        try CalimochoPrefixContinuity.prepare(prefix: target, selection: selection, productID: product, legacyIDs: [id])
        check(try Data(contentsOf: old.appendingPathComponent(save)) == bytes
              && Data(contentsOf: target.appendingPathComponent(save)) == bytes
              && Data(contentsOf: CalimochoPrefixContinuity.marker(for: old)) == markerBytes,
              "S9: \(label) clones prefix-local saves while preserving the old prefix and ownership bytes")
        let marker = try JSONValue.decodeUnique(Data(contentsOf: CalimochoPrefixContinuity.marker(for: target)),
                                                maximumBytes: 4_096)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("z:").path)
        check(marker["engine"]?.string == selection.inspection.engineName
              && marker["wine_sha256"]?.string == selection.inspection.wineSha256
              && link == "/",
              "S9: \(label) binds the new marker to admitted -06 and preserves external Wine links as links")
        let progressed = Data("new progress".utf8)
        try progressed.write(to: target.appendingPathComponent(save))
        try CalimochoPrefixContinuity.prepare(prefix: target, selection: selection, productID: product, legacyIDs: [id])
        check(try Data(contentsOf: target.appendingPathComponent(save)) == progressed
              && Data(contentsOf: old.appendingPathComponent(save)) == bytes,
              "S9: \(label) never recopies over an existing new prefix or changes the old saves")
    }

    private static func reinstallPrefixCheck(root: URL, selection: AdmittedEngineSelection,
                                            check: (Bool, String) -> Void) async throws {
        let store = InstalledGameStore(file: root.appendingPathComponent("installed-games.json"))
        let first = InstalledGame(id: UUID(), title: "Halls", identityName: "Halls", version: "1.0.0.0",
            storeId: "9NMNMS626R59", folder: root.appendingPathComponent("game").path,
            launcher: "", importedAt: Date(), usesNativeLifecycle: true)
        try await store.save([first])
        let prefixes = root.appendingPathComponent("Prefixes")
        let old = prefixes.appendingPathComponent(first.id.uuidString)
            .appendingPathComponent(CalimochoReleasePin.release04.engineName)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let save = Data("saved before uninstall".utf8)
        try save.write(to: old.appendingPathComponent("save.dat"))
        _ = try await store.remove(id: first.id)
        let reinstalled = InstalledGame(id: UUID(), title: first.title, identityName: first.identityName,
            version: first.version, storeId: first.storeId, folder: first.folder, launcher: "",
            importedAt: Date(), usesNativeLifecycle: true)
        try await store.save([reinstalled])
        let history = try await store.prefixInstallationIDs(productID: first.storeId)
        let target = CalimochoPrefixContinuity.location(productID: first.storeId, installationID: reinstalled.id,
            engine: selection.inspection.engineName!, root: prefixes)
        try CalimochoPrefixContinuity.prepare(prefix: target, selection: selection,
            productID: first.storeId, legacyIDs: history + [reinstalled.id])
        let restored = try Data(contentsOf: target.appendingPathComponent("save.dat"))
        check(history == [first.id] && restored == save
              && FileManager.default.fileExists(atPath: old.appendingPathComponent("save.dat").path),
              "S9: uninstall persists UUID-to-product provenance and reinstall restores prefix saves without deleting the old copy")
        let sameGame = CalimochoPrefixContinuity.location(productID: first.storeId, installationID: UUID(),
            engine: CalimochoReleasePin.release04.engineName, root: prefixes)
        let otherGame = CalimochoPrefixContinuity.location(productID: "9P9VNSQK1W3K", installationID: UUID(),
            engine: selection.inspection.engineName!, root: prefixes)
        check(target.path == sameGame.path && target.path != otherGame.path,
              "S9: stable product/Wine-family prefix survives installation UUID and release changes without sharing between games")
        let privateEngine = "calimocho-wine11.20-gptk4b3-tls-vulkan-private"
        check(CalimochoPrefixContinuity.location(productID: first.storeId, installationID: first.id,
            engine: privateEngine, root: prefixes) == prefixes.appendingPathComponent(first.id.uuidString).appendingPathComponent(privateEngine),
              "S9: developer-local NMS and non-release prefix keys are unchanged")
    }

    private static func finish(_ controller: CalimochoReleaseInstallController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while controller.isWorking {
            guard ContinuousClock.now < deadline else { throw CalimochoInstallError.extraction }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func renderUpdateControls(_ controller: CalimochoReleaseInstallController, name: String,
                                              check: (Bool, String) -> Void) throws {
        for (width, appearance) in [(CGFloat(560), NSAppearance.Name.aqua), (CGFloat(820), .darkAqua)] {
            let view = CalimochoUpdateControls(installer: controller, isBusy: { false },
                                               beginUpdate: { _ in }, removeOld: {})
                .padding(20).frame(width: width, height: 220, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 220)
            host.layoutSubtreeIfNeeded()
            check(host.window == nil, "REQ123: \(name) controls render detached at \(Int(width))")
            if let directory = ProcessInfo.processInfo.environment["XODUS_ENGINE_RENDER_DIRECTORY"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("updates-\(name)-\(Int(width)).png"))
            }
        }
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
