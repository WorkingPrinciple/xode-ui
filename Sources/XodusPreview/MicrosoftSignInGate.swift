// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Serializes interactive consent, not service identities or credential ownership.
@MainActor
final class MicrosoftSignInGate {
    static let shared = MicrosoftSignInGate()
    private var owner: UUID?

    var available: Bool { owner == nil }

    func acquire(_ id: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = id
        return true
    }

    func release(_ id: UUID) {
        if owner == id { owner = nil }
    }
}
