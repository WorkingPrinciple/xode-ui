// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

/// Exercises `DownloadQueueController` end-to-end against a controllable in-memory engine:
/// FIFO promotion under a single slot, progress forwarding, pause (frees the slot, keeps
/// partial files), resume (requeues behind the running job), cancel, and natural completion.
/// No real install script or backend is started.
@MainActor
enum DownloadQueueChecks {
    /// A deterministic `InstallQueueDriver` double. Each run suspends until the test resolves
    /// it (complete/fail) or the controller stops it, so intermediate queue states can be
    /// asserted without timing races.
    actor Engine {
        private struct Run {
            let onProgress: @Sendable (InstallActivity, InstallProgress) async -> Void
            let continuation: CheckedContinuation<InstallEvent, Never>
        }
        private var runs: [String: Run] = [:]
        private(set) var startOrder: [String] = []
        private(set) var stopOrder: [String] = []

        func begin(_ runID: String,
                   _ onProgress: @escaping @Sendable (InstallActivity, InstallProgress) async -> Void) async -> InstallEvent {
            startOrder.append(runID)
            return await withCheckedContinuation { continuation in
                runs[runID] = Run(onProgress: onProgress, continuation: continuation)
            }
        }
        func emit(_ runID: String, _ activity: InstallActivity, _ progress: InstallProgress) async {
            await runs[runID]?.onProgress(activity, progress)
        }
        func complete(_ runID: String) { resolve(runID, .complete) }
        func failRun(_ runID: String, code: Int) { resolve(runID, .fail(code: code)) }
        func stop(_ runID: String) { stopOrder.append(runID); resolve(runID, .cancel) }

        private func resolve(_ runID: String, _ event: InstallEvent) {
            guard let run = runs.removeValue(forKey: runID) else { return }
            run.continuation.resume(returning: event)
        }
        var activeRuns: [String] { startOrder.filter { runs[$0] != nil } }
        var starts: [String] { startOrder }
        var stops: [String] { stopOrder }
    }

    struct Driver: InstallQueueDriver {
        let engine: Engine
        func run(runID: String, job: InstallJob, destination: String,
                 onProgress: @escaping @Sendable (InstallActivity, InstallProgress) async -> Void) async -> InstallEvent {
            await engine.begin(runID, onProgress)
        }
        func stop(runID: String) async { await engine.stop(runID) }
    }

    /// A driver whose `stop` lands too late to interrupt the run: it models the race where the
    /// engine already finished on disk, so the in-flight run still resolves with its natural
    /// terminal and the stop request is a no-op.
    struct LateStopDriver: InstallQueueDriver {
        let engine: Engine
        func run(runID: String, job: InstallJob, destination: String,
                 onProgress: @escaping @Sendable (InstallActivity, InstallProgress) async -> Void) async -> InstallEvent {
            await engine.begin(runID, onProgress)
        }
        func stop(runID: String) async { /* engine already finishing; stop lands too late */ }
    }

    static func run(check: (Bool, String) -> Void) async throws {
        let engine = Engine()
        let controller = DownloadQueueController(driver: Driver(engine: engine), maxConcurrent: 1)

        func settle(_ condition: @escaping () async -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await condition()) {
                guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        let a = controller.enqueue(productID: "9NBLGGH1234A", title: "Alpha", destination: "/games/Alpha")
        let b = controller.enqueue(productID: "9NBLGGH1234B", title: "Bravo", destination: "/games/Bravo")
        try await settle { await engine.activeRuns.count == 1 }
        check(controller.job(id: a)?.phase == .preparing, "First queued job claims the single slot")
        check(controller.job(id: b)?.phase == .queued, "Second job waits behind the running one")
        check(controller.jobs.map(\.id) == [a, b], "Queue keeps FIFO order")

        let runA = await engine.activeRuns.first ?? ""
        await engine.emit(runA, .downloading, InstallProgress(bytesDone: 50, bytesTotal: 100)!)
        try await settle { controller.job(id: a)?.phase == .downloading }
        check(controller.job(id: a)?.progress?.fraction == 0.5, "Engine progress reaches the active job")
        check(controller.job(id: b)?.phase == .queued, "Progress on one job does not disturb a waiting job")

        controller.pause(a)
        check(controller.job(id: a)?.phase == .paused, "An active job pauses")
        try await settle { await engine.stops.contains(runA) }
        check(await engine.stops.contains(runA), "Pausing stops the engine run so partial files are kept")
        try await settle { controller.job(id: b)?.phase == .preparing }
        check(controller.job(id: b)?.phase == .preparing, "Pausing frees the slot and promotes the next job")

        controller.resume(a)
        check(controller.job(id: a)?.phase == .queued, "Resume returns a paused job to the queue")
        try await settle { controller.job(id: a)?.phase == .queued }
        check(await engine.activeRuns.count == 1, "Resume does not exceed the concurrency limit")

        let runB = await engine.activeRuns.first ?? ""
        await engine.complete(runB)
        try await settle { controller.job(id: b)?.phase == .completed }
        check(controller.job(id: b)?.phase == .completed, "A running job completes on a successful engine result")
        try await settle { controller.job(id: a)?.phase == .preparing }
        check(controller.job(id: a)?.phase == .preparing, "A requeued job restarts once the slot frees")

        let runA2 = await engine.activeRuns.first ?? ""
        check(runA2 != runA, "A resumed run uses a fresh engine run id")
        controller.cancel(a)
        check(controller.job(id: a)?.phase == .cancelled, "A running job cancels")
        try await settle { await engine.stops.contains(runA2) }
        check(await engine.stops.contains(runA2), "Cancelling stops the active engine run")

        controller.clearFinished()
        check(controller.jobs.isEmpty, "Clearing finished jobs empties a fully terminal queue")

        // A natural engine failure surfaces as a failed job carrying the exit code.
        let c = controller.enqueue(productID: "9NBLGGH1234C", title: "Charlie", destination: "/games/Charlie")
        try await settle { await engine.activeRuns.count == 1 }
        let runC = await engine.activeRuns.first ?? ""
        await engine.failRun(runC, code: 11)
        try await settle { controller.job(id: c)?.phase == .failed }
        check(controller.job(id: c)?.failureCode == 11, "A failed engine result records the exit code on the job")

        // Race: the engine finishes naturally at the instant the user taps Pause. The stop
        // request arrives too late (the run already resolved with .complete), so the controller
        // must let that natural terminal win instead of stranding the job in `paused` — otherwise
        // a later resume would re-install an already-installed title.
        let raceEngine = Engine()
        let raceController = DownloadQueueController(driver: LateStopDriver(engine: raceEngine), maxConcurrent: 1)
        let x = raceController.enqueue(productID: "9NBLGGH1234X", title: "Xray", destination: "/games/Xray")
        try await settle { await raceEngine.activeRuns.count == 1 }
        let runX = await raceEngine.activeRuns.first ?? ""
        raceController.pause(x)
        check(raceController.job(id: x)?.phase == .paused, "Pause is recorded while the engine run is still open")
        await raceEngine.complete(runX)
        try await settle { raceController.job(id: x)?.phase == .completed }
        check(raceController.job(id: x)?.phase == .completed,
              "A natural completion delivered after a late pause wins, so the job is not stranded paused")
    }
}
