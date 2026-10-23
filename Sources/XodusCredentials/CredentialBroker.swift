// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation
import Security

public enum CredentialFailure: Error, Sendable {
    case invalid, denied, unavailable, timeout, migrationRequired, keychain(OSStatus)
}

public enum CredentialOperation: UInt8, Sendable {
    case read = 1, write, delete, migrate
}

public struct CredentialRequest: Sendable {
    public let id: UUID
    public let operation: CredentialOperation
    public let presenceOnly: Bool
    public let value: String?

    public init(operation: CredentialOperation, presenceOnly: Bool = false, value: String? = nil) {
        id = UUID()
        self.operation = operation
        self.presenceOnly = presenceOnly
        self.value = value
    }

    public func encoded() throws -> Data {
        let token = value.map { Data($0.utf8) } ?? Data()
        guard (!presenceOnly || operation == .read),
              (operation == .write ? !token.isEmpty : token.isEmpty),
              token.count <= CredentialWire.maximumToken else { throw CredentialFailure.invalid }
        return Data([1, operation.rawValue, presenceOnly ? 1 : 0])
            + Data(id.uuidString.utf8) + token
    }

    public init(data: Data) throws {
        guard data.count >= 39, data.count <= CredentialWire.maximumToken + 39,
              data[0] == 1, let op = CredentialOperation(rawValue: data[1]),
              data[2] <= 1,
              let uuid = UUID(uuidString: String(decoding: data[3..<39], as: UTF8.self)) else {
            throw CredentialFailure.invalid
        }
        id = uuid
        operation = op
        presenceOnly = data[2] == 1
        let token = data.subdata(in: 39..<data.count)
        guard (!presenceOnly || op == .read),
              (op == .write ? !token.isEmpty : token.isEmpty) else { throw CredentialFailure.invalid }
        if token.isEmpty { value = nil }
        else {
            guard let text = String(data: token, encoding: .utf8) else { throw CredentialFailure.invalid }
            value = text
        }
    }
}

public struct CredentialResponse: Sendable {
    public let id: UUID
    public let present: Bool
    public let migrationRequired: Bool
    public let legacyRetained: Bool
    public let value: String?
    public let status: OSStatus

    public init(id: UUID, present: Bool = false, migrationRequired: Bool = false, legacyRetained: Bool = false,
                value: String? = nil, status: OSStatus = errSecSuccess) {
        self.id = id
        self.present = present
        self.migrationRequired = migrationRequired
        self.legacyRetained = legacyRetained
        self.value = value
        self.status = status
    }

    public func encoded() throws -> Data {
        let token = value.map { Data($0.utf8) } ?? Data()
        guard token.count <= CredentialWire.maximumToken,
              token.isEmpty || (present && !migrationRequired && status == errSecSuccess) else {
            throw CredentialFailure.invalid
        }
        let bits = UInt32(bitPattern: status)
        guard !legacyRetained || (present && !migrationRequired) else { throw CredentialFailure.invalid }
        return Data([1, present ? 1 : 0, (migrationRequired ? 1 : 0) | (legacyRetained ? 2 : 0)])
            + Data(id.uuidString.utf8)
            + Data([UInt8(bits >> 24), UInt8((bits >> 16) & 255), UInt8((bits >> 8) & 255), UInt8(bits & 255)])
            + token
    }

