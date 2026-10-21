// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

@MainActor
enum LibraryAccessChecks {
    static func run(check: (Bool, String) -> Void) throws {
        check(InstalledGameActionCopy.title(incomplete: false, installationIssue: false, launchIssue: false) == "View details",
              "An app-wide launch gate is not labelled as a broken game")
        check(OfflineGameCompatibility.snapshot?.products.isEmpty == false
              && OfflineGameCompatibility.snapshot?.products.values.allSatisfy({ !$0.antiCheat.isEmpty }) == true,
              "A sourced offline catalogue is bundled with explicit anti-cheat classification fields")
        let admitted = OfflineGameCompatibility.snapshot?.products.filter { $0.value.supported01 }
        let rawCatalogue = try JSONSerialization.jsonObject(with: Data(contentsOf:
            CompatibilityResources.catalogueURL())) as? [String: Any]
        let rawProducts = rawCatalogue?["products"] as? [String: [String: Any]] ?? [:]
        let declared = Set(rawProducts.filter { ($0.value["supported01"] as? Bool) == true }.map(\.key))
        check(!declared.isEmpty && Set(admitted?.keys.map { $0 } ?? []) == declared
              && declared.allSatisfy { OfflineGameCompatibility.validClearance(
                  productID: $0, product: rawProducts[$0] ?? [:]) }
              && admitted?.values.allSatisfy({ $0.packageFormat == "MSIXVC" && $0.antiCheat == "none" }) == true,
              "OX-9/UI-3: Real bundled admission exactly matches S4's evolving supported01 facts")
        check(GameSupportPolicy.issues(packageFormat: "MSIXVC", antiCheat: "none").isEmpty,
              "0.1 admits MSIXVC with explicit no-anti-cheat classification")
        for format in ["MSIX", "Appx", "EAppx", "UWP", "Win32", "Unspecified", ""] {
            check(GameSupportPolicy.issues(packageFormat: format, antiCheat: "none")
                .contains(where: { $0.kind == .packageType }),
                  "0.1 rejects non-MSIXVC package format: \(format)")
        }
        for technology in ["Easy Anti-Cheat", "BattlEye", "Vanguard"] {
            let issues = GameSupportPolicy.issues(packageFormat: "MSIXVC", antiCheat: technology)
            check(issues.contains(where: { $0.kind == .antiCheat }),
                  "0.1 rejects named anti-cheat: \(technology)")
        }
        for technology in [Optional("unknown"), "Unspecified", "", nil] {
            check(GameSupportPolicy.issues(packageFormat: "MSIXVC", antiCheat: technology).isEmpty,
                  "User-directed policy allows trying MSIXVC without inventing an anti-cheat blocker: \(technology ?? "missing")")
        }
        check(GameSupportPolicy.issues(packageFormat: nil, antiCheat: nil).count == 1
              && !GameSupportPolicy.issues(packageFormat: "MSIXVC / EAppx", antiCheat: "none").isEmpty
              && GameSupportPolicy.issues(packageFormat: "msixvc", antiCheat: " none ").isEmpty,
              "Missing or ambiguous formats fail closed; only a classified MSIXVC package is cleared")
        for technology in [Optional("none"), "Easy Anti-Cheat", "unknown", nil] {
            var input = rawCatalogue ?? [:]
            var product = rawProducts["9P4NV23Q6QC2"] ?? [:]
            product["antiCheat"] = technology
            input["products"] = ["9P4NV23Q6QC2": product]
            let database = try OfflineGameCompatibility.decode(JSONSerialization.data(withJSONObject: input))
            let entry = database.products["9P4NV23Q6QC2"]
            check(entry?.antiCheat == (technology ?? "unknown")
                  && entry?.supported01 == (technology == "none"),
                  "Catalogue loader accepts none, named and unknown anti-cheat; missing defaults to unknown: \(technology ?? "missing")")
        }
        for field in ["antiCheatEvidence", "packageFormatEvidence", "supported01"] {
            var input = rawCatalogue ?? [:]
            var product = rawProducts["9P4NV23Q6QC2"] ?? [:]
            product.removeValue(forKey: field)
            input["products"] = ["9P4NV23Q6QC2": product]
            do {
                _ = try OfflineGameCompatibility.decode(JSONSerialization.data(withJSONObject: input))
                check(false, "Bare none cannot admit a title missing \(field)")
            } catch { check(true, "Bare none cannot admit a title missing \(field)") }
        }
        var forged = rawProducts["9P4NV23Q6QC2"] ?? [:]
        forged["antiCheatEvidence"] = ["type": "package-scan", "packageScan": ["complete": true]]
        check(!OfflineGameCompatibility.validClearance(productID: "9P4NV23Q6QC2", product: forged),
              "A claimed complete scan without StoreID, digest, signature inventory and public checks is not clearance")
        let evidence = Data("""
            {"schemaVersion":1,"updatedAt":"2026-10-21T00:00:00Z","games":[
            {"productId":"FIXTURE00001","title":"Synthetic proof","verdict":"GAMEPLAY_PASS",
             "scope":"Movement observed; save persistence unverified.","engine":"synthetic",
             "runId":null,"screenshots":[{"path":"/synthetic/proof.png","caption":"Synthetic path only"}],
             "owner":"test","blocker":null}]}
            """.utf8)
        let decodedEvidence = try MacGameEvidence.decode(evidence)
        check(decodedEvidence.games.first?.scope.contains("save persistence unverified") == true
              && decodedEvidence.games.first?.screenshots.count == 1,
              "Mac evidence keeps observation scope and screenshot references without inventing save proof")
        let notTested = String(decoding: evidence, as: UTF8.self)
            .replacingOccurrences(of: #""engine":"synthetic""#, with: #""engine":null"#)
            .replacingOccurrences(of: "GAMEPLAY_PASS", with: "NOT_TESTED")
        check(try MacGameEvidence.decode(Data(notTested.utf8)).games.first?.engine == nil,
              "A not-tested title without a selected engine does not invalidate other real Mac evidence")
        let working = String(decoding: evidence, as: UTF8.self).replacingOccurrences(of: "GAMEPLAY_PASS", with: "WORKING")
        check(try MacGameEvidence.decode(Data(working.utf8)).games.first?.verdict == .working,
              "An externally qualified WORKING record preserves its scoped evidence without granting Windows package admission")
        check(MacGameEvidence.Verdict.gameplay.label == "Playable, not fully verified"
              && MacGameEvidence.Verdict.working.label == "Works on Mac"
              && MacGameEvidence.Verdict.blocked.label == "Not tested on Mac yet"
              && MacGameEvidence.Verdict.menu.label == "Starts, not yet playable"
              && MacGameEvidence.Verdict.failed.label == "Doesn't start yet"
              && decodedEvidence.games.first?.engineLabel == "Free Wine"
              && decodedEvidence.games.first?.provenEngine == "synthetic",
              "Cards use compact verdict/provider copy; only successful gameplay supplies automatic engine selection")
        let preLaunch = String(decoding: evidence, as: UTF8.self)
            .replacingOccurrences(of: #""blocker":null"#, with: #""blocker":null,"launchAttempted":false"#)
        check(try MacGameEvidence.decode(Data(preLaunch.utf8)).games.first?.statusLabel == "Not tested on Mac yet",
              "Installer-only failures never imply that a game was launched")
        check(NativeGameForeground.matchesGameWindow("Hollow Knight", title: "Hollow Knight: Voidheart Edition")
              && NativeGameForeground.matchesGameWindow("Hades II", title: "Hades II")
              && !NativeGameForeground.matchesGameWindow("Hollow Knight: Silksong", title: "Hollow Knight: Voidheart Edition")
              && !NativeGameForeground.matchesGameWindow("Wine System Tray", title: "Hades II")
              && !NativeGameForeground.matchesGameWindow("Other game", title: ""),
              "Foreground handoff targets the launched game's window, never unrelated Wine windows")
        check(NativeGameForeground.matchesOwner("Hollow Knight.exe", executables: ["Hollow Knight.exe"])
              && NativeGameForeground.matchesOwner("wine64-preloader", executables: ["Hades2.exe"])
              && !NativeGameForeground.matchesOwner("Microsoft Edge", executables: ["Hollow Knight.exe"]),
              "Foreground matching accepts the game's executable or Wine owner, never browser windows with game titles")
        check(GameLaunchArguments.parse(["--play-game", "FIXTURE00001"]) == .play("FIXTURE00001")
              && GameLaunchArguments.parse(["--play-game", "/tmp/game.exe"]) == nil
              && GameLaunchArguments.parse(["--play-game", "FIXTURE00001", "--fixture"]) == nil
              && GameLaunchArguments.parse(["--open-native-minecraft"]) == .nativeMinecraft,
              "App launch actions accept only exact product IDs/native Minecraft, never an executable or fixture override")
        check(NativeMinecraft.minecraftJavaPID(in: """
            123 501 /usr/bin/java
            124 501 /Users/example/Library/Application Support/minecraft/runtime/java-runtime/bin/java
            125 502 /Users/other/Library/Application Support/minecraft/runtime/java-runtime/bin/java
            """, uid: 501) == 124,
              "Native Minecraft detects only this user's bundled Minecraft Java executable, without reading credential-bearing arguments")
        for invalid in [
            String(decoding: evidence, as: UTF8.self).replacingOccurrences(of: "GAMEPLAY_PASS", with: "SHIPPED"),
            String(decoding: evidence, as: UTF8.self).replacingOccurrences(of: "/synthetic/proof.png", with: "https://invalid/proof.png")
        ] {
            do {
                _ = try MacGameEvidence.decode(Data(invalid.utf8))
                check(false, "Unknown verdicts and nonlocal screenshot references are rejected")
            } catch { check(true, "Unknown verdicts and nonlocal screenshot references are rejected") }
        }
        check(GameSupportPolicy.packageFormat(observed: "Win32", classified: "MSIXVC") == "MSIXVC"
              && GameSupportPolicy.packageFormat(observed: "Unknown", classified: "MSIXVC") == "MSIXVC"
              && GameSupportPolicy.packageFormat(observed: "EAppx", classified: "MSIXVC") == "EAppx"
              && GameSupportPolicy.packageFormat(observed: "Win32", classified: nil) == "Win32",
              "An extracted PE application model never erases its classified source container; a real unsupported container still vetoes")
        check(OfflineGameCompatibility.publisherEvidence(for: "9NP1P1WFS0LB")?.technologies == ["Easy Anti-Cheat"]
              && OfflineGameCompatibility.publisherEvidence(for: "9NP1P1WFS0LB")?.scope.contains("Campaign") == true
              && OfflineGameCompatibility.publisherEvidence(for: "9PB301R051CQ")?.scope.contains("Windows") == true
              && OfflineGameCompatibility.publisherEvidence(for: "BQVQTL3PCH05") == nil,
              "Publisher evidence is Store-ID/title bound, preserves mode/platform scope, and leaves NMS unknown")
        check(InstalledGameActionCopy.title(incomplete: true, installationIssue: false, launchIssue: false) == "Install required"
              && InstalledGameActionCopy.title(incomplete: false, installationIssue: true, launchIssue: false) == "Check installation"
              && InstalledGameActionCopy.title(incomplete: false, installationIssue: false, launchIssue: true) == "Review launch issue",
              "Installed actions name the specific recovery rather than a generic warning")
        let feedID = "00000000-0000-4000-8000-000000000001"
        let recentIDs = try GamePassCollectionSource.productIDs(Data("""
            [{"siglId":"\(feedID)"},{"id":"FIXTURE00002"},{"id":"FIXTURE00001"}]
            """.utf8), feedID: feedID)
        check(recentIDs == ["FIXTURE00002", "FIXTURE00001"],
              "Recently added retains official feed order rather than alphabetizing or using release date")
        let html = """
            <script src="/en-US/xbox-game-pass/games/js/xgpcatPopulate-MWF2.js"></script>
            <span class="colgroup collections-pc hidden">
            <a data-col="pcgaVTpopular"><span>Most popular</span></a>
            <a data-col="pdoPC"><span>Day one fixture</span></a>
            <span class="colgroup collections-cloud hidden">
            """
        let script = """
            var globalAdd = {
              "00000000-0000-4000-8000-000000000002": { colname: "benefitspc", plat: "pc",
                title: "Benefits fixture", spot: 2, startstring: "benefits" }
            }
            var newListIds = Object.keys(globalAdd);
            guidAmpt = {"pdoPC":"\(feedID)", "pcgaVTpopular":"00000000-0000-4000-8000-000000000003"};
            """
        let categories = try GamePassCollectionSource.definitions(html: html, script: script)
        check(categories.first?.key == "pdoPC" && categories.count == 3
              && categories.first?.feedID == feedID
              && categories.contains(where: { $0.title == "Benefits fixture" && $0.isBenefits }),
              "Official PC markup and script data dynamically supply lists and additions, with Day one first")
        check(try GamePassCollectionSource.scriptURL(in: html).host == "www.xbox.com",
              "Category configuration scripts resolve only on the official Xbox origin")
        do {
            _ = try GamePassCollectionSource.scriptURL(in: html.replacingOccurrences(
                of: "/en-US/", with: "https://untrusted.invalid/en-US/"))
            check(false, "Off-origin collection configuration must not be fetched")
        } catch { check(true, "Off-origin collection configuration is rejected") }
        for payload in [
            #"[{"siglId":"wrong"},{"id":"FIXTURE00001"}]"#,
            #"[{"siglId":"\#(feedID)"},{"id":"FIXTURE00001"},{"id":"FIXTURE00001"}]"#,
            #"[{"siglId":"\#(feedID)"},{"id":"invalid"}]"#
        ] {
            do {
                _ = try GamePassCollectionSource.productIDs(Data(payload.utf8), feedID: feedID)
                check(false, "Invalid recently-added metadata must be rejected")
            } catch { check(true, "Wrong, duplicated, malformed or empty recent feed fails explicitly") }
        }
        check(!LibrarySupportVisibility.issues(productID: "C2KDNLT2H7DM", installed: true,
                  packageFormat: "Win32", compatibility: nil).isEmpty
              && !LibrarySupportVisibility.isVisible(productID: "C2KDNLT2H7DM", installed: true,
                  packageFormat: "Win32", compatibility: nil, showsUnsupportedGames: false),
              "The supported filter excludes installed anti-cheat games too")
        check(LibrarySupportVisibility.issues(productID: "FIXTURE00001", installed: true,
                  packageFormat: "EAppx", compatibility: nil).contains(where: { $0.kind == .packageType }),
              "Actual installed package evidence contributes a blocker, not a fabricated success")
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
        let displayed = LibraryGame.displayCollection(installed: [local], account: collection)
        check(displayed.count == 2 && LibraryGame.visible(displayed, query: "", filter: .installed, sort: .title).count == 1
              && displayed.first(where: { $0.installed?.id == local.id })?.owned == false,
              "All counts known installed games without promoting them to owned or subscription access")
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
        let purchase = LibraryGame.collection(installed: [], owned: [
            PCGame(id: "FIXTURE00008", title: "Purchased game", artwork: nil, acquisitionKind: .purchased)
        ], products: [], gamePass: [], active: false)
        check(LibraryGame.heroCandidates(qualified: purchase + granted, catalogue: catalogue,
              continuingIDs: []).map(\.id) == granted.map(\.id),
              "First-run hero prioritizes current subscription-held games over purchases")
        check(LibraryGame.heroCandidates(qualified: purchase, catalogue: catalogue,
              continuingIDs: []).map(\.id) == purchase.map(\.id),
              "Without subscription-held titles the hero features purchased PC games")
        let browsingHeroes = LibraryGame.heroCandidates(qualified: [], catalogue: catalogue, continuingIDs: [])
        check(!browsingHeroes.isEmpty && browsingHeroes.allSatisfy { $0.pc == nil || $0.pc?.id == held.id }
              && browsingHeroes.contains { $0.eligibility == nil && !$0.owned },
              "A new or empty account still gets real catalogue heroes without fabricated account access")
        check(LibraryGame.visible(catalogue, query: "Public PC", filter: .gamePass, sort: .title).count == 1,
              "Game Pass filter searches the catalogue instead of only the owned-library overlap")
        check(LibraryGame.continuing(both, launchableIDs: [local.id]).map(\.id) == [local.id]
              && LibraryGame.localRecords(installed: [installedHeld], qualified: both, query: "", sort: .title).isEmpty,
              "SDD-LIB-04/05: exact held installation is featured and is not duplicated in unverified local records")
        check(LibraryGame.displayCollection(installed: [installedHeld], account: both).count == 1,
              "Unified Library does not count the same installed/account-held game twice")
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
        check(refusal.contains("download") && refusal.contains("doesn't establish")
              && refusal.contains("Check download access")
              && !refusal.contains("don't own") && !refusal.contains("isn't supported"),
              "SDD-LIB-07: ambiguous acquisition failure is not ownership loss or a demand to sign in")
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
