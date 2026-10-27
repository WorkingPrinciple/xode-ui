// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import XodusManagement

struct GameFacts: Equatable {
    enum Ownership: Equatable {
        case purchased(Date?), inLibraryUnknownAcquisition, notInLibrary, unknown
    }
    enum Plan: String, CaseIterable {
        case pcGamePass, ultimate, premium, eaPlay, ubisoftPlusClassics

        var label: String {
            switch self {
            case .pcGamePass: "Game Pass"
            case .ultimate: "Game Pass Ultimate"
            case .premium: "Game Pass Premium"
            case .eaPlay: "EA Play"
            case .ubisoftPlusClassics: "Ubisoft+ Classics"
            }
        }
    }
    struct Membership: Equatable {
        let plan: Plan
        var since: Date?
        var leavingOn: Date?
    }
    enum Coverage { case verified, partial, unknown }
    enum Installation: Equatable {
        case installed(String), installing(Double), notInstalled
    }
    enum Support: Equatable { case supported, unsupported(String), unknown }
    enum Classification { case game, app, unresolved }

    var ownership: Ownership = .unknown
    var memberships: [Membership] = []
    var coverage: Coverage = .unknown
    var userPlans: Set<Plan>?
    var installation: Installation = .notInstalled
    var package: String?
    var downloadBytes: Int64?
    var support: Support = .unknown
    var classification: Classification = .unresolved
    var accessIsCurrent = false
    var subscriptionAcquisition = false
    /// REQ-7/63: an active Game Pass plan covers this PC Game Pass title; not a purchase, never "missing".
    var availableWithGamePass = false
    static let availableWithGamePassLabel = "Available with Game Pass"

    init(ownership: Ownership = .unknown, memberships: [Membership] = [], accessIsCurrent: Bool = false) {
        self.ownership = ownership
        self.memberships = memberships
        self.accessIsCurrent = accessIsCurrent
    }

    init(pc: PCGame?, gamePass: Bool, installed: InstalledGame? = nil, accessIsCurrent: Bool) {
        subscriptionAcquisition = accessIsCurrent && pc?.acquisitionKind == .subscription
        if accessIsCurrent {
            switch pc?.acquisitionKind {
            case .purchased: ownership = .purchased(nil)
            case .subscription, .unknown: ownership = .inLibraryUnknownAcquisition
            case nil: ownership = .notInLibrary
            }
        } else {
            ownership = .unknown
        }
        // allgamespc proves PC catalogue membership, not an account plan.
        memberships = gamePass ? [Membership(plan: .pcGamePass)] : []
        coverage = .partial
        self.accessIsCurrent = accessIsCurrent
        if let installed { installation = .installed(installed.folder) }
        package = installed?.packageType?.label
        classification = pc != nil ? .game : .unresolved
    }

    init(pc: PCGame?, gamePass: Bool, installed: InstalledGame? = nil, accessIsCurrent: Bool,
         availableWithGamePass: Bool) {
        self.init(pc: pc, gamePass: gamePass, installed: installed, accessIsCurrent: accessIsCurrent)
        self.availableWithGamePass = availableWithGamePass && gamePass && pc?.acquisitionKind != .purchased
    }

    func badgeLabels(detail: Bool = false) -> [String] {
        var labels: [String] = []
        if accessIsCurrent {
            switch ownership {
            case .purchased: labels.append("Owned")
            case .inLibraryUnknownAcquisition: labels.append("In your library")
            case .notInLibrary, .unknown: break
            }
        }
        for plan in Plan.allCases {
            guard let membership = memberships.first(where: { $0.plan == plan }) else { continue }
            if plan == .pcGamePass, availableWithGamePass {
                labels.append(Self.availableWithGamePassLabel)
            } else {
                labels.append(detail && plan == .pcGamePass ? "Included with PC Game Pass" : plan.label)
            }
            if detail, let date = membership.leavingOn {
                labels.append("Leaving \(plan.label) on \(date.formatted(date: .abbreviated, time: .omitted))")
            }
        }
        return labels
    }

    func heroAccessLabels() -> [String] {
        var labels: [String] = []
        if accessIsCurrent {
            switch ownership {
            case .purchased: labels.append("Owned")
            case .inLibraryUnknownAcquisition:
                if !subscriptionAcquisition { labels.append("In your library") }
            case .notInLibrary, .unknown: break
            }
            if subscriptionAcquisition, !availableWithGamePass { labels.append("Subscription (plan unknown)") }
        }
        for plan in Plan.allCases where memberships.contains(where: { $0.plan == plan }) {
            if plan == .pcGamePass, availableWithGamePass {
                labels.append(Self.availableWithGamePassLabel)
            } else {
                labels.append("In \(plan == .pcGamePass ? "PC Game Pass" : plan.label) catalog")
            }
        }
        return labels
    }
}

struct GameHeroAccess: View {
    let facts: GameFacts

    var body: some View {
        if !facts.heroAccessLabels().isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { labels }
                VStack(alignment: .leading, spacing: 4) { labels }
            }
            .font(.callout.weight(.medium))
            .accessibilityIdentifier("xodus.game.heroAccess")
        }
    }

    private var labels: some View {
        ForEach(facts.heroAccessLabels(), id: \.self) { Text($0) }
    }
}

extension LibraryGame {
    var facts: GameFacts {
        GameFacts(pc: pc, gamePass: gamePass, installed: installed, accessIsCurrent: accessIsCurrent,
                  availableWithGamePass: availableWithGamePass)
    }
}

struct AccessBadges: View {
    let facts: GameFacts
    var detail = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badges }
            VStack(alignment: .leading, spacing: 4) { badges }
        }
    }

    private var badges: some View {
        ForEach(facts.badgeLabels(detail: detail), id: \.self) { label in
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(white: 0.12), in: Capsule())
                .accessibilityIdentifier("xodus.game.accessBadge")
        }
    }
}
