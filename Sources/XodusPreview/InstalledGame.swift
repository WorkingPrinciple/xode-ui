// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusCore

struct InstalledGame: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let identityName: String
    let version: String
    let storeId: String
    let folder: String
    let launcher: String
    let importedAt: Date
    var publisher: String? = nil
    var lastPlayedAt: Date? = nil
    var lastSessionSeconds: Double? = nil
    /// Detected on-disk package format (M1). Optional so pre-M1 registries decode
    /// unchanged; it is backfilled from file evidence after load, never invented.
    var packageType: PackageType? = nil
    /// Historical choices are preserved, but current launches read only V2.
    var engineOverride: RuntimeProviderKind? = nil
    var engineSelection: AdmittedEngineSelection? = nil
    var engineOverrideV2: GameEngineOverride? = nil
    var usesNativeLifecycle: Bool? = nil
    var storageVolume: GameStorageVolume? = nil
}

struct GameEngineOverride: Codable, Equatable, Sendable {
    let version: Int
    let selection: AdmittedEngineSelection
    let chosenAt: Date

    init(selection: AdmittedEngineSelection, chosenAt: Date = Date()) {
        version = 2
        self.selection = selection
        self.chosenAt = chosenAt
    }
}

enum InstalledGameError: Error, LocalizedError, Equatable {
    case invalidConfig, missingFolder, folderPermission, folderUnavailable, missingLauncher, placeholderContent, invalidRegistry, storage, launch
    /// macOS privacy (EPERM) blocked a folder in a protected place; fixed in System Settings, not Finder.
    case folderPrivacy(PrivacyPermission)

    var errorDescription: String? {
        switch self {
        case .invalidConfig: "This folder doesn't contain a valid MicrosoftGame.config. Choose the installed Xbox game folder."
        case .missingFolder: "The game folder is no longer available. Reconnect its drive or import the game again."
        case .folderUnavailable: "The installation couldn't be checked. Try again."
        case .folderPermission: "\(AppBrand.displayName) doesn't have permission to read this folder. Check the folder's permissions, then try again."
        case .missingLauncher: "The launch script is missing or isn't an executable file. Import the game again to choose its script."
        case .placeholderContent: "This installation contains only Minecraft's placeholder, not a playable game. Install the full Minecraft Launcher package before playing. Signing in again won't replace these files."
        case .invalidRegistry: "The installed games list couldn't be read. Your game files haven't been changed."
        case .storage: "The installed games list couldn't be saved. Check access to Application Support and try again."
        case .launch: "The game couldn't start. Check its launch script and try again."
        case .folderPrivacy(let permission): PrivacyDenial.installFolderProblem(.privacyDenied(permission), fallback: "").message
        }
    }
}

struct MicrosoftGameConfig: Equatable, Sendable {
    let identityName: String
    let version: String
    let storeId: String
    let title: String
    let publisher: String?
    let tileArt: [String]
    let splashArt: String?
    var executables: [String] = []

    var placeholderOnly: Bool {
        !executables.isEmpty && executables.allSatisfy {
            $0.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last?.lowercased()
                == "mcplaceholderstub.exe"
        }
    }

    static func read(folder: URL) throws -> Self {
        try InstalledGameFiles.checkFolder(folder)
        guard let file = try configurationFile(in: folder) else { throw InstalledGameError.invalidConfig }
        let data: Data
        do { data = try InstalledGameFiles.readRegular(file, maximumBytes: 1_048_576) }
        catch { throw InstalledGameError.invalidConfig }
        return try parse(data)
    }

