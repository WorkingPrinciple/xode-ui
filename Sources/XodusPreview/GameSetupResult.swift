// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct GameSetupResult: Decodable, Sendable {
    struct Item: Decodable, Identifiable, Sendable {
        enum ID: String, Decodable, CaseIterable, Hashable, Sendable { case crossover, environment, service, signin }
        let id: ID
        let title: String
        let ready: Bool
        let fix: String?
    }
    let ready: Bool
    let items: [Item]

    var orderedItems: [Item] {
        Item.ID.allCases.compactMap { id in items.first { $0.id == id } }
    }
    var needsSignIn: Bool { items.first { $0.id == .signin }?.ready == false }

    static func parse(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.items.count == Item.ID.allCases.count,
              Set(value.items.map(\.id)) == Set(Item.ID.allCases),
              value.items.allSatisfy({ item in
                  !item.title.isEmpty && item.title.utf8.count <= 256
                      && validText(item.title)
                      && (item.fix.map { !$0.isEmpty && $0.utf8.count <= 4096 && validText($0) } ?? true)
              }) else { throw GameScriptError.invalidReceipt }
        return value
    }

    private static func validText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
