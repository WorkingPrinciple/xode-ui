// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import OdeUpdates
import XodusManagement

@MainActor
final class SparkleUpdateDriverTests: XCTestCase {
    func testFailedCycleNeverBecomesUpToDate() throws {
        let noUpdate = NSError(domain: "SUSparkleErrorDomain", code: 1001)
        let offline = URLError(.notConnectedToInternet)
        let parseFailure = NSError(domain: "SUSparkleErrorDomain", code: 1000)
        XCTAssertEqual(try SparkleCheckOutcome.resolve(response: nil,
            callbackError: noUpdate, cycleError: noUpdate), .current(etag: nil))
        for error in [offline as NSError, parseFailure,
                      NSError(domain: "OtherDomain", code: 1001)] {
            XCTAssertThrowsError(try SparkleCheckOutcome.resolve(
                response: nil, callbackError: error, cycleError: nil))
            XCTAssertThrowsError(try SparkleCheckOutcome.resolve(
                response: .current(etag: nil), callbackError: noUpdate, cycleError: error))
            XCTAssertThrowsError(try SparkleCheckOutcome.resolve(
                response: .available(AppUpdateInfo(version: "1.0"), etag: nil),
                callbackError: nil, cycleError: error))
        }
        XCTAssertThrowsError(try SparkleCheckOutcome.resolve(
            response: nil, callbackError: nil, cycleError: nil))
    }

    func testMissingConfigurationNeverConstructsSparkle() async {
        for info: [String: Any] in [
            [:], ["SUFeedURL": "https://example.invalid/appcast.xml"],
            ["SUPublicEDKey": "fixture-only"],
            ["SUFeedURL": "", "SUPublicEDKey": "fixture-only"],
            ["SUFeedURL": "http://example.invalid/appcast.xml", "SUPublicEDKey": "fixture-only"],
            ["SUFeedURL": "https://example.invalid/appcast.xml", "SUPublicEDKey": " \n"]
        ] {
            var starts = 0
            let driver = SparkleUpdateDriver(configuration: UpdateFeedConfiguration(info: info)) {
                starts += 1
                return FakeSession()
            }
            XCTAssertFalse(driver.isConfigured)
            do {
                _ = try await driver.check(etag: nil)
                XCTFail("Unconfigured driver must refuse a check")
            } catch {
                XCTAssertEqual(error as? AppUpdateError, .unconfigured)
            }
            do {
                try await driver.relaunchToInstall(AppUpdateInfo(version: "1.0"))
                XCTFail("Unconfigured driver must refuse a relaunch")
            } catch {
                XCTAssertEqual(error as? AppUpdateError, .unconfigured)
            }
            XCTAssertEqual(starts, 0)
        }
    }

    func testConfiguredDriverLazilyUsesOneSessionWithoutASecondHTTPClient() async throws {
        let session = FakeSession()
        var starts = 0
        let driver = SparkleUpdateDriver(configuration: configured) {
            starts += 1
            return session
        }
        XCTAssertTrue(driver.isConfigured)
        XCTAssertEqual(starts, 0)
        let first = try await driver.check(etag: "old-provider-etag")
        let second = try await driver.check(etag: nil)
        XCTAssertEqual(first, .current(etag: nil))
        XCTAssertEqual(second, first)
        XCTAssertEqual(session.checks, 2)
        XCTAssertEqual(starts, 1)
        try await driver.relaunchToInstall(AppUpdateInfo(version: "1.0"))
        XCTAssertEqual(session.relaunches, 1)
    }

    func testRelaunchContinuationWaitsForIdleAndRunsOnce() throws {
        var busy = true
        var invocations = 0
        let gate = DeferredUpdateRelaunch(isBusy: { busy })
        let update = AppUpdateInfo(version: "0.2.0", buildVersion: "664")
        gate.postpone(update) { invocations += 1 }
        XCTAssertThrowsError(try gate.resume(update))
        XCTAssertEqual(invocations, 0)
        busy = false
        XCTAssertThrowsError(try gate.resume(AppUpdateInfo(version: "other")))
        try gate.resume(update)
        XCTAssertEqual(invocations, 1)
        XCTAssertThrowsError(try gate.resume(update))
        XCTAssertEqual(invocations, 1)
        gate.postpone(update) { invocations += 1 }
        gate.cancel()
        XCTAssertThrowsError(try gate.resume(update))
        XCTAssertEqual(invocations, 1)
    }

    func testSparkleBuildNumberCanUpdateTheSameMarketingVersion() async throws {
        let domain = "OdeUpdateChecks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let update = AppUpdateInfo(version: "0.2.0", buildVersion: "664")
        let driver = FixtureDriver(response: .available(update, etag: nil))
        let controller = AppUpdateController(driver: driver,
            preferences: AppUpdatePreferences(defaults: defaults),
            currentVersion: UpdateVersion("0.2.0"), currentBuildVersion: UpdateVersion("663"))
        await controller.checkNow()
        XCTAssertEqual(controller.state, .available(update))
        controller.skipThisVersion()
        XCTAssertNil(controller.indicator)
        let nextDriver = FixtureDriver(response: .available(
            AppUpdateInfo(version: "0.2.0", buildVersion: "665"), etag: nil))
        let next = AppUpdateController(driver: nextDriver,
            preferences: AppUpdatePreferences(defaults: defaults),
            currentVersion: UpdateVersion("0.2.0"), currentBuildVersion: UpdateVersion("663"))
        AppUpdatePreferences(defaults: defaults).nextCheck = .distantPast
        await next.checkIfDue()
        // A saved skip must not suppress a newer build with the same marketing version.
        XCTAssertNotNil(next.indicator)

        let older = AppUpdateController(driver: driver,
            preferences: AppUpdatePreferences(defaults: defaults),
            currentVersion: UpdateVersion("0.2.0"), currentBuildVersion: UpdateVersion("665"))
        await older.checkNow()
        XCTAssertEqual(older.state, .upToDate)
    }

    private var configured: UpdateFeedConfiguration {
        UpdateFeedConfiguration(info: [
            "SUFeedURL": "https://example.invalid/appcast.xml", "SUPublicEDKey": "fixture-only"
        ])
    }
}

@MainActor
private final class FakeSession: UpdateSession {
    var checks = 0
    var relaunches = 0
    func check() async throws -> AppUpdateFeedResponse {
        checks += 1
        return .current(etag: nil)
    }
    func resumeInstallation(_ info: AppUpdateInfo) throws { relaunches += 1 }
}

private struct FixtureDriver: UpdateDriver {
    var isConfigured: Bool { true }
    let response: AppUpdateFeedResponse
    func check(etag: String?) async throws -> AppUpdateFeedResponse { response }
    func relaunchToInstall(_ info: AppUpdateInfo) async throws {}
}
