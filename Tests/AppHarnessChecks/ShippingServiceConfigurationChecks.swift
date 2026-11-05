// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import XCTest
import XodusManagement
@testable import XodusPreview

final class ShippingServiceConfigurationChecks: XCTestCase {
    private struct PairReceipt: Decodable {
        struct FileIdentity: Decodable {
            let sha256: String
            let bytes: Int64
        }
        let schemaVersion: Int
        let approvedAppSourceCommit: String
        let approvedAppSourceTree: String
        let producerCommit: String
        let producerTree: String
        let signedBundledCLI: FileIdentity
        let signedHelper: FileIdentity
        let helperVersion: Int
        let helperSourceCommit: String
        let generatedPinsSHA256: String

        var pins: ShippingPairIdentity {
            ShippingPairIdentity(schemaVersion: schemaVersion,
                appSourceCommit: approvedAppSourceCommit, appSourceTree: approvedAppSourceTree,
                producerCommit: producerCommit, producerTree: producerTree,
                engineSHA256: signedBundledCLI.sha256, engineBytes: signedBundledCLI.bytes,
                helperSHA256: signedHelper.sha256, helperBytes: signedHelper.bytes,
                helperVersion: helperVersion, helperSourceCommit: helperSourceCommit)
        }
    }

    @MainActor
    func testRealControlledPairReadsEngineAndInstallationWithoutHistoricalCLIPin() async throws {
        guard let path = ProcessInfo.processInfo.environment["XODUS_ENGINE_INSPECTION_TEST_BACKEND"] else {
            throw XCTSkip("Supply the existing backend selector with an actual controlled app's bundled CLI.")
        }
        let executable = URL(fileURLWithPath: path)
        let app = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let receiptURL = app.deletingLastPathComponent().appendingPathComponent("package-receipt.json")
        guard app.pathExtension == "app", FileManager.default.fileExists(atPath: receiptURL.path) else {
            throw XCTSkip("An actual controlled package and its retained receipt are required; no substitute is used.")
        }
        let receipt = try JSONDecoder().decode(PairReceipt.self, from: Data(contentsOf: receiptURL))
        let generated = try Data(contentsOf: app.deletingLastPathComponent()
            .appendingPathComponent("source/Sources/XodusPreview/ShippingPairPins.swift"))
        XCTAssertEqual(SHA256.hash(data: generated).map { String(format: "%02x", $0) }.joined(),
                       receipt.generatedPinsSHA256)
        let generatedSource = try XCTUnwrap(String(data: generated, encoding: .utf8))
        XCTAssertTrue(generatedSource.contains("engineSHA256: \"\(receipt.signedBundledCLI.sha256)\""))
        XCTAssertTrue(generatedSource.contains("helperSHA256: \"\(receipt.signedHelper.sha256)\""))
        XCTAssertTrue(generatedSource.contains("producerCommit: \"\(receipt.producerCommit)\""))
        let bundle = try XCTUnwrap(Bundle(url: app))
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("current-service-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove owned service-check outputs: \(error)") }
        }
        let admitted = try ShippingPairAdmission.configuration(
            bundle: bundle, stateDirectory: root, pins: receipt.pins)
        XCTAssertNotEqual(admitted.executableIdentity?.sha256, NativeLifecyclePins.cliSHA256,
                          "The actual current signed CLI must exercise the formerly rejected boundary.")
        let current = try XCTUnwrap(ShippingPairAdmission.connectedServiceConfiguration(
            admitted, pins: receipt.pins))
        XCTAssertEqual(current.executable, executable)
        XCTAssertNil(ShippingPairAdmission.connectedServiceConfiguration(admitted, pins: nil))
        XCTAssertNil(ShippingPairAdmission.connectedServiceConfiguration(nil, pins: receipt.pins))
        let otherExecutable = URL(fileURLWithPath: "/usr/bin/false")
        let otherIdentity = try XCTUnwrap(NativeAuthHostBinding.forExecutable(otherExecutable))
        let mismatched = BackendConfiguration(executable: otherExecutable, stateDirectory: root,
            nativeAuthHost: admitted.nativeAuthHost, executableIdentity: otherIdentity)
        XCTAssertNil(ShippingPairAdmission.connectedServiceConfiguration(mismatched, pins: receipt.pins),
                     "A genuine different executable cannot borrow the admitted current pair.")
        let unbound = BackendConfiguration(executable: admitted.executable, stateDirectory: root,
            nativeAuthHost: admitted.nativeAuthHost)
        XCTAssertNil(ShippingPairAdmission.connectedServiceConfiguration(unbound, pins: receipt.pins))
        let missingHelper = BackendConfiguration(executable: admitted.executable, stateDirectory: root,
            executableIdentity: admitted.executableIdentity)
        XCTAssertNil(ShippingPairAdmission.connectedServiceConfiguration(missingHelper, pins: receipt.pins))

        let release = try CalimochoInstalledRelease.locate()
        let inspection = try await EngineInspectionClient().inspect(executable: current.executable,
            registry: release.registry, engine: CalimochoInstalledRelease.engineName,
            expectedDigest: release.registrySHA256, executableIdentity: current.executableIdentity)
        XCTAssertTrue(inspection.ready)
        XCTAssertFalse(inspection.qualified)
        let query = NativeInstallationQuery()
        let status = try await query.run(configuration: current, product: "9P9VNSQK1W3K",
            gameDirectory: root.appendingPathComponent("not-installed"),
            stateDirectory: root.appendingPathComponent("installation-status"))
        XCTAssertTrue(status.success)
        XCTAssertEqual(status.status, .missing)
        XCTAssertFalse(query.isRunning)
        let brotato = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Games/Xodus/Brotato-Xbox", isDirectory: true)
        guard FileManager.default.fileExists(atPath: brotato.path) else {
            throw XCTSkip("The actual retained Brotato installation is unavailable; no game fixture is created.")
        }
        let installed = try await query.run(configuration: current, product: "9P9VNSQK1W3K",
            gameDirectory: brotato, stateDirectory: root.appendingPathComponent("brotato-status"))
        XCTAssertTrue(installed.success)
        XCTAssertEqual(installed.status, .complete)
        XCTAssertGreaterThan(installed.filesTotal ?? 0, 0)
        XCTAssertFalse(query.isRunning)
        print("Actual controlled CLI \(receipt.signedBundledCLI.sha256): engine ready=\(inspection.ready), "
            + "absent installation=\(status.status?.rawValue ?? "unknown"), "
            + "retained Brotato=\(installed.status?.rawValue ?? "unknown"), files=\(installed.filesTotal ?? 0). "
            + "No account, Wine, helper or management client started.")
        let historical = try NativeTitleLaunchProfile.RuntimeCatalogue.bundled()
        XCTAssertEqual(historical.cliSha256, NativeLifecyclePins.cliSHA256)
        XCTAssertNotEqual(historical.cliSha256, receipt.signedBundledCLI.sha256)
    }
}
