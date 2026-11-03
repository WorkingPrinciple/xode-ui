// SPDX-License-Identifier: GPL-3.0-only
import XCTest

@testable import XodusPreview

final class StorageProbeChecks: XCTestCase {
    @MainActor
    func testStorageLocationAndWorkerReservationChecks() async throws {
        try await InstalledGameChecks.storageLocationChecks { passed, message in
            XCTAssertTrue(passed, message)
        }
    }
}
