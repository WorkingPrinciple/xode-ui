// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import XodusManagement
@testable import XodusPreview

final class AccountReadContractChecks: XCTestCase {
    private func wireError(category: String, stage: String, code: String, retryable: Bool,
                           retryAfter: JSONValue? = nil) -> JSONValue {
        var details: [String: JSONValue] = ["category": .string(category), "stage": .string(stage)]
        if let retryAfter { details["retryAfterSeconds"] = retryAfter }
        let prefix = category == "authenticatedReadFailure" ? "Authenticated read" : "Recent library read"
        return .object(["code": .string(code), "retryable": .bool(retryable),
                        "message": .string("\(prefix) failed: \(stage)."), "details": .object(details)])
    }

    func testEveryExistingStageKeepsItsExactContract() throws {
        let validator = try ContractValidator()
        for stage in AuthenticatedReadFailure.allCases {
            let error = wireError(category: "authenticatedReadFailure", stage: stage.rawValue,
                                  code: stage.code, retryable: stage.retryable)
            XCTAssertEqual(AuthenticatedReadFailure(error: error), stage)
            try validator.validate(error, definition: "error")
            if stage != .throttled {
                let withHint = wireError(category: "authenticatedReadFailure", stage: stage.rawValue,
                                         code: stage.code, retryable: stage.retryable, retryAfter: .integer(60))
                XCTAssertNil(AuthenticatedReadFailure(error: withHint))
                XCTAssertThrowsError(try validator.validate(withHint, definition: "error"))
            }
        }
        for stage in RecentLibraryFailure.allCases {
            let error = wireError(category: "recentLibraryFailure", stage: stage.rawValue,
                                  code: stage.code, retryable: stage.retryable)
            XCTAssertEqual(RecentLibraryFailure(error: error), stage)
            try validator.validate(error, definition: "error")
            if stage != .throttled {
                let withHint = wireError(category: "recentLibraryFailure", stage: stage.rawValue,
                                         code: stage.code, retryable: stage.retryable, retryAfter: .integer(60))
                XCTAssertNil(RecentLibraryFailure(error: withHint))
                XCTAssertThrowsError(try validator.validate(withHint, definition: "error"))
            }
        }
    }

    func testThrottleHintPreservesTheFullWireInteger() throws {
        let validator = try ContractValidator()
        for seconds: UInt64? in [nil, 0, 1, 86_400, UInt64.max] {
            for category in ["authenticatedReadFailure", "recentLibraryFailure"] {
                let error = wireError(category: category, stage: "throttled", code: "NETWORK_UNAVAILABLE",
                                      retryable: true, retryAfter: seconds.map(JSONValue.unsigned))
                let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(error))
                try validator.validate(decoded, definition: "error")
                if category == "authenticatedReadFailure" {
                    XCTAssertEqual(AuthenticatedReadFailure(error: decoded), .throttled)
                } else {
                    XCTAssertEqual(RecentLibraryFailure(error: decoded), .throttled)
                }
                XCTAssertEqual(decoded["details"]?["retryAfterSeconds"]?.uint64, seconds)
            }
        }
    }

    func testMalformedHintsAndThrottleTuplesStayRejected() throws {
        let validator = try ContractValidator()
        for category in ["authenticatedReadFailure", "recentLibraryFailure"] {
            for invalid: JSONValue in [.integer(-1), .number(1.5), .string("60"), .bool(true), .null] {
                let error = wireError(category: category, stage: "throttled", code: "NETWORK_UNAVAILABLE",
                                      retryable: true, retryAfter: invalid)
                XCTAssertNil(AuthenticatedReadFailure(error: error))
                XCTAssertNil(RecentLibraryFailure(error: error))
                XCTAssertThrowsError(try validator.validate(error, definition: "error"))
            }
            for (code, retryable) in [("AUTH_INVALID", true), ("NETWORK_UNAVAILABLE", false)] {
                let error = wireError(category: category, stage: "throttled", code: code, retryable: retryable)
                XCTAssertNil(AuthenticatedReadFailure(error: error))
                XCTAssertNil(RecentLibraryFailure(error: error))
                XCTAssertThrowsError(try validator.validate(error, definition: "error"))
            }
        }
    }

    @MainActor
    func testPreviewConsumerDistinguishesThrottleRejectionAndTransport() {
        for seconds: UInt64? in [nil, 0, 86_400, UInt64.max] {
            let message = seconds.map {
                "Microsoft is limiting requests. Wait \($0) seconds before checking again."
            } ?? "Microsoft is limiting requests. Wait before checking again."
            let authenticated = ManagementError.authenticatedReadFailed(.throttled, retryAfterSeconds: seconds)
            let recent = ManagementError.recentLibraryFailed(.throttled, retryAfterSeconds: seconds)
            XCTAssertEqual(LiveSession.describe(authenticated), message)
            XCTAssertEqual(LiveSession.describe(recent), message)
            XCTAssertEqual(authenticated.localizedDescription, message)
            XCTAssertEqual(recent.localizedDescription, message)
            XCTAssertNotEqual(authenticated, .authenticatedReadFailed(.authRejected))
            XCTAssertNotEqual(authenticated, .authenticatedReadFailed(.transportFailed))
        }
        XCTAssertEqual(LiveSession.describe(ManagementError.authenticatedReadFailed(.authRejected)),
                       "Microsoft rejected access to this feature. Check account status before reconnecting.")
        XCTAssertEqual(LiveSession.describe(ManagementError.authenticatedReadFailed(.transportFailed)),
                       "The connection didn't finish. Check your network and try again.")
    }

    @MainActor
    func testSettingsVersionUsesTheActualHostBundle() {
        let bundle = Bundle.main
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        XCTAssertEqual(GeneralSettingsTab.versionDescription(in: bundle), "Version \(version) (Build \(build))")
    }
}
