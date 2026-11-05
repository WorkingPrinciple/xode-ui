// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Security
import XodusManagement

enum CalimochoInstallFailure: LocalizedError {
    case space, archive, integrity, exists, extraction, shutdown, busy, cleanup(String)
    var errorDescription: String? {
        switch self {
        case .space: "There isn't enough free space to download and unpack Calimocho."
        case .archive: "The Calimocho ZIP isn't the expected safe release archive. Nothing was selected."
        case .integrity: "Calimocho failed its release size, SHA-256 or publisher signature check. Nothing was selected."
        case .exists: "This Calimocho release folder already exists. It wasn't overwritten."
        case .extraction: "Calimocho couldn't be unpacked. Try the download again."
        case .shutdown: "Calimocho extraction hasn't stopped. Keep Ode to X open and retry quitting; its temporary files were retained."
        case .busy: "Finish the running game or current operation before changing Calimocho."
        case .cleanup(let reason): "Calimocho temporary files couldn't be removed: \(reason)"
        }
    }
}

@MainActor
final class CalimochoReleaseInstaller {
    private let inspector = EngineInspectionClient()
    private var extraction: Process?
    private var lockFD: Int32?
    private var shutdownRequired = false

    var hasOwnedProcess: Bool { extraction?.isRunning == true }
    var hasUnjoinedWork: Bool { hasOwnedProcess || shutdownRequired }