    static func configurationFile(in folder: URL) throws -> URL? {
        let matches: [URL]
        do {
            matches = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch { throw InstalledGameError.invalidConfig }
        return try configurationFile(in: matches)
    }

    static func configurationFile(in entries: [URL]) throws -> URL? {
        let matches = entries.filter { $0.lastPathComponent.lowercased() == "microsoftgame.config" }
        guard matches.count <= 1 else { throw InstalledGameError.invalidConfig }
        return matches.first
    }

    static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw InstalledGameError.invalidConfig }
        let reader = ConfigReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, reader.root == "Game",
              let identity = reader.identity, let version = reader.version,
              let storeId = reader.storeId, !storeId.isEmpty,
              !identity.isEmpty, !version.isEmpty else { throw InstalledGameError.invalidConfig }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && UInt16($0) != nil
        }), [identity, storeId, reader.title ?? ""].allSatisfy({
            $0.count <= 512 && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }) else { throw InstalledGameError.invalidConfig }
        return Self(identityName: identity, version: version, storeId: storeId,
                    title: reader.title.flatMap { $0.isEmpty ? nil : $0 } ?? identity,
                    publisher: reader.visuals["PublisherDisplayName"].flatMap {
                        $0.isEmpty || $0.count > 512 || $0.unicodeScalars.contains(where: {
                            CharacterSet.controlCharacters.contains($0)
                        }) ? nil : $0
                    },
                    tileArt: ["Square480x480Logo", "Square150x150Logo", "StoreLogo"].compactMap {
                        reader.visuals[$0]
                    }, splashArt: reader.visuals["SplashScreenImage"], executables: reader.executables)
    }
}

private final class ConfigReader: NSObject, XMLParserDelegate {
    var root: String?
    var identity: String?
    var version: String?
    var title: String?
    var storeId: String?
    var invalid = false
    var visuals: [String: String] = [:]
    var executables: [String] = []
    private var path: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        path.append(elementName)
        guard path.count <= 32 else { invalid = true; parser.abortParsing(); return }
        if path.count == 1 { root = elementName }
        if path == ["Game", "Identity"] {
            if identity != nil { invalid = true }
            identity = attributes["Name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            version = attributes["Version"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if path == ["Game", "ShellVisuals"] {
            if !visuals.isEmpty { invalid = true }
            visuals = attributes
            title = attributes["DefaultDisplayName"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if path == ["Game", "StoreId"] { text = "" }
        if path == ["Game", "ExecutableList", "Executable"], let name = attributes["Name"] {
            executables.append(name)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if path == ["Game", "StoreId"] { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if path == ["Game", "StoreId"] {
            if storeId != nil { invalid = true }
            storeId = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        path.removeLast()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        invalid = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) {
        invalid = true
        parser.abortParsing()
    }
}

enum InstalledGameFiles {
    static func checkPlayableContent(_ folder: URL) throws {
        if try MicrosoftGameConfig.read(folder: folder).placeholderOnly {
            throw InstalledGameError.placeholderContent
        }
    }

    static func checkFolder(_ url: URL) throws {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isDirectoryKey]) }
        catch { throw folderReadError(error as NSError, path: url.path) }
        guard url.isFileURL, values.isDirectory == true else { throw InstalledGameError.missingFolder }
    }

    /// With a path, EPERM in a protected place becomes a privacy denial; EACCES stays ordinary permissions.
    static func folderReadError(_ error: NSError, path: String? = nil) -> InstalledGameError {
        if let path, case .privacyDenied(let permission?) = PrivacyDenial.classify(error, path: path) {
            return .folderPrivacy(permission)
        }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return .folderPermission }
        if error.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(error.code) { return .folderPermission }
        if error.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return .missingFolder }
        if error.domain == NSPOSIXErrorDomain, [Int(ENOENT), Int(ENOTDIR)].contains(error.code) { return .missingFolder }
        return .folderUnavailable
    }

    static func checkLauncher(_ url: URL) throws {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw InstalledGameError.missingLauncher
        }
    }

    static func readRegular(_ url: URL, maximumBytes: Int, privateFile: Bool = false) throws -> Data {
        // O_NONBLOCK keeps a FIFO from blocking open(); fstat below still requires a regular file.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw InstalledGameError.invalidRegistry }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { handle.closeFile() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes,
              !privateFile || (info.st_uid == getuid() && info.st_mode & 0o777 == 0o600),
              let data = try handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else {
            throw InstalledGameError.invalidRegistry
        }
        return data
    }
}

