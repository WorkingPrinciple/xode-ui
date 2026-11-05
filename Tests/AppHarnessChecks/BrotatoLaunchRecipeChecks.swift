// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import XodusCore
import XodusManagement
@testable import XodusPreview

final class BrotatoLaunchRecipeChecks: XCTestCase {
    func testBundledBrotatoRestoresOnlyTheHistorical06Route() throws {
        let profile = try XCTUnwrap(NativeTitleLaunchProfile.bundledProfiles().first {
            $0.productID == "9P9VNSQK1W3K" && $0.provider == nil
        })
        XCTAssertEqual(profile.engine, "calimocho-11.20-4.0b3-06")
        XCTAssertNil(profile.preservedPrefixPath, "A fresh title-isolated prefix is not a historical save claim")
        XCTAssertEqual(profile.registrySHA256,
            "fe35dba8938abbe3ca921cc4f92abd65ec8a539b1bac20ac5cf58a18213ce48d")
        XCTAssertEqual(profile.arguments, ["--exe", "Brotato.exe", "--no-auto-dismiss"])
        XCTAssertEqual(profile.environment, [:])
        XCTAssertEqual(Set(profile.unsetEnvironment ?? []),
            ["XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM"])
        XCTAssertEqual(profile.runtime?.primarySHA256,
            "6c9d97d3b1690c6c314d303be5d6da82f630808fc33a57395c8e102216a802a8")
        XCTAssertEqual(profile.runtime?.legacySHA256,
            "cfe7e5f837fabc51b8066809ca69c2ee0a7852512afbb1979190ec495b0b8b96")
        let nms = try XCTUnwrap(NativeTitleLaunchProfile.bundledProfiles().first {
            $0.productID == "BQVQTL3PCH05" && $0.provider == nil
        })
        XCTAssertEqual(nms.engine, "calimocho-wine11.20-gptk4b3-tls-vulkan-private")
        XCTAssertEqual(nms.registrySHA256,
            "170ca4ad08a5274b614e74bf740866ef219a97fdc7855270c5d8fa03192ed609")
    }

    @MainActor
    func testActual06OverrideMatchesBut04AndDifferentRegistryDoNot() async throws {
        let configuration = try configuration()
        let selection = try await inspect(.release06, configuration: configuration)
        let game = try installedGame()
        try NativeLaunchConfiguration.validateOverride(selection, game: game)
        let older = try await inspect(.release04, configuration: configuration)
        XCTAssertThrowsError(try NativeLaunchConfiguration.validateOverride(older, game: game))
        let currentDefault = CalimochoInstalledRelease.registriesRoot.appendingPathComponent(
            "calimocho-11.20-4.0b3-06-ode-default-v3-bc748c7e64d832152ec4a2af09fb7b553c374d1bd1fe5c6fbfec0d7b5656a450.json")
        let otherInspection = try await EngineInspectionClient().inspect(
            executable: configuration.executable, registry: currentDefault,
            engine: CalimochoRelease.release06.rawValue,
            expectedDigest: "bc748c7e64d832152ec4a2af09fb7b553c374d1bd1fe5c6fbfec0d7b5656a450",
            executableIdentity: configuration.executableIdentity)
        let other = AdmittedEngineSelection(registryPath: currentDefault.path, inspection: otherInspection)
        XCTAssertThrowsError(try NativeLaunchConfiguration.validateOverride(other, game: game))
    }