    static func worker<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .utility, operation: body)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func obtain(_ release: CalimochoRelease, root: URL, registries: URL,
                configuration: BackendConfiguration, cachedArchive: URL? = nil,
                progress: @escaping @Sendable (String) async -> Void) async throws -> AdmittedEngineSelection {
        guard !hasUnjoinedWork, lockFD == nil else { throw CalimochoInstallFailure.busy }
        try prepare(root)
        let fd = open(root.appendingPathComponent(".calimocho-install.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw GameScriptError.storage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw CalimochoInstallFailure.busy
        }
        lockFD = fd
        defer { if !hasUnjoinedWork { releaseLock() } }
        let engine = root.appendingPathComponent(release.rawValue, isDirectory: true)
        if try exists(engine) {
            await progress("Verifying the existing release")
            return try await admit(release, engine: engine, registries: registries, configuration: configuration)
        }
        guard let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
              Int64(available) >= release.archiveBytes + release.expandedBytes else {
            throw CalimochoInstallFailure.space
        }
        let staging = root.appendingPathComponent(".calimocho-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var published = false
        do {
            let archive = staging.appendingPathComponent("release.zip")
            if let cachedArchive {
                await progress("Verifying the cached release archive")
                try await Self.worker {
                    try GameScriptFiles.checkPath(cachedArchive)
                    let size = try cachedArchive.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard size.isRegularFile == true, size.fileSize == Int(release.archiveBytes) else {
                        throw CalimochoInstallFailure.integrity
                    }
                    try Task.checkCancellation()
                    try FileManager.default.copyItem(at: cachedArchive, to: archive)
                }
            } else {
                try await Self.download(release, to: archive, progress: progress)
            }
            await progress("Verifying the release archive")
            try await Self.worker {
                try Task.checkCancellation()
                let bytes = try InstalledGameFiles.readRegular(archive, maximumBytes: Int(release.archiveBytes))
                guard bytes.count == release.archiveBytes, CalimochoRelease.digest(bytes) == release.archiveSHA256 else {
                    throw CalimochoInstallFailure.integrity
                }
                try Task.checkCancellation()
                try CalimochoArchive.validate(bytes, release: release)
            }
            let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            await progress("Unpacking Calimocho \(release.version)")
            try await extract(archive, to: extracted)
            try await Self.worker {
                try CalimochoArchive.validateExtracted(root: extracted, release: release)
            }
            let stagedEngine = extracted.appendingPathComponent(release.rawValue, isDirectory: true)
            await progress("Checking the staged engine with the app service")
            _ = try await admit(release, engine: stagedEngine, registries: staging.appendingPathComponent("Registries"),
                                configuration: configuration)
            try Task.checkCancellation()
            guard renamex_np(stagedEngine.path, engine.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw CalimochoInstallFailure.exists }
                throw GameScriptError.storage
            }
            published = true
            await progress("Verifying Calimocho in its final location")
            let selection = try await admit(release, engine: engine, registries: registries, configuration: configuration)
            try await cleanup(staging)
            return selection
        } catch {
            let original = error
            do { try await inspector.closeOwnedProcess() }
            catch { shutdownRequired = true; throw error }
            if hasOwnedProcess { throw CalimochoInstallFailure.shutdown }
            if published { try await cleanup(engine) }
            try await cleanup(staging)
            throw original
        }
    }

    func admit(_ release: CalimochoRelease, engine: URL, registries: URL,
               configuration: BackendConfiguration) async throws -> AdmittedEngineSelection {
        let data = try await Self.worker {
            try Task.checkCancellation()
            let data = try release.registryData(engine: engine)
            for name in ["wine", "wineserver"] {
                try Task.checkCancellation()
                let executable = engine.appendingPathComponent("bin/\(name)")
                var code: SecStaticCode?, requirement: SecRequirement?
                let text = "anchor apple generic and certificate leaf[subject.OU] = \"M62Z4M5EUY\""
                guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
                      SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                      let requirement,
                      SecStaticCodeCheckValidity(code,
                        SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else {
                    throw CalimochoInstallFailure.integrity
                }
            }
            return data
        }
        try Task.checkCancellation()
        try prepare(registries)
        let digest = CalimochoRelease.digest(data)
        let registry = registries.appendingPathComponent("\(release.rawValue)-ode-default-v3-\(digest).json")
        let created = try !exists(registry)
        if !created {
            guard try InstalledGameFiles.readRegular(registry, maximumBytes: 65_536) == data else {
                throw NativeLaunchError.selectionChanged
            }
        } else {
            try GameScriptFiles.writePrivate(data, to: registry)
        }
        do {
            let result = try await inspector.inspect(executable: configuration.executable, registry: registry,
                engine: release.rawValue, expectedDigest: digest, executableIdentity: configuration.executableIdentity)
            if !result.ready, let error = result.error { throw EngineInspectionError.rejected(error) }
            let selection = AdmittedEngineSelection(registryPath: registry.path, inspection: result)
            try selection.validate(registryPath: registry.path, engineName: release.rawValue, registryDigest: digest)
            guard result.wineSha256 == release.wineSHA256, result.wineserverSha256 == release.wineserverSHA256 else {
                throw NativeLaunchError.selectionChanged
            }
            try Task.checkCancellation()
            return selection
        } catch {
            let original = error
            do { try await inspector.closeOwnedProcess() }
            catch { shutdownRequired = true; throw error }
            if created { try await cleanup(registry) }
            throw original
        }
    }

    private func prepare(_ root: URL) throws {
        try GameScriptFiles.checkPath(root, allowMissing: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try GameScriptFiles.checkPath(root)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(root.path, 0o700) == 0 else {
            throw GameScriptError.storage
        }
    }

    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw GameScriptError.storage }
        return false
    }

    private func cleanup(_ url: URL) async throws {
        // Join cleanup even after cancellation; never remove a directory under a live worker.
        let task = Task.detached(priority: .utility) {
            try GameScriptFiles.checkPath(url)
            try FileManager.default.removeItem(at: url)
        }
        do { try await task.value }
        catch { throw CalimochoInstallFailure.cleanup(error.localizedDescription) }
    }

    static func download(_ release: CalimochoRelease, to archive: URL,
                         progress: @escaping @Sendable (String) async -> Void) async throws {
        let task = Task.detached(priority: .utility) {
            var request = URLRequest(url: release.archiveURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.timeoutIntervalForResource = 900
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme == "https",
                  http.expectedContentLength < 0 || http.expectedContentLength == release.archiveBytes else {
                throw CalimochoInstallFailure.integrity
            }
            let fd = open(archive.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw GameScriptError.storage }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { handle.closeFile() }
            var received: Int64 = 0, buffer = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                received += 1
                guard received <= release.archiveBytes else { throw CalimochoInstallFailure.integrity }
                buffer.append(byte)
                if buffer.count == 262_144 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    await progress("Downloading Calimocho: \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: release.archiveBytes, countStyle: .file))")
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.synchronize()
            guard received == release.archiveBytes else { throw CalimochoInstallFailure.integrity }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func extract(_ archive: URL, to destination: URL) async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        child.arguments = ["-x", "-k", archive.path, destination.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try child.run()
        extraction = child
        do {
            while child.isRunning { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(20)) }
            extraction = nil
            try Task.checkCancellation()
            guard child.terminationReason == .exit, child.terminationStatus == 0 else {
                throw CalimochoInstallFailure.extraction
            }
        } catch {
            if child.isRunning { child.terminate() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while child.isRunning, ContinuousClock.now < deadline {
                await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while child.isRunning, ContinuousClock.now < killDeadline {
                await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
            }
            guard !child.isRunning else { throw CalimochoInstallFailure.shutdown }
            extraction = nil
            throw error
        }
    }

    private func releaseLock() {
        if let lockFD { Darwin.close(lockFD); self.lockFD = nil }
    }

    func close() async throws {
        try await inspector.closeOwnedProcess()
        guard !hasOwnedProcess else { throw CalimochoInstallFailure.shutdown }
        extraction = nil
        shutdownRequired = false
        releaseLock()
    }
}
