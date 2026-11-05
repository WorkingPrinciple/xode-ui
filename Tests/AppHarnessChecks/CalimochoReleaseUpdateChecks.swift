// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import XodusCore
import XodusManagement
@testable import XodusPreview

final class CalimochoReleaseUpdateChecks: XCTestCase {
    @MainActor
    func testGenuine04To06ObtainUpdateAndPreservedFailurePaths() async throws {
        let configuration = try configuration()
        let cache = artifactDirectory
        let olderArchive = cache.appendingPathComponent(CalimochoRelease.release04.rawValue + "-macos.zip")
        guard FileManager.default.fileExists(atPath: olderArchive.path) else {
            throw XCTSkip("Put the genuine published04 ZIP at \(olderArchive.path) to run artifact-only update acceptance.")
        }
        let newerArchive = cache.appendingPathComponent(CalimochoRelease.release06.rawValue + "-macos.zip")
        if !FileManager.default.fileExists(atPath: newerArchive.path) {
            try await CalimochoReleaseInstaller.download(.release06, to: newerArchive) { print($0) }
        }
        let directory = cache.appendingPathComponent("calimocho-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let engines = directory.appendingPathComponent("Engines")
        let registries = directory.appendingPathComponent("Registries")
        let installer = CalimochoReleaseInstaller()
        let older = try await installer.obtain(.release04, root: engines, registries: registries,
            configuration: configuration, cachedArchive: olderArchive) { print("04: \($0)") }
        XCTAssertTrue(older.inspection.ready)
        XCTAssertFalse(older.inspection.qualified)
        let olderRegistry = try Data(contentsOf: URL(fileURLWithPath: older.registryPath))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: olderRegistry) as? [String: Any])
        let entries = try XCTUnwrap(object["engines"] as? [[String: Any]])
        XCTAssertNil(entries.first?["smoke_test"])
        let domain = "io.github.dragoshont.ode.real-update.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        let controller = CalimochoEngineController(defaults: defaults, root: engines, registries: registries)
        controller.refresh(configuration: configuration)
        await controller.waitForRefresh()
        XCTAssertEqual(controller.detectedRelease, .release04)
        XCTAssertTrue(controller.availableUpdate)
        XCTAssertEqual(EngineDefaults.defaultEngine(defaults), .crossover, "Acquisition never selects a default")
        controller.refresh(configuration: configuration, selectAsDefault: true)
        await controller.waitForRefresh()
        XCTAssertEqual(try AdmittedEngineSelection.read(defaults: defaults), older)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let installed = InstalledGamesController(store: InstalledGameStore(file: directory.appendingPathComponent("games.json")),
                                                discoveryRoot: directory.appendingPathComponent("Games"))
        await installed.load()
        XCTAssertTrue(installed.loaded)
        let operations = GameOperationsController(installed: installed)

