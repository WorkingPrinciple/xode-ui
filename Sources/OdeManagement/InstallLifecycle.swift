// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Client-side install/download lifecycle control states.
///
/// This is a deterministic, pure state machine that governs the local queue (pause,
/// resume, cancel, progress). It is intentionally distinct from the backend wire
/// protocol (`CatalogJob` / `CatalogJobState`) which models engine-reported job state and
/// is owned by the package-type / engine-routing work. This type never performs IO.
public enum InstallPhase: String, Codable, CaseIterable, Sendable {
    case queued, preparing, downloading, paused, verifying, configuring, completed, cancelled, failed

    /// A phase from which the job can make no further transitions.
    public var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }

    /// Whether the phase actively occupies an engine concurrency slot.
    public var occupiesSlot: Bool {
        switch self {
        case .preparing, .downloading, .verifying, .configuring: true
        case .queued, .paused, .completed, .cancelled, .failed: false
        }
    }

    public var canPause: Bool { occupiesSlot }
    public var canResume: Bool { self == .paused }
    public var canCancel: Bool { !isTerminal }
}

/// The fine-grained activity an engine reports while a job occupies a slot.
///
/// Mirrors the engine's reported install phases (preparing → downloading → verifying →
/// configuring). `done`/`failed` engine phases are modelled as `complete`/`fail` events.
public enum InstallActivity: String, Codable, CaseIterable, Sendable {
    case preparing, downloading, verifying, configuring

    public var phase: InstallPhase {
        switch self {
        case .preparing: .preparing
        case .downloading: .downloading
        case .verifying: .verifying
        case .configuring: .configuring
        }
    }
}

/// Validated byte progress for an install job. Carried alongside the phase (not inside the
/// phase enum) so the transition function stays finite and pure.
public struct InstallProgress: Equatable, Sendable, Codable {
    public let bytesDone: Int64
    public let bytesTotal: Int64?

    public init?(bytesDone: Int64, bytesTotal: Int64?) {
        guard bytesDone >= 0, bytesTotal.map({ $0 >= bytesDone }) ?? true else { return nil }
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    /// Completion fraction in `0...1` when a positive total is known.
    public var fraction: Double? {
        guard let total = bytesTotal, total > 0 else { return nil }
        return Double(bytesDone) / Double(total)
    }
}

/// An input to the lifecycle state machine.
public enum InstallEvent: Equatable, Sendable {
    /// The queue granted this job a slot; the engine should begin.
    case start
    /// The engine reported current activity and progress.
    case report(InstallActivity, InstallProgress)
    /// The user paused an actively running job (engine stops, partial files are kept).
    case pause
    /// The user resumed a paused job (re-enters the queue; engine resumes from partial files).
    case resume
    /// The job was cancelled.
    case cancel
    /// The engine finished successfully.
    case complete
    /// The engine failed with the given exit code.
    case fail(code: Int)
}

/// A single install/download job tracked by the queue.
public struct InstallJob: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let productID: String
    public let title: String
    public var phase: InstallPhase
    public var progress: InstallProgress?
    public var failureCode: Int?

    public init(id: UUID = UUID(), productID: String, title: String,
                phase: InstallPhase = .queued, progress: InstallProgress? = nil,
                failureCode: Int? = nil) {
        self.id = id
        self.productID = productID
        self.title = title
        self.phase = phase
        self.progress = progress
        self.failureCode = failureCode
    }
}

/// The pure lifecycle reducer. Every `(phase, event)` pair is defined; illegal or no-op
/// combinations return `nil`.
public enum InstallLifecycle {
    /// Pure, total transition function over phases. Returns `nil` for illegal transitions.
    public static func reduce(_ phase: InstallPhase, _ event: InstallEvent) -> InstallPhase? {
        switch phase {
        case .queued:
            switch event {
            case .start: return .preparing
            case .cancel: return .cancelled
            // A queued job has no engine slot yet, so it cannot report progress or terminate;
            // it must be promoted (`.start`) first. This mirrors `.paused`, which also rejects
            // `.report`, and keeps the slot accounting the single source of truth.
            case .report, .pause, .resume, .complete, .fail: return nil
            }
        case .preparing, .downloading, .verifying, .configuring:
            switch event {
            case .report(let activity, _): return activity.phase
            case .pause: return .paused
            case .cancel: return .cancelled
            case .complete: return .completed
            case .fail: return .failed
            case .start, .resume: return nil
            }
        case .paused:
            switch event {
            case .resume: return .queued
            case .cancel: return .cancelled
            // A paused job's engine run may still resolve on its own if the stop request
            // raced a natural terminal: honour both outcomes symmetrically so a finished
            // install is never re-run and a failed one is never silently retried.
            case .complete: return .completed
            case .fail: return .failed
            case .start, .report, .pause: return nil
            }
        case .completed, .cancelled, .failed:
            return nil
        }
    }

    /// Applies an event to a job, threading phase, progress and failure code. Returns `nil`
    /// when the transition is illegal (the job is left unchanged by the caller).
    public static func apply(_ job: InstallJob, _ event: InstallEvent) -> InstallJob? {
        guard let phase = reduce(job.phase, event) else { return nil }
        var updated = job
        updated.phase = phase
        switch event {
        case .report(_, let progress):
            updated.progress = progress
        case .fail(let code):
            updated.failureCode = code
        case .complete:
            if let total = job.progress?.bytesTotal {
                updated.progress = InstallProgress(bytesDone: total, bytesTotal: total)
            }
        case .start, .pause, .resume, .cancel:
            break
        }
        return updated
    }
}

/// An ordered queue of install jobs with bounded concurrency and deterministic FIFO
/// promotion. Pure value type; it decides *what* should run next but performs no IO.
public struct InstallQueue: Equatable, Sendable {
    public private(set) var jobs: [InstallJob]
    public let maxConcurrent: Int

    public init(maxConcurrent: Int = 1, jobs: [InstallJob] = []) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.jobs = jobs
    }

    /// Jobs currently occupying an engine slot.
    public var activeCount: Int { jobs.lazy.filter { $0.phase.occupiesSlot }.count }

    public func job(id: UUID) -> InstallJob? { jobs.first { $0.id == id } }

    /// Appends a new queued job (ignoring duplicate ids), then promotes. Returns the jobs
    /// that newly became active so the caller can launch the engine for them.
    @discardableResult
    public mutating func enqueue(_ job: InstallJob) -> [InstallJob] {
        guard !jobs.contains(where: { $0.id == job.id }) else { return [] }
        jobs.append(job)
        return promote()
    }

    /// Routes an event to one job, then promotes. Returns newly-activated jobs.
    @discardableResult
    public mutating func apply(_ event: InstallEvent, to id: UUID) -> [InstallJob] {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              let updated = InstallLifecycle.apply(jobs[index], event) else { return [] }
        jobs[index] = updated
        return promote()
    }

    /// Starts queued jobs in FIFO order until the concurrency limit is reached. Returns the
    /// jobs that transitioned into an active slot during this call.
    @discardableResult
    public mutating func promote() -> [InstallJob] {
        var started: [InstallJob] = []
        var index = 0
        while activeCount < maxConcurrent, index < jobs.count {
            if jobs[index].phase == .queued, let updated = InstallLifecycle.apply(jobs[index], .start) {
                jobs[index] = updated
                started.append(updated)
            }
            index += 1
        }
        return started
    }

    /// Removes terminal jobs from the queue.
    public mutating func prune() {
        jobs.removeAll { $0.phase.isTerminal }
    }
}