    public init(data: Data, request: CredentialRequest) throws {
        guard data.count >= 43, data.count <= CredentialWire.maximumToken + 43,
              data[0] == 1, data[1] <= 1, data[2] <= 3,
              UUID(uuidString: String(decoding: data[3..<39], as: UTF8.self)) == request.id else {
            throw CredentialFailure.invalid
        }
        id = request.id
        present = data[1] == 1
        migrationRequired = data[2] & 1 != 0
        legacyRetained = data[2] & 2 != 0
        status = Int32(bitPattern: data[39..<43].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let token = data.subdata(in: 43..<data.count)
        guard !migrationRequired || present,
              !legacyRetained || (present && !migrationRequired),
              token.isEmpty || (request.operation == .read && !request.presenceOnly
                                && present && !migrationRequired && status == errSecSuccess),
              request.operation != .read || request.presenceOnly || status != errSecSuccess
                || migrationRequired || (present == !token.isEmpty) else { throw CredentialFailure.invalid }
        if token.isEmpty { value = nil }
        else {
            guard let text = String(data: token, encoding: .utf8) else { throw CredentialFailure.invalid }
            value = text
        }
    }
}

public enum CredentialIdentity {
    public static let certificate = "6C5F1CD832A2B2842686245B4DEF219BB8B465B2"
    public static let app = "io.github.dragoshont.xodus"
    public static let broker = "io.github.dragoshont.xodus.credential-broker"

    public static func requirement(_ identifier: String) throws -> SecRequirement {
        var result: SecRequirement?
        let text = "identifier \"\(identifier)\" and certificate leaf = H\"\(certificate)\""
        guard SecRequirementCreateWithString(text as CFString, [], &result) == errSecSuccess,
              let result else { throw CredentialFailure.denied }
        return result
    }

    public static func authenticatePeer(_ descriptor: Int32) throws {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout<audit_token_t>.size else { throw CredentialFailure.denied }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else {
            throw CredentialFailure.denied
        }
        let data = withUnsafeBytes(of: token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: data] as CFDictionary,
                                            [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], try requirement(app)) == errSecSuccess else {
            throw CredentialFailure.denied
        }
    }

    public static func verifyFile(_ url: URL, sha256: String, bytes: Int) throws -> Data {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }), bytes > 0 else {
            throw CredentialFailure.unavailable
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0,
              info.st_nlink == 1, info.st_size == bytes,
              url.resolvingSymlinksInPath().path == url.path else { throw CredentialFailure.unavailable }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw CredentialFailure.unavailable
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate),
                                         try requirement(broker)) == errSecSuccess else {
            throw CredentialFailure.denied
        }
        var metadata: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &metadata) == errSecSuccess,
              let hash = (metadata as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            throw CredentialFailure.denied
        }
        return hash
    }

    public static func authenticateChild(_ pid: pid_t, expectedCodeHash: Data) throws {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary,
                                            [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], try requirement(broker)) == errSecSuccess else {
            throw CredentialFailure.denied
        }
        var staticCode: SecStaticCode?
        var metadata: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &metadata) == errSecSuccess,
              let hash = (metadata as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              hash == expectedCodeHash else { throw CredentialFailure.denied }
    }
}

public enum CredentialWire {
    public static let maximumToken = 128 * 1024
    private static let maximumFrame = maximumToken + 43

    public static func validateSocket(_ descriptor: Int32) throws {
        var type: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &size) == 0, type == SOCK_STREAM else {
            throw CredentialFailure.invalid
        }
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &length) }
        }
        guard result == 0, address.sun_family == sa_family_t(AF_UNIX),
              length <= MemoryLayout<sockaddr_un>.size,
              withUnsafeBytes(of: address.sun_path, { $0.allSatisfy { $0 == 0 } }) else {
            throw CredentialFailure.invalid
        }
        let flags = fcntl(descriptor, F_GETFL)
        var noSignal: Int32 = 1
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, size) == 0 else {
            throw CredentialFailure.unavailable
        }
    }

    public static func read(_ descriptor: Int32, deadline: ContinuousClock.Instant) throws -> Data {
        let header = try transfer(descriptor, data: Data(count: 4), reading: true, deadline: deadline)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximumFrame else { throw CredentialFailure.invalid }
        return try transfer(descriptor, data: Data(count: Int(count)), reading: true, deadline: deadline)
    }

    public static func write(_ data: Data, to descriptor: Int32, deadline: ContinuousClock.Instant) throws {
        guard !data.isEmpty, data.count <= maximumFrame else { throw CredentialFailure.invalid }
        let count = UInt32(data.count)
        let header = Data([UInt8(count >> 24), UInt8((count >> 16) & 255),
                           UInt8((count >> 8) & 255), UInt8(count & 255)])
        _ = try transfer(descriptor, data: header + data, reading: false, deadline: deadline)
    }

    private static func transfer(_ fd: Int32, data: Data, reading: Bool,
                                 deadline: ContinuousClock.Instant) throws -> Data {
        var result = data
        var offset = 0
        while offset < result.count {
            guard ContinuousClock.now < deadline else { throw CredentialFailure.timeout }
            var descriptor = pollfd(fd: fd, events: Int16(reading ? POLLIN : POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw CredentialFailure.unavailable }
            if ready == 0 { continue }
            guard descriptor.revents & descriptor.events != 0 else { throw CredentialFailure.unavailable }
            let remaining = result.count - offset
            let transferred = result.withUnsafeMutableBytes {
                if reading { return Darwin.read(fd, $0.baseAddress!.advanced(by: offset), remaining) }
                return Darwin.write(fd, $0.baseAddress!.advanced(by: offset), remaining)
            }
            if transferred > 0 { offset += transferred }
            else if transferred < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            else { throw CredentialFailure.unavailable }
        }
        return result
    }
}

