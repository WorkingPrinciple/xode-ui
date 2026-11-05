// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation
import XCTest
@testable import XodusPreview

final class InstallReviewIdentityChecks: XCTestCase {
    @MainActor func testStaleCallbacksPreserveReplacementReview() async {
        let operations = GameOperationsController(installed: InstalledGamesController())
        let game = PCGame(id: "FIXTURE00001", title: "Test game", artwork: nil)
        let first = GameInstallConsent(game: game, destination: URL(fileURLWithPath: "/tmp/ode-first"),
                                       freeBytes: 0, installedID: nil, nativeAccountHash: nil)
        let second = GameInstallConsent(game: game, destination: URL(fileURLWithPath: "/tmp/ode-second"),
                                        freeBytes: 0, installedID: nil, nativeAccountHash: nil)
        operations.installConsent = first
        let oldBinding = GameInstallSheet(operations: operations, reviewID: first.id).installConsentBinding
        let oldView = GameInstallConsentView(operations: operations, consent: first)
        XCTAssertEqual(oldBinding.wrappedValue?.id, first.id)
        var moved = first
        moved.destination = URL(fileURLWithPath: "/tmp/ode-first-moved")
        oldBinding.wrappedValue = moved
        XCTAssertEqual(oldView.displayedConsent.destination, moved.destination)

        operations.installConsent = second
        XCTAssertNil(oldBinding.wrappedValue)
        XCTAssertEqual(oldView.displayedConsent.id, first.id)
        XCTAssertEqual(oldView.displayedConsent.destination, first.destination)
        oldBinding.wrappedValue = moved
        XCTAssertEqual(operations.installConsent?.id, second.id)
        operations.confirmInstall(first)
        XCTAssertEqual(operations.installConsent?.id, second.id)
        await operations.cancelInstallConsent(reviewID: first.id)
        XCTAssertEqual(operations.installConsent?.id, second.id)
        XCTAssertEqual(operations.installConsent?.destination, second.destination)
        XCTAssertNil(operations.operation)
    }

    @MainActor func testDismissalBindingIsBoundToOriginatingReview() async throws {
        let operations = GameOperationsController(installed: InstalledGamesController())
        let game = PCGame(id: "FIXTURE00001", title: "Test game", artwork: nil)
        let first = GameInstallConsent(game: game, destination: URL(fileURLWithPath: "/tmp/ode-first"),
                                       freeBytes: 0, installedID: nil, nativeAccountHash: nil)
        let second = GameInstallConsent(game: game, destination: URL(fileURLWithPath: "/tmp/ode-second"),
                                        freeBytes: 0, installedID: nil, nativeAccountHash: nil)
        operations.installConsent = first
        let oldBinding = GameInstallSheet(operations: operations, reviewID: first.id).installConsentBinding
        operations.installConsent = second
        oldBinding.wrappedValue = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(operations.installConsent?.id, second.id)
        XCTAssertEqual(operations.installConsent?.destination, second.destination)
        let currentBinding = GameInstallSheet(operations: operations, reviewID: second.id).installConsentBinding
        var updates = 0
        let observation = operations.objectWillChange.sink { updates += 1 }
        currentBinding.wrappedValue = nil
        for _ in 0..<100 where operations.installConsent != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(operations.installConsent)
        XCTAssertGreaterThan(updates, 0)
        withExtendedLifetime(observation) {}
    }
}
