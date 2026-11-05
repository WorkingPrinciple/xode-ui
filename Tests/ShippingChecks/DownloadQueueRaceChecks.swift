// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import XodusManagement
@testable import XodusPreview

private actor DelayedStopDriver: InstallQueueDriver {
    private var runs: [String: CheckedContinuation<InstallEvent, Never>] = [:]
    private var starts: [String] = []
    private var stops: [String] = []

    func run(runID: String, job: InstallJob, destination: String,
             onProgress: @escaping @Sendable (InstallActivity, InstallProgress) async -> Void) async -> InstallEvent {
        starts.append(runID)
        return await withCheckedContinuation { runs[runID] = $0 }
    }

    func stop(runID: String) async { stops.append(runID) }
    func started() -> [String] { starts }
    func stopped() -> [String] { stops }

    func finish(_ runID: String, as event: InstallEvent) {
        runs.removeValue(forKey: runID)?.resume(returning: event)
    }

    func finishAll() {
        for continuation in runs.values { continuation.resume(returning: .cancel) }
        runs.removeAll()
    }
}

@MainActor
final class DownloadQueueRaceChecks: XCTestCase {
    private func waitFor(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func testCancellationWaitsForNaturalCompletionBeforePromoting() async {
        let driver = DelayedStopDriver()
        let queue = DownloadQueueController(driver: driver)
        let first = queue.enqueue(productID: "FIRST", title: "First", destination: "/first")
        let second = queue.enqueue(productID: "SECOND", title: "Second", destination: "/second")
        guard await waitFor({ await driver.started().count == 1 }),
              let runID = await driver.started().first else {
            XCTFail("First driver run did not start")
            await driver.finishAll()
            return
        }

        queue.cancel(first)
        XCTAssertEqual(queue.job(id: second)?.phase, .queued,
                       "A new job must wait until the cancelled driver run has actually ended")
        if let job = queue.job(id: first) {
            XCTAssertEqual(DownloadQueueRow(queue: queue, job: job).statusLabel, "Cancelling...")
        } else { XCTFail("The pending cancellation disappeared") }
        queue.clearFinished()
        XCTAssertNotNil(queue.job(id: first), "An in-flight cancellation cannot be pruned")
        let stopRequested = await waitFor { await driver.stopped().contains(runID) }
        let startsBeforeCompletion = await driver.started().count
        XCTAssertTrue(stopRequested)
        XCTAssertEqual(startsBeforeCompletion, 1)

        await driver.finish(runID, as: .complete)
        let completed = await waitFor { queue.job(id: first)?.phase == .completed }
        XCTAssertTrue(completed, "An already completed install must not be reported as cancelled")
        let promoted = await waitFor { await driver.started().count == 2 }
        XCTAssertTrue(promoted)
        await driver.finishAll()
    }

    func testPauseWaitsForStoppedRunBeforePromoting() async {
        let driver = DelayedStopDriver()
        let queue = DownloadQueueController(driver: driver)
        let first = queue.enqueue(productID: "FIRST", title: "First", destination: "/first")
        let second = queue.enqueue(productID: "SECOND", title: "Second", destination: "/second")
        guard await waitFor({ await driver.started().count == 1 }),
              let runID = await driver.started().first else {
            XCTFail("First driver run did not start")
            await driver.finishAll()
            return
        }

        queue.pause(first)
        XCTAssertEqual(queue.job(id: second)?.phase, .queued,
                       "Pausing must not release the active slot before the engine stops")
        if let job = queue.job(id: first) {
            XCTAssertEqual(DownloadQueueRow(queue: queue, job: job).statusLabel, "Pausing...")
        } else { XCTFail("The pending pause disappeared") }
        let stopRequested = await waitFor { await driver.stopped().contains(runID) }
        let startsBeforeCompletion = await driver.started().count
        XCTAssertTrue(stopRequested)
        XCTAssertEqual(startsBeforeCompletion, 1)

        await driver.finish(runID, as: .cancel)
        let paused = await waitFor { queue.job(id: first)?.phase == .paused }
        let promoted = await waitFor { await driver.started().count == 2 }
        XCTAssertTrue(paused)
        XCTAssertTrue(promoted)
        await driver.finishAll()
    }

    func testNaturalFailureAfterCancellationRemainsVisible() async {
        let driver = DelayedStopDriver()
        let queue = DownloadQueueController(driver: driver)
        let first = queue.enqueue(productID: "FIRST", title: "First", destination: "/first")
        guard await waitFor({ await driver.started().count == 1 }),
              let runID = await driver.started().first else {
            XCTFail("Driver run did not start")
            await driver.finishAll()
            return
        }

        queue.cancel(first)
        await driver.finish(runID, as: .fail(code: 11))
        let failed = await waitFor { queue.job(id: first)?.phase == .failed }
        XCTAssertTrue(failed, "A natural failure must not be hidden by a late cancellation")
        XCTAssertEqual(queue.job(id: first)?.failureCode, 11)
        await driver.finishAll()
    }

    func testPauseCanBeUpgradedToCancellationWithoutASecondStop() async {
        let driver = DelayedStopDriver()
        let queue = DownloadQueueController(driver: driver)
        let first = queue.enqueue(productID: "FIRST", title: "First", destination: "/first")
        let second = queue.enqueue(productID: "SECOND", title: "Second", destination: "/second")
        guard await waitFor({ await driver.started().count == 1 }),
              let runID = await driver.started().first else {
            XCTFail("First driver run did not start")
            await driver.finishAll()
            return
        }

        queue.pause(first)
        queue.cancel(first)
        XCTAssertEqual(queue.pendingStops[first], .cancel)
        XCTAssertEqual(queue.job(id: second)?.phase, .queued)
        let stopRequested = await waitFor { await driver.stopped().count == 1 }
        XCTAssertTrue(stopRequested)
        await driver.finish(runID, as: .cancel)
        let cancelled = await waitFor { queue.job(id: first)?.phase == .cancelled }
        let promoted = await waitFor { await driver.started().count == 2 }
        let stops = await driver.stopped()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(promoted)
        XCTAssertEqual(stops, [runID])
        await driver.finishAll()
    }

    func testCancellingQueuedJobDoesNotStopActiveJob() async {
        let driver = DelayedStopDriver()
        let queue = DownloadQueueController(driver: driver)
        _ = queue.enqueue(productID: "FIRST", title: "First", destination: "/first")
        let second = queue.enqueue(productID: "SECOND", title: "Second", destination: "/second")
        guard await waitFor({ await driver.started().count == 1 }) else {
            XCTFail("First driver run did not start")
            await driver.finishAll()
            return
        }

        queue.cancel(second)
        let stops = await driver.stopped()
        XCTAssertEqual(queue.job(id: second)?.phase, .cancelled)
        XCTAssertTrue(stops.isEmpty)
        await driver.finishAll()
    }
}
