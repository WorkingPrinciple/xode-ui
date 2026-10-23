// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

extension Checks {
    func installLifecycleChecks() throws {
        try transitionTableChecks()
        queuePromotionChecks()
        try updateDetectionChecks()
    }

    // MARK: - Pure transition table

    private func transitionTableChecks() throws {
        guard let rows = try fixture("install-lifecycle-transitions").array else {
            throw ManagementError.invalidPayload
        }
        let stub = InstallProgress(bytesDone: 10, bytesTotal: 100)!
        func event(_ name: String) -> InstallEvent? {
            switch name {
            case "start": return .start
            case "pause": return .pause
            case "resume": return .resume
            case "cancel": return .cancel
            case "complete": return .complete
            case "fail": return .fail(code: 13)
            case "report:preparing": return .report(.preparing, stub)
            case "report:downloading": return .report(.downloading, stub)
            case "report:verifying": return .report(.verifying, stub)
            case "report:configuring": return .report(.configuring, stub)
            default: return nil
            }
        }

        var covered: Set<String> = []
        for row in rows {
            guard let from = row["from"]?.string, let phase = InstallPhase(rawValue: from),
                  let name = row["event"]?.string, let event = event(name) else {
                throw ManagementError.invalidPayload
            }
            let expected: InstallPhase?
            switch row["to"] {
            case .some(.null), .none:
                expected = nil
            case .some(.string(let value)):
                guard let phase = InstallPhase(rawValue: value) else { throw ManagementError.invalidPayload }
                expected = phase
            default:
                throw ManagementError.invalidPayload
            }
            covered.insert("\(from)|\(name)")
            check(InstallLifecycle.reduce(phase, event) == expected,
                  "Lifecycle transition \(from) + \(name) -> \(expected?.rawValue ?? "nil")")
        }
        check(rows.count == 90, "Transition table enumerates every phase x event pair")
        check(covered.count == InstallPhase.allCases.count * 10,
              "Transition table exhaustively covers all \(InstallPhase.allCases.count) phases")

        // Progress and failure code are threaded by apply().
        let job = InstallJob(productID: "9NBLGGGGGGG1", title: "Fixture")
        check(InstallLifecycle.apply(job, .start)?.phase == .preparing, "apply advances a queued job to preparing")
        let downloading = InstallLifecycle.apply(
            InstallJob(productID: "9NBLGGGGGGG1", title: "Fixture", phase: .downloading), .report(.downloading, stub))
        check(downloading?.progress == stub, "apply records reported progress")
        let paused = InstallLifecycle.apply(
            InstallJob(productID: "9NBLGGGGGGG1", title: "Fixture", phase: .downloading, progress: stub), .pause)
        check(paused?.phase == .paused && paused?.progress == stub, "Pausing retains progress for resume")
        let failed = InstallLifecycle.apply(
            InstallJob(productID: "9NBLGGGGGGG1", title: "Fixture", phase: .verifying), .fail(code: 11))
        check(failed?.phase == .failed && failed?.failureCode == 11, "apply records the failure code")
        let completed = InstallLifecycle.apply(
            InstallJob(productID: "9NBLGGGGGGG1", title: "Fixture", phase: .configuring, progress: stub), .complete)
        check(completed?.phase == .completed && completed?.progress?.bytesDone == 100,
              "Completion fills progress to the known total")
        check(InstallLifecycle.apply(job, .pause) == nil, "Illegal transition leaves the job unchanged")
        check(InstallProgress(bytesDone: -1, bytesTotal: nil) == nil
              && InstallProgress(bytesDone: 10, bytesTotal: 5) == nil,
              "Invalid progress is rejected")
    }

    // MARK: - Queue concurrency and FIFO promotion

