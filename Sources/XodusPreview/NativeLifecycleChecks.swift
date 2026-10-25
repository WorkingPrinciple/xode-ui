// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import XodusCore
import XodusManagement

@MainActor
enum NativeLifecycleChecks {
    static func launchOutcomeChecks(check: (Bool, String) -> Void) throws {
        let json = """
            {"version":1,"run_id":"2b9218c5-1251-4d57-9c3c-e0097a607dc9",
             "operation":"launch","product":"BQVQTL3PCH05","success":false,"exit_code":1,
             "error_code":"OPERATION_FAILED","error":"Account broker did not shut down cleanly",
             "wine_exit_code":0,"wine_termination_signal":null,
             "game_dir":"/fixture/game","log_dir":"/fixture/run",
             "result_path":"/fixture/run/result.json","progress_path":"/fixture/run/progress.jsonl"}
            """
        let old = try JSONDecoder().decode(NativeGameResult.self, from: Data(json.utf8))
        check(old.launchFailureMessage(stoppedByUser: true) == nil,
              "COR137: Owner Stop with the exact old NMS broker-failure receipt returns to Play without a message")
        check(old.launchFailureMessage(stoppedByUser: false) == nil,
              "COR137: Clean Wine exit with only broker teardown failure is diagnostic-only")
        let cancelled = try JSONDecoder().decode(NativeGameResult.self,
            from: Data(json.replacingOccurrences(of: "OPERATION_FAILED", with: "CANCELLED").utf8))
        check(cancelled.launchFailureMessage(stoppedByUser: true) == nil,
              "COR137: New launch CANCELLED plus known Stop intent returns to Play without installer copy")
        check(cancelled.launchFailureMessage(stoppedByUser: false) == InstalledGameActionCopy.launchUnavailable,
              "COR137: Cancellation without owner Stop intent remains a generic launch failure")
        let crashed = try JSONDecoder().decode(NativeGameResult.self,
            from: Data(json.replacingOccurrences(of: "\"wine_exit_code\":0", with: "\"wine_exit_code\":1").utf8))
        check(crashed.launchFailureMessage(stoppedByUser: false) == InstalledGameActionCopy.launchUnavailable,
              "COR137: Genuine failed game exit stays visible through the existing generic launch surface")
        let install = try JSONDecoder().decode(NativeGameResult.self,
            from: Data(json.replacingOccurrences(of: "\"launch\"", with: "\"install\"")
                .replacingOccurrences(of: "OPERATION_FAILED", with: "CANCELLED").utf8))
        check(install.failureMessage.contains("Partial files") && install.failureMessage.contains("installation"),
              "COR137: Real install cancellation keeps installation recovery copy")
        let normal = try JSONDecoder().decode(NativeGameResult.self,
            from: Data(json.replacingOccurrences(of: "\"success\":false", with: "\"success\":true")
                .replacingOccurrences(of: "\"exit_code\":1", with: "\"exit_code\":0")
                .replacingOccurrences(of: "\"error_code\":\"OPERATION_FAILED\"", with: "\"error_code\":null").utf8))
        check(normal.launchFailureMessage(stoppedByUser: false) == nil,
              "COR137: Normal launch exit returns to Play without a message")
        check(InstalledGamesController.nativeLaunchFailureMessage(GameScriptError.failed(14))
              == InstalledGameActionCopy.launchUnavailable,
              "COR137: Launch error mapping never presents installer cancellation copy")
        do {
            try NativeLifecycleCancellation.check(operation: "launch", cancelled: true)
            check(false, "COR137: Lifecycle cancellation retains launch operation identity")
        } catch NativeLifecycleCancellation.launchStopped {
            check(true, "COR137: Lifecycle cancellation retains launch operation identity")
        }
        do {
            try NativeLifecycleCancellation.check(operation: "install", cancelled: true)
            check(false, "COR137: Lifecycle install cancellation keeps the existing installation contract")
        } catch GameScriptError.failed(14) {
            check(true, "COR137: Lifecycle install cancellation keeps the existing installation contract")
        }
    }