        try operations.reserveEngineChange()
        XCTAssertTrue(installed.mutationActive)
        XCTAssertTrue(installed.runtimeRepairActive)
        XCTAssertFalse(operations.canDisconnectAccount)
        controller.obtainLatest(configuration: configuration, operations: operations, cachedArchive: newerArchive)
        await controller.waitForRefresh()
        guard case .failed = controller.state else { return XCTFail("An already owned mutation must refuse update") }
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: engines.appendingPathComponent(CalimochoRelease.release06.rawValue).path))
        operations.releaseEngineChange()
        controller.refresh(configuration: configuration)
        await controller.waitForRefresh()

        controller.obtainLatest(configuration: configuration, operations: operations, cachedArchive: newerArchive)
        XCTAssertTrue(installed.runtimeRepairActive)
        controller.cancel()
        await controller.waitForRefresh()
        XCTAssertEqual(controller.state, .canceled)
        XCTAssertFalse(installed.mutationActive)
        XCTAssertFalse(installed.runtimeRepairActive)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: older.registryPath)), olderRegistry)

        controller.refresh(configuration: configuration)
        await controller.waitForRefresh()
        controller.obtainLatest(configuration: configuration, operations: operations, cachedArchive: newerArchive)
        let joined = await controller.shutdownForApplicationTermination()
        XCTAssertTrue(joined)
        XCTAssertFalse(installed.mutationActive)
        XCTAssertFalse(installed.runtimeRepairActive)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        controller.resumeAfterTerminationRefusal()
        controller.refresh(configuration: configuration)
        await controller.waitForRefresh()
        let unsupported = URL(fileURLWithPath: "/usr/bin/false")
        let rejected = BackendConfiguration(executable: unsupported, stateDirectory: directory,
            executableIdentity: try XCTUnwrap(NativeAuthHostBinding.forExecutable(unsupported)))
        controller.obtainLatest(configuration: rejected, operations: operations, cachedArchive: newerArchive)
        await controller.waitForRefresh()
        guard case .failed = controller.state else { return XCTFail("The real unsupported verifier must refuse update") }
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        XCTAssertFalse(installed.mutationActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: engines.appendingPathComponent(CalimochoRelease.release06.rawValue).path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: older.registryPath)), olderRegistry)

        controller.refresh(configuration: configuration)
        await controller.waitForRefresh()
        controller.obtainLatest(configuration: configuration, operations: operations, cachedArchive: olderArchive)
        await controller.waitForRefresh()
        guard case .failed = controller.state else { return XCTFail("A genuine04 archive must never install as06") }
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: engines.appendingPathComponent(CalimochoRelease.release06.rawValue).path))
        controller.refresh(configuration: configuration)
        await controller.waitForRefresh()
        controller.obtainLatest(configuration: configuration, operations: operations, cachedArchive: newerArchive)
        await controller.waitForRefresh()
        guard case .verified(let newer) = controller.state else {
            return XCTFail("Genuine04->06 update failed: \(controller.state)")
        }
        XCTAssertEqual(newer.inspection.engineName, CalimochoRelease.release06.rawValue)
        XCTAssertTrue(newer.inspection.ready)
        XCTAssertFalse(newer.inspection.qualified)
        XCTAssertEqual(EngineDefaults.defaultEngine(defaults), .calimocho)
        XCTAssertEqual(try AdmittedEngineSelection.read(defaults: defaults), newer)
        XCTAssertEqual(defaults.string(forKey: "Xodus.lifecycle.registry"), newer.registryPath)
        XCTAssertFalse(installed.mutationActive)
        XCTAssertFalse(installed.runtimeRepairActive)
        controller.obtainLatest(configuration: configuration, operations: operations, cachedArchive: newerArchive)
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        let concurrentChoice = defaults.dictionaryRepresentation() as NSDictionary
        await controller.waitForRefresh()
        guard case .failed = controller.state else { return XCTFail("The changed explicit choice must refuse stale selection") }
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, concurrentChoice)
        XCTAssertFalse(installed.mutationActive)
        controller.refresh(configuration: configuration, selectAsDefault: true)
        await controller.waitForRefresh()
        XCTAssertEqual(try AdmittedEngineSelection.read(defaults: defaults), newer)
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        controller.obtainLatest(configuration: configuration, operations: operations, cachedArchive: newerArchive)
        await controller.waitForRefresh()
        XCTAssertEqual(EngineDefaults.defaultEngine(defaults), .crossover, "Obtaining an existing06 never auto-selects it")
        controller.refresh(configuration: configuration, selectAsDefault: true)
        await controller.waitForRefresh()
        XCTAssertEqual(try AdmittedEngineSelection.read(defaults: defaults), newer,
                       "Explicit selection after obtaining06 must not silently return to saved04")
        XCTAssertEqual(EngineDefaults.defaultEngine(defaults), .calimocho)
        let reinspectedOlder = try await installer.obtain(.release04, root: engines, registries: registries,
            configuration: configuration, cachedArchive: olderArchive) { print("Preserved04: \($0)") }
        XCTAssertEqual(reinspectedOlder, older, "The complete older manifest must still pass real backend admission")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: older.registryPath)), olderRegistry)
        try JSONEncoder().encode(reinspectedOlder.inspection).write(to: directory.appendingPathComponent("inspection04.json"))
        try JSONEncoder().encode(newer.inspection).write(to: directory.appendingPathComponent("inspection06.json"))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: engines.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix(".calimocho-install-") })
        controller.checkForUpdates(force: true)
        await controller.waitForUpdateCheck()
        XCTAssertNotNil(defaults.object(forKey: "Xodus.calimocho.lastUpdateCheck"),
                        "A genuine anonymous GitHub response must be observed; rate limits aren't a successful check")
        print("Public release check: \(controller.updateMessage ?? "missing result")")
        let stopped = await controller.shutdownForApplicationTermination()
        XCTAssertTrue(stopped)
        try await installer.close()
        print("Genuine04->06 evidence retained at \(directory.path); both complete engines and no-smoke registries retained. Only isolated defaults \(domain) were changed and removed.")
    }

    @MainActor
    func testRealExtractionCancellationJoinsBeforeRemovingStage() async throws {
        let configuration = try configuration()
        let cache = artifactDirectory
        let archive = cache.appendingPathComponent(CalimochoRelease.release04.rawValue + "-macos.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw XCTSkip("Genuine published04 archive is unavailable.")
        }
        let directory = cache.appendingPathComponent("calimocho-cancel-\(UUID().uuidString)")
        let engines = directory.appendingPathComponent("Engines")
        let installer = CalimochoReleaseInstaller()
        let task = Task {
            try await installer.obtain(.release04, root: engines, registries: directory.appendingPathComponent("Registries"),
                                       configuration: configuration, cachedArchive: archive) { print("Cancellation: \($0)") }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !installer.hasOwnedProcess, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(installer.hasOwnedProcess, "Cancellation must hit the genuine owned ditto process")
        task.cancel()
        do { _ = try await task.value; XCTFail("The real extraction must cancel") }
        catch is CancellationError {}
        XCTAssertFalse(installer.hasUnjoinedWork)
        XCTAssertFalse(FileManager.default.fileExists(atPath: engines.appendingPathComponent(CalimochoRelease.release04.rawValue).path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: engines.path).contains { $0.hasPrefix(".calimocho-install-") })
        try await installer.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func configuration() throws -> BackendConfiguration {
        guard let path = ProcessInfo.processInfo.environment["XODUS_ENGINE_INSPECTION_TEST_BACKEND"] else {
            throw XCTSkip("The actual source809dd6f-or-newer CLI is required; installed development CLI is not equivalent.")
        }
        let executable = URL(fileURLWithPath: path)
        return BackendConfiguration(executable: executable, stateDirectory: FileManager.default.temporaryDirectory,
                                    executableIdentity: try XCTUnwrap(NativeAuthHostBinding.forExecutable(executable)))
    }

    private var artifactDirectory: URL {
        ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
    }
}
