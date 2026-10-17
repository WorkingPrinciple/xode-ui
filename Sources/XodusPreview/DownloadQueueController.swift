// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation
import XodusManagement

/// Executes the engine side of a single queued install and reports progress back to the
/// queue. Abstracting this boundary lets `DownloadQueueController` be driven by the real
/// game-script engine in the shipping app and by a deterministic double in checks, without
/// the orchestration logic (ordering, pause/resume/cancel) knowing which is in use.
///
/// `run` returns the *natural* terminal event for a run that finished on its own
/// (`.complete` or `.fail`). When a run is interrupted by `stop(runID:)`, the returned value
/// is ignored by the controller — the controller has already recorded the user's intent
/// (paused or cancelled) and never promotes an interrupted terminal over it.
protocol InstallQueueDriver: Sendable {
    func run(runID: String, job: InstallJob, destination: String,
             onProgress: @escaping @Sendable (InstallActivity, InstallProgress) async -> Void) async -> InstallEvent
    func stop(runID: String) async
}

/// Real orchestration layer over the pure `InstallQueue` state machine.
///
/// Owns the ordered queue and the live engine runs. All queue mutations go through the pure
/// `InstallQueue`/`InstallLifecycle` reducers; this controller only performs the IO the
/// reducers intentionally avoid: launching, stopping and observing engine runs. Concurrency
/// defaults to one, matching the single-mutation guarantee the rest of the app relies on.
@MainActor
final class DownloadQueueController: ObservableObject {
    @Published private(set) var queue: InstallQueue

    private let driver: InstallQueueDriver
    private let makeRunID: @Sendable () -> String
    /// Per-job payload needed to (re)launch a run. Retained until the job is pruned.
    private var destinations: [UUID: String] = [:]
    /// The run id currently executing for a job. A fresh id is minted on every (re)launch so a
    /// superseded run's late terminal can be recognised and discarded.
    private var activeRunID: [UUID: String] = [:]
    private var runTasks: [UUID: Task<Void, Never>] = [:]

    init(driver: InstallQueueDriver, maxConcurrent: Int = 1,
         makeRunID: @escaping @Sendable () -> String = { InstalledGamesController.runID() }) {
        self.queue = InstallQueue(maxConcurrent: maxConcurrent)
        self.driver = driver
        self.makeRunID = makeRunID
    }

    /// The jobs in queue order (active, queued, paused and — until pruned — terminal).
    var jobs: [InstallJob] { queue.jobs }

    func job(id: UUID) -> InstallJob? { queue.job(id: id) }

    /// Enqueues a new install and promotes if a slot is free. Returns the new job id.
    @discardableResult
    func enqueue(productID: String, title: String, destination: String) -> UUID {
        let job = InstallJob(productID: productID, title: title)
        destinations[job.id] = destination
        launch(queue.enqueue(job))
        return job.id
    }

    /// Pauses an actively running job: the engine stops (partial files are kept) and a freed
    /// slot is handed to the next queued job.
    func pause(_ id: UUID) {
        guard queue.job(id: id)?.phase.canPause == true else { return }
        let runID = activeRunID[id]
        let promoted = queue.apply(.pause, to: id)
        if let runID { Task { await driver.stop(runID: runID) } }
        launch(promoted)
    }

    /// Resumes a paused job by returning it to the queue; it restarts when a slot is free and
    /// the engine resumes from the kept partial files.
    func resume(_ id: UUID) {
        guard queue.job(id: id)?.phase.canResume == true else { return }
        launch(queue.apply(.resume, to: id))
    }

    /// Cancels a job in any non-terminal phase, stopping the engine if it is running.
    func cancel(_ id: UUID) {
        guard let phase = queue.job(id: id)?.phase, phase.canCancel else { return }
        let runID = activeRunID[id]
        let promoted = queue.apply(.cancel, to: id)
        if phase.occupiesSlot, let runID { Task { await driver.stop(runID: runID) } }
        launch(promoted)
    }

    /// Drops terminal jobs from the visible queue.
    func clearFinished() {
        for job in queue.jobs where job.phase.isTerminal { forget(job.id) }
        queue.prune()
    }

    // MARK: - Engine wiring

    private func launch(_ started: [InstallJob]) {
        for job in started {
            guard let destination = destinations[job.id] else { continue }
            let runID = makeRunID()
            activeRunID[job.id] = runID
            let snapshot = job
            runTasks[job.id] = Task { [weak self] in
                guard let self else { return }
                let terminal = await self.driver.run(
                    runID: runID, job: snapshot, destination: destination,
                    onProgress: { [weak self] activity, progress in
                        await self?.report(job.id, runID: runID, activity: activity, progress: progress)
                    })
                await self.finish(job.id, runID: runID, terminal: terminal)
            }
        }
    }

    private func report(_ id: UUID, runID: String, activity: InstallActivity, progress: InstallProgress) {
        // Discard progress from a superseded or already-interrupted run.
        guard activeRunID[id] == runID, queue.job(id: id)?.phase.occupiesSlot == true else { return }
        queue.apply(.report(activity, progress), to: id)
    }

    private func finish(_ id: UUID, runID: String, terminal: InstallEvent) {
        // A newer run (resume) always supersedes a stale terminal, so a run that is no longer
        // the active one is discarded outright.
        guard activeRunID[id] == runID else { return }
        activeRunID[id] = nil
        runTasks[id] = nil
        // A run's *natural* terminal (.complete/.fail) reflects work the engine already did on
        // disk, so it must win even if a pause/cancel raced in just after the engine finished —
        // otherwise a completed install would show as paused and be re-driven on resume. An
        // interrupted terminal (.cancel, emitted when the engine is stopped) stays absorbed: the
        // user's paused/cancelled intent is already recorded and the job keeps its partial files.
        let isNaturalTerminal: Bool
        switch terminal {
        case .complete, .fail: isNaturalTerminal = true
        default: isNaturalTerminal = false
        }
        guard queue.job(id: id)?.phase.occupiesSlot == true || isNaturalTerminal else { return }
        launch(queue.apply(terminal, to: id))
    }

    private func forget(_ id: UUID) {
        runTasks[id]?.cancel()
        runTasks[id] = nil
        activeRunID[id] = nil
        destinations[id] = nil
    }
}
