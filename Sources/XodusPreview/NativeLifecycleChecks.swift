// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

@MainActor
enum NativeLifecycleChecks {
    static func run(check: (Bool, String) -> Void) async throws {
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
            deadline = time.monotonic() + 5
            while not cancelled and time.monotonic() < deadline:
                time.sleep(0.01)
        code = 1 if operation == "repair" or cancelled else 0
        result = dict(version=1, run_id=run_id, operation=operation, product=product,
            success=code == 0, exit_code=code,
            error_code="CANCELLED" if cancelled else "OPERATION_FAILED" if code else None,
            game_dir=game, log_dir=str(log), result_path=str(log / "result.json"), progress_path=str(progress))
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
              "Native lifecycle: actual synthetic child result and persisted receipt agree after streamed progress")
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
              && saved.map { installed.launchableIDs.contains($0.id) } == true,
              "Native lifecycle: StoreID-bound installation persists and becomes locally ready without an invented launcher script")
        let reloaded = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc })
        await reloaded.load()
        check(reloaded.games.first?.usesNativeLifecycle == true && reloaded.launchableIDs.count == 1,
              "Native lifecycle: native installation routing survives registry reload")
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
        check(installed.games.contains { $0.storeId == "FIXTURE00002" && $0.usesNativeLifecycle == true }
              && installed.discoveryError?.contains("broken-game") == true,
              "Automatic discovery imports valid native records while a corrupt sibling stays an explicit separate error")
        let discoveredCount = installed.games.count
        await installed.discoverNativeInstallations(root: discovery)
        check(installed.games.count == discoveredCount,
              "Repeated discovery never duplicates an existing installation")
        let repair = try await runner.run(configuration: configuration, accountHash: String(repeating: "a", count: 64),
            operation: "repair", product: "FIXTURE00001", gameDirectory: game,
            runID: InstalledGamesController.runID(), stateRoot: root.appendingPathComponent("repair"))
        check(!repair.success && repair.errorCode == "OPERATION_FAILED",
              "Native lifecycle: stream completed before a failed repair cannot register success")
        let cancelled = try await runner.run(configuration: configuration, accountHash: String(repeating: "a", count: 64),
            operation: "launch", product: "FIXTURE00001", gameDirectory: game,
            runID: InstalledGamesController.runID(), stateRoot: root.appendingPathComponent("cancel"),
            launchEnvironment: ["S5_SYNTHETIC_ENV": "owned-fixture"],
            onProgress: { _ in runner.cancel() })
        check(cancelled.errorCode == "CANCELLED" && !runner.isRunning,
              "Native lifecycle: cancellation signals the exact live child and joins its terminal receipt")
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
        let launch = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: .standaloneWine, defaults: defaults)
        let args = try await launch.arguments()
        check(args.contains(primary.path) && args.contains("synthetic") && !args.contains("--shim-dir"),
              "A local launch keeps the explicit registry engine and selected pair without inferred shims")
        defaults.set(root.path, forKey: "Xodus.lifecycle.profileDirectory")
        let profile = NativeTitleLaunchProfile(version: 1, productID: nativeGame.storeId,
            shimDirectory: root.path, environment: ["CX_ENV": "synthetic override"])
        let profileURL = root.appendingPathComponent(nativeGame.storeId + ".json")
        try JSONEncoder().encode(profile).write(to: profileURL)
        let profiled = try NativeLaunchConfiguration.resolve(game: nativeGame, provider: .standaloneWine, defaults: defaults)
        let profileArguments = try await profiled.arguments()
        check(profileArguments.contains("--shim-dir") && profiled.profile?.environment["CX_ENV"] == "synthetic override",
              "A product-bound data-only launch profile forwards its explicit shims and environment")
        let wrongProfile = NativeTitleLaunchProfile(version: 1, productID: "OTHER0000001",
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
    }
}
