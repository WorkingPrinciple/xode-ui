// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import XodusPreview

final class GameOperationPathConflictChecks: XCTestCase {
    func testCaseSensitiveVolumeKeepsDistinctDestinations() throws {
        try withVolume(caseSensitive: true) { volume in
            let upper = volume.appendingPathComponent("Game")
            let lower = volume.appendingPathComponent("game")
            try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: lower, withIntermediateDirectories: false)
            let record = record(at: upper)
            XCTAssertFalse(try record.conflicts(productID: "FIXTURE00002", destination: lower.path))
            XCTAssertFalse(try record.conflicts(productID: "FIXTURE00002",
                                                destination: lower.appendingPathComponent("future/child").path))
            XCTAssertFalse(try self.record(at: volume.appendingPathComponent("Future"))
                .conflicts(productID: "FIXTURE00002", destination: volume.appendingPathComponent("future").path))
            try assertOverlaps(record, at: upper, volume: volume)
            let journal = GameInstallQueueJournal(file: volume.appendingPathComponent("queue.json"))
            try journal.save([
                QueuedGameInstall(record: record, storageVolume: nil),
                QueuedGameInstall(record: self.record(at: lower, productID: "FIXTURE00002"), storageVolume: nil)
            ])
            XCTAssertEqual(try journal.load().count, 2)
        }
    }

    func testCaseInsensitiveVolumeRejectsCaseAliases() throws {
        try withVolume(caseSensitive: false) { volume in
            let upper = volume.appendingPathComponent("Game")
            let lower = volume.appendingPathComponent("game")
            try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: false)
            let record = record(at: upper)
            XCTAssertTrue(try record.conflicts(productID: "FIXTURE00002", destination: lower.path))
            XCTAssertTrue(try record.conflicts(productID: "FIXTURE00002",
                                               destination: lower.appendingPathComponent("future/child").path))
            XCTAssertTrue(try self.record(at: volume.appendingPathComponent("Future"))
                .conflicts(productID: "FIXTURE00002", destination: volume.appendingPathComponent("future").path))
            try assertOverlaps(record, at: upper, volume: volume)
            let journal = GameInstallQueueJournal(file: volume.appendingPathComponent("queue.json"))
            XCTAssertThrowsError(try journal.save([
                QueuedGameInstall(record: record, storageVolume: nil),
                QueuedGameInstall(record: self.record(at: lower, productID: "FIXTURE00002"), storageVolume: nil)
            ]))
        }
    }

    private func assertOverlaps(_ record: GameOperationRecord, at path: URL, volume: URL) throws {
        XCTAssertTrue(try record.conflicts(productID: "FIXTURE00002", destination: path.path))
        XCTAssertTrue(try record.conflicts(productID: "FIXTURE00002", destination: volume.path))
        XCTAssertTrue(try record.conflicts(productID: "FIXTURE00002",
                                           destination: path.appendingPathComponent("future/child").path))
        XCTAssertTrue(try record.conflicts(productID: record.productID, destination: nil))
        XCTAssertFalse(try record.conflicts(productID: "FIXTURE00002",
                                            destination: volume.appendingPathComponent("GameOther").path))
        let alias = volume.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: path)
        XCTAssertTrue(try record.conflicts(productID: "FIXTURE00002",
                                           destination: alias.appendingPathComponent("future/child").path))
        let futureAlias = volume.appendingPathComponent("future-alias")
        try FileManager.default.createSymbolicLink(at: futureAlias,
                                                   withDestinationURL: path.appendingPathComponent("future"))
        XCTAssertThrowsError(try record.conflicts(productID: "FIXTURE00002",
                                                 destination: futureAlias.appendingPathComponent("child").path))
        let file = volume.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        XCTAssertThrowsError(try record.conflicts(productID: "FIXTURE00002",
                                                 destination: file.appendingPathComponent("child").path))
        let journal = GameInstallQueueJournal(file: volume.appendingPathComponent("invalid-queue.json"))
        XCTAssertThrowsError(try journal.save([
            QueuedGameInstall(record: record, storageVolume: nil),
            QueuedGameInstall(record: self.record(at: file.appendingPathComponent("child"),
                                                  productID: "FIXTURE00002"), storageVolume: nil)
        ]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.file.path))
    }

    private func record(at path: URL, productID: String = "FIXTURE00001") -> GameOperationRecord {
        GameOperationRecord(id: InstalledGamesController.runID(), kind: .install, productID: productID,
                            title: "Path conflict check", destination: path.path, installedID: nil)
    }

    private func withVolume(caseSensitive: Bool, body: (URL) throws -> Void) throws {
        let files = FileManager.default
        let scratch = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/PathConflict-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let image = scratch.appendingPathComponent("volume.sparseimage")
        let mount = scratch.appendingPathComponent("mounted")
        var attached = false
        defer {
            do {
                if attached { try diskImage(["detach", mount.path]) }
                try files.removeItem(at: scratch)
            } catch {
                XCTFail("Could not detach/clean the owned path-check volume at \(scratch.path): \(error)")
            }
        }
        try diskImage(["create", "-size", "256m", "-fs", caseSensitive ? "Case-sensitive APFS" : "APFS",
                       "-volname", "REQ184Paths", "-type", "SPARSE", "-o", image.path])
        try diskImage(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        attached = true
        let values = try mount.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        XCTAssertEqual(values.volumeSupportsCaseSensitiveNames, caseSensitive)
        print("Real APFS volume \(mount.path), caseSensitive=\(String(describing: values.volumeSupportsCaseSensitiveNames))")
        try body(mount)
    }

    private func diskImage(_ arguments: [String]) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        child.arguments = arguments
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        try child.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        print("hdiutil \(arguments.joined(separator: " ")): \(text)")
        guard child.terminationStatus == 0 else {
            throw NSError(domain: "REQ184OwnedDiskImage", code: Int(child.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
    }
}
