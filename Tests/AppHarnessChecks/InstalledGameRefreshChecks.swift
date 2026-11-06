// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
@testable import XodusPreview

final class InstalledGameRefreshChecks: XCTestCase {
    @MainActor
    func testBackgroundFailurePreservesVerifiedReadinessButAuthoritativeChangesApply() {
        let controller = InstalledGamesController()
        let game = InstalledGame(id: UUID(), title: "Readiness transition", identityName: "", version: "",
            storeId: "9N9C8SV0S16W", folder: "", launcher: "", importedAt: .distantPast)
        func result(success: Bool, status: NativeInstallationStatus.Status?) -> NativeInstallationStatus {
            NativeInstallationStatus(version: 1, operation: "install-status", product: game.storeId,
                runID: UUID().uuidString, gameDirectory: game.folder, logDirectory: "", resultPath: "",
                success: success, exitCode: success ? 0 : 1, errorCode: success ? nil : "RESOURCE_BUSY",
                status: status, reasonCode: nil, detail: nil, filesTotal: nil, contentID: nil)
        }
        let complete = result(success: true, status: .complete)
        controller.recordNativeInspectionResult(complete, for: game, background: true)
        XCTAssertEqual(controller.installationStatuses[game.id], complete)
        let eligible = controller.launchableIDs.contains(game.id)
        controller.recordNativeInspectionFailure(game.id, background: true, message: "Drive check timed out")
        XCTAssertEqual(controller.installationStatuses[game.id], complete)
        XCTAssertEqual(controller.launchableIDs.contains(game.id), eligible)
        XCTAssertEqual(controller.installationErrors[game.id], "Drive check timed out")
        controller.recordNativeInspectionResult(result(success: false, status: nil), for: game, background: true)
        XCTAssertEqual(controller.installationStatuses[game.id], complete)
        XCTAssertEqual(controller.launchableIDs.contains(game.id), eligible)
        XCTAssertFalse(controller.checkingInstallations.contains(game.id))
        controller.recordNativeInspectionResult(result(success: true, status: .partial), for: game, background: true)
        XCTAssertEqual(controller.installationStatuses[game.id]?.action, .resume)
        XCTAssertFalse(controller.launchableIDs.contains(game.id))
        controller.recordNativeInspectionResult(complete, for: game, background: true)
        controller.recordNativeInspectionResult(result(success: true, status: .missing), for: game, background: true)
        XCTAssertEqual(controller.installationStatuses[game.id]?.action, .install)
        controller.recordNativeInspectionResult(complete, for: game, background: true)
        controller.recordNativeInspectionFailure(game.id, background: false, message: "Explicit check failed")
        XCTAssertNil(controller.installationStatuses[game.id])
        XCTAssertFalse(controller.launchableIDs.contains(game.id))
    }

    @MainActor
    func testBackgroundDiscoveryAndStorageGuards() async throws {
        try await InstalledGameChecks.storageLocationChecks { condition, name in
            XCTAssertTrue(condition, name)
        }
    }
}