public struct CredentialBrokerPin: Codable, Sendable {
    public let version: Int
    public let sha256: String
    public let bytes: Int

    public init(sha256: String, bytes: Int) { version = 1; self.sha256 = sha256; self.bytes = bytes }
}

private final class CredentialChild: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}

public struct CredentialBrokerClient: Sendable {
    public let executable: URL
    public let pin: CredentialBrokerPin
    public let arguments: [String]

    public init(executable: URL, pin: CredentialBrokerPin, arguments: [String] = []) {
        self.executable = executable
        self.pin = pin
        self.arguments = arguments
    }

    public func send(_ request: CredentialRequest) async throws -> CredentialResponse {
        let child = CredentialChild()
        return try await withTaskCancellationHandler {
            let response = try await Task.detached {
                try Task.checkCancellation()
                guard pin.version == 1 else { throw CredentialFailure.unavailable }
                let codeHash = try CredentialIdentity.verifyFile(executable, sha256: pin.sha256, bytes: pin.bytes)
                var sockets: [Int32] = [-1, -1]
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
                    throw CredentialFailure.unavailable
                }
                let local = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
                let remote = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
                defer { try? local.close(); try? remote.close(); child.cancel() }
                guard fcntl(sockets[0], F_SETFD, FD_CLOEXEC) == 0,
                      fcntl(sockets[1], F_SETFD, FD_CLOEXEC) == 0 else {
                    throw CredentialFailure.unavailable
                }
                try CredentialWire.validateSocket(sockets[0])
                child.process.executableURL = executable
                child.process.arguments = arguments
                child.process.standardInput = remote
                child.process.standardOutput = FileHandle.nullDevice
                child.process.standardError = FileHandle.nullDevice
                child.process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
                try child.start()
                try remote.close()
                try CredentialIdentity.authenticateChild(child.process.processIdentifier, expectedCodeHash: codeHash)
                let deadline = ContinuousClock.now.advanced(by: request.operation == .migrate ? .seconds(300) : .seconds(30))
                let response: CredentialResponse
                do {
                    try CredentialWire.write(request.encoded(), to: sockets[0], deadline: deadline)
                    response = try CredentialResponse(data: CredentialWire.read(sockets[0], deadline: deadline),
                                                      request: request)
                } catch {
                    let exitDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
                    while child.process.isRunning && ContinuousClock.now < exitDeadline { usleep(1_000) }
                    if !child.process.isRunning, child.process.terminationReason == .exit,
                       child.process.terminationStatus == 77 { throw CredentialFailure.denied }
                    throw error
                }
                try Task.checkCancellation()
                if response.status != errSecSuccess { throw CredentialFailure.keychain(response.status) }
                return response
            }.value
            try Task.checkCancellation()
            return response
        } onCancel: { child.cancel() }
    }
}
