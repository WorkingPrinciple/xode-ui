// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import XodusCore
import XodusManagement
@testable import XodusPreview

final class CalimochoInstalledReleaseChecks: XCTestCase {
    func testMissingInstallationAndRegistryHaveDistinctFailures() throws {
        let absent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try CalimochoInstalledRelease.locate(root: absent)) {
            guard case CalimochoInstalledRelease.Failure.notInstalled = $0 else {
                return XCTFail("Unexpected missing-install error: \($0)")
            }
        }
        _ = try installedRelease()
        XCTAssertThrowsError(try CalimochoInstalledRelease.locate(registries: absent)) {
            guard case CalimochoInstalledRelease.Failure.registryMissing = $0 else {
                return XCTFail("Unexpected missing-registry error: \($0)")
            }
        }
    }

    @MainActor
    func testUncheckedAndMissingNeverClaimToolkitReadinessOrChangeChoice() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let absent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        let controller = CalimochoEngineController(defaults: defaults, root: absent)
        XCTAssertEqual(controller.state.label, "Not checked")
        XCTAssertFalse(controller.isVerified)
        controller.refresh(configuration: nil)
        await controller.waitForRefresh()
        XCTAssertEqual(controller.state, .missing)
        XCTAssertEqual(controller.state.label, "Not installed")
        XCTAssertFalse(controller.isVerified)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
    }

    @MainActor
    func testRealInstalledReleaseDetectionNeedsServiceBeforeSelection() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        _ = try installedRelease(defaults: defaults)
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let controller = CalimochoEngineController(defaults: defaults)
        controller.refresh(configuration: nil)
        await controller.waitForRefresh()
        XCTAssertEqual(controller.state, .detected)
        XCTAssertFalse(controller.isVerified)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        controller.refresh(configuration: nil, selectAsDefault: true)
        await controller.waitForRefresh()
        guard case .failed = controller.state else { return XCTFail("Selection without admission must fail") }
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
    }

    @MainActor
    func testRealCLIAdmitsInstalledReleaseAndOnlyExplicitSelectionWritesDefaults() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let release = try installedRelease(defaults: defaults)
        let configuration = try installedConfiguration()
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let controller = CalimochoEngineController(defaults: defaults)
        controller.refresh(configuration: configuration)
        await controller.waitForRefresh()
        guard case .verified(let checked) = controller.state else {
            return XCTFail("Actual installed CLI refused the actual release: \(controller.state)")
        }
        XCTAssertFalse(checked.inspection.qualified)
        XCTAssertEqual(checked.registryPath, release.registry.path)
        XCTAssertEqual(checked.inspection.registrySha256, release.registrySHA256)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        controller.refresh(configuration: configuration, selectAsDefault: true)
        await controller.waitForRefresh()
        guard case .verified(let selected) = controller.state else {
            return XCTFail("Actual explicit release selection failed: \(controller.state)")
        }
        XCTAssertEqual(EngineDefaults.defaultEngine(defaults), .calimocho)
        XCTAssertEqual(try AdmittedEngineSelection.read(defaults: defaults), selected)
        let saved = try XCTUnwrap(defaults.data(forKey: NativeEngineDefaults.preferenceKey))
        XCTAssertEqual(try JSONDecoder().decode(AdmittedEngineSelection.self, from: saved), selected)
        XCTAssertEqual(defaults.string(forKey: "Xodus.lifecycle.registry"), release.registry.path)
        let stopped = await controller.shutdownForApplicationTermination()
        XCTAssertTrue(stopped)
    }

    @MainActor
    func testRealInspectionFailureAndCancellationPreserveExplicitChoice() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        _ = try installedRelease(defaults: defaults)
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let executable = URL(fileURLWithPath: "/usr/bin/false")
        let identity = try XCTUnwrap(NativeAuthHostBinding.forExecutable(executable))
        let configuration = BackendConfiguration(executable: executable,
            stateDirectory: FileManager.default.temporaryDirectory, executableIdentity: identity)
        let controller = CalimochoEngineController(defaults: defaults)
        controller.refresh(configuration: configuration, selectAsDefault: true)
        await controller.waitForRefresh()
        guard case .failed = controller.state else { return XCTFail("Unsupported real executable must refuse") }
        XCTAssertFalse(controller.isVerified)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        controller.refresh(configuration: configuration, selectAsDefault: true)
        controller.cancel()
        await controller.waitForRefresh()
        XCTAssertEqual(controller.state, .canceled)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
    }

    @MainActor
    func testChoiceChangedDuringRealAdmissionIsNotOverwritten() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        _ = try installedRelease(defaults: defaults)
        let configuration = try installedConfiguration()
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        let controller = CalimochoEngineController(defaults: defaults)
        controller.refresh(configuration: configuration, selectAsDefault: true)
        EngineDefaults.setDefaultEngine(.gptk3, defaults)
        let changed = defaults.dictionaryRepresentation() as NSDictionary
        await controller.waitForRefresh()
        guard case .failed = controller.state else { return XCTFail("Concurrent choice must refuse stale commit") }
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, changed)
    }

    @MainActor
    func testRealDistinctRegistriesWithoutPreferenceFailClosedAndPreserveChoice() async throws {
        _ = try installedRelease()
        let releases = try matchingRegistryURLs().map {
            try CalimochoInstalledRelease.locate(preferredRegistry: $0.path)
        }
        guard Set(releases.map(\.registrySHA256)).count > 1 else {
            throw XCTSkip("Multiple distinct genuine Calimocho registry records are not present on this host.")
        }
        XCTAssertThrowsError(try CalimochoInstalledRelease.locate()) {
            guard case CalimochoInstalledRelease.Failure.ambiguousRegistry = $0 else {
                return XCTFail("Unexpected unpreferred registry error: \($0)")
            }
        }
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        XCTAssertNil(defaults.object(forKey: "Xodus.lifecycle.registry"))
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let controller = CalimochoEngineController(defaults: defaults)
        for selectAsDefault in [false, true] {
            controller.refresh(configuration: nil, selectAsDefault: selectAsDefault)
            await controller.waitForRefresh()
            XCTAssertEqual(controller.state, .failed(
                CalimochoInstalledRelease.Failure.ambiguousRegistry.localizedDescription))
            XCTAssertFalse(controller.isVerified)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    @MainActor
    func testRealReleaseWithoutHistoricalSmokeMetadataNeedsArtifactAdmission() async throws {
        let installed = try installedRelease()
        let configuration = try installedConfiguration()
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("calimocho-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove the test-owned registry directory: \(error)") }
        }
        let bytes = try InstalledGameFiles.readRegular(installed.registry, maximumBytes: 2_097_152)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var engines = try XCTUnwrap(object["engines"] as? [[String: Any]])
        for index in engines.indices { engines[index].removeValue(forKey: "smoke_test") }
        object["engines"] = engines
        let registryURL = directory.appendingPathComponent(CalimochoInstalledRelease.engineName + "-preflight.json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: registryURL)
        let registry = try NativeEngineRegistry.read(registryURL)
        let entry = try XCTUnwrap(registry.engines.first)
        XCTAssertNil(entry.smoke_test)
        XCTAssertFalse(entry.isAvailable, "Missing smoke metadata must not become legacy availability")
        XCTAssertThrowsError(try NativeLaunchConfiguration.selectEngine(registry: registry, provider: nil,
            defaults: defaults, provenEngine: CalimochoInstalledRelease.engineName))
        let controller = CalimochoEngineController(defaults: defaults, registries: directory)
        controller.refresh(configuration: configuration)
        await controller.waitForRefresh()
        guard case .verified(let selection) = controller.state else {
            return XCTFail("The real release without smoke prose was not admitted: \(controller.state)")
        }
        XCTAssertFalse(selection.inspection.qualified)
        let selected = try NativeLaunchConfiguration.selectEngine(registry: registry, provider: nil,
            defaults: defaults, provenEngine: CalimochoInstalledRelease.engineName, admittedSelection: selection)
        XCTAssertEqual(selected.name, entry.name)
        XCTAssertNil(defaults.object(forKey: NativeEngineDefaults.preferenceKey))
    }

    private let defaultsSuite = "io.github.dragoshont.ode.calimocho-checks.\(UUID().uuidString)"

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    }

    private func installedRelease(defaults: UserDefaults? = nil) throws -> CalimochoInstalledRelease {
        let engine = CalimochoInstalledRelease.enginesRoot
            .appendingPathComponent(CalimochoInstalledRelease.engineName)
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw XCTSkip("The genuine pinned Calimocho release is not installed on this host.")
        }
        do {
            return try CalimochoInstalledRelease.locate()
        } catch CalimochoInstalledRelease.Failure.ambiguousRegistry {
            let registry = try XCTUnwrap(matchingRegistryURLs().first,
                "The genuine pinned Calimocho release has no matching registry record.")
            let release = try CalimochoInstalledRelease.locate(preferredRegistry: registry.path)
            defaults?.set(release.registry.path, forKey: "Xodus.lifecycle.registry")
            return release
        }
    }

    private func matchingRegistryURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: CalimochoInstalledRelease.registriesRoot,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter {
                $0.lastPathComponent.hasPrefix(CalimochoInstalledRelease.engineName + "-")
                    && $0.pathExtension == "json"
            }
            .sorted { $0.path < $1.path }
    }

    private func installedConfiguration() throws -> BackendConfiguration {
        let path = ProcessInfo.processInfo.environment["XODUS_ENGINE_INSPECTION_TEST_BACKEND"]
            ?? "/Applications/Ode to X.app/Contents/Resources/XodusEngine/xodus-cli"
        let executable = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("The actual installed Ode CLI is unavailable; no substitute is used.")
        }
        let identity = try XCTUnwrap(NativeAuthHostBinding.forExecutable(executable))
        return BackendConfiguration(executable: executable, stateDirectory: FileManager.default.temporaryDirectory,
                                    executableIdentity: identity)
    }
}
