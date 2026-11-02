// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import XodusCredentials
@testable import XodusPreview

final class AppHarnessChecks: XCTestCase {
    func testSandboxBrokerIssuesRotatesAndDeletesThroughAdapter() async throws {
        let broker = SandboxCredentialBroker()
        let direct = PCGamesMockStore("SYNTHETIC_DIRECT_MUST_NOT_BE_READ")
        let adapter = PCGamesCredentialStore(sandboxBroker: { try await broker.send($0) }, direct: direct)
        let initiallyPresent = try await adapter.contains()
        XCTAssertFalse(initiallyPresent)
        try await adapter.save("SYNTHETIC_INITIAL_REFRESH_TOKEN")
        let issued = try await adapter.read()
        XCTAssertEqual(issued, "SYNTHETIC_INITIAL_REFRESH_TOKEN")
        try await adapter.save("SYNTHETIC_ROTATED_REFRESH_TOKEN")
        let rotated = try await adapter.read()
        XCTAssertEqual(rotated, "SYNTHETIC_ROTATED_REFRESH_TOKEN")
        do {
            try await adapter.save("not-a-synthetic-token")
            XCTFail("Sandbox must refuse non-synthetic credentials")
        } catch {
            XCTAssertEqual(error as? PCGamesError, .credentialBrokerUnavailable)
        }
        try await adapter.delete()
        let remaining = try await adapter.read()
        XCTAssertNil(remaining)
        let reads = await direct.reads
        let writes = await direct.saved
        let deletions = await direct.deletions
        let presence = await direct.presenceChecks
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(deletions, 0)
        XCTAssertEqual(presence, 0)
    }

    func testSandboxBrokerAdapterFailsClosed() async throws {
        let direct = PCGamesMockStore("SYNTHETIC_DIRECT_MUST_NOT_BE_READ")
        let adapter = PCGamesCredentialStore(sandboxBroker: { _ in
            throw CredentialFailure.unavailable
        }, direct: direct)
        do {
            _ = try await adapter.read()
            XCTFail("Rejected sandbox broker must not fall back to direct storage")
        } catch {
            XCTAssertEqual(error as? PCGamesError, .credentialBrokerUnavailable)
        }
        let reads = await direct.reads
        let saves = await direct.saved
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(saves.isEmpty)
    }

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
