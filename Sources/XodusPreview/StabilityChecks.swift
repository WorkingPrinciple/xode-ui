// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// REQ-135–139 (owner COR-286/287, L19 d4a04aa3): game actions never lose saves, prefixes or another
/// process's operation, and gated titles say why. Synthetic folders only; no game or service.
@MainActor enum StabilityChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".xodus-stability-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try uninstallChecks(root: root.appendingPathComponent("uninstall"), check: check)
        do { try await uninstallActionChecks(root: root.appendingPathComponent("uninstall-actions"), check: check) }
        catch { check(false, "REQ-135 action fixture: \(error)") }
        do { try await twoProcessChecks(root: root.appendingPathComponent("two-process"), check: check) }
        catch { check(false, "REQ-136 two-process fixture: \(error)") }
        do { try await contentionChecks(root: root.appendingPathComponent("contention"), check: check) }
        catch { check(false, "fc2f17d1 contention fixture: \(error)") }
        try await journalChecks(root: root.appendingPathComponent("journal"), check: check)
        do { try await registryChecks(root: root.appendingPathComponent("registry"), check: check) }
        catch { check(false, "REQ-136 registry fixture: \(error)") }
        do { try await discardChecks(root: root.appendingPathComponent("discard"), check: check) }
        catch { check(false, "REQ-137 discard fixture: \(error)") }
        gatingChecks(check: check)
        do { try await installVerdictChecks(root: root.appendingPathComponent("verdicts"), check: check) }
        catch { check(false, "fc2f17d1 H1 fixture: \(error)") }
        heuristicChecks(check: check)
        do { try await accessReadBudgetChecks(check: check) }
        catch { check(false, "REQ-159 fixture: \(error)") }
    }

    /// REQ-159: the app polled every installed product's licence every minute and got this device throttled
    /// by login.live.com. Reads are now on demand for one product, cached 10 minutes and backed off on failure.
    static func accessReadBudgetChecks(check: (Bool, String) -> Void) async throws {
        let account = String(repeating: "a", count: 64)
        let installed = (0..<25).map { String(format: "9BUDGET%05d", $0) }
        let played = installed[3]
        let start = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
        var reads: [String] = []
        var failing = false
        let reader: @MainActor (String) async throws -> OdeAccountRead = { id in
            reads.append(id)
            if failing { throw ManagementError.disconnected }
            let payload: [String: Any] = ["section": "license", "accountHash": account,
                "checkedAt": "2030-01-01T00:00:00Z",
                "payload": ["productID": id, "access": "permitted", "reason": NSNull(), "expiresAt": NSNull()]]
            return try JSONDecoder().decode(OdeAccountRead.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let access = InstalledProductAccess()
        for minute in 0..<10 {
            await access.refresh(account: account, installedIDs: installed, now: start.addingTimeInterval(Double(minute) * 60),
                                 read: reader)
        }
        check(reads.isEmpty && access.readCount == 0,
              "REQ-159: ten minutes of library refreshes over 25 installed games make no licence reads (\(reads.count))")
        for minute in 0..<9 {
            await access.refresh(account: account, installedIDs: installed, now: start.addingTimeInterval(Double(minute) * 60),
                                 force: true, selectedProductID: played, read: reader)
        }
        check(reads == [played] && access.permits(played, account: account, now: start.addingTimeInterval(540)),
              "REQ-159: playing one game reads only its licence, once per 10 minutes (\(reads.count) reads in 9 Play presses)")
        await access.refresh(account: account, installedIDs: installed, now: start.addingTimeInterval(601),
                             force: true, selectedProductID: played, read: reader)
        check(reads.count == 2, "REQ-159: after 10 minutes the next Play reads that licence again")
        failing = true
        let other = installed[7]
        await access.refresh(account: account, installedIDs: installed, now: start.addingTimeInterval(700),
                             force: true, selectedProductID: other, read: reader)
        let afterFailure = reads.count
        await access.refresh(account: account, installedIDs: installed, now: start.addingTimeInterval(720),
                             force: true, selectedProductID: other, read: reader)
        await access.refresh(account: account, installedIDs: installed, now: start.addingTimeInterval(730),
                             force: true, selectedProductID: installed[9], read: reader)
        check(afterFailure == 3 && reads.count == 3 && access.pausedUntil != nil
              && InstalledProductAccess.backoff(afterFailures: 1) == 60
              && InstalledProductAccess.backoff(afterFailures: 3) == 240
              && InstalledProductAccess.backoff(afterFailures: 10) == InstalledProductAccess.maximumBackoff,
              "REQ-159: a failed read backs off for every product (60 s doubling to 15 min) instead of retrying")
    }

    /// Review fc2f17d1 H1: producer #7 sends installation verdicts as a lifecycle error_code. Each is a receipt,
    /// maps to Repair or Remove with its reason, and never locks the app in recovery.
    static func installVerdictChecks(root: URL, check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let state = root.appendingPathComponent("state"), game = root.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        func producerResult(_ operation: String, _ code: String) throws -> NativeGameResult {
            let runID = UUID().uuidString.lowercased()
            let log = state.appendingPathComponent("runs/\(runID)").path
            let json = """
                {"version":1,"operation":"\(operation)","product":"FIXTURE00130","run_id":"\(runID)","success":false,\
                "exit_code":1,"error_code":"\(code)","error":"\(code): fixture","game_dir":"\(game.path)",\
                "log_dir":"\(log)","result_path":"\(log)/result.json","progress_path":"\(log)/progress.jsonl"}
                """
            let result = try JSONDecoder().decode(NativeGameResult.self, from: Data(json.utf8))
            try result.validate(operation: operation, product: "FIXTURE00130", gameDirectory: game,
                                stateDirectory: state, exitCode: 1)
            return result
        }
        let expected: [(String, NativeInstallationStatus.Action, String)] = [
            ("INSTALL_REPAIR_REQUIRED", .repair, NativeInstallationStatus.repairRequiredExplanation),
            ("INSTALL_IDENTITY_UNPROVEN", .remove, NativeInstallationStatus.identityUnprovenExplanation),
            ("INSTALL_PRODUCT_MISMATCH", .remove, NativeInstallationStatus.productMismatchExplanation)]
        for (code, action, message) in expected {
            let launch = try producerResult("launch", code), repair = try producerResult("repair", code)
            check(launch.installVerdict == action && launch.launchFailureMessage(stoppedByUser: false) == message
                  && repair.installVerdict == action && repair.failureMessage == message,
                  "fc2f17d1 H1: a producer \(code) launch or repair result is a valid receipt that offers \(action) with its reason")
        }
        let preflight = NativeGameResult.launchPreflightCodes.sorted()
        let preflightResults = try preflight.map { try producerResult("launch", $0) }
        check(preflight.count == 10 && preflightResults.allSatisfy {
                  $0.installVerdict == nil && $0.preflightMessage != nil
                  && $0.launchFailureMessage(stoppedByUser: false) == $0.preflightMessage
                  && $0.launchFailureMessage(stoppedByUser: false) != InstalledGameActionCopy.launchUnavailable
              } && Set(preflightResults.compactMap(\.preflightMessage)).count >= 8,
              "producer #8/L12: \(preflight.joined(separator: ", ")) are valid launch receipts with their own explanation, never recovery")
        let required = try producerResult("launch", "TITLE_RECIPE_REQUIRED")
        check(NativeGameResult.failureCodes.contains("TITLE_RECIPE_REQUIRED") && required.installVerdict == nil,
              "REQ-153: TITLE_RECIPE_REQUIRED is a valid launch receipt")
        let recipe = try producerResult("launch", "TITLE_RECIPE_REJECTED")
        check(recipe.installVerdict == nil && recipe.launchFailureMessage(stoppedByUser: false) == InstalledGameActionCopy.launchUnavailable,
              "fc2f17d1 H1: TITLE_RECIPE_REJECTED is a valid launch receipt, not a broken one")
        // The controller path: a repair that ends INSTALL_PRODUCT_MISMATCH finishes without recovery.
        let paths = GameScriptPaths(scripts: root.appendingPathComponent("scripts"),
            processed: root.appendingPathComponent("processed"), logs: root.appendingPathComponent("logs"),
            games: root.appendingPathComponent("Games"), journal: root.appendingPathComponent("private/operation.json"))
        let library = InstalledGamesController(store: InstalledGameStore(file: root.appendingPathComponent("games.json")))
        await library.load()
        let record = GameOperationRecord(id: InstalledGamesController.runID(), kind: .repair, productID: "FIXTURE00130",
            title: "Verdict", destination: game.path, installedID: UUID(), nativeAccountHash: String(repeating: "a", count: 64))
        try await GameOperationJournal(file: paths.journal).save(record)
        let controller = GameOperationsController(installed: library, paths: paths)
        await controller.restore()
        try await controller.completeNative(record, result: try producerResult("repair", "INSTALL_PRODUCT_MISMATCH"))
        check(!controller.recoveryRequired && controller.operation == nil
              && controller.error == NativeInstallationStatus.productMismatchExplanation,
              "fc2f17d1 H1: a repair refused as INSTALL_PRODUCT_MISMATCH shows Remove's reason and never locks the app in recovery")
        let partialMismatch = NativeInstallationStatus(version: 1, operation: "install-status", product: "FIXTURE00130",
            runID: UUID().uuidString, gameDirectory: game.path, logDirectory: "/fixture/log",
            resultPath: "/fixture/log/result.json", success: true, exitCode: 0, errorCode: nil, status: .partial,
            reasonCode: "PRODUCT_MISMATCH", detail: nil, filesTotal: nil, contentID: nil)
        check(partialMismatch.action == .remove && partialMismatch.explanation == NativeInstallationStatus.productMismatchExplanation,
              "fc2f17d1 H1: install-status PRODUCT_MISMATCH offers Remove (Keep Files), not Repair")
    }

    /// Review fc2f17d1 M1: save-like names and extensions anywhere in the folder refuse Delete Game Files.
    static func heuristicChecks(check: (Bool, String) -> Void) {
        typealias Ops = GameOperationsController
        let saves = ["autosave_03.bin", "mysavedata", "slot1.sav", "game.sl2", "quick.ess", "player.profile.json", "world.save"]
        let content = ["data.pck", "game.exe", "microsoftgame.config", "textures.bin", "level01.pak"]
        check(saves.allSatisfy(Ops.looksLikeSave) && !content.contains(where: Ops.looksLikeSave),
              "fc2f17d1 M1: save-like names and extensions are recognised; ordinary package files are not")
        let witcher = (try? NativeTitleLaunchProfile.bundledProfiles())?.first { $0.productID == "C261457LCNMJ" }
        var withArguments = witcher
        withArguments?.gameArguments = ["-usebundles", "-splitcook", "-dlcinstall", "-goty"]
        check(witcher?.runtime == nil && witcher?.gameArguments == nil
              && witcher?.playArguments.contains("--game-arg") == false
              && witcher?.playArguments.starts(with: ["--exe", "bin/Gaming.Desktop.x64/witcher3.exe"]) == true
              && Array(withArguments?.playArguments.suffix(8) ?? []) == ["--game-arg", "-usebundles", "--game-arg", "-splitcook",
                                                                         "--game-arg", "-dlcinstall", "--game-arg", "-goty"],
              "REQ-140/COR-320: the Witcher 3 baseline passes no arguments on the app-default runtime; a profile's gameArguments each become one --game-arg")
    }

    // MARK: REQ-135 Uninstall

    private static func game(_ folder: URL, product: String = "FIXTURE00077") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<Game><Identity Name=\"Fixture.Game\" Version=\"1.0.0.0\"/><StoreId>\(product)</StoreId></Game>".utf8)
            .write(to: folder.appendingPathComponent("MicrosoftGame.config"))
        try Data("payload".utf8).write(to: folder.appendingPathComponent("game.exe"))
    }

    private static func snapshot(_ folder: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url) { files[url.path] = data }
        }
        return files
    }

    static func uninstallChecks(root: URL, check: (Bool, String) -> Void) throws {
        typealias Ops = GameOperationsController
        let clean = root.appendingPathComponent("clean")
        try game(clean)
        let inRootSave = root.appendingPathComponent("in-root-save")
        try game(inRootSave)
        try FileManager.default.createDirectory(at: inRootSave.appendingPathComponent("Saves"), withIntermediateDirectories: true)
        try Data("slot".utf8).write(to: inRootSave.appendingPathComponent("Saves/slot1.sav"))
        let nestedPrefix = root.appendingPathComponent("nested-prefix")
        try game(nestedPrefix)
        try FileManager.default.createDirectory(at: nestedPrefix.appendingPathComponent("bottle/drive_c"), withIntermediateDirectories: true)
        try Data("REGEDIT4".utf8).write(to: nestedPrefix.appendingPathComponent("bottle/system.reg"))
        let unknown = root.appendingPathComponent("unknown-layout")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: unknown.appendingPathComponent("game.exe"))
        let otherProduct = root.appendingPathComponent("other-product")
        try game(otherProduct, product: "FIXTURE00078")
        let linked = root.appendingPathComponent("linked")
        try game(linked)
        let separatePrefix = root.appendingPathComponent("separate-prefix/drive_c/users")
        try FileManager.default.createDirectory(at: separatePrefix, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: separatePrefix.appendingPathComponent("progress.sav"))
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("saves-link"),
                                                   withDestinationURL: separatePrefix)
        // F1: an unreadable folder that sorts before the saves must not end the walk as "safe".
        let unreadable = root.appendingPathComponent("unreadable-first")
        try game(unreadable)
        try FileManager.default.createDirectory(at: unreadable.appendingPathComponent("AAA-locked"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unreadable.appendingPathComponent("ZZZ/Saves"), withIntermediateDirectories: true)
        try Data("slot".utf8).write(to: unreadable.appendingPathComponent("ZZZ/Saves/slot.sav"))
        chmod(unreadable.appendingPathComponent("AAA-locked").path, 0)
        defer { chmod(unreadable.appendingPathComponent("AAA-locked").path, 0o700) }
        // F2: Unreal keeps saves deep under …/Saved/SaveGames.
        let unreal = root.appendingPathComponent("unreal")
        try game(unreal)
        try FileManager.default.createDirectory(at: unreal.appendingPathComponent("Game/Content/Paks/a/b/Saved/SaveGames"),
                                                withIntermediateDirectories: true)
        try Data("slot".utf8).write(to: unreal.appendingPathComponent("Game/Content/Paks/a/b/Saved/SaveGames/0.sav"))
        let before = snapshot(root)
        let verdicts = [clean, inRootSave, nestedPrefix, unknown, otherProduct, linked, unreadable, unreal].map {
            Ops.uninstallSafety(folder: $0, productID: "FIXTURE00077")
        }
        check(verdicts[0] == .safe && verdicts.dropFirst().allSatisfy { $0 == .unsafe(Ops.uninstallUnsafeMessage) },
              "REQ-135: only a verified game folder can be deleted; in-root saves, a nested prefix, an unknown layout, another product and a symlink an unreadable entry before Saves and a deep Unreal Saved all fail closed: \(verdicts)")
        check(snapshot(root) == before,
              "REQ-135: the safety check leaves every sentinel (in-root save, nested prefix, separate prefix) unchanged")
        check(InstalledGameActionCopy.uninstallExplanation.contains("Keep Files")
              && InstalledGameActionCopy.deleteGameFiles == "Delete Game Files",
              "REQ-135: Uninstall defaults to Remove (Keep Files); deleting is the explicit secondary action")
    }

    /// Review ea4dda97 F2: the real Remove and Delete Game Files actions, with sentinels inside and beside the root.
    static func uninstallActionChecks(root: URL, check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = root.appendingPathComponent("Game")
        try game(folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Saved"), withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("Saved/slot.sav"))
        let beside = root.appendingPathComponent("prefix/drive_c/users/save.dat")
        try FileManager.default.createDirectory(at: beside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("beside".utf8).write(to: beside)
        let sentinels = { snapshot(folder).merging(snapshot(root.appendingPathComponent("prefix"))) { a, _ in a } }
        let before = sentinels()
        let entry = InstalledGame(id: UUID(), title: "Sentinel", identityName: "Fixture.Game", version: "1.0.0.0",
                                  storeId: "FIXTURE00077", folder: folder.path, launcher: "", importedAt: Date(),
                                  usesNativeLifecycle: true)
        let store = InstalledGameStore(file: root.appendingPathComponent("registry/installed-games.json"))
        try await store.save([entry])
        let library = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc }, mountedStorageRoots: { [] })
        await library.load()
        let paths = GameScriptPaths(scripts: root.appendingPathComponent("scripts"),
            processed: root.appendingPathComponent("processed"), logs: root.appendingPathComponent("logs"),
            games: root.appendingPathComponent("Games"), journal: root.appendingPathComponent("private/operation.json"))
        let operations = GameOperationsController(installed: library, paths: paths)
        guard let loaded = library.games.first else { check(false, "REQ-135 action fixture must load"); return }
        operations.prepareUninstall(loaded)
        operations.confirmUninstall(loaded)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while operations.error == nil, operations.operation != nil || operations.uninstallConsent != nil,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let deleteRefused = operations.error?.contains("won't be deleted") == true && sentinels() == before
        operations.prepareUninstall(loaded)
        await operations.uninstallKeepingFiles(loaded)
        check(deleteRefused && library.games.isEmpty && sentinels() == before,
              "REQ-135 F2: Delete Game Files refuses a folder with saves and Remove (Keep Files) only unregisters it; sentinels inside and beside the root are unchanged (error \(operations.error ?? "nil"))")
    }

    /// Review ea4dda97 F3: a separate process (python, flock) writes while this one does; nothing is lost.
    static func twoProcessChecks(root: URL, check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let journalFile = root.appendingPathComponent("game-operation.json")
        let foreign = record("xodus-20261027T200000Z-000000aa", product: "FIXTURE00120", destination: root.path + "/foreign")
        let foreignJSON = String(decoding: try JSONEncoder().encode(foreign), as: UTF8.self)
        // The helper holds the lease, writes its run's journal, then holds a little longer before releasing.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        helper.arguments = ["-c", """
            import fcntl, os, sys, time
            lock = open(sys.argv[1] + ".lock", "a"); fcntl.flock(lock, fcntl.LOCK_EX)
            open(sys.argv[2], "w").write("ready")
            fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600); os.write(fd, sys.argv[3].encode()); os.close(fd)
            time.sleep(0.6); fcntl.flock(lock, fcntl.LOCK_UN)
            """, journalFile.path, root.appendingPathComponent("helper-ready").path, foreignJSON]
        try helper.run()
        let ready = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("helper-ready").path), ContinuousClock.now < ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        let journal = GameOperationJournal(file: journalFile)
        let ours = record("xodus-20261027T200001Z-000000bb", product: "FIXTURE00121", destination: root.path + "/ours")
        var refused = false
        do { try await journal.save(ours) } catch GameScriptError.busy { refused = true }
        helper.waitUntilExit()
        let survivor = try? await journal.load()
        check(refused && survivor == foreign,
              "REQ-136 F3: while another process holds the journal lease, this process waits, then refuses rather than overwriting its run")
    }

    /// Review fc2f17d1 LOW: another process holds each lock; the engine override and the resumable record wait
    /// for it instead of writing underneath it.
    static func contentionChecks(root: URL, check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func holding(_ lock: URL, during body: () async throws -> Void) async throws -> Duration {
            let ready = root.appendingPathComponent("ready-\(UUID().uuidString)")
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            helper.arguments = ["-c", """
                import fcntl, sys, time
                lock = open(sys.argv[1], "a"); fcntl.flock(lock, fcntl.LOCK_EX)
                open(sys.argv[2], "w").write("ready"); time.sleep(0.6); fcntl.flock(lock, fcntl.LOCK_UN)
                """, lock.path, ready.path]
            try helper.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let start = ContinuousClock.now
            try await body()
            let waited = start.duration(to: .now)
            helper.waitUntilExit()
            return waited
        }
        let registry = root.appendingPathComponent("installed-games.json")
        let folder = root.appendingPathComponent("Game")
        try game(folder)
        let entry = InstalledGame(id: UUID(), title: "Contended", identityName: "Fixture.Game", version: "1.0.0.0",
                                  storeId: "FIXTURE00077", folder: folder.path, launcher: "", importedAt: Date(),
                                  usesNativeLifecycle: true)
        let store = InstalledGameStore(file: registry)
        try await store.save([entry])
        var games: [InstalledGame] = []
        let overrideWait = try await holding(registry.appendingPathExtension("lock")) {
            games = try await store.setEngineOverride(id: entry.id, override: nil)
        }
        check(overrideWait >= .milliseconds(400) && games.map(\.id) == [entry.id],
              "fc2f17d1 LOW: setEngineOverride waits for another process's registry lock (\(overrideWait)) and keeps the entry")
        let journalFile = root.appendingPathComponent("game-operation.json")
        let journal = GameOperationJournal(file: journalFile)
        let partial = record("xodus-20261027T210000Z-000000cc", product: "FIXTURE00131", destination: root.path + "/partial")
        let resumableWait = try await holding(journalFile.appendingPathExtension("lock")) {
            try await journal.retainResumable(partial)
        }
        let retained = try await journal.loadResumable()
        check(resumableWait >= .milliseconds(400) && retained.values.contains { $0.id == partial.id },
              "fc2f17d1 LOW: retainResumable waits for another process's journal lock (\(resumableWait)) and then records the run")
    }

    // MARK: REQ-136 journal and registry

    private static func record(_ id: String, product: String, destination: String) -> GameOperationRecord {
        GameOperationRecord(id: id, kind: .install, productID: product, title: "Fixture",
                            destination: destination, installedID: nil)
    }

    static func journalChecks(root: URL, check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("game-operation.json")
        let processA = GameOperationJournal(file: file), processB = GameOperationJournal(file: file)
        let first = record("xodus-20261027T170000Z-0000000a", product: "FIXTURE00080", destination: root.path + "/a")
        let second = record("xodus-20261027T170001Z-0000000b", product: "FIXTURE00081", destination: root.path + "/b")
        try await processA.save(first)
        var refused = false
        do { try await processB.save(second) } catch GameScriptError.busy { refused = true }
        try await processB.clear(expectedRunID: second.id)
        let survivor = try await processA.load()
        check(refused && survivor == first,
              "REQ-136: a second process can neither overwrite nor clear another run's pending journal")
        try await processA.clear(expectedRunID: first.id)
        check(try await processA.load() == nil, "REQ-136: the owning run clears its own journal")
    }

    static func registryChecks(root: URL, check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("installed-games.json")
        let games = (0..<12).map { index in
            InstalledGame(id: UUID(), title: "Game \(index)", identityName: "Fixture\(index)", version: "1",
                          storeId: String(format: "FIXTURE%05d", 100 + index),
                          folder: root.appendingPathComponent("g\(index)").path, launcher: "", importedAt: Date(),
                          usesNativeLifecycle: true)
        }
        // Two store instances stand for two processes editing the same registry concurrently.
        let stores = [InstalledGameStore(file: file), InstalledGameStore(file: file)]
        await withTaskGroup(of: Void.self) { group in
            for (index, entry) in games.enumerated() {
                let store = stores[index % 2]
                group.addTask { _ = try? await store.upsert(entry) }
            }
        }
        let saved = try await stores[0].load()
        check(Set(saved.map(\.id)) == Set(games.map(\.id)),
              "REQ-136: concurrent registry edits from two stores all survive (\(saved.count)/\(games.count))")
    }

    // MARK: REQ-137 discard

    static func discardChecks(root: URL, check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let journal = GameOperationJournal(file: root.appendingPathComponent("game-operation.json"))
        let registry = root.appendingPathComponent("installed-games.json")
        let partial = root.appendingPathComponent("Partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("chunk".utf8).write(to: partial.appendingPathComponent("chunk.bin"))
        let stopped = record("xodus-20261027T170002Z-0000000c", product: "FIXTURE00090", destination: partial.path)
        try await journal.retainResumable(stopped)
        let deleteMarker = root.appendingPathComponent("deleted")
        let attempt: @Sendable () async -> Result<Bool, Error> = {
            do {
                return .success(try await journal.discardStopped(stopped,
                    registeredFolders: { try InstalledGameStore.registeredFolders(file: registry) },
                    delete: {
                        FileManager.default.createFile(atPath: deleteMarker.path, contents: Data())
                        return true
                    }))
            } catch { return .failure(error) }
        }
        // Another process registered the folder after this window loaded.
        let other = InstalledGame(id: UUID(), title: "Other", identityName: "Other", version: "1",
                                  storeId: "FIXTURE00090", folder: partial.path, launcher: "", importedAt: Date(),
                                  usesNativeLifecycle: true)
        _ = try await InstalledGameStore(file: registry).upsert(other)
        let registered = await attempt()
        _ = try await InstalledGameStore(file: registry).remove(id: other.id)
        // Another process holds an active operation on the same folder.
        let active = record("xodus-20261027T170003Z-0000000d", product: "FIXTURE00090", destination: partial.path)
        try await journal.save(active)
        let resumed = await attempt()
        try await journal.clear(expectedRunID: active.id)
        check(!FileManager.default.fileExists(atPath: deleteMarker.path)
              && { if case .failure(GameScriptError.busy) = registered { true } else { false } }()
              && { if case .failure(GameScriptError.busy) = resumed { true } else { false } }(),
              "REQ-137: discarding fails closed when another process registered the folder or holds an active operation on it")
        // No journal at all is the ordinary case and must still discard.
        let ordinary = await attempt()
        check({ if case .success(true) = ordinary { true } else { false } }()
              && FileManager.default.fileExists(atPath: deleteMarker.path),
              "REQ-137/L19: an absent journal is no conflict; an ordinary stopped download discards under the lease")
    }

    // MARK: REQ-138 / REQ-139

    static func gatingChecks(check: (Bool, String) -> Void) {
        let ordinary = "io.github.dragoshont.xodus.development", qual = "io.github.dragoshont.xodus.qualification"
        typealias Run = ConcurrentAppGuard.Running
        check(ConcurrentAppGuard.runningPeer(bundleID: ordinary, running: [Run(bundleID: ordinary, pid: 10), Run(bundleID: qual, pid: 11)], selfPID: 10) == "X Ode Qualification"
              && ConcurrentAppGuard.runningPeer(bundleID: qual, running: [Run(bundleID: qual, pid: 11), Run(bundleID: ordinary, pid: 10)], selfPID: 11) == "X Ode"
              && ConcurrentAppGuard.runningPeer(bundleID: ordinary, running: [Run(bundleID: ordinary, pid: 10), Run(bundleID: ordinary, pid: 12)], selfPID: 12) == "Another copy of X Ode"
              && ConcurrentAppGuard.runningPeer(bundleID: ordinary, running: [Run(bundleID: ordinary, pid: 10)], selfPID: 10) == nil
              && ConcurrentAppGuard.runningPeer(bundleID: nil, running: [Run(bundleID: ordinary, pid: 10)], selfPID: 99) == nil,
              "REQ-138 F4: the ordinary and Qualification apps, and a second copy of either, refuse to run at the same time")
        let copies: [(path: String, bundleID: String, build: Int)] = [
            ("/Applications/Ode.app", ordinary, 681), ("/Applications/Q.app", qual, 690),
            ("/Applications/Other.app", "com.example.other", 999)]
        check(ConcurrentAppGuard.newerInstalledBuild(selfBuild: 681, installed: copies)?.build == 690
              && ConcurrentAppGuard.newerInstalledBuild(selfBuild: 690, installed: copies) == nil
              && ConcurrentAppGuard.newerBuildMessage(path: "/Applications/Q.app", build: 690).contains("build 690"),
              "Owner hardening 2: an older X Ode of either variant refuses to start games once a newer build is installed; other apps are ignored")
        let fh6 = NativeLaunchSupport.notSupported(NativeLaunchSupport.inTestingReason)
        check(fh6.unavailableTitle == "In testing on Mac" && !fh6.unavailableTitle.contains("Not available")
              && NativeLaunchSupport.notSupported("x").unavailableTitle == NativeLaunchSupport.notSupportedTitle,
              "REQ-139: a test-build title says it's in testing, so it never contradicts \"Last played … on this Mac\"")
        check(GameReadyAnnouncement(productID: "A", title: "Gated", folder: "/x", playable: false).body
                == "Gated was installed. Play isn't offered for it in this build yet."
              && GameReadyAnnouncement(productID: "A", title: "Game", folder: "/x").body == "Game is ready to play.",
              "L19 MED 3: an installed title Play can't start is never announced as ready to play")
        check(GameOperationsController.finishPlayingMessage("Hades") == "Finish playing Hades first, then try again.",
              "d6d729c0 LOW: uninstall or repair of the game that's playing explains itself")
        func status(_ code: String, success: Bool) -> NativeInstallationStatus {
            NativeInstallationStatus(version: 1, operation: "install-status", product: "FIXTURE00095",
                runID: UUID().uuidString, gameDirectory: "/fixture", logDirectory: "/fixture/log",
                resultPath: "/fixture/log/result.json", success: success, exitCode: success ? 0 : 1,
                errorCode: success ? nil : code, status: success ? .partial : nil, reasonCode: success ? code : nil,
                detail: nil, filesTotal: nil, contentID: nil)
        }
        let repairs = [status("INSTALL_REPAIR_REQUIRED", success: true), status("INSTALL_REPAIR_REQUIRED", success: false)]
        let unproven = [status("INSTALL_IDENTITY_UNPROVEN", success: true), status("INSTALL_IDENTITY_UNPROVEN", success: false)]
        check(repairs.allSatisfy { $0.action == .repair }
              && unproven.allSatisfy { $0.action == .remove && $0.explanation == NativeInstallationStatus.identityUnprovenExplanation }
              && status("INSTALL_PRODUCT_MISMATCH", success: false).action == .remove
              && status("INSTALL_PRODUCT_MISMATCH", success: true).explanation == NativeInstallationStatus.productMismatchExplanation
              && status("SOMETHING_ELSE", success: false).action == .check,
              "REQ-141: INSTALL_REPAIR_REQUIRED offers Repair and INSTALL_IDENTITY_UNPROVEN offers Remove (Keep Files) with its reason, never Retry")
        check(NativeGameResult.failureCodes.contains("UNINSTALL_FAILED")
              && !InstalledGameManagement.offersInPlaceUpdate,
              "L19 MED 4/5: UNINSTALL_FAILED is a known receipt code; in-place Update without rollback is off")
        #if !XODUS_FH6_QUALIFICATION
        check(NativeLaunchSupport.evaluate(productID: NativeFH6Recipe.productID) == fh6,
              "REQ-139: ordinary builds gate Forza Horizon 6 with the in-testing reason")
        #endif
    }
}
