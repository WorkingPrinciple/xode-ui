// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusManagement

/// REQ-135: the producer's read-only package inventory (`xodus-cli install-inventory`, producer #8). It lists
/// the files the installed package owns, from the package's own NTFS inventory, with an lstat-only disk state.
/// Anything not listed (saves, user files, a prefix) is not the package's and is never deleted.
struct NativeInstallInventory: Decodable, Equatable, Sendable {
    struct File: Decodable, Equatable, Sendable {
        let path: String
        let bytes: UInt64
        let encryptedAtRest: Bool
        let diskState: String

        private enum CodingKeys: String, CodingKey {
            case path, bytes, encryptedAtRest = "encrypted_at_rest", diskState = "disk_state"
        }
    }

    let version: Int
    let operation: String
    let product: String
    let gameDirectory: String
    let success: Bool
    let errorCode: String?
    let manifestIdentity: String?
    let filesTotal: Int?
    let files: [File]?
    let directories: [String]?
    let packageRecords: [String]?

    private enum CodingKeys: String, CodingKey {
        case version, operation, product, success, files, directories
        case gameDirectory = "game_dir", errorCode = "error_code", manifestIdentity = "manifest_identity"
        case filesTotal = "files_total", packageRecords = "package_records"
    }

    static let maximumEntries = 1_000_000
    static let layoutMatches = "layout_matches"

    /// Only a successful, verified inventory of this exact product and folder authorises any delete.
    func validate(product: String, gameDirectory: URL) throws {
        guard version == 1, operation == "install-inventory", self.product == product,
              self.gameDirectory == gameDirectory.path else { throw GameScriptError.invalidReceipt }
        guard success, errorCode == nil else { throw PackageInventoryRemoval.Refusal.unavailable(errorCode) }
        guard manifestIdentity == "verified" else { throw PackageInventoryRemoval.Refusal.identityUnproven }
        guard let files, let directories, files.count == filesTotal, files.count <= Self.maximumEntries,
              directories.count <= Self.maximumEntries, (packageRecords?.count ?? 0) <= 16 else {
            throw GameScriptError.invalidReceipt
        }
        var seen = Set<String>()
        for entry in files {
            guard try PackageInventoryRemoval.components(entry.path).count >= 1, seen.insert(entry.path).inserted else {
                throw GameScriptError.invalidReceipt
            }
        }
        for directory in directories { _ = try PackageInventoryRemoval.components(directory) }
        for record in packageRecords ?? [] {
            guard try PackageInventoryRemoval.components(record).count == 1,
                  record.hasPrefix(".xodus-streaming") else { throw GameScriptError.invalidReceipt }
        }
    }
}

/// Deletes only package-owned files the inventory reports as `layout_matches`, one path component at a time with
/// `openat`/`unlinkat` and `O_NOFOLLOW` from the root it opened, rechecking each file's type, link count and size
/// immediately before unlinking it. Modified (`layout_differs`), unsafe, non-regular and unlisted entries stay.
/// Listed directories are removed only when empty; identity markers and package records go last.
enum PackageInventoryRemoval {
    enum Refusal: Error, Equatable, LocalizedError {
        case unavailable(String?)
        case identityUnproven
        case rootChanged

        var errorDescription: String? {
            switch self {
            case .unavailable(let code) where code == "RESOURCE_BUSY":
                "This game is in use by another operation, so nothing was deleted. Try again when it finishes."
            case .unavailable:
                "X Ode couldn't list this game's own files, so nothing was deleted. Use Remove from Library (Keep Files) instead."
            case .identityUnproven:
                NativeInstallationStatus.identityUnprovenExplanation
            case .rootChanged:
                "The game folder changed while it was being checked, so nothing was deleted."
            }
        }
    }

    struct Outcome: Equatable, Sendable {
        var removedFiles = 0
        var removedBytes: UInt64 = 0
        var removedDirectories = 0
        var removedRoot = false
        /// Relative paths kept because they changed, are unsafe or couldn't be removed.
        var kept: [String] = []
        /// Entries in the root the package doesn't own (saves, user files), counted after the delete.
        var unlisted = 0
    }

