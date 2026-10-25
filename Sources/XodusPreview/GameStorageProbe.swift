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
    private(set) var active = false

    func read<Value: Sendable>(timeout: Duration = .seconds(15),
                              _ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        guard !active else { throw GameStorageProbeError.pending }
        active = true
        let completion = StorageReadCompletion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let deadline = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    completion.resolve(.failure(GameStorageProbeError.timedOut))
                }
                Task {
                    let result = await Task.detached(priority: .utility, operation: operation).result
                    active = false
                    deadline.cancel()
                    completion.resolve(result)
                }
            }
        } onCancel: {
            completion.resolve(.failure(CancellationError()))
        }
    }
}

// Cancelling a Swift task cannot interrupt a blocked filesystem syscall. Keep
// its one worker reserved until it actually returns, but release the UI waiter.
private final class StorageReadCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

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
