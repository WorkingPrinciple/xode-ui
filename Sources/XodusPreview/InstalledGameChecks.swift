// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import Foundation
import ImageIO
import SwiftUI
import Vision
import XodusCore

@MainActor
enum InstalledGameChecks {
    static func discoveryIsolationChecks(check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/DiscoveryIsolation-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "REQ106: Isolation fixture is cleaned") }
        }
        let local = root.appendingPathComponent("local/game")
        let remote = root.appendingPathComponent("remote/game")
        for (folder, product) in [(local, "FIXTURE00001"), (remote, "9NR1R1XWLCNB"),
                                 (root.appendingPathComponent("remote/second"), "FIXTURE00002"),
                                 (root.appendingPathComponent("remote/third"), "FIXTURE00003")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("<Game><Identity Name=\"Fixture\" Version=\"1.0.0.0\"/><StoreId>\(product)</StoreId></Game>".utf8)
                .write(to: folder.appendingPathComponent("MicrosoftGame.config"))
        }
        let launcher = root.appendingPathComponent("local/launch.sh")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let game = InstalledGame(id: UUID(), title: "Local", identityName: "Fixture", version: "1.0.0.0",
            storeId: "FIXTURE00001", folder: local.path, launcher: launcher.path, importedAt: Date())
        let store = InstalledGameStore(file: root.appendingPathComponent("registry/games.json"))
        try await store.save([game])
        let completeness = DiscoveryCompletenessFixture()
        let controller = InstalledGamesController(store: store, inspectPackage: { _ in .win32 },
            mountedStorageRoots: { [] }, discoveryRoot: remote.deletingLastPathComponent(),
            installLocation: { nil }, discoveryCompleteness: { _, _ in
                try await completeness.check()
            })
        await controller.load()
        check(controller.launchableIDs.contains(game.id), "REQ106: Local fixture starts with verified launch readiness")
        completeness.slow = true
        let scan = Task { await controller.discoverNativeInstallations(root: remote.deletingLastPathComponent()) }
        try await Task.sleep(for: .milliseconds(100))
        check(controller.discoveringInstallations && !controller.editing
              && controller.launchableIDs.contains(game.id) && !controller.mutationActive,
              "REQ106: Pending slow NFS discovery never takes global editing or local launch readiness")
        scan.cancel()
        await scan.value
        completeness.slow = false
        completeness.timeout = true
        await controller.verifyDiscoveredInstallation(productID: "9NR1R1XWLCNB")
        check(controller.launchableIDs.contains(game.id) && !controller.editing
              && !controller.verifyingDiscoveredProducts.contains("9NR1R1XWLCNB"),
              "REQ106: Candidate verification timeout leaves other games launchable and clears only its busy state")
        let operations = GameOperationsController(installed: controller)
        let candidate = PCGame(id: "9NR1R1XWLCNB", title: "Forza Horizon 6", artwork: nil)
        check(GameInstallAction(game: candidate, operations: operations).actionTitle == "Retry"
              && !controller.canCreateInstallation(productID: candidate.id),
              "REQ106: Timed-out NFS verification stays Check installation and never offers a duplicate Install")
        check(controller.discoveryError == nil
              && controller.discoveredVerificationErrors[candidate.id] != nil
              && controller.discoveredVerificationErrors["FIXTURE00002"] == nil,
              "REQ106: An explicit failed check reports only on its own product, never an automatic-discovery banner")
        completeness.timeout = false
        completeness.slow = true
        let first = Task { await controller.automaticallyVerifyDiscoveredInstallation(productID: candidate.id) }
        let coalesced = Task { await controller.automaticallyVerifyDiscoveredInstallation(productID: candidate.id) }
        let second = Task { await controller.verifyDiscoveredInstallation(productID: "FIXTURE00002") }
        let verificationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.verifyingDiscoveredProducts.count < 2 && ContinuousClock.now < verificationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await controller.verifyDiscoveredInstallation(productID: "FIXTURE00003")
        check(controller.verifyingDiscoveredProducts.count == 2 && !controller.editing
              && controller.launchableIDs.contains(game.id),
              "REQ106: Candidate verification admits at most two cancellable workers without locking local Play")
        controller.cancelDiscoveredVerification(productID: candidate.id)
        controller.cancelDiscoveredVerification(productID: "FIXTURE00002")
        await first.value
        await coalesced.value
        await second.value
        check(controller.verifyingDiscoveredProducts.isEmpty && controller.automaticDiscoveryProducts.isEmpty
              && controller.discoveredVerificationErrors[candidate.id]?.contains("cancelled") == true,
              "COR169: Coalesced automatic checks cancel only their product and retain a neutral cancelled reason for explicit Retry")
        let slowGame = InstalledGame(id: UUID(), title: "Slow drive", identityName: "Fixture", version: "1.0.0.0",
            storeId: candidate.id, folder: remote.path, launcher: launcher.path, importedAt: Date())
        let isolatedStore = InstalledGameStore(file: root.appendingPathComponent("independent/games.json"))
        try await isolatedStore.save([slowGame, game])
        let gate = PackageInspectionInterleaving()
        defer { gate.release() }
        let isolated = InstalledGamesController(store: isolatedStore, inspectPackage: { folder in
            if folder.path == remote.path { return try gate.inspect(folder) }
            return .win32
        }, mountedStorageRoots: { [] })
        let loading = Task { await isolated.load() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.isWaiting || !isolated.launchableIDs.contains(game.id) {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(gate.isWaiting && isolated.launchableIDs.contains(game.id) && !isolated.editing,
              "REQ106: A slow per-game probe publishes local Play independently before the slow probe returns (waiting \(gate.isWaiting), local \(isolated.launchableIDs.contains(game.id)), errors \(isolated.packageErrors.count))")
        await loading.value
        check(isolated.launchableIDs.contains(game.id) && isolated.packageErrors[game.id] == nil,
              "REQ106: A readiness probe timeout preserves every other game's launchability")
        func tileHeight() -> CGFloat {
            let tile = PCGameTile(game: PCGame(id: game.storeId, title: game.title, artwork: nil),
                installed: isolated, operations: GameOperationsController(installed: isolated),
                allowsArtworkLoading: false, viewDetails: {})
            let host = NSHostingView(rootView: tile.frame(width: 220))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let readyHeight = tileHeight()
        let nested = local.appendingPathComponent("Binaries/game.exe")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nested fixture".utf8).write(to: nested)
        var knownGame = game
        knownGame.packageType = .msixvc
        let knownStore = InstalledGameStore(file: root.appendingPathComponent("known/games.json"))
        try await knownStore.save([knownGame])
        let unknownObservation = InstalledGamesController(store: knownStore)
        await unknownObservation.load()
        let retainedClassification = try await knownStore.load().first?.packageType
        check(try PackageInspector.detect(folder: local) == .unknown
              && unknownObservation.games.first?.packageType == .msixvc && retainedClassification == .msixvc,
              "M3: Missing root-level evidence with a nested executable never overwrites known MSIXVC classification")
        let positive = try await knownStore.recordPackageType(id: knownGame.id, type: .win32)
        check(positive.first?.packageType == .win32,
              "M3: Positive new package classification still replaces an older known classification")
        let nativeGame = InstalledGame(id: UUID(), title: game.title, identityName: game.identityName,
            version: game.version, storeId: game.storeId, folder: game.folder, launcher: "",
            importedAt: Date(), usesNativeLifecycle: true)
        let automaticStore = InstalledGameStore(file: root.appendingPathComponent("automatic/games.json"))
        try await automaticStore.save([nativeGame])
        let automatic = InstalledGamesController(store: automaticStore, inspectPackage: { _ in .win32 },
            mountedStorageRoots: { [] })
        await automatic.load()
        guard let admittedNative = automatic.games.first else {
            check(false, "COR170: Automatic readiness fixture must load its registered game")
            return
        }
        await automatic.automaticallyCheckInstallation(admittedNative)
        let serviceFailure = automatic.installationErrors[nativeGame.id]
        await automatic.automaticallyCheckInstallation(admittedNative)
        check(serviceFailure?.contains("service") == true
              && automatic.installationErrors[nativeGame.id] == serviceFailure
              && automatic.installationStatuses[nativeGame.id] == nil
              && InstalledPlayButton(library: automatic, operations: GameOperationsController(installed: automatic),
                  game: nativeGame).nativeActionTitle == "Retry",
              "COR170: Registered entry automatically verifies and retains a concrete disconnected-service Retry, never unsafe Play (service \(serviceFailure ?? "nil"), package \(automatic.packageErrors[nativeGame.id] ?? "nil"))")
        for (status, reason, title) in [
            (NativeInstallationStatus.Status.missing, "CONTENT_MISSING", "Download"),
            (.partial, "CONTENT_INCOMPLETE", GameDownloadCopy.downloadAgain),
            (.partial, "MANIFEST_INVALID", "Repair")
        ] {
            try automatic.recordInstallationStatus(NativeInstallationStatus(version: 1, operation: "install-status",
                product: admittedNative.storeId, runID: UUID().uuidString, gameDirectory: admittedNative.folder,
                logDirectory: "/fixture", resultPath: "/fixture/result.json", success: true, exitCode: 0,
                errorCode: nil, status: status, reasonCode: reason, detail: "Fixture requires \(title.lowercased()).",
                filesTotal: nil, contentID: nil), for: admittedNative)
            let primary = InstalledPlayButton(library: automatic,
                operations: GameOperationsController(installed: automatic), game: admittedNative)
            check(primary.nativeActionTitle == title && !primary.ownsInstallationCheck
                  && InstalledGameAttentionView(installed: automatic,
                      operations: GameOperationsController(installed: automatic), game: admittedNative,
                      installationCheckInHeader: primary.ownsInstallationCheck, close: {}).offersInstallationCheck,
                  "COR171 M1: \(title) names its real consent action and leaves read-only Retry available in the attention panel")
        }
        let cancelledGame = InstalledGame(id: UUID(), title: "Cancelled mounted fixture", identityName: "Fixture",
            version: "1", storeId: "FIXTURE00002", folder: "/Volumes/REQ106Cancelled/game", launcher: "",
            importedAt: Date(), usesNativeLifecycle: true)
        let cancelledStore = InstalledGameStore(file: root.appendingPathComponent("cancelled/games.json"))
        try await cancelledStore.save([cancelledGame])
        let cancellationGate = PackageInspectionInterleaving()
        defer { cancellationGate.release() }
        let cancelled = InstalledGamesController(store: cancelledStore,
            inspectPackage: { try cancellationGate.inspect($0) }, mountedStorageRoots: { [] })
        await cancelled.load()
        guard let cancelledEntry = cancelled.games.first else {
            check(false, "COR171 H1: Mounted cancellation fixture must load")
            return
        }
        let automaticCheck = Task { await cancelled.automaticallyCheckInstallation(cancelledEntry) }
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !cancellationGate.isWaiting, ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(cancellationGate.isWaiting && cancelled.checkingInstallations.contains(cancelledEntry.id),
              "COR171 H1: Mounted visible-entry verification is running before simulated view cancellation")
        automaticCheck.cancel()
        cancellationGate.release()
        await automaticCheck.value
        await cancelled.automaticallyCheckInstallation(cancelledEntry)
        check(cancelled.installationStatuses[cancelledEntry.id] == nil
              && cancelled.installationErrors[cancelledEntry.id]?.contains("cancelled") == true
              && !cancelled.checkingInstallations.contains(cancelledEntry.id)
              && InstalledPlayButton(library: cancelled, operations: GameOperationsController(installed: cancelled),
                  game: cancelledEntry).nativeActionTitle == "Retry",
              "COR171 H1: Cancelled mounted view re-entry retains an explained Retry, never an idle Checking spinner")
        try cancelled.reserveMutation(gameID: nil)
        check(InstalledPlayButton(library: cancelled, operations: GameOperationsController(installed: cancelled),
            game: cancelledEntry).nativeReadinessUnavailableReason?.contains("operation") == true,
              "COR171: A mutation-blocked readiness Retry is explicitly disabled with an operation-wait reason, not a no-op")
        cancelled.releaseMutation()
        try FileManager.default.removeItem(at: local)
        await isolated.checkInstallation(game)
        check(isolated.packageErrors[game.id] == InstalledGameError.missingFolder.localizedDescription
              && !isolated.launchableIDs.contains(game.id) && tileHeight() == readyHeight,
              "COR156: Missing-folder truth disables unsafe Play without adding diagnostic text or icons to catalogue card layout")
        check(InstalledGameFiles.folderReadError(NSError(domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError)) == .folderPermission
              && InstalledGameFiles.folderReadError(NSError(domain: NSPOSIXErrorDomain,
                  code: Int(ETIMEDOUT))) == .folderUnavailable
              && InstalledGameFiles.folderReadError(NSError(domain: NSPOSIXErrorDomain,
                  code: Int(ENOENT))) == .missingFolder,
              "COR156: Permission and timeout errors remain unverified, never mislabeled as a missing folder")
        let warning = NSHostingView(rootView: InstallationWarning(message: InstalledGameError.missingFolder.localizedDescription))
        warning.layoutSubtreeIfNeeded()
        check(warning.fittingSize.height > 0 && warning.fittingSize.height <= 24,
              "COR156: Detail recovery uses a compact warning with help and accessible label, not an inline paragraph")
        let mountedGame = InstalledGame(id: UUID(), title: "Large mounted fixture", identityName: "Fixture",
            version: "1.0.0.0", storeId: "9NR1R1XWLCNB", folder: "/Volumes/REQ106Fixture/FH6",
            launcher: "", importedAt: Date(), usesNativeLifecycle: true,
            storageVolume: GameStorageVolume(path: "/Volumes/REQ106Fixture"))
        let mountedStore = InstalledGameStore(file: root.appendingPathComponent("mounted/games.json"))
        try await mountedStore.save([mountedGame])
        let mounted = InstalledGamesController(store: mountedStore, mountedStorageRoots: { [] })
        await mounted.load()
        let offline = InstalledGamesController(store: mountedStore, mountedStorageRoots: { [] })
        await offline.load()
        await offline.checkInstallation(mountedGame)
        let offlinePanel = InstalledGameAttentionView(installed: offline,
            operations: GameOperationsController(installed: offline), game: mountedGame, close: {})
        let offlineHost = NSHostingView(rootView: offlinePanel.padding(20).frame(width: 560, height: 420)
            .background(Color.white).environment(\.colorScheme, .light))
        offlineHost.frame = CGRect(x: 0, y: 0, width: 560, height: 420)
        offlineHost.layoutSubtreeIfNeeded()
        if let bitmap = offlineHost.bitmapImageRepForCachingDisplay(in: offlineHost.bounds) {
            offlineHost.cacheDisplay(in: offlineHost.bounds, to: bitmap)
            if let image = bitmap.cgImage {
                let text = try NativeCheckOCR.recognize(image).joined(separator: " ")
                check(text.contains("drive is unavailable") && text.contains("Reconnect the drive")
                      && text.contains("Retry") && text.contains(mountedGame.folder),
                      "COR177: Mounted attention visibly explains the disconnected drive with recovery and the retained location, without hover: \(text)")
            } else { check(false, "COR177: Attention panel capture contains rendered pixels") }
        } else { check(false, "COR177: Attention panel supports a mounted render capture") }
        let status = NativeInstallationStatus(version: 1, operation: "install-status", product: mountedGame.storeId,
            runID: UUID().uuidString, gameDirectory: mountedGame.folder, logDirectory: "/fixture",
            resultPath: "/fixture/result.json", success: true, exitCode: 0, errorCode: nil, status: .complete,
            reasonCode: nil, detail: nil, filesTotal: 1, contentID: nil)
        try mounted.recordInstallationStatus(status, for: mountedGame)
        check(mounted.hasFreshCompleteInstallation(mountedGame)
              && mounted.installationStatuses[mountedGame.id]?.action == .play
              && mounted.launchableIDs.contains(mountedGame.id),
              "REQ106: Verified mounted completeness publishes fresh Play immediately without waiting for skipped bulk inspection")
        check(InstalledPlayButton(library: mounted, operations: GameOperationsController(installed: mounted),
            game: mountedGame).nativeActionTitle == "Play",
              "COR170: A verified complete installed game presents Play, never routine readiness bookkeeping")
        let accessSession = LiveSession()
        mounted.useUnifiedAccount(accessSession)
        mounted.setAccountAccessAllowed(true)
        let accessAttention = InstalledGameAttentionView(installed: mounted,
            operations: GameOperationsController(installed: mounted), game: mountedGame, close: {})
        let namedPrimary = InstalledPlayButton(library: mounted, operations: GameOperationsController(installed: mounted),
            game: mountedGame, displayTitle: "Current catalog title")
        check(mounted.accountAccessAllowed && !mounted.canRequestPlay(mountedGame.storeId)
              && mounted.productAccessNotice(for: mountedGame) != nil && accessAttention.needsAttention
              && namedPrimary.actionGameTitle == "Current catalog title"
              && mountedGame.title == "Large mounted fixture",
              "COR171 native: Global account admission never hides exact-product access failure; catalog action naming preserves authoritative config")
        for primary in [
            InstalledPlayButton(library: mounted, operations: GameOperationsController(installed: mounted),
                game: mountedGame, displayTitle: "Current catalog title", usesGlass: true, heroStyle: true),
            InstalledPlayButton(library: mounted, operations: GameOperationsController(installed: mounted),
                game: mountedGame, displayTitle: "Current catalog title", usesGlass: true, prominent: false)
        ] {
            check(primary.actionGameTitle == namedPrimary.actionGameTitle
                  && primary.game.storeId == mountedGame.storeId && primary.game.title == mountedGame.title,
                  "COR171: Hero and card primary action titles agree with detail without changing installed product/config identity")
        }
        mounted.setAccountAccessAllowed(false, message: "Account identity changed.")
        check(!mounted.canRequestPlay(mountedGame.storeId) && accessAttention.needsAttention
              && mounted.accountAccessMessage == "Account identity changed.",
              "COR171 native: Product access recovery never bypasses a global account mismatch")
        check(InstalledGamesController.inspectionTimeout(for: mountedGame) == .seconds(900)
              && InstalledGamesController.inspectionTimeout(for: game, explicitCheck: true) == .seconds(900)
              && InstalledGamesController.inspectionTimeout(for: game) == .seconds(120),
              "REQ106: Necessary mounted launch checks and explicit checks retain the large-install budget, never the 120-second background limit")
        check(!InstalledGamesController.permitsNativeInspection(activeChecks: 2, preparingLaunch: false)
              && InstalledGamesController.permitsNativeInspection(activeChecks: 2, preparingLaunch: true),
              "REQ106: Two background checks cannot consume the separate single foreground launch inspection slot")
        await mounted.checkInstallation(mountedGame)
        let missingStatus = NativeInstallationStatus(version: 1, operation: "install-status", product: mountedGame.storeId,
            runID: UUID().uuidString, gameDirectory: mountedGame.folder, logDirectory: "/fixture",
            resultPath: "/fixture/result.json", success: true, exitCode: 0, errorCode: nil, status: .missing,
            reasonCode: nil, detail: nil, filesTotal: nil, contentID: nil)
        try mounted.recordInstallationStatus(missingStatus, for: mountedGame)
        check(InstalledPlayButton(library: mounted, operations: GameOperationsController(installed: mounted),
                  game: mountedGame).nativeActionTitle == "Retry"
              && InstalledGameAttentionView(installed: mounted, operations: GameOperationsController(installed: mounted),
                  game: mountedGame, close: {}).needsAttention,
              "Detail: A registered unavailable folder keeps recovery instead of contradictory Install in the header")
        let recoveryOperations = GameOperationsController(installed: mounted)
        let header = InstalledPlayButton(library: mounted, operations: recoveryOperations, game: mountedGame)
        let attention = InstalledGameAttentionView(installed: mounted, operations: recoveryOperations,
            game: mountedGame, installationCheckInHeader: header.ownsInstallationCheck, close: {})
        check((header.ownsInstallationCheck ? 1 : 0) + (attention.offersInstallationCheck ? 1 : 0) == 1
              && attention.needsAttention && !attention.offersInstallationCheck,
              "Detail: Header-owned recovery renders exactly one installation check while keeping the body warning and location")
        check(InstalledGameAttentionView(installed: mounted, operations: recoveryOperations,
            game: mountedGame, close: {}).offersInstallationCheck,
              "Detail: A standalone attention panel retains its check when no header owns recovery")
    }

    static func descriptionChecks(check: (Bool, String) -> Void) {
        let fixtures: [(String, String, String)] = [
            ("First sentence. Still the same paragraph.\n\nSecond paragraph.",
             "First sentence. Still the same paragraph.", "Second paragraph."),
            ("First sentence wraps\nonto another line.\nFEATURES\nExplore the world.",
             "First sentence wraps\nonto another line.", "FEATURES\nExplore the world."),
            ("Explore Mexico.\n- Race together\n- Collect cars",
             "Explore Mexico.", "- Race together\n- Collect cars"),
            ("Explore Mexico.\n• Race together\n• Collect cars",
             "Explore Mexico.", "• Race together\n• Collect cars"),
            ("Explore Mexico.\n1. Race together\n2. Collect cars",
             "Explore Mexico.", "1. Race together\n2. Collect cars"),
            ("WELCOME\nA complete first paragraph.\n\nMORE\nAnother paragraph.",
             "WELCOME\nA complete first paragraph.", "MORE\nAnother paragraph."),
            ("A short description.", "A short description.", ""),
            ("- First item\n- Second item\n\nA later paragraph.",
             "- First item\n- Second item", "A later paragraph."),
            ("", "", ""),
            (" \r\nFirst complete paragraph.\r\n\r\nSecond paragraph.\r\n ",
             "First complete paragraph.", "Second paragraph."),
            ("An abbreviation e.g. a title has no forced character or sentence cutoff.",
             "An abbreviation e.g. a title has no forced character or sentence cutoff.", "")
        ]
        for (index, fixture) in fixtures.enumerated() {
            let result = GameDescriptionParagraphs(fixture.0)
            check(result.first == fixture.1 && result.remaining == fixture.2,
                  "REQ105: First-paragraph fixture \(index) preserves complete text and separates only structural boundaries")
        }
    }

    static func externalDiscoveryChecks(check: (Bool, String) -> Void) async throws {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Use default (Calimocho 11.20)", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
        check(InstalledGameActions.containsEngineMenu(menu, defaultTitle: "Use default (Calimocho 11.20)"),
              "REQ95: Root Actions menu tracking finds its nested Engine submenu for retry")
        check(InstalledGamesController.engineInspectionNames(all: ["ready", "failed"], failed: ["failed"],
              checked: true, force: false) == ["failed"]
              && InstalledGamesController.engineInspectionNames(all: ["ready", "failed"], failed: ["failed"],
              checked: true, force: true) == ["ready", "failed"],
              "REQ95: Menu retry inspects only failures while explicit refresh can revalidate every binding")
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ExternalDiscovery-\(UUID().uuidString)")
        let volume = home.appendingPathComponent("Mounts/homelab")
        let library = volume.appendingPathComponent("Xodus")
        let folder = library.appendingPathComponent("ForzaHorizon6-Xbox")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: home) }
            catch { check(false, "REQ106: Synthetic external library is cleaned") }
        }
        try Data("""
            <Game><Identity Name="Microsoft.ForteBaseGame" Version="3.461.691.0"/>
            <StoreId>9NR1R1XWLCNB</StoreId></Game>
            """.utf8).write(to: folder.appendingPathComponent("MicrosoftGame.Config"))
        let roots = GameInstallationDiscovery.mountedLibraryRoots(
            [volume.path, volume.path, "/", home.appendingPathComponent("Mounts/deep/nested").path],
            home: home.path)
        check(roots.map(\.path) == [volume.appendingPathComponent("Xode").path, library.path],
              "COR180: Mounted discovery checks new Xode then legacy Xodus, deduplicated/depth-one without guessed absent mounts")
        check(GameInstallationDiscovery.defaultLibraryRoots(home: home.path).map(\.path)
                == [home.appendingPathComponent("Games/Xode").path, home.appendingPathComponent("Games/Xodus").path],
              "COR180: Default local discovery retains the legacy root without moving or recreating it")
        check(InstalledGamesController.retainingMountedCandidates([folder.path: "9NR1R1XWLCNB"],
              volumes: [], home: home.path).isEmpty,
              "REQ106: Unmounted library candidates retire rather than blocking installation forever")
        check(!InstalledGamesController.permitsInstallation(productID: "9NR1R1XWLCNB", destination: nil,
              candidates: [:], pendingRoots: [library.path]),
              "REQ106: A timed-out or pending mount scan blocks blind Install even before product identity returns")
        check(InstalledGamesController.permitsInstallation(productID: "FIXTURE00001",
                  destination: home.appendingPathComponent("local/game").path,
                  candidates: [:], pendingRoots: [library.path])
              && !InstalledGamesController.permitsInstallation(productID: "FIXTURE00001",
                  destination: folder.path, candidates: [:], pendingRoots: [library.path])
              && !InstalledGamesController.permitsInstallation(productID: "9NR1R1XWLCNB",
                  destination: home.appendingPathComponent("local/game").path,
                  candidates: [folder.path: "9NR1R1XWLCNB"], pendingRoots: [library.path]),
              "COR161: Pending external roots gate only their destination while known same-product candidates still prevent duplication")
        check(GameInstallationDiscovery.mountedLibraryRoots([], home: home.path).isEmpty,
              "REQ106: Unmounted volumes are never guessed or auto-mounted for discovery")
        guard let discoveredRoot = roots.last else { return }
        let observed = try await GameStorageProbe().read {
            try GameInstallationDiscovery.scan(originalRoot: discoveredRoot, location: nil, entries: [],
                mountedRoots: [volume.path], inspectPackage: { _ in .msixvc })
        }
        check(observed.candidates.count == 1 && observed.candidates.first?.config.storeId == "9NR1R1XWLCNB",
              "REQ106: NFS-style MicrosoftGame.Config casing reaches exact product identity discovery")
        let refused = try await GameStorageProbe().read {
            try GameInstallationDiscovery.scan(originalRoot: library, location: nil, entries: [],
                mountedRoots: [volume.path], inspectPackage: { _ in throw InstalledGameError.invalidConfig })
        }
        check(refused.candidates.isEmpty && refused.identifiedInstallations[folder.path] == "9NR1R1XWLCNB"
              && !refused.errors.isEmpty,
              "REQ106: Package-inspection failure retains a known matching identity for duplicate-download protection")
        do {
            _ = try MicrosoftGameConfig.configurationFile(in: [
                folder.appendingPathComponent("MicrosoftGame.Config"),
                folder.appendingPathComponent("MicrosoftGame.config")])
            check(false, "REQ106: Ambiguous case variants refuse instead of choosing an arbitrary config")
        } catch InstalledGameError.invalidConfig {
            check(true, "REQ106: Ambiguous case variants refuse instead of choosing an arbitrary config")
        }
        var complete = false
        var completenessCalls = 0
        let store = InstalledGameStore(file: home.appendingPathComponent("registry/games.json"))
        let gate = PackageInspectionInterleaving(initiallyArmed: false)
        let blockedMounts = InstalledGamesController(
            store: InstalledGameStore(file: home.appendingPathComponent("blocked/games.json")),
            mountedStorageRoots: {
                _ = try? gate.inspect(home)
                return []
            }, discoveryRoot: library, installLocation: { nil })
        await blockedMounts.load()
        gate.arm()
        let blockedSession = LiveSession()
        blockedMounts.useUnifiedAccount(blockedSession)
        await blockedMounts.discoverNativeInstallations(root: library)
        check(blockedMounts.discoveringMounts
              && !blockedMounts.canCreateInstallation(productID: "9NR1R1XWLCNB")
              && blockedMounts.canCreateInstallation(productID: "FIXTURE00001",
                  destination: home.appendingPathComponent("local/game").path)
              && blockedMounts.discoveryError == nil,
              "REQ106: Dead mount enumeration times out off-main and keeps unknown-root Install fail-closed")
        gate.release()
        let controller = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc },
            mountedStorageRoots: {
                guard !Thread.isMainThread else { fatalError("Mount enumeration ran on UI thread") }
                return []
            }, discoveryRoot: library, installLocation: { nil },
            discoveryCompleteness: { _, _ in completenessCalls += 1; return complete })
        await controller.load()
        let session = LiveSession()
        controller.useUnifiedAccount(session)
        await controller.discoverNativeInstallations(root: library)
        check(controller.games.isEmpty && controller.hasUnverifiedInstallation(productID: "9NR1R1XWLCNB")
              && !controller.canCreateInstallation(productID: "9NR1R1XWLCNB"),
              "REQ106: Failed completeness neither imports an external payload nor allows a duplicate default-root download")
        let configuration = folder.appendingPathComponent("MicrosoftGame.Config")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: configuration.path)
        await controller.discoverNativeInstallations(root: library)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        check(controller.hasUnverifiedInstallation(productID: "9NR1R1XWLCNB")
              && !controller.canCreateInstallation(productID: "9NR1R1XWLCNB") && controller.discoveryError == nil,
              "REQ106: A transient unreadable config retains its known candidate and Check installation without reopening blind Install")
        check(!controller.canCreateInstallation(productID: "9NR1R1XWLCNB", destination: folder.path)
              && controller.canCreateInstallation(productID: "9NR1R1XWLCNB", destination: folder.path,
                  resumingManagedOperation: true)
              && !controller.canCreateInstallation(productID: "9NR1R1XWLCNB",
                                                    destination: home.appendingPathComponent("default/game").path),
              "COR161: An unmanaged same-product folder stays Check; only a matching managed operation can resume its exact destination")
        let resume = GameOperationRecord(id: InstalledGamesController.runID(), kind: .install,
            productID: "9NR1R1XWLCNB", title: "Forza Horizon 6", destination: folder.path, installedID: nil)
        check(controller.canCreateInstallation(productID: resume.productID, destination: resume.destination,
                  resumingManagedOperation: true),
              "REQ106: A queued partial-install record is admitted at its original destination")
        check(InstalledGamesController.readableEngineName("calimocho-wine11.20-gptk4b3-tls-vulkan-private")
              == "Calimocho"
              && !controller.defaultEngineLabel(for: InstalledGame(id: UUID(), title: "Fixture",
                  identityName: "Fixture", version: "1", storeId: "FIXTURE00001",
                  folder: folder.path, launcher: "", importedAt: Date())).isEmpty,
              "REQ95: Engine menu names the default readably even without alternative inspection rows")
        let operations = GameOperationsController(installed: controller)
        let game = PCGame(id: "9NR1R1XWLCNB", title: "Forza Horizon 6", artwork: nil)
        let resumePaths = GameScriptPaths(scripts: home.appendingPathComponent("scripts"),
            processed: home.appendingPathComponent("processed"), logs: home.appendingPathComponent("logs"),
            games: library, journal: home.appendingPathComponent("operation.json"))
        let resumeOperations = GameOperationsController(installed: controller, paths: resumePaths)
        check(GameInstallAction(game: game, operations: resumeOperations).actionTitle == "Checking…",
              "COR161: A discovered unmanaged folder never becomes a new Install just because it matches the default destination")
        check(GameInstallAction(game: game, operations: operations).actionTitle == "Checking…",
              "REQ106: Unverified matching package uses existing Check installation action, not blind Install")
        let callsBeforeEntry = completenessCalls
        await operations.automaticallyCheckExistingInstallation(game)
        check(operations.installConsent == nil && operations.operation == nil
              && operations.existingInstallationError(productID: game.id) != nil && operations.error == nil,
              "COR169: Entering a discovered product automatically verifies it and surfaces failure without download or consent")
        await operations.automaticallyCheckExistingInstallation(game)
        check(completenessCalls == callsBeforeEntry + 1
              && GameInstallAction(game: game, operations: operations).actionTitle == "Retry"
              && operations.existingInstallationError(productID: game.id)?.contains("incomplete") == true,
              "COR170: Terminal readiness has a specific reason and Retry, with no repeated automatic verification storm")
        complete = true
        await GameInstallAction(game: game, operations: operations).requestInstall()
        check(controller.games.count == 1 && controller.games[0].folder == folder.path
              && controller.games[0].usesNativeLifecycle == true
              && controller.games[0].storageVolume != nil && controller.launchableIDs.isEmpty
              && !controller.hasUnverifiedInstallation(productID: game.id)
              && !controller.canCreateInstallation(productID: game.id),
              "REQ106: Verified external package is registered at its original path without copying or bypassing launch account checks")
        await controller.discoverNativeInstallations(root: library)
        check(controller.games.count == 1,
              "REQ106: Repeated external discovery never creates duplicate installed records")
        try FileManager.default.removeItem(at: folder)
        await controller.discoverNativeInstallations(root: library)
        check(controller.games.count == 1,
              "REQ106: Losing an external folder never prunes or relocates an already registered installation")
        let consent = GameInstallConsent(game: PCGame(id: "FIXTURE00002", title: "Original Ridge", artwork: nil),
            destination: home.appendingPathComponent("Original Ridge"), freeBytes: 80_000_000_000,
            installedID: nil, compatibility: GameCompatibilityResult(storeId: "FIXTURE00002",
                packageBytes: 3_200_000_000, supported: true, reason: nil, checkedAt: "2026-10-07T00:00:00Z"))
        NativeUIChecks.checkConsentContentHeight(operations: operations, consent: consent, check: check)
    }

    static func storageLocationChecks(check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/StorageChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "REQ92: Synthetic storage files are cleaned") }
        }
        let a = root.appendingPathComponent("drive-a"), b = root.appendingPathComponent("drive-b")
        let detachedB = root.appendingPathComponent("detached-b")
        let launcher = root.appendingPathComponent("never-run.sh")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        var entries: [InstalledGame] = []
        for (index, drive) in [a, b].enumerated() {
            let folder = drive.appendingPathComponent("installed-game")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let product = String(format: "FIXTURE%05d", index + 1)
            try Data("""
                <Game><Identity Name="Storage.Game" Version="1.0.0.0"/>
                <StoreId>\(product)</StoreId></Game>
                """.utf8).write(to: folder.appendingPathComponent("MicrosoftGame.config"))
            entries.append(InstalledGame(id: UUID(), title: "Storage game \(index)", identityName: "Storage.Game",
                version: "1.0.0.0", storeId: product, folder: folder.path, launcher: launcher.path,
                importedAt: Date(), packageType: .msixvc, storageVolume: GameStorageVolume(path: drive.path)))
        }
        let store = InstalledGameStore(file: root.appendingPathComponent("registry/games.json"))
        var legacy = entries[0]
        legacy.storageVolume = nil
        let legacyData = try JSONEncoder().encode(legacy)
        check(try JSONDecoder().decode(InstalledGame.self, from: legacyData).storageVolume == nil
              && !String(decoding: legacyData, as: UTF8.self).contains("storageVolume"),
              "REQ92: Existing registry entries without volume evidence remain decodable without invented drive status")
        try await store.save(entries)
        let controller = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc },
            mountedStorageRoots: { [a, b].filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path) })
        await controller.load()
        check(Set(controller.games.map(\.folder)) == Set(entries.map(\.folder))
              && controller.launchableIDs == Set(entries.map(\.id)),
              "REQ92: Games across multiple recorded roots retain their exact paths and local readiness")
        try FileManager.default.moveItem(at: b, to: detachedB)
        await controller.checkInstallation(entries[1])
        let savedOffline = try await store.load()
        check(controller.games.map(\.folder) == entries.map(\.folder)
              && controller.unavailableDriveIDs == [entries[1].id]
              && !controller.launchableIDs.contains(entries[1].id)
              && controller.launchableIDs.contains(entries[0].id)
              && savedOffline.map(\.folder) == entries.map(\.folder),
              "REQ92: Missing recorded mount preserves both entries/paths and fences only that drive")
        let offlineOperations = GameOperationsController(installed: controller)
        let offlineAttention = InstalledGameAttentionView(installed: controller, operations: offlineOperations,
            game: entries[1], repairGame: PCGame(id: entries[1].storeId, title: entries[1].title, artwork: nil), close: {})
        check(!offlineAttention.offersRepair && !offlineOperations.canRepair(entries[1]),
              "REQ92: An unavailable drive offers read-only recovery rather than repair or replacement")
        try FileManager.default.moveItem(at: detachedB, to: b)
        await controller.checkInstallation(entries[1])
        check(controller.unavailableDriveIDs.isEmpty
              && controller.launchableIDs.contains(entries[1].id)
              && controller.games.map(\.folder) == entries.map(\.folder),
              "REQ92: Read-only Check again restores readiness after a drive returns without relocation or reimport")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: entries[1].folder))
        await controller.checkInstallation(entries[1])
        check(controller.unavailableDriveIDs.isEmpty && controller.games.count == 2
              && !controller.launchableIDs.contains(entries[1].id)
              && controller.packageErrors[entries[1].id] == InstalledGameError.missingFolder.localizedDescription,
              "REQ92: A deleted folder on a mounted drive is not mislabeled as an unavailable drive")
        let invalidStore = InstalledGameStore(file: root.appendingPathComponent("invalid-registry/games.json"))
        try await invalidStore.save([entries[0]])
        var invalid = entries[1]
        invalid.storageVolume = GameStorageVolume(path: "/different-volume")
        let validBytes = try Data(contentsOf: invalidStore.file)
        do {
            try await invalidStore.save([entries[0], invalid])
            check(false, "REQ92 invalid volume containment cannot be persisted")
        } catch {
            check(try Data(contentsOf: invalidStore.file) == validBytes,
                  "REQ92 invalid volume containment cannot be persisted")
        }
        try JSONEncoder().encode([entries[0], invalid]).write(to: invalidStore.file)
        do {
            let migrated = try await invalidStore.load()
            check(migrated.count == 2 && migrated[0] == entries[0]
                  && migrated[1].storageVolume == nil && migrated[1].folder == invalid.folder,
                  "REQ92 a legacy invalid volume is retired per entry without losing the other installed games")
        } catch {
            check(false, "REQ92 a legacy invalid volume is retired per entry without losing the other installed games")
        }
        let link = root.appendingPathComponent("linked-game")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: entries[0].folder))
        check(GameStorageVolume.read(at: link) == nil,
              "REQ92 symlinked folders do not generate lexical-volume evidence from their resolved target")
        var linked = entries[0]
        linked = InstalledGame(id: UUID(), title: linked.title, identityName: linked.identityName,
            version: linked.version, storeId: linked.storeId, folder: link.path, launcher: linked.launcher,
            importedAt: Date(), packageType: .msixvc)
        linked.storageVolume = GameStorageVolume(path: "/different-volume")
        try JSONEncoder().encode([entries[0], linked]).write(to: invalidStore.file)
        let linkedController = InstalledGamesController(store: invalidStore, inspectPackage: { _ in .msixvc })
        await linkedController.load()
        check(linkedController.games.count == 2 && !linkedController.launchableIDs.contains(linked.id)
              && linkedController.packageErrors[linked.id] != nil,
              "REQ92 symlinked registry entry is not ready and does not poison a healthy saved library")
        await linkedController.importGame(folder: link, launcher: launcher)
        check(linkedController.error != nil && linkedController.games.count == 2,
              "REQ92 manual import refuses symlinked storage without replacing recorded games")
        let probe = GameStorageProbe()
        do {
            _ = try await probe.read(timeout: .milliseconds(10)) {
                Thread.sleep(forTimeInterval: 0.15)
                return 1
            }
            check(false, "REQ92: A stalled filesystem read releases its UI waiter at the deadline")
        } catch {
            check(error as? GameStorageProbeError == .timedOut,
                  "REQ92: A stalled filesystem read releases its UI waiter at the deadline")
        }
        do {
            _ = try await probe.read { 2 }
            check(false, "REQ92: Timed-out syscall retains its one worker reservation until it actually returns")
        } catch {
            check(error as? GameStorageProbeError == .pending,
                  "REQ92: Timed-out syscall retains its one worker reservation until it actually returns")
        }
        try await Task.sleep(for: .milliseconds(200))
        check(try await probe.read { 3 } == 3,
              "REQ92: Late completion cannot republish its old result and a returned worker can be reused")
        let gate = PackageInspectionInterleaving()
        defer { gate.release() }
        let cancelledRead = Task { try await probe.read { try gate.inspect(root) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.isWaiting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        check(gate.isWaiting, "COR105: Synthetic blocked storage worker starts off the main actor")
        cancelledRead.cancel()
        do {
            _ = try await cancelledRead.value
            check(false, "COR105: Cancellation completes only the storage waiter")
        } catch {
            check(error is CancellationError, "COR105: Cancellation completes only the storage waiter")
        }
        do {
            _ = try await probe.read { 4 }
            check(false, "COR105: Cancelled blocked worker prevents a replacement worker")
        } catch {
            check(error as? GameStorageProbeError == .pending,
                  "COR105: Cancelled blocked worker prevents a replacement worker")
        }
        gate.release()
        try await Task.sleep(for: .milliseconds(50))
        check(try await probe.read { 5 } == 5,
              "COR105: Only actual worker return releases the cancelled storage reservation")
        try await discoveryLocationChecks(root: root, check: check)
    }

    private static func discoveryLocationChecks(root: URL, check: (Bool, String) -> Void) async throws {
        let original = root.appendingPathComponent("original")
        let selected = root.appendingPathComponent("selected")
        let recorded = root.appendingPathComponent("recorded")
        var folders: [String: URL] = [:]
        for (index, parent) in [recorded, original, selected, recorded, selected].enumerated() {
            let product = String(format: "FIXTURE%05d", index + 1)
            let folder = parent.appendingPathComponent(product)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("""
                <Game><Identity Name="Discovery.\(index)" Version="1.0.0.0"/>
                <StoreId>\(product)</StoreId></Game>
                """.utf8).write(to: folder.appendingPathComponent("MicrosoftGame.config"))
            folders[product] = folder
        }
        let savedLocation = try GameInstallLocation(folder: selected)
        let existing = InstalledGame(id: UUID(), title: "Recorded", identityName: "Discovery.0",
            version: "1.0.0.0", storeId: "FIXTURE00001",
            folder: recorded.appendingPathComponent("FIXTURE00001").path,
            launcher: "", importedAt: Date(), packageType: .msixvc, usesNativeLifecycle: true,
            storageVolume: GameStorageVolume(path: recorded.path))
        let store = InstalledGameStore(file: root.appendingPathComponent("discovery/games.json"))
        try await store.save([existing])
        let expectedFolders = folders
        var inspections: [String] = []
        let controller = InstalledGamesController(store: store, inspectPackage: { _ in
            guard !Thread.isMainThread else { throw InstalledGameError.invalidConfig }
            return .msixvc
        }, mountedStorageRoots: { ["/", recorded.path] },
            discoveryRoot: original, installLocation: { savedLocation }, discoveryCompleteness: { product, folder in
                inspections.append(product)
                return product != "FIXTURE00005" && expectedFolders[product]?.path == folder.path
            })
        let session = LiveSession()
        await controller.load()
        controller.useUnifiedAccount(session)
        await controller.discoverNativeInstallations()
        check(Set(controller.games.map(\.folder)) == Set(folders.filter { $0.key != "FIXTURE00005" }.map(\.value.path))
              && Set(inspections) == Set(["FIXTURE00002", "FIXTURE00003", "FIXTURE00004", "FIXTURE00005"]),
              "COR105: Discovery scans original, saved default and recorded roots using exact product/folder completeness checks")
        check(!controller.games.contains { $0.storeId == "FIXTURE00005" }
              && controller.discoveryError == nil && controller.launchableIDs.isEmpty,
              "COR105: Config-only incomplete payload is not adopted or promoted to launch/account readiness")
        await controller.discoverNativeInstallations()
        check(controller.games.count == 4 && controller.games.filter { $0.id == existing.id }.count == 1,
              "COR105: Repeated discovery deduplicates roots and preserves the registered identity")

        let offline = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc },
            mountedStorageRoots: { [] }, discoveryRoot: original, installLocation: { savedLocation },
            discoveryCompleteness: { _, _ in false })
        await offline.load()
        offline.useUnifiedAccount(session)
        await offline.discoverNativeInstallations()
        check(offline.games.count == 4 && offline.games.contains { $0.id == existing.id && $0.folder == existing.folder }
              && offline.discoveryError == nil,
              "COR105: Automatic offline discovery keeps entries without a raw-path banner")
        let invalid = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc },
            mountedStorageRoots: { [] }, discoveryRoot: original,
            installLocation: { throw GameScriptError.invalidDestination },
            discoveryCompleteness: { _, _ in true })
        await invalid.load()
        invalid.useUnifiedAccount(session)
        await invalid.discoverNativeInstallations()
        check(invalid.games.count == 4 && invalid.discoveryError == nil,
              "COR105: Automatic invalid saved root retains entries without importing a fallback or showing a banner")
        let changingRoot = root.appendingPathComponent("changing")
        let changingFolder = changingRoot.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: changingFolder, withIntermediateDirectories: true)
        let changingConfig = changingFolder.appendingPathComponent("MicrosoftGame.config")
        let before = """
            <Game><Identity Name="Before" Version="1.0.0.0"/><StoreId>FIXTURE00006</StoreId></Game>
            """
        try Data(before.utf8).write(to: changingConfig)
        let changingStore = InstalledGameStore(file: root.appendingPathComponent("changing-registry/games.json"))
        let changing = InstalledGamesController(store: changingStore, inspectPackage: { _ in .msixvc },
            mountedStorageRoots: { [] }, discoveryRoot: changingRoot, installLocation: { nil }, discoveryCompleteness: { _, _ in
                try await Task.detached {
                    try Data(before.replacingOccurrences(of: "Before", with: "After").utf8).write(to: changingConfig)
                }.value
                return true
            })
        await changing.load()
        changing.useUnifiedAccount(session)
        await changing.discoverNativeInstallations()
        check(changing.games.isEmpty && changing.discoveryError == nil
              && changing.hasUnverifiedInstallation(productID: "FIXTURE00006"),
              "COR105: Same-product config identity changed during completeness checking cannot be adopted from stale metadata")
        let capped = root.appendingPathComponent("capped")
        try FileManager.default.createDirectory(at: capped, withIntermediateDirectories: false)
        for index in 0..<513 {
            try Data().write(to: capped.appendingPathComponent("child-\(index)"))
        }
        let observed = try await GameStorageProbe().read {
            try GameInstallationDiscovery.scan(originalRoot: capped, location: nil, entries: [],
                mountedRoots: [], inspectPackage: { _ in .msixvc })
        }
        check(observed.candidates.isEmpty && observed.errors.count == 1,
              "COR105: Discovery stops at the existing 512-child bound rather than scanning an unbounded root")
    }

    static func legacyNativeReadiness(check: (Bool, String) -> Void) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/LegacyNativeChecks-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "REQ95: Synthetic legacy installation is cleaned") }
        }
        try Data("""
            <Game><Identity Name="HelloGames.NoMansSky" Version="7.6.0.0"/>
            <StoreId>BQVQTL3PCH05</StoreId></Game>
            """.utf8).write(to: folder.appendingPathComponent("MicrosoftGame.config"))
        let game = InstalledGame(id: UUID(), title: "No Man's Sky", identityName: "HelloGames.NoMansSky",
            version: "7.6.0.0", storeId: "BQVQTL3PCH05", folder: folder.path,
            launcher: root.appendingPathComponent("XodusRemote/launchers/BQVQTL3PCH05.sh").path,
            importedAt: Date(), packageType: .msixvc, storageVolume: GameStorageVolume(path: "/"))
        let store = InstalledGameStore(file: root.appendingPathComponent("registry/games.json"))
        try await store.save([game])
        let controller = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc })
        let session = LiveSession()
        controller.useUnifiedAccount(session)
        await controller.load()
        check(game.engineSelection == nil && game.usesNativeLifecycle == nil
              && controller.packageErrors[game.id] == nil,
              "REQ95: NMS-shaped native record verifies folder and identity without requiring its unused legacy launcher")
        check(!controller.launchableIDs.contains(game.id),
              "REQ95: Local folder verification alone never bypasses native completeness or account admission")
        controller.setAccountAccessAllowed(true)
        await controller.play(game)
        let attention = InstalledGameAttentionView(installed: controller,
            operations: GameOperationsController(installed: controller), game: game, close: {})
        check(controller.playErrors[game.id] != nil && attention.needsAttention
              && !attention.offersRepair && !attention.offersInstallationCheck
              && controller.productAccessNotice(for: game) != nil,
              "REQ95: A launch/access refusal never becomes an installation-damage claim or repair action")
        try Data("<Game><Identity Name=\"Wrong\" Version=\"7.6.0.0\"/><StoreId>FIXTURE00001</StoreId></Game>".utf8)
            .write(to: folder.appendingPathComponent("MicrosoftGame.config"))
        await controller.checkInstallation(game)
        check(controller.packageErrors[game.id] != nil,
              "REQ95: Native legacy records still reject a mismatched product identity")
        let historical = InstalledGamesController(store: store, inspectPackage: { _ in .msixvc })
        await historical.load()
        check(historical.packageErrors[game.id] != nil,
              "REQ95: Non-native historical launch paths still require their launcher")
    }

    static func run(check: (Bool, String) -> Void) async throws {
        try await legacyNativeReadiness(check: check)
        try await LaunchAssociationChecks.run(check: check)
        let catalogue = OfflineGameCompatibility(version: 1, checkedAt: "2026-10-21T00:00:00Z",
            market: "GB", packageSource: "Synthetic unit-test classification", antiCheatReference: "Unit test",
            products: ["FIXTURE00001": .init(title: nil, packageFormat: "MSIXVC", pcPackageIdentified: true,
                antiCheat: "none", technologyReferences: [], referencePlatforms: [])])
        let config = """
        <?xml version="1.0"?>
        <Game><Identity Name="Fixture.Game" Version="1.2.3.4"/>
        <ShellVisuals DefaultDisplayName="Fixture Installed Game"/><StoreId>FIXTURE00001</StoreId></Game>
        """
        let metadata = try MicrosoftGameConfig.parse(Data(config.utf8))
        check(metadata.identityName == "Fixture.Game" && metadata.version == "1.2.3.4"
              && metadata.storeId == "FIXTURE00001" && metadata.title == "Fixture Installed Game",
              "Installed config reads identity, version, StoreId and display name without a provider")
        let fallback = try MicrosoftGameConfig.parse(Data(config.replacingOccurrences(
            of: "<ShellVisuals DefaultDisplayName=\"Fixture Installed Game\"/>", with: "").utf8))
        check(fallback.title == fallback.identityName, "Missing display name falls back to exact Identity Name")
        let placeholderConfig = config.replacingOccurrences(of: "</Game>", with:
            #"<ExecutableList><Executable Name="MCPlaceholderStub.exe"/></ExecutableList></Game>"#)
        check(try MicrosoftGameConfig.parse(Data(placeholderConfig.utf8)).placeholderOnly,
              "An explicitly declared Minecraft placeholder is not playable content")
        let mixedConfig = placeholderConfig.replacingOccurrences(of: "</ExecutableList>",
            with: #"<Executable Name="MinecraftLauncher.exe"/></ExecutableList>"#)
        check(try !MicrosoftGameConfig.parse(Data(mixedConfig.utf8)).placeholderOnly
              && !metadata.placeholderOnly,
              "Placeholder detection never guesses from the title, missing executable metadata or a mixed full package")
        for xml in ["", "<Game>", "<Other/>", config.replacingOccurrences(of: "Version=\"1.2.3.4\"", with: ""),
                    config.replacingOccurrences(of: "<StoreId>FIXTURE00001</StoreId>", with: ""),
                    config.replacingOccurrences(of: "1.2.3.4", with: "not-a-version"),
                    "<!DOCTYPE Game [<!ENTITY title 'unexpected'>]><Game>&title;</Game>"] {
            do { _ = try MicrosoftGameConfig.parse(Data(xml.utf8)); check(false, "Invalid installed config is refused") }
            catch { check(error is InstalledGameError, "Invalid installed config is refused") }
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/InstalledGameChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "Synthetic installed-game files are cleaned after sessions exit") }
        }
        let folder = root.appendingPathComponent("game folder with spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sizeFolder = root.appendingPathComponent("size-fixture")
        let sizeOutside = root.appendingPathComponent("size-outside")
        try FileManager.default.createDirectory(at: sizeFolder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sizeOutside, withIntermediateDirectories: false)
        let sizeFile = sizeFolder.appendingPathComponent("payload")
        try Data(repeating: 42, count: 8192).write(to: sizeFile)
        try Data(repeating: 42, count: 32768).write(to: sizeOutside.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: sizeFolder.appendingPathComponent("external"),
                                                  withDestinationURL: sizeOutside)
        guard link(sizeFile.path, sizeFolder.appendingPathComponent("hardlink").path) == 0 else {
            throw InstalledSizeFailure.unavailable
        }
        let measured = try await Task.detached { try InstalledFolderSize.measure(folder: sizeFolder) }.value
        var sizeRootInfo = stat(), sizeFileInfo = stat()
        guard lstat(sizeFolder.path, &sizeRootInfo) == 0, lstat(sizeFile.path, &sizeFileInfo) == 0 else {
            throw InstalledSizeFailure.unavailable
        }
        check(measured.logicalBytes == 8192 &&
              measured.allocatedBytes == Int64(sizeRootInfo.st_blocks + sizeFileInfo.st_blocks) * 512,
              "Installed size measures off-main, excludes external symlinks and counts hardlinks once")
        do {
            _ = try await Task.detached { try InstalledFolderSize.measure(folder: sizeFolder, maximumEntries: 1) }.value
            check(false, "Incomplete bounded folder traversal never publishes a successful size")
        } catch { check(error as? InstalledSizeFailure == .incomplete,
                        "Incomplete bounded folder traversal never publishes a successful size") }
        let sizeGame = InstalledGame(id: UUID(), title: "Size fixture", identityName: "Fixture.Size",
            version: "1.0.0.0", storeId: "FIXTURE00002", folder: sizeFolder.path, launcher: "/fixture/not-run",
            importedAt: Date())
        let sizeStore = InstalledGameSizeStore()
        await sizeStore.load(sizeGame)
        await sizeStore.load(sizeGame)
        check(sizeStore.measurementAttempts == 1 && sizeStore.value(for: sizeGame)?.logicalBytes == 8192,
              "Rendering/reopening the same installed identity reuses its size cache without another traversal")
        do { _ = try MicrosoftGameConfig.read(folder: folder); check(false, "Missing config folder is rejected") }
        catch { check(error is InstalledGameError, "Missing config folder is rejected") }
        try Data(config.utf8).write(to: folder.appendingPathComponent("MicrosoftGame.Config"))
        check(try MicrosoftGameConfig.read(folder: folder) == metadata,
              "Case-insensitive MicrosoftGame.Config filename is found in only the selected folder")
        let visuals = """
        <Game><Identity Name="Fixture.Game" Version="1.2.3.4"/><ShellVisuals
        DefaultDisplayName="Fixture Installed Game" PublisherDisplayName="Fixture Publisher"
        Square480x480Logo="Resources\\large.png" Square150x150Logo="Resources\\small.png"
        StoreLogo="Resources\\store.png" SplashScreenImage="Resources\\splash.png"/>
        <StoreId>FIXTURE00001</StoreId></Game>
        """
        let enriched = try MicrosoftGameConfig.parse(Data(visuals.utf8))
        check(enriched.publisher == "Fixture Publisher" && enriched.tileArt ==
            ["Resources\\large.png", "Resources\\small.png", "Resources\\store.png"]
            && enriched.splashArt == "Resources\\splash.png",
              "AC1.1/1.2: ShellVisuals retains publisher and exact ordered Windows-style artwork paths")
        let resources = folder.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        func png(width: Int) throws -> Data {
            guard let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { throw ArtworkLoadError.invalidImage }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
                throw ArtworkLoadError.invalidImage
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ArtworkLoadError.invalidImage }
            return bytes as Data
        }
        let tiny = try png(width: 8)
        try tiny.write(to: resources.appendingPathComponent("large.png"))
        try png(width: 4).write(to: resources.appendingPathComponent("small.png"))
        try png(width: 2).write(to: resources.appendingPathComponent("store.png"))
        let selected = InstalledArtworkPolicy.image(folder: folder, candidates: enriched.tileArt, maxDimension: 480)
        check(selected?.width == 8, "AC1.1: Valid Square480 art is preferred without using a catalog")
        try Data("broken".utf8).write(to: resources.appendingPathComponent("large.png"))
        check(InstalledArtworkPolicy.image(folder: folder, candidates: enriched.tileArt, maxDimension: 480)?.width == 4,
              "AC1.1: Invalid Square480 falls back to valid Square150")
        try FileManager.default.removeItem(at: resources.appendingPathComponent("small.png"))
        check(InstalledArtworkPolicy.image(folder: folder, candidates: enriched.tileArt, maxDimension: 480)?.width == 2,
              "AC1.1: Missing Square150 falls back to StoreLogo")
        let art = try InstalledArtworkPolicy.read(folder: folder, relative: "Resources\\store.png")
        check(try InstalledArtworkPolicy.decode(art, maxDimension: 1).width == 1,
              "AC1.1: Local decode is downsampled to its presentation budget")
        for path in ["../outside.png", "/outside.png", "\\outside.png", "C:\\outside.png",
                     "Resources/../store.png", "Resources//store.png", "Resources/./store.png",
                     "Resources/store.gif", "Resources/store.png\u{0}"] {
            check(InstalledArtworkPolicy.components(path) == nil, "AC1.6: Unsafe or non-PNG/JPEG local art path is rejected")
        }
        let outside = root.appendingPathComponent("outside.png")
        try tiny.write(to: outside)
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("link.png"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: resources)
        for path in ["Resources/link.png", "linked/store.png", "Resources"] {
            do { _ = try InstalledArtworkPolicy.read(folder: folder, relative: path); check(false, "AC1.6: Symlink/nonregular artwork is refused") }
            catch { check(true, "AC1.6: Symlink/nonregular artwork is refused") }
        }
        let tooLarge = resources.appendingPathComponent("huge.png")
        try Data(repeating: 0, count: InstalledArtworkPolicy.maximumBytes).write(to: tooLarge)
        check(try InstalledArtworkPolicy.read(folder: folder, relative: "Resources/huge.png").count == 8 * 1024 * 1024,
              "AC1.6: Exact 8MiB byte boundary is accepted for bounded reading")
        try Data(repeating: 0, count: InstalledArtworkPolicy.maximumBytes + 1).write(to: tooLarge)
        do { _ = try InstalledArtworkPolicy.read(folder: folder, relative: "Resources/huge.png"); check(false, "AC1.6: Artwork above 8MiB is refused") }
        catch { check(true, "AC1.6: Artwork above 8MiB is refused") }
        try InstalledArtworkPolicy.validatePixels(width: 4000, height: 4000)
        check(true, "AC1.6: Exact 16M-pixel boundary passes")
        for dimensions in [(4001, 4000), (0, 1), (Int.max, Int.max)] {
            do { try InstalledArtworkPolicy.validatePixels(width: dimensions.0, height: dimensions.1); check(false, "AC1.6: Unsafe pixel dimensions fail before decode") }
            catch { check(true, "AC1.6: Unsafe pixel dimensions fail before decode") }
        }
        var pixelBomb = tiny
        for offset in [16, 20] {
            pixelBomb.replaceSubrange(offset..<(offset + 4), with: [UInt8(0), 0, 16, 0])
        }
        var crc: UInt32 = 0xffffffff
        for byte in pixelBomb[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        crc ^= 0xffffffff
        pixelBomb.replaceSubrange(29..<33, with: [
            UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
            UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)
        ])
        do { _ = try InstalledArtworkPolicy.decode(pixelBomb, maxDimension: 480); check(false, "AC1.6: Invalid oversized PNG header never produces a decoded image") }
        catch {
            check(error as? ArtworkLoadError == .oversized || error as? ArtworkLoadError == .invalidImage,
                  "AC1.6: Invalid oversized PNG header never produces a decoded image")
        }
        check(InstalledArtworkPolicy.image(folder: folder, candidates: ["missing.png", "Resources/huge.png"], maxDimension: 480) == nil,
              "AC1.1: Missing/invalid artwork silently preserves the system-symbol fallback")
        try Data(visuals.utf8).write(to: folder.appendingPathComponent("MicrosoftGame.Config"))
        func script(_ name: String, _ contents: String) throws -> URL {
            let file = root.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + contents + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file
        }
        let zero = try script("exit zero.sh", "exit 0")
        let failure = try script("exit three.sh", "exit 3")
        let record = root.appendingPathComponent("arguments.txt")
        let slow = try script("sleep two.sh",
            "printf '%s\\n' \"$#\" \"$1\" \"$2\" \"$PATH\" \"${XODUS_ENGINE-unset}\" \"${XODUS_NEUTRAL_SECRET-unset}\" > '\(record.path)'\nsleep 2\nexit 0")
        let file = root.appendingPathComponent("private/installed-games.json")
        let store = InstalledGameStore(file: file)
        let library = InstalledGamesController(store: store, launchingDuration: .milliseconds(100),
                                               logDirectory: root.appendingPathComponent("logs"),
                                               defaultEngine: { .crossover },
                                               detectAvailability: { RunnerAvailability([.crossover]) },
                                               compatibilityCatalogue: catalogue)
        await library.load()
        check(library.loaded && library.games.isEmpty && library.error == nil,
              "Absent private list loads as empty without importing or scanning games")
        await library.importGame(folder: folder, launcher: zero)
        guard let game = library.games.first else {
            check(false, "Exact-folder fixture import: \(library.error ?? "no error")")
            throw InstalledGameError.invalidRegistry
        }
        let unclassified = InstalledGamesController(store: store, compatibilityCatalogue: nil)
        await unclassified.load()
        guard let title = unclassified.games.first else { throw InstalledGameError.invalidRegistry }
        check(unclassified.launchableIDs.contains(title.id)
              && LibrarySupportVisibility.issues(productID: title.storeId, installed: true,
                    packageFormat: nil, compatibility: nil, catalogue: nil).isEmpty,
              "#44: An unclassified installed title retains playable content without a generic unsupported blocker")
        for (format, antiCheat) in [("MSIXVC", "Easy Anti-Cheat"), ("Appx", "none")] {
            let rejectedCatalogue = OfflineGameCompatibility(version: 1, checkedAt: catalogue.checkedAt,
                market: catalogue.market, packageSource: catalogue.packageSource,
                antiCheatReference: catalogue.antiCheatReference,
                products: [game.storeId: .init(title: nil, packageFormat: format, pcPackageIdentified: true,
                    antiCheat: antiCheat, technologyReferences: [], referencePlatforms: [])])
            let rejected = InstalledGamesController(store: store, compatibilityCatalogue: rejectedCatalogue)
            await rejected.load()
            rejected.setAccountAccessAllowed(true)
            guard let title = rejected.games.first else { throw InstalledGameError.invalidRegistry }
            await rejected.play(title)
            check(rejected.runningGameID == nil && !rejected.launchStarted
                  && rejected.playErrors[title.id]?.contains(antiCheat == "none" ? format.uppercased() : antiCheat) == true,
                  "UI-5: Direct play rejects \(format) with \(antiCheat) even when account access is allowed")
        }
        NativeUIChecks.checkWelcomePrivacy(installed: library, check: check)
        check(game.publisher == "Fixture Publisher" && game.lastPlayedAt == nil && library.continuingGame == nil,
              "AC1.2/1.4: Import stores publisher but never invents a played session or hero")
        check(game.title == metadata.title && game.identityName == metadata.identityName
              && game.version == metadata.version && game.storeId == metadata.storeId
              && game.folder == folder.path && game.launcher == zero.path,
              "Explicit selected folder and launcher persist only their imported identity")
        check(try await store.load() == [game], "Private installed-game JSON round-trips exact fields")
        let configFile = folder.appendingPathComponent("MicrosoftGame.Config")
        let savedConfig = try Data(contentsOf: configFile)
        try Data(placeholderConfig.utf8).write(to: configFile)
        let placeholderLibrary = InstalledGamesController(store: store, defaultEngine: { nil },
            detectAvailability: { RunnerAvailability([.crossover]) })
        await placeholderLibrary.load()
        check(placeholderLibrary.placeholderIDs.contains(game.id)
              && !placeholderLibrary.launchableIDs.contains(game.id)
              && placeholderLibrary.packageErrors[game.id] == InstalledGameError.placeholderContent.localizedDescription
              && placeholderLibrary.games.count == 1,
              "Known placeholder registration remains intact but cannot advertise Play or Continue Playing")
        await placeholderLibrary.checkInstallation(game)
        check(placeholderLibrary.placeholderIDs.contains(game.id)
              && placeholderLibrary.checkingInstallations.isEmpty && !placeholderLibrary.editing
              && !placeholderLibrary.launchStarted,
              "Automatic local installation checking settles without launching or repairing placeholder content")
        do {
            try InstalledGameFiles.checkPlayableContent(folder)
            check(false, "The live prelaunch content check refuses a declared placeholder before spawning")
        } catch {
            check(error as? InstalledGameError == .placeholderContent,
                  "The live prelaunch content check refuses a declared placeholder before spawning")
        }
        try savedConfig.write(to: configFile)
        let legacyData = try JSONEncoder().encode([game])
        guard var legacy = try JSONSerialization.jsonObject(with: legacyData) as? [[String: Any]] else {
            throw InstalledGameError.invalidRegistry
        }
        for key in ["publisher", "lastPlayedAt", "lastSessionSeconds"] { legacy[0].removeValue(forKey: key) }
        let oldEntry = try JSONDecoder().decode([InstalledGame].self, from: JSONSerialization.data(withJSONObject: legacy))[0]
        check(oldEntry.publisher == nil && oldEntry.lastPlayedAt == nil && oldEntry.lastSessionSeconds == nil,
              "AC1.2/1.6: Legacy registry entries without new fields decode unchanged")
        legacy[0]["lastSessionSeconds"] = "invalid"
        do { _ = try JSONDecoder().decode([InstalledGame].self, from: JSONSerialization.data(withJSONObject: legacy)); check(false, "AC1.2: Wrong-type new history fields are refused") }
        catch { check(true, "AC1.2: Wrong-type new history fields are refused") }
        let filePermissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        check(filePermissions?.intValue == 0o600 && directoryPermissions?.intValue == 0o700,
              "Atomic installed list is 0600 within a 0700 directory")
        await library.importGame(folder: folder, launcher: failure)
        check(library.games.count == 1 && library.games.first?.id == game.id,
              "Reimport updates one local folder entry rather than duplicating it")
        guard let failedGame = library.games.first else { throw InstalledGameError.invalidRegistry }
        library.setAccountAccessAllowed(false, message: "Xbox services are reconnecting automatically.")
        await library.playHistoricalFixture(failedGame)
        check(library.runningGameID == nil
              && library.playErrors[failedGame.id] == "Xbox services are reconnecting automatically.",
              "Unavailable Xbox services block an installed game before its launcher starts")
        library.setAccountAccessAllowed(true)
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw InstalledGameError.launch }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        await library.playHistoricalFixture(failedGame)
        try await wait { library.runningGameID == nil }
        await library.waitForSessionPersistence()
        let failedSession = try await store.load().first
        check(failedSession?.lastPlayedAt != nil && failedSession?.lastSessionSeconds.map { $0 >= 0 } == true,
              "AC1.3: A short-lived Xodus-launched failure records its start and measured lifetime atomically")
        check(library.playErrors[game.id] == "The game launcher reported an error (code 3)." && library.playState == nil,
              "Nonzero fake session exit returns to Play with exact code and retry message")
        let failedButton = InstalledPlayButton(library: library,
            operations: GameOperationsController(installed: library), game: failedGame)
        check(failedButton.loadingTitle == nil && failedButton.title == "Try again",
              "REQ-75: A real launcher failure retires loading and exposes retry while preserving its exact error")
        check(library.playLogs[game.id] == nil, "AC2.3: A nonzero session without its stderr file offers no Show log")
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        let loggedFailure = try script("logged failure.sh",
            "printf 'neutral launch error\\n' > '\(logs.path)/'\"$1\"'.stderr.log'\nexit 3")
        await library.importGame(folder: folder, launcher: loggedFailure)
        guard let loggedGame = library.games.first else { throw InstalledGameError.invalidRegistry }
        await library.playHistoricalFixture(loggedGame)
        try await wait { library.playLogs[game.id] != nil }
        check(library.playLogs[game.id]?.deletingLastPathComponent().path == logs.path
              && library.playErrors[game.id] == "The game launcher reported an error (code 3).",
              "AC2.3: Nonzero script exit exposes only its existing generated-session stderr file")
        await library.waitForSessionPersistence()
        await library.importGame(folder: folder, launcher: zero)
        guard let zeroGame = library.games.first else { throw InstalledGameError.invalidRegistry }
        await library.playHistoricalFixture(zeroGame)
        try await wait { library.runningGameID == nil }
        check(library.playErrors[game.id] == nil && library.playState == nil,
              "Retry's exit zero returns silently to Play without stale failure")
        check(library.playLogs[game.id] == nil, "AC2.3: Retry clears the previous session log action")
        await library.importGame(folder: folder, launcher: slow)
        guard let slowGame = library.games.first else { throw InstalledGameError.invalidRegistry }
        await library.playHistoricalFixture(slowGame)
        check(library.playState == .launching && library.runningGameID == slowGame.id,
              "A live fake launcher first publishes Launching")
        let launchingButton = InstalledPlayButton(library: library,
            operations: GameOperationsController(installed: library), game: slowGame)
        check(launchingButton.loadingTitle == "Opening \(slowGame.title)" && library.launchStarted,
              "REQ-75: A started synthetic launcher presents title-specific opening status, not game readiness")
        await library.playHistoricalFixture(slowGame)
        try await wait { library.playState == .playing }
        check(launchingButton.loadingTitle == nil && launchingButton.title == "Stop",
              "REQ-75: Actual launch transition retires loading and keeps the supported Stop action")
        await library.waitForSessionPersistence()
        check(try await store.load().first?.lastPlayedAt == library.games.first?.lastPlayedAt
              && library.games.first?.lastSessionSeconds == nil && library.continuingGame?.id == slowGame.id,
              "AC1.3/1.4: Launch start is durable before exit and drives only the imported game hero")
        check(library.runningGameID == slowGame.id,
              "A still-alive fake session transitions to Playing and duplicate Play is guarded")
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        check(lines.count == 6 && lines[0] == "2" && lines[1].range(
            of: #"^xodus-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"#, options: .regularExpression) != nil
              && lines[2] == "crossover" && lines[3] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
              && lines[4] == "crossover" && lines[5] == "unset",
              "Actual bash invocation passes the safe runID, the routed engine arg and XODUS_ENGINE, not shell interpolation")
        check(InstalledGamesController.launchEnvironment(["HOME": "/home", "USER": "fixture", "LANG": "en",
                    "PATH": "/wrong", "TOKEN": "secret"], engine: .crossover).keys.sorted()
                == ["HOME", "LANG", "PATH", "USER", "XODUS_ENGINE"],
              "Launch environment excludes unrelated secrets, overrides PATH and adds only the routed engine")
        let runtime = URL(fileURLWithPath: "/approved app/XodusPython/bin/python3")
        let runtimeEnvironment = InstalledGamesController.launchEnvironment(
            ["HOME": "/home", "PATH": "/untrusted", "PYTHONPATH": "/untrusted"], engine: .crossover,
            interpreter: runtime)
        check(runtimeEnvironment["PATH"] == "/approved app/XodusPython/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
              && runtimeEnvironment["PYTHONPATH"] == nil
              && runtimeEnvironment["PYTHONNOUSERSITE"] == "1"
              && runtimeEnvironment["PYTHONDONTWRITEBYTECODE"] == "1",
              "Admitted bundled interpreter takes precedence while preserving legacy tool PATH and excluding user modules")
        let fixedID = InstalledGamesController.runID(date: Date(timeIntervalSince1970: 0),
            nonce: UUID(uuidString: "abcdef01-2345-6789-abcd-ef0123456789")!)
        check(fixedID == "xodus-19700101T000000Z-abcdef01", "runID uses fixed UTC/POSIX date and lowercase eight-hex nonce")
        check(InstalledGamesController.sessionLog(runID: fixedID, directory: root)?.lastPathComponent ==
              "xodus-19700101T000000Z-abcdef01.stderr.log",
              "AC2.3: Log path contains only the app-generated runID and fixed stderr suffix")
        for input in ["../secret", fixedID + "/file", fixedID + "\n", "xodus-20260101T000000Z-ABCDEF00"] {
            check(InstalledGamesController.sessionLog(runID: input, directory: root) == nil,
                  "AC2.3: Arbitrary or path-bearing log runIDs are refused")
        }
        let otherFolder = root.appendingPathComponent("other fixture")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: false)
        try Data(config.utf8).write(to: otherFolder.appendingPathComponent("MicrosoftGame.config"))
        await library.importGame(folder: otherFolder, launcher: failure)
        guard let other = library.games.last else { throw InstalledGameError.invalidRegistry }
        await library.playHistoricalFixture(other)
        check(library.runningGameID == slowGame.id
              && (other.id == slowGame.id || library.playErrors[other.id]?.contains("Quit the running game") == true),
              "A second game's Play cannot overlap the running session and explains its busy state")
        let coordinator = ApplicationTerminationCoordinator()
        check(await coordinator.shutdown(session: nil, runtime: nil, installedGames: library)
              && library.applicationTerminating && library.runningGameID == slowGame.id,
              "App termination fences new launches without terminating the running game")
        try await wait { library.runningGameID == nil }
        await library.waitForSessionPersistence()
        let completedSession = try await store.load().first { $0.id == slowGame.id }
        check(completedSession?.lastSessionSeconds.map { (1.8...4).contains($0) } == true,
              "AC1.3/1.6: Session end persists measured fake-process seconds despite another game import")
        check(library.playErrors[game.id] == nil, "The fake game finishes naturally after app termination begins")
        library.applicationTerminating = false
        try FileManager.default.removeItem(at: failure)
        await library.playHistoricalFixture(other)
        check(library.runningGameID == nil && library.playErrors[other.id] == InstalledGameError.missingLauncher.localizedDescription,
              "Missing launcher fails before execution with actionable per-game error")
        await library.remove(other)
        check(!library.games.contains(other) && FileManager.default.fileExists(atPath: otherFolder.path),
              "Remove changes only the saved list and never deletes the installed game folder")
        let reloaded = InstalledGamesController(store: store)
        await reloaded.load()
        check(reloaded.games == library.games && reloaded.loaded,
              "A new app coordinator restores the durable local list without running a game")
        let windows = NSApplication.shared.windows.count
        for width in [CGFloat(700), CGFloat(1100)] {
            let host = NSHostingView(rootView: InstalledGamesView(library: reloaded,
                operations: GameOperationsController(installed: reloaded), allowsArtworkLoading: false))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 400)
            host.layoutSubtreeIfNeeded()
            check(host.window == nil && host.fittingSize.width <= width + 1,
                  "Installed rows and native actions fit detached narrow and wide layouts")
        }
        check(NSApplication.shared.windows.count == windows && reloaded.runningGameID == nil,
              "Installed layout checks create no window or launch")
        var older = game
        older.lastPlayedAt = Date(timeIntervalSince1970: 10)
        var newer = InstalledGame(id: UUID(), title: "Second Fixture", identityName: "Fixture.Second",
            version: game.version, storeId: game.storeId, folder: otherFolder.path,
            launcher: zero.path, importedAt: game.importedAt)
        newer.lastPlayedAt = Date(timeIntervalSince1970: 20)
        try await store.save([older, newer])
        let ordered = InstalledGamesController(store: store)
        await ordered.load()
        check(ordered.continuingGame?.id == newer.id, "AC1.4/1.6: Most recent imported launchable entry wins hero selection")
        newer = InstalledGame(id: newer.id, title: newer.title, identityName: newer.identityName,
            version: newer.version, storeId: newer.storeId, folder: newer.folder,
            launcher: failure.path, importedAt: newer.importedAt, lastPlayedAt: Date(timeIntervalSince1970: 30))
        try await store.save([older, newer])
        let unavailable = InstalledGamesController(store: store)
        await unavailable.load()
        check(unavailable.continuingGame?.id == older.id,
              "AC1.4: An unavailable launcher is excluded even when its recorded play is newest")
        try await store.save([older])
        let resilient = InstalledGamesController(store: store, launchingDuration: .milliseconds(100),
                                                logDirectory: root.appendingPathComponent("logs"),
                                                defaultEngine: { .crossover },
                                                detectAvailability: { RunnerAvailability([.crossover]) },
                                                compatibilityCatalogue: catalogue)
        await resilient.load()
        resilient.setAccountAccessAllowed(true)
        await resilient.importGame(folder: folder, launcher: slow)
        guard let resilientGame = resilient.games.first else { throw InstalledGameError.invalidRegistry }
        await resilient.playHistoricalFixture(resilientGame)
        await resilient.waitForSessionPersistence()
        let beforeCorruption = try Data(contentsOf: file)
        try Data("corrupt".utf8).write(to: file)
        try await wait { resilient.runningGameID == nil }
        await resilient.waitForSessionPersistence()
        check(resilient.playState == nil && resilient.playErrors[resilientGame.id] == nil
              && resilient.historyError != nil,
              "AC1.3: A history save failure never blocks termination or misreports game exit")
        try beforeCorruption.write(to: file)
        let corruptFile = root.appendingPathComponent("corrupt.json")
        try Data("not json".utf8).write(to: corruptFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptFile.path)
        let corrupt = InstalledGamesController(store: InstalledGameStore(file: corruptFile))
        await corrupt.load()
        await corrupt.importGame(folder: folder, launcher: zero)
        let retainedCorruptBytes = try Data(contentsOf: corruptFile)
        check(!corrupt.loaded && corrupt.error != nil && corrupt.games.isEmpty
              && retainedCorruptBytes == Data("not json".utf8),
              "Corrupt persistence stays a visible failure and cannot be overwritten as empty success")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let exposed = InstalledGamesController(store: store)
        await exposed.load()
        check(!exposed.loaded && exposed.error != nil,
              "Nonprivate saved-list permissions are refused instead of silently trusting exposed paths")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let alias = root.appendingPathComponent("aliased-list.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let aliased = InstalledGamesController(store: InstalledGameStore(file: alias))
        await aliased.load()
        check(!aliased.loaded && aliased.error != nil, "Saved-list symlinks are refused without following or replacing their target")

        // M1 + M3 integration: detection is backfilled and persisted, a per-game
        // override survives relaunch, and a selected-but-missing engine refuses launch.
        let routingRoot = root.appendingPathComponent("routing")
        try FileManager.default.createDirectory(at: routingRoot, withIntermediateDirectories: false)
        let routingFolder = routingRoot.appendingPathComponent("routed game")
        try FileManager.default.createDirectory(at: routingFolder, withIntermediateDirectories: false)
        try Data(config.utf8).write(to: routingFolder.appendingPathComponent("MicrosoftGame.config"))
        check(try PackageInspector.detect(folder: routingFolder) == .unknown,
              "M1: GDK config alone never claims MSIXVC container evidence")
        var containerHeader = Data(repeating: 0, count: 4096)
        containerHeader.replaceSubrange(0x200..<0x208, with: Data("msft-xvd".utf8))
        let container = routingFolder.appendingPathComponent(".xodus-streaming.msixvc")
        try containerHeader.write(to: container)
        let misleadingFolder = routingRoot.appendingPathComponent("nonfiles")
        try FileManager.default.createDirectory(at: misleadingFolder, withIntermediateDirectories: false)
        for name in ["game.exe", "game.eappx", "MicrosoftGame.config", "AppxManifest.xml", "game.msixvc"] {
            try FileManager.default.createDirectory(at: misleadingFolder.appendingPathComponent(name),
                                                    withIntermediateDirectories: false)
        }
        check(try PackageInspector.detect(folder: misleadingFolder) == .unknown,
              "M1: Directories named after evidence files do not establish a format")
        try FileManager.default.createSymbolicLink(at: misleadingFolder.appendingPathComponent("linked.msixvc"),
                                                  withDestinationURL: container)
        check(try PackageInspector.detect(folder: misleadingFolder) == .unknown,
              "M1: Symlinked external evidence is ignored")
        let malformed = misleadingFolder.appendingPathComponent("broken.exe")
        try Data("not a PE file".utf8).write(to: malformed)
        check(try PackageInspector.detect(folder: misleadingFolder) == .unknown,
              "M1: An executable extension without PE bytes is not Win32 evidence")
        let routingLauncher = try script("routing launch.sh", "exit 0")
        let registeredRunner = try script("registered-gptk4-runner", "exit 0")
        let declaredPaths: [RuntimeProviderKind: String] = [.gptk4: registeredRunner.path]
        let observed = RunnerAvailabilityDetector.detect(crossOver: .absent, runnerPaths: declaredPaths)
        check(observed == RunnerAvailability([.gptk4]),
              "M3: An independently registered executable is observed without a global default")
        let suiteName = "Xodus.EngineChecks.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else { throw InstalledGameError.storage }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(registeredRunner.path, forKey: "Xodus.developerBackendPath")
        EngineDefaults.setDefaultEngine(.gptk3, preferences)
        check(RunnerAvailabilityDetector.detect(crossOver: .absent,
                    runnerPaths: EngineDefaults.runnerPaths(preferences)).installed.isEmpty,
              "M3: An executable management backend never fabricates a GPTK installation")
        EngineDefaults.setRunnerPath(registeredRunner.path, for: .gptk4, defaults: preferences)
        check(EngineDefaults.defaultEngine(preferences) == .gptk3
              && EngineDefaults.runnerPaths(preferences)[.gptk4] == registeredRunner.path
              && RunnerAvailabilityDetector.detect(crossOver: .absent,
                    runnerPaths: EngineDefaults.runnerPaths(preferences)) == observed,
              "M3: Per-provider paths persist independently of a different global default")
        EngineDefaults.setCrossOverApplication("/synthetic/CrossOver.app", defaults: preferences)
        EngineDefaults.setPrefixPath("/synthetic/bottle", for: .gptk4, defaults: preferences)
        check(EngineDefaults.crossOverApplication(preferences) == "/synthetic/CrossOver.app"
              && EngineDefaults.prefixPath(.gptk4, defaults: preferences) == "/synthetic/bottle"
              && EngineDefaults.prefixPath(.standaloneWine, defaults: preferences) == nil,
              "Runtime app and per-provider bottle choices persist independently without rewriting a bottle")
        EngineDefaults.setCrossOverApplication(nil, defaults: preferences)
        EngineDefaults.setPrefixPath(nil, for: .gptk4, defaults: preferences)
        check(EngineDefaults.crossOverApplication(preferences) == nil
              && EngineDefaults.prefixPath(.gptk4, defaults: preferences) == nil,
              "Clearing runtime preferences removes only the saved selection")
        check(RunnerAvailabilityDetector.executable(in: registeredRunner) == registeredRunner
              && RunnerAvailabilityDetector.executable(in: routingFolder) == nil
              && !RunnerAvailabilityDetector.isPrefix(routingFolder),
              "An actual chosen executable resolves; an unrelated folder is not a runtime or bottle")
        check(RunnerAvailabilityDetector.detect(crossOver: .absent,
                    runnerPaths: [.gptk3: routingFolder.path, .standaloneWine: "relative/wine"]).installed.isEmpty,
              "M3: Directories and relative runner paths are not observed as available")
        check(EngineRouting.decide(.init(packageType: .win32, override: .gptk4, defaultEngine: .crossover,
                    availability: observed)) == .routed(.gptk4, .perGameOverride),
              "M3: A non-default Experimental override routes when its own executable is present")
        let routingFile = routingRoot.appendingPathComponent("private/routing-list.json")
        let routingStore = InstalledGameStore(file: routingFile)
        let routing = InstalledGamesController(store: routingStore, launchingDuration: .milliseconds(100),
            logDirectory: routingRoot, defaultEngine: { nil },
            detectAvailability: { RunnerAvailability([.crossover]) }, compatibilityCatalogue: catalogue)
        await routing.load()
        routing.setAccountAccessAllowed(true)
        await routing.importGame(folder: routingFolder, launcher: routingLauncher)
        guard let routed = routing.games.first else { throw InstalledGameError.invalidRegistry }
        check(routed.packageType == .msixvc,
              "M1: MSIXVC classification requires actual container-header evidence")
        check(try await InstalledGameStore(file: routingFile).load().first?.packageType == .msixvc,
              "M1: Detected package type is persisted to the private registry, not recomputed as a label")
        await routing.setEngineOverride(.gptk4, for: routed)
        check(routing.games.first?.engineOverride == .gptk4, "M3: A per-game engine override is applied")
        check(try await InstalledGameStore(file: routingFile).load().first?.engineOverride == .gptk4,
              "M3: A per-game engine override persists across relaunch")
        guard let overridden = routing.games.first else { throw InstalledGameError.invalidRegistry }
        await routing.playHistoricalFixture(overridden)
        try await wait { routing.runningGameID == nil }
        check(routing.playErrors[overridden.id]?.contains("isn't installed") == true,
              "M3: An override whose engine is not installed refuses launch, never substituting another runner")
        await routing.setEngineOverride(nil, for: overridden)
        guard let cleared = routing.games.first else { throw InstalledGameError.invalidRegistry }
        await routing.play(cleared)
        try await wait { routing.runningGameID == nil }
        // REQ114 B2: the refusal keeps its specific cause rather than the generic launch copy.
        check(routing.playErrors[cleared.id] == NativeLaunchError.providerPolicy.localizedDescription,
              "REQ95 clearing an override without a configured default refuses instead of silently launching CrossOver")
        await routing.waitForSessionPersistence()
        await routing.setEngineOverride(.gptk4, for: cleared)
        try FileManager.default.removeItem(at: container)
        var peHeader = Data(repeating: 0, count: 128)
        peHeader.replaceSubrange(0..<2, with: Data([0x4d, 0x5a]))
        peHeader[0x3c] = 64
        peHeader.replaceSubrange(64..<68, with: Data([0x50, 0x45, 0, 0]))
        try peHeader.write(to: routingFolder.appendingPathComponent("game.exe"))
        let placeholder = routingFolder.appendingPathComponent("partial.eappx")
        try Data().write(to: placeholder)
        check(try PackageInspector.detect(folder: routingFolder) == .win32,
              "M1: Empty encrypted-download placeholders cannot override verified PE evidence")
        try Data("unrelated data".utf8).write(to: placeholder)
        check(try PackageInspector.detect(folder: routingFolder) == .win32,
              "M1: A filename without encrypted-header content cannot override verified PE evidence")
        try FileManager.default.removeItem(at: placeholder)
        await routing.importGame(folder: routingFolder, launcher: routingLauncher)
        check(routing.games.first?.packageType == .win32 && routing.games.first?.engineOverride == .gptk4,
              "M1/M3: Reimport refreshes changed package facts without dropping the user's override")
        let disconnected = routingRoot.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: routingFolder, to: disconnected)
        let offline = InstalledGamesController(store: routingStore, defaultEngine: { nil },
            detectAvailability: { RunnerAvailability([.crossover]) })
        await offline.load()
        check(offline.packageErrors[routed.id] != nil && offline.games.first?.packageType == .win32,
              "M1: An unavailable folder exposes an observation error without overwriting saved evidence")
        try FileManager.default.moveItem(at: disconnected, to: routingFolder)
        try containerHeader.write(to: container)
        await offline.importGame(folder: routingFolder, launcher: routingLauncher)
        check(offline.packageErrors[routed.id] == nil && offline.games.first?.packageType == .msixvc
              && offline.games.first?.engineOverride == .gptk4,
              "M1/M3: Reconnecting and reimporting refreshes evidence and retains the override")
        let selectorRecord = routingRoot.appendingPathComponent("selected-engine.txt")
        let selectorLauncher = try script("selector-launch.sh", "printf '%s\\n' \"$2\" > '\(selectorRecord.path)'")
        let nonDefault = InstalledGamesController(store: routingStore, defaultEngine: { .crossover },
            detectAvailability: {
                RunnerAvailabilityDetector.detect(crossOver: .absent, runnerPaths: declaredPaths)
            }, compatibilityCatalogue: catalogue)
        await nonDefault.load()
        nonDefault.setAccountAccessAllowed(true)
        await nonDefault.importGame(folder: routingFolder, launcher: selectorLauncher)
        guard let selected = nonDefault.games.first else { throw InstalledGameError.invalidRegistry }
        await nonDefault.playHistoricalFixture(selected)
        try await wait { nonDefault.runningGameID == nil }
        await nonDefault.waitForSessionPersistence()
        let recordedSelector = try String(contentsOf: selectorRecord, encoding: .utf8)
        check(nonDefault.playErrors[selected.id] == nil
              && recordedSelector == "gptk4\n",
              "M3: Observed non-default override reaches the launch script, not only the pure decision")
        let uiState = AppState()
        let uiSession = LiveSession()
        let uiOperations = GameOperationsController(installed: nonDefault)
        let liveLibrary = NSHostingView(rootView: LiveLibraryView(library: uiState.pcGames,
            installed: nonDefault, operations: uiOperations, query: "",
            allowsStartupTasks: false, allowsArtworkLoading: false, allowsHeroAnimation: false,
            browse: {}, recentActivity: {}).environmentObject(uiSession))
        liveLibrary.sizingOptions = []
        liveLibrary.frame = CGRect(x: 0, y: 0, width: 820, height: 874)
        liveLibrary.layoutSubtreeIfNeeded()
        check(liveLibrary.window == nil && uiSession.phase == .disconnected && !uiOperations.isBusy,
              "M1/M3: The real live Library lays out a detected installation and override without network or process startup")
        let interleaving = PackageInspectionInterleaving()
        let concurrent = InstalledGamesController(store: routingStore, defaultEngine: { nil },
            detectAvailability: { RunnerAvailability([.gptk4]) },
            inspectPackage: { try interleaving.inspect($0) })
        let suspendedLoad = Task { await concurrent.load() }
        defer { interleaving.release() }
        try await wait { interleaving.isWaiting }
        await concurrent.importGame(folder: routingFolder, launcher: selectorLauncher)
        check(concurrent.games.first?.packageType == .msixvc,
              "M1: A new reimport observation completes while the old load observation is suspended")
        interleaving.release()
        await suspendedLoad.value
        let afterConcurrentImport = try await routingStore.load()
        check(concurrent.games.first?.packageType == .msixvc
              && concurrent.packageErrors[routed.id] == nil
              && concurrent.launchableIDs.contains(routed.id)
              && afterConcurrentImport.first?.packageType == .msixvc,
              "M1: Superseded observations cannot overwrite newer format, errors, launchability or persisted facts")
    }
}

@MainActor
private final class DiscoveryCompletenessFixture {
    var slow = false
    var timeout = false

    func check() async throws -> Bool {
        if timeout { throw GameScriptError.timeout }
        if slow { try await Task.sleep(for: .seconds(60)) }
        return false
    }
}

private final class PackageInspectionInterleaving: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var first = true
    private var waiting = false

    init(initiallyArmed: Bool = true) { first = initiallyArmed }

    func arm() {
        lock.lock()
        first = true
        lock.unlock()
    }

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting
    }

    func inspect(_ folder: URL) throws -> PackageType {
        lock.lock()
        let suspend = first
        first = false
        if suspend { waiting = true }
        lock.unlock()
        if suspend {
            guard resume.wait(timeout: .now() + 10) == .success else { throw InstalledGameError.invalidConfig }
            return .win32
        }
        return try PackageInspector.detect(folder: folder)
    }

    func release() { resume.signal() }
}
