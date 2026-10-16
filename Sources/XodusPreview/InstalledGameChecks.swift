// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import Foundation
import ImageIO
import SwiftUI
import XodusCore

@MainActor
enum InstalledGameChecks {
    static func run(check: (Bool, String) -> Void) async throws {
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
        for xml in ["", "<Game>", "<Other/>", config.replacingOccurrences(of: "Version=\"1.2.3.4\"", with: ""),
                    config.replacingOccurrences(of: "<StoreId>FIXTURE00001</StoreId>", with: ""),
                    config.replacingOccurrences(of: "1.2.3.4", with: "not-a-version"),
                    "<!DOCTYPE Game [<!ENTITY title 'unexpected'>]><Game>&title;</Game>"] {
            do { _ = try MicrosoftGameConfig.parse(Data(xml.utf8)); check(false, "Invalid installed config is refused") }
            catch { check(error is InstalledGameError, "Invalid installed config is refused") }
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("InstalledGameChecks-\(UUID().uuidString)")
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
                                               defaultEngine: { nil },
                                               detectAvailability: { RunnerAvailability([.crossover]) })
        await library.load()
        check(library.loaded && library.games.isEmpty && library.error == nil,
              "Absent private list loads as empty without importing or scanning games")
        await library.importGame(folder: folder, launcher: zero)
        guard let game = library.games.first else { throw InstalledGameError.invalidRegistry }
        NativeUIChecks.checkWelcomePrivacy(installed: library, check: check)
        check(game.publisher == "Fixture Publisher" && game.lastPlayedAt == nil && library.continuingGame == nil,
              "AC1.2/1.4: Import stores publisher but never invents a played session or hero")
        check(game.title == metadata.title && game.identityName == metadata.identityName
              && game.version == metadata.version && game.storeId == metadata.storeId
              && game.folder == folder.path && game.launcher == zero.path,
              "Explicit selected folder and launcher persist only their imported identity")
        check(try await store.load() == [game], "Private installed-game JSON round-trips exact fields")
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
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw InstalledGameError.launch }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        await library.play(failedGame)
        try await wait { library.runningGameID == nil }
        await library.waitForSessionPersistence()
        let failedSession = try await store.load().first
        check(failedSession?.lastPlayedAt != nil && failedSession?.lastSessionSeconds.map { $0 >= 0 } == true,
              "AC1.3: A short-lived Xodus-launched failure records its start and measured lifetime atomically")
        check(library.playErrors[game.id] == "The game stopped unexpectedly (code 3)." && library.playState == nil,
              "Nonzero fake session exit returns to Play with exact code and retry message")
        check(library.playLogs[game.id] == nil, "AC2.3: A nonzero session without its stderr file offers no Show log")
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        let loggedFailure = try script("logged failure.sh",
            "printf 'neutral launch error\\n' > '\(logs.path)/'\"$1\"'.stderr.log'\nexit 3")
        await library.importGame(folder: folder, launcher: loggedFailure)
        guard let loggedGame = library.games.first else { throw InstalledGameError.invalidRegistry }
        await library.play(loggedGame)
        try await wait { library.playLogs[game.id] != nil }
        check(library.playLogs[game.id]?.deletingLastPathComponent().path == logs.path
              && library.playErrors[game.id] == "The game stopped unexpectedly (code 3).",
              "AC2.3: Nonzero script exit exposes only its existing generated-session stderr file")
        await library.waitForSessionPersistence()
        await library.importGame(folder: folder, launcher: zero)
        guard let zeroGame = library.games.first else { throw InstalledGameError.invalidRegistry }
        await library.play(zeroGame)
        try await wait { library.runningGameID == nil }
        check(library.playErrors[game.id] == nil && library.playState == nil,
              "Retry's exit zero returns silently to Play without stale failure")
        check(library.playLogs[game.id] == nil, "AC2.3: Retry clears the previous session log action")
        await library.importGame(folder: folder, launcher: slow)
        guard let slowGame = library.games.first else { throw InstalledGameError.invalidRegistry }
        await library.play(slowGame)
        check(library.playState == .launching && library.runningGameID == slowGame.id,
              "A live fake launcher first publishes Launching")
        await library.play(slowGame)
        try await wait { library.playState == .playing }
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
        await library.play(other)
        check(library.runningGameID == slowGame.id && library.playErrors[other.id] == nil,
              "A second game's Play cannot overlap the running session")
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
        await library.play(other)
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
                                                defaultEngine: { nil },
                                                detectAvailability: { RunnerAvailability([.crossover]) })
        await resilient.load()
        await resilient.importGame(folder: folder, launcher: slow)
        guard let resilientGame = resilient.games.first else { throw InstalledGameError.invalidRegistry }
        await resilient.play(resilientGame)
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
            detectAvailability: { RunnerAvailability([.crossover]) })
        await routing.load()
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
        await routing.play(overridden)
        try await wait { routing.runningGameID == nil }
        check(routing.playErrors[overridden.id]?.contains("isn't installed") == true,
              "M3: An override whose engine is not installed refuses launch, never substituting another runner")
        await routing.setEngineOverride(nil, for: overridden)
        guard let cleared = routing.games.first else { throw InstalledGameError.invalidRegistry }
        await routing.play(cleared)
        try await wait { routing.runningGameID == nil }
        check(routing.playErrors[cleared.id] == nil,
              "M3: Clearing the override falls back to an installed runner and launches")
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
            })
        await nonDefault.load()
        await nonDefault.importGame(folder: routingFolder, launcher: selectorLauncher)
        guard let selected = nonDefault.games.first else { throw InstalledGameError.invalidRegistry }
        await nonDefault.play(selected)
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

private final class PackageInspectionInterleaving: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var first = true
    private var waiting = false

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
