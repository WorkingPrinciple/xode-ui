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

    init(ownership: Ownership = .unknown, memberships: [Membership] = [], accessIsCurrent: Bool = false) {
        self.ownership = ownership
        self.memberships = memberships
        self.accessIsCurrent = accessIsCurrent
    }

    init(pc: PCGame?, gamePass: Bool, installed: InstalledGame? = nil, accessIsCurrent: Bool) {
        switch pc?.acquisitionKind {
        case .purchased: ownership = .purchased(nil)
        case .subscription, .unknown: ownership = .inLibraryUnknownAcquisition
        case nil: ownership = accessIsCurrent ? .notInLibrary : .unknown
        }
        // allgamespc proves PC catalogue membership, not an account plan.
        memberships = gamePass ? [Membership(plan: .pcGamePass)] : []
        coverage = .partial
        self.accessIsCurrent = accessIsCurrent
        if let installed { installation = .installed(installed.folder) }
        package = installed?.packageType?.label
        classification = pc != nil ? .game : .unresolved
    }

    func badgeLabels(detail: Bool = false) -> [String] {
        var labels: [String] = []
        switch ownership {
        case .purchased: labels.append("Owned")
        case .inLibraryUnknownAcquisition: labels.append("In your library")
        case .notInLibrary, .unknown: break
        }
        for plan in Plan.allCases {
            guard let membership = memberships.first(where: { $0.plan == plan }) else { continue }
            labels.append(detail && plan == .pcGamePass ? "Included with PC Game Pass" : plan.label)
            if detail, let date = membership.leavingOn {
                labels.append("Leaving \(plan.label) on \(date.formatted(date: .abbreviated, time: .omitted))")
            }
        }
        return labels
    }
}

extension LibraryGame {
    var facts: GameFacts {
        GameFacts(pc: pc, gamePass: gamePass, installed: installed, accessIsCurrent: accessIsCurrent)
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
