// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest

final class NativeEngineDefaultsBindingChecks: XCTestCase {
    func testInspectionFailureIsPreservedBeforeSelectionValidation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/XodusPreview/NativeEngineDefaults.swift"), encoding: .utf8)
        let rejection = try XCTUnwrap(source.range(of: """
            if !result.ready, let failure = result.error {
                            throw EngineInspectionError.rejected(failure)
                        }
            """))
        let validation = try XCTUnwrap(source.range(of: "let selection = AdmittedEngineSelection"))
        XCTAssertLessThan(rejection.lowerBound, validation.lowerBound)
    }
}
