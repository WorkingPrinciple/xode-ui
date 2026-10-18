// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Darwin
import Security
import XodusProcessIdentity

struct LaunchProcessIdentity: Decodable, Equatable {
    let pid: Int32
    let start_sec: UInt64
    let start_usec: UInt64

    func matchesKernel() -> Bool {
        pid != getpid() && xodus_process_matches(pid, start_sec, start_usec) == 1
    }
}

struct LaunchAssociationAssets {
    let adapter: URL
    let library: URL
    let interpreter: URL
    static let broker = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/CrossOver-Hosted Application/wineserver"
    static let brokerSHA256 = "f9c4ed146c7d6dfc94334255907d4e0658218585085ca2107a5181b4deb474fc"

    private struct Manifest: Decodable {
        let version: Int
        let enabled: Bool
        let adapterSHA256: String
        let peerSHA256: String
        let brokerSHA256: String
    }

    private struct PythonRuntime: Decodable {
        struct FileIdentity: Decodable {
            let sha256: String
            let bytes: Int
            let executable: Bool
        }
        let version: Int
        let pythonVersion: String
        let archiveSHA256: String
        let files: [String: FileIdentity]
    }

    static func bundled(_ bundle: Bundle = .main) throws -> Self? {
        let root = bundle.bundleURL.appendingPathComponent("Contents/Resources/LaunchAssociation")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        try requireSignature(bundle)
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: checkedFile(root.appendingPathComponent("manifest.json"), maximum: 4096))
        guard manifest.version == 1 else { throw AssociationError.unavailable }
        guard manifest.enabled else { return nil }
        var brokerCode: SecStaticCode?
        var requirement: SecRequirement?
        let brokerURL = URL(fileURLWithPath: broker)
        guard manifest.brokerSHA256 == brokerSHA256,
              SHA256.hash(data: try checkedFile(brokerURL, maximum: 64 * 1024 * 1024))
                .map({ String(format: "%02x", $0) }).joined() == brokerSHA256,
              SecRequirementCreateWithString(
                #"anchor apple generic and certificate leaf[subject.OU] = "9C6B7X7Z8E" and identifier "com.codeweavers.CrossOver.bin.wineserver""# as CFString,
                [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(brokerURL as CFURL, [], &brokerCode) == errSecSuccess,
              let brokerCode, SecStaticCodeCheckValidity(brokerCode, [], requirement) == errSecSuccess else {
            throw AssociationError.unavailable
        }
        let adapter = root.appendingPathComponent("adapter.py")
        let library = root.appendingPathComponent("peer.dylib")
        for (url, expected) in [(adapter, manifest.adapterSHA256), (library, manifest.peerSHA256)] {
            guard expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  SHA256.hash(data: try checkedFile(url, maximum: 16 * 1024 * 1024))
                    .map({ String(format: "%02x", $0) }).joined() == expected else {
                throw AssociationError.unavailable
            }
        }
        guard let interpreter = try bundledInterpreter(bundle) else { throw AssociationError.unavailable }
        return Self(adapter: adapter, library: library, interpreter: interpreter)
    }

    static func bundledInterpreter(_ bundle: Bundle = .main) throws -> URL? {
        let pythonRoot = bundle.bundleURL.appendingPathComponent("Contents/Resources/XodusPython")
        let metadata = pythonRoot.appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: pythonRoot.path)
                || FileManager.default.fileExists(atPath: metadata.path)
                || (try? pythonRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                || (try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
            return nil
        }
        try requireSignature(bundle)
        let python = try JSONDecoder().decode(PythonRuntime.self, from: checkedFile(
            metadata, maximum: 4 * 1024 * 1024))
        let interpreter = pythonRoot.appendingPathComponent("bin/python3")
        guard python.version == 1, python.pythonVersion == "3.14.8",
              python.archiveSHA256 == "994adadc202c5df0b4570192cc9a70e3f2c131e512f4a125c56efa8562f44b28",
              let executable = python.files["bin/python3"], executable.executable,
              !interpreter.deletingLastPathComponent().path.contains(":"),
              FileManager.default.isExecutableFile(atPath: interpreter.path) else {
            throw AssociationError.unavailable
        }
        let executableData = try checkedFile(interpreter, maximum: 64 * 1024 * 1024)
        guard executableData.count == executable.bytes,
              SHA256.hash(data: executableData).map({ String(format: "%02x", $0) }).joined()
                == executable.sha256 else { throw AssociationError.unavailable }
        return interpreter
    }

    static func interpreterEnvironment(_ interpreter: URL) -> [String: String] {
        ["PATH": interpreter.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"]
    }

    private static func requireSignature(_ bundle: Bundle) throws {
        var code: SecStaticCode?
        guard bundle.bundleURL.pathExtension == "app",
              SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures
                | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw AssociationError.unavailable
        }
    }

    private static func checkedFile(_ url: URL, maximum: Int) throws -> Data {
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else { throw AssociationError.unavailable }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AssociationError.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= maximum,
              let data = try file.read(upToCount: maximum + 1), data.count <= maximum else {
            throw AssociationError.unavailable
        }
        return data
    }
}

enum AssociationError: Error { case unavailable }

/// One optional launch-scoped request. No process discovery or cached PID reuse.
@MainActor
final class LaunchAssociationHandoff {
    static let diagnostic = "Game foreground handoff unavailable."
    let environment: [String: String]
    private let assets: LaunchAssociationAssets
    private let root: URL
    private let runID: String
    private let nonce: String
    private var task: Task<Void, Never>?
    private var command: Process?
    private var cancelled = false
    private var attempted = false
    private var observer: NSObjectProtocol?
    private let donorActive: @MainActor () -> Bool
    private let ready: @MainActor (LaunchProcessIdentity) -> Bool
    private let activate: @MainActor (LaunchProcessIdentity) -> Bool

