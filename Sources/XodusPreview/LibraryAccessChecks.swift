// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

@MainActor
enum LibraryAccessChecks {
    static func run(check: (Bool, String) -> Void) throws {
        let held = PCGame(id: "FIXTURE00001", title: "Held PC game", artwork: nil)
        let local = InstalledGame(id: UUID(), title: "Local unknown access", identityName: "Fixture.Local",
            version: "1.0.0.0", storeId: "FIXTURE00002", folder: "/synthetic/local",
            launcher: "/synthetic/local/launcher", importedAt: .distantPast,
            lastPlayedAt: Date())
        let publicPC = try LibraryGame.details(id: "FIXTURE00003", title: "Public PC candidate",
            market: "US", language: "en-US", source: "MicrosoftGamePassSigls:v3", pcCandidate: true)
        let console = try LibraryGame.details(id: "FIXTURE00004", title: "Console candidate",
            market: "US", language: "en-US", source: "MicrosoftGamePassSigls:v3", pcCandidate: false)
        let collection = LibraryGame.collection(installed: [local], owned: [held, held],
            products: [publicPC], gamePass: [publicPC, console], active: true)
        check(collection.map(\.id) == [held.id],
              "SDD-LIB-01/03: only held PC access enters Your Games; installation/public/global status is not a grant")
        check(collection.first?.pc?.acquisitionKind == .unknown,
              "SDD-LIB-01: held does not imply paid acquisition")
        let granted = LibraryGame.collection(installed: [], owned: [PCGame(id: "FIXTURE00005", title: "Pass grant",
            artwork: nil, acquisitionKind: .subscription)], products: [], gamePass: [], active: false)
        check(granted.first.flatMap(LibraryAccess.init) == .subscription
              && granted.first.map(LibraryAccess.badges) == [.subscription]
              && granted.first?.owned == false && granted.first?.eligibility == .gamePass
              && LibraryGame.visible(granted, query: "", filter: .owned, sort: .title).isEmpty
              && PCGameAcquisitionKind.merged(.subscription, .purchased) == .purchased
              && PCGameAcquisitionKind.merged(nil, .subscription) == .subscription,
              "M10: current subscription-held titles qualify without entering Owned or inventing a plan")
        let page = try JSONDecoder().decode(PCGamesCollectionPage.self, from: Data("""
            {"items":[{"productId":"FIXTURE00005","productKind":"Game","status":"Active","acquisitionType":"Recurring"},
            {"productId":"FIXTURE00006","productKind":"Game","status":"Active","acquisitionType":"Single"},
            {"productId":"FIXTURE00007","productKind":"Game","status":"Active"}]}
            """.utf8))
        check(page.items.map(\.acquisitionKind) == [.subscription, .purchased, .unknown],
              "Collections acquisitionType maps Recurring to a subscription grant and Single to a purchase")
        check(LibraryGame.visible(collection, query: "", filter: .all, sort: .title).count == 1,
              "SDD-LIB-05: Your Games count uses the qualified join")
        check(LibraryGame.visible(collection, query: "Local", filter: .all, sort: .recentlyPlayed).isEmpty,
              "SDD-LIB-04/05: personal search and recent sort do not promote local unknown access")
        check(LibraryGame.visible(collection, query: "", filter: .installed, sort: .title).isEmpty,
              "SDD-LIB-05: Installed personal filter does not certify access")
        check(LibraryGame.collection(installed: [local], owned: [], products: [publicPC],
            gamePass: [publicPC], active: false).isEmpty,
              "SDD-LIB-03: inactive and removed collection access do not survive via installation")
        check(LibraryGame.collection(installed: [], owned: [], products: [publicPC],
            gamePass: [publicPC], active: true).isEmpty,
              "SDD-LIB-02/06: a public partial feed and global probe cannot prove exact account Game Pass access")
        check(local.folder == "/synthetic/local" && local.launcher == "/synthetic/local/launcher",
              "SDD-LIB-04: classification never changes installation paths")
        let locals = LibraryGame.localRecords(installed: [local], qualified: collection, query: "", sort: .title)
        check(locals.count == 1 && locals[0].installed == local && !locals[0].owned && !locals[0].gamePass,
              "SDD-LIB-04: live local-record seam preserves exact registry data without access badges")
        check(collection.first?.eligibility == .owned && locals[0].eligibility == .installedUnknown,
              "M10: eligibility classifies held access as owned and installed-only as installedUnknown")
        check(LibraryGame.continuing(collection, launchableIDs: [local.id]).isEmpty,
              "SDD-LIB-05: local unknown access cannot become hero or Continue Playing")
        let installedHeld = InstalledGame(id: local.id, title: local.title, identityName: local.identityName,
            version: local.version, storeId: held.id, folder: local.folder, launcher: local.launcher,
            importedAt: local.importedAt, lastPlayedAt: local.lastPlayedAt)
        let overlap = try LibraryGame.details(id: held.id, title: "Public held candidate",
            market: "US", language: "en-US", source: "MicrosoftGamePassSigls:v3", pcCandidate: true)
        let both = LibraryGame.collection(installed: [installedHeld], owned: [held],
            products: [], gamePass: [overlap], active: true)
        check(both.count == 1 && both[0].owned && both[0].gamePass
              && LibraryAccess.badges(both[0]) == [.owned, .gamePass],
              "SDD-LIB-02: held access and explicitly public Game Pass membership remain independent overlapping facts")
        check(both[0].eligibility == .owned,
              "M10: eligibility prefers owned entitlement when a title is both owned and Game Pass")
        check(LibraryGame.visible(both, query: "", filter: .owned, sort: .title).count == 1
              && LibraryGame.visible(both, query: "", filter: .gamePass, sort: .title).count == 1,
              "SDD-LIB-05: Owned and Game Pass catalog filters overlap without double counting")
        let catalogue = LibraryGame.gamePassCatalog(installed: [installedHeld], owned: [held],
            products: [overlap, overlap, publicPC, console])
        check(catalogue.count == 2 && catalogue.first?.owned == true
              && LibraryAccess.badges(catalogue[0]) == [.owned, .gamePass]
              && catalogue.last?.owned == false,
              "Game Pass catalogue includes unowned PC members and independently marks overlapping held access")
        check(catalogue.last?.eligibility == nil,
              "M10: public Game Pass catalogue membership is not account eligibility")
        check(LibraryGame.visible(catalogue, query: "Public PC", filter: .gamePass, sort: .title).count == 1,
              "Game Pass filter searches the catalogue instead of only the owned-library overlap")
        check(LibraryGame.continuing(both, launchableIDs: [local.id]).map(\.id) == [local.id]
              && LibraryGame.localRecords(installed: [installedHeld], qualified: both, query: "", sort: .title).isEmpty,
              "SDD-LIB-04/05: exact held installation is featured and is not duplicated in unverified local records")
        let consoleOverlap = try LibraryGame.details(id: held.id, title: "Console product",
            market: "US", language: "en-US", source: "MicrosoftGamePassSigls:v3", pcCandidate: false)
        check(LibraryGame.collection(installed: [], owned: [held], products: [],
            gamePass: [consoleOverlap], active: true).first?.gamePass == false,
              "SDD-LIB-03: console catalogue flag cannot become PC Game Pass membership")
        let stale = LibraryGame.collection(installed: [installedHeld], owned: [held],
            products: [], gamePass: [overlap], active: true, accessIsCurrent: false)
        check(stale.isEmpty && LibraryGame.localRecords(installed: [installedHeld],
            qualified: stale, query: "", sort: .title).first?.eligibility == .installedUnknown,
              "M10: stale held evidence leaves Your Games and preserves the qualified local installation")
        check(GameDetailFacetCopy.access(acquisition: .subscription, current: true) == "Subscription (plan unknown)"
              && GameDetailFacetCopy.access(acquisition: .purchased, current: false).contains("refresh required")
              && GameDetailFacetCopy.access(acquisition: nil, current: true) == "Access not verified",
              "M10: detail facets never relabel subscription, stale or absent access as current Owned")
        let refusal = GameScriptError.failed(11).localizedDescription
        check(refusal.contains("account") && refusal.contains("sign-in")
              && refusal.contains("try again")
              && !refusal.contains("don't own") && !refusal.contains("isn't supported"),
              "SDD-LIB-07: authorization failure is distinct from ownership and unsupported package")
        check(GameScriptError.failed(12).localizedDescription != refusal,
              "SDD-LIB-07: package incompatibility retains a separate failure")
        check(LibraryAccess.summary(owned: false, catalogMembership: true, current: true)
                == "Access not verified · Game Pass catalog",
              "SDD-LIB-02/07: live detail facet never presents public membership as account access")
        check(DiscoverBrowse.canReviewInstall(owned: false, accessIsCurrent: false,
                  gamePass: true, subscriptionActive: true, pcCandidate: true)
              && collection.allSatisfy { $0.id != publicPC.id },
              "SDD-LIB-02: shared live action policy opens protected Game Pass review without admitting public-only personal access")
        check(LibraryAccess.summary(owned: true, catalogMembership: true, current: false)
                == "Saved Owned · refresh required · Game Pass catalog",
              "SDD-LIB-06: live detail facet labels retained access stale independently of catalog membership")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryPreservation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data("synthetic preserved game and save".utf8)
        let gameFile = root.appendingPathComponent("game")
        let saveFile = root.appendingPathComponent("save")
        try content.write(to: gameFile)
        try content.write(to: saveFile)
        let preserved = InstalledGame(id: UUID(), title: local.title, identityName: local.identityName,
            version: local.version, storeId: local.storeId, folder: root.path, launcher: gameFile.path,
            importedAt: local.importedAt)
        let withdrawn = LibraryGame.collection(installed: [preserved], owned: [], products: [],
            gamePass: [], active: false)
        let records = LibraryGame.localRecords(installed: [preserved], qualified: withdrawn, query: "", sort: .title)
        let gameBytes = try Data(contentsOf: gameFile), saveBytes = try Data(contentsOf: saveFile)
        check(records.first?.installed == preserved && gameBytes == content && saveBytes == content,
              "SDD-LIB-04: withdrawing access preserves real synthetic game/save bytes and reachable registry record")
    }
}
