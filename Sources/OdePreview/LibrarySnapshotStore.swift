// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OSLog
import OdeManagement

/// REQ-119: the last library this Mac showed for one account, so a warm launch draws it at once while the
/// account is read again in the background. It holds only what the library already displayed (public product
/// IDs, titles, artwork references, acquisition kind and counts) bound to the account hash and catalogue
/// scope; never tokens, raw account IDs or entitlement proof. A restored copy is never current access.
/// Sign-out removes it.
struct SavedLibrary: Codable, Equatable, Sendable {
    struct Game: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let artwork: CatalogArtworkReference?
        let acquisitionKind: PCGameAcquisitionKind
    }
    static let schemaVersion = 1
    static let maximumGames = 5_000
    let schema: Int
    let accountHash: String
    let market: String
    let language: String
    let savedAt: Date
    let games: [Game]
    let excludedCount: Int
    let unresolvedIDs: [String]
    let unresolvedCount: Int
    let detailFailureCount: Int

    init?(_ snapshot: PCGamesSnapshot, accountHash: String, market: String, language: String, savedAt: Date) {
        guard !accountHash.isEmpty, !snapshot.games.isEmpty, snapshot.games.count <= Self.maximumGames,
              snapshot.games.allSatisfy({ PCGamesClient.validProductID($0.id) }) else { return nil }
        schema = Self.schemaVersion
        self.accountHash = accountHash
        self.market = market
        self.language = language
        self.savedAt = savedAt
        games = snapshot.games.map {
            Game(id: $0.id, title: $0.title, artwork: $0.artwork, acquisitionKind: $0.acquisitionKind)
        }
        excludedCount = snapshot.excludedCount
        unresolvedIDs = snapshot.unresolvedIDs.sorted()
        unresolvedCount = snapshot.unresolvedCount
        detailFailureCount = snapshot.detailFailureCount
    }

    func matches(accountHash: String?, market: String, language: String) -> Bool {
        schema == Self.schemaVersion && accountHash == self.accountHash && market == self.market
            && language == self.language
    }

    /// The saved library as a snapshot bound to this account; marked restored so it never claims current access.
    func snapshot() -> PCGamesSnapshot {
        PCGamesSnapshot(games: games.map {
                PCGame(id: $0.id, title: $0.title, artwork: $0.artwork, acquisitionKind: $0.acquisitionKind)
            },
            excludedCount: excludedCount, updatedAt: savedAt, boundAccountHash: accountHash,
            unresolvedIDs: Set(unresolvedIDs), unresolvedCount: unresolvedCount,
            detailFailureCount: detailFailureCount, restored: true)
    }
}

/// One private file holding the most recent account's saved library; written atomically with owner-only access.
final class LibrarySnapshotStore: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.workingprinciple.xode", category: "pc-library")

    init(file: URL) { self.file = file }

    /// The app's copy, only for an interactive or game-launch run; checks and previews stay isolated.
    static let production: LibrarySnapshotStore? = {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || GameLaunchArguments.parse(arguments) != nil else { return nil }
        return LibrarySnapshotStore(file: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Ode to X/LibrarySnapshot/library-v1.plist"))
    }()

    func load(accountHash: String?, market: String, language: String) -> SavedLibrary? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file), data.count <= 8 * 1024 * 1024,
              let saved = try? PropertyListDecoder().decode(SavedLibrary.self, from: data),
              saved.games.count <= SavedLibrary.maximumGames,
              saved.games.allSatisfy({ PCGamesClient.validProductID($0.id) }) else { return nil }
        return saved.matches(accountHash: accountHash, market: market, language: language) ? saved : nil
    }

    func save(_ saved: SavedLibrary) {
        lock.lock(); defer { lock.unlock() }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(saved).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            logger.warning("stage=librarySnapshotWriteFailed; the next launch reads the library from the account")
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        do { try FileManager.default.removeItem(at: file) }
        catch CocoaError.fileNoSuchFile {}
        catch { logger.warning("stage=librarySnapshotRemoveFailed; it is ignored for other accounts") }
    }
}