    @MainActor
    func testActualFrozenRouteUsesStableTitlePrefixWithoutChangingChoice() async throws {
        let configuration = try configuration()
        let game = try installedGame()
        let suite = "io.github.dragoshont.ode.brotato-checks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = try await inspect(.release04, configuration: configuration)
        defaults.set(try JSONEncoder().encode(selection), forKey: NativeEngineDefaults.preferenceKey)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let prefix = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Xodus/Prefixes/\(game.id.uuidString)/calimocho-11.20-4.0b3-06")
        let launch = try await NativeLaunchConfiguration.resolveDefault(
            game: game, configuration: configuration, provider: .calimocho, defaults: defaults)
        XCTAssertEqual(launch.prefix, prefix)
        XCTAssertEqual(launch.engine, "calimocho-11.20-4.0b3-06")
        XCTAssertEqual(launch.admittedSelection?.inspection.registrySha256,
            "fe35dba8938abbe3ca921cc4f92abd65ec8a539b1bac20ac5cf58a18213ce48d")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.path),
                       "Resolution must not create a prefix or launch Wine")
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        var conflicting = game
        conflicting.engineOverrideV2 = GameEngineOverride(selection: selection)
        do {
            _ = try await NativeLaunchConfiguration.resolveDefault(
                game: conflicting, configuration: configuration, provider: .calimocho, defaults: defaults)
            XCTFail("An explicit conflicting override must not be replaced by the title recipe")
        } catch NativeLaunchError.configurationConflict {}
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        defaults.removeObject(forKey: NativeEngineDefaults.preferenceKey)
        let cleared = defaults.dictionaryRepresentation() as NSDictionary
        let implicit = try await NativeLaunchConfiguration.resolveDefault(
            game: game, configuration: configuration, provider: nil, defaults: defaults)
        XCTAssertEqual(implicit.engine, launch.engine)
        XCTAssertEqual(implicit.prefix, prefix)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, cleared,
                       "A frozen title route must not select or inspect an unrelated global default")
    }

    @MainActor
    func testMissingExactArtifactsRefuseWithoutCreatingPrefix() async throws {
        let configuration = try configuration()
        let game = try installedGame()
        let suite = "io.github.dragoshont.ode.brotato-artifacts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let launch = try await NativeLaunchConfiguration.resolveDefault(
            game: game, configuration: configuration, provider: .calimocho, defaults: defaults)
        let runtimePresent = [launch.runtime.primary.executable, launch.runtime.legacy.executable]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        let shimsPresent = launch.shims.hashes.keys.allSatisfy {
            FileManager.default.fileExists(atPath: launch.shims.directory.appendingPathComponent($0).path)
        }
        guard !runtimePresent || !shimsPresent else {
            throw XCTSkip("All exact artifacts are present; the missing-artifact refusal needs a genuinely absent artifact.")
        }
        do {
            _ = try await launch.arguments()
            XCTFail("Missing exact runtime/shim artifacts must refuse argument admission")
        } catch {
            XCTAssertTrue(error is GameScriptError || error is CocoaError || error is NativeLaunchError,
                          "Unexpected artifact failure: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.prefix.path))
        XCTAssertNil(defaults.object(forKey: NativeEngineDefaults.preferenceKey))
    }

    @MainActor
    private func inspect(_ release: CalimochoRelease,
                         configuration: BackendConfiguration) async throws -> AdmittedEngineSelection {
        let installed: CalimochoInstalledRelease
        if release == .release06 {
            installed = CalimochoInstalledRelease(
                registry: CalimochoInstalledRelease.registriesRoot.appendingPathComponent(
                    "calimocho-11.20-4.0b3-06-ode-default-v2-fe35dba8938abbe3ca921cc4f92abd65ec8a539b1bac20ac5cf58a18213ce48d.json"),
                registrySHA256: "fe35dba8938abbe3ca921cc4f92abd65ec8a539b1bac20ac5cf58a18213ce48d")
        } else {
            installed = try CalimochoInstalledRelease.locate(release: release)
        }
        let inspection = try await EngineInspectionClient().inspect(executable: configuration.executable,
            registry: installed.registry, engine: release.rawValue, expectedDigest: installed.registrySHA256,
            executableIdentity: configuration.executableIdentity)
        let selection = AdmittedEngineSelection(registryPath: installed.registry.path, inspection: inspection)
        try selection.validate(registryPath: installed.registry.path, engineName: release.rawValue,
                               registryDigest: installed.registrySHA256)
        return selection
    }

    private func installedGame() throws -> InstalledGame {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Games/Xodus/Brotato-Xbox")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("MicrosoftGame.config").path) else {
            throw XCTSkip("The actual installed Brotato package is unavailable; no game fixture is created.")
        }
        return InstalledGame(id: UUID(), title: "Brotato", identityName: "Brotato",
            version: "installed", storeId: "9P9VNSQK1W3K", folder: folder.path,
            launcher: "", importedAt: Date(), usesNativeLifecycle: true)
    }

    private func configuration() throws -> BackendConfiguration {
        let path = ProcessInfo.processInfo.environment["XODUS_ENGINE_INSPECTION_TEST_BACKEND"]
            ?? "/Applications/Ode to X.app/Contents/Resources/XodusEngine/xodus-cli"
        let executable = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("The actual CLI is unavailable; no substitute is used.")
        }
        return BackendConfiguration(executable: executable, stateDirectory: FileManager.default.temporaryDirectory,
            executableIdentity: try XCTUnwrap(NativeAuthHostBinding.forExecutable(executable)))
    }
}
