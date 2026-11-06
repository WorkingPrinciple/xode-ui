// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import XodusPreview

final class GameInstallLocationPathChecks: XCTestCase {
    func testValidatedFilesystemPathRoundTripsWithoutRewriting() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Xodus-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let location = try GameInstallLocation(folder: root)
        XCTAssertEqual(location.folder, root.path)
        let restored = try XCTUnwrap(GameInstallLocation.decode(JSONEncoder().encode(location)))
        XCTAssertEqual(restored, location)
        XCTAssertEqual(restored.folder, root.path)
    }

    func testInvalidPathsAndSymlinksRemainRejected() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Xodus-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try GameInstallLocation(folder: link))
        XCTAssertThrowsError(try GameInstallLocation(folder: root.appendingPathComponent("missing")))
        XCTAssertThrowsError(try GameInstallLocation(folder: XCTUnwrap(URL(string: "https://example.invalid/games"))))
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertThrowsError(try GameInstallLocation(folder: file))
        for path in ["/", "relative", "/private//tmp", "/private/tmp/../tmp",
                     "/private/tmp/./games", "/private/tmp/\0games",
                     "/" + String(repeating: "a", count: 4096)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "folder": path, "volume": ["path": "/"]
            ])
            XCTAssertThrowsError(try GameInstallLocation.decode(data), path)
        }
    }
}
