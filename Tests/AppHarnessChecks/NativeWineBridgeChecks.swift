// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import OSLog
import XodusManagement
@testable import XodusPreview

final class NativeWineBridgeChecks: XCTestCase {
    @MainActor
    func testExistingAdmissionGatesRetainControlledPreflightFailures() async throws {
        var failures: [String] = []
        try await EngineManagementChecks.run { passed, name in
            if !passed { failures.append(name) }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func actualCLI() throws -> BackendConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard let cliPath = environment["XODUS_WINE_BRIDGE_CLI"] else {
            throw XCTSkip("Requires the actual source-reviewed native CLI; no substitutes.")
        }
        let cli = URL(fileURLWithPath: cliPath)
        return BackendConfiguration(executable: cli,
            stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            executableIdentity: NativeAuthHostBinding(executable: cli,
                sha256: NativeWineBridgeSelection.cliSHA256))
    }

    private func actualInputs() throws -> (URL, BackendConfiguration) {
        guard let export = ProcessInfo.processInfo.environment["XODUS_WINE_BRIDGE_EXPORT"] else {
            throw XCTSkip("Requires an actual source-reviewed Highball/Heroic export; no substitutes.")
        }
        return (URL(fileURLWithPath: export).appendingPathComponent("registry.json"), try actualCLI())
    }

    @MainActor
    private func launchLogs(action: () async throws -> Void) async throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-2))
        let predicate = NSPredicate(format: "subsystem == %@ AND category == %@",
                                    "io.github.dragoshont.xodus", "GameLaunch")
        let logger = Logger(subsystem: "io.github.dragoshont.xodus", category: "GameLaunch")
        let marker = UUID().uuidString
        let begin = "Diagnostic test begin \(marker)"
        let end = "Diagnostic test end \(marker)"
        logger.error("\(begin, privacy: .public)")
        try await action()
        logger.error("\(end, privacy: .public)")

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let entries = try store.getEntries(at: position, matching: predicate)
            let logEntries = entries.compactMap({ $0 as? OSLogEntryLog })
            if let beginIndex = logEntries.lastIndex(where: { $0.composedMessage == begin }),
               let endIndex = logEntries.lastIndex(where: { $0.composedMessage == end }),
               beginIndex < endIndex {
                return logEntries[(beginIndex + 1)..<endIndex].map(\.composedMessage)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Could not capture the bounded GameLaunch log interval.")
        return []
    }

    @MainActor
    private func launchLog(containing text: String, action: () async throws -> Void) async throws -> String? {
        try await launchLogs(action: action).last(where: { $0.contains(text) })
    }

    private func actualProvider(for registry: URL) throws -> String {
        let recipe = registry.deletingLastPathComponent().appendingPathComponent("recipe.json")
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: recipe))
        guard let object = value as? [String: Any], let provider = object["provider"] as? String else {
            throw XCTSkip("The actual provider export does not identify a provider.")
        }
        return provider
    }

    @MainActor
    func testActualConsumerSelectionPreservesGenericAdmissionAndDefaults() async throws {
        let (registry, configuration) = try actualInputs()
        let previousDefault = UserDefaults.standard.data(forKey: NativeEngineDefaults.preferenceKey)
        if try actualProvider(for: registry) == ExternalGameProvider.highball.rawValue {
            do {
                _ = try await NativeWineBridgeSelection.select(registry: registry, configuration: configuration)
                XCTFail("Highball's effective process store cannot be proven from its exported config")
            } catch NativeWineBridgeError.rejected(let reason) {
                XCTAssertTrue(reason.contains("effective engine store cannot be proven"))
            }
            XCTAssertEqual(UserDefaults.standard.data(forKey: NativeEngineDefaults.preferenceKey), previousDefault)
            return
        }
        let start = ContinuousClock.now
        let selection = try await NativeWineBridgeSelection.select(registry: registry, configuration: configuration)
        print("REQ187 complete consumer selection duration: \(start.duration(to: .now))")
        XCTAssertEqual(selection.inspection.admission, "genericWine")
        XCTAssertNil(selection.inspection.admittedProvider)
        XCTAssertFalse(selection.inspection.qualified)
        XCTAssertEqual(selection.inspection.registrySha256, selection.candidate.registrySHA256)
        XCTAssertEqual(UserDefaults.standard.data(forKey: NativeEngineDefaults.preferenceKey), previousDefault)
        XCTAssertNoThrow(try selection.validateUnusedPrefix())
        XCTAssertFalse(FileManager.default.fileExists(atPath: selection.prefix.path))
        let admitted = AdmittedEngineSelection(registryPath: registry.path, inspection: selection.inspection)
        XCTAssertThrowsError(try admitted.validate(registryPath: registry.path,
            engineName: selection.candidate.engine, registryDigest: selection.candidate.registrySHA256)) {
            guard case NativeLaunchError.providerNotAdmitted = $0 else {
                return XCTFail("Generic bridge must not become admitted Calimocho: \($0)")
            }
        }
        do {
            try await selection.validateLaunch(configuration: configuration, arguments: [])
            XCTFail("Missing selected digest/prefix must not launch")
        } catch NativeWineBridgeError.rejected { }
    }

    @MainActor
    func testActualConsumerCancellationDoesNotCreatePrefixOrInvokeGame() async throws {
        let (registry, configuration) = try actualInputs()
        let task = Task { try await NativeWineBridgeSelection.select(registry: registry, configuration: configuration) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled complete-source verification must not select an engine")
        } catch is CancellationError { }
    }

    @MainActor
    func testReviewedProviderCannotSwitchAfterExplicitSelection() async throws {
        let (original, configuration) = try actualInputs()
        guard try actualProvider(for: original) != ExternalGameProvider.highball.rawValue else {
            throw XCTSkip("Highball is fail-closed until its selected process's effective store can be proven.")
        }
        guard let otherExport = ProcessInfo.processInfo.environment["XODUS_WINE_BRIDGE_OTHER_EXPORT"] else {
            throw XCTSkip("Requires both actual reviewed provider exports for the cross-provider negative control.")
        }
        let root = original.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("negative-provider-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Owned cross-provider test export could not be removed: \(error)") }
        }
        for name in ["registry.json", "recipe.json"] {
            try FileManager.default.copyItem(at: original.deletingLastPathComponent().appendingPathComponent(name),
                                             to: root.appendingPathComponent(name))
        }
        let selected = try await NativeWineBridgeSelection.select(
            registry: root.appendingPathComponent("registry.json"), configuration: configuration)
        let other = URL(fileURLWithPath: otherExport)
        let otherRegistry = try Data(contentsOf: other.appendingPathComponent("registry.json"))
        XCTAssertNotEqual(otherRegistry, try Data(contentsOf: original))
        for name in ["registry.json", "recipe.json"] {
            try Data(contentsOf: other.appendingPathComponent(name)).write(to: root.appendingPathComponent(name))
        }
        let arguments = ["--registry", selected.registry.path, "--engine", selected.candidate.engine,
                         "--expected-registry-sha256", selected.candidate.registrySHA256,
                         "--prefix", selected.prefix.path, "--no-auto-dismiss", "--timeout-seconds", "120"]
        do {
            try await selected.validateLaunch(configuration: configuration, arguments: arguments)
            XCTFail("Another reviewed provider is not the user's explicit selection or an automatic fallback")
        } catch NativeWineBridgeError.rejected { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.prefix.path))
    }

    @MainActor
    func testActualMissingLegacyWineRetainsItsActionableInspectionFailure() async throws {
        let configuration = try actualCLI()
        let defaults = try NativeEngineDefaults.read()
        let binding = try XCTUnwrap(defaults.bindings.first {
            $0.engineName == "calimocho-wine11.20-gptk4b3-tls-vulkan-private"
        })
        let registryPath = try XCTUnwrap(binding.registryPath)
        let registry = try NativeEngineRegistry.read(URL(fileURLWithPath:
            NativeTitleLaunchProfile.expand(registryPath)))
        let entry = try XCTUnwrap(registry.engines.first { $0.name == binding.engineName })
        guard !FileManager.default.fileExists(atPath: entry.wine) else {
            throw XCTSkip("Missing-legacy-Wine boundary no longer applies after explicit engine recovery.")
        }
        do {
            _ = try await binding.inspect(configuration: configuration)
            XCTFail("Missing Wine cannot admit the legacy engine")
        } catch {
            guard case EngineInspectionError.rejected(let failure) = error else {
                return XCTFail("Genuine missing executable became a different failure: \(error)")
            }
            XCTAssertEqual(failure.code, "ENGINE_INSPECTION_FAILED")
            XCTAssertTrue(failure.message.contains("Wine must be an existing absolute executable path"))
            let message = InstalledGamesController.nativeLaunchFailureMessage(error)
            XCTAssertEqual(message, InstalledGameActionCopy.launchUnavailable)
            XCTAssertFalse(message.contains("saved Calimocho configuration has changed"))
            let captured = try await launchLog(containing: failure.message) {
                InstalledGamesController.recordNativeLaunchFailure(error)
            }
            let diagnostic = try XCTUnwrap(captured)
            XCTAssertTrue(diagnostic.contains(failure.message))
            XCTAssertTrue(diagnostic.contains("Restore the selected engine files or choose a verified build in Engines"))
            XCTAssertFalse(diagnostic.contains(NativeTitleLaunchProfile.expand(registryPath)))
        }
    }

    @MainActor
    func testTitlePinnedMissingEngineRetainsPrivateActionableDiagnostic() async throws {
        let configuration = try actualCLI()
        let catalog = try NativeEngineDefaults.read()
        let engine = "calimocho-wine11.20-gptk4b3-tls-vulkan-private"
        let binding = try XCTUnwrap(catalog.bindings.first { $0.engineName == engine })
        let (registry, _) = try binding.registry()
        let suite = "io.github.dragoshont.ode.title-preflight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let title = InstalledGame(id: UUID(), title: "No Man's Sky", identityName: "HelloGames.NoMansSky",
            version: "1", storeId: "BQVQTL3PCH05", folder: "/Unavailable/Game",
            launcher: "", importedAt: Date())
        let before = NativeEngineDefaults.PreferenceSnapshot(defaults)
        let failure = await InstalledGamesController.performNativePreflight(productID: title.storeId) {
            _ = try await NativeLaunchConfiguration.resolveDefault(game: title, configuration: configuration,
                provider: .calimocho, defaults: defaults, runtime: nil, engineDefaults: catalog)
        }
        let error = try XCTUnwrap(failure)

        XCTAssertEqual(InstalledGamesController.nativeLaunchFailureMessage(error),
                       InstalledGameActionCopy.launchUnavailable)
        XCTAssertEqual(InstalledGamesController.publicEngineInspectionReason(error),
                       "Wine must be an existing absolute executable path")
        guard case NativeLaunchError.titleEngineInspectionFailed(let actualEngine, .rejected(let failure)) = error else {
            return XCTFail("Title-pinned inspection lost its typed rejection: \(error)")
        }
        XCTAssertEqual(actualEngine, engine)
        XCTAssertEqual(failure.code, "ENGINE_INSPECTION_FAILED")
        XCTAssertEqual(failure.message, "Wine must be an existing absolute executable path")
        let inspection = EngineInspectionError.rejected(failure)
        XCTAssertEqual(error.localizedDescription,
            "This title requires its pinned engine \(engine). Its preflight failed: \(inspection.localizedDescription) Restore the matching configuration; no recipe or prefix was transplanted.")
        XCTAssertEqual(NativeEngineDefaults.PreferenceSnapshot(defaults), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.stateDirectory.path))
        XCTAssertFalse(InstalledGamesController.publicEngineInspectionReason(error)?.contains(registry) ?? true)

        let changed = EngineInspectionError.rejected(.init(code: "ENGINE_INSPECTION_FAILED",
            message: "Engine preflight: Wine entrypoint does not match its registered SHA256: \(registry)"))
        let release = EngineInspectionError.rejected(.init(code: "ENGINE_INSPECTION_FAILED",
            message: "ENGINE_RELEASE_FILE_DIGEST_MISMATCH"))
        for (cause, reason) in [(changed, "Wine executable does not match the selected engine"),
                                (release, "A Calimocho engine file no longer matches the verified release")] {
            let wrapped = NativeLaunchError.titleEngineInspectionFailed(engine, cause)
            XCTAssertEqual(InstalledGamesController.publicEngineInspectionReason(cause), reason)
            XCTAssertEqual(InstalledGamesController.publicEngineInspectionReason(wrapped), reason)
            XCTAssertFalse(reason.contains(registry))
            XCTAssertEqual(InstalledGamesController.nativeLaunchFailureMessage(wrapped),
                           InstalledGameActionCopy.launchUnavailable)
        }
        let unknown = EngineInspectionError.rejected(.init(code: "ENGINE_INSPECTION_FAILED",
            message: "Unrecognized failure at \(registry)"))
        let wrongCode = EngineInspectionError.rejected(.init(code: "OTHER_FAILURE",
            message: "Wine must be an existing absolute executable path"))
        for cause in [unknown, wrongCode, .failed] {
            XCTAssertNil(InstalledGamesController.publicEngineInspectionReason(cause))
            XCTAssertNil(InstalledGamesController.publicEngineInspectionReason(
                NativeLaunchError.titleEngineInspectionFailed(engine, cause)))
        }

        let absentRegistry = registry + ".missing"
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentRegistry))
        let absentBinding = NativeEngineDefaults.Binding(registryPath: absentRegistry,
            registrySha256: binding.registrySha256, engineName: binding.engineName,
            wineSha256: binding.wineSha256, wineserverSha256: binding.wineserverSha256)
        do {
            _ = try await NativeLaunchConfiguration.resolveDefault(game: title, configuration: configuration,
                provider: .calimocho, defaults: defaults, runtime: nil,
                engineDefaults: .init(version: 1, defaultEngine: engine, bindings: [absentBinding]))
            XCTFail("An absent title registry must not admit an engine")
        } catch NativeLaunchError.migrationRequired(let reason) {
            XCTAssertTrue(reason.contains("pinned engine"))
        }

        let cancelled = Task { @MainActor in
            try await NativeLaunchConfiguration.resolveDefault(game: title, configuration: configuration,
                provider: .calimocho, defaults: defaults, runtime: nil, engineDefaults: catalog)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled title-pinned preflight must not select an engine")
        } catch is CancellationError { }
        XCTAssertEqual(NativeEngineDefaults.PreferenceSnapshot(defaults), before)
    }

    @MainActor
    func testRealEngineDriftIsRejectedWithPrivateActionableDiagnostics() async throws {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["XODUS_REQ189_RELEASE_ROOT", "XODUS_REQ189_CLI",
                    "XODUS_REQ189_CLI_SHA256", "XODUS_REQ189_TEST_ROOT"]
        if keys.allSatisfy({ environment[$0] == nil }) {
            throw XCTSkip("Requires a verified release engine and source-reviewed CLI; no substitutes.")
        }
        guard let source = environment["XODUS_REQ189_RELEASE_ROOT"],
              let cliPath = environment["XODUS_REQ189_CLI"],
              let cliDigest = environment["XODUS_REQ189_CLI_SHA256"],
              let testParent = environment["XODUS_REQ189_TEST_ROOT"] else {
            return XCTFail("All real-engine test inputs must be supplied together")
        }
        guard EngineInspection.validDigest(cliDigest) else {
            return XCTFail("The real-engine CLI must have a valid expected SHA-256")
        }
        let pin = CalimochoReleasePin.release06
        let parent = URL(fileURLWithPath: testParent, isDirectory: true)
        guard parent.standardizedFileURL == parent, parent.resolvingSymlinksInPath() == parent else {
            return XCTFail("Engine test parent must be an existing physical directory")
        }
        let root = parent
            .appendingPathComponent("engine-drift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Owned engine test copy could not be removed: \(error)") }
        }
        let engines = root.appendingPathComponent("Engines", isDirectory: true)
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: false)
        let original = URL(fileURLWithPath: source, isDirectory: true).appendingPathComponent(pin.engineName)
        let copied = engines.appendingPathComponent(pin.engineName)
        try FileManager.default.copyItem(at: original, to: copied)
        try GameScriptFiles.checkPath(copied)

        let cli = URL(fileURLWithPath: cliPath)
        let identity = NativeAuthHostBinding(executable: cli, sha256: cliDigest)
        let configuration = BackendConfiguration(executable: cli, stateDirectory: root, executableIdentity: identity)
        let binding = NativeEngineDefaults.Binding(registryPath: nil, registrySha256: nil,
            engineName: pin.engineName, wineSha256: pin.wineSha256, wineserverSha256: pin.wineserverSha256)
        let selection = try await binding.inspect(configuration: configuration, enginesRoot: engines,
            registries: root.appendingPathComponent("Registries", isDirectory: true))
        XCTAssertTrue(selection.inspection.ready)
        XCTAssertEqual(selection.inspection.admission, "admitted")
        XCTAssertFalse(selection.inspection.qualified)
        let registryDigest = try XCTUnwrap(selection.inspection.registrySha256)
        let arguments = ["--registry", selection.registryPath, "--engine", pin.engineName,
                         "--expected-registry-sha256", registryDigest]
        let inspector = EngineInspectionClient()
        try await inspector.validateLaunch(configuration: configuration, arguments: arguments, selection: selection)

        let wine = copied.appendingPathComponent("bin/wine")
        let originalWine = try Data(contentsOf: wine)
        let wineHandle = try FileHandle(forWritingTo: wine)
        try wineHandle.seekToEnd()
        try wineHandle.write(contentsOf: Data([0]))
        try wineHandle.close()
        XCTAssertNotEqual(try CalimochoReleaseEngines.fileDigest(wine), pin.wineSha256)
        do {
            try await inspector.validateLaunch(configuration: configuration, arguments: arguments, selection: selection)
            XCTFail("A changed Wine entrypoint must not be admitted")
        } catch {
            guard case EngineInspectionError.rejected(let failure) = error else {
                return XCTFail("Changed Wine became a different failure: \(error)")
            }
            XCTAssertEqual(failure.code, "ENGINE_INSPECTION_FAILED")
            XCTAssertEqual(failure.message,
                "Engine preflight: Wine entrypoint does not match its registered SHA256: \(wine.path)")
            XCTAssertEqual(InstalledGamesController.nativeLaunchFailureMessage(error),
                           InstalledGameActionCopy.launchUnavailable)
            let captured = try await launchLog(containing: "Native launch failed.") {
                InstalledGamesController.recordNativeLaunchFailure(error)
            }
            let diagnostic = try XCTUnwrap(captured)
            XCTAssertTrue(diagnostic.contains("Wine executable does not match the selected engine"),
                          "The changed Wine reason must be public")
            XCTAssertTrue(diagnostic.contains("Restore the selected engine files or choose a verified build in Engines"),
                          "The changed Wine recovery route must be public")
            XCTAssertFalse(diagnostic.contains(wine.path))
        }

        let suite = "io.github.dragoshont.ode.preflight-check.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var game = InstalledGame(id: UUID(), title: "Engine inspection", identityName: "Example.Game",
                                 version: "1", storeId: "GAME00000001", folder: root.path,
                                 launcher: "", importedAt: Date())
        game.engineOverrideV2 = .init(selection: selection)
        let hypotheticalPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Xodus/Prefixes/\(game.id.uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hypotheticalPrefix.path))
        let before = NativeEngineDefaults.PreferenceSnapshot(defaults)
        var preflightError: Error?
        let preflightLogs = try await launchLogs {
            preflightError = await InstalledGamesController.performNativePreflight(productID: game.storeId) {
                _ = try await NativeLaunchConfiguration.resolveDefault(
                    game: game, configuration: configuration, provider: .calimocho, defaults: defaults,
                    runtime: nil, engineDefaults: .init(version: 1, defaultEngine: pin.engineName, bindings: []))
            }
        }
        guard let preflightError,
              case EngineInspectionError.rejected(let rejected) = preflightError else {
            return XCTFail("The real resolver must preserve the engine inspection failure: \(String(describing: preflightError))")
        }
        XCTAssertEqual(rejected.message,
                       "Engine preflight: Wine entrypoint does not match its registered SHA256: \(wine.path)")
        XCTAssertEqual(InstalledGamesController.nativeLaunchFailureMessage(preflightError),
                       InstalledGameActionCopy.launchUnavailable)
        let publicLogs = preflightLogs.joined(separator: "\n")
        XCTAssertTrue(publicLogs.contains("Wine executable does not match the selected engine"),
                      "Resolver preflight must publish the sanitized changed-Wine reason.")
        XCTAssertTrue(publicLogs.contains("Restore the selected engine files or choose a verified build in Engines"),
                      "Resolver preflight must publish the recovery route.")
        XCTAssertFalse(publicLogs.contains(wine.path),
                       "Resolver preflight must not publish the engine path.")
        XCTAssertEqual(NativeEngineDefaults.PreferenceSnapshot(defaults), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hypotheticalPrefix.path))

        let restore = try FileHandle(forWritingTo: wine)
        try restore.seek(toOffset: 0)
        try restore.write(contentsOf: originalWine)
        try restore.truncate(atOffset: UInt64(originalWine.count))
        try restore.close()
        XCTAssertEqual(try CalimochoReleaseEngines.fileDigest(wine), pin.wineSha256)
        try await inspector.validateLaunch(configuration: configuration, arguments: arguments, selection: selection)

        let server = copied.appendingPathComponent("bin/wineserver")
        let serverHandle = try FileHandle(forWritingTo: server)
        try serverHandle.seekToEnd()
        try serverHandle.write(contentsOf: Data([0]))
        try serverHandle.close()
        XCTAssertNotEqual(try CalimochoReleaseEngines.fileDigest(server), pin.wineserverSha256)
        do {
            try await inspector.validateLaunch(configuration: configuration, arguments: arguments, selection: selection)
            XCTFail("A changed release file must not be admitted")
        } catch {
            guard case EngineInspectionError.rejected(let failure) = error else {
                return XCTFail("Changed release file became a different failure: \(error)")
            }
            XCTAssertEqual(failure.code, "ENGINE_INSPECTION_FAILED")
            XCTAssertEqual(failure.message, "ENGINE_RELEASE_FILE_DIGEST_MISMATCH")
            XCTAssertEqual(InstalledGamesController.nativeLaunchFailureMessage(error),
                           InstalledGameActionCopy.launchUnavailable)
            let captured = try await launchLog(containing: "Native launch failed.") {
                InstalledGamesController.recordNativeLaunchFailure(error)
            }
            let diagnostic = try XCTUnwrap(captured)
            XCTAssertTrue(diagnostic.contains("A Calimocho engine file no longer matches the verified release"),
                          "The changed release-file reason must be public")
            XCTAssertTrue(diagnostic.contains("Restore the selected engine files or choose a verified build in Engines"),
                          "The changed release-file recovery route must be public")
            XCTAssertFalse(diagnostic.contains(server.path))
        }
        XCTAssertEqual(try CalimochoReleaseEngines.fileDigest(original.appendingPathComponent("bin/wine")),
                       pin.wineSha256)
        XCTAssertEqual(try CalimochoReleaseEngines.fileDigest(original.appendingPathComponent("bin/wineserver")),
                       pin.wineserverSha256)
    }

    @MainActor
    func testNativeLaunchDiagnosticKeepsOtherDetailsPrivate() async throws {
        let marker = UUID().uuidString
        let failure = NativeLaunchError.candidateBlocked("Private detail \(marker)")
        let prefix = "Native launch failed. Detail:"
        let captured = try await launchLog(containing: prefix) {
            InstalledGamesController.recordNativeLaunchFailure(failure)
        }
        let diagnostic = try XCTUnwrap(captured)
        guard diagnostic.hasPrefix(prefix) else { return XCTFail("Unexpected diagnostic: \(diagnostic)") }
        let renderedDetail = diagnostic.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(renderedDetail.isEmpty, "A privacy-protected detail should be present")
        XCTAssertFalse(renderedDetail.contains(marker))

        let inspection = EngineInspectionError.rejected(.init(code: "ENGINE_INSPECTION_FAILED",
            message: "Unrecognized engine detail \(marker)"))
        let capturedInspection = try await launchLog(containing: prefix) {
            InstalledGamesController.recordNativeLaunchFailure(inspection)
        }
        let inspectionDiagnostic = try XCTUnwrap(capturedInspection)
        let inspectionDetail = inspectionDiagnostic.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(inspectionDetail.isEmpty, "A privacy-protected engine detail should be present")
        XCTAssertFalse(inspectionDetail.contains(marker))

        var preflightError: Error?
        let preflightLogs = try await launchLogs {
            preflightError = await InstalledGamesController.performNativePreflight(productID: "GAME00000001") {
                throw inspection
            }
        }
        XCTAssertEqual(preflightError?.localizedDescription, inspection.localizedDescription)
        XCTAssertTrue(preflightLogs.contains { $0.contains("Play failed before launch: GAME00000001") })
        XCTAssertTrue(preflightLogs.contains { $0.hasPrefix(prefix) })
        XCTAssertFalse(preflightLogs.joined(separator: "\n").contains(marker))
    }

    @MainActor
    func testActualFH6MissingRuntimeStopsBeforeArgumentConstruction() async throws {
        let (registry, configuration) = try actualInputs()
        if try actualProvider(for: registry) == ExternalGameProvider.highball.rawValue {
            do {
                _ = try await NativeWineBridgeSelection.select(registry: registry, configuration: configuration)
                XCTFail("Highball must fail closed when its effective process store cannot be proven")
            } catch NativeWineBridgeError.rejected(let reason) {
                XCTAssertTrue(reason.contains("effective engine store cannot be proven"))
            }
            return
        }
        guard NativeRuntimePins.approved == nil,
              UserDefaults.standard.data(forKey: "Xodus.lifecycle.runtime") == nil else {
            throw XCTSkip("Missing-runtime boundary no longer applies after explicit runtime recovery.")
        }
        let folder = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Games/Xodus/ForzaHorizon6-Xbox")
        let installed = try MicrosoftGameConfig.read(folder: folder)
        XCTAssertEqual(installed.storeId, "9NR1R1XWLCNB")
        XCTAssertEqual(installed.identityName, "Microsoft.ForteBaseGame")
        let game = InstalledGame(id: UUID(), title: installed.title, identityName: installed.identityName,
            version: installed.version, storeId: installed.storeId, folder: folder.path,
            launcher: "", importedAt: Date())
        do {
            _ = try await NativeLaunchConfiguration.resolveDefault(game: game, configuration: configuration,
                                                                   provider: .standaloneWine)
            XCTFail("The explicit bridge must not enable generic Wine in normal Play")
        } catch NativeLaunchError.providerPolicy { }
        let selection = try await NativeWineBridgeSelection.select(registry: registry, configuration: configuration)
        XCTAssertThrowsError(try NativeLaunchConfiguration.resolveWineBridge(game: game, selection: selection)) {
            guard case NativeLaunchError.runtimeNotQualified = $0 else {
                return XCTFail("Missing real runtime must not substitute a pair: \($0)")
            }
            XCTAssertTrue(InstalledGamesController.nativeLaunchFailureMessage($0)
                .contains("local primary and legacy runtime pair"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: selection.prefix.path))
    }

    @MainActor
    func testChangedExportFailsBeforeNativeInspection() async throws {
        let (registry, configuration) = try actualInputs()
        let root = registry.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("negative-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Owned negative-test export could not be removed: \(error)") }
        }
        var changed = try Data(contentsOf: registry)
        changed.append(10)
        let selected = root.appendingPathComponent("registry.json")
        try changed.write(to: selected)
        do {
            _ = try await NativeWineBridgeSelection.select(registry: selected, configuration: configuration)
            XCTFail("A byte-changed registry cannot reuse prior inspection")
        } catch NativeWineBridgeError.rejected(let reason) {
            XCTAssertTrue(reason.contains("registry differs"))
        }
    }
}