    static func run(check: (Bool, String) -> Void) async throws {
        check(NativePlayerFailure.message(errorCode: "TIMEOUT", error: nil, diagnostic: "",
            windowRecorded: nil, monitorReliable: false, success: false)?.contains("Open the launch log") == true,
            "A confirmed launcher timeout has plain-language copy and an actionable log route")
        check(NativePlayerFailure.message(errorCode: "OPERATION_FAILED", error: nil,
            diagnostic: "err:module:import_dll Library missing.dll not found",
            windowRecorded: false, monitorReliable: true, success: false)?.contains("runtime component") == true,
            "A loader's explicit missing-library report names a missing component, not an invented repair")
        check(NativePlayerFailure.message(errorCode: nil, error: nil, diagnostic: "",
            windowRecorded: false, monitorReliable: true, success: true)?.contains("before Ode to X detected its window") == true,
            "A clean exit with reliable empty window evidence is not described as playable")
        for reliable in [true, false] {
            check(NativePlayerFailure.message(errorCode: "ACCOUNT_UNAVAILABLE", error: nil,
                diagnostic: "err:module:import_dll Library missing.dll not found",
                windowRecorded: false, monitorReliable: reliable, success: false) == nil,
                "Account failures retain their specific recovery and cannot become no-window diagnoses")
        }
        check(NativePlayerFailure.message(errorCode: "OPERATION_FAILED", error: nil, diagnostic: "",
            windowRecorded: false, monitorReliable: false, success: false) == nil
              && NativePlayerFailure.message(errorCode: "OPERATION_FAILED", error: nil, diagnostic: "",
                windowRecorded: nil, monitorReliable: true, success: false) == nil
              && NativePlayerFailure.message(errorCode: nil, error: nil, diagnostic: "ordinary module noise",
                windowRecorded: true, monitorReliable: true, success: true) == nil,
              "Missing/broken monitor evidence and an observed window cannot fabricate a no-window failure")
        var progress = NativeGameProgress()
        for line in [
            #"{"event":"file_started","id":18446744073709551615,"name":"metadata","total_bytes":50}"#,
            #"{"event":"bytes","id":18446744073709551615,"delta_bytes":50}"#,
            #"{"event":"remaining","phase":"Downloading","remaining_bytes":100}"#,
            #"{"event":"bytes","id":0,"delta_bytes":25}"#,
            #"{"event":"completed"}"#
        ] { try progress.consume(Data(line.utf8)) }
        check(progress.bytesDone == 25 && progress.bytesTotal == 100 && progress.phase != .done,
              "Native lifecycle: UInt64 metadata progress is separate; completed never asserts success")
        for line in [#"{"event":"bytes","id":0,"delta_bytes":-1}"#,
                     #"{"event":"remaining","remaining_bytes":-1}"#,
                     #"{"event":"future"}"#] {
            do {
                try progress.consume(Data(line.utf8))
                check(false, "Native lifecycle rejects invalid progress")
            } catch { check(true, "Native lifecycle rejects invalid progress") }
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/NativeLifecycleChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Native lifecycle synthetic files cleaned after child exit") }
        }
        let failureLog = root.appendingPathComponent("player-evidence")
        try FileManager.default.createDirectory(at: failureLog, withIntermediateDirectories: false)
        let resultFixture = NativeGameResult(version: 1, runID: UUID().uuidString, operation: "launch",
            product: "FIXTURE00001", success: true, exitCode: 0, errorCode: nil,
            gameDirectory: root.path, logDirectory: failureLog.path,
            resultPath: failureLog.appendingPathComponent("result.json").path,
            progressPath: failureLog.appendingPathComponent("progress.jsonl").path)
        for (code, expected) in [
            ("CANCELLED", "cancelled"), ("TIMEOUT", "install operation took too long"),
            ("RESOURCE_BUSY", "in use"), ("ACCOUNT_UNAVAILABLE", "Keychain"),
            ("DISK_SPACE_FLOOR", "Free space"), ("DISK_SPACE_FLOOR_INVALID", "limit is invalid"),
            ("OPERATION_FAILED", "Open its log")
        ] {
            let failed = NativeGameResult(version: 1, runID: resultFixture.runID, operation: "install",
                product: resultFixture.product, success: false, exitCode: 1, errorCode: code,
                gameDirectory: resultFixture.gameDirectory, logDirectory: resultFixture.logDirectory,
                resultPath: resultFixture.resultPath, progressPath: resultFixture.progressPath)
            check(NativeGameResult.failureCodes.contains(code)
                  && failed.failureMessage.contains(expected) && !failed.failureMessage.contains("playable game"),
                  "Native lifecycle maps \(code) actionably without inventing a launch during installation")
        }
        try Data().write(to: failureLog.appendingPathComponent("windows.jsonl"))
        check(try await resultFixture.playerMessage()?.contains("before Ode to X detected its window") == true,
              "Player failure reader binds empty monitor evidence to the exact result run folder")
        try Data(#"{"dialog":false,"title":"Observed game"}"#.utf8)
            .write(to: failureLog.appendingPathComponent("windows.jsonl"))
        check(try await resultFixture.playerMessage() == nil,
              "Actual parsed game-window evidence suppresses no-window copy even after exit0")
        var warnedResult = resultFixture
        warnedResult.warnings = [.init(code: "POPUP_MONITOR_FAILED", message: "Synthetic monitor failure")]
        let decodedWarning = try JSONDecoder().decode(NativeGameResult.self, from: JSONEncoder().encode(warnedResult))
        try Data().write(to: failureLog.appendingPathComponent("windows.jsonl"))
        check(try await decodedWarning.playerMessage() == nil,
              "Structured S2 monitor warnings decode correctly and block no-window diagnoses")
        try Data("malformed synthetic window record".utf8)
            .write(to: failureLog.appendingPathComponent("windows.jsonl"))
        do {
            _ = try await resultFixture.playerMessage()
            check(false, "Malformed window evidence must be surfaced, not treated as an empty success")
        } catch {
            check(true, "Malformed window evidence is surfaced without fabricating a no-window cause")
        }
        let executable = root.appendingPathComponent("synthetic-cli")
        let script = #"""
        #!/usr/bin/python3
        import json, os, pathlib, signal, sys, time, uuid
        operation, product = sys.argv[1:3]
        options = dict(zip(sys.argv[3::2], sys.argv[4::2]))
        assert sys.argv[-1] == "--allow-keychain-prompt"
        assert options["--account-hash"] == "a" * 64
        state = pathlib.Path(options["--state-dir"])
        game = options["--game-dir"]
        run_id = str(uuid.uuid4())
        log = state / "runs" / run_id
        log.mkdir(parents=True, mode=0o700)
        def write(path, data):
            path.write_text(data)
            path.chmod(0o600)
        progress = log / "progress.jsonl"
        write(progress, '{"event":"bytes","id":18446744073709551615,"delta_bytes":7}\n'
                        '{"event":"bytes","id":0,"delta_bytes":25}\n'
                        '{"event":"completed"}\n')
        cancelled = False
        def stop(signum, frame):
            global cancelled
            cancelled = True
        signal.signal(signal.SIGTERM, stop)
        if operation == "launch":
            assert os.environ.get("S5_SYNTHETIC_ENV") == "owned-fixture"
            assert "HOME" not in os.environ
            deadline = time.monotonic() + 5
            while not cancelled and time.monotonic() < deadline:
                time.sleep(0.01)
        code = 0 if os.environ.get("S5_SUCCESS_AFTER_CANCEL") == "1" else 1 if operation == "repair" or cancelled else 0
        result = dict(version=1, run_id=run_id, operation=operation, product=product,
            success=code == 0, exit_code=code,
            error_code="CANCELLED" if cancelled and code else "OPERATION_FAILED" if code else None,
            game_dir=game, log_dir=str(log), result_path=str(log / "result.json"), progress_path=str(progress))
        result["warnings"] = [dict(code="POPUP_MONITOR_FAILED", message="Synthetic monitor timeout")]
        result["popup_monitor_error"] = "Synthetic monitor timeout"
        write(log / "result.json", json.dumps(result))
        if operation == "uninstall":
            result["success"] = False
            result["exit_code"] = 1
            result["error_code"] = "OPERATION_FAILED"
        print(json.dumps(result))
        sys.exit(code)
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let configuration = BackendConfiguration(executable: executable, stateDirectory: root.appendingPathComponent("manage"))
        let runner = NativeGameLifecycle()
        let game = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: false)
        try GameScriptFiles.checkPath(game)
        try GameScriptFiles.checkPath(root.appendingPathComponent("install"), allowMissing: true)
        var received: [GameScriptProgress] = []
        let result: NativeGameResult
        do {
            result = try await runner.run(configuration: configuration, accountHash: String(repeating: "a", count: 64),
                operation: "install", product: "FIXTURE00001", gameDirectory: game,
                runID: InstalledGamesController.runID(), stateRoot: root.appendingPathComponent("install"),
                onProgress: { received.append($0) })
        } catch {
            print("Native fixture failed after child start: \(runner.started), state: \(runner.stateDirectory?.path ?? "none")")
            if let state = runner.stateDirectory {
                let stderr = try String(contentsOf: state.appendingPathComponent("launcher-stderr.log"), encoding: .utf8)
                print("Native fixture stderr: \(stderr)")
            }
            throw error
        }
        check(result.success && result.exitCode == 0 && received.last?.bytesDone == 25 && !runner.isRunning,
              "Native lifecycle: actual synthetic child receipt agrees; a popup warning does not override clean exit")
        let prestartState = root.appendingPathComponent("cancel-after-preparation")
        var prestartCancelled = false
        var prestartFailure: String?
        let prestart = Task {
            do {
                _ = try await runner.run(configuration: configuration, accountHash: String(repeating: "a", count: 64),
                    operation: "launch", product: "FIXTURE00001", gameDirectory: game,
                    runID: InstalledGamesController.runID(), stateRoot: prestartState)
            } catch NativeLifecycleCancellation.launchStopped { prestartCancelled = true }
            catch { prestartFailure = error.localizedDescription }
        }
        InstalledGamesController.cancelPrestartLaunch(preparation: nil, launch: prestart, launcher: runner)
        await prestart.value
        check(prestartCancelled && prestartFailure == nil && !runner.isRunning
              && !FileManager.default.fileExists(atPath: prestartState.path),
              "M1: Visible Cancel after preparation cancels the actual pending launch task before spawn without a failure")
        try Data("""
            <Game><Identity Name="Fixture.Native" Version="1.0.0.0"/><StoreId>FIXTURE00001</StoreId></Game>
            """.utf8).write(to: game.appendingPathComponent("MicrosoftGame.config"))
        let store = InstalledGameStore(file: root.appendingPathComponent("registry/installed.json"))
        let installed = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc })
        await installed.load()
        try installed.reserveMutation(gameID: nil)
        try await installed.registerNativeInstallation(folder: game, expectedStoreID: "FIXTURE00001")
        installed.releaseMutation()
        let saved = try await store.load().first
        check(saved?.usesNativeLifecycle == true && saved?.launcher == ""
              && saved.map { installed.launchableIDs.contains($0.id) } == false,
              "Native lifecycle: metadata registration persists but cannot invent authoritative installation completeness")
        let reloaded = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc })
        await reloaded.load()
        check(reloaded.games.first?.usesNativeLifecycle == true && reloaded.launchableIDs.isEmpty,
              "Native lifecycle: registry reload preserves routing without promoting cached metadata to Play")
        let discovery = root.appendingPathComponent("discovery")
        let discoveredGame = discovery.appendingPathComponent("new-game")
        let brokenGame = discovery.appendingPathComponent("broken-game")
        for directory in [discoveredGame, brokenGame] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("""
            <Game><Identity Name="Fixture.Discovered" Version="1.0.0.0"/><StoreId>FIXTURE00002</StoreId></Game>
            """.utf8).write(to: discoveredGame.appendingPathComponent("MicrosoftGame.config"))
        try Data("<broken".utf8).write(to: brokenGame.appendingPathComponent("MicrosoftGame.config"))
        let session = LiveSession()
        installed.useUnifiedAccount(session)
        await installed.discoverNativeInstallations(root: discovery)
        check(!installed.games.contains { $0.storeId == "FIXTURE00002" }
              && installed.discoveryError == nil
              && installed.hasUnverifiedInstallation(productID: "FIXTURE00002"),
              "Automatic discovery keeps valid candidates unverified and skips corrupt siblings without raw-path banners")
        let discoveredCount = installed.games.count
        await installed.discoverNativeInstallations(root: discovery)
        check(installed.games.count == discoveredCount,
              "Repeated discovery never duplicates an existing installation")
        let repair = try await runner.run(configuration: configuration, accountHash: String(repeating: "a", count: 64),
            operation: "repair", product: "FIXTURE00001", gameDirectory: game,
            runID: InstalledGamesController.runID(), stateRoot: root.appendingPathComponent("repair"))
        check(!repair.success && repair.errorCode == "OPERATION_FAILED",
              "Native lifecycle: stream completed before a failed repair cannot register success")
        for succeeds in [false, true] {
            let cancelledState = root.appendingPathComponent("cancel-\(succeeds)")
            do {
                _ = try await runner.run(configuration: configuration, accountHash: String(repeating: "a", count: 64),
                    operation: "launch", product: "FIXTURE00001", gameDirectory: game,
                    runID: InstalledGamesController.runID(), stateRoot: cancelledState,
                    launchEnvironment: ["S5_SYNTHETIC_ENV": "owned-fixture",
                                        "S5_SUCCESS_AFTER_CANCEL": succeeds ? "1" : "0"],
                    unsetLaunchEnvironment: ["HOME"], onProgress: { _ in runner.cancel() })
                check(false, "REQ95 requested cancellation cannot return success or terminal result")
            } catch NativeLifecycleCancellation.launchStopped {
                let persisted = try NativeGameLifecycle.readResult(state: cancelledState, operation: "launch",
                    product: "FIXTURE00001", gameDirectory: game)
                check(!runner.isRunning && persisted.success == succeeds && runner.completedResult == persisted,
                      "REQ95 cancellation joins child, validates its terminal receipt and refuses success-after-cancel")
            }
        }
        do {
            _ = try await runner.run(configuration: configuration, accountHash: String(repeating: "a", count: 64),
                operation: "uninstall", product: "FIXTURE00001", gameDirectory: game,
                runID: InstalledGamesController.runID(), stateRoot: root.appendingPathComponent("mismatch"))
            check(false, "Native lifecycle refuses stdout/status disagreement")
        } catch { check(true, "Native lifecycle refuses stdout/status disagreement") }
        let defaultsName = "NativeLifecycleChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let nativeGame = InstalledGame(id: UUID(), title: "Fixture",
                identityName: "Fixture", version: "1.0.0.0", storeId: "FIXTURE00001",
                folder: game.path, launcher: "", importedAt: Date(), usesNativeLifecycle: true)
        do {
            _ = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: .standaloneWine, defaults: defaults)
            check(false, "A missing runtime selection cannot enable launch")
        } catch NativeLaunchError.runtimeNotQualified {
            check(true, "A missing runtime selection cannot enable launch")
        }
        let primary = root.appendingPathComponent("xgameruntime.dll")
        let legacy = root.appendingPathComponent("xgameruntime_legacy.dll")
        try Data("synthetic primary".utf8).write(to: primary)
        try Data("synthetic legacy".utf8).write(to: legacy)
        let reference = try NativeRuntimeReference.capture(primary)
        let runtimeURL = try await reference.validate()
        check(runtimeURL == primary, "An explicitly selected local DLL pair is available without claiming release qualification")
        defaults.set(try JSONEncoder().encode(NativeLocalRuntime(reference)), forKey: "Xodus.lifecycle.runtime")
        let registry = root.appendingPathComponent("engines.json")
        try JSONSerialization.data(withJSONObject: ["engines": [
            ["name": "synthetic", "kind": "free", "wine": executable.path, "smoke_test": ["status": "pass"]]
        ]]).write(to: registry)
        defaults.set(registry.path, forKey: "Xodus.lifecycle.registry")
        defaults.set("synthetic", forKey: "Xodus.lifecycle.engine.standaloneWine")
        let shimDirectory = root.appendingPathComponent("shims")
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        var shimHashes: [String: String] = [:]
        for name in ["windows.web.dll", "XCurl.dll", "cacert.pem"] {
            let bytes = Data("Synthetic shim \(name)".utf8)
            try bytes.write(to: shimDirectory.appendingPathComponent(name))
            shimHashes[name] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        let shims = NativeShimReference(directory: shimDirectory, hashes: shimHashes)
        do {
            _ = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: nil, defaults: defaults)
            check(false, "Unconfigured Play cannot silently choose generic Wine")
        } catch NativeLaunchError.engineNotSelected {
            check(true, "REQ95 unconfigured Play refuses generic Wine/CrossOver/GPTK substitution")
        }
        let proven = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: nil, defaults: defaults,
                                                            provenEngine: "synthetic")
        check(proven.engine == "synthetic",
              "Historical exact recipe data remains inspectable without admitting it for current execution")
        let orderedRegistry = try JSONDecoder().decode(NativeEngineRegistry.self,
            from: JSONSerialization.data(withJSONObject: ["engines": [
                ["name": "failed-presentation", "kind": "free", "engine_label": "Free Wine",
                 "wine": executable.path, "smoke_test": ["status": "pass"],
                 "presentation_validation": ["status": "failed"]],
                ["name": "paid", "kind": "CrossOver", "engine_label": "CrossOver",
                 "wine": executable.path, "smoke_test": ["status": "pass"]],
                ["name": "synthetic", "kind": "free", "engine_label": "Free Wine",
                 "wine": executable.path, "smoke_test": ["status": "pass"]]
            ]]))
        do {
            _ = try NativeLaunchConfiguration.selectEngine(registry: orderedRegistry, provider: nil,
                defaults: defaults, provenEngine: nil)
            check(false, "Unspecified selection cannot use an ordered legacy runner")
        } catch NativeLaunchError.engineNotSelected {
            check(true, "REQ95 installed legacy runner order cannot admit an unspecified Calimocho configuration")
        }
        check(try NativeLaunchConfiguration.selectEngine(registry: orderedRegistry, provider: nil,
                defaults: defaults, provenEngine: "paid").name == "paid"
              && NativeLaunchConfiguration.selectEngine(registry: orderedRegistry, provider: .standaloneWine,
                defaults: defaults, provenEngine: "paid").name == "synthetic",
              "Historical explicit recipe resolution stays separate from current execution policy")
        do {
            _ = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: nil, defaults: defaults,
                                                       provenEngine: "unavailable-proven-engine")
            check(false, "An unavailable proven engine cannot silently become a different engine")
        } catch NativeLaunchError.engineUnavailable {
            check(true, "An unavailable proven engine is reported instead of silently substituting")
        }
        let launch = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: .standaloneWine, defaults: defaults,
                                                           shims: shims)
        let args = try await launch.arguments()
        check(args.contains(primary.path) && args.contains("synthetic")
              && args.contains("--shim-dir") && args.contains(shimDirectory.path),
              "Every MSIXVC launch requires the hash-verified native sign-in shims alongside its separate runtime pair")
        defaults.set(root.path, forKey: "Xodus.lifecycle.profileDirectory")
        let profile = NativeTitleLaunchProfile(version: 1, productID: nativeGame.storeId, engine: "synthetic",
            shimDirectory: shimDirectory.path, environment: ["CX_ENV": "synthetic override"])
        let profileURL = root.appendingPathComponent(nativeGame.storeId + ".json")
        try JSONEncoder().encode(profile).write(to: profileURL)
        let profiled = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: .standaloneWine, defaults: defaults,
                                                             shims: shims)
        let profileArguments = try await profiled.arguments()
        check(profileArguments.contains("--shim-dir") && profiled.profile?.environment["CX_ENV"] == "synthetic override",
              "A product-bound data-only launch profile forwards its explicit shims and environment")
        let bound = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: nil, defaults: defaults,
            shims: shims, provenEngine: "obsolete-evidence-engine")
        check(bound.engine == "synthetic",
              "A title's current exact recipe binding takes precedence over its historical gameplay engine")
        let originalRegistry = try Data(contentsOf: registry)
        let fallbackKey = "Xodus.lifecycle.fallback.\(nativeGame.storeId)"
        let fallbacks = try NativeTitleLaunchProfile.bundledEngineFallbacks()
        check(fallbacks.map(\.engine) == ["apple4-d3dshared", "creation-dx11-d3dshared", "queue-winecx-d3dshared"]
              && fallbacks.map(\.library.sha256) == [
                "e985a9e0b9807856018ee63ac40de3b3baaca7c33568f672d80d89934fbc41f1",
                "e985a9e0b9807856018ee63ac40de3b3baaca7c33568f672d80d89934fbc41f1",
                "5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995"],
              "Only S1's frozen three sibling fallbacks and own support-library hashes are admitted")
        for rule in fallbacks {
            var title = profile
            title.engine = rule.baseEngine
            title.runtime = NativeLocalRuntime(reference)
            title.executable = "Title/Exact.exe"
            title.environment = ["XODUS_PRIVATE_RUNTIME_COM_STA": "1"]
            title.requiredFiles = [.init(path: primary.path, sha256: reference.primary.sha256)]
            title.prefixRegistryImports = [.init(path: primary.path, sha256: reference.primary.sha256)]
            title.prefixOverlays = [.init(path: legacy.path, sha256: reference.legacy.sha256,
                                          destination: "drive_c/windows/system32/title.dll")]
            try JSONEncoder().encode(title).write(to: profileURL)
            let fixtureBytes = try JSONSerialization.data(withJSONObject: ["engines": [
                ["name": rule.baseEngine, "kind": "free", "wine": executable.path,
                 "smoke_test": ["status": "pass"], "environment": ["KEEP": "unchanged"]],
                ["name": rule.engine, "kind": "free", "wine": executable.path,
                 "smoke_test": ["status": "pass"], "environment": [
                    "KEEP": "unchanged", "CX_APPLEGPTK_LIBD3DSHARED_PATH": rule.library.url.path]]
            ]])
            try fixtureBytes.write(to: registry)
            defaults.set(rule.engine, forKey: "Xodus.lifecycle.fallback.UNRELATED001")
            check(try NativeLaunchConfiguration.resolve(game: nativeGame, provider: nil, defaults: defaults,
                shims: shims).engine == rule.baseEngine,
                "\(rule.engine) is never a default or an unrelated title's selection")
            defaults.set(rule.engine, forKey: fallbackKey)
            let explicit = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: nil,
                defaults: defaults, shims: shims)
            let registryAfter = try Data(contentsOf: registry)
            check(explicit.engine == rule.engine && explicit.profile?.runtime?.primarySHA256 == reference.primary.sha256
                  && explicit.profile?.runtime?.legacySHA256 == reference.legacy.sha256
                  && explicit.profile?.shimDirectory == title.shimDirectory
                  && explicit.profile?.arguments == ["--exe", "Title/Exact.exe"]
                  && explicit.profile?.environment["XODUS_PRIVATE_RUNTIME_COM_STA"] == "1"
                  && explicit.profile?.requiredFiles?.first?.sha256 == reference.primary.sha256
                  && explicit.profile?.requiredFiles?.last?.sha256 == rule.library.sha256
                  && explicit.profile?.prefixRegistryImports?.first?.path == primary.path
                  && explicit.profile?.prefixOverlays?.first?.destination == "drive_c/windows/system32/title.dll"
                  && explicit.prefix.lastPathComponent == rule.engine
                  && explicit.registry == registry && registryAfter == fixtureBytes,
                  "\(rule.engine) preserves exact title runtime/shims/executable/COM and uses full sibling registry without mutation")
            guard var mismatched = try JSONSerialization.jsonObject(with: fixtureBytes) as? [String: [[String: Any]]] else {
                throw NativeLaunchError.invalidProfile
            }
            mismatched["engines"]?[1]["environment"] = ["KEEP": "changed"]
            try JSONSerialization.data(withJSONObject: mismatched).write(to: registry)
            do {
                _ = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: nil, defaults: defaults, shims: shims)
                check(false, "A sibling with changed base environment must not be substituted")
            } catch NativeLaunchError.invalidProfile {
                check(true, "A sibling with changed base environment is rejected before any launch")
            }
            try fixtureBytes.write(to: registry)
            defaults.set("unapproved-sibling", forKey: fallbackKey)
            do {
                _ = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: nil, defaults: defaults, shims: shims)
                check(false, "An arbitrary fallback must not be substituted")
            } catch NativeLaunchError.invalidProfile {
                check(true, "An arbitrary fallback fails explicitly without changing the base")
            }
            defaults.removeObject(forKey: fallbackKey)
        }
        try originalRegistry.write(to: registry)
        try JSONEncoder().encode(profile).write(to: profileURL)
        try Data("changed shim".utf8).write(to: shimDirectory.appendingPathComponent("windows.web.dll"))
        do {
            _ = try await profiled.arguments()
            check(false, "A changed native sign-in shim cannot start a game")
        } catch NativeLaunchError.shimsUnavailable {
            check(true, "A changed native sign-in shim fails before launching instead of silently using Wine's built-in Web/JSON")
        }
        try Data("Synthetic shim windows.web.dll".utf8).write(to: shimDirectory.appendingPathComponent("windows.web.dll"))
        let extra = shimDirectory.appendingPathComponent("xgameruntime.dll")
        try Data("stale runtime".utf8).write(to: extra)
        do {
            _ = try await profiled.arguments()
            check(false, "A shim directory cannot smuggle an old runtime")
        } catch NativeLaunchError.shimsUnavailable {
            check(true, "A shim directory containing extra runtime DLLs is rejected")
        }
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.removeItem(at: shimDirectory.appendingPathComponent("XCurl.dll"))
        do {
            _ = try await profiled.arguments()
            check(false, "An incomplete native sign-in shim directory cannot launch")
        } catch NativeLaunchError.shimsUnavailable {
            check(true, "A missing native sign-in shim fails before launching")
        }
        let wrongProfile = NativeTitleLaunchProfile(version: 1, productID: "OTHER0000001", engine: nil,
            shimDirectory: nil, environment: [:])
        try JSONEncoder().encode(wrongProfile).write(to: profileURL)
        do {
            _ = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: .standaloneWine, defaults: defaults)
            check(false, "A launch profile for another product cannot be substituted")
        } catch NativeLaunchError.invalidProfile {
            check(true, "A launch profile for another product cannot be substituted")
        }
        try Data("changed synthetic legacy".utf8).write(to: legacy)
        do {
            _ = try await reference.validate()
            check(false, "A changed local legacy DLL requires selecting the updated pair")
        } catch { check(true, "A changed local legacy DLL requires selecting the updated pair") }
        try await installationStatusChecks(root: root, check: check)
        try await titleRecipeChecks(root: root, check: check)
        try await candidateRecipeChecks(root: root, check: check)
    }

    private static func candidateRecipeChecks(root: URL, check: (Bool, String) -> Void) async throws {
        let rows = try NativeCandidateLaunchCatalogue.rows()
        let expected = [
            "9P8NSTDMZ11P": ("creation-dx11-d3dmetal", "Inscryption.exe"),
            "9MSVVM5NS9L6": ("creation-dx11-d3dmetal", "DREDGE.exe"),
            "9PBWWQGXVMKC": ("creation-dx11-d3dmetal", "Monster Sanctuary.exe"),
            "9NLRT31Z4RWM": ("creation-dx11-d3dmetal", "Secret Legend.exe"),
            "9PD5BM2Z8C4L": ("creation-dx11-d3dmetal", "VampireSurvivors.exe"),
            "9P03JGQ4S1GC": ("creation-dx11-d3dmetal", "SkyrimSELauncher.exe"),
            "9P1N07XDL1D4": ("queue-winecx-nativejson", "Binaries/Win64/Dishonored.exe"),
            "9MWR1NC6VQ6L": ("queue-winecx-nativejson", "Stardew Valley.exe"),
            "9PNG83MDD6SH": ("queue-winecx-nativejson", "Limbo.exe"),
            "9P3T7HVKM6D0": ("creation-dx11-d3dmetal", "KingdomCome.exe"),
            "9N8C07SS8C9D": ("queue-winecx-nativejson", "FINAL FANTASY IV.exe")
        ]
        let suite = "io.github.xodus.candidate-check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NativeLaunchError.invalidProfile }
        defer { defaults.removePersistentDomain(forName: suite) }
        check(Set(rows.filter(\.admitted).map(\.store_id)) == Set(expected.keys)
              && NativeCandidateLaunchCatalogue.issue(productID: "9NMNMS626R59") != nil
              && NativeCandidateLaunchCatalogue.issue(productID: "UNKNOWN00001") == nil,
              "Exactly eleven published S1 candidates are admitted for attempts; Halls stays blocked, unknown titles gain no recipe")
        for row in rows where row.admitted {
            let profile = try NativeTitleLaunchProfile.read(productID: row.store_id, defaults: defaults,
                                                           provider: .standaloneWine)
            check(profile?.engine == expected[row.store_id]?.0
                  && profile?.arguments == ["--exe", expected[row.store_id]?.1 ?? ""]
                  && profile?.environment.isEmpty == true && profile?.dllOverrides == nil
                  && profile?.unsetEnvironment?.contains("XODUS_PRIVATE_RUNTIME_COM_STA") == true
                  && row.game_arguments.isEmpty,
                  "Candidate \(row.store_id) binds exact S1 engine/exe/empty args without STA or DLL overrides")
        }
        do {
            _ = try NativeTitleLaunchProfile.read(productID: "9NMNMS626R59", defaults: defaults)
            check(false, "Halls must not resolve a launch profile")
        } catch NativeLaunchError.candidateBlocked {
            check(true, "Halls blocks direct profile resolution, not only its visible Play action")
        }
        let hallsDocument: [String: Any] = [
            "schemaVersion": 1, "updatedAt": "2026-10-22T00:00:00Z",
            "games": [[
                "productId": "9NMNMS626R59", "title": "Halls of Torment", "verdict": "WORKING",
                "scope": "Synthetic exact recipe admission regression", "engine": "apple-gptk-4.0b3",
                "runId": "8d7ea6ba-ec75-4cb1-8b96-7300bd467159",
                "retentionRunId": "5b39beb9-62b4-4241-9330-33422bbccafd", "owner": "test",
                "screenshots": [["path": "/synthetic/halls.png", "caption": "Synthetic evidence"]],
                "saveObservation": ["retentionVerified": true, "normalMenuQuitObserved": true]
            ]]
        ]
        let hallsBytes = try JSONSerialization.data(withJSONObject: hallsDocument)
        let hallsEvidence = try MacGameEvidence.decode(hallsBytes).games[0]
        let hallsProfile = try NativeTitleLaunchProfile.read(productID: "9NMNMS626R59", defaults: defaults,
            provider: .standaloneWine, evidence: hallsEvidence)
        check(NativeCandidateLaunchCatalogue.issue(productID: "9NMNMS626R59", evidence: hallsEvidence) == nil
              && hallsEvidence.verifiedWorkingEvidence != nil && hallsProfile?.engine == "apple-gptk-4.0b3"
              && hallsProfile?.arguments == ["--exe", "Halls of Torment.exe", "--timeout-seconds", "300", "--no-auto-dismiss"],
              "Exact admitted Halls WORKING evidence replaces Launch unavailable with Play eligibility and a Working badge")
        let hallsRegistry = root.appendingPathComponent("halls-registry.json")
        let hallsRegistryBytes = try JSONSerialization.data(withJSONObject: ["engines": [[
            "name": "apple-gptk-4.0b3", "kind": "free", "wine": "/usr/bin/true",
            "smoke_test": ["status": "pass"], "environment": ["KEEP": "unchanged"]
        ]]])
        try hallsRegistryBytes.write(to: hallsRegistry)
        defaults.set(hallsRegistry.path, forKey: "Xodus.lifecycle.registry")
        defaults.set("unavailable-global-engine", forKey: "Xodus.lifecycle.engine.standaloneWine")
        let hallsGame = InstalledGame(id: UUID(), title: "Halls of Torment", identityName: "SyntheticHalls",
            version: "1.0.0.0", storeId: "9NMNMS626R59", folder: root.path, launcher: "",
            importedAt: Date(), usesNativeLifecycle: true)
        let resolvedHalls = try NativeLaunchConfiguration.resolve(game: hallsGame, provider: .standaloneWine,
            defaults: defaults, evidence: hallsEvidence)
        check(resolvedHalls.engine == NativeWorkingLaunchRecipe.engine
              && resolvedHalls.prefix.path == NativeWorkingLaunchRecipe.admitted(
                productID: hallsGame.storeId, evidence: hallsEvidence)?.prefix.path
              && resolvedHalls.profile?.environment.isEmpty == true
              && resolvedHalls.profile?.runtime?.primarySHA256 == "6c9d97d3b1690c6c314d303be5d6da82f630808fc33a57395c8e102216a802a8",
              "Halls exact Apple4/default-COM/runtime/preserved save prefix wins over a conflicting global provider without launching")
        defaults.set("creation-dx11-d3dshared", forKey: "Xodus.lifecycle.fallback.9NMNMS626R59")
        do {
            _ = try NativeLaunchConfiguration.resolve(game: hallsGame, provider: nil,
                defaults: defaults, evidence: hallsEvidence)
            check(false, "Halls may not substitute a sibling fallback")
        } catch NativeLaunchError.invalidProfile {
            check(true, "Qualified Halls refuses unobserved fallback or inherited COM/support-library settings")
        }
        defaults.removeObject(forKey: "Xodus.lifecycle.fallback.9NMNMS626R59")
        let hogwartsJSON = String(decoding: hallsBytes, as: UTF8.self)
            .replacingOccurrences(of: "9NMNMS626R59", with: "9MT5NJ5W7B8Z")
            .replacingOccurrences(of: "Halls of Torment", with: "Hogwarts Legacy")
            .replacingOccurrences(of: "8d7ea6ba-ec75-4cb1-8b96-7300bd467159",
                                  with: "891d061f-4820-4cd3-9b61-efefa5700be9")
            .replacingOccurrences(of: "5b39beb9-62b4-4241-9330-33422bbccafd",
                                  with: "86e8da68-f4b0-48f8-bf7a-46e577ff3488")
        var hogwartsDocument = try JSONSerialization.jsonObject(with: Data(hogwartsJSON.utf8)) as? [String: Any] ?? [:]
        var hogwartsRows = hogwartsDocument["games"] as? [[String: Any]] ?? []
        hogwartsRows[0]["normalQuitRunId"] = "f2471368-2523-4578-8eb8-75c8d4db7040"
        hogwartsDocument["games"] = hogwartsRows
        let hogwartsEvidence = try MacGameEvidence.decode(JSONSerialization.data(withJSONObject: hogwartsDocument)).games[0]
        let hogwartsGame = InstalledGame(id: UUID(), title: "Hogwarts Legacy", identityName: "SyntheticHogwarts",
            version: "1.0.0.0", storeId: "9MT5NJ5W7B8Z", folder: root.path, launcher: "",
            importedAt: Date(), usesNativeLifecycle: true)
        let resolvedHogwarts = try NativeLaunchConfiguration.resolve(game: hogwartsGame,
            provider: .standaloneWine, defaults: defaults, evidence: hogwartsEvidence)
        check(resolvedHogwarts.engine == "apple-gptk-4.0b3"
              && resolvedHogwarts.profile?.executable == "Phoenix/Binaries/WinGDK/HogwartsLegacy.exe"
              && resolvedHogwarts.profile?.launchEnvironment == ["XODUS_PRIVATE_RUNTIME_COM_STA": "1"]
              && resolvedHogwarts.prefix.path.hasSuffix("/XodusCLI/prefixes/s3-hogwarts-apple4-v1")
              && hogwartsEvidence.verifiedWorkingEvidence != nil,
              "Qualified Hogwarts uses exact published Apple4/STA1/direct exe/existing save prefix with Play eligibility and Working badge")
        hogwartsRows[0]["normalQuitRunId"] = "00000000-0000-0000-0000-000000000001"
        hogwartsDocument["games"] = hogwartsRows
        let wrongQuit = try MacGameEvidence.decode(JSONSerialization.data(withJSONObject: hogwartsDocument)).games[0]
        check(NativeCandidateLaunchCatalogue.issue(productID: hogwartsGame.storeId, evidence: wrongQuit) != nil
              && NativeCandidateLaunchCatalogue.issue(productID: hogwartsGame.storeId) != nil,
              "Hogwarts requires its exact ordinary-quit evidence before any STA recipe applies")
        for change in [
            ("WORKING", "GAMEPLAY_PASS"), ("WORKING", "FUTURE_RESULT"),
            ("apple-gptk-4.0b3", "creation-dx11-d3dmetal"),
            ("5b39beb9-62b4-4241-9330-33422bbccafd", "00000000-0000-0000-0000-000000000001")
        ] {
            let changed = String(decoding: hallsBytes, as: UTF8.self)
                .replacingOccurrences(of: change.0, with: change.1)
            let evidence = try MacGameEvidence.decode(Data(changed.utf8)).games[0]
            check(NativeCandidateLaunchCatalogue.issue(productID: "9NMNMS626R59", evidence: evidence) != nil,
                  "Halls partial/unknown/mismatched engine or retention proof cannot bypass its frozen blocked row")
        }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf:
            LaunchRecipeResources.candidateProfilesURL("small-game-candidates"))) as? [String: Any] ?? [:]
        let sample = (raw["profiles"] as? [[String: Any]])?.first ?? [:]
        for change: [String: Any] in [
            ["status": "unknown-future-status"], ["ready_for_launch": false],
            ["title_environment": ["XODUS_PRIVATE_RUNTIME_COM_STA": "1"]],
            ["title_environment": ["WINEDLLOVERRIDES": "unapproved=n"]],
            ["game_arguments": ["--unapproved"]], ["profile": "unknown-engine"]
        ] {
            let changed = sample.merging(change) { _, new in new }
            let row = try JSONDecoder().decode(NativeCandidateLaunchCatalogue.Row.self,
                                               from: JSONSerialization.data(withJSONObject: changed))
            check(!row.admitted, "Unknown/unqualified candidate changes cannot auto-apply STA, overrides, args or another engine")
        }
        let first = rows.first { $0.admitted }!
        let fakeWine = root.appendingPathComponent("synthetic-install-status").path
        for environment in [[:], ["XODUS_PRIVATE_RUNTIME_COM_STA": "1"],
                            ["XODUS_PRIVATE_CALLER_OWNS_COM": "1"],
                            ["CX_APPLEGPTK_LIBD3DSHARED_PATH": "/unapproved/library"]] {
            let registry = try JSONDecoder().decode(NativeEngineRegistry.self,
                from: JSONSerialization.data(withJSONObject: ["engines": [
                    ["name": first.profile, "kind": "free", "wine": fakeWine,
                     "smoke_test": ["status": "pass"], "environment": environment]
                ]]))
            do {
                try first.validateEngine(registry.engines[0], fallback: nil)
                check(environment.isEmpty, "Candidate rejects engine-level unqualified STA/caller-owns/support-library contamination")
            } catch NativeLaunchError.invalidProfile {
                check(!environment.isEmpty, "Candidate rejects engine-level unqualified STA/caller-owns/support-library contamination")
            }
        }
        do {
            try first.validateManifest(folder: root)
            check(false, "Candidate manifest must match its frozen S1 edition/executable evidence")
        } catch { check(true, "Missing or changed manifest fails before any prefix/launch mutation") }

        guard let mixtape = try NativeTitleLaunchProfile.read(productID: "9NH0MSG29X6L", defaults: defaults) else {
            throw NativeLaunchError.invalidProfile
        }
        check(mixtape.dllOverrides == "msvcp140_2,vcruntime140_1=n,b"
              && mixtape.dllOverrideEvidence?.runID == "005115dd-7928-4fbc-9ffa-28379040292d"
              && mixtape.engine == "apple-gptk-4.0b3" && mixtape.arguments == ["--exe", "Mixtape.exe"]
              && mixtape.environment.isEmpty
              && mixtape.unsetEnvironment?.contains("XODUS_PRIVATE_RUNTIME_COM_STA") == true,
              "Mixtape-only native VC suffix is evidence-bound; pending STA stays inactive and no WORKING promotion occurs")
        let registry = root.appendingPathComponent("mixtape-original-registry.json")
        let base = "d3d10,d3d11,d3d12,d3d12core,dxgi=b;windows.web=n;XCurl=n;xgameruntime=n,b"
        let original: [String: Any] = ["engines": [
            ["name": "apple-gptk-4.0b3", "environment": ["WINEDLLOVERRIDES": base, "KEEP": "unchanged"]],
            ["name": "other-engine", "environment": ["WINEDLLOVERRIDES": "other=b"]]
        ]]
        let bytes = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try bytes.write(to: registry)
        let selected = try await mixtape.registryForLaunch(base: registry, engine: "apple-gptk-4.0b3",
            outputDirectory: root.appendingPathComponent("mixtape-owned-run-registry"))
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: selected)) as? [String: Any]
        let entries = result?["engines"] as? [[String: Any]]
        let retained = try Data(contentsOf: registry)
        check((entries?.first?["environment"] as? [String: String])
                  == ["WINEDLLOVERRIDES": base + ";msvcp140_2,vcruntime140_1=n,b", "KEEP": "unchanged"]
              && (entries?.last?["environment"] as? [String: String]) == ["WINEDLLOVERRIDES": "other=b"]
              && retained == bytes && selected != registry,
              "Frozen CLI-honored per-run registry appends exact VC suffix, preserves existing clauses/other engines and shared source bytes")
        let conflictRegistry = root.appendingPathComponent("mixtape-conflicting-registry.json")
        try JSONSerialization.data(withJSONObject: ["engines": [
            ["name": "apple-gptk-4.0b3", "environment": ["WINEDLLOVERRIDES": base + ";MSVCP140_2=b"]]
        ]]).write(to: conflictRegistry)
        do {
            _ = try await mixtape.registryForLaunch(base: conflictRegistry, engine: "apple-gptk-4.0b3",
                outputDirectory: root.appendingPathComponent("mixtape-conflict-rejected"))
            check(false, "Conflicting VC clause must not be overwritten or doubled")
        } catch NativeLaunchError.invalidProfile {
            check(true, "Conflicting VC DLL clauses are rejected case-insensitively before writing")
        }
        for mode in ["other-title", "missing-evidence", "unapproved-dll", "pending-sta"] {
            var invalid = mixtape
            if mode == "missing-evidence" { invalid.dllOverrideEvidence = nil }
            if mode == "unapproved-dll" { invalid.dllOverrides = "another=n" }
            if mode == "pending-sta" { invalid.environment["XODUS_PRIVATE_RUNTIME_COM_STA"] = "1" }
            if mode == "other-title" {
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mixtape)) as? [String: Any] ?? [:]
                object["productID"] = "FIXTURE00001"
                invalid = try JSONDecoder().decode(NativeTitleLaunchProfile.self,
                    from: JSONSerialization.data(withJSONObject: object))
            }
            do {
                _ = try await invalid.registryForLaunch(base: registry, engine: "apple-gptk-4.0b3",
                    outputDirectory: root.appendingPathComponent("mixtape-rejected-\(mode)"))
                check(false, "DLL recipe rejects \(mode)")
            } catch NativeLaunchError.invalidProfile {
                check(true, "DLL recipe rejects \(mode) before a per-run registry is written")
            }
        }
    }

    private static func titleRecipeChecks(root: URL, check: (Bool, String) -> Void) async throws {
        let profiles = try NativeTitleLaunchProfile.bundledProfiles()
        let hollowCandidate = try JSONDecoder().decode(NativeTitleLaunchProfile.self,
            from: Data(contentsOf: LaunchRecipeResources.hollowKnightSaveCandidateURL()))
        check(hollowCandidate.productID == "9MW9469V91LM"
              && hollowCandidate.environment["XODUS_PRIVATE_LOCAL_SAVES"] == "1"
              && hollowCandidate.crossOverEnvironment == ["XODUS_PRIVATE_LOCAL_SAVES": "1"]
              && hollowCandidate.launchEnvironment["CX_ENV"] == "XODUS_PRIVATE_LOCAL_SAVES='1'"
              && !profiles.contains(where: { $0.productID == hollowCandidate.productID }),
              "HK local-save mirror is an inactive data candidate, never applied before real saved-relaunch evidence")
        let runtimeCatalogue = try NativeTitleLaunchProfile.RuntimeCatalogue.bundled()
        check(runtimeCatalogue.items.filter(\.observed).map(\.storeId) == ["9P4NV23Q6QC2", "9MT5NJ5W7B8Z"],
              "Only observed Abiotic and now-qualified Hogwarts STA settings are active; other diagnostic candidates remain inactive")
        for item in runtimeCatalogue.items where !item.observed {
            check(!profiles.contains(where: {
                $0.productID == item.storeId && $0.environment["XODUS_PRIVATE_RUNTIME_COM_STA"] == "1"
            }), "Pending \(item.storeId) never auto-applies STA from diagnostic inventory")
        }
        let abiotic = profiles.first { $0.productID == "9P4NV23Q6QC2" }
        check(abiotic?.engine == "apple-gptk-4.0b3"
              && abiotic?.arguments == ["--exe", "AbioticFactor/Binaries/WinGDK/AbioticFactor-WinGDK-Shipping.exe",
                                       "--timeout-seconds", "600", "--no-auto-dismiss"]
              && abiotic?.environment["XODUS_PRIVATE_RUNTIME_COM_STA"] == "1"
              && abiotic?.unsetEnvironment == ["CX_APPLEGPTK_LIBD3DSHARED_PATH", "XODUS_PRIVATE_CALLER_OWNS_COM"],
              "Abiotic tile binds S2's observed direct-Shipping STA1, stripping caller-owns and inherited sibling library without gameplay claims")
        guard let nms = profiles.first(where: { $0.productID == "BQVQTL3PCH05" && $0.provider == .crossover }),
              let freeNMS = profiles.first(where: { $0.productID == "BQVQTL3PCH05" && $0.provider == nil }) else {
            check(false, "NMS frozen recipe is bundled")
            return
        }
        check(nms.engine == "crossover-26.3"
              && nms.environment["WINEDLLOVERRIDES"] == "xgameruntime=n,b;XCurl=n,b;windows.web=n,b"
              && nms.runtime?.primarySHA256 == "6c9d97d3b1690c6c314d303be5d6da82f630808fc33a57395c8e102216a802a8"
              && nms.runtime?.legacySHA256 == "cfe7e5f837fabc51b8066809ca69c2ee0a7852512afbb1979190ec495b0b8b96"
              && nms.requiredFiles?.first?.sha256 == "c2b53b24c9f4a29df60bffc73e3da6ec1b4d0d88ebcf40e81acc32ad6ff9b8cc"
              && nms.prefixRegistryImports?.first?.sha256 == "4b91e27c5ae34a0237e2e60678d74117c8f110e261105128ea269058c1962eac",
              "NMS tile data preserves S3's exact engine, frozen runtime pair, c2b driver and native-JSON import")
        check(freeNMS.engine == "calimocho-wine11.20-gptk4b3-tls-vulkan-private"
              && freeNMS.runtime?.primaryPath == "${HOME}/Library/Application Support/Ode to X/Runtime/candidates/7106d0712618544b130e8c0ebcb0881ebd663155e14c24a698445746b82ca51b/xgameruntime.dll"
              && freeNMS.runtime?.legacySHA256 == "cfe7e5f837fabc51b8066809ca69c2ee0a7852512afbb1979190ec495b0b8b96"
              && freeNMS.environment == ["XODUS_PRIVATE_LOCAL_SAVES": "1", "XODUS_XBL_ONLINE": "1"]
              && freeNMS.arguments == ["--exe", "Binaries/NMS.exe", "--no-auto-dismiss"],
              "Free NMS binds the observed port11b runtime, executable, local saves and online environment without old GPTK3 overrides")
        let suite = "io.github.xodus.recipe-check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NativeLaunchError.invalidProfile }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "Xodus.lifecycle.profileDirectory")
        let obsolete = NativeTitleLaunchProfile(version: 1, productID: nms.productID, engine: "obsolete-engine",
                                               shimDirectory: nil, environment: ["CX_ENV": "obsolete"])
        try JSONEncoder().encode(obsolete).write(to: root.appendingPathComponent(nms.productID + ".json"))
        let defaultNMS = try NativeTitleLaunchProfile.read(productID: nms.productID, defaults: defaults)
        let fallbackNMS = try NativeTitleLaunchProfile.read(productID: nms.productID, defaults: defaults, provider: .crossover)
        check(defaultNMS?.engine == "calimocho-wine11.20-gptk4b3-tls-vulkan-private" && fallbackNMS?.engine == "crossover-26.3",
              "Automatic NMS uses the observed port11b binding; explicit CrossOver selects its unchanged separate recipe")
        let brotatoRegistry = root.appendingPathComponent("brotato-route-registry.json")
        try JSONSerialization.data(withJSONObject: ["engines": [
            ["name": "wine-stable", "kind": "free", "wine": "/usr/bin/true", "smoke_test": ["status": "pass"]],
            ["name": "apple-gptk-4.0b3", "kind": "free", "wine": "/usr/bin/true", "smoke_test": ["status": "pass"]]
        ]]).write(to: brotatoRegistry)
        defaults.set(brotatoRegistry.path, forKey: "Xodus.lifecycle.registry")
        defaults.set("wine-stable", forKey: "Xodus.lifecycle.engine.crossover")
        let brotato = InstalledGame(id: UUID(), title: "Brotato", identityName: "Synthetic.Brotato",
            version: "1.0", storeId: "9P9VNSQK1W3K", folder: root.path, launcher: "",
            importedAt: Date(), usesNativeLifecycle: true)
        for provider: RuntimeProviderKind? in [nil, .crossover] {
            let launch = try NativeLaunchConfiguration.resolve(game: brotato, provider: provider, defaults: defaults)
            check(launch.engine == "apple-gptk-4.0b3"
                  && launch.profile?.arguments == ["--exe", "Brotato.exe", "--no-auto-dismiss"]
                  && launch.profile?.environment.isEmpty == true
                  && Set(launch.profile?.unsetEnvironment ?? []) == Set([
                    "XODUS_PRIVATE_RUNTIME_COM_STA", "XODUS_PRIVATE_CALLER_OWNS_COM", "CX_APPLEGPTK_LIBD3DSHARED_PATH"])
                  && launch.profile?.runtime?.primarySHA256 == "6c9d97d3b1690c6c314d303be5d6da82f630808fc33a57395c8e102216a802a8"
                  && launch.profile?.runtime?.legacySHA256 == "cfe7e5f837fabc51b8066809ca69c2ee0a7852512afbb1979190ec495b0b8b96"
                  && launch.shims.directory.path.hasSuffix("/Ode to X/Engines/profiles/native-web-shims-v1")
                  && launch.prefix.path.hasSuffix("/\(brotato.id.uuidString)/apple-gptk-4.0b3"),
                  "#43: Brotato selects its explicit Apple4/defaultCOM/runtime7106/native-shims/direct-exe recipe, not generic wine-stable or a conflicting default provider")
        }
        let observedAbiotic = try NativeTitleLaunchProfile.read(productID: "9P4NV23Q6QC2", defaults: defaults)
        check(observedAbiotic?.launchEnvironment["XODUS_PRIVATE_RUNTIME_COM_STA"] == "1"
              && observedAbiotic?.launchEnvironment["XODUS_PRIVATE_CALLER_OWNS_COM"] == nil
              && observedAbiotic?.unsetEnvironment?.contains("CX_APPLEGPTK_LIBD3DSHARED_PATH") == true
              && defaultNMS?.environment["XODUS_PRIVATE_RUNTIME_COM_STA"] == nil,
              "Actual tile profile selection consumes observed Abiotic settings and preserves working NMS")
        let pendingID = "9PJPCB188SVG"
        check(try NativeTitleLaunchProfile.read(productID: pendingID, defaults: defaults) == nil,
              "An unqualified pending diagnostic candidate is not a normal tile launch profile")
        let pendingProfile = NativeTitleLaunchProfile(version: 1, productID: pendingID,
            engine: "apple-gptk-4.0b3", shimDirectory: nil, environment: ["XODUS_PRIVATE_RUNTIME_COM_STA": "1"])
        try JSONEncoder().encode(pendingProfile).write(to: root.appendingPathComponent(pendingID + ".json"))
        do {
            _ = try NativeTitleLaunchProfile.read(productID: pendingID, defaults: defaults)
            check(false, "A stale local pending candidate must not bypass the observed-only gate")
        } catch NativeLaunchError.invalidProfile {
            check(true, "A stale local pending STA profile fails explicitly rather than auto-applying")
        }
        let serializer = Process()
        serializer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        serializer.arguments = ["-c", "import json,shlex,sys; print(json.dumps(dict(v.split('=',1) for v in shlex.split(sys.argv[1]))))",
                                nms.launchEnvironment["CX_ENV"] ?? ""]
        let output = Pipe()
        serializer.standardOutput = output
        serializer.standardError = FileHandle.nullDevice
        try serializer.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        serializer.waitUntilExit()
        let mirrored = try JSONDecoder().decode([String: String].self, from: bytes)
        check(serializer.terminationStatus == 0 && mirrored == nms.crossOverEnvironment?.mapValues(NativeTitleLaunchProfile.expand)
              && mirrored.allSatisfy({ nms.launchEnvironment[$0.key] == $0.value }),
              "CrossOver --env serialization round-trips paths with spaces and mirrors exact ambient graphics values")
        let registry = root.appendingPathComponent("recipe-base.json")
        let original: [String: Any] = ["version": 1, "engines": [
            ["name": "exact-engine", "wine": "/unchanged/wine", "kind": "CrossOver",
             "smoke_test": ["status": "pass"], "environment": ["KEEP": "unchanged"]]
        ]]
        let originalBytes = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try originalBytes.write(to: registry)
        let importURL = root.appendingPathComponent("synthetic-native-json.reg")
        let importBytes = Data("Synthetic import, never executed".utf8)
        try importBytes.write(to: importURL)
        let importHash = SHA256.hash(data: importBytes).map { String(format: "%02x", $0) }.joined()
        var fixture = NativeTitleLaunchProfile(version: 1, productID: "FIXTURE00001", engine: "exact-engine",
                                              shimDirectory: nil, environment: [:])
        fixture.prefixRegistryImports = [.init(path: importURL.path, sha256: importHash)]
        let selected = try await fixture.registryForLaunch(base: registry, engine: "exact-engine",
                                                           outputDirectory: root.appendingPathComponent("recipe-output"))
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: selected)) as? [String: Any]
        let entry = (document?["engines"] as? [[String: Any]])?.first
        let retainedBase = try Data(contentsOf: registry)
        check(entry?["name"] as? String == "exact-engine" && entry?["wine"] as? String == "/unchanged/wine"
              && (entry?["environment"] as? [String: String]) == ["KEEP": "unchanged"]
              && (entry?["prefix_registry_imports"] as? [[String: String]]) == [["source": importURL.path, "sha256": importHash]]
              && retainedBase == originalBytes,
              "Per-title registry scopes checksum-bound setup while preserving exact engine identity and shared base bytes")
        try Data("Changed import".utf8).write(to: importURL)
        do {
            _ = try await fixture.registryForLaunch(base: registry, engine: "exact-engine",
                                                    outputDirectory: root.appendingPathComponent("must-not-exist"))
            check(false, "Changed recipe import must not produce a launch registry")
        } catch NativeLaunchError.invalidProfile {
            check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-exist").path),
                  "Changed recipe-bound files fail before prefix preparation or launch")
        }
    }

    private static func installationStatusChecks(root: URL, check: (Bool, String) -> Void) async throws {
        let executable = root.appendingPathComponent("synthetic-install-status")
        try Data(#"""
        #!/usr/bin/python3
        import json, pathlib, sys, time, uuid
        assert len(sys.argv) == 7 and sys.argv[1] == "install-status"
        options = dict(zip(sys.argv[3::2], sys.argv[4::2]))
        assert set(options) == {"--game-dir", "--state-dir"}
        game = pathlib.Path(options["--game-dir"])
        state = pathlib.Path(options["--state-dir"])
        mode = game.name
        if mode == "timeout":
            time.sleep(5)
        if mode == "slow-complete":
            time.sleep(54)
        run_id = str(uuid.uuid4())
        log = state / "runs" / run_id
        log.mkdir(parents=True, mode=0o700)
        status = None if mode == "busy" else "partial" if mode in {"partial", "metadata"} else "missing" if mode == "missing" else "complete"
        code = 1 if mode == "busy" else 0
        result = dict(version=1, operation="install-status", product=sys.argv[2],
            run_id=run_id, game_dir=str(game), log_dir=str(log),
            result_path=str(log / "result.json"), success=code == 0, exit_code=code,
            status=status, error_code="RESOURCE_BUSY" if code else None,
            reason_code="MANIFEST_INVALID" if mode == "metadata" else "PAYLOAD_INCOMPLETE" if mode == "partial" else None)
        if mode == "wrong-product":
            result["product"] = "FIXTURE00002"
        if mode == "wrong-directory":
            result["game_dir"] = str(game.parent)
        if mode == "wrong-run":
            result["run_id"] = "not-a-uuid"
        if mode == "wrong-exit":
            result["exit_code"] = 1
        receipt = log / "result.json"
        receipt.write_text(json.dumps(result))
        receipt.chmod(0o600)
        if mode == "mismatch":
            result["status"] = "partial"
        print(json.dumps(result))
        sys.exit(code)
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let configuration = BackendConfiguration(executable: executable, stateDirectory: root.appendingPathComponent("manage"))
        let query = NativeInstallationQuery()
        check(NativeInstallationQuery.defaultTimeout == .seconds(120),
              "Read-only readiness allows the measured 54-second TUNIC inspection within a bounded 120-second deadline")
        let slowQuery = Task {
            try await query.run(configuration: configuration, product: "FIXTURE00001",
                gameDirectory: root.appendingPathComponent("slow-complete"),
                stateDirectory: root.appendingPathComponent("status-slow-complete"))
        }
        let slowStartDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !query.isRunning && ContinuousClock.now < slowStartDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(query.isRunning, "The 54-second readiness check keeps its inspection running rather than reporting failure")
        let slowResult = try await slowQuery.value
        check(slowResult.action == .play && slowResult.status == .complete && !query.isRunning,
              "A real 54-second synthetic inspection completes with default timing and preserves the authoritative Play result")
        check(NativeInstallationQuery.failureMessage(GameScriptError.timeout)
                == "Check is taking longer than expected. Try checking the installation again."
              && !NativeInstallationQuery.failureMessage(GameScriptError.invalidReceipt).contains("taking longer"),
              "Only a readiness deadline produces the retryable taking-longer message; invalid receipts remain explicit failures")
        let actions: [(String, NativeInstallationStatus.Action)] = [
            ("complete", .play), ("partial", .resume), ("missing", .install), ("metadata", .repair), ("busy", .check)
        ]
        for (mode, action) in actions {
            let result = try await query.run(configuration: configuration, product: "FIXTURE00001",
                gameDirectory: root.appendingPathComponent(mode), stateDirectory: root.appendingPathComponent("status-\(mode)"))
            check(result.action == action && (mode == "busy" ? !result.success : result.success),
                  "Read-only native status \(mode) selects \(action); query success alone never grants Play")
            if mode == "busy" {
                check(result.status == nil && result.explanation?.contains("in use") == true,
                      "RESOURCE_BUSY stays an explicit unavailable check, never partial/repair")
            }
        }
        do {
            _ = try await query.run(configuration: configuration, product: "FIXTURE00001",
                gameDirectory: root.appendingPathComponent("mismatch"), stateDirectory: root.appendingPathComponent("status-mismatch"))
            check(false, "Readiness stdout and persisted receipt must agree")
        } catch GameScriptError.statusMismatch {
            check(true, "Readiness stdout/status disagreement cannot admit Play")
        }
        for mode in ["wrong-product", "wrong-directory", "wrong-run", "wrong-exit"] {
            do {
                _ = try await query.run(configuration: configuration, product: "FIXTURE00001",
                    gameDirectory: root.appendingPathComponent(mode), stateDirectory: root.appendingPathComponent("status-\(mode)"))
                check(false, "Readiness must bind the requested product, directory, run and actual exit")
            } catch GameScriptError.invalidReceipt {
                check(true, "Readiness rejects \(mode) rather than admitting Play")
            }
        }
        do {
            _ = try await query.run(configuration: configuration, product: "FIXTURE00001",
                gameDirectory: root.appendingPathComponent("timeout"), stateDirectory: root.appendingPathComponent("status-timeout"),
                timeout: .milliseconds(100))
            check(false, "A stuck read-only inspector must time out")
        } catch GameScriptError.timeout {
            check(!query.isRunning, "A stuck read-only inspector is bounded and its exact child is joined")
        }
        let cancelledQuery = Task {
            try await query.run(configuration: configuration, product: "FIXTURE00001",
                gameDirectory: root.appendingPathComponent("timeout"), stateDirectory: root.appendingPathComponent("status-cancel"))
        }
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !query.isRunning && ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(query.isRunning, "Read-only cancellation exercises an actually started child")
        cancelledQuery.cancel()
        do {
            _ = try await cancelledQuery.value
            check(false, "Cancelling the read-only check must propagate cancellation")
        } catch is CancellationError {
            check(!query.isRunning, "Cancelling the read-only check joins its exact child before returning")
        }
        let inside = root.appendingPathComponent("complete/forbidden-status")
        do {
            _ = try await query.run(configuration: configuration, product: "FIXTURE00001",
                gameDirectory: root.appendingPathComponent("complete"), stateDirectory: inside)
            check(false, "Inspection evidence must stay outside the game")
        } catch GameScriptError.invalidDestination {
            check(!FileManager.default.fileExists(atPath: inside.path),
                  "Read-only inspection rejects an in-game evidence directory before creating it")
        }
        let resume = GameOperationRecord(id: InstalledGamesController.runID(), kind: .resume,
            productID: "FIXTURE00001", title: "Synthetic resume", destination: root.appendingPathComponent("game").path,
            installedID: UUID(), nativeAccountHash: String(repeating: "a", count: 64))
        try resume.validate()
        check(resume.kind.nativeOperation == "install",
              "Native Resume uses incremental install, not Repair's full redownload")
        let legacyResume = GameOperationRecord(id: InstalledGamesController.runID(), kind: .resume,
            productID: "FIXTURE00001", title: "Synthetic resume", destination: root.appendingPathComponent("game").path,
            installedID: UUID())
        do {
            try legacyResume.validate()
            check(false, "Resume cannot fall back to a legacy script")
        } catch { check(true, "Resume requires the explicit account-bound native operation journal") }
    }
}
