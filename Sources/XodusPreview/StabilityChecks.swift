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
        try await journalChecks(root: root.appendingPathComponent("journal"), check: check)
        do { try await registryChecks(root: root.appendingPathComponent("registry"), check: check) }
        catch { check(false, "REQ-136 registry fixture: \(error)") }
        do { try await discardChecks(root: root.appendingPathComponent("discard"), check: check) }
        catch { check(false, "REQ-137 discard fixture: \(error)") }
        gatingChecks(check: check)
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
        let before = snapshot(root)
        let verdicts = [clean, inRootSave, nestedPrefix, unknown, otherProduct, linked].map {
            Ops.uninstallSafety(folder: $0, productID: "FIXTURE00077")
        }
        check(verdicts[0] == .safe && verdicts.dropFirst().allSatisfy { $0 == .unsafe(Ops.uninstallUnsafeMessage) },
              "REQ-135: only a verified game folder can be deleted; in-root saves, a nested prefix, an unknown layout, another product and a symlink all fail closed: \(verdicts)")
        check(snapshot(root) == before,
              "REQ-135: the safety check leaves every sentinel (in-root save, nested prefix, separate prefix) unchanged")
        check(InstalledGameActionCopy.uninstallExplanation.contains("Keep Files")
              && InstalledGameActionCopy.deleteGameFiles == "Delete Game Files",
              "REQ-135: Uninstall defaults to Remove (Keep Files); deleting is the explicit secondary action")
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
        check(ConcurrentAppGuard.runningPeer(bundleID: ordinary, running: [ordinary, qual]) == "X Ode Qualification"
              && ConcurrentAppGuard.runningPeer(bundleID: qual, running: [qual, ordinary]) == "X Ode"
              && ConcurrentAppGuard.runningPeer(bundleID: ordinary, running: [ordinary]) == nil
              && ConcurrentAppGuard.runningPeer(bundleID: nil, running: [ordinary, qual]) == nil,
              "REQ-138: the ordinary and Qualification apps refuse to run at the same time")
        let fh6 = NativeLaunchSupport.notSupported(NativeLaunchSupport.inTestingReason)
        check(fh6.unavailableTitle == "In testing on Mac" && !fh6.unavailableTitle.contains("Not available")
              && NativeLaunchSupport.notSupported("x").unavailableTitle == NativeLaunchSupport.notSupportedTitle,
              "REQ-139: a test-build title says it's in testing, so it never contradicts \"Last played … on this Mac\"")
        check(GameReadyAnnouncement(productID: "A", title: "Gated", folder: "/x", playable: false).body
                == "Gated was installed. Play isn't offered for it in this build yet."
              && GameReadyAnnouncement(productID: "A", title: "Game", folder: "/x").body == "Game is ready to play.",
              "L19 MED 3: an installed title Play can't start is never announced as ready to play")
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
