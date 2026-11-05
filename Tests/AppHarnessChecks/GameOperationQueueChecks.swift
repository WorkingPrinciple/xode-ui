// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import XodusPreview

final class GameOperationQueueChecks: XCTestCase {
    @MainActor func testInstallRepairQueueAndRecovery() async throws {
        var assertions = 0
        // Foundation can standardize /private/tmp to the /tmp symlink for existing folders.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Xodus-GameOperations-\(UUID().uuidString)", isDirectory: true)
        try await GameOperationChecks.run(root: root) { condition, message in
            assertions += 1
            XCTAssertTrue(condition, message)
        }
        XCTAssertGreaterThan(assertions, 0)
        print("\(assertions) existing game operation assertions completed.")
    }

    @MainActor func testDownloadQueueOrderingAndCancellation() async throws {
        var assertions = 0
        try await DownloadQueueChecks.run { condition, message in
            assertions += 1
            XCTAssertTrue(condition, message)
        }
        XCTAssertGreaterThan(assertions, 0)
        print("\(assertions) existing download queue assertions completed.")
    }

}
