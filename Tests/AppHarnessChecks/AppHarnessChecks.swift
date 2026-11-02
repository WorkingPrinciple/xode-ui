// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import XodusPreview

final class AppHarnessChecks: XCTestCase {
    @MainActor
    func testSyntheticAuthenticatedScenariosWithoutApplicationStartup() async throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("XodusManagementChecks")
        let passed = try await AuthenticatedScenarioChecks.run(managementExecutable: executable)
        XCTAssertTrue(passed)
    }

    func testScenarioArgumentsFailClosed() {
        for mode in ["--authenticated-scenario-runner", "--settings-accessibility-check",
                     "--real-account-scenario-runner"] {
            XCTAssertTrue(DevelopmentArguments.accepts([mode]))
            XCTAssertFalse(DevelopmentArguments.accepts([mode, "--fixture"]))
            XCTAssertFalse(DevelopmentArguments.accepts(["--fixture", mode]))
        }
    }

    func testOperatorAvailabilityFailsClosed() {
        var reads = 0
        var warnings = 0
        for (input, output) in [(false, false), (false, true), (true, false)] {
            XCTAssertFalse(OperatorAvailabilityGate.confirm(
                stdinInteractive: input, stderrInteractive: output,
                warn: { warnings += 1 }, readResponse: { reads += 1; return "YES" }))
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(warnings, 0)
        for response in [nil, Optional(""), Optional("no"), Optional("yes later")] {
            XCTAssertFalse(OperatorAvailabilityGate.confirm(
                stdinInteractive: true, stderrInteractive: true,
                warn: { warnings += 1 }, readResponse: { response }))
        }
        XCTAssertTrue(OperatorAvailabilityGate.confirm(
            stdinInteractive: true, stderrInteractive: true,
            warn: { warnings += 1 }, readResponse: { " YES\n" }))
        XCTAssertEqual(warnings, 5)
    }
}
