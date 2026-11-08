// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import XodusPreview

final class SignInOwnershipPolicyChecks: XCTestCase {
    func testAmbiguousRetryCannotCancelTerminalPredecessor() {
        XCTAssertFalse(SignInOwnershipPolicy.canCancel(ownerPresent: true,
            ownerFlowID: nil, displayedFlowID: "fixture-failed-flow"))
        XCTAssertFalse(SignInOwnershipPolicy.canCancel(ownerPresent: true,
            ownerFlowID: "fixture-gated-flow-2", displayedFlowID: "fixture-gated-flow-1"))
        XCTAssertTrue(SignInOwnershipPolicy.canCancel(ownerPresent: true,
            ownerFlowID: "fixture-gated-flow-2", displayedFlowID: "fixture-gated-flow-2"))
    }

    func testPendingOwnerRejectsNilAndMismatchedStatusIdentity() {
        XCTAssertFalse(SignInOwnershipPolicy.acceptsStatus(
            ownerFlowID: "fixture-gated-flow-1", incomingFlowID: nil))
        XCTAssertFalse(SignInOwnershipPolicy.acceptsStatus(
            ownerFlowID: "fixture-gated-flow-1", incomingFlowID: "fixture-failed-flow"))
        XCTAssertTrue(SignInOwnershipPolicy.acceptsStatus(
            ownerFlowID: "fixture-gated-flow-1", incomingFlowID: "fixture-gated-flow-1"))
        XCTAssertTrue(SignInOwnershipPolicy.acceptsStatus(ownerFlowID: nil, incomingFlowID: nil))
    }

    func testTerminalOwnerReleasesRetryLatchWithoutDroppingActiveAttempt() {
        XCTAssertFalse(SignInOwnershipPolicy.retainsRetryLatch(requested: true, ownerActive: false))
        XCTAssertTrue(SignInOwnershipPolicy.retainsRetryLatch(requested: true, ownerActive: true))
        XCTAssertFalse(SignInOwnershipPolicy.retainsRetryLatch(requested: false, ownerActive: true))
    }
}