    private func queuePromotionChecks() {
        let a = InstallJob(productID: "9NBLGGGGGGG1", title: "A")
        let b = InstallJob(productID: "9NBLGGGGGGG2", title: "B")
        let c = InstallJob(productID: "9NBLGGGGGGG3", title: "C")

        var single = InstallQueue(maxConcurrent: 1)
        check(single.enqueue(a).map(\.id) == [a.id], "First enqueued job starts immediately")
        check(single.enqueue(b).isEmpty && single.enqueue(c).isEmpty, "Extra jobs wait for a free slot")
        check(single.activeCount == 1 && single.job(id: a.id)?.phase == .preparing
              && single.job(id: b.id)?.phase == .queued, "Only one job runs at concurrency 1")

        check(single.apply(.complete, to: a.id).map(\.id) == [b.id], "Completing a job promotes the next in FIFO order")
        check(single.job(id: b.id)?.phase == .preparing && single.job(id: c.id)?.phase == .queued,
              "Promotion preserves queue order")

        check(single.apply(.pause, to: b.id).map(\.id) == [c.id], "Pausing frees a slot and promotes the next job")
        check(single.job(id: b.id)?.phase == .paused && single.job(id: c.id)?.phase == .preparing,
              "A paused job yields its slot to the next queued job")

        check(single.apply(.resume, to: b.id).isEmpty, "Resuming while the slot is busy only requeues")
        check(single.job(id: b.id)?.phase == .queued, "Resume returns a paused job to the queue")

        check(single.apply(.cancel, to: c.id).map(\.id) == [b.id], "Cancelling the active job promotes the requeued one")
        check(single.job(id: b.id)?.phase == .preparing && single.job(id: c.id)?.phase == .cancelled,
              "Cancelled jobs stay terminal while the next starts")

        _ = single.apply(.complete, to: b.id)
        single.prune()
        check(single.jobs.isEmpty, "Pruning clears terminal jobs")

        var dual = InstallQueue(maxConcurrent: 2)
        dual.enqueue(a)
        dual.enqueue(b)
        check(dual.enqueue(c).isEmpty && dual.activeCount == 2, "Concurrency 2 runs two jobs and queues the third")
        check(dual.job(id: c.id)?.phase == .queued, "The third job waits at concurrency 2")
        check(dual.apply(.complete, to: a.id).map(\.id) == [c.id], "Freeing one of two slots promotes exactly one job")
        check(dual.enqueue(a).isEmpty, "Duplicate job ids are ignored")
    }

    // MARK: - Update detection

    private func updateDetectionChecks() throws {
        guard let rows = try fixture("update-detection").array else { throw ManagementError.invalidPayload }
        check(rows.count == 18, "Update-detection corpus covers equal, newer, older and malformed versions")
        for row in rows {
            guard let name = row["name"]?.string, let installed = row["installed"]?.string,
                  let expectedRaw = row["expected"]?.string, let expected = UpdateStatus(rawValue: expectedRaw) else {
                throw ManagementError.invalidPayload
            }
            let available = row["available"]?.string
            check(UpdateDetector.status(installed: installed, available: available) == expected,
                  "Update detection \(name) -> \(expectedRaw)")
        }

        check(GameVersion(parsing: "1.0.0.0")! < GameVersion(parsing: "1.0.0.1")!, "Version ordering is lexicographic")
        check(!(GameVersion(parsing: "1.2.3.4")! < GameVersion(parsing: "1.2.3.4")!), "Equal versions are not ordered")
        check(GameVersion(parsing: "1.0.0")  == nil && GameVersion(parsing: "1.0.0.x") == nil
              && GameVersion(parsing: "1.0.0.70000") == nil, "Malformed versions fail to parse")

        let status = UpdateDetector.resolve(
            installed: [(id: "a", version: "1.0.0.0"), (id: "b", version: "2.0.0.0"), (id: "c", version: "1.0.0.0")],
            available: ["a": "1.0.0.1", "b": "2.0.0.0"])
        check(status["a"] == .updateAvailable && status["b"] == .upToDate && status["c"] == .unknown,
              "Batch resolution maps each installed item to its status")
    }
}
