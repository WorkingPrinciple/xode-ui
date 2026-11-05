// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import XodusPreview

final class InstalledGameRefreshChecks: XCTestCase {
    @MainActor
    func testBackgroundDiscoveryAndStorageGuards() async throws {
        try await InstalledGameChecks.storageLocationChecks { condition, name in
            XCTAssertTrue(condition, name)
        }
    }
}
