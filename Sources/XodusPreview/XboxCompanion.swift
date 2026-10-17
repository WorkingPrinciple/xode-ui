// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import XodusManagement

struct XboxCompanionError: Decodable, Sendable {
    let reason: String
    let httpStatus: Int?
}

struct XboxCompanionSection<Value: Decodable & Sendable>: Decodable, Sendable {
    let state: String
    let value: Value?
    let error: XboxCompanionError?

    var available: Bool { state == "available" && value != nil && error == nil }
    var unavailable: Bool { state == "unavailable" && value == nil && error != nil }
}

struct XboxProfile: Decodable, Sendable {
    let gamertag: String
    let displayName: String?
    let avatarURL: String?
    let gamerscore: UInt?
    let bio: String?
    let location: String?
}

struct XboxFriend: Decodable, Identifiable, Sendable {
    let gamertag: String
    let avatarURL: String?
    let presenceState: String?
    let presenceText: String?
    var id: String { gamertag }
}

struct XboxConsole: Decodable, Identifiable, Sendable {
    struct Storage: Decodable, Identifiable, Sendable {
        let name: String?
        let freeBytes: Int64?
        let totalBytes: Int64?
        var id: String { "\(name ?? ""):\(freeBytes ?? -1):\(totalBytes ?? -1)" }
    }
    let id: String
    let name: String
    let consoleType: String?
    let powerState: String?
    let streamingEnabled: Bool?
    let remoteManagementEnabled: Bool?
    let storage: [Storage]
}

struct XboxRecentGame: Decodable, Identifiable, Sendable {
    let titleId: String
    let name: String
    let devices: [String]?
    let lastPlayed: String?
    let artworkURL: String?
    let achievementsUnlocked: UInt?
    let achievementsTotal: UInt?
    let gamerscore: UInt?
    let gamerscoreTotal: UInt?
    let productIds: [String]
    var id: String { titleId }
}

struct XboxCompanionCache: Decodable, Sendable {
    let ok: Bool
    let accountHash: String
    let checkedAt: String
    let profile: XboxCompanionSection<XboxProfile>
    let friends: XboxCompanionSection<[XboxFriend]>
    let consoles: XboxCompanionSection<[XboxConsole]>
    let recentGames: XboxCompanionSection<[XboxRecentGame]>

    var date: Date? { XboxCompanionValidation.date(checkedAt) }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        let validProfile = value.profile.value.map(XboxCompanionValidation.profile) ?? true
        let validFriends = value.friends.value.map {
            $0.count <= 5000 && Set($0.map(\.gamertag)).count == $0.count &&
            $0.allSatisfy(XboxCompanionValidation.friend)
        } ?? true
        let validConsoles = value.consoles.value.map {
            $0.count <= 100 && Set($0.map(\.id)).count == $0.count &&
            $0.allSatisfy(XboxCompanionValidation.console)
        } ?? true
        let validRecent = value.recentGames.value.map {
            $0.count <= 100 && Set($0.map(\.titleId)).count == $0.count &&
            $0.allSatisfy(XboxCompanionValidation.recentGame)
        } ?? true
        guard value.ok, XboxAccountBinding.valid(value.accountHash), value.date != nil,
              XboxCompanionValidation.section(value.profile),
              XboxCompanionValidation.section(value.friends),
              XboxCompanionValidation.section(value.consoles),
              XboxCompanionValidation.section(value.recentGames),
              validProfile, validFriends, validConsoles, validRecent else {
            throw GameScriptError.invalidReceipt
        }
        return value
    }
}

struct XboxAchievementRequirement: Decodable, Sendable {
    let id: String?
    let current: String?
    let target: String?
}

struct XboxAchievement: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let progressState: String
    let unlocked: Bool
    let unlockTime: String?
    let gamerscore: UInt?
    let isSecret: Bool?
    let artworkURL: String?
    let rarityPercentage: Double?
    let requirements: [XboxAchievementRequirement]
}

