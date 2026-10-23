// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

public struct NativeAuthHostBinding: Sendable {
    public let executable: URL
    public let sha256: String
    public let version: Int
    public let expectedBytes: Int64?

    public init(executable: URL, sha256: String, version: Int = 1, expectedBytes: Int64? = nil) {
        self.executable = executable
        self.sha256 = sha256
        self.version = version
        self.expectedBytes = expectedBytes
    }

    public func validatedArguments() throws -> [String] {
        guard version == 1, sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              executable.isFileURL, executable.path.hasPrefix("/"),
              executable.standardizedFileURL == executable,
              executable.resolvingSymlinksInPath() == executable else {
            throw ManagementError.backendUnavailable
        }
        let fd = open(executable.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ManagementError.backendUnavailable }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
              before.st_mode & 0o100 != 0, before.st_size > 0 else {
            throw ManagementError.backendUnavailable
        }
        if let expectedBytes, expectedBytes <= 0 || before.st_size != expectedBytes {
            throw ManagementError.backendUnavailable
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var digest = SHA256()
        do {
            while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty {
                digest.update(data: bytes)
            }
        } catch { throw ManagementError.backendUnavailable }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode,
              before.st_uid == after.st_uid, before.st_nlink == after.st_nlink,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw ManagementError.backendUnavailable
        }
        return ["--native-auth-host", executable.path, "--native-auth-host-sha256", sha256,
                "--native-auth-host-version", String(version)]
    }

    public static func bundled(in bundle: Bundle, expectedSourceCommit: String? = nil) throws -> Self? {
        let executable = bundle.bundleURL.appendingPathComponent("Contents/MacOS/XodusAuthHost")
        let metadata = bundle.resourceURL?.appendingPathComponent("XodusAuthHost.json")
        let hasExecutable = FileManager.default.fileExists(atPath: executable.path)
        let hasMetadata = metadata.map { FileManager.default.fileExists(atPath: $0.path) } == true
        if !hasExecutable && !hasMetadata {
            guard bundle.bundleURL.pathExtension.lowercased() != "app" else {
                throw ManagementError.nativeAuthHostUnavailable
            }
            return nil
        }
        guard hasExecutable, hasMetadata, let metadata,
              metadata.isFileURL, metadata.standardizedFileURL.path == metadata.path,
              metadata.resolvingSymlinksInPath().path == metadata.path,
              let bytes = try? readMetadata(metadata),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: bytes),
              Set(object.keys) == ["version", "sha256", "sourceCommit"],
              case .integer(1) = object["version"], case .string(let hash) = object["sha256"],
              case .string(let source) = object["sourceCommit"],
              source.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              expectedSourceCommit == nil || expectedSourceCommit == source,
              bytes == Data("{\"sha256\": \"\(hash)\", \"sourceCommit\": \"\(source)\", \"version\": 1}\n".utf8) else {
            throw ManagementError.nativeAuthHostUnavailable
        }
        return Self(executable: executable, sha256: hash)
    }

    private static func readMetadata(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ManagementError.backendUnavailable }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
              before.st_size > 0, before.st_size <= 1024 else { throw ManagementError.backendUnavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: 1025) ?? Data()
        var after = stat()
        guard bytes.count == before.st_size, fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode,
              before.st_uid == after.st_uid, before.st_nlink == after.st_nlink,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ManagementError.backendUnavailable
        }
        return bytes
    }
}
