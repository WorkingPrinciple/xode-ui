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

        var label: String {
            switch self {
            case .gameplay: "Mac gameplay observed"
            case .menu: "Mac menu observed"
            case .blocked: "Mac launch blocked"
            case .failed: "Mac launch failed"
            case .notTested: "Mac play not tested"
            case .excluded: "Anti-cheat excluded"
            case .working: "Working on Mac"
            }
        }
    }
    struct Screenshot: Decodable, Sendable {
        let path: String
        let caption: String
    }
    struct Game: Decodable, Sendable {
        let productId: String
        let title: String
        let verdict: Verdict
        let scope: String
        let engine: String?
        let runId: String?
        let screenshots: [Screenshot]
        let owner: String
        let blocker: String?
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

    func refresh(defaults: UserDefaults = .standard) async {
        let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Ode to X/Evidence/tried-games.json")
        let selected = defaults.string(forKey: "Xodus.evidence.triedGames").flatMap { $0.isEmpty ? nil : $0 }
        let path = selected ?? defaultURL.path
        guard selected != nil || FileManager.default.fileExists(atPath: path) else {
            games = [:]
            errorMessage = nil
            return
        }
        do {
            let catalogue = try await Task.detached {
                let url = URL(fileURLWithPath: path)
                try GameScriptFiles.checkPath(url)
                return try MacGameEvidence.decode(InstalledGameFiles.readRegular(url, maximumBytes: 1_048_576))
            }.value
            games = Dictionary(uniqueKeysWithValues: catalogue.games.map { ($0.productId, $0) })
            errorMessage = nil
        } catch {
            games = [:]
            errorMessage = "Mac test evidence couldn't be read at \(path). Check the ledger's format and file access."
        }
    }
}

struct MacGameEvidenceView: View {
    let record: MacGameEvidence.Game?
    @State private var openError: String?

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 4) {
                if let proof = record.screenshots.first {
                    Button { open(proof) } label: {
                        Label(record.verdict == .gameplay
                              ? "Played on Mac (\(record.engine?.hasPrefix("crossover") == true ? "CrossOver" : record.engine ?? "engine not recorded"))"
                              : record.verdict.label, systemImage: "photo")
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("\(record.verdict.label). Open screenshot for \(record.title)")
                    .contextMenu {
                        ForEach(Array(record.screenshots.enumerated()), id: \.offset) { _, image in
                            Button(image.caption) { open(image) }
                        }
                    }
                } else {
                    Label(record.verdict.label, systemImage: "exclamationmark.circle")
                    Text("No screenshot recorded").font(.caption)
                }
                Text(record.scope).fixedSize(horizontal: false, vertical: true)
                if let blocker = record.blocker {
                    Text(blocker).fixedSize(horizontal: false, vertical: true)
                }
                Text("\(record.engine ?? "Engine not recorded") · \(record.owner)").font(.caption)
            }
            .help(record.scope)
            .alert("Screenshot unavailable", isPresented: Binding(
                get: { openError != nil }, set: { if !$0 { openError = nil } })) {
                Button("OK") { openError = nil }
            } message: { Text(openError ?? "") }
        } else {
            Label("Mac play not tested", systemImage: "questionmark.circle")
                .help("Package eligibility is separate from observed Mac gameplay. No Mac test evidence is recorded.")
        }
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
