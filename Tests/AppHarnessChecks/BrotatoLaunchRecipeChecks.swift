// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import CryptoKit
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
        XCTAssertEqual(profile.sourceRecipeSHA256,
            "8e71ce9f47efe4573eba7ac327c7f248e88e7087561c7fe1db1747ff7430f429")
        XCTAssertEqual(profile.arguments, ["--exe", "Brotato.exe", "--no-auto-dismiss"])
        XCTAssertEqual(profile.environment, [:])
        XCTAssertEqual(Set(profile.unsetEnvironment ?? []),
            ["XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM"])
        XCTAssertEqual(profile.runtime?.primarySHA256,
            "6c9d97d3b1690c6c314d303be5d6da82f630808fc33a57395c8e102216a802a8")
        XCTAssertEqual(profile.runtime?.legacySHA256,
            "cfe7e5f837fabc51b8066809ca69c2ee0a7852512afbb1979190ec495b0b8b96")
        let candidate = try XCTUnwrap(NativeTitleLaunchProfile.bundledProfiles().first {
            $0.productID == "9P9VNSQK1W3K" && $0.provider == .calimocho
        })
        XCTAssertEqual(candidate.engine, profile.engine)
        XCTAssertEqual(candidate.registrySHA256, profile.registrySHA256)
        XCTAssertEqual(candidate.sourceRecipe, profile.sourceRecipe)
        XCTAssertEqual(candidate.shimSet, NativeShimReference.brotatoWeb03CandidateID)
        XCTAssertEqual(candidate.shimDirectory.map(NativeTitleLaunchProfile.expand),
                       NativeShimReference.brotatoSourceCandidate.directory.path)
        XCTAssertEqual(candidate.sourceRecipeSHA256, profile.sourceRecipeSHA256)
        XCTAssertEqual(candidate.candidateManifest, "BrotatoWeb03Candidate/manifest.json")
        XCTAssertEqual(candidate.candidateManifestSHA256,
            "95530323eb22fcbdfa91b5cb9d43f090a42d1758fc749246247f9b160f4ff17e")
        XCTAssertEqual(candidate.engineRecipe, "BrotatoWeb03Candidate/Recipe/9P9VNSQK1W3K.json")
        XCTAssertEqual(candidate.engineRecipeSHA256,
            "3d9d3809481affe0b63ae7832f0c8987d5a247806b670f78a146b54964b3973c")
        XCTAssertEqual(candidate.diagnosticReceiptSHA256,
            "c8cc7790d331f5b36abdd769769ff23f1d998e53022760fe237564a026339895")
        XCTAssertEqual(candidate.runtime?.primarySHA256, profile.runtime?.primarySHA256)
        XCTAssertEqual(candidate.runtime?.legacySHA256, profile.runtime?.legacySHA256)
        XCTAssertFalse(NativeShimReference.brotatoSourceCandidate.hashes.keys.contains("windows.web.dll"))
        XCTAssertEqual(Set(NativeShimReference.brotatoSourceCandidate.hashes.keys), ["XCurl.dll", "cacert.pem"])
        XCTAssertNil(candidate.preservedPrefixPath)
        XCTAssertEqual(candidate.arguments, profile.arguments)
        XCTAssertEqual(candidate.environment, [:])
        let candidateEnvironment = try candidate.validatedLaunchEnvironment()
        XCTAssertEqual(Set(candidateEnvironment.keys), ["XODE_RECIPES_DIR"])
        XCTAssertNil(candidateEnvironment["WINEDEBUG"],
                     "Registry precedence requires diagnostics in the post-registry producer recipe")
        XCTAssertEqual(try profile.validatedLaunchEnvironment(), [:],
                       "The ordinary historical route must not inherit diagnostic logging")
        let recipeDirectory = try XCTUnwrap(candidateEnvironment["XODE_RECIPES_DIR"])
        XCTAssertEqual(URL(fileURLWithPath: recipeDirectory).lastPathComponent, "Recipe")
        let recipeURL = URL(fileURLWithPath: recipeDirectory).appendingPathComponent("9P9VNSQK1W3K.json")
        let recipeData = try Data(contentsOf: recipeURL)
        XCTAssertEqual(SHA256.hash(data: recipeData).map { String(format: "%02x", $0) }.joined(),
                       candidate.engineRecipeSHA256)
        let recipe = try XCTUnwrap(JSONSerialization.jsonObject(with: recipeData) as? [String: Any])
        let launch = try XCTUnwrap(recipe["launch"] as? [String: Any])
        XCTAssertEqual(launch["dllOverrides"] as? String,
                       "mscoree,mshtml=;windows.web=n;wintypes=n;xgameruntime=n,b")
        XCTAssertNil(launch["wineDebug"])
        XCTAssertEqual(candidate.prefixRegistryImports?.count, 1)
        XCTAssertEqual(candidate.prefixRegistryImports?.first?.path,
            "${HOME}/Library/Application Support/Ode to X/Engines/profiles/brotato-web03-native-vector-v1/Vector.reg")
        XCTAssertEqual(candidate.prefixRegistryImports?.first?.sha256,
                       "fd207f820aa20b6bfae50d712b3afd655adefa9f692864c1c3822ff1b93a6d80")
        XCTAssertEqual(candidate.prefixOverlays?.count, 2)
        XCTAssertEqual(candidate.prefixOverlays?.compactMap(\.destination),
                       ["drive_c/windows/system32/windows.web.dll", "drive_c/windows/system32/wintypes.dll"])
        XCTAssertEqual(candidate.prefixOverlays?.map(\.sha256), [
            "6e334c81e31f428cd4f524cd5539d1825e8e55cb2df1faa102ba0c3df857dfe8",
            "d19da3e350f70116097eb200a25aa31497415ed3999bb2d87faf7b724b7d2e74"
        ])
        let manifestData = try Data(contentsOf: LaunchRecipeResources.brotatoWeb03CandidateManifestURL())
        XCTAssertEqual(SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined(),
                       candidate.candidateManifestSHA256)
        let ordinaryData = try Data(contentsOf: LaunchRecipeResources.brotatoSourceCandidateRecipeURL())
        XCTAssertEqual(SHA256.hash(data: ordinaryData).map { String(format: "%02x", $0) }.joined(),
                       "9b53f2ad3a5d82a22433f09dc41a45f6e3db401072c3d9e4734c361fd6340c9b")
        let ordinary = try XCTUnwrap(JSONSerialization.jsonObject(with: ordinaryData) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap((ordinary["launch"] as? [String: Any])?["dllOverrides"] as? String),
                       "mscoree,mshtml=;windows.web=b;xgameruntime=n,b")
        let diagnosticData = try Data(contentsOf: LaunchRecipeResources.brotatoLoaderDiagnosticRecipeURL())
        XCTAssertEqual(SHA256.hash(data: diagnosticData).map { String(format: "%02x", $0) }.joined(),
                       "84e79412ea69873c5dee75e2f833dba6245affdecd38509c5996e48fa4ed9076")
        var diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticData) as? [String: Any])
        let diagnosticLaunch = try XCTUnwrap(diagnostic["launch"] as? [String: Any])
        XCTAssertEqual(diagnosticLaunch["wineDebug"] as? String, "-all,+timestamp,+loaddll,+seh")
        var ordinaryLaunch = diagnosticLaunch
        ordinaryLaunch.removeValue(forKey: "wineDebug")
        diagnostic["launch"] = ordinaryLaunch
        XCTAssertEqual(diagnostic as NSDictionary, ordinary as NSDictionary,
                       "The separate diagnostic recipe remains an exact debug-only variant of ordinary")
        XCTAssertNil(candidate.dllOverrides)
        XCTAssertEqual(Set(candidate.unsetEnvironment ?? []),
            ["XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM"])
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
        XCTAssertEqual(launch.shims.directory, NativeShimReference.brotatoSourceCandidate.directory)
        XCTAssertEqual(launch.shims.hashes, NativeShimReference.brotatoSourceCandidate.hashes)
        let candidateProfile = try XCTUnwrap(launch.profile)
        XCTAssertEqual(try launch.admittedSetupArguments(), [
            "--brotato-web03-setup-dir",
            NSHomeDirectory() + "/Library/Application Support/Ode to X/Engines/profiles/brotato-web03-native-vector-v1"
        ])
        let candidateEnvironment = try candidateProfile.validatedLaunchEnvironment()
        let recipeDirectory = try XCTUnwrap(candidateEnvironment["XODE_RECIPES_DIR"])
        let recipeURL = URL(fileURLWithPath: recipeDirectory).appendingPathComponent("9P9VNSQK1W3K.json")
        let recipeData = try Data(contentsOf: recipeURL)
        let recipe = try XCTUnwrap(JSONSerialization.jsonObject(with: recipeData) as? [String: Any])
        let recipeLaunch = try XCTUnwrap(recipe["launch"] as? [String: Any])
        XCTAssertEqual(recipeLaunch["dllOverrides"] as? String,
                       "mscoree,mshtml=;windows.web=n;wintypes=n;xgameruntime=n,b")
        XCTAssertEqual(candidateProfile.prefixOverlays?.count, 2)
        XCTAssertEqual(candidateProfile.prefixRegistryImports?.count, 1)
        XCTAssertNil(candidateProfile.preservedPrefixPath)
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
    func testWeb03AdmissionReachesMissingSetupFileWithoutReplacingRegistry() async throws {
        let configuration = try configuration()
        let game = try installedGame()
        let suite = "io.github.dragoshont.ode.brotato-web03-admission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let launch = try await NativeLaunchConfiguration.resolveDefault(
            game: game, configuration: configuration, provider: .calimocho, defaults: defaults)
        let profile = try XCTUnwrap(launch.profile)
        let registration = try XCTUnwrap(profile.prefixRegistryImports?.first)
        guard !FileManager.default.fileExists(atPath: registration.url.path) else {
            throw XCTSkip("The real setup registration exists; no artifact is removed for this check.")
        }
        do {
            _ = try await launch.arguments()
            XCTFail("The absent pinned setup registration must refuse argument construction")
        } catch {
            XCTAssertEqual(error as? GameScriptError, .invalidDestination,
                           "Exact Web03 admission must reach missing-file path verification, not invalidProfile")
        }
        XCTAssertEqual(launch.registry.path, launch.admittedSelection?.registryPath)
        XCTAssertEqual(launch.admittedSelection?.inspection.registrySha256,
                       "fe35dba8938abbe3ca921cc4f92abd65ec8a539b1bac20ac5cf58a18213ce48d")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.prefix.path))
    }

    @MainActor
    func testWeb03SetupAdmissionRejectsChangesToExactTuple() async throws {
        let configuration = try configuration()
        let game = try installedGame()
        let suite = "io.github.dragoshont.ode.brotato-web03-tuple.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let launch = try await NativeLaunchConfiguration.resolveDefault(
            game: game, configuration: configuration, provider: .calimocho, defaults: defaults)
        let original = try XCTUnwrap(launch.profile)
        var changedHash = original
        let registration = try XCTUnwrap(original.prefixRegistryImports?.first)
        changedHash.prefixRegistryImports = [.init(path: registration.path, sha256: String(repeating: "0", count: 64))]
        var extraOverlay = original
        extraOverlay.prefixOverlays?.append(try XCTUnwrap(original.prefixOverlays?.first))
        var changedDestination = original
        let overlay = try XCTUnwrap(original.prefixOverlays?.first)
        changedDestination.prefixOverlays?[0] = .init(
            path: overlay.path, sha256: overlay.sha256, destination: "drive_c/windows/system32/other.dll")
        var changedRecipe = original
        changedRecipe.engineRecipeSHA256 = "9b53f2ad3a5d82a22433f09dc41a45f6e3db401072c3d9e4734c361fd6340c9b"
        var changedID = original
        changedID.shimSet = NativeShimReference.brotatoSourceCandidateID
        var extraOverride = original
        extraOverride.dllOverrides = "windows.web=b"
        var missingSetup = original
        missingSetup.prefixRegistryImports = nil
        for profile in [changedHash, extraOverlay, changedDestination, changedRecipe,
                        changedID, extraOverride, missingSetup] {
            let invalid = NativeLaunchConfiguration(engine: launch.engine, registry: launch.registry,
                prefix: launch.prefix, runtime: launch.runtime, profile: profile, shims: launch.shims,
                admittedSelection: launch.admittedSelection)
            XCTAssertThrowsError(try invalid.admittedSetupArguments()) { error in
                guard case NativeLaunchError.invalidProfile = error else {
                    return XCTFail("Expected exact invalidProfile refusal, got \(error)")
                }
            }
        }
        let otherSelection = try await inspect(.release04, configuration: configuration)
        let otherRegistry = NativeLaunchConfiguration(engine: launch.engine,
            registry: URL(fileURLWithPath: otherSelection.registryPath), prefix: launch.prefix,
            runtime: launch.runtime, profile: original, shims: launch.shims,
            admittedSelection: otherSelection)
        XCTAssertThrowsError(try otherRegistry.admittedSetupArguments()) { error in
            guard case NativeLaunchError.invalidProfile = error else {
                return XCTFail("Web03 must refuse an admitted non-fe35 registry, got \(error)")
            }
        }
        var ordinary = original
        ordinary.prefixRegistryImports = nil
        ordinary.prefixOverlays = nil
        let noSetup = NativeLaunchConfiguration(engine: launch.engine, registry: launch.registry,
            prefix: launch.prefix, runtime: launch.runtime, profile: ordinary, shims: launch.shims,
            admittedSelection: launch.admittedSelection)
        XCTAssertEqual(try noSetup.admittedSetupArguments(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.prefix.path))
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