actor InstalledGameStore {
    static var defaultFile: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Xodus/installed-games.json")
    }
    let file: URL

    init(file: URL = InstalledGameStore.defaultFile) { self.file = file }

    func load() throws -> [InstalledGame] {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw InstalledGameError.invalidRegistry }
            return []
        }
        let data = try InstalledGameFiles.readRegular(file, maximumBytes: 1_048_576, privateFile: true)
        let games = try JSONDecoder().decode([InstalledGame].self, from: data)
        guard Set(games.map(\.id)).count == games.count, Set(games.map(\.folder)).count == games.count,
              games.allSatisfy({ !$0.title.isEmpty && !$0.identityName.isEmpty && !$0.version.isEmpty
                  && !$0.storeId.isEmpty && $0.folder.hasPrefix("/")
                  && ($0.usesNativeLifecycle == true ? $0.launcher.isEmpty : $0.launcher.hasPrefix("/"))
                  && ($0.lastSessionSeconds.map { $0.isFinite && $0 >= 0 } ?? true)
                  && ($0.lastPlayedAt.map { $0.timeIntervalSince1970.isFinite } ?? true) }) else {
            throw InstalledGameError.invalidRegistry
        }
        return games.map { game in
            guard let volume = game.storageVolume, !volume.contains(game.folder) else { return game }
            var entry = game
            // Discard only the invalid hint; readiness still requires fresh exact-folder checks.
            entry.storageVolume = nil
            return entry
        }
    }

    func save(_ games: [InstalledGame]) throws {
        guard games.allSatisfy({ $0.storageVolume?.contains($0.folder) ?? true }) else {
            throw InstalledGameError.invalidRegistry
        }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else { throw InstalledGameError.storage }
        let data = try JSONEncoder().encode(games)
        guard data.count <= 1_048_576 else { throw InstalledGameError.storage }
        let temporary = directory.appendingPathComponent(".installed-games-\(UUID().uuidString).json")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw InstalledGameError.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard fsync(descriptor) == 0 else { throw InstalledGameError.storage }
            try handle.close()
            guard rename(temporary.path, file.path) == 0 else { throw InstalledGameError.storage }
        } catch {
            handle.closeFile()
            if unlink(temporary.path) != 0 && errno != ENOENT {
                throw InstalledGameError.storage
            }
            throw error
        }
    }

    func upsert(_ game: InstalledGame) throws -> [InstalledGame] {
        var games = try load()
        var updated = game
        if let previous = games.first(where: { $0.id == game.id }) {
            updated.lastPlayedAt = previous.lastPlayedAt
            updated.lastSessionSeconds = previous.lastSessionSeconds
            updated.packageType = game.packageType ?? previous.packageType
            updated.engineOverride = game.engineOverride ?? previous.engineOverride
            updated.engineSelection = game.engineSelection ?? previous.engineSelection
            updated.engineOverrideV2 = game.engineOverrideV2 ?? previous.engineOverrideV2
            updated.storageVolume = game.storageVolume ?? previous.storageVolume
        }
        for previous in games where previous.folder == game.folder && previous.id != game.id {
            try rememberPrefixInstallation(previous)
        }
        games.removeAll { $0.folder == game.folder }
        games.append(updated)
        try save(games)
        return games
    }

    func remove(id: UUID) throws -> [InstalledGame] {
        var games = try load()
        if let game = games.first(where: { $0.id == id }) { try rememberPrefixInstallation(game) }
        games.removeAll { $0.id == id }
        try save(games)
        return games
    }

    func prefixInstallationIDs(productID: String) throws -> [UUID] {
        try prefixIdentities()[productID] ?? []
    }

    private func prefixIdentities() throws -> [String: [UUID]] {
        let history = file.appendingPathExtension("prefix-identities-v1.json")
        var info = stat()
        if lstat(history.path, &info) != 0 {
            guard errno == ENOENT else { throw InstalledGameError.invalidRegistry }
            return [:]
        }
        let bytes = try InstalledGameFiles.readRegular(history, maximumBytes: 1_048_576, privateFile: true)
        let records = try JSONDecoder().decode([String: [UUID]].self, from: bytes)
        guard records.count <= 1024, records.allSatisfy({
            PCGamesClient.validProductID($0.key) && $0.value.count <= 64
                && Set($0.value).count == $0.value.count
        }) else { throw InstalledGameError.invalidRegistry }
        return records
    }

    private func rememberPrefixInstallation(_ game: InstalledGame) throws {
        guard PCGamesClient.validProductID(game.storeId) else { return }
        var records = try prefixIdentities()
        var ids = records[game.storeId] ?? []
        if !ids.contains(game.id) { ids.append(game.id) }
        guard ids.count <= 64, records.count < 1024 || records[game.storeId] != nil else {
            throw InstalledGameError.invalidRegistry
        }
        records[game.storeId] = ids
        try GameScriptFiles.writePrivate(JSONEncoder().encode(records),
            to: file.appendingPathExtension("prefix-identities-v1.json"))
    }

    func recordSession(id: UUID, startedAt: Date, seconds: Double?) throws {
        var games = try load()
        guard let index = games.firstIndex(where: { $0.id == id }),
              games[index].lastPlayedAt.map({ $0 <= startedAt }) ?? true else { return }
        games[index].lastPlayedAt = startedAt
        games[index].lastSessionSeconds = seconds
        try save(games)
    }

    /// Persist the detected package format. Returns the saved list, or the current
    /// list unchanged when the value already matches, so backfill is idempotent.
    func recordPackageType(id: UUID, type: PackageType, observedAtImport: Date? = nil) throws -> [InstalledGame] {
        var games = try load()
        guard type != .unknown,
              let index = games.firstIndex(where: { $0.id == id }), games[index].packageType != type else {
            return games
        }
        if let observedAtImport, games[index].importedAt != observedAtImport { return games }
        games[index].packageType = type
        try save(games)
        return games
    }

    func recordStorageVolume(id: UUID, volume: GameStorageVolume, observedAtImport: Date) throws -> [InstalledGame] {
        var games = try load()
        guard let index = games.firstIndex(where: { $0.id == id }),
              games[index].importedAt == observedAtImport,
              games[index].storageVolume != volume else { return games }
        guard volume.contains(games[index].folder) else { throw InstalledGameError.invalidRegistry }
        games[index].storageVolume = volume
        try save(games)
        return games
    }

    /// Persist a per-game engine override (or clear it with `nil`).
    func setEngineOverride(id: UUID, override: RuntimeProviderKind?,
                           selection: AdmittedEngineSelection? = nil) throws -> [InstalledGame] {
        var games = try load()
        guard let index = games.firstIndex(where: { $0.id == id }) else { return games }
        if override == .calimocho {
            guard let selection, let engine = selection.inspection.engineName,
                  let digest = selection.inspection.registrySha256 else { throw NativeLaunchError.engineNotSelected }
            try selection.validate(registryPath: selection.registryPath, engineName: engine, registryDigest: digest)
        }
        games[index].engineOverride = override
        games[index].engineSelection = override == .calimocho ? selection : nil
        try save(games)
        return games
    }

    func setEngineOverrideV2(id: UUID, selection: AdmittedEngineSelection?) throws -> [InstalledGame] {
        var games = try load()
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw InstalledGameError.invalidRegistry }
        if let selection {
            guard let name = selection.inspection.engineName,
                  let digest = selection.inspection.registrySha256 else { throw NativeLaunchError.engineUnavailable }
            try selection.validate(registryPath: selection.registryPath, engineName: name, registryDigest: digest)
        }
        games[index].engineOverrideV2 = selection.map { GameEngineOverride(selection: $0) }
        try save(games)
        return games
    }

    func retargetCalimochoTitles(_ selection: AdmittedEngineSelection, replacing oldEngine: String) throws -> [InstalledGame] {
        var games = try load()
        for index in games.indices where ["9P9VNSQK1W3K", "9NMNMS626R59"].contains(games[index].storeId) {
            let legacyMatches = games[index].engineOverride == .calimocho
                && games[index].engineSelection?.inspection.admittedProvider == "calimocho"
                && games[index].engineSelection?.inspection.engineName == oldEngine
            let currentMatches = games[index].engineOverrideV2?.selection.inspection.admittedProvider == "calimocho"
                && games[index].engineOverrideV2?.selection.inspection.engineName == oldEngine
                && (games[index].engineOverride == nil || games[index].engineOverride == .calimocho)
            if legacyMatches || currentMatches {
                try NativeLaunchConfiguration.validateOverride(selection, game: games[index])
            }
            if legacyMatches { games[index].engineSelection = selection }
            if currentMatches { games[index].engineOverrideV2 = GameEngineOverride(selection: selection) }
        }
        try save(games)
        return games
    }
}
