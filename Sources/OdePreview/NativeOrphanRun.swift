// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import OdeLegacyCompatibility
import Foundation

/// Detects a backend lifecycle run that outlived the app process that started it
/// (for example after a force quit). Read-only: it never starts, repeats or changes a run.
enum NativeOrphanRun {
    enum Status: Equatable {
        case notRunning
        /// The backend still holds the game folder lock. `pid` is set only when the exact
        /// backend process for this run was verified.
        case running(pid: Int32?)
    }

    static let pidFileName = "ode-backend.pid"

    struct Identity: Equatable {
        let operation: String
        let product: String
        let gameDirectory: String
        let stateDirectory: String
        let executable: String?
    }

    /// The sibling lock the backend holds for the whole operation (`.<name>.ode-lifecycle.lock`; a pre-rename backend's lock name is also checked).
    static func lockURL(gameDirectory: URL) -> URL? {
        let name = gameDirectory.lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        let parent = gameDirectory.deletingLastPathComponent()
        let resolvedParent: URL
        if FileManager.default.fileExists(atPath: gameDirectory.path) {
            resolvedParent = gameDirectory.resolvingSymlinksInPath().deletingLastPathComponent()
        } else {
            resolvedParent = parent.resolvingSymlinksInPath()
        }
        let resolvedName = FileManager.default.fileExists(atPath: gameDirectory.path)
            ? gameDirectory.resolvingSymlinksInPath().lastPathComponent : name
        return resolvedParent.appendingPathComponent(".\(resolvedName).ode-lifecycle.lock")
    }

    static func lockHeld(gameDirectory: URL) -> Bool {
        guard let url = lockURL(gameDirectory: gameDirectory) else { return false }
        return held(url) || LegacyCompatibility.legacySidecar(for: url).map(held) == true
    }

    private static func held(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            return false
        }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    static func status(identity: Identity) -> Status {
        guard lockHeld(gameDirectory: URL(fileURLWithPath: identity.gameDirectory)) else { return .notRunning }
        return .running(pid: verifiedPID(identity: identity))
    }

    /// Candidates come from the app's own pid record and from the backend's `child_started`
    /// event (whose parent is the backend). Each candidate must match this run's exact command.
    static func verifiedPID(identity: Identity) -> Int32? {
        let state = URL(fileURLWithPath: identity.stateDirectory)
        var candidates: [Int32] = []
        if let data = try? InstalledGameFiles.readRegular(state.appendingPathComponent(pidFileName),
                                                          maximumBytes: 32, privateFile: true),
           let text = String(data: data, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            candidates.append(pid)
        }
        if let child = childStartedPID(state: state), let parent = parentPID(child) { candidates.append(parent) }
        return candidates.first { matches(pid: $0, identity: identity) }
    }

    static func childStartedPID(state: URL) -> Int32? {
        let runs = state.appendingPathComponent("runs")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil),
              entries.count == 1, let run = entries.first, UUID(uuidString: run.lastPathComponent) != nil,
              let data = try? InstalledGameFiles.readRegular(run.appendingPathComponent("events.jsonl"),
                                                             maximumBytes: 1_048_576, privateFile: true) else {
            return nil
        }
        for line in data.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["event"] as? String == "child_started", let pid = object["pid"] as? Int,
                  pid > 1, pid <= Int(Int32.max) else { continue }
            return Int32(pid)
        }
        return nil
    }

    static func parentPID(_ pid: Int32) -> Int32? {
        guard let info = processInfo(pid), info.kp_eproc.e_ucred.cr_uid == getuid() else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    private static func processInfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    /// Executable path and argv from `KERN_PROCARGS2`.
    static func command(pid: Int32) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size <= 1_048_576 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard count > 0, count < 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        func string() -> String? {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            guard index < size else { return nil }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        guard let executable = string() else { return nil }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard let value = string() else { return nil }
            arguments.append(value)
        }
        return (executable, arguments)
    }

    static func matches(executable: String, arguments: [String], identity: Identity) -> Bool {
        if let expected = identity.executable,
           URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            != URL(fileURLWithPath: expected).resolvingSymlinksInPath().path {
            return false
        }
        guard arguments.count >= 7, arguments[1] == identity.operation, arguments[2] == identity.product else {
            return false
        }
        func value(_ flag: String) -> String? {
            guard let position = arguments.firstIndex(of: flag), position + 1 < arguments.count else { return nil }
            return arguments[position + 1]
        }
        return value("--game-dir") == identity.gameDirectory && value("--state-dir") == identity.stateDirectory
    }

    static func matches(pid: Int32, identity: Identity) -> Bool {
        guard pid > 1, pid != getpid(), let info = processInfo(pid), info.kp_eproc.e_ucred.cr_uid == getuid(),
              let command = command(pid: pid) else { return false }
        return matches(executable: command.executable, arguments: command.arguments, identity: identity)
    }

    /// Sends TERM only to the verified backend process of this run; the backend stops its own child.
    static func terminate(pid: Int32, identity: Identity) -> Bool {
        guard matches(pid: pid, identity: identity) else { return false }
        return kill(pid, SIGTERM) == 0
    }
}
