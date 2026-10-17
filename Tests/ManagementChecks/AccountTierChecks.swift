// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

private struct AccountTierFixture: Decodable {
    let name: String
    let signedIn: Bool
    let accessIsCurrent: Bool
    let held: [PCGameAcquisitionKind]
    let gamePassActive: Bool?
    let expectedSummary: String
    let expectedOwned: Bool
    let expectedPass: String
    let entitlement: PCGameAcquisitionKind?
    let installed: Bool
    let verifiedGamePassAccess: Bool
    let expectedEligibility: LibraryEligibility?
}

extension Checks {
    func accountTierChecks() throws {
        let cases = try fixture("account-tiers").decode([AccountTierFixture].self)
        check(cases.count >= 14 && Set(cases.map(\.name)).count == cases.count,
              "M10: pinned entitlement fixture matrix has distinct cases")
        for item in cases {
            let account = AccountEntitlements.derive(signedIn: item.signedIn, held: item.held,
                gamePassActive: item.gamePassActive, accessIsCurrent: item.accessIsCurrent)
            let pass: String
            switch account.gamePass {
            case .unknown: pass = "unknown"
            case .inactive: pass = "inactive"
            case let .active(plan): pass = plan.rawValue
            }
            check(account.summary == item.expectedSummary && account.ownsGames == item.expectedOwned
                  && pass == item.expectedPass, "M10 account tier: \(item.name)")
            let eligibility = LibraryEligibility.evaluate(entitlement: item.entitlement,
                accessIsCurrent: item.accessIsCurrent && item.signedIn,
                verifiedGamePassAccess: item.verifiedGamePassAccess && item.signedIn,
                installed: item.installed)
            check(eligibility == item.expectedEligibility, "M10 per-title eligibility: \(item.name)")
            check(!account.tiers.contains(.gamePass(.console)) && !account.tiers.contains(.gamePass(.ultimate)),
                  "M10 PC-only evidence never invents Console or Ultimate: \(item.name)")
        }
        check(GamePassPlan.console.label == "Console Game Pass"
              && GamePassPlan.ultimate.label == "Game Pass Ultimate",
              "M10: complete plan taxonomy remains representable without autodetection")
        check(PCGameAcquisitionKind.merged(.subscription, .purchased) == .purchased,
              "M10: independent held purchase wins when a title also has a subscription grant")
    }
}