struct XboxAchievementCache: Decodable, Sendable {
    let ok: Bool
    let accountHash: String
    let titleId: String
    let checkedAt: String
    let complete: Bool
    let achievements: [XboxAchievement]
    let error: XboxCompanionError?

    var date: Date? { XboxCompanionValidation.date(checkedAt) }

    static func decode(_ data: Data, titleID: String) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.titleId == titleID, XboxCompanionValidation.titleID(titleID),
              XboxAccountBinding.valid(value.accountHash), value.date != nil,
              value.achievements.count <= 2000,
              Set(value.achievements.map(\.id)).count == value.achievements.count,
              value.achievements.allSatisfy(XboxCompanionValidation.achievement),
              value.complete ? (value.ok && value.error == nil) : value.error != nil else {
            throw GameScriptError.invalidReceipt
        }
        return value
    }
}

enum XboxCompanionArtwork {
    static func reference(_ value: String?, role: CatalogArtworkRole = .tile) -> CatalogArtworkReference? {
        guard var value, value.utf8.count <= 2048 else { return nil }
        let source: CatalogArtworkSource
        if value.hasPrefix("http://store-images.s-microsoft.com/image/") {
            value = "https://" + value.dropFirst("http://".count)
            source = .titleHub
        } else if value.hasPrefix("https://store-images.s-microsoft.com/image/") {
            source = .titleHub
        } else if value.hasPrefix("https://images-eds-ssl.xboxlive.com/") {
            source = .xboxCompanion
        } else { return nil }
        let object = JSONValue.object([
            "role": .string(role.rawValue), "url": .string(value),
            "width": .null, "height": .null, "source": .string(source.rawValue)
        ])
        guard let data = try? JSONEncoder().encode(object),
              let reference = try? JSONDecoder().decode(CatalogArtworkReference.self, from: data),
              (try? reference.validatedURL()) != nil else { return nil }
        return reference
    }
}

