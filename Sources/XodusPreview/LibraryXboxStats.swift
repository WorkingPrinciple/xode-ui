// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusManagement

struct LibraryXboxStatsCache: Decodable, Sendable {
    struct Friend: Decodable, Sendable {
        let gamertag: String
        let online: Bool
    }
    struct Game: Decodable, Sendable {
        let achievementsUnlocked: Int
        let achievementsTotal: Int
        let gamerscore: Int
        let gamerscoreTotal: Int
        let genres: [String]
        let logoUrl: String?
        let minutesPlayed: Int?
        let friendsWhoPlay: [Friend]

        var playTime: String? {
            minutesPlayed.map {
                "\((Double($0) / 60).formatted(.number.precision(.fractionLength(1)))) h on Xbox"
            }
        }
        var achievements: String {
            let count = achievementsTotal > 0
                ? "\(achievementsUnlocked.formatted()) of \(achievementsTotal.formatted()) achievements"
                : "\(achievementsUnlocked.formatted()) achievements"
            let score = gamerscoreTotal > 0
                ? "\(gamerscore.formatted()) / \(gamerscoreTotal.formatted()) G"
                : "\(gamerscore.formatted()) G"
            return "\(count) · \(score)"
        }
        var friends: String? {
            guard !friendsWhoPlay.isEmpty else { return nil }
            return friendsWhoPlay.count == 1 ? "1 friend plays" : "\(friendsWhoPlay.count.formatted()) friends play"
        }
        var friendHelp: String { friendsWhoPlay.map(\.gamertag).joined(separator: "\n") }
        var logo: CatalogArtworkReference? {
            PCGamesClient.artwork(uri: logoUrl, width: nil, height: nil, role: .hero)
        }
    }
    let friends: Int
    let checkedAt: String
    let accountHash: String?
    let games: [String: Game]

    var date: Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: checkedAt) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: checkedAt)
    }

    static func decode(_ data: Data) throws -> Self {
        let cache = try JSONDecoder().decode(Self.self, from: data)
        guard cache.date != nil, cache.accountHash.map(XboxAccountBinding.valid) ?? true,
              cache.friends >= 0, cache.games.count <= 5000,
              cache.games.allSatisfy({ id, game in
                  PCGamesClient.validProductID(id) && game.achievementsUnlocked >= 0 &&
                  game.achievementsTotal >= 0 && game.gamerscore >= 0 && game.gamerscoreTotal >= 0 &&
                  (game.achievementsTotal == 0 || game.achievementsUnlocked <= game.achievementsTotal) &&
                  (game.gamerscoreTotal == 0 || game.gamerscore <= game.gamerscoreTotal) &&
                  (game.minutesPlayed.map { (0...31_536_000).contains($0) } ?? true) &&
                  game.genres.count <= 20 && game.genres.allSatisfy { safeText($0, maximum: 128) } &&
                  game.friendsWhoPlay.count <= 2000 &&
                  game.friendsWhoPlay.allSatisfy { safeText($0.gamertag, maximum: 128) }
              }) else { throw PCGamesError.invalidResponse }
        return cache
    }

    private static func safeText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

@MainActor
final class LibraryXboxStats: ObservableObject {
    static let shared = LibraryXboxStats()
    @Published private(set) var cache: LibraryXboxStatsCache?
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false
    private let paths: GameScriptPaths
    private let runner: GameScriptRunner
    private let ledger: GameStatsRefreshLedger
    private var owner: String?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var runID: String?
    private var terminating = false

    init(paths: GameScriptPaths = .production) {
        self.paths = paths
        runner = GameScriptRunner(paths: paths)
        ledger = GameStatsRefreshLedger(file: paths.statsRefreshLedger)
    }

    func invalidateBinding() {
        generation += 1
        owner = nil
        cache = nil
        error = nil
        task?.cancel()
    }

    func shutdown() async {
        terminating = true
        invalidateBinding()
        if let runID { await runner.cancel(runID: runID) }
        await task?.value
    }

    func resumeAfterTerminationRefusal() { terminating = false }