    /// Splits a relative inventory path; anything absolute, empty, `.`/`..` or with NUL is refused.
    static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4_096 else {
            throw GameScriptError.invalidReceipt
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw GameScriptError.invalidReceipt
        }
        return parts
    }

    static let identityMarkers: Set<String> = ["microsoftgame.config", "game.xml"]

    static func remove(_ inventory: NativeInstallInventory, root: URL,
                       isCancelled: () -> Bool = { false }) throws -> Outcome {
        try GameScriptFiles.checkPath(root)
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Refusal.rootChanged }
        defer { close(rootFD) }
        var outcome = Outcome()
        let files = inventory.files ?? []
        // Ordinary content first, root identity markers last, so an interrupted delete stays recognisable.
        let ordered = files.filter { !isIdentityMarker($0.path) } + files.filter { isIdentityMarker($0.path) }
        for entry in ordered {
            guard !isCancelled() else { break }
            guard entry.diskState == NativeInstallInventory.layoutMatches else {
                if entry.diskState != "missing" { outcome.kept.append(entry.path) }
                continue
            }
            switch try unlinkFile(entry, rootFD: rootFD) {
            case .removed: outcome.removedFiles += 1; outcome.removedBytes += entry.bytes
            case .missing: break
            case .kept: outcome.kept.append(entry.path)
            }
        }
        if !isCancelled() {
            for record in inventory.packageRecords ?? [] {
                var info = stat()
                guard fstatat(rootFD, record, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, unlinkat(rootFD, record, 0) == 0 {
                    outcome.removedFiles += 1
                } else {
                    outcome.kept.append(record)
                }
            }
            // Deepest first, and only when empty: a directory holding saves or user files stays.
            let directories = (inventory.directories ?? []).sorted {
                $0.split(separator: "/").count > $1.split(separator: "/").count
            }
            for directory in directories where removeEmptyDirectory(directory, rootFD: rootFD) {
                outcome.removedDirectories += 1
            }
        }
        outcome.unlisted = countEntries(rootFD)
        if outcome.unlisted == 0, outcome.kept.isEmpty, !isCancelled() {
            outcome.removedRoot = removeEmptyRoot(root)
        }
        return outcome
    }

    private static func isIdentityMarker(_ path: String) -> Bool {
        !path.contains("/") && identityMarkers.contains(path.lowercased())
    }

    private enum FileResult { case removed, missing, kept }

    /// Opens each parent directory with O_NOFOLLOW from the root descriptor; a symlinked or replaced
    /// ancestor, or a file whose type, link count or size no longer matches, is kept.
    private static func unlinkFile(_ entry: NativeInstallInventory.File, rootFD: Int32) throws -> FileResult {
        let parts = try components(entry.path)
        var directory = rootFD
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return errno == ENOENT ? .missing : .kept }
            opened.append(next)
            directory = next
        }
        let name = parts[parts.count - 1]
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT ? .missing : .kept }
        let size = UInt64(max(0, info.st_size))
        let padded = (entry.bytes + 4_095) / 4_096 * 4_096
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              size == entry.bytes || (entry.encryptedAtRest && size == padded) else { return .kept }
        guard unlinkat(directory, name, 0) == 0 else { return errno == ENOENT ? .missing : .kept }
        return .removed
    }

    private static func removeEmptyDirectory(_ path: String, rootFD: Int32) -> Bool {
        guard let parts = try? components(path) else { return false }
        var directory = rootFD
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return false }
            opened.append(next)
            directory = next
        }
        var info = stat()
        guard fstatat(directory, parts[parts.count - 1], &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { return false }
        // unlinkat with AT_REMOVEDIR fails with ENOTEMPTY when anything is left inside.
        return unlinkat(directory, parts[parts.count - 1], AT_REMOVEDIR) == 0
    }

    private static func countEntries(_ fd: Int32) -> Int {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { return Int.max }
        defer { closedir(stream) }
        var count = 0
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if name != "." && name != ".." { count += 1 }
        }
        return count
    }

    private static func removeEmptyRoot(_ root: URL) -> Bool {
        let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return false }
        defer { close(parent) }
        return unlinkat(parent, root.lastPathComponent, AT_REMOVEDIR) == 0
    }
}

/// Runs `xodus-cli install-inventory` for one product and folder. Read-only and account-free.
@MainActor
final class NativeInstallInventoryQuery {
    static let timeout: Duration = .seconds(300)
    nonisolated static let maximumOutputBytes = 64 * 1_048_576

    func run(configuration: BackendConfiguration, product: String, gameDirectory: URL) async throws -> NativeInstallInventory {
        guard PCGamesClient.validProductID(product) else { throw GameScriptError.invalidDestination }
#if XODUS_SHIPPING
        guard configuration.executableIdentity != nil else { throw GameScriptError.runtimeUnavailable }
#endif
        if let identity = configuration.executableIdentity {
            guard identity.executable == configuration.executable else { throw GameScriptError.runtimeUnavailable }
            _ = try await Task.detached { try identity.validatedArguments() }.value
        }
        try GameScriptFiles.checkPath(gameDirectory)
        let state = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Xodus/InstallInventory/\(InstalledGamesController.runID())")
        try GameScriptFiles.checkPath(state, allowMissing: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: state) }
        let outputURL = state.appendingPathComponent("stdout.json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: Data(),
                                             attributes: [.posixPermissions: 0o600]) else { throw GameScriptError.storage }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { output.closeFile() }
        let child = Process()
        child.executableURL = configuration.executable
        child.arguments = ["install-inventory", product, "--game-dir", gameDirectory.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.environment = InstalledGamesController.launchEnvironment(ProcessInfo.processInfo.environment)
        try child.run()
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        while child.isRunning {
            guard ContinuousClock.now < deadline else {
                child.terminate()
                await Task.detached { child.waitUntilExit() }.value
                throw GameScriptError.timeout
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try output.synchronize()
        let data = try await Task.detached {
            try InstalledGameFiles.readRegular(outputURL, maximumBytes: Self.maximumOutputBytes, privateFile: true)
        }.value
        guard let value = try? JSONDecoder().decode(NativeInstallInventory.self, from: data) else {
            // A game service without install-inventory (before producer #8) can't prove package files.
            throw PackageInventoryRemoval.Refusal.unavailable(nil)
        }
        guard value.success == (child.terminationStatus == 0) else { throw GameScriptError.invalidReceipt }
        return value
    }
}
