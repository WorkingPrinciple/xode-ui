// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation
import XCTest
@testable import XodusPreview

final class CalimochoVerificationCancellationChecks: XCTestCase {
    private static func waitForEntry(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 5)
    }

    func testCancellationJoinsVerifierBeforeCleanupAndAllowsRetry() async throws {
        let owner = CalimochoVerificationWork()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let task = Task {
            do {
                try await owner.run { cancellation in
                    entered.signal()
                    release.wait()
                    try cancellation.check()
                }
                XCTFail("Canceled verification returned success")
            } catch is CancellationError {
                try await owner.run(cancelWithParent: false) { _ in
                    try FileManager.default.removeItem(at: staging)
                }
            }
        }
        let started = await Task.detached { Self.waitForEntry(entered) }.value
        XCTAssertEqual(started, .success)
        task.cancel()
        XCTAssertTrue(owner.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        release.signal()
        try await task.value
        XCTAssertFalse(owner.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let retried = try await owner.run { cancellation in
            try cancellation.check()
            return 7
        }
        XCTAssertEqual(retried, 7)
    }

    func testCleanupRemainsOwnedEvenWhenParentIsCanceled() async throws {
        let owner = CalimochoVerificationWork()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await owner.run(cancelWithParent: false) { _ in
                entered.signal()
                release.wait()
            }
        }
        let started = await Task.detached { Self.waitForEntry(entered) }.value
        XCTAssertEqual(started, .success)
        task.cancel()
        XCTAssertTrue(owner.isRunning)
        release.signal()
        try await task.value
        XCTAssertFalse(owner.isRunning)
    }

    func testDigestAndArchiveParsingCheckCancellationBeforeWork() throws {
        let cancellation = CalimochoVerificationCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try CalimochoReleaseEngines.fileDigest(URL(fileURLWithPath: "/Unavailable/archive"),
            checkCancellation: cancellation.check)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try CalimochoReleaseInstallService.inspectArchive(Data(), engineName: "unused",
            expandedLimit: 1, checkCancellation: cancellation.check)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try CalimochoReleaseEngines.verify(.release06,
            root: URL(fileURLWithPath: "/Unavailable/engines"),
            checkCancellation: cancellation.check)) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCancellationBetweenRealHashChunksLeavesInputUntouchedAndRetryable() throws {
        let input = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("hash-cancellation-\(UUID().uuidString)")
        let data = Data(repeating: 0x61, count: 3_145_728)
        try data.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        var checkpoints = 0
        XCTAssertThrowsError(try CalimochoReleaseEngines.fileDigest(input, checkCancellation: {
            checkpoints += 1
            if checkpoints == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checkpoints, 3)
        XCTAssertEqual(try Data(contentsOf: input), data)
        XCTAssertEqual(try CalimochoReleaseEngines.fileDigest(input), CalimochoReleaseEngines.digest(data))
    }

    @MainActor
    func testQuitRefusesWhileVerifierRemainsOwnedThenCanRetry() async throws {
        let owner = CalimochoVerificationWork()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let suite = "io.github.dragoshont.ode.quit-preservation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = CalimochoDefaultEngineController(defaults: defaults, verification: owner)
        let work = Task {
            try await owner.run { cancellation in
                entered.signal()
                release.wait()
                try cancellation.check()
            }
        }
        let started = await Task.detached { Self.waitForEntry(entered) }.value
        XCTAssertEqual(started, .success)
        let clock = ContinuousClock.now
        let refused = await controller.shutdownForApplicationTermination()
        XCTAssertFalse(refused)
        XCTAssertLessThan(clock.duration(to: .now), .seconds(2))
        XCTAssertTrue(owner.isRunning)
        release.signal()
        try await work.value
        let stopped = await controller.shutdownForApplicationTermination()
        XCTAssertTrue(stopped)
        controller.resumeAfterTerminationRefusal()
        XCTAssertFalse(controller.isWorking)
    }

    @MainActor
    func testCoordinatorDoesNotDisconnectSessionWhenEngineRefusesQuit() async throws {
        let owner = CalimochoVerificationWork()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let controller = CalimochoDefaultEngineController(verification: owner)
        let session = LiveSession()
        var phaseChanges = 0
        let observation = session.$phase.dropFirst().sink { _ in phaseChanges += 1 }
        defer { observation.cancel() }
        let work = Task {
            try await owner.run { _ in
                entered.signal()
                release.wait()
            }
        }
        let started = await Task.detached { Self.waitForEntry(entered) }.value
        XCTAssertEqual(started, .success)
        let coordinator = ApplicationTerminationCoordinator()
        let refused = await coordinator.shutdown(session: session, runtime: nil, calimochoEngine: controller)
        XCTAssertFalse(refused)
        XCTAssertTrue(owner.isRunning)
        XCTAssertFalse(session.applicationTerminating)
        XCTAssertEqual(phaseChanges, 0, "A refused quit must not retire the live management session")

        release.signal()
        try await work.value
        let closed = await coordinator.shutdown(session: session, runtime: nil, calimochoEngine: controller)
        XCTAssertTrue(closed)
        XCTAssertGreaterThan(phaseChanges, 0, "A later successful quit should disconnect the session")
    }
}
