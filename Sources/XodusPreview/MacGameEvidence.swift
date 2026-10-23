// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import SwiftUI
import XodusManagement

struct MacGameEvidence: Decodable, Sendable {
    enum Verdict: String, Decodable, Sendable {
        case gameplay = "GAMEPLAY_PASS", menu = "MENU_PASS", blocked = "BLOCKED"
        case failed = "FAIL", notTested = "NOT_TESTED", excluded = "ANTI_CHEAT_EXCLUDED"
        case working = "WORKING"
        case workingCandidate = "WORKING_CANDIDATE"
        case titleScreen = "TITLE_SCREEN_ONLY"
        case inconclusive = "INCONCLUSIVE"
        case unknown = "UNRECOGNIZED"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .unknown
        }

        var label: String {
            switch self {
            case .gameplay: "Playable, not fully verified"
            case .working: "Works on Mac"
            case .workingCandidate: "Candidate · CLI only"
            case .menu: "Starts, not yet playable"
            case .titleScreen: "Title screen only"
            case .unknown: "Result not recognized"
            case .failed: "Doesn't start yet"
            case .blocked, .notTested: "Not tested on Mac yet"
            case .excluded: "Excluded from Mac testing"
            case .inconclusive: "Inconclusive"
            }
        }
    }
    struct Screenshot: Decodable, Sendable {
        let path: String
        let caption: String
    }
    struct Game: Decodable, Sendable {
        struct SaveObservation: Decodable, Sendable {
            let saveDirectory: String?
            let retentionVerified: Bool?
            let normalMenuQuitObserved: Bool?
        }

        private enum CodingKeys: String, CodingKey {
            case productId, title, verdict, scope, engine, runId, retentionRunId, normalQuitRunId
            case screenshots, owner, blocker, launchAttempted, saveObservation, app_e2e
        }

        let productId: String
        let title: String
        let verdict: Verdict
        let scope: String
        let engine: String?
        let runId: String?
        let retentionRunId: String?
        let normalQuitRunId: String?
        let screenshots: [Screenshot]
        let owner: String
        let blocker: String?
        let launchAttempted: Bool?
        let saveObservation: SaveObservation?
        let app_e2e: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            productId = try container.decode(String.self, forKey: .productId)
            title = try container.decode(String.self, forKey: .title)
            verdict = try container.decode(Verdict.self, forKey: .verdict)
            scope = try container.decode(String.self, forKey: .scope)
            engine = try container.decodeIfPresent(String.self, forKey: .engine)
            runId = try container.decodeIfPresent(String.self, forKey: .runId)
            retentionRunId = try container.decodeIfPresent(String.self, forKey: .retentionRunId)
            normalQuitRunId = try container.decodeIfPresent(String.self, forKey: .normalQuitRunId)
            screenshots = try container.decodeIfPresent([Screenshot].self, forKey: .screenshots) ?? []
            owner = try container.decode(String.self, forKey: .owner)
            blocker = try container.decodeIfPresent(String.self, forKey: .blocker)
            launchAttempted = try container.decodeIfPresent(Bool.self, forKey: .launchAttempted)
            saveObservation = try container.decodeIfPresent(SaveObservation.self, forKey: .saveObservation)
            app_e2e = try container.decodeIfPresent(String.self, forKey: .app_e2e)
        }

        var verificationScopeLabel: String? {
            app_e2e == "unobserved" || verdict == .workingCandidate
                ? "CLI only · App testing not observed" : nil
        }

        var verifiedWorkingEvidence: Screenshot? {
            verdict == .working && launchAttempted != false
                && saveObservation?.normalMenuQuitObserved != false ? screenshots.first : nil
        }

        var saveVerifiedQuitPending: Bool {
            (verdict == .gameplay || verdict == .working) && launchAttempted != false
                && saveObservation?.retentionVerified == true
                && saveObservation?.normalMenuQuitObserved == false
                && retentionRunId.flatMap(UUID.init(uuidString:)) != nil
        }

        var statusLabel: String {
            if launchAttempted == false { return Verdict.notTested.label }
            if saveVerifiedQuitPending { return "Save verified · quit pending" }
            if verdict == .working, saveObservation?.normalMenuQuitObserved == false {
                return "Quit not verified"
            }
            if verdict == .blocked, launchAttempted == true { return Verdict.failed.label }
            return verdict.label
        }

        var engineLabel: String? {
            guard let engine else { return nil }
            if engine == "native-macos" { return "Native" }
            return engine.lowercased().hasPrefix("crossover") ? "CrossOver" : "Free Wine"
        }

        var provenEngine: String? {
            verdict == .gameplay || verdict == .working ? engine : nil
        }
    }
    let schemaVersion: Int
    let updatedAt: String
    let games: [Game]

    static let bundled: Result<Self, Error> = Result {
        try decode(Data(contentsOf: CompatibilityResources.macGameEvidenceURL()))
    }

    func merging(_ local: Self) throws -> [String: Game] {
        guard let localDate = GameCompatibilityResult.parseDate(local.updatedAt),
              let bundledDate = GameCompatibilityResult.parseDate(updatedAt) else {
            throw PCGamesError.invalidResponse
        }
        let localIsNewer = localDate >= bundledDate
        var result = Dictionary(uniqueKeysWithValues: games.map { ($0.productId, $0) })
        for game in local.games where localIsNewer || result[game.productId] == nil {
            result[game.productId] = game
        }
        return result
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 1_048_576 else { throw PCGamesError.responseTooLarge }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        func validText(_ text: String, limit: Int) -> Bool {
            !text.isEmpty && text.utf8.count <= limit
                && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard value.schemaVersion == 1, GameCompatibilityResult.parseDate(value.updatedAt) != nil,
              value.games.count <= 4096,
              Set(value.games.map(\.productId)).count == value.games.count,
              value.games.allSatisfy({ game in
                  PCGamesClient.validProductID(game.productId) && validText(game.title, limit: 512)
                      && validText(game.scope, limit: 4096)
                      && (game.engine.map { validText($0, limit: 128) } ?? true)
                      && validText(game.owner, limit: 128)
                      && (game.runId.map { UUID(uuidString: $0) != nil } ?? true)
                      && game.screenshots.count <= 16
                      && game.screenshots.allSatisfy {
                          validText($0.caption, limit: 1024) && $0.path.hasPrefix("/")
                              && validText($0.path, limit: 4096)
                              && ["png", "jpg", "jpeg", "heic"].contains(
                                  URL(fileURLWithPath: $0.path).pathExtension.lowercased())
                      }
              }) else { throw PCGamesError.invalidResponse }
        return value
    }
}