    func refresh(for status: GameServiceStatus?, signingIn: Bool = false) async {
        let binding = !signingIn && status?.signedIn == true ? status?.accountHash : nil
        if binding != owner {
            invalidateBinding()
            owner = binding
            let retirement = generation
            await task?.value
            guard retirement == generation, owner == binding else { return }
        }
        guard !terminating, let binding, XboxAccountBinding.valid(binding) else {
            if owner == nil { cache = nil }
            if status?.signedIn == true, !signingIn, binding == nil {
                error = "The Xbox account couldn't be confirmed. Check game sign-in before loading stats."
            }
            return
        }
        if let task { await task.value; return }
        let epoch = generation
        let paths = paths
        let started = Date()
        let refresh = Task {
            defer { refreshing = false; task = nil; runID = nil }
            do {
                let saved = try await Self.read(paths.gameStats)
                guard epoch == generation, !terminating else { return }
                cache = saved?.accountHash == binding ? saved : nil
                error = nil
                if let date = cache?.date, started.timeIntervalSince(date) >= -60,
                   started.timeIntervalSince(date) < 900 { return }
                guard try await ledger.claim(accountHash: binding, now: started) else { return }
                try Task.checkCancellation()
                guard epoch == generation, !terminating else { return }
                refreshing = true
                let id = InstalledGamesController.runID()
                runID = id
                let outcome = try await runner.run(command: .gameStats, runID: id)
                try Task.checkCancellation()
                guard epoch == generation, !terminating else { return }
                guard outcome.code == 0, let data = outcome.result else {
                    throw GameStatsRefreshError.failed(outcome.code)
                }
                let receipt = try JSONDecoder().decode(GameStatsRefreshResult.self, from: data)
                let fresh = try await Self.read(paths.gameStats)
                guard epoch == generation, !terminating else { return }
                guard receipt.accountHash == binding, let fresh, fresh.accountHash == binding,
                      receipt.games == fresh.games.count, receipt.friends == fresh.friends,
                      receipt.games <= 5000, receipt.friends >= 0,
                      let date = fresh.date, date >= started.addingTimeInterval(-5),
                      date <= Date().addingTimeInterval(60) else { throw GameStatsRefreshError.unconfirmed }
                cache = fresh
            } catch is CancellationError { }
            catch {
                if epoch == generation, !terminating {
                    self.error = (error as? GameStatsRefreshError)?.localizedDescription ??
                        "Xbox stats couldn't be refreshed. Previously confirmed stats are kept; try again later."
                }
            }
        }
        task = refresh
        await refresh.value
    }

    func loadReadOnly() async {
        do {
            cache = try await Self.read(paths.gameStats)
            error = nil
        } catch {
            self.error = "Saved Xbox game stats couldn't be read. Your games and access haven't changed."
        }
    }

    nonisolated private static func read(_ file: URL) async throws -> LibraryXboxStatsCache? {
        try await Task.detached {
            try GameScriptFiles.checkPath(file.deletingLastPathComponent(), allowMissing: true)
            var info = stat()
            if lstat(file.path, &info) != 0 {
                guard errno == ENOENT else { throw PCGamesError.invalidResponse }
                return nil
            }
            return try LibraryXboxStatsCache.decode(
                InstalledGameFiles.readRegular(file, maximumBytes: 1_048_576, privateFile: true))
        }.value
    }
}

private struct GameStatsRefreshResult: Decodable {
    let accountHash: String
    let games: Int
    let friends: Int
}

enum GameStatsRefreshError: Error, LocalizedError {
    case failed(Int), unconfirmed
    var errorDescription: String? {
        switch self {
        case .failed(11): "Xbox stats aren't available while game sign-in or its service is unavailable."
        case .failed: "Xbox stats couldn't be refreshed. Previously confirmed stats are kept; try again later."
        case .unconfirmed: "Xbox stats didn't match this account's confirmed result. Previous stats are kept."
        }
    }
}

actor GameStatsRefreshLedger {
    private struct Record: Codable { let accountHash: String; let attemptedAt: Date }
    private let file: URL
    init(file: URL) { self.file = file }

    func claim(accountHash: String, now: Date) throws -> Bool {
        guard XboxAccountBinding.valid(accountHash) else { throw GameScriptError.invalidReceipt }
        let directory = file.deletingLastPathComponent()
        try GameScriptFiles.checkPath(directory, allowMissing: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = directory.appendingPathComponent(".game-stats-refresh.lock")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GameScriptError.storage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, flock(fd, LOCK_EX) == 0 else { throw GameScriptError.storage }
        defer { flock(fd, LOCK_UN) }
        if let data = try GameScriptFiles.read(file, missingAllowed: true) {
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard XboxAccountBinding.valid(record.accountHash), record.attemptedAt <= now.addingTimeInterval(60) else {
                throw GameScriptError.invalidReceipt
            }
            if record.accountHash == accountHash, now.timeIntervalSince(record.attemptedAt) < 900 { return false }
        }
        try GameScriptFiles.writePrivate(JSONEncoder().encode(Record(accountHash: accountHash, attemptedAt: now)), to: file)
        return true
    }
}