private enum XboxCompanionValidation {
    static func date(_ value: String?) -> Date? {
        guard let value, value.utf8.count <= 64 else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func text(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func optionalText(_ value: String?, maximum: Int) -> Bool {
        value.map { text($0, maximum: maximum) } ?? true
    }
    static func titleID(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{1,10}$"#, options: .regularExpression)
            == value.startIndex..<value.endIndex
    }
    static func section<T>(_ value: XboxCompanionSection<T>) -> Bool {
        (value.available || value.unavailable) &&
        value.error.map { text($0.reason, maximum: 512) && ($0.httpStatus.map { (100...599).contains($0) } ?? true) } ?? true
    }
    static func profile(_ value: XboxProfile) -> Bool {
        text(value.gamertag, maximum: 128) &&
        optionalText(value.displayName, maximum: 256) &&
        optionalText(value.bio, maximum: 2048) &&
        optionalText(value.location, maximum: 256)
    }
    static func friend(_ value: XboxFriend) -> Bool {
        text(value.gamertag, maximum: 128) &&
        optionalText(value.presenceState, maximum: 128) &&
        optionalText(value.presenceText, maximum: 512)
    }
    static func console(_ value: XboxConsole) -> Bool {
        text(value.id, maximum: 128) && text(value.name, maximum: 256) &&
        optionalText(value.consoleType, maximum: 128) &&
        optionalText(value.powerState, maximum: 128) && value.storage.count <= 32 &&
        value.storage.allSatisfy {
            optionalText($0.name, maximum: 256) &&
            ($0.freeBytes.map { $0 >= 0 } ?? true) && ($0.totalBytes.map { $0 > 0 } ?? true) &&
            ($0.freeBytes == nil || $0.totalBytes == nil || $0.freeBytes! <= $0.totalBytes!)
        }
    }
    static func recentGame(_ value: XboxRecentGame) -> Bool {
        titleID(value.titleId) && text(value.name, maximum: 512) &&
        (value.devices?.count ?? 0) <= 32 &&
        (value.devices?.allSatisfy { text($0, maximum: 128) } ?? true) &&
        (value.lastPlayed == nil || date(value.lastPlayed) != nil) &&
        (value.achievementsTotal.map { $0 > 0 } ?? true) &&
        (value.achievementsUnlocked == nil || value.achievementsTotal == nil ||
         value.achievementsUnlocked! <= value.achievementsTotal!) &&
        gamerscore(value) &&
        value.productIds.count <= 32 &&
        value.productIds.allSatisfy(PCGamesClient.validProductID)
    }
    static func achievement(_ value: XboxAchievement) -> Bool {
        text(value.id, maximum: 256) && text(value.name, maximum: 512) &&
        optionalText(value.description, maximum: 4096) &&
        text(value.progressState, maximum: 128) &&
        (value.unlocked ? date(value.unlockTime) != nil : value.unlockTime == nil) &&
        (value.rarityPercentage.map { $0.isFinite && (0...100).contains($0) } ?? true) &&
        value.requirements.count <= 64 &&
        value.requirements.allSatisfy {
            optionalText($0.id, maximum: 256) && optionalText($0.current, maximum: 256) &&
            optionalText($0.target, maximum: 256)
        }
    }
}

private extension XboxCompanionValidation {
    static func gamerscore(_ game: XboxRecentGame) -> Bool {
        game.gamerscoreTotal == nil || game.gamerscore == nil || game.gamerscore! <= game.gamerscoreTotal!
    }
}

@MainActor
final class XboxCompanionController: ObservableObject {
    static let shared = XboxCompanionController()
    @Published private(set) var cache: XboxCompanionCache?
    @Published private(set) var achievements: [String: XboxAchievementCache] = [:]
    @Published private(set) var error: String?
    @Published private(set) var achievementErrors: [String: String] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var refreshingTitles = Set<String>()
    private let paths: GameScriptPaths
    private let runner: GameScriptRunner
    private let ledger: XboxCompanionRefreshLedger
    private var owner: String?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var achievementTasks: [String: Task<Void, Never>] = [:]
    private var runIDs = Set<String>()
    private var terminating = false

    init(paths: GameScriptPaths = .production) {
        self.paths = paths
        runner = GameScriptRunner(paths: paths)
        ledger = XboxCompanionRefreshLedger(file: paths.xboxCompanionRefreshLedger)
    }

    func invalidateBinding() {
        generation += 1
        owner = nil
        cache = nil
        achievements = [:]
        error = nil
        achievementErrors = [:]
        task?.cancel()
        for value in achievementTasks.values { value.cancel() }
    }

    func shutdown() async {
        terminating = true
        invalidateBinding()
        for id in runIDs { await runner.cancel(runID: id) }
        await task?.value
        for value in achievementTasks.values { await value.value }
    }

    func resumeAfterTerminationRefusal() { terminating = false }

    func refresh(for status: GameServiceStatus?, force: Bool = false) async {
        let binding = status?.signedIn == true ? status?.accountHash : nil
        await bind(binding, signedIn: status?.signedIn == true)
        guard !terminating, let binding, XboxAccountBinding.valid(binding) else { return }
        if let task { await task.value; return }
        let epoch = generation
        let started = Date()
        let job = Task {
            defer { refreshing = false; task = nil }
            do {
                let saved = try await Self.readCompanion(paths.xboxCompanion)
                guard epoch == generation, owner == binding, !terminating else { return }
                cache = saved?.accountHash == binding ? saved : nil
                error = nil
                if !force, let date = cache?.date, started.timeIntervalSince(date) >= -60,
                   started.timeIntervalSince(date) < 900 { return }
                guard try await ledger.claim(key: "companion:\(binding)", now: started) else { return }
                refreshing = true
                let runID = InstalledGamesController.runID()
                runIDs.insert(runID)
                defer { runIDs.remove(runID) }
                let outcome = try await runner.run(command: .xboxCompanion, runID: runID)
                guard outcome.code == 0, let data = outcome.result else {
                    throw XboxCompanionRefreshError.failed(outcome.code)
                }
                let receipt = try JSONDecoder().decode(XboxCompanionReceipt.self, from: data)
                let fresh = try await Self.readCompanion(paths.xboxCompanion)
                guard epoch == generation, owner == binding, !terminating,
                      receipt.accountHash == binding, let fresh, fresh.accountHash == binding,
                      receipt.matches(fresh), let date = fresh.date,
                      date >= started.addingTimeInterval(-5), date <= Date().addingTimeInterval(60) else {
                    throw XboxCompanionRefreshError.unconfirmed
                }
                cache = fresh
            } catch is CancellationError { }
            catch {
                if epoch == generation, owner == binding, !terminating {
                    self.error = (error as? XboxCompanionRefreshError)?.localizedDescription
                        ?? "Xbox profile, friends and consoles couldn't be refreshed. Saved data is kept."
                }
            }
        }
        task = job
        await job.value
    }

    func loadAchievements(titleID: String, status: GameServiceStatus?, force: Bool = false) async {
        guard XboxCompanionValidation.titleID(titleID) else {
            achievementErrors[titleID] = "This Xbox title identifier isn't valid."
            return
        }
        let binding = status?.signedIn == true ? status?.accountHash : nil
        await bind(binding, signedIn: status?.signedIn == true)
        guard !terminating, let binding, XboxAccountBinding.valid(binding) else { return }
        if let task = achievementTasks[titleID] { await task.value; return }
        let epoch = generation
        let started = Date()
        let job = Task {
            defer {
                refreshingTitles.remove(titleID)
                achievementTasks[titleID] = nil
            }
            do {
                let file = try paths.xboxAchievementsFile(titleID: titleID)
                let saved = try await Self.readAchievements(file, titleID: titleID)
                guard epoch == generation, owner == binding, !terminating else { return }
                if saved?.accountHash == binding { achievements[titleID] = saved }
                achievementErrors[titleID] = nil
                if !force, let date = achievements[titleID]?.date,
                   started.timeIntervalSince(date) >= -60, started.timeIntervalSince(date) < 900 { return }
                guard try await ledger.claim(key: "achievement:\(binding):\(titleID)", now: started) else { return }
                refreshingTitles.insert(titleID)
                let runID = InstalledGamesController.runID()
                runIDs.insert(runID)
                defer { runIDs.remove(runID) }
                let outcome = try await runner.run(command: .xboxAchievements, runID: runID,
                                                   arguments: [titleID])
                guard outcome.code == 0, let data = outcome.result else {
                    throw XboxCompanionRefreshError.failed(outcome.code)
                }
                let receipt = try JSONDecoder().decode(XboxAchievementReceipt.self, from: data)
                let fresh = try await Self.readAchievements(file, titleID: titleID)
                guard epoch == generation, owner == binding, !terminating,
                      receipt.accountHash == binding, receipt.titleId == titleID,
                      let fresh, fresh.accountHash == binding, receipt.count == fresh.achievements.count,
                      receipt.complete == fresh.complete, receipt.error?.reason == fresh.error?.reason,
                      let date = fresh.date, date >= started.addingTimeInterval(-5),
                      date <= Date().addingTimeInterval(60) else {
                    throw XboxCompanionRefreshError.unconfirmed
                }
                achievements[titleID] = fresh
            } catch is CancellationError { }
            catch {
                if epoch == generation, owner == binding, !terminating {
                    achievementErrors[titleID] =
                        (error as? XboxCompanionRefreshError)?.localizedDescription
                        ?? "Achievements couldn't be refreshed. Saved results are kept."
                }
            }
        }
        achievementTasks[titleID] = job
        await job.value
    }

    private func bind(_ binding: String?, signedIn: Bool) async {
        if binding != owner {
            invalidateBinding()
            owner = binding
            await task?.value
            for value in achievementTasks.values { await value.value }
        }
        if signedIn, binding == nil {
            error = "The Xbox game-service account couldn't be confirmed. Check game sign-in."
        }
    }

    nonisolated private static func readCompanion(_ file: URL) async throws -> XboxCompanionCache? {
        try await read(file, maximum: 2 * 1024 * 1024).map(XboxCompanionCache.decode)
    }

    nonisolated private static func readAchievements(_ file: URL, titleID: String) async throws -> XboxAchievementCache? {
        try await read(file, maximum: 4 * 1024 * 1024).map { try XboxAchievementCache.decode($0, titleID: titleID) }
    }

    nonisolated private static func read(_ file: URL, maximum: Int) async throws -> Data? {
        try await Task.detached {
            try GameScriptFiles.checkPath(file.deletingLastPathComponent(), allowMissing: true)
            var info = stat()
            if lstat(file.path, &info) != 0 {
                guard errno == ENOENT else { throw GameScriptError.invalidReceipt }
                return nil
            }
            return try InstalledGameFiles.readRegular(file, maximumBytes: maximum, privateFile: true)
        }.value
    }
}

actor XboxCompanionRefreshLedger {
    private struct Record: Codable {
        let attempts: [String: Date]
    }
    private let file: URL
    init(file: URL) { self.file = file }

    func claim(key: String, now: Date) throws -> Bool {
        guard key.utf8.count <= 160,
              key.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...122).contains($0.value) ||
                  $0.value == 45 || $0.value == 58
              }) else { throw GameScriptError.invalidReceipt }
        var attempts: [String: Date] = [:]
        if let data = try GameScriptFiles.read(file, maximumBytes: 64 * 1024, missingAllowed: true) {
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.attempts.count <= 500,
                  record.attempts.values.allSatisfy({ $0 <= now.addingTimeInterval(60) }) else {
                throw GameScriptError.invalidReceipt
            }
            attempts = record.attempts
            if let previous = attempts[key], now.timeIntervalSince(previous) < 900 { return false }
        }
        attempts[key] = now
        try GameScriptFiles.writePrivate(JSONEncoder().encode(Record(attempts: attempts)), to: file)
        return true
    }
}

