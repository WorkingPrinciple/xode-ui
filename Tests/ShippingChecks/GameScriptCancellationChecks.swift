// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import CryptoKit
import Foundation
import XCTest
import XodusManagement
@testable import XodusPreview

final class GameScriptCancellationChecks: XCTestCase {
    func testAlreadyCancelledTaskDoesNotReachLaunchPreparation() async {
        let paths = GameScriptPaths(scripts: URL(fileURLWithPath: "/no-such-ode-cancellation-script"),
                                    processed: URL(fileURLWithPath: "/no-such-ode-cancellation-receipts"),
                                    logs: URL(fileURLWithPath: "/no-such-ode-cancellation-logs"),
                                    games: URL(fileURLWithPath: "/no-such-ode-cancellation-games"),
                                    journal: URL(fileURLWithPath: "/no-such-ode-cancellation-journal"))
        let runner = GameScriptRunner(paths: paths)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(command: .check, runID: InstalledGamesController.runID(),
                                        arguments: ["FIXTURE00001"])
        }
        do {
            _ = try await operation.value
            XCTFail("An already cancelled task must not return a result")
        } catch is CancellationError {
        } catch {
            XCTFail("An already cancelled task reached script preparation: \(error)")
        }
    }

    func testCancellationJoinsEachOwnedChildAndRunnerCanBeReused() async throws {
        let files = FileManager.default
        let resolvedTemporaryPath = try XCTUnwrap(realpath(files.temporaryDirectory.path, nil))
        defer { free(resolvedTemporaryPath) }
        let root = URL(fileURLWithPath: String(cString: resolvedTemporaryPath), isDirectory: true)
            .appendingPathComponent("OdeScriptCancellation-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer {
            do { try files.removeItem(at: root) }
            catch { XCTFail("Could not remove owned cancellation fixture: \(error)") }
        }
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let processed = root.appendingPathComponent("processed", isDirectory: true)
        let markers = root.appendingPathComponent("markers", isDirectory: true)
        for directory in [scripts, processed, markers] {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
        }
        let script = scripts.appendingPathComponent(GameScriptCommand.check.file)
        try Data("""
        #!/bin/bash
        set -euo pipefail
        run="$1"
        product="$2"
        if [ "$run" = "repair" ] || [ "$run" = "launch" ]; then
            run="${6##*/}"
            exec /usr/bin/python3 - "$run" '\(markers.path)' <<'PY'
        import os, pathlib, signal, sys, time
        run, directory = sys.argv[1:]
        markers = pathlib.Path(directory)
        deadline = time.monotonic() + 3
        def cleanup(signum, frame):
            descriptor = os.open(markers / (run + ".signals"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            os.write(descriptor, b"TERM\\n")
            os.close(descriptor)
            while not (markers / (run + ".release")).exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            sys.exit(14)
        signal.signal(signal.SIGTERM, cleanup)
        (markers / (run + ".started")).write_text("started\\n")
        temporary = markers / (run + ".pid.tmp")
        temporary.write_text(str(os.getpid()))
        temporary.rename(markers / (run + ".pid"))
        while time.monotonic() < deadline:
            time.sleep(0.01)
        sys.exit(1)
        PY
        fi
        umask 077
        printf 'started\\n' > '\(markers.path)'/"$run.started"
        if [ "$product" = "FIXTURE00002" ]; then
            umask 077
            printf '0\\n' > '\(processed.path)'/"$run.status"
            printf '{}\\n' > '\(processed.path)'/"$run.result.json"
            exit 0
        fi
        if [ "$product" = "FIXTURE00003" ]; then
            cancelled() {
                printf 'TERM\\n' >> '\(markers.path)'/"$run.signals"
                while [ ! -e '\(markers.path)'/"$run.release" ] && [ "$SECONDS" -lt 3 ]; do
                    /bin/sleep 0.01
                done
                umask 077
                printf '14\\n' > '\(processed.path)'/"$run.status"
                exit 14
            }
            trap cancelled TERM
        fi
        printf '%s\\n' "$$" > '\(markers.path)'/"$run.pid.tmp"
        /bin/mv '\(markers.path)'/"$run.pid.tmp" '\(markers.path)'/"$run.pid"
        if [ "$product" = "FIXTURE00003" ]; then
            while [ "$SECONDS" -lt 3 ]; do /bin/sleep 0.01; done
            exit 1
        fi
        exec /bin/sleep 3
        """.utf8).write(to: script)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let paths = GameScriptPaths(scripts: scripts, processed: processed, logs: root,
                                    games: root.appendingPathComponent("games"),
                                    journal: root.appendingPathComponent("journal.json"))
        try GameScriptFiles.checkPath(script)
        XCTAssertEqual(try GameScriptFiles.script(.check, paths: paths), script)
        let runner = GameScriptRunner(paths: paths)

        let cancelledRunID = InstalledGamesController.runID()
        let cancelledBeforeEntry = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(command: .check, runID: cancelledRunID, arguments: ["FIXTURE00002"])
        }
        do {
            _ = try await cancelledBeforeEntry.value
            XCTFail("An already cancelled task launched the valid child")
        } catch is CancellationError {
        } catch {
            XCTFail("Pre-cancelled valid execution returned an unexpected error: \(error)")
        }
        XCTAssertFalse(files.fileExists(atPath: markers.appendingPathComponent(cancelledRunID + ".started").path))
        XCTAssertFalse(files.fileExists(atPath: processed.appendingPathComponent(cancelledRunID + ".status").path))

        let pendingRunID = InstalledGamesController.runID()
        await runner.cancel(runID: pendingRunID)
        let pendingOutcome = try await runner.run(command: .check, runID: pendingRunID, arguments: ["FIXTURE00002"])
        XCTAssertEqual(pendingOutcome.code, 14)
        XCTAssertFalse(files.fileExists(atPath: markers.appendingPathComponent(pendingRunID + ".started").path))

        func child(_ runID: String, product: String = "FIXTURE00002") -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, runID, product]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }

        let deniedRunID = InstalledGamesController.runID()
        let deniedLaunch = GameScriptProcess()
        deniedLaunch.cancel()
        XCTAssertFalse(try deniedLaunch.start(child(deniedRunID)))
        XCTAssertFalse(files.fileExists(atPath: markers.appendingPathComponent(deniedRunID + ".started").path))

        let heldRunID = InstalledGamesController.runID()
        let heldLaunch = GameScriptProcess()
        let ready = expectation(description: "Detached launch has not committed")
        let releaseLaunch = AsyncStream<Void>.makeStream()
        let heldChild = child(heldRunID)
        let heldOperation = Task {
            try await withTaskCancellationHandler {
                try await Task.detached {
                    ready.fulfill()
                    for await _ in releaseLaunch.stream { break }
                    return try heldLaunch.start(heldChild)
                }.value
            } onCancel: {
                heldLaunch.cancel()
            }
        }
        await fulfillment(of: [ready], timeout: 2)
        heldOperation.cancel()
        releaseLaunch.continuation.yield()
        releaseLaunch.continuation.finish()
        let heldStarted = try await heldOperation.value
        XCTAssertFalse(heldStarted, "Task cancellation accepted before commit must prevent the actual child launch")
        XCTAssertFalse(files.fileExists(atPath: markers.appendingPathComponent(heldRunID + ".started").path))

        let committedRunID = InstalledGamesController.runID()
        let committedLaunch = GameScriptProcess()
        let committedChild = child(committedRunID, product: "FIXTURE00001")
        let committedExit = AsyncStream<Void>.makeStream()
        committedChild.terminationHandler = { _ in
            committedExit.continuation.yield()
            committedExit.continuation.finish()
        }
        XCTAssertTrue(try committedLaunch.start(committedChild))
        let committedPID = committedChild.processIdentifier
        committedLaunch.cancel()
        committedLaunch.cancel()
        await Task.detached {
            for await _ in committedExit.stream { break }
        }.value
        let committedProbe = kill(committedPID, 0)
        let committedErrno = errno
        XCTAssertEqual(committedProbe, -1, "Cancellation after commit must terminate the actual committed child")
        XCTAssertEqual(committedErrno, ESRCH)

        for iteration in 0..<32 {
            let runID = InstalledGamesController.runID()
            let marker = markers.appendingPathComponent(runID + ".pid")
            let operation = Task {
                try await runner.run(command: .check, runID: runID,
                                     arguments: [iteration == 0 ? "FIXTURE00003" : "FIXTURE00001"])
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !files.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard files.fileExists(atPath: marker.path) else {
                operation.cancel()
                do {
                    _ = try await operation.value
                    XCTFail("The owned fixture returned without reporting its process")
                } catch {
                    XCTFail("The owned fixture did not start: \(error)")
                }
                return
            }
            let text = try String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = try XCTUnwrap(Int32(text))
            let signals = markers.appendingPathComponent(runID + ".signals")
            if iteration == 0 {
                await runner.cancel(runID: runID)
                let signalled = ContinuousClock.now.advanced(by: .seconds(2))
                while !files.fileExists(atPath: signals.path), ContinuousClock.now < signalled {
                    try await Task.sleep(for: .milliseconds(2))
                }
                XCTAssertTrue(files.fileExists(atPath: signals.path), "The owned child must observe the first cancellation")
                await runner.cancel(runID: runID)
            }
            operation.cancel()
            if iteration == 0 {
                try Data().write(to: markers.appendingPathComponent(runID + ".release"))
            }
            do {
                _ = try await operation.value
                XCTFail("Cancellation returned a success-shaped result")
            } catch is CancellationError {
            } catch {
                XCTFail("Cancellation returned an unexpected error: \(error)")
            }
            let result = kill(pid, 0)
            let error = errno
            XCTAssertEqual(result, -1, "The runner returned before its owned process exited")
            XCTAssertEqual(error, ESRCH)
            if iteration == 0 {
                XCTAssertEqual(try String(contentsOf: signals, encoding: .utf8), "TERM\n",
                               "Task cancellation and repeated runner cancellation must signal the owned child only once")
            }
        }

        let nativeExecutable = script.standardizedFileURL.resolvingSymlinksInPath()
        let nativeIdentity = NativeAuthHostBinding(executable: nativeExecutable,
            sha256: SHA256.hash(data: try Data(contentsOf: script)).map { String(format: "%02x", $0) }.joined())
        _ = try nativeIdentity.validatedArguments()
        let nativeConfiguration = BackendConfiguration(executable: nativeExecutable,
            stateDirectory: root.appendingPathComponent("unused-management"), executableIdentity: nativeIdentity)
        for (kind, runnerFirst) in [("repair", true), ("launch", true), ("repair", false), ("launch", false)] {
            let native = NativeGameLifecycle()
            let nativeRunID = InstalledGamesController.runID()
            let nativeMarker = markers.appendingPathComponent(nativeRunID + ".pid")
            let nativeSignals = markers.appendingPathComponent(nativeRunID + ".signals")
            let nativeRelease = markers.appendingPathComponent(nativeRunID + ".release")
            let operation = Task { @MainActor in
                try await native.run(configuration: nativeConfiguration, accountHash: String(repeating: "a", count: 64),
                    operation: kind, product: "FIXTURE00001", gameDirectory: root,
                    runID: nativeRunID, stateRoot: root.appendingPathComponent(nativeRunID))
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !files.fileExists(atPath: nativeMarker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard files.fileExists(atPath: nativeMarker.path) else {
                operation.cancel()
                do { _ = try await operation.value }
                catch { XCTFail("Native owned child did not reach readiness: \(error)") }
                return
            }
            let nativePID = try XCTUnwrap(Int32(try String(contentsOf: nativeMarker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            if runnerFirst { await native.cancel() }
            else { operation.cancel() }
            let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !files.fileExists(atPath: nativeSignals.path), ContinuousClock.now < cleanupDeadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertTrue(files.fileExists(atPath: nativeSignals.path), "Native cancellation reaches the real child's cleanup")
            let nativeRunning = await native.isRunning
            XCTAssertTrue(nativeRunning, "The native child remains owned during delayed cleanup")
            await native.cancel()
            operation.cancel()
            let duplicateDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
            while ContinuousClock.now < duplicateDeadline {
                if try String(contentsOf: nativeSignals, encoding: .utf8).split(separator: "\n").count > 1 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try Data().write(to: nativeRelease)
            do {
                _ = try await operation.value
                XCTFail("Native cancellation must not require or accept a fabricated success receipt")
            } catch {
                if kind == "launch" {
                    XCTAssertTrue(error is NativeLifecycleCancellation,
                                  "Native launch retains launchStopped error mapping: \(error)")
                } else {
                    XCTAssertEqual(error as? GameScriptError, .failed(14),
                                   "Native repair retains cancellation error mapping")
                }
            }
            let nativeProbe = kill(nativePID, 0)
            let nativeErrno = errno
            XCTAssertEqual(nativeProbe, -1, "Native run returns only after its owned child exits")
            XCTAssertEqual(nativeErrno, ESRCH)
            XCTAssertEqual(try String(contentsOf: nativeSignals, encoding: .utf8), "TERM\n",
                           "Repeated native cancel plus task cancellation sends one TERM during cleanup")
        }

        let outcome = try await runner.run(command: .check, runID: InstalledGamesController.runID(),
                                           arguments: ["FIXTURE00002"])
        XCTAssertEqual(outcome.code, 0)
        XCTAssertEqual(outcome.result, Data("{}\n".utf8))
    }
}
