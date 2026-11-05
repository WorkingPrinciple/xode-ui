// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Cancellation is cooperative between filesystem calls, not an interruption of kernel I/O.
final class CalimochoVerificationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false

    func cancel() {
        lock.lock()
        canceled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = canceled
        lock.unlock()
        if value { throw CancellationError() }
        try Task.checkCancellation()
    }
}

final class CalimochoVerificationWork: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count != 0
    }

    private func started() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    private func finished() {
        lock.lock()
        count -= 1
        lock.unlock()
    }

    func run<Value: Sendable>(cancelWithParent: Bool = true,
        _ operation: @escaping @Sendable (CalimochoVerificationCancellation) throws -> Value) async throws -> Value {
        let cancellation = CalimochoVerificationCancellation()
        started()
        let worker = Task.detached(priority: .utility) { [self] in
            defer { finished() }
            if cancelWithParent { try cancellation.check() }
            return try operation(cancellation)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            if cancelWithParent {
                cancellation.cancel()
                worker.cancel()
            }
        }
    }
}
