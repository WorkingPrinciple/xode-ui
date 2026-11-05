// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import XodusCore
import XodusManagement
@testable import XodusPreview

final class CalimochoDefaultPreservationChecks: XCTestCase {
    private func preferences() throws -> (UserDefaults, String) {
        let suite = "io.github.dragoshont.ode.default-preservation.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func inspection(engine: String = CalimochoReleasePin.release06.engineName,
                            registry: String = String(repeating: "a", count: 64),
                            wine: String = CalimochoReleasePin.release06.wineSha256,
                            server: String = CalimochoReleasePin.release06.wineserverSha256) -> EngineInspection {
        EngineInspection(schemaVersion: 1, capability: "engineAdmissionV1", registrySha256: registry,
            engineName: engine, declaredProvider: "calimocho", admittedProvider: "calimocho",
            admission: "admitted", ready: true, qualified: false,
            wineSha256: wine, wineserverSha256: server, error: nil)
    }

    private func game() -> InstalledGame {
        InstalledGame(id: UUID(), title: "Preservation check", identityName: "Example.Game",
            version: "1", storeId: "GAME00000001", folder: "/Unavailable/Game",
            launcher: "", importedAt: Date())
    }

    private func isolatedHome() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("default-preservation-\(UUID().uuidString)")
    }

    private func installDriftedPreviousDefault(home: URL, defaults: UserDefaults) throws -> URL {
        let pin = CalimochoReleasePin.release06
        let previous = home.appendingPathComponent("previous-home")
        let engines = previous.appendingPathComponent("Library/Application Support/Xode/Engines")
        let registries = previous.appendingPathComponent("Library/Application Support/Xodus/EngineRegistries")
        try FileManager.default.createDirectory(at: registries, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let digest = String(repeating: "a", count: 64)
        let registry = registries.appendingPathComponent("\(pin.engineName)-ode-default-v2-\(digest).json")
        try Data("changed registry".utf8).write(to: registry)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path)
        let selected = AdmittedEngineSelection(registryPath: registry.path, inspection: inspection(registry: digest))
        let automatic = NativeEngineDefaults.Automatic(selection: selected, home: previous.path,
            enginesRoot: engines.path, registriesRoot: registries.path)
        let encoded = try JSONEncoder().encode(selected)
        defaults.set(RuntimeProviderKind.calimocho.rawValue, forKey: EngineDefaults.defaultEngineKey)
        defaults.set(encoded, forKey: NativeEngineDefaults.preferenceKey)
        defaults.set(encoded, forKey: AdmittedEngineSelection.preferenceKey)
        defaults.set(registry.path, forKey: "Xodus.lifecycle.registry")
        defaults.set(try JSONEncoder().encode(automatic), forKey: NativeEngineDefaults.automaticKey)
        XCTAssertThrowsError(try NativeEngineDefaults.mayPrepareAutomatically(defaults: defaults)) {
            guard case NativeLaunchError.selectionChanged = $0 else { return XCTFail("\($0)") }
        }
        return registry
    }

    @MainActor
    func testNoSavedChoiceAndConcurrentExplicitChanges() throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(try NativeEngineDefaults.mayPrepareAutomatically(defaults: defaults))
        let expected = NativeEngineDefaults.PreferenceSnapshot(defaults)
        let selection = AdmittedEngineSelection(registryPath: "/Unavailable/registry", inspection: inspection())
        EngineDefaults.setDefaultEngine(.crossover, defaults)
        XCTAssertThrowsError(try NativeEngineDefaults.commitAutomatic(selection, expected: expected,
                                                                      defaults: defaults)) {
            guard case NativeLaunchError.automaticSelectionChanged = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(EngineDefaults.defaultEngine(defaults), .crossover)
        XCTAssertNil(defaults.object(forKey: NativeEngineDefaults.preferenceKey))
        EngineDefaults.setDefaultEngine(nil, defaults)
        XCTAssertFalse(try NativeEngineDefaults.mayPrepareAutomatically(defaults: defaults))
        let beforeSameValueChoice = NativeEngineDefaults.PreferenceSnapshot(defaults)
        EngineDefaults.setDefaultEngine(nil, defaults)
        XCTAssertNotEqual(beforeSameValueChoice, NativeEngineDefaults.PreferenceSnapshot(defaults))
    }

    @MainActor
    func testVerifiedReceiptCommitUpdatesBothConsumersAndDetectsRegistryDrift() throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = isolatedHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let engines = home.appendingPathComponent("Library/Application Support/Xode/Engines")
        let registries = home.appendingPathComponent("Library/Application Support/Xodus/EngineRegistries")
        let pin = CalimochoReleasePin.release06
        let engine = engines.appendingPathComponent(pin.engineName)
        // Preference-commit unit input, not a publisher/backend verification substitute.
        let manifest = CalimochoReleaseManifest(schema: "calimocho-engine/1", engine_id: pin.engineName,
            version: "0.1120.4.6", provider: .init(id: "calimocho", contract_version: 1),
            paths: .init(wine: "bin/wine", wineserver: "bin/wineserver"), environment: [:],
            signing: .init(team_id: pin.teamID))
        let rendered = try CalimochoReleaseEngines.renderRegistry(.init(pin: pin, root: engine,
            manifest: manifest, wine: engine.appendingPathComponent("bin/wine"),
            wineserver: engine.appendingPathComponent("bin/wineserver"), environment: [:]), registries: registries)
        let selected = AdmittedEngineSelection(registryPath: rendered.url.path,
                                               inspection: inspection(registry: rendered.digest))
        let before = NativeEngineDefaults.PreferenceSnapshot(defaults)
        try NativeEngineDefaults.commitAutomatic(selected, expected: before, defaults: defaults,
            home: home, enginesRoot: engines, registries: registries)
        XCTAssertEqual(try NativeEngineDefaults.saved(defaults: defaults), selected)
        XCTAssertEqual(try AdmittedEngineSelection.read(defaults: defaults), selected)
        XCTAssertEqual(EngineDefaults.defaultEngine(defaults), .calimocho)
        XCTAssertEqual(defaults.string(forKey: "Xodus.lifecycle.registry"), rendered.url.path)
        XCTAssertTrue(try NativeEngineDefaults.mayPrepareAutomatically(
            defaults: defaults, home: home, enginesRoot: engines, registries: registries))
        let relocatedHome = home.appendingPathComponent("relocated")
        let relocatedEngines = relocatedHome.appendingPathComponent("Library/Application Support/Xode/Engines")
        let relocatedRegistries = relocatedHome.appendingPathComponent("Library/Application Support/Xodus/EngineRegistries")
        try FileManager.default.createDirectory(at: relocatedRegistries, withIntermediateDirectories: true)
        let stale = relocatedRegistries.appendingPathComponent(rendered.url.lastPathComponent)
        let oldBytes = try Data(contentsOf: rendered.url)
        try oldBytes.write(to: stale)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stale.path)
        XCTAssertTrue(try NativeEngineDefaults.mayPrepareAutomatically(defaults: defaults,
            home: relocatedHome, enginesRoot: relocatedEngines, registries: relocatedRegistries))
        let movedRoot = relocatedEngines.appendingPathComponent(pin.engineName)
        let movedRegistry = try CalimochoReleaseEngines.renderRegistry(.init(pin: pin, root: movedRoot,
            manifest: manifest, wine: movedRoot.appendingPathComponent("bin/wine"),
            wineserver: movedRoot.appendingPathComponent("bin/wineserver"), environment: [:]),
            registries: relocatedRegistries)
        let movedSelection = AdmittedEngineSelection(registryPath: movedRegistry.url.path,
            inspection: inspection(registry: movedRegistry.digest))
        try NativeEngineDefaults.commitAutomatic(movedSelection,
            expected: .init(defaults), defaults: defaults, home: relocatedHome,
            enginesRoot: relocatedEngines, registries: relocatedRegistries)
        XCTAssertEqual(try AdmittedEngineSelection.read(defaults: defaults), movedSelection)
        XCTAssertEqual(try NativeEngineDefaults.automatic(defaults: defaults, selection: movedSelection,
            home: relocatedHome, enginesRoot: relocatedEngines, registries: relocatedRegistries)?.previousHomes, [home.path])
        XCTAssertEqual(try Data(contentsOf: stale), oldBytes)
        XCTAssertEqual(try Data(contentsOf: rendered.url), oldBytes)
        XCTAssertNotEqual(movedRegistry.url.lastPathComponent, stale.lastPathComponent)
        XCTAssertTrue(try NativeEngineDefaults.mayPrepareAutomatically(defaults: defaults,
            home: relocatedHome, enginesRoot: relocatedEngines, registries: relocatedRegistries))
        try Data("changed".utf8).write(to: movedRegistry.url)
        XCTAssertThrowsError(try NativeEngineDefaults.mayPrepareAutomatically(
            defaults: defaults, home: relocatedHome, enginesRoot: relocatedEngines, registries: relocatedRegistries))
        XCTAssertEqual(try Data(contentsOf: movedRegistry.url), Data("changed".utf8))
    }

    @MainActor
    func testConcurrentSavedSelectionOrRegistryCannotBeOverwritten() throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = AdmittedEngineSelection(registryPath: "/explicit/selection", inspection: inspection())
        for key in [NativeEngineDefaults.preferenceKey, AdmittedEngineSelection.preferenceKey,
                    "Xodus.lifecycle.registry", "Xodus.lifecycle.engine.calimocho"] {
            defaults.removePersistentDomain(forName: suite)
            let before = NativeEngineDefaults.PreferenceSnapshot(defaults)
            if key.contains("Admission") || key == AdmittedEngineSelection.preferenceKey {
                defaults.set(try JSONEncoder().encode(selected), forKey: key)
            } else {
                defaults.set("/explicit/changed", forKey: key)
            }
            let concurrent = NativeEngineDefaults.PreferenceSnapshot(defaults)
            XCTAssertThrowsError(try NativeEngineDefaults.commitAutomatic(selected, expected: before, defaults: defaults))
            XCTAssertEqual(concurrent, NativeEngineDefaults.PreferenceSnapshot(defaults))
        }
    }

    func testLegacyChoicesRemainStoredWhileV2ControlsLaunch() throws {
        var saved = game()
        let selection = AdmittedEngineSelection(registryPath: "/explicit/old", inspection: inspection())
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for provider in [nil, .crossover, .gptk3, .gptk4, .standaloneWine, .calimocho] as [RuntimeProviderKind?] {
            saved.engineOverride = provider
            saved.engineSelection = selection
            let before = try encoder.encode(saved)
            XCTAssertNil(try NativeLaunchConfiguration.explicitSelection(game: saved))
            XCTAssertEqual(try encoder.encode(saved), before)
        }
        saved.engineOverride = .calimocho
        saved.engineSelection = nil
        let legacy = saved
        XCTAssertNil(try NativeLaunchConfiguration.explicitSelection(game: saved))
        XCTAssertEqual(saved, legacy)
        saved.engineOverrideV2 = .init(selection: selection)
        XCTAssertEqual(try NativeLaunchConfiguration.explicitSelection(game: saved), selection)
        XCTAssertEqual(saved.engineOverride, legacy.engineOverride)
        XCTAssertEqual(saved.engineSelection, legacy.engineSelection)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var override = try XCTUnwrap(object["engineOverrideV2"] as? [String: Any])
        override["version"] = 1
        object["engineOverrideV2"] = override
        let invalid = try JSONDecoder().decode(InstalledGame.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try NativeLaunchConfiguration.explicitSelection(game: invalid)) {
            guard case NativeLaunchError.selectionChanged = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        saved.engineOverrideV2 = .init(selection: selection, chosenAt: Date(timeIntervalSince1970: .infinity))
        XCTAssertThrowsError(try NativeLaunchConfiguration.explicitSelection(game: saved)) {
            guard case NativeLaunchError.selectionChanged = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testMissingExactAutomaticLegacyRegistryCanMigrateButExplicitChoicesCannot() throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = isolatedHome()
        let path = home.path + "/src/copilot-worktrees/calimocho/dragoshont-cautious-potato/build/winehq-11.20/metal-port-11b-private-binding-01/calimocho-wine11.20-gptk4b3-tls-vulkan-private.registry.local.PERF-FROZEN-170ca4ad.json"
        let selection = AdmittedEngineSelection(registryPath: path, inspection: inspection(
            engine: "calimocho-wine11.20-gptk4b3-tls-vulkan-private",
            registry: "170ca4ad08a5274b614e74bf740866ef219a97fdc7855270c5d8fa03192ed609",
            wine: "f6d0546fad2d0dafaa09a9fe6cabe75bb070567df6b0933ecd3622dcb6349194",
            server: "e3ec4e7e76cee273f17d5fa3459902642f73d6921e94c576aa74e8cdbdcd7da1"))
        XCTAssertTrue(try NativeEngineDefaults.missingAutomaticLegacyDefault(selection, defaults: defaults, home: home))
        defaults.set("explicit-engine", forKey: "Xodus.lifecycle.engine.calimocho")
        XCTAssertFalse(try NativeEngineDefaults.missingAutomaticLegacyDefault(selection, defaults: defaults, home: home))
        defaults.removeObject(forKey: "Xodus.lifecycle.engine.calimocho")
        let arbitrary = AdmittedEngineSelection(registryPath: "/explicit/removed/registry", inspection: selection.inspection)
        XCTAssertFalse(try NativeEngineDefaults.missingAutomaticLegacyDefault(arbitrary, defaults: defaults, home: home))
        defaults.set(try JSONEncoder().encode(arbitrary), forKey: NativeEngineDefaults.preferenceKey)
        XCTAssertFalse(try NativeEngineDefaults.mayPrepareAutomatically(defaults: defaults))
    }

    func testRelocatedAutomaticRecordRequiresExactProvenanceAndPreservesExplicitRegistry() throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldHome = "/Users/previous-ode-home"
        let home = isolatedHome()
        let engines = home.appendingPathComponent("Library/Application Support/Xode/Engines")
        let registries = home.appendingPathComponent("Library/Application Support/Xodus/EngineRegistries")
        let proof = inspection()
        let selection = AdmittedEngineSelection(registryPath: oldHome
            + "/Library/Application Support/Xodus/EngineRegistries/\(CalimochoReleasePin.release06.engineName)-ode-default-v2-\(proof.registrySha256!).json",
            inspection: proof)
        let record = NativeEngineDefaults.Automatic(selection: selection, home: oldHome,
            enginesRoot: oldHome + "/Library/Application Support/Xode/Engines",
            registriesRoot: oldHome + "/Library/Application Support/Xodus/EngineRegistries")
        defaults.set(try JSONEncoder().encode(selection), forKey: NativeEngineDefaults.preferenceKey)
        XCTAssertFalse(try NativeEngineDefaults.mayPrepareAutomatically(
            defaults: defaults, home: home, enginesRoot: engines, registries: registries))
        defaults.set(try JSONEncoder().encode(record), forKey: NativeEngineDefaults.automaticKey)
        defaults.set(selection.registryPath, forKey: "Xodus.lifecycle.registry")
        XCTAssertTrue(try NativeEngineDefaults.mayPrepareAutomatically(
            defaults: defaults, home: home, enginesRoot: engines, registries: registries))
        defaults.set("/explicit/registry", forKey: "Xodus.lifecycle.registry")
        XCTAssertFalse(try NativeEngineDefaults.mayPrepareAutomatically(
            defaults: defaults, home: home, enginesRoot: engines, registries: registries))
        XCTAssertEqual(defaults.string(forKey: "Xodus.lifecycle.registry"), "/explicit/registry")
        EngineDefaults.setDefaultEngine(.calimocho, defaults)
        XCTAssertNil(defaults.data(forKey: NativeEngineDefaults.automaticKey))
    }

    func testExistingPrefixDataFailsBeforeCreatingOrMovingAnything() throws {
        let home = isolatedHome()
        let id = UUID()
        let old = home.appendingPathComponent("Library/Application Support/Xodus/Prefixes/\(id.uuidString)/old-engine")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let save = old.appendingPathComponent("save.dat")
        try Data("preserve-save".utf8).write(to: save)
        XCTAssertThrowsError(try NativeLaunchConfiguration.defaultPrefix(gameID: id, engine: "new-engine", home: home)) {
            XCTAssertTrue($0.localizedDescription.contains(old.path))
        }
        XCTAssertEqual(try Data(contentsOf: save), Data("preserve-save".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.deletingLastPathComponent()
            .appendingPathComponent("new-engine").path))
        XCTAssertEqual(try NativeLaunchConfiguration.defaultPrefix(gameID: id, engine: "old-engine", home: home).path, old.path)
    }

    @MainActor
    func testMissingTitleSpecificEngineFailsWithoutDefaultMutation() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        var title = game()
        title = InstalledGame(id: title.id, title: "No Man's Sky", identityName: "HelloGames.NoMansSky",
            version: "1", storeId: "BQVQTL3PCH05", folder: "/Unavailable/Game", launcher: "", importedAt: Date())
        let before = NativeEngineDefaults.PreferenceSnapshot(defaults)
        do {
            _ = try await NativeLaunchConfiguration.resolveDefault(game: title,
                configuration: BackendConfiguration(executable: URL(fileURLWithPath: "/Unavailable/cli"),
                    stateDirectory: URL(fileURLWithPath: "/Unavailable/state")),
                provider: .calimocho, defaults: defaults,
                engineDefaults: .init(version: 1, defaultEngine: "new-engine", bindings: []))
            XCTFail("A title-specific recipe cannot silently move to a new engine")
        } catch NativeLaunchError.migrationRequired(let message) {
            XCTAssertTrue(message.contains("pinned engine"))
            XCTAssertTrue(message.contains("not moved"))
        }
        XCTAssertEqual(before, NativeEngineDefaults.PreferenceSnapshot(defaults))
    }

    @MainActor
    func testPinnedTitleReportsItsOwnMissingEngineDespiteUnrelatedDefaultDrift() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = isolatedHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let drifted = try installDriftedPreviousDefault(home: home, defaults: defaults)
        let before = NativeEngineDefaults.PreferenceSnapshot(defaults)
        let title = InstalledGame(id: UUID(), title: "No Man's Sky", identityName: "HelloGames.NoMansSky",
            version: "1", storeId: "BQVQTL3PCH05", folder: "/Unavailable/Game", launcher: "", importedAt: Date())
        do {
            _ = try await NativeLaunchConfiguration.resolveDefault(game: title,
                configuration: BackendConfiguration(executable: URL(fileURLWithPath: "/Unavailable/cli"),
                    stateDirectory: home), provider: .calimocho, defaults: defaults,
                engineDefaults: .init(version: 1, defaultEngine: "new-engine", bindings: []))
            XCTFail("The pinned title must not use a different engine")
        } catch NativeLaunchError.migrationRequired(let message) {
            XCTAssertTrue(message.contains("pinned engine"))
        }
        XCTAssertEqual(before, NativeEngineDefaults.PreferenceSnapshot(defaults))
        XCTAssertEqual(try Data(contentsOf: drifted), Data("changed registry".utf8))
    }

    @MainActor
    func testRealExplicitEngineAdmissionIgnoresUnrelatedDefaultDrift() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let parent = environment["XODUS_REQ193_INTEGRATION_ROOT"],
              let cliPath = environment["XODUS_REQ193_BACKEND_CLI"] else {
            throw XCTSkip("Set the existing REQ193 integration root and backend CLI to check the installed engine.")
        }
        let home = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent("explicit-preservation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cli = URL(fileURLWithPath: cliPath)
        let identity = try XCTUnwrap(NativeAuthHostBinding.forExecutable(cli))
        let configuration = BackendConfiguration(executable: cli, stateDirectory: home, executableIdentity: identity)
        let pin = CalimochoReleasePin.release06
        let binding = NativeEngineDefaults.Binding(registryPath: nil, registrySha256: nil,
            engineName: pin.engineName, wineSha256: pin.wineSha256, wineserverSha256: pin.wineserverSha256)
        let selected = try await binding.inspect(configuration: configuration,
            enginesRoot: CalimochoReleaseEngines.defaultEnginesRoot,
            registries: home.appendingPathComponent("explicit-registries"))
        let drifted = try installDriftedPreviousDefault(home: home, defaults: defaults)
        let before = NativeEngineDefaults.PreferenceSnapshot(defaults)
        var title = game()
        title.engineOverrideV2 = .init(selection: selected)
        do {
            _ = try await NativeLaunchConfiguration.resolveDefault(game: title, configuration: configuration,
                provider: .calimocho, defaults: defaults, runtime: nil,
                engineDefaults: .init(version: 1, defaultEngine: pin.engineName, bindings: []))
            XCTFail("No qualified runtime was provided")
        } catch NativeLaunchError.runtimeNotQualified {
            // This boundary follows a fresh admission by the real backend.
        }
        XCTAssertEqual(before, NativeEngineDefaults.PreferenceSnapshot(defaults))
        XCTAssertEqual(try Data(contentsOf: drifted), Data("changed registry".utf8))
    }
}