    init(assets: LaunchAssociationAssets, runID: String, root: URL,
         donorActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         ready: @escaping @MainActor (LaunchProcessIdentity) -> Bool = LaunchAssociationHandoff.readyTarget,
         activate: @escaping @MainActor (LaunchProcessIdentity) -> Bool = LaunchAssociationHandoff.activateTarget) throws {
        guard GameScriptPaths.validRunID(runID), donorActive() else { throw AssociationError.unavailable }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AssociationError.unavailable
        }
        nonce = bytes.map { String(format: "%02x", $0) }.joined()
        self.assets = assets
        self.runID = runID
        self.root = root
        self.donorActive = donorActive
        self.ready = ready
        self.activate = activate
        guard mkdir(root.path, 0o700) == 0 else { throw AssociationError.unavailable }
        environment = ["XODUS_LAUNCH_ASSOCIATION_ROOT": root.path, "XODUS_LAUNCH_RUN_ID": runID,
                       "XODUS_LAUNCH_RUN_NONCE": nonce, "XODUS_LAUNCH_PEER_LIBRARY": assets.library.path,
                       "XODUS_LAUNCH_TRUSTED_BROKER_PATH": LaunchAssociationAssets.broker,
                       "XODUS_LAUNCH_EXPECTED_BROKER_SHA256": LaunchAssociationAssets.brokerSHA256]
            .merging(LaunchAssociationAssets.interpreterEnvironment(assets.interpreter)) { _, new in new }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
    }

    func start(current: @escaping () -> Bool, diagnostic: @escaping () -> Void,
               duration: Duration = .seconds(120)) {
        guard task == nil, !cancelled, !attempted else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.cleanup() }
            let deadline = ContinuousClock.now.advanced(by: duration)
            while !Task.isCancelled && !self.cancelled && current() && self.donorActive()
                    && ContinuousClock.now < deadline {
                if let identity = await self.consume(deadline: deadline), !Task.isCancelled, !self.cancelled,
                   ContinuousClock.now < deadline, current(), self.donorActive(),
                   identity.matchesKernel(), self.ready(identity) {
                    self.attempted = true
                    if !self.activate(identity) { diagnostic() }
                    return
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { break }
                do { try await Task.sleep(for: min(.milliseconds(250), remaining)) } catch { return }
            }
            if !Task.isCancelled && !self.cancelled && current() && self.donorActive() { diagnostic() }
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        if let command, command.isRunning { command.terminate() }
        if task == nil { cleanup() }
    }

