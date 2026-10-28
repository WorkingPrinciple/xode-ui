// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

actor PrivateChannel {
    private let descriptor: Int32
    private var stopped = false
    private var reading = false
    private var writing = false

    init(descriptor: Int32) throws {
        var type: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &size) == 0, type == SOCK_STREAM else {
            throw HostFailure.protocolInvalid
        }
        var address = sockaddr_un()
        var addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let addressResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressSize)
            }
        }
        guard addressResult == 0, address.sun_family == sa_family_t(AF_UNIX),
              addressSize <= MemoryLayout<sockaddr_un>.size,
              withUnsafeBytes(of: address.sun_path, { $0.allSatisfy { $0 == 0 } }) else {
            throw HostFailure.protocolInvalid
        }
        let peerResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(descriptor, $0, &addressSize)
            }
        }
        guard peerResult == 0, address.sun_family == sa_family_t(AF_UNIX),
              addressSize <= MemoryLayout<sockaddr_un>.size,
              withUnsafeBytes(of: address.sun_path, { $0.allSatisfy { $0 == 0 } }) else {
            throw HostFailure.protocolInvalid
        }
        let owned = dup(descriptor)
        guard owned >= 0 else { throw HostFailure.channelClosed }
        let flags = fcntl(owned, F_GETFL)
        var noSignal: Int32 = 1
        guard flags >= 0, fcntl(owned, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(owned, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(owned, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(owned)
            throw HostFailure.channelClosed
        }
        self.descriptor = owned
    }

    deinit { Darwin.close(descriptor) }

    func read(deadline: ContinuousClock.Instant) async throws -> Data {
        guard !stopped, !reading else { throw HostFailure.channelClosed }
        reading = true
        defer { reading = false }
        let fd = descriptor
        let result = try await Task.detached {
            let header = try Self.readExactly(4, descriptor: fd, deadline: deadline)
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0 && length <= PrivateJSON.maximumBytes else { throw HostFailure.protocolInvalid }
            return try Self.readExactly(Int(length), descriptor: fd, deadline: deadline)
        }.value
        guard !stopped else { throw HostFailure.channelClosed }
        return result
    }

    func write(_ data: Data, deadline: ContinuousClock.Instant,
               afterDelivery: (@Sendable () async -> Void)? = nil) async throws {
        guard !stopped, !writing, !data.isEmpty, data.count <= PrivateJSON.maximumBytes else {
            throw HostFailure.protocolInvalid
        }
        writing = true
        defer { writing = false }
        let length = UInt32(data.count)
        let framed = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
                           UInt8((length >> 8) & 255), UInt8(length & 255)]) + data
        let fd = descriptor
        try await Task.detached {
            var offset = 0
            while offset < framed.count {
                try Self.ready(fd, events: Int16(POLLOUT), deadline: deadline)
                let sent = framed.withUnsafeBytes { buffer in
                    Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), framed.count - offset)
                }
                if sent > 0 { offset += sent }
                else if sent < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                else { throw HostFailure.channelClosed }
            }
            await afterDelivery?()
        }.value
        guard !stopped else { throw HostFailure.channelClosed }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    private static func ready(_ descriptor: Int32, events: Int16,
                              deadline: ContinuousClock.Instant) throws {
        while true {
            guard ContinuousClock.now < deadline else { throw HostFailure.deadlineExpired }
            var descriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&descriptor, 1, 50)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw HostFailure.channelClosed }
            if result == 0 { continue }
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw HostFailure.channelClosed
            }
        }
    }

    private static func readExactly(_ count: Int, descriptor: Int32,
                                    deadline: ContinuousClock.Instant) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try ready(descriptor, events: Int16(POLLIN), deadline: deadline)
            let received = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if received > 0 { offset += received }
            else if received < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            else { throw HostFailure.channelClosed }
        }
        return data
    }
}
