// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import XodusManagement
@testable import XodusPreview

final class LibraryActivityProjectionChecks: XCTestCase {
    @MainActor
    func testProductionQueueRestorationAndCancellation() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
            .appendingPathComponent(".build/LibraryActivity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove owned queue-check directory: \(error)") }
        }
        let paths = GameScriptPaths(scripts: root.appendingPathComponent("scripts"),
            processed: root.appendingPathComponent("processed"), logs: root.appendingPathComponent("logs"),
            games: root.appendingPathComponent("games"), journal: root.appendingPathComponent("operation.json"))
        let entries = [GameOperationRecord.Kind.install, .repair, .resume].enumerated().map { index, kind in
            QueuedGameInstall(record: GameOperationRecord(id: InstalledGamesController.runID(), kind: kind,
                productID: "FIXTURE0000\(index)", title: "Queue \(index)",
                destination: root.appendingPathComponent("game-\(index)").path,
                installedID: kind == .install ? nil : UUID(),
                nativeAccountHash: kind == .resume ? String(repeating: "a", count: 64) : nil),
                storageVolume: nil)
        }
        let journal = GameInstallQueueJournal(file: paths.journal.appendingPathExtension("queue.json"))
        try journal.save(entries)
        let installed = InstalledGamesController(store: InstalledGameStore(file: root.appendingPathComponent("installed.json")))
        let controller = GameOperationsController(installed: installed, paths: paths)
        await controller.restore()
        XCTAssertEqual(controller.queuedInstalls.count, 3)
        for entry in entries {
            let activity = LibraryActivity.resolve(productID: entry.record.productID,
                operations: .init(controller))
            XCTAssertEqual(activity?.kind, LibraryActivity.Kind(entry.record.kind))
            XCTAssertEqual(activity?.state, .paused)
            XCTAssertNil(activity?.fraction)
        }
        XCTAssertNil(LibraryActivity.resolve(productID: "UNRELATED001", operations: .init(controller)))
        await controller.cancelQueuedInstall(entries[1].id)
        XCTAssertNil(LibraryActivity.resolve(productID: entries[1].record.productID, operations: .init(controller)))
        XCTAssertEqual(try journal.load().map(\.id), [entries[0].id, entries[2].id])
        XCTAssertNil(controller.operation)
        XCTAssertFalse(installed.mutationActive)
    }

    @MainActor
    func testActiveLegacyJobWinsOverLaterQueuedDuplicate() {
        var active = InstallJob(productID: "FIXTURE00001", title: "Active")
        active.phase = .downloading
        active.progress = InstallProgress(bytesDone: 42, bytesTotal: 100)
        let queued = InstallJob(productID: active.productID, title: "Later duplicate")
        for jobs in [[active, queued], [queued, active]] {
            let activity = LibraryActivity.resolve(productID: active.productID, operations: .init(), jobs: jobs)
            XCTAssertEqual(activity?.fraction, 0.42)
            XCTAssertEqual(activity?.title, "Installing 42%")
        }
    }

    @MainActor
    func testActiveLegacyJobWinsOverPausedDuplicate() {
        let active = InstallJob(productID: "FIXTURE00001", title: "Active",
                                phase: .downloading, progress: InstallProgress(bytesDone: 42, bytesTotal: 100))
        let paused = InstallJob(productID: active.productID, title: "Paused duplicate", phase: .paused)
        for jobs in [[active, paused], [paused, active]] {
            let activity = LibraryActivity.resolve(productID: active.productID, operations: .init(), jobs: jobs)
            XCTAssertEqual(activity?.title, "Installing 42%")
            XCTAssertEqual(LibraryActivity.resolve(productID: active.productID, operations: .init(),
                                                   jobs: jobs, stoppingJobIDs: [active.id])?.state, .stopping)
        }
        XCTAssertEqual(LibraryActivity.resolve(productID: active.productID, operations: .init(),
                                               jobs: [paused])?.state, .paused)
    }

    @MainActor
    func testTransitionsAndNativeRendering() async throws {
        try await LibraryActivityChecks.run { condition, name in
            XCTAssertTrue(condition, name)
        }
    }
}
