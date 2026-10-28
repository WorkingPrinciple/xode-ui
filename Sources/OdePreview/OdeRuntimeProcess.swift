// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import OdeManagement

@MainActor
final class OdeRuntimeProcess {
    private let parentDirectory: URL
    private let unexpectedExit: @MainActor () -> Void
    private var process: Process?
    private var parent: FileHandle?
    private var output: FileHandle?
    private var directory: URL?
    private var socketIdentity: (device: dev_t, inode: ino_t)?
    private var readiness = Data()
    private var ready = false
    private var failed = false
    private var stopping = false
    private var shutdownTask: Task<Bool, Never>?
    private(set) var socket: URL?

    init(parentDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Ode to X/State/RPS"),
         unexpectedExit: @escaping @MainActor () -> Void = {}) {
        self.parentDirectory = parentDirectory
        self.unexpectedExit = unexpectedExit
    }

    func start(_ configuration: BackendConfiguration) async throws {
        guard process == nil, !stopping else { throw GameScriptError.busy }
        try Task.checkCancellation()
#if ODE_SHIPPING
        guard configuration.executableIdentity != nil else { throw ManagementError.pairedEngineUnavailable }
#endif
        if let identity = configuration.executableIdentity {
            guard identity.executable == configuration.executable else { throw ManagementError.pairedEngineUnavailable }
            _ = try identity.validatedArguments()
        }
        try GameScriptFiles.checkPath(parentDirectory, allowMissing: true)
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let root = parentDirectory.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        let endpoint = root.appendingPathComponent("s")
        guard endpoint.path.utf8.count <= 103 else { throw GameScriptError.invalidDestination }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        directory = root
        socket = endpoint
        let input = Pipe(), outputPipe = Pipe()
        let child = Process()
        child.executableURL = configuration.executable
        child.arguments = ["ode-runtime", "--socket", endpoint.path]
        child.environment = InstalledGamesController.launchEnvironment(ProcessInfo.processInfo.environment)
        child.standardInput = input
        child.standardOutput = outputPipe
        child.standardError = FileHandle.nullDevice
        parent = input.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in self?.consume(bytes) }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopping else { return }
                self.failed = true
                self.ready = false
                self.unexpectedExit()
            }
        }
        process = child
        do {
            try child.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !ready, !failed, child.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard ready, !failed, child.isRunning else { throw GameScriptError.runtimeUnavailable }
            var info = stat()
            guard lstat(endpoint.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                  info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else {
                throw GameScriptError.runtimeUnavailable
            }
            socketIdentity = (info.st_dev, info.st_ino)
        } catch {
            guard await shutdown() else { throw ManagementError.shutdownFailed }
            throw error
        }
    }

    private func consume(_ bytes: Data) {
        guard !stopping, !failed else { return }
        let expected = Data("{\"kind\":\"ready\",\"version\":1}\n".utf8)
        guard !bytes.isEmpty, readiness.count + bytes.count <= expected.count else {
            failed = true
            unexpectedExit()
            return
        }
        readiness.append(bytes)
        guard expected.starts(with: readiness) else {
            failed = true
            unexpectedExit()
            return
        }
        ready = readiness == expected
    }

    func shutdown() async -> Bool {
        if let shutdownTask { return await shutdownTask.value }
        if stopping, process == nil, parent == nil, output == nil, directory == nil { return true }
        let job = Task { await self.finishShutdown() }
        shutdownTask = job
        let result = await job.value
        shutdownTask = nil
        return result
    }

    private func finishShutdown() async -> Bool {
        stopping = true
        ready = false
        if let parent {
            do { try parent.close() } catch { return false }
            self.parent = nil
        }
        if let process {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                process.terminate()
                let stopDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                while process.isRunning, ContinuousClock.now < stopDeadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            guard !process.isRunning else { return false }
        }
        output?.readabilityHandler = nil
        if let output {
            do { try output.close() } catch { return false }
            self.output = nil
        }
        if let socket {
            var info = stat()
            if lstat(socket.path, &info) == 0 {
                guard let socketIdentity, info.st_dev == socketIdentity.device, info.st_ino == socketIdentity.inode,
                      info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(),
                      unlink(socket.path) == 0 else { return false }
            } else if errno != ENOENT { return false }
        }
        if let directory, rmdir(directory.path) != 0, errno != ENOENT { return false }
        directory = nil
        socket = nil
        socketIdentity = nil
        process = nil
        return true
    }
}