private struct XboxCompanionReceipt: Decodable {
    struct Section: Decodable { let state: String; let count: Int?; let error: XboxCompanionError? }
    let accountHash: String
    let checkedAt: String
    let sections: [String: Section]

    func matches(_ cache: XboxCompanionCache) -> Bool {
        guard XboxCompanionValidation.date(checkedAt) != nil,
              Set(sections.keys) == Set(["profile", "friends", "consoles", "recentGames"]) else { return false }
        let states = [
            "profile": cache.profile.state, "friends": cache.friends.state,
            "consoles": cache.consoles.state, "recentGames": cache.recentGames.state
        ]
        return sections.allSatisfy { name, section in
            let count: Int?
            switch name {
            case "friends": count = cache.friends.value?.count
            case "consoles": count = cache.consoles.value?.count
            case "recentGames": count = cache.recentGames.value?.count
            default: count = nil
            }
            return section.state == states[name] && section.count == count &&
            XboxCompanionValidation.optionalText(section.error?.reason, maximum: 512)
        }
    }
}

private struct XboxAchievementReceipt: Decodable {
    let accountHash: String
    let titleId: String
    let checkedAt: String
    let count: Int
    let complete: Bool
    let error: XboxCompanionError?
}

private enum XboxCompanionRefreshError: Error, LocalizedError {
    case failed(Int), unconfirmed
    var errorDescription: String? {
        switch self {
        case .failed(11): "Xbox companion data requires the current game-service account. Check game sign-in."
        case .failed(13): "Xbox returned companion data Xodus couldn't validate. Saved data is kept."
        case .failed(1): "Xbox companion data timed out. Try again later."
        case .failed(2): "The Xbox title identifier wasn't accepted."
        case .failed: "Xbox companion data couldn't be refreshed. Saved data is kept."
        case .unconfirmed: "Xbox companion data didn't match the current account. Saved data is kept."
        }
    }
}
