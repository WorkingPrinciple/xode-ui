// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
import AppKit
import SwiftUI
import XodusManagement
@testable import XodusPreview

final class InstalledGameRefreshChecks: XCTestCase {
    @MainActor
    func testNativeRecoveryWaitsForPersistentStorageAdmission() async throws {
        let operations = GameOperationsController(installed: InstalledGamesController())
        let folder = FileManager.default.temporaryDirectory
        let gates = (0..<4).map { _ in PackageInspectionInterleaving() }
        defer { gates.forEach { $0.release() } }
        let workers = gates.map { gate in
            Task { try await operations.storageProbe.read { try gate.inspect(folder) } }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gates.allSatisfy(\.isWaiting) {
            guard ContinuousClock.now < deadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        workers.forEach { $0.cancel() }
        for worker in workers {
            do { _ = try await worker.value; XCTFail("Blocked waiter must cancel") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        let record = GameOperationRecord(id: InstalledGamesController.runID(), kind: .install,
            productID: "FIXTURE00001", title: "Recovery admission", destination: folder.path,
            installedID: nil, nativeAccountHash: String(repeating: "a", count: 64))
        var finished = false
        let recovery = Task {
            defer { finished = true }
            return try await operations.readNativeRecovery(record)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finished, "Receipt path construction and reading must wait for the existing owner")
        XCTAssertEqual(operations.storageProbe.activeReads, 4)
        recovery.cancel()
        do { _ = try await recovery.value; XCTFail("Unadmitted recovery must propagate cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "Recovery bypassed admission: \(error)") }
        XCTAssertEqual(operations.storageProbe.activeReads, 4,
                       "Cancelling recovery cannot release the four actual blocked reservations")
        gates.forEach { $0.release() }
        let returnDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while operations.storageProbe.activeReads != 0 {
            guard ContinuousClock.now < returnDeadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        let retainedGate = PackageInspectionInterleaving()
        defer { retainedGate.release() }
        let retained = Task {
            try await operations.storageProbe.read(key: "native-recovery:" + record.id) {
                try retainedGate.inspect(folder)
            }
        }
        let retainedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !retainedGate.isWaiting {
            guard ContinuousClock.now < retainedDeadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        retained.cancel()
        do { _ = try await retained.value; XCTFail("Blocked recovery waiter must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await operations.readNativeRecovery(record)
            XCTFail("A retained recovery record must not be re-admitted")
        } catch {
            XCTAssertEqual(error as? GameStorageProbeError, .pending)
        }
        XCTAssertEqual(operations.storageProbe.activeReads, 1)
        retainedGate.release()
        let finalDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while operations.storageProbe.activeReads != 0 {
            guard ContinuousClock.now < finalDeadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    func testOnlyDiscoveryReservationsEnterPendingRoots() async throws {
        let controller = InstalledGamesController()
        let root = FileManager.default.temporaryDirectory
        let gate = PackageInspectionInterleaving()
        defer { gate.release() }
        let work = Task {
            try await controller.readinessProbe.read(key: "discovery-root:" + root.path) {
                try gate.inspect(root)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.isWaiting {
            guard ContinuousClock.now < deadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        work.cancel()
        do { _ = try await work.value; XCTFail("Blocked waiter must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        controller.reconcilePendingDiscoveryRoots(volumes: nil)
        XCTAssertEqual(controller.pendingDiscoveryRoots, [root.path],
                       "Real discovery reservations remain fail-closed after waiter cancellation")
        gate.release()
        while controller.readinessProbe.activeReads != 0 {
            guard ContinuousClock.now < deadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    func testUnavailableRecordedRootStaysLexicalAndSkipsInspection() async throws {
        let missingMount = "/Volumes/COR479-\(UUID().uuidString)"
        let folder = missingMount + "/Xodus/registered"
        let game = InstalledGame(id: UUID(), title: "Readiness transition", identityName: "", version: "",
            storeId: "9N9C8SV0S16W", folder: folder, launcher: "", importedAt: .distantPast,
            usesNativeLifecycle: true, storageVolume: GameStorageVolume(path: missingMount))
        let original = URL(fileURLWithPath: missingMount + "/Xodus", isDirectory: true)
        let roots = GameInstallationDiscovery.discoveryRoots(originalRoot: original, location: nil, entries: [game])
        XCTAssertTrue(roots.allSatisfy { $0.0.hasDirectoryPath },
                      "Recorded roots must not infer directory-ness before volume availability")
        let observation = try await GameStorageProbe().read {
            try GameInstallationDiscovery.scan(originalRoot: original, location: nil, entries: [game],
                mountedRoots: [], originalVolume: game.storageVolume, originalRequired: true) { _ in
                    XCTFail("Unavailable volume must not reach per-folder inspection")
                    throw InstalledGameError.invalidConfig
                }
        }
        XCTAssertTrue(observation.candidates.isEmpty)
        XCTAssertTrue(observation.scannedRoots.isEmpty)
        XCTAssertEqual(observation.errors.count, 1)
        XCTAssertTrue(observation.errors[0].contains(GameInstallLocationError.driveUnavailable.localizedDescription))
    }

    @MainActor
    func testRepeatedBlockedRootDoesNotStarveHealthyStorage() async throws {
        let probe = GameStorageProbe()
        let folder = FileManager.default.temporaryDirectory
        let gates = (0..<4).map { _ in PackageInspectionInterleaving() }
        defer { gates.forEach { $0.release() } }
        let rootKey = folder.path
        let first = Task { try await probe.read(key: rootKey) { try gates[0].inspect(folder) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gates[0].isWaiting {
            guard ContinuousClock.now < deadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        first.cancel()
        do { _ = try await first.value; XCTFail("Blocked root waiter must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        for gate in gates.dropFirst() {
            do {
                _ = try await probe.read(timeout: .milliseconds(30), key: rootKey) { try gate.inspect(folder) }
                XCTFail("A retained root must not be re-admitted")
            } catch {
                XCTAssertEqual(error as? GameStorageProbeError, .pending,
                               "Repeated discovery is coalesced before another syscall starts")
            }
        }
        XCTAssertEqual(probe.activeReads, 1)
        XCTAssertFalse(gates.dropFirst().contains(where: \.isWaiting))
        do {
            let healthy = try await probe.read(timeout: .milliseconds(30), key: rootKey + "/healthy") {
                FileManager.default.fileExists(atPath: folder.path)
            }
            XCTAssertTrue(healthy)
        } catch { XCTFail("Healthy root/query was starved by duplicate blocked-root attempts: \(error)") }
        gates.forEach { $0.release() }
        let returnDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while probe.activeReads != 0 {
            guard ContinuousClock.now < returnDeadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        let recovered = try await probe.read(key: rootKey) { FileManager.default.fileExists(atPath: folder.path) }
        XCTAssertTrue(recovered, "Actual worker return permits later automatic root recovery")
    }

    @MainActor
    func testVisibleLibraryDiscoveryUsesPersistentBoundedOwners() async throws {
        let evidence = MacGameEvidenceStore()
        let minecraft = NativeMinecraft()
        let suite = "COR479-evidence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try CompatibilityResources.macGameEvidenceURL().path, forKey: "Xodus.evidence.triedGames")
        for probe in [evidence.storageProbe, minecraft.storageProbe] {
            let gates = (0..<4).map { _ in PackageInspectionInterleaving() }
            defer { gates.forEach { $0.release() } }
            let folder = FileManager.default.temporaryDirectory
            let workers = gates.map { gate in Task { try await probe.read { try gate.inspect(folder) } } }
            let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !gates.allSatisfy(\.isWaiting) {
                guard ContinuousClock.now < admissionDeadline else { throw GameStorageProbeError.timedOut }
                try await Task.sleep(for: .milliseconds(5))
            }
            workers.forEach { $0.cancel() }
            for worker in workers {
                do { _ = try await worker.value; XCTFail("Blocked waiter must cancel") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
            let refresh = Task {
                if probe === evidence.storageProbe { await evidence.refresh(defaults: defaults) }
                else { await minecraft.refresh() }
            }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(probe.activeReads, 4)
            refresh.cancel()
            await refresh.value
            XCTAssertEqual(probe.activeReads, 4)
            XCTAssertTrue(evidence.games.isEmpty)
            XCTAssertNil(evidence.errorMessage)
            XCTAssertEqual(minecraft.installation.state, .checking)
            XCTAssertNil(minecraft.errorMessage)
            gates.forEach { $0.release() }
            let returnDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while probe.activeReads != 0 {
                guard ContinuousClock.now < returnDeadline else { throw GameStorageProbeError.timedOut }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        await evidence.refresh(defaults: defaults)
        XCTAssertNil(evidence.errorMessage)
        XCTAssertFalse(evidence.games.isEmpty, "Actual bundled evidence first-load remains available")
        await minecraft.refresh()
        XCTAssertNotEqual(minecraft.installation.state, .checking,
                          "Actual read-only workspace discovery completes without a window or launcher action")
    }

    @MainActor
    func testCancelledAdmissionDoesNotStartStorageWork() async {
        let probe = GameStorageProbe()
        let work = Task {
            try await probe.read {
                XCTFail("Cancellation before admission must not start filesystem work")
                return true
            }
        }
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("Cancelled admission must propagate cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.activeReads, 0)
    }

    @MainActor
    func testStorageCancellationAndDeadlineReachRetainedWorker() async throws {
        let probe = GameStorageProbe()
        let folder = FileManager.default.temporaryDirectory
        for cancel in [true, false] {
            let gate = PackageInspectionInterleaving()
            defer { gate.release() }
            let work = Task {
                try await probe.read(timeout: cancel ? .seconds(2) : .milliseconds(200)) {
                    XCTAssertFalse(Thread.isMainThread)
                    let result = try gate.inspect(folder)
                    XCTAssertTrue(Task.isCancelled,
                                  "Released waiter must cancel its retained worker before late work continues")
                    return result
                }
            }
            let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !gate.isWaiting {
                guard ContinuousClock.now < admissionDeadline else { throw GameStorageProbeError.timedOut }
                try await Task.sleep(for: .milliseconds(5))
            }
            if cancel { work.cancel() }
            do {
                _ = try await work.value
                XCTFail("Cancellation or deadline must release the waiter")
            } catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? GameStorageProbeError, .timedOut) }
            }
            XCTAssertEqual(probe.activeReads, 1,
                           "The blocked worker remains admitted after its waiter returns")
            gate.release()
            let returnDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while probe.activeReads != 0 {
                guard ContinuousClock.now < returnDeadline else { throw GameStorageProbeError.timedOut }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @MainActor
    func testExistingNativeStatusFilesystemAndReceiptGuards() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/COR479-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Isolated status cleanup failed: \(error)") }
        }
        let controller = InstalledGamesController(
            store: InstalledGameStore(file: root.appendingPathComponent("installed.json", isDirectory: false)),
            mountedStorageRoots: { nil }, discoveryRoot: root, installLocation: { nil })
        await controller.load()
        try await NativeLifecycleChecks.installationStatusChecks(root: root, owner: controller.readinessProbe,
            observeOverlap: {
                controller.reconcilePendingDiscoveryRoots(volumes: nil)
                print("COR479 overlap: queryKeyLeaked=\(controller.pendingDiscoveryRoots.contains(root.appendingPathComponent("slow-complete", isDirectory: true).path)) activeWorkers=\(controller.readinessProbe.activeReads)")
                XCTAssertTrue(controller.pendingDiscoveryRoots.isEmpty,
                              "An overlapping native query is not an unresolved discovery root")
                XCTAssertTrue(controller.canCreateInstallation(productID: "FIXTURE00002"),
                              "Nil mount enumeration must not poison Download admission during or after query completion")
                XCTAssertTrue(controller.games.isEmpty)
                XCTAssertTrue(controller.launchableIDs.isEmpty, "No readiness or installed registration is fabricated")
            }) { condition, name in
            XCTAssertTrue(condition, name)
        }
        let configuration = BackendConfiguration(
            executable: root.appendingPathComponent("synthetic-install-status", isDirectory: false),
            stateDirectory: root.appendingPathComponent("manage", isDirectory: true))
        let queryOwner = GameStorageProbe()
        let admissionGates = (0..<4).map { _ in PackageInspectionInterleaving() }
        defer { admissionGates.forEach { $0.release() } }
        let blockedReads = admissionGates.map { gate in
            Task { try await queryOwner.read { try gate.inspect(root) } }
        }
        let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !admissionGates.allSatisfy(\.isWaiting) {
            guard ContinuousClock.now < admissionDeadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        blockedReads.forEach { $0.cancel() }
        for blocked in blockedReads {
            do { _ = try await blocked.value; XCTFail("Blocked owner cancellation must release its waiter") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        let freshQuery = NativeInstallationQuery(storageProbe: queryOwner)
        let waitingState = root.appendingPathComponent("status-admission", isDirectory: true)
        let waitingQuery = Task {
            try await freshQuery.run(configuration: configuration, product: "FIXTURE00001",
                gameDirectory: root.appendingPathComponent("complete", isDirectory: true),
                stateDirectory: waitingState)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(queryOwner.activeReads, 4)
        XCTAssertFalse(freshQuery.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: waitingState.path),
                       "A fresh native attempt cannot stage or launch a fifth worker")
        waitingQuery.cancel()
        do {
            _ = try await waitingQuery.value
            XCTFail("Cancelling before native admission must propagate cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(freshQuery.isRunning)
            XCTAssertEqual(queryOwner.activeReads, 4)
        }
        admissionGates.forEach { $0.release() }
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while queryOwner.activeReads != 0 {
            guard ContinuousClock.now < releaseDeadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        let rootGate = PackageInspectionInterleaving()
        defer { rootGate.release() }
        let rootKey = root.appendingPathComponent("blocked-root", isDirectory: true).path
        let rootRead = Task { try await queryOwner.read(key: rootKey) { try rootGate.inspect(root) } }
        let rootDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !rootGate.isWaiting {
            guard ContinuousClock.now < rootDeadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        rootRead.cancel()
        do { _ = try await rootRead.value; XCTFail("Blocked root waiter must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<3 {
            do {
                _ = try await queryOwner.read(key: rootKey) {
                    XCTFail("Duplicate root must not start another syscall")
                    return true
                }
            } catch { XCTAssertEqual(error as? GameStorageProbeError, .pending) }
        }
        let healthy = try await NativeInstallationQuery(storageProbe: queryOwner).run(
            configuration: configuration, product: "FIXTURE00001",
            gameDirectory: root.appendingPathComponent("complete", isDirectory: true),
            stateDirectory: root.appendingPathComponent("status-healthy-after-blocked-root", isDirectory: true))
        XCTAssertEqual(healthy.action, .play,
                       "The existing actual inspector/receipt scenario is not starved by repeated blocked-root discovery")
        XCTAssertEqual(queryOwner.activeReads, 1)
        rootGate.release()
        let rootReturnDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while queryOwner.activeReads != 0 {
            guard ContinuousClock.now < rootReturnDeadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    func testMountedRootConstructionDoesNotInferDirectoryFromFilesystem() {
        XCTAssertTrue(Thread.isMainThread)
        let missingMount = "/Volumes/COR479-\(UUID().uuidString)"
        let roots = GameInstallationDiscovery.mountedLibraryRoots([missingMount, missingMount])
        XCTAssertEqual(roots.map(\.path), [missingMount + "/Xodus"])
        XCTAssertTrue(roots.allSatisfy(\.hasDirectoryPath),
                      "Mounted directory URL hints must be explicit, never inferred with main-thread lstat")
    }

    @MainActor
    func testUnresolvedDownloadLocationShowsFeedbackWithoutConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("COR479-download-\(UUID().uuidString)")
        let suite = "COR479-download-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Isolated download store cleanup failed: \(error)") }
        }
        defaults.set("invalid location", forKey: GameInstallLocation.preferenceKey)
        let controller = InstalledGamesController(store: InstalledGameStore(file: root.appendingPathComponent("installed.json")),
                                                  discoveryRoot: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        await controller.load()
        let paths = GameScriptPaths(scripts: root.appendingPathComponent("scripts"),
            processed: root.appendingPathComponent("processed"), logs: root.appendingPathComponent("logs"),
            games: root.appendingPathComponent("games"), journal: root.appendingPathComponent("operation.json"))
        let operations = GameOperationsController(installed: controller, paths: paths, installLocationDefaults: defaults)
        let game = PCGame(id: "9N9C8SV0S16W", title: "Readiness transition", artwork: nil)
        let action = GameInstallAction(game: game, operations: operations)
        XCTAssertTrue(action.canInstall)
        XCTAssertTrue(operations.installationCheckRequired(for: game))
        await action.requestInstall()
        XCTAssertNil(operations.installConsent)
        XCTAssertNil(operations.operation)
        XCTAssertNotNil(operations.error)
        let feedback = GameOperationProgressView(operations: operations, productID: game.id)
        XCTAssertEqual(feedback.failureMessage, "This game couldn't be downloaded.")
        XCTAssertNotNil(ImageRenderer(content: feedback.fixedSize()).cgImage)
    }

    @MainActor
    func testDisconnectedServiceRetriesReadinessThroughExistingBackgroundLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("COR479-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Isolated store cleanup failed: \(error)") }
        }
        let game = InstalledGame(id: UUID(), title: "Readiness transition", identityName: "Readiness",
            version: "1", storeId: "9N9C8SV0S16W", folder: root.path, launcher: "",
            importedAt: .distantPast, usesNativeLifecycle: true)
        let store = InstalledGameStore(file: root.appendingPathComponent("installed.json"))
        try await store.save([game])
        let controller = InstalledGamesController(store: store)
        await controller.load()
        XCTAssertTrue(controller.nativeInspectionIsDue(game))
        await controller.refreshNativeInstallationStatuses()
        XCTAssertNotNil(controller.installationErrors[game.id])
        XCTAssertNil(controller.installationStatuses[game.id])
        XCTAssertFalse(controller.nativeInspectionIsDue(game))
        XCTAssertTrue(controller.nativeInspectionIsDue(game, at: .now.advanced(by: .seconds(16))))
    }

    @MainActor
    func testLegacyPresenceFailureRecoversAutomaticallyWithoutTokenRead() async {
        let store = PCGamesMockStore()
        await store.failPresence(at: 0)
        let transport = PCGamesMockTransport([])
        let library = PCGamesController(store: store, client: PCGamesClient(transport: transport))
        await library.restorePresence()
        XCTAssertTrue(library.presenceUnavailable)
        await library.refreshInBackground()
        XCTAssertFalse(library.presenceUnavailable)
        XCTAssertFalse(library.hasSavedSignIn)
        let reads = await store.reads
        let deletions = await store.deletions
        let requests = await transport.requests
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(deletions, 0)
        XCTAssertTrue(requests.isEmpty)
        let savedStore = PCGamesMockStore("neutral-preserved-sign-in")
        await savedStore.failPresence(at: 0)
        let savedTransport = PCGamesMockTransport([])
        let savedLibrary = PCGamesController(store: savedStore, client: PCGamesClient(transport: savedTransport))
        await savedLibrary.restorePresence()
        XCTAssertTrue(savedLibrary.presenceUnavailable)
        let presenceReads = await savedStore.reads
        XCTAssertEqual(presenceReads, 0)
        await savedLibrary.refreshInBackground()
        await savedLibrary.waitForOperation()
        XCTAssertFalse(savedLibrary.presenceUnavailable)
        XCTAssertTrue(savedLibrary.hasSavedSignIn)
        let collectionReads = await savedStore.reads
        let collectionRequests = await savedTransport.requests
        let savedDeletions = await savedStore.deletions
        XCTAssertEqual(collectionReads, 1, "Recovered saved sign-in continues the existing collection load")
        XCTAssertEqual(collectionRequests.count, 1)
        XCTAssertEqual(savedDeletions, 0)
        XCTAssertNotNil(savedLibrary.error, "Existing empty transport reports load failure, never fabricated success")
        await savedLibrary.refreshInBackground()
        let repeatedReads = await savedStore.reads
        XCTAssertEqual(repeatedReads, 1)
    }

    @MainActor
    func testPlayFailureRendersPlainFeedbackWithoutLaunching() async {
        let controller = InstalledGamesController()
        let game = InstalledGame(id: UUID(), title: "Readiness transition", identityName: "", version: "",
            storeId: "9N9C8SV0S16W", folder: "", launcher: "", importedAt: .distantPast)
        await controller.play(game)
        XCTAssertNotNil(controller.playErrors[game.id])
        let host = NSHostingView(rootView: InstalledPlayError(library: controller, game: game).fixedSize())
        XCTAssertNil(host.window)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertNil(controller.runningGameID)
        XCTAssertNotNil(ImageRenderer(content: InstalledPlayError(library: controller, game: game)
            .fixedSize()).cgImage)
        XCTAssertEqual(InstalledPlayError(library: controller, game: game).message, "Sign in to play this game.")
    }

    @MainActor
    func testUnknownReadinessFailureRendersExplanationWithoutUnsafeAction() {
        let controller = InstalledGamesController()
        let game = InstalledGame(id: UUID(), title: "Readiness transition", identityName: "", version: "",
            storeId: "9N9C8SV0S16W", folder: "", launcher: "", importedAt: .distantPast,
            usesNativeLifecycle: true)
        controller.recordNativeInspectionFailure(game.id, background: true, message: "Drive check timed out")
        let button = InstalledPlayButton(library: controller,
            operations: GameOperationsController(installed: controller), game: game)
        XCTAssertNil(controller.installationStatuses[game.id])
        XCTAssertFalse(controller.launchableIDs.contains(game.id))
        XCTAssertEqual(button.nativeActionTitle, "")
        XCTAssertEqual(button.unavailableMessage,
                       "This game can't play right now.")
        let host = NSHostingView(rootView: button.fixedSize())
        XCTAssertNil(host.window)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertTrue(controller.nativeInspectionIsDue(game))
        XCTAssertNotNil(ImageRenderer(content: InstalledPlayError(library: controller, game: game)
            .fixedSize()).cgImage)
    }

    @MainActor
    func testConcurrentStorageReadDoesNotRejectHealthyFolder() async throws {
        let probe = GameStorageProbe()
        let folder = FileManager.default.temporaryDirectory
        let gate = PackageInspectionInterleaving()
        defer { gate.release() }
        let first = Task { try await probe.read { try gate.inspect(folder) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.isWaiting {
            guard ContinuousClock.now < deadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = Task { try await probe.read {
            FileManager.default.fileExists(atPath: folder.path)
        } }
        do {
            let healthy = try await second.value
            XCTAssertTrue(healthy)
        } catch {
            gate.release()
            _ = try await first.value
            throw error
        }
        gate.release()
        _ = try await first.value
    }

    @MainActor
    func testBlockedStorageWorkersRemainBoundedUntilActualReturn() async throws {
        let probe = GameStorageProbe()
        let folder = FileManager.default.temporaryDirectory
        let gates = (0..<4).map { _ in PackageInspectionInterleaving() }
        defer { gates.forEach { $0.release() } }
        let workers = gates.map { gate in
            Task { try await probe.read { try gate.inspect(folder) } }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gates.allSatisfy(\.isWaiting) {
            guard ContinuousClock.now < deadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        workers.forEach { $0.cancel() }
        for worker in workers {
            do {
                _ = try await worker.value
                XCTFail("Cancellation must release the waiter")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
        XCTAssertEqual(probe.activeReads, 4)
        do {
            _ = try await probe.read(timeout: .milliseconds(20)) {
                FileManager.default.fileExists(atPath: folder.path)
            }
            XCTFail("A fifth syscall must not exceed the worker bound")
        } catch {
            XCTAssertEqual(error as? GameStorageProbeError, .timedOut)
        }
        XCTAssertEqual(probe.activeReads, 4)
        gates.forEach { $0.release() }
        while probe.activeReads != 0 {
            guard ContinuousClock.now < deadline else { throw GameStorageProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        let healthy = try await probe.read { FileManager.default.fileExists(atPath: folder.path) }
        XCTAssertTrue(healthy)
    }

    @MainActor
    func testBackgroundFailurePreservesVerifiedReadinessButAuthoritativeChangesApply() {
        let controller = InstalledGamesController()
        let game = InstalledGame(id: UUID(), title: "Readiness transition", identityName: "", version: "",
            storeId: "9N9C8SV0S16W", folder: "", launcher: "", importedAt: .distantPast)
        func result(success: Bool, status: NativeInstallationStatus.Status?) -> NativeInstallationStatus {
            NativeInstallationStatus(version: 1, operation: "install-status", product: game.storeId,
                runID: UUID().uuidString, gameDirectory: game.folder, logDirectory: "", resultPath: "",
                success: success, exitCode: success ? 0 : 1, errorCode: success ? nil : "RESOURCE_BUSY",
                status: status, reasonCode: nil, detail: nil, filesTotal: nil, contentID: nil)
        }
        let complete = result(success: true, status: .complete)
        controller.recordNativeInspectionResult(complete, for: game, background: true)
        XCTAssertEqual(controller.installationStatuses[game.id], complete)
        let eligible = controller.launchableIDs.contains(game.id)
        let button = InstalledPlayButton(library: controller,
            operations: GameOperationsController(installed: controller), game: game)
        XCTAssertEqual(button.nativeActionTitle, "Play")
        let initialSize = NSHostingView(rootView: button.fixedSize()).fittingSize
        controller.recordNativeInspectionFailure(game.id, background: true, message: "Drive check timed out")
        XCTAssertNil(button.readinessDiagnostic)
        XCTAssertEqual(button.nativeActionTitle, "Play")
        XCTAssertEqual(NSHostingView(rootView: button.fixedSize()).fittingSize, initialSize)
        XCTAssertEqual(controller.installationStatuses[game.id], complete)
        XCTAssertEqual(controller.launchableIDs.contains(game.id), eligible)
        XCTAssertEqual(controller.installationErrors[game.id], "Drive check timed out")
        controller.recordNativeInspectionResult(result(success: false, status: nil), for: game, background: true)
        XCTAssertEqual(controller.installationStatuses[game.id], complete)
        XCTAssertEqual(controller.launchableIDs.contains(game.id), eligible)
        XCTAssertFalse(controller.checkingInstallations.contains(game.id))
        controller.recordNativeInspectionResult(result(success: true, status: .partial), for: game, background: true)
        XCTAssertEqual(controller.installationStatuses[game.id]?.action, .resume)
        XCTAssertEqual(button.nativeActionTitle, "Download")
        XCTAssertFalse(controller.launchableIDs.contains(game.id))
        controller.recordNativeInspectionResult(complete, for: game, background: true)
        controller.recordNativeInspectionResult(result(success: true, status: .missing), for: game, background: true)
        XCTAssertEqual(controller.installationStatuses[game.id]?.action, .install)
        XCTAssertEqual(button.nativeActionTitle, "Download")
        controller.recordNativeInspectionResult(complete, for: game, background: true)
        controller.recordNativeInspectionFailure(game.id, background: false, message: "Explicit check failed")
        XCTAssertNil(controller.installationStatuses[game.id])
        XCTAssertEqual(button.nativeActionTitle, "")
        XCTAssertFalse(controller.launchableIDs.contains(game.id))
    }

    @MainActor
    func testBackgroundDiscoveryAndStorageGuards() async throws {
        try await InstalledGameChecks.storageLocationChecks { condition, name in
            XCTAssertTrue(condition, name)
        }
    }
}
