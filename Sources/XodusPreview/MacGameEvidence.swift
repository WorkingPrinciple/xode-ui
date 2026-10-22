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
        case titleScreen = "TITLE_SCREEN_ONLY"
        case unknown = "UNRECOGNIZED"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .unknown
        }

        var label: String {
            switch self {
            case .gameplay: "Playable, not fully verified"
            case .working: "Works on Mac"
            case .menu: "Starts, not yet playable"
            case .titleScreen: "Title screen only"
            case .unknown: "Result not recognized"
            case .failed: "Doesn't start yet"
            case .blocked, .notTested: "Not tested on Mac yet"
            case .excluded: "Not supported yet"
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
        guard selected != nil || FileManager.default.fileExists(atPath: path) else {
            games = [:]
            errorMessage = nil
            lastBytes = nil
            return
        }
        do {
            let bytes = try await Task.detached {
                let url = URL(fileURLWithPath: path)
                try GameScriptFiles.checkPath(url)
                return try InstalledGameFiles.readRegular(url, maximumBytes: 1_048_576)
            }.value
            guard bytes != lastBytes || errorMessage != nil else { return }
            let catalogue = try MacGameEvidence.decode(bytes)
            games = Dictionary(uniqueKeysWithValues: catalogue.games.map { ($0.productId, $0) })
            lastBytes = bytes
            errorMessage = nil
        } catch {
            games = [:]
            errorMessage = "Mac test evidence couldn't be read at \(path). Check the ledger's format and file access."
        }
    }
}

struct MacGameEvidenceView: View {
    let record: MacGameEvidence.Game?
    var detailed = false
    @State private var openError: String?

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 4) {
                if let proof = record.screenshots.first {
                    Button { open(proof) } label: {
                        Label(status(record),
                              systemImage: record.verifiedWorkingEvidence != nil ? "checkmark.seal" : "photo")
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier(record.verifiedWorkingEvidence != nil
                        ? "xodus.evidence.verifiedWorking" : "xodus.evidence.screenshot")
                    .accessibilityLabel("\(status(record)). Open screenshot for \(record.title)")
                    .help("Recorded evidence: \(proof.path)\n\(record.scope)")
                    .contextMenu {
                        if detailed {
                            ForEach(Array(record.screenshots.enumerated()), id: \.offset) { _, image in
                                Button(image.caption) { open(image) }
                            }
                        }
                    }
                    if detailed, record.verifiedWorkingEvidence != nil {
                        Text(proof.path).font(.caption).textSelection(.enabled)
                    }
                } else {
                    Label(status(record), systemImage: "questionmark.circle")
                }
                if detailed {
                    Text(record.scope).fixedSize(horizontal: false, vertical: true)
                    if let blocker = record.blocker {
                        Text(blocker).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .alert("Screenshot unavailable", isPresented: Binding(
                get: { openError != nil }, set: { if !$0 { openError = nil } })) {
                Button("OK") { openError = nil }
            } message: { Text(openError ?? "") }
        } else {
            Label("Not tested on Mac yet", systemImage: "questionmark.circle")
                .help("Package eligibility is separate from observed Mac gameplay. No Mac test evidence is recorded.")
        }
    }

    private func status(_ record: MacGameEvidence.Game) -> String {
        let engine = record.statusLabel == MacGameEvidence.Verdict.notTested.label ? nil : record.engineLabel
        let label = record.verifiedWorkingEvidence != nil ? "Verified working" : record.statusLabel
        return label + (engine.map { " · " + $0 } ?? "")
    }

    private func open(_ proof: MacGameEvidence.Screenshot) {
        let url = URL(fileURLWithPath: proof.path)
        do {
            try GameScriptFiles.checkPath(url)
            guard FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else {
                throw PCGamesError.invalidResponse
            }
        } catch {
            openError = "The recorded screenshot is no longer available at \(proof.path). Refresh the Mac test evidence."
        }
    }
}