    func cancelAndWait() async -> Bool {
        cancel()
        await task?.value
        return command?.isRunning != true
    }

    func releaseRootAfterLauncherExit() {
        // The bridge owns RUN_ID/bridge.json. Never delete its live descriptor.
        _ = rmdir(root.path)
    }

    private func consume(deadline overallDeadline: ContinuousClock.Instant) async -> LaunchProcessIdentity? {
        guard command?.isRunning != true else { return nil }
        let child = Process()
        let pipe = Pipe()
        child.executableURL = assets.interpreter
        child.arguments = ["-I", "-B", assets.adapter.path, "--association",
            root.appendingPathComponent(runID).appendingPathComponent("bridge.json").path,
            "--run-id", runID, "--run-nonce-env", "XODUS_LAUNCH_RUN_NONCE", "--peer-library", assets.library.path,
            "--trusted-broker-path", LaunchAssociationAssets.broker,
            "--expected-broker-sha256", LaunchAssociationAssets.brokerSHA256]
        child.environment = ["PATH": "/usr/bin:/bin", "XODUS_LAUNCH_RUN_NONCE": nonce,
                             "PYTHONDONTWRITEBYTECODE": "1",
                             "XODUS_LAUNCH_TRUSTED_BROKER_PATH": LaunchAssociationAssets.broker,
                             "XODUS_LAUNCH_EXPECTED_BROKER_SHA256": LaunchAssociationAssets.brokerSHA256]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        do { try child.run() } catch { return nil }
        pipe.fileHandleForWriting.closeFile()
        command = child
        defer {
            if !child.isRunning { command = nil }
            pipe.fileHandleForReading.closeFile()
        }
        var data = Data()
        let deadline = min(overallDeadline, ContinuousClock.now.advanced(by: .seconds(3)))
        while true {
            var buffer = [UInt8](repeating: 0, count: 1025)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            if data.count > 1024 || cancelled || Task.isCancelled || ContinuousClock.now >= deadline {
                if child.isRunning { child.terminate() }
                try? await Task.sleep(for: .milliseconds(100))
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
                let joinDeadline = ContinuousClock.now.advanced(by: .seconds(1))
                while child.isRunning && ContinuousClock.now < joinDeadline {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
                }
                return nil
            }
            if !child.isRunning && count <= 0 { break }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { continue }
        }
        guard child.terminationStatus == 0,
              // This exact three-number contract has three key strings, no string values.
              data.filter({ $0 == 34 }).count == 6,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["pid", "start_sec", "start_usec"],
              let identity = try? JSONDecoder().decode(LaunchProcessIdentity.self, from: data),
              identity.matchesKernel() else { return nil }
        return identity
    }

    private func cleanup() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    }

    private static func readyTarget(_ identity: LaunchProcessIdentity) -> Bool {
        guard identity.matchesKernel(), let target = NSRunningApplication(processIdentifier: identity.pid),
              !target.isTerminated, target.isFinishedLaunching,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains {
            guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == identity.pid,
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0,
                  let bounds = $0[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.width > 1 && rect.height > 1
        }
    }

    private static func activateTarget(_ identity: LaunchProcessIdentity) -> Bool {
        guard #available(macOS 14, *), NSApp.isActive, readyTarget(identity),
              let target = NSRunningApplication(processIdentifier: identity.pid),
              !target.isTerminated, target.isFinishedLaunching, identity.matchesKernel(),
              NSApp.isActive else { return false }
        NSApp.yieldActivation(to: target)
        return target.activate(options: [])
    }
}
