// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum GameStorageProbeError: Error, LocalizedError {
    case pending, timedOut

    var errorDescription: String? {
        switch self {
        case .pending: "A storage check is still waiting for its drive. Reconnect the drive and try again."
        case .timedOut: "The drive didn't respond in time. Reconnect it before checking again."
        }
    }
}

@MainActor
final class GameStorageProbe {
    private(set) var activeReads = 0
    private(set) var activeKeys: Set<String> = []

    func read<Value: Sendable>(timeout: Duration = .seconds(15), key: String? = nil,
                              _ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let expires = ContinuousClock.now.advanced(by: timeout)
        try Task.checkCancellation()
        if let key, activeKeys.contains(key) { throw GameStorageProbeError.pending }
        while activeReads >= 4 {
            try Task.checkCancellation()
            if let key, activeKeys.contains(key) { throw GameStorageProbeError.pending }
            guard ContinuousClock.now < expires else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < expires else { throw GameStorageProbeError.timedOut }
        activeReads += 1
        if let key { activeKeys.insert(key) }
        let completion = StorageReadCompletion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let deadline = Task {
                    do { try await Task.sleep(until: expires, clock: .continuous) }
                    catch { return }
                    completion.cancel(with: GameStorageProbeError.timedOut)
                }
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try operation()
                }
                completion.installWorker(worker)
                Task {
                    let result = await worker.result
                    activeReads -= 1
                    if let key { activeKeys.remove(key) }
                    deadline.cancel()
                    completion.resolve(result)
                }
            }
        } onCancel: {
            completion.cancel(with: CancellationError())
        }
    }
}

// Cancelling a Swift task cannot interrupt a blocked filesystem syscall. Keep
// its bounded worker slot reserved until it returns, but release the UI waiter.
private final class StorageReadCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var worker: Task<Value, Error>?

    func installWorker(_ worker: Task<Value, Error>) {
        lock.lock()
        self.worker = worker
        let cancelled = result != nil
        lock.unlock()
        if cancelled { worker.cancel() }
    }

    func cancel(with error: Error) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .failure(error)
        let continuation = continuation
        self.continuation = nil
        let worker = worker
        worker?.cancel()
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
