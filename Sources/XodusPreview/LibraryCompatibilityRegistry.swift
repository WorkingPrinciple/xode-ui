// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum LibraryCompatibilityIssueKind: String, Hashable, Sendable {
    case packageType, antiCheat, runtime

    var symbol: String {
        switch self {
        case .packageType: "shippingbox"
        case .antiCheat: "shield.slash"
        case .runtime: "exclamationmark.triangle"
        }
    }
}

struct LibraryCompatibilityIssue: Identifiable, Hashable, Sendable {
    let kind: LibraryCompatibilityIssueKind
    let title: String
    let detail: String
    let source: URL?
    var id: String { "\(kind.rawValue):\(title)" }
    var browseTitle: String { kind == .packageType ? "Package not supported yet" : title }
    var browseDetail: String {
        kind == .packageType
            ? "This game uses a Windows package this version can't run yet. Open game details for the format."
            : detail
    }
}

enum LibraryCompatibilityRegistry {
    private static let entries: [String: [LibraryCompatibilityIssue]] = [
        // Official Xbox support documents Easy Anti-Cheat specifically for Gears 5.
        "C2KDNLT2H7DM": [
            LibraryCompatibilityIssue(
                kind: .antiCheat,
                title: "Easy Anti-Cheat",
                detail: "Gears 5 uses Easy Anti-Cheat, which this Mac runtime does not support.",
                source: URL(string: "https://support.xbox.com/en-US/help/games-apps/game-titles/gears-easy-anti-cheat")
            )
        ]
    ]

    static func issues(productID: String) -> [LibraryCompatibilityIssue] {
        entries[productID.uppercased()] ?? []
    }
}