enum MacGameEvidenceDiagnostic {
    static let bundledUnavailable = "The app's bundled Mac test evidence couldn't be loaded."

    static func unreadable(path: String) -> String {
        "Mac test evidence couldn't be read at \(path). Check file access."
    }

    static func invalid(path: String) -> String {
        "Mac test evidence at \(path) is invalid. Check its JSON structure and required fields."
    }
}

@MainActor
final class MacGameEvidenceStore: ObservableObject {
    static let shared = MacGameEvidenceStore()
    @Published private(set) var games: [String: MacGameEvidence.Game] = [:]
    @Published private(set) var errorMessage: String?
    private var lastBytes: Data?

    func refresh(defaults: UserDefaults = .standard) async {
        let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Ode to X/Evidence/tried-games.json")
        let selected = defaults.string(forKey: "Xodus.evidence.triedGames").flatMap { $0.isEmpty ? nil : $0 }
        let path = selected ?? defaultURL.path
        let bundled: MacGameEvidence
        do {
            bundled = try MacGameEvidence.bundled.get()
        } catch {
            games = [:]
            errorMessage = MacGameEvidenceDiagnostic.bundledUnavailable
            return
        }
        if selected == nil && !FileManager.default.fileExists(atPath: path) {
            games = Dictionary(uniqueKeysWithValues: bundled.games.map { ($0.productId, $0) })
            errorMessage = nil
            lastBytes = nil
            return
        }
        let bytes: Data
        do {
            bytes = try await Task.detached {
                let url = URL(fileURLWithPath: path)
                try GameScriptFiles.checkPath(url)
                return try InstalledGameFiles.readRegular(url, maximumBytes: 1_048_576)
            }.value
        } catch {
            games = [:]
            errorMessage = MacGameEvidenceDiagnostic.unreadable(path: path)
            return
        }
        guard bytes != lastBytes || errorMessage != nil else { return }
        let catalogue: MacGameEvidence
        do {
            catalogue = try MacGameEvidence.decode(bytes)
        } catch {
            games = [:]
            errorMessage = MacGameEvidenceDiagnostic.invalid(path: path)
            return
        }
        do {
            games = selected == nil ? try bundled.merging(catalogue)
                : Dictionary(uniqueKeysWithValues: catalogue.games.map { ($0.productId, $0) })
        } catch {
            games = [:]
            errorMessage = MacGameEvidenceDiagnostic.invalid(path: path)
            return
        }
        lastBytes = bytes
        errorMessage = nil
    }
}
