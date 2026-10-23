// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum GameSearchScope: String, CaseIterable, Identifiable {
    case allGames = "All games", gamePass = "Game Pass", installed = "Installed"
    var id: String { rawValue }

    func includes(_ game: LibraryGame) -> Bool {
        switch self {
        case .allGames: true
        case .gamePass: game.gamePass
        case .installed: game.installed != nil
        }
    }
}

enum GameSearchHistory {
    static func recording(_ query: String, in previous: [String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(previous.prefix(8)) }
        return Array(([query] + previous.filter {
            $0.compare(query, options: .caseInsensitive) != .orderedSame
        }).prefix(8))
    }
}
