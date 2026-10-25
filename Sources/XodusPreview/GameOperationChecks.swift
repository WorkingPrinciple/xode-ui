// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import XodusCore
import XodusManagement

@MainActor
enum GameOperationChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        // macOS temporary URLs retain the /var symlink; the receipt policy correctly refuses it.
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".xodus-game-operation-checks-\(UUID().uuidString)")
        let paths = GameScriptPaths(scripts: root.appendingPathComponent("scripts"),
            processed: root.appendingPathComponent("processed"), logs: root.appendingPathComponent("logs"),
            games: root.appendingPathComponent("Games"), journal: root.appendingPathComponent("private/operation.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check(false, "S3/S5/S6 synthetic files are cleaned after all fake scripts exit") }
        }
        for directory in [paths.scripts, paths.processed, paths.logs, paths.games] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        func privateFile(_ url: URL, _ text: String, mode: Int = 0o600) throws {
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        func script(_ command: GameScriptCommand, _ body: String) throws {
            try privateFile(paths.scripts.appendingPathComponent(command.file), """
                #!/bin/bash
                umask 077
                publish() { cat > "$1.tmp"; mv "$1.tmp" "$1"; }
                \(body)

                """, mode: 0o700)
        }
        func writeMode(_ mode: String) throws { try privateFile(root.appendingPathComponent("mode"), mode) }
        func wait(_ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<150 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw GameScriptError.timeout
        }
        let runID = InstalledGamesController.runID()
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let production = GameScriptPaths.production
        check(production.scripts == home.appendingPathComponent("Library/Application Support/Xodus/Runtime/scripts/macos")
              && production.processed == home.appendingPathComponent("Library/Application Support/XodusRemote/processed")
              && production.logs == home.appendingPathComponent("Library/Logs/XodusRemote")
              && production.games == home.appendingPathComponent("Games/Xodus")
              && production.journal == home.appendingPathComponent("Library/Application Support/Xodus/game-operation.json"),
              "B7 changes only the fixed script directory; receipts, logs, games and journal stay unchanged")
        check(GameScriptPaths.validRunID(runID), "S3/S5/S6 run IDs use the existing generated-only contract")
        for value in ["../status", "xodus-20260101T010101Z-AAAAAAAA", runID + "/../other", "custom-run"] {
            do { _ = try paths.receipt(value, suffix: "status"); check(false, "Receipt paths reject nongenerated IDs") }
            catch { check(true, "Receipt paths reject nongenerated IDs") }
            check(GameScriptFiles.log(runID: value, paths: paths) == nil, "Show log rejects user-controlled paths")
        }
        check(try paths.destination(title: "Game's title / É ! 42", productID: "FIXTURE00001").lastPathComponent
              == "Gamestitle42-Xbox", "S5 destination title is ASCII letters/digits only")
        check(try paths.destination(title: String(repeating: "a", count: 200), productID: "FIXTURE00001")
              .lastPathComponent.count == 101, "S5 destination is bounded")
        let parsed = try GameServiceStatus.parse(Data(
            #"{"serviceRunning":true,"signedIn":true,"accountHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","extra":1}"#.utf8))
        check(parsed.signedIn, "S3 status ignores unrelated fields")
        _ = try GameServiceSignOutResult.parse(Data(
            #"{"serviceRunning":false,"signedIn":false,"credentialsRemoved":true}"#.utf8))
        for value in [
            #"{"serviceRunning":true,"signedIn":false,"credentialsRemoved":true}"#,
            #"{"serviceRunning":false,"signedIn":true,"credentialsRemoved":true}"#,
            #"{"serviceRunning":false,"signedIn":false,"credentialsRemoved":false}"#,
            #"{"serviceRunning":false,"signedIn":false}"#,
            #"{"serviceRunning":false,"signedIn":false,"credentialsRemoved":1}"#,
            #"{"serviceRunning":false,"signedIn":false,"credentialsRemoved":true,"accountHash":"retained"}"#
        ] {
            do {
                _ = try GameServiceSignOutResult.parse(Data(value.utf8))
                check(false, "Service sign-out requires stopped service, signed-out state and confirmed credential removal")
            } catch {
                check(true, "Service sign-out requires stopped service, signed-out state and confirmed credential removal")
            }
        }
        for value in [#"{"serviceRunning":false,"signedIn":true}"#, #"{"serviceRunning":true}"#, #"{"serviceRunning":1,"signedIn":true}"#] {
            do { _ = try GameServiceStatus.parse(Data(value.utf8)); check(false, "S3 incomplete/inconsistent status is not signed in") }
            catch { check(true, "S3 incomplete/inconsistent status is not signed in") }
        }
        for phase in ["preparing", "downloading", "verifying", "configuring", "done", "failed"] {
            let value = try GameScriptProgress.parse(Data("""
                {"phase":"\(phase)","bytesDone":20,"bytesTotal":100,"message":"private diagnostic"}
                """.utf8))
            check(value.bytesDone == 20 && value.bytesTotal == 100 && !value.phase.title.contains("diagnostic"),
                  "S5 real-byte progress has product copy for \(phase)")
        }
        check(try GameScriptProgress.parse(Data(#"{"phase":"preparing","bytesDone":0,"bytesTotal":null}"#.utf8))
            .bytesTotal == nil, "S5 unknown size stays unknown")
        check(try GameScriptProgress.parse(Data(#"{"phase":"preparing","bytesDone":0,"bytesTotal":0}"#.utf8))
            .bytesTotal == 0, "S5 zero total is valid without a percentage denominator")
        for value in [#"{"phase":"invented","bytesDone":0}"#, #"{"phase":"downloading","bytesDone":-1}"#,
                      #"{"phase":"downloading","bytesDone":101,"bytesTotal":100}"#, #"{"phase":"downloading","bytesDone":1.5}"#,
                      #"{"phase":"failed","bytesDone":0,"message":"bad\u0001message"}"#] {
            do { _ = try GameScriptProgress.parse(Data(value.utf8)); check(false, "S5 malformed progress is refused") }
            catch { check(true, "S5 malformed progress is refused") }
        }
        let signed = root.appendingPathComponent("signed-in")
        let verifiedAccount = root.appendingPathComponent("verified-account")
        let verificationFails = root.appendingPathComponent("verification-fails")
        let verificationCancels = root.appendingPathComponent("verification-cancels")
        let statusFails = root.appendingPathComponent("status-fails")
        let verificationCalls = root.appendingPathComponent("verification-calls")
        let fixtureAccountHash = String(repeating: "a", count: 64)
        try script(.serviceStatus, """
            if [ -f '\(statusFails.path)' ]; then
                printf '{"serviceRunning":true}\\n' | publish '\(paths.processed.path)'/"$1.result.json"
                printf '0\\n' | publish '\(paths.processed.path)'/"$1.status"; exit 0
            fi
            if [ -f '\(signed.path)' ]; then signed=true; else signed=false; fi
            if [ "$signed" = true ] && [ -f '\(verifiedAccount.path)' ]; then account='"\(fixtureAccountHash)"'; else account=null; fi
            printf '{"serviceRunning":true,"signedIn":%s,"accountHash":%s}\\n' "$signed" "$account" | publish '\(paths.processed.path)'/"$1.result.json"
            printf '0\\n' | publish '\(paths.processed.path)'/"$1.status"
            """)
        try script(.serviceSignIn, """
            printf 'verification\\n' >> '\(verificationCalls.path)'
            if [ -f '\(verificationCancels.path)' ]; then
                printf '14\\n' | publish '\(paths.processed.path)'/"$1.status"; exit 14
            fi
            if [ -f '\(verificationFails.path)' ]; then
                printf '11\\n' | publish '\(paths.processed.path)'/"$1.status"; exit 11
            fi
            touch '\(signed.path)' '\(verifiedAccount.path)'
            printf '0\\n' | publish '\(paths.processed.path)'/"$1.status"
            """)
        try script(.check, """
            r="$1"; product="$2"; receipts='\(paths.processed.path)'
            printf '%s\\n' "$#" "$r" "$product" > '\(root.path)/check-arguments'
            printf '%s\\n' "$r" "$product" >> '\(root.path)/check-calls'
            printf 'Synthetic check log\\n' > '\(paths.logs.path)'/"$r.stderr.log"
            mode="$(cat '\(root.path)/mode')"
            trap 'printf "14\\n" | publish "$receipts/$r.status"; exit 14' TERM
            if [ "$mode" = checkslow ]; then while :; do sleep 0.1; done; fi
            if [ "$mode" = check11 ]; then printf '11\\n' | publish "$receipts/$r.status"; exit 11; fi
            if [ "$mode" = checkmissing ]; then exit 9; fi
            if [ "$mode" = checkunsupported ]; then supported=false; reason='"Neutral package is not supported."'
            else supported=true; reason=null; fi
            if [ "$mode" = checkwrongid ]; then product=OTHER0000001; fi
            printf '{"storeId":"%s","packageBytes":3200000000,"supported":%s,"reason":%s,"checkedAt":"2026-10-07T00:00:00Z","extra":"ignored"}\\n' "$product" "$supported" "$reason" | publish "$receipts/$r.result.json"
            printf '0\\n' | publish "$receipts/$r.status"
            """)
        try script(.gamePassStatus, """
            r="$1"; product="$2"; receipts='\(paths.processed.path)'
            printf '%s\\n' "$#" "$r" "$product" > '\(root.path)/gamepass-arguments'
            printf '%s\\n' "$r" "$product" >> '\(root.path)/gamepass-calls'
            printf 'Neutral Game Pass check\\n' > '\(paths.logs.path)'/"$r.stderr.log"
            mode="$(cat '\(root.path)/mode')"
            if [ "$mode" = passslow ]; then sleep 0.3; fi
            if [ "$mode" = pass11 ]; then printf '11\\n' | publish "$receipts/$r.status"; exit 11; fi
            if [ "$mode" = passmissing ]; then exit 9; fi
            if [ "$mode" = passmismatch ]; then printf '0\\n' | publish "$receipts/$r.status"; exit 3; fi
            case "$mode" in passfalse) active=false;; passnull) active=null;; passtype) active=1;; *) active=true;; esac
            if [ "$mode" = passretry ] || [ "$mode" = passretrywrong ]; then
                if [ "$product" = FIXTURE00002 ]; then active=null; fi
            fi
            if [ "$mode" = passretrywrong ] && [ "$product" = FIXTURE00003 ]; then product=OTHER0000001; fi
            if [ "$mode" = passwrongid ]; then product=OTHER0000001; fi
            printf '{"active":%s,"probeProductId":"%s","checkedAt":"2026-10-07T00:00:00Z","extra":1}\\n' "$active" "$product" | publish "$receipts/$r.result.json"
            printf '0\\n' | publish "$receipts/$r.status"
            """)
        try script(.stop, """
            r="$1"; product="$2"; receipts='\(paths.processed.path)'
            printf '%s\\n' "$#" "$r" "$product" > '\(root.path)/stop-arguments'
            printf 'Neutral Stop log\\n' > '\(paths.logs.path)'/"$r.stderr.log"
            mode="$(cat '\(root.path)/mode')"
            if [ "$mode" = stop21 ]; then printf '21\\n' | publish "$receipts/$r.status"; exit 21; fi
            kill -TERM "$(cat '\(root.path)/launcher-pid')" || exit 22
            if [ "$mode" = stopafter ]; then sleep 0.4; fi
            if [ "$mode" = stopmissing ]; then exit 9; fi
            if [ "$mode" = stopmismatch ]; then printf '0\\n' | publish "$receipts/$r.status"; exit 3; fi
            stopped=true
            if [ "$mode" = stopfalse ]; then stopped=false; fi
            if [ "$mode" = stopwrongid ]; then product=OTHER0000001; fi
            printf '{"storeId":"%s","stopped":%s,"extra":1}\\n' "$product" "$stopped" | publish "$receipts/$r.result.json"
            printf '0\\n' | publish "$receipts/$r.status"
            """)
        try script(.setup, """
            r="$1"; action="$2"; receipts='\(paths.processed.path)'
            printf '%s\\n' "$#" "$r" "$action" >> '\(root.path)/setup-arguments'
            printf 'Neutral setup log\\n' > '\(paths.logs.path)'/"$r.stderr.log"
            mode="$(cat '\(root.path)/mode')"
            if [ "$mode" = setupslow ]; then sleep 0.3; fi
            if [ "$mode" = setup31 ]; then
                printf '{"ready":false,"items":[]}\\n' | publish "$receipts/$r.result.json"
                printf '31\\n' | publish "$receipts/$r.status"; exit 31
            fi
            if [ "$mode" = setup22 ]; then printf '22\\n' | publish "$receipts/$r.status"; exit 22; fi
            if [ "$mode" = setupmissing ]; then exit 9; fi
            if [ "$mode" = setupmismatch ]; then printf '0\\n' | publish "$receipts/$r.status"; exit 3; fi
            if [ "$mode" = setupbad ]; then
                printf '{"ready":true,"items":[]}\\n' | publish "$receipts/$r.result.json"
            else
                ready=true; environment=true; fix=null
                if [ "$mode" = setupnotready ] || [ "$mode" = setupfailure ]; then ready=false; environment=false; fix='"Repair the game environment."'; fi
                if [ -f '\(signed.path)' ]; then signin=true; signinfix=null; else signin=false; signinfix='"Sign in for games."'; fi
                printf '{"ready":%s,"items":[{"id":"crossover","title":"CrossOver","ready":true,"fix":null},{"id":"environment","title":"Game environment","ready":%s,"fix":%s},{"id":"service","title":"Game service","ready":true,"fix":null},{"id":"signin","title":"Game sign-in","ready":%s,"fix":%s}],"extra":1}\\n' "$ready" "$environment" "$fix" "$signin" "$signinfix" | publish "$receipts/$r.result.json"
            fi
            if [ "$mode" = setupfailure ]; then printf '31\\n' | publish "$receipts/$r.status"; exit 31; fi
            printf '0\\n' | publish "$receipts/$r.status"
            """)
        let launcher = root.appendingPathComponent("fixture launcher.sh")
        try privateFile(launcher, "#!/bin/bash\nsleep 1\nexit 0\n", mode: 0o700)
        try script(.install, """
            r="$1"; product="$2"; folder="$3"; receipts='\(paths.processed.path)'
            printf '%s\\n' "$#" "$r" "$product" "$folder" "$PATH" "${XODUS_NEUTRAL_SECRET-unset}" > '\(root.path)/arguments'
            printf 'Synthetic operation log\\n' > '\(paths.logs.path)'/"$r.stderr.log"
            mode="$(cat '\(root.path)/mode')"
            if [ "$mode" = missing ]; then exit 9; fi
            if [ "$mode" = mismatch ]; then printf '0\\n' | publish "$receipts/$r.status"; exit 3; fi
            trap 'printf "14\\n" | publish "$receipts/$r.status"; exit 14' TERM
            printf '{"phase":"downloading","bytesDone":20,"bytesTotal":100}\\n' | publish "$receipts/$r.progress.json"
            if [ "$mode" = partialslow ]; then
                mkdir -p "$folder"
                printf '<Game><Identity Name="Fixture.Game" Version="1.2.3.4"/><StoreId>%s</StoreId></Game>' "$product" > "$folder/MicrosoftGame.config"
                while :; do sleep 0.1; done
            fi
            if [ "$mode" = slow ]; then while :; do sleep 0.1; done; fi
            if [ "$mode" = invalidprogress ]; then
                printf '{"phase":"downloading","bytesDone":-1}\\n' | publish "$receipts/$r.progress.json"
                while :; do sleep 0.1; done
            fi
            if [ "$mode" = 12progress ]; then
                printf '{"phase":"failed","bytesDone":20,"bytesTotal":100,"message":"Neutral terminal package reason."}\\n' | publish "$receipts/$r.progress.json"
                printf '12\\n' | publish "$receipts/$r.status"
                exit 12
            fi
            if [ "$mode" = 13progress ]; then
                printf '{"phase":"failed","bytesDone":20,"bytesTotal":100,"message":"Authorized broker returned no account credentials."}\\n' | publish "$receipts/$r.progress.json"
                printf '13\\n' | publish "$receipts/$r.status"
                exit 13
            fi
            case "$mode" in 10|11|12|13|14) printf '%s\\n' "$mode" | publish "$receipts/$r.status"; exit "$mode";; esac
            mkdir -p "$folder"
            if [ "$mode" != badconfig ]; then
                printf '<Game><Identity Name="Fixture.Game" Version="1.2.3.4"/><ShellVisuals DefaultDisplayName="Fixture Game"/><StoreId>%s</StoreId></Game>' "$product" > "$folder/MicrosoftGame.config"
            fi
            if [ "$mode" = wrongid ]; then resultid=OTHER0000001; else resultid="$product"; fi
            printf '{"folder":"%s","launcher":"%s","storeId":"%s","title":"Ignored result title","bottle":"ignored","contentId":"ignored","bytesOnDisk":42}\\n' "$folder" '\(launcher.path)' "$resultid" | publish "$receipts/$r.result.json"
            if [ "$mode" = resultfailure ]; then printf '13\\n' | publish "$receipts/$r.status"; exit 13; fi
            printf '0\\n' | publish "$receipts/$r.status"
            exit 0
            """)
        try script(.uninstall, """
            printf '%s\\n' "$2" >> '\(root.path)/uninstall-calls'
            mode="$(cat '\(root.path)/mode')"
            if [ "$mode" = preservefail ]; then code=20; else code=0; fi
            printf '%s\\n' "$code" | publish '\(paths.processed.path)'/"$1.status"
            exit "$code"
            """)
        _ = try GameScriptFiles.script(.serviceStatus, paths: paths)
        _ = try GameScriptFiles.read(paths.journal, missingAllowed: true)
        let store = InstalledGameStore(file: root.appendingPathComponent("registry/installed-games.json"))
        let catalogue = OfflineGameCompatibility(version: 1, checkedAt: "2026-10-21T00:00:00Z",
            market: "GB", packageSource: "Synthetic unit-test classification", antiCheatReference: "Unit test",
            products: Dictionary(uniqueKeysWithValues: (1...5).map {
                (String(format: "FIXTURE%05d", $0),
                 OfflineGameCompatibility.Entry(title: nil, packageFormat: "MSIXVC", pcPackageIdentified: true,
                    antiCheat: "none", technologyReferences: [], referencePlatforms: []))
            }))
        let installed = InstalledGamesController(store: store, launchingDuration: .milliseconds(50),
            defaultEngine: { .crossover }, detectAvailability: { RunnerAvailability([.crossover]) },
            compatibilityCatalogue: catalogue)
        let operations = GameOperationsController(installed: installed, paths: paths,
                                                  compatibilityCatalogue: catalogue)
        check(operations.serviceStatus == nil && !operations.serviceBusy && operations.operation == nil
              && operations.gamePassStatus == nil && !operations.gamePassActive
              && installed.stoppingGameID == nil && operations.setupResult == nil && !operations.setupBusy
              && !operations.setupNeedsAttention && !FileManager.default.fileExists(atPath: paths.journal.path),
              "S3/S5/S6 construction performs no script, credential or journal I/O")
        await installed.load()
        var installedNotifications = 0
        let observation = operations.objectWillChange.sink { installedNotifications += 1 }
        installed.serviceSignInActive = true
        installed.serviceSignInActive = false
        check(installedNotifications >= 2,
              "S3/S5 installed-state changes invalidate computed game-service and consent controls")
        observation.cancel()
        await operations.restore()
        let signInState = AppState(installedGames: installed, gameScriptPaths: paths)
        await signInState.refreshGameServiceStatusAfterSignIn()
        check(signInState.gameOperations.serviceStatus?.signedIn == false
              && signInState.gameOperations.serviceError == nil
              && !FileManager.default.fileExists(atPath: verificationCalls.path),
              "Completing launcher sign-in refreshes game-service status without starting a second Microsoft sign-in")
        operations.refreshService()
        await operations.waitForService()
        if let error = operations.serviceError { print("NEUTRAL service-status failure: \(error)") }
        check(operations.serviceStatus?.signedIn == false && operations.serviceError == nil,
              "S3 explicit status reads only the service-owned receipt")
        check(operations.serviceSignInActionTitle == "Sign in for games"
              && operations.serviceLabel == "Sign in for games" && !operations.serviceAccountNeedsVerification,
              "XO-018: Signed-out game service offers normal sign-in, not identity verification")
        check(GameServiceAccountView(operations: operations, library: PCGamesController()).accountStatusText
              == "Xbox sign-in couldn't be confirmed",
              "Plain Xbox status does not treat an unconfirmed backend boolean as proven credential removal")
        operations.signInForGames()
        await operations.waitForService()
        if let error = operations.serviceError { print("NEUTRAL service-signin failure: \(error)") }
        check(operations.serviceStatus?.signedIn == true
              && operations.serviceStatus?.accountHash == fixtureAccountHash
              && !installed.serviceSignInActive,
              "S3 explicit sign-in is followed by a fresh account-bound status check; no token transfer")
        let callsBeforeStatus = try String(contentsOf: verificationCalls, encoding: .utf8)
        operations.refreshService()
        await operations.waitForService()
        let callsAfterStatus = try String(contentsOf: verificationCalls, encoding: .utf8)
        check(operations.serviceStatus?.signedIn == true
              && operations.serviceStatus?.accountHash == fixtureAccountHash
              && !operations.serviceAccountNeedsVerification
              && operations.serviceLabel == "Signed in for games"
              && operations.serviceSignInActionTitle == nil
              && operations.serviceAccountSymbol == "checkmark.circle"
              && callsAfterStatus == callsBeforeStatus,
              "XO-018: Bound saved sign-in remains ready without another user-visible account action")
        try FileManager.default.removeItem(at: verifiedAccount)
        operations.refreshService()
        await operations.waitForService()
        check(operations.serviceStatus == nil && operations.serviceError != nil
              && !operations.serviceAccountNeedsVerification,
              "XO-018: signedIn without an account binding is rejected, never exposed as a partial login state")
        try privateFile(verificationFails, "Neutral refused verification.")
        operations.signInForGames()
        check(operations.serviceBusy && operations.serviceSigningIn && installed.serviceSignInActive
              && !operations.canSignIn && !operations.canQuit,
              "XO-018: Explicit verification uses the existing service/Play/Quit fences")
        operations.signInForGames()
        await operations.waitForService()
        let callsAfterFailure = try String(contentsOf: verificationCalls, encoding: .utf8)
        check(operations.serviceError?.contains("authorization wasn't confirmed") == true
              && operations.serviceStatus == nil && operations.serviceSignInActionTitle != nil
              && !operations.serviceBusy && !installed.serviceSignInActive && operations.canQuit
              && callsAfterFailure.split(separator: "\n").count == 2,
              "XO-018: Verification failure is visible, releases joined holds, preserves retry and deduplicates activation")
        try FileManager.default.removeItem(at: verificationFails)
        operations.signInForGames()
        await operations.waitForService()
        check(operations.serviceStatus?.accountHash == fixtureAccountHash && operations.serviceError == nil
              && !operations.serviceAccountNeedsVerification && operations.serviceSignInActionTitle == nil
              && operations.serviceLabel == "Signed in for games" && operations.serviceAccountSymbol == "checkmark.circle"
              && !installed.serviceSignInActive && operations.canQuit,
              "XO-018: Explicit retry consumes a fresh bound status and removes the verification action")
        let game = PCGame(id: "FIXTURE00001", title: "Fixture Game", artwork: nil)
        for (kind, labels) in [
            (PCGameAcquisitionKind.unknown, ["In your library"]),
            (.purchased, ["Owned"])
        ] {
            let held = PCGame(id: game.id, title: game.title, artwork: nil, acquisitionKind: kind)
            let row = LibraryGame.collection(installed: [], owned: [held], products: [],
                gamePass: [], active: false)[0]
            let action = GameInstallAction(game: held, operations: operations,
                enabled: DiscoverBrowse.canReviewInstall(owned: row.pc != nil,
                    accessIsCurrent: row.accessIsCurrent, gamePass: row.gamePass,
                    subscriptionActive: false, pcCandidate: true))
            check(row.facts.badgeLabels() == labels && row.installed == nil
                  && row.owned == (kind == .purchased) && action.actionTitle == "Install" && action.canInstall
                  && operations.installConsent == nil && !operations.canConfirmInstall,
                  "REQ-50: \(kind) held acquisition pairs truthful uninstalled badges with review, not unchecked confirmation")
        }
        let publicProduct = try LibraryGame.details(id: game.id, title: game.title,
            market: "US", language: "en-US", source: "MicrosoftGamePassSigls:v3", pcCandidate: true)
        let publicRow = LibraryGame.gamePassCatalog(installed: [], owned: [], products: [publicProduct])[0]
        for subscription in [false, true] {
            let action = GameInstallAction(game: PCGame(product: publicProduct), operations: operations,
                enabled: DiscoverBrowse.canReviewInstall(owned: false, accessIsCurrent: false,
                    gamePass: publicRow.gamePass, subscriptionActive: subscription, pcCandidate: true))
            check(publicRow.facts.badgeLabels() == ["Game Pass"] && publicRow.eligibility == nil
                  && !publicRow.owned && action.canInstall == subscription && !operations.canConfirmInstall,
                  "REQ-50: Public-only Game Pass stays membership-only; active probe permits review, never confirmation")
            let retainedOwnedAction = GameInstallAction(game: game, operations: operations,
                enabled: DiscoverBrowse.canReviewInstall(owned: true, accessIsCurrent: false,
                    gamePass: true, subscriptionActive: subscription, pcCandidate: true))
            check(retainedOwnedAction.canInstall == subscription && !operations.canConfirmInstall,
                  "REQ88: Owned-but-stale representation does not shadow independently verified subscription review")
        }
        check(operations.installUnavailableReason == nil,
              "REQ88: Ready operation has no invented installation blocker")
        let unknownOperations = GameOperationsController(installed: installed, paths: paths,
                                                          compatibilityCatalogue: nil)
        let unknownAction = GameInstallAction(game: game, operations: unknownOperations,
            enabled: DiscoverBrowse.canReviewInstall(owned: true, accessIsCurrent: true,
                gamePass: false, subscriptionActive: false, pcCandidate: true))
        check(GameFacts(pc: game, gamePass: false, accessIsCurrent: true).support == .unknown
              && unknownOperations.supportIssues(productID: game.id).isEmpty && unknownAction.canInstall
              && unknownOperations.compatibility[game.id] == nil && !unknownOperations.canConfirmInstall,
              "REQ-50: Unknown compatibility is not an unsupported fact or a verified install permit")
        for (format, technology) in [("MSIXVC", "Easy Anti-Cheat"),
                                     ("Appx", "none"), ("EAppx", "none")] {
            let blockedCatalogue = OfflineGameCompatibility(version: 1, checkedAt: catalogue.checkedAt,
                market: catalogue.market, packageSource: catalogue.packageSource,
                antiCheatReference: catalogue.antiCheatReference,
                products: [game.id: .init(title: game.title, packageFormat: format, pcPackageIdentified: true,
                    antiCheat: technology, technologyReferences: [], referencePlatforms: [])])
            let blocked = GameOperationsController(installed: installed, paths: paths,
                                                    compatibilityCatalogue: blockedCatalogue)
            await blocked.prepareInstall(game)
            check(blocked.installConsent == nil && blocked.operation == nil && !installed.mutationActive
                  && blocked.error?.contains(technology == "none" ? format.uppercased() : technology) == true,
                  "UI-5: \(format)/\(technology) is rejected before a compatibility script or download starts")
            let forged = GameInstallConsent(game: game, destination: paths.games.appendingPathComponent("blocked"),
                freeBytes: 100_000_000_000, installedID: nil,
                compatibility: GameCompatibilityResult(storeId: game.id, packageBytes: 1, supported: true,
                    reason: nil, checkedAt: catalogue.checkedAt))
            blocked.installConsent = forged
            check(!blocked.canConfirmInstall, "UI-5: A positive runtime verdict cannot enable unsupported confirmation")
            check(GameFacts(pc: game, gamePass: false, accessIsCurrent: true).badgeLabels() == ["In your library"]
                  && !blocked.supportIssues(productID: game.id).isEmpty && !blocked.canConfirmInstall,
                  "REQ-50: Known unsupported classification blocks confirmation without erasing held acquisition facts")
            blocked.confirmInstall(forged)
            check(blocked.operation == nil && blocked.installConsent == nil && !installed.mutationActive
                  && blocked.error?.contains(technology == "none" ? format.uppercased() : technology) == true,
                  "UI-5: Direct confirmation independently rejects unsupported classification")
            let queued = await blocked.runQueuedOperation(GameOperationRecord(
                id: InstalledGamesController.runID(), kind: .install, productID: game.id,
                title: game.title, destination: forged.destination.path, installedID: nil),
                onProgress: { _ in })
            check(queued == .fail(code: 12) && blocked.operation == nil,
                  "UI-5: Queued installs cannot bypass 0.1 classification")
        }
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("check-arguments").path)
              && !FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path),
              "UI-5: Rejected admission produced no script side effect")
        func checkUnrelatedDetail(_ controller: GameOperationsController, owner: String, stage: String) {
            let unrelatedID = owner == "FIXTURE00001" ? "FIXTURE00002" : "FIXTURE00001"
            let unrelated = GameOperationProgressView(operations: controller, productID: unrelatedID)
            check(unrelated.operationError == nil && unrelated.operationNotice == nil
                  && unrelated.presentedOperation == nil && unrelated.operationTitle == nil
                  && !unrelated.showsPreparation && unrelated.preparationCancelTitle == nil
                  && unrelated.installCancelTitle == nil && !unrelated.showsLog && !unrelated.showsGameSignIn,
                  "XO-022: Unrelated detail hides title-owned \(stage), including recovery/log/cancel/sign-in controls")
            let windows = NSApplication.shared.windows.count
            let host = NSHostingView(rootView: unrelated)
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: 560, height: 300)
            host.layoutSubtreeIfNeeded()
            check(host.window == nil && NSApplication.shared.windows.count == windows,
                  "XO-022: Scoped \(stage) presentation mounts detached without a window or navigation mutation")
        }
        let compatibilityData = """
            {"storeId":"\(game.id)","packageBytes":null,"supported":true,"reason":null,"checkedAt":"2026-10-07T00:00:00.123Z"}
            """
        let compatible = try GameCompatibilityResult.parse(Data(compatibilityData.utf8), productID: game.id)
        check(compatible.supported && compatible.packageBytes == nil && compatible.badge == "Available to install",
              "B3: Support receipt preserves unknown size and validates fractional ISO dates")
        for invalid in [
            compatibilityData.replacingOccurrences(of: game.id, with: "OTHER0000001"),
            compatibilityData.replacingOccurrences(of: "\"packageBytes\":null", with: "\"packageBytes\":-1"),
            compatibilityData.replacingOccurrences(of: "\"supported\":true", with: "\"supported\":1"),
            compatibilityData.replacingOccurrences(of: "2026-10-07T00:00:00.123Z", with: "not-a-date")
        ] {
            do {
                _ = try GameCompatibilityResult.parse(Data(invalid.utf8), productID: game.id)
                check(false, "B3: Invalid identity/size/support/time cannot become Plays on Mac")
            } catch { check(true, "B3: Invalid identity/size/support/time cannot become Plays on Mac") }
        }
        await operations.loadCompatibility(productID: game.id)
        check(operations.compatibility[game.id] == nil && operations.compatibilityErrors[game.id] == nil,
              "B3: Missing cache supplies no badge and never starts a check")
        try FileManager.default.createDirectory(at: paths.compatibility, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let cached = try paths.compatibilityFile(productID: game.id)
        for (text, expected) in [(#"{"active":true}"#, Optional(true)), (#"{"active":false}"#, Optional(false)),
                                 (#"{"active":null}"#, Optional<Bool>.none)] {
            try privateFile(paths.gamePassStatus, text)
            await operations.loadGamePassCache()
            check(operations.gamePassStatus?.active == expected && operations.gamePassFromCache
                  && operations.gamePassError == nil && !operations.gamePassActive
                  && operations.gamePassLabel.contains("check required"),
                  "M10: cached Game Pass status is historical, never current access or install authority")
        }
        for text in ["{}", #"{"active":1}"#, #"{"active":true,"checkedAt":"invalid"}"#,
                     #"{"active":true,"probeProductId":"../escape"}"#] {
            try privateFile(paths.gamePassStatus, text)
            await operations.loadGamePassCache()
            check(!operations.gamePassActive && operations.gamePassStatus == nil && operations.gamePassError != nil,
                  "B5 malformed cache is explicit Unknown, never subscription access")
        }
        try privateFile(paths.gamePassStatus, #"{"active":true}"#, mode: 0o644)
        await operations.loadGamePassCache()
        check(!operations.gamePassActive && operations.gamePassError != nil,
              "B5 nonprivate cache cannot authorize Game Pass Install")
        try FileManager.default.removeItem(at: paths.gamePassStatus)
        await operations.loadGamePassCache()
        check(operations.gamePassStatus == nil && operations.gamePassError == nil,
              "B5 removed cache clears prior subscription evidence")
        let probeID = "FIXTURE00002"
        func discoveryProduct(_ id: String, pc: Bool = true) throws -> CatalogProduct {
            try JSONDecoder().decode(CatalogProduct.self, from: Data("""
                {"productID":"\(id)","title":"Neutral game","market":"US","language":"en-US",
                "source":"MicrosoftGamePassSigls:v3","checkedAt":"2026-10-07T00:00:00Z",
                "freshness":"current","editions":[],"pcCatalogCandidate":\(pc),
                "artwork":[],"artworkStatus":"absent"}
                """.utf8))
        }
        let discoveryProducts = try [discoveryProduct(game.id), discoveryProduct(probeID)]
        func probes(_ products: [CatalogProduct], cache: [String: GameCompatibilityResult] = [:]) -> [String] {
            GameOperationsController.gamePassProbes(discoveryProducts: products, ownedGames: [game], compatibility: cache)
        }
        check(probes(discoveryProducts) == [probeID]
              && GameOperationsController.gamePassProbes(discoveryProducts: discoveryProducts,
                                                          ownedGames: nil, compatibility: [:]).isEmpty
              && probes([discoveryProducts[0]]).isEmpty,
              "B5 probe requires loaded ownership and a loaded, valid, nonowned discovery ID")
        operations.checkGamePass(discoveryProducts: discoveryProducts, ownedGames: nil)
        check(operations.gamePassError != nil
              && !FileManager.default.fileExists(atPath: root.appendingPathComponent("gamepass-arguments").path),
              "B5 missing ownership cannot launch a subscription probe")
        for mode in ["passactive", "passfalse", "passnull", "passwrongid", "passtype", "pass11", "passmissing", "passmismatch"] {
            try writeMode(mode)
            operations.checkGamePass(discoveryProducts: discoveryProducts, ownedGames: [game])
            await operations.waitForMutation()
            if mode == "passactive" {
                check(operations.gamePassActive && operations.gamePassStatus?.probeProductId == probeID
                      && operations.gamePassError == nil && !operations.gamePassFromCache,
                      "B5 validated live receipt alone refreshes Active")
            } else if mode == "passfalse" || mode == "passnull" {
                check(!operations.gamePassActive && operations.gamePassError == nil,
                      "B5 inactive/unknown receipt disables subscription access without inventing expiry")
            } else {
                check(!operations.gamePassActive && operations.gamePassError != nil && operations.gamePassLog != nil,
                      "B5 wrong identity/type/status or failed probe yields Unknown and Show log")
                if mode == "pass11" {
                    check(operations.gamePassError?.contains("doesn't establish") == true,
                         "An ambiguous Game Pass acquisition failure does not claim expired sign-in or subscription")
                }
            }
            check(!installed.mutationActive && operations.canQuit,
                  "B5 joined probe releases the one-mutation and normal-Quit fences")
        }
        try writeMode("passslow")
        operations.checkGamePass(discoveryProducts: discoveryProducts, ownedGames: [game])
        check(operations.gamePassBusy && installed.mutationActive && !operations.canQuit
              && !operations.canStartMutation && !operations.canSignIn && !operations.canCancel,
              "B5 explicit probe reserves the existing fence and cannot be cancelled as an installation")
        let busyInstall = GameInstallAction(game: game, operations: operations, enabled: true)
        check(!busyInstall.canInstall && busyInstall.unavailableReason?.contains("Game Pass") == true,
              "REQ88: Current title access cannot bypass operation-busy fences; the blocking check is explained")
        check(operations.isBusy && !operations.hasDownloadStatus,
              "Downloads keeps its empty action during unrelated Game Pass work")
        operations.checkGamePass(discoveryProducts: discoveryProducts, ownedGames: [game])
        await operations.loadGamePassCache()
        await operations.waitForMutation()
        let passArguments = try String(contentsOf: root.appendingPathComponent("gamepass-arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        check(passArguments.count == 3 && passArguments[0] == "2"
              && GameScriptPaths.validRunID(passArguments[1]) && passArguments[2] == probeID && operations.gamePassActive,
              "B5 script receives only generated runID and nonowned Store ID; cache cannot race the probe")
        let later = try discoveryProduct("FIXTURE00003")
        let fallback = try discoveryProduct("FIXTURE00004", pc: false)
        let fourth = try discoveryProduct("FIXTURE00005")
        let ranked = [fallback, discoveryProducts[0], later, discoveryProducts[1], later, fourth]
        check(probes(ranked) == [later.id, probeID, fourth.id, fallback.id],
              "B5 PC candidates take precedence while preserving feed order and exact-ID deduplication")
        for reason in ["No PC game package is available.", "This game's PACKAGE TYPE isn't supported on Mac yet."] {
            let unsupported = GameCompatibilityResult(storeId: later.id, packageBytes: nil, supported: false,
                reason: reason, checkedAt: "2026-10-07T00:00:00Z")
            check(probes(ranked, cache: [later.id: unsupported]) == [probeID, fourth.id, fallback.id],
                  "B5 cached no-PC-package and package-type failures are skipped, case insensitively")
        }
        let otherUnsupported = GameCompatibilityResult(storeId: later.id, packageBytes: nil, supported: false,
            reason: "This game needs Xbox features Xodus can't provide.", checkedAt: "2026-10-07T00:00:00Z")
        check(probes(ranked, cache: [later.id: otherUnsupported]).first == later.id,
              "B5 an unrelated gameplay compatibility failure does not eliminate a licensing probe")
        let retryProducts = [discoveryProducts[1], later, fourth, fallback]
        for (mode, expectedIDs) in [
            ("passretry", [probeID, later.id]), ("passfalse", [probeID]),
            ("passnull", [probeID, later.id, fourth.id]), ("passretrywrong", [probeID, later.id])
        ] {
            try privateFile(root.appendingPathComponent("gamepass-calls"), "")
            try writeMode(mode)
            operations.checkGamePass(discoveryProducts: retryProducts, ownedGames: [game])
            await operations.waitForMutation()
            let calls = try String(contentsOf: root.appendingPathComponent("gamepass-calls"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            check(stride(from: 1, to: calls.count, by: 2).map { calls[$0] } == expectedIDs
                  && Set(stride(from: 0, to: calls.count, by: 2).map { calls[$0] }).count == expectedIDs.count,
                  "B5 null-only retries stop at three with distinct generated run IDs; false/errors do not retry")
            check(mode == "passretry" ? operations.gamePassActive
                  : mode == "passretrywrong" ? operations.gamePassError != nil && operations.gamePassStatus == nil
                  : !operations.gamePassActive && operations.gamePassError == nil,
                  "B5 each retry strictly matches its own probe ID; exhausted null remains Unknown")
            check(operations.canQuit && !installed.mutationActive,
                  "B5 the entire bounded retry operation releases its single mutation fence")
        }
        let excludedCache = try paths.compatibilityFile(productID: probeID)
        try privateFile(excludedCache, """
            {"storeId":"\(probeID)","packageBytes":null,"supported":false,
            "reason":"No PC game package is available.","checkedAt":"2026-10-07T00:00:00Z"}
            """)
        try privateFile(root.appendingPathComponent("gamepass-calls"), "")
        try writeMode("passactive")
        operations.checkGamePass(discoveryProducts: retryProducts, ownedGames: [game])
        await operations.waitForMutation()
        check(operations.gamePassStatus?.probeProductId == later.id,
              "B5 explicit Check reads strict disk compatibility before selection even without tile loading")
        operations.checkGamePass(discoveryProducts: [discoveryProducts[1]], ownedGames: [game])
        await operations.waitForMutation()
        check(operations.gamePassStatus == nil && operations.gamePassError != nil && operations.canQuit,
              "B5 no eligible cached probe is a visible no-script failure, never Active")
        try privateFile(excludedCache, #"{"supported":false,"reason":"no PC game package"}"#)
        operations.checkGamePass(discoveryProducts: discoveryProducts, ownedGames: [game])
        await operations.waitForMutation()
        check(operations.gamePassStatus?.probeProductId == probeID && operations.compatibilityErrors[probeID] != nil,
              "B5 malformed compatibility cache cannot silently exclude a probe")
        try FileManager.default.removeItem(at: excludedCache)
        let setupData = """
            {"ready":true,"items":[{"id":"crossover","title":"CrossOver","ready":true,"fix":null},
            {"id":"environment","title":"Game environment","ready":true,"fix":null},
            {"id":"service","title":"Game service","ready":true,"fix":null},
            {"id":"signin","title":"Game sign-in","ready":false,"fix":"Sign in for games."}],"extra":1}
            """
        let setup = try GameSetupResult.parse(Data(setupData.utf8))
        check(setup.ready && setup.needsSignIn && setup.orderedItems.map(\.id) == GameSetupResult.Item.ID.allCases,
              "B8 setup readiness and sign-in stay independent; every required item is displayed in stable order")
        for invalid in [
            setupData.replacingOccurrences(of: "\"id\":\"environment\"", with: "\"id\":\"crossover\""),
            setupData.replacingOccurrences(of: "\"id\":\"service\"", with: "\"id\":\"unknown\""),
            setupData.replacingOccurrences(of: "\"ready\":true", with: "\"ready\":1"),
            setupData.replacingOccurrences(of: "\"title\":\"CrossOver\"", with: "\"title\":\"\""),
            #"{"ready":true,"items":[]}"#
        ] {
            do { _ = try GameSetupResult.parse(Data(invalid.utf8)); check(false, "B8 malformed setup cannot become Ready") }
            catch { check(true, "B8 malformed setup cannot become Ready") }
        }
        try writeMode("setupnotready")
        try FileManager.default.removeItem(at: signed)
        operations.checkSetupOnce()
        operations.checkSetupOnce()
        await operations.waitForSetup()
        let firstSetupArguments = try String(contentsOf: root.appendingPathComponent("setup-arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        check(firstSetupArguments.count == 3 && firstSetupArguments[0] == "2"
              && GameScriptPaths.validRunID(firstSetupArguments[1]) && firstSetupArguments[2] == "check"
              && operations.setupNeedsAttention && operations.setupResult?.items.count == 4
              && operations.setupError == nil && !installed.mutationActive,
              "B8 startup performs one readonly check, reports unready items and never starts Repair or sign-in")
        try privateFile(signed, "")
        try writeMode("setupready")
        operations.refreshService()
        operations.repairSetup()
        check(operations.serviceBusy && !operations.setupRepairing,
              "B8 Repair cannot race an in-flight game-service status read")
        await operations.waitForService()
        await operations.waitForSetup()
        check(operations.serviceStatus?.signedIn == true && operations.setupResult?.needsSignIn == false
              && !operations.setupNeedsAttention,
              "B8 successful Check game sign-in refreshes Setup items and clears a stale setup banner")
        let concurrentSetup = GameOperationsController(installed: installed, paths: paths,
                                                       compatibilityCatalogue: catalogue)
        let setupCallsBefore = try String(contentsOf: root.appendingPathComponent("setup-arguments"), encoding: .utf8)
            .split(separator: "\n").count
        try writeMode("setupslow")
        concurrentSetup.checkSetupOnce()
        concurrentSetup.refreshService()
        await concurrentSetup.waitForService()
        await concurrentSetup.waitForSetup()
        let setupCallsAfter = try String(contentsOf: root.appendingPathComponent("setup-arguments"), encoding: .utf8)
            .split(separator: "\n").count
        check(setupCallsAfter == setupCallsBefore + 6 && concurrentSetup.setupResult?.needsSignIn == false
              && !concurrentSetup.setupBusy && !concurrentSetup.setupNeedsAttention,
              "B8 service success during an existing Setup check queues exactly one fresh readonly follow-up")
        try writeMode("setupslow")
        operations.repairSetup()
        check(operations.setupRepairing && installed.runtimeRepairActive && installed.mutationActive
              && !operations.canQuit && !operations.canStartMutation && !operations.canSignIn,
              "B8 explicit Repair reserves the shared mutation, all-game launch, service restart and Quit fences")
        operations.refreshService()
        check(!operations.serviceBusy, "B8 game-service reads cannot race an environment rebuild")
        operations.repairSetup()
        await operations.waitForSetup()
        check(operations.setupResult?.ready == true && !operations.setupNeedsAttention
              && !installed.runtimeRepairActive && !installed.mutationActive && operations.canQuit,
              "B8 joined Repair reports only its strict readiness result and releases all fences")
        for mode in ["setup22", "setup31", "setupbad", "setupmissing", "setupmismatch"] {
            try writeMode(mode)
            operations.repairSetup()
            await operations.waitForSetup()
            check(operations.setupError != nil && operations.setupLog != nil && operations.setupNeedsAttention
                  && operations.setupResult == nil && !installed.runtimeRepairActive && operations.canQuit,
                  "B8 code22/31 or invalid/missing/conflicting receipt cannot claim Ready and exposes Show log")
            if mode == "setup22" {
                check(operations.setupError == "Quit the running game or finish the download first.",
                      "B8 backend running-game/download refusal preserves its actionable copy")
            }
        }
        check(operations.setupError == GameScriptError.statusMismatch.localizedDescription,
              "B8 conflicting process/status results remain explicit, not readiness defaults")
        try writeMode("setupfailure")
        operations.repairSetup()
        await operations.waitForSetup()
        check(operations.setupResult?.ready == false && operations.setupResult?.items.count == 4
              && operations.setupError == GameScriptError.failed(31).localizedDescription
              && operations.setupNeedsAttention && !installed.runtimeRepairActive && operations.canQuit,
              "Nonzero setup repair keeps validated unready items and actionable failure without reporting success")
        do {
            _ = try GameSetupResult.parse(GameScriptOutcome(code: 31, result: Data(setupData.utf8), log: nil))
            check(false, "Nonzero setup cannot publish a contradictory Ready result")
        } catch {
            check(error as? GameScriptError == .statusMismatch,
                  "Nonzero setup cannot publish a contradictory Ready result")
        }
        let setupValidation = GameScriptRunner(paths: paths)
        try writeMode("setup31")
        let failedSetup = try await setupValidation.run(command: .setup, runID: InstalledGamesController.runID(),
                                                        arguments: ["repair"])
        check(failedSetup.code == 31 && failedSetup.result != nil,
              "Nonzero setup preserves a present bounded result receipt for truthful consumer decoding")
        for arguments in [[], ["install"], ["check", "repair"], ["../repair"]] {
            do {
                _ = try await setupValidation.run(command: .setup, runID: InstalledGamesController.runID(), arguments: arguments)
                check(false, "B8 only check or repair is accepted before any script launch")
            } catch { check(true, "B8 only check or repair is accepted before any script launch") }
        }
        try writeMode("setupready")
        operations.repairSetup()
        await operations.waitForSetup()
        try privateFile(cached, compatibilityData)
        await operations.loadCompatibility(productID: game.id)
        check(operations.compatibility[game.id] == compatible
              && !FileManager.default.fileExists(atPath: root.appendingPathComponent("check-arguments").path),
              "B3: Cached private support result is read without a script, network or game files")
        try FileManager.default.removeItem(at: cached)
        await operations.loadCompatibility(productID: game.id)
        check(operations.compatibility[game.id] == nil && operations.compatibilityErrors[game.id] == nil,
              "B3: A removed cache clears the previous badge instead of inventing current support")
        try privateFile(cached, compatibilityData)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cached.path)
        await operations.loadCompatibility(productID: game.id)
        check(operations.compatibility[game.id] == nil && operations.compatibilityErrors[game.id] != nil,
              "B3: Nonprivate cache is an explicit quiet error, never a compatibility badge")
        try privateFile(cached, compatibilityData)
        for mode in ["checkunsupported", "check11", "checkmissing", "checkwrongid"] {
            try writeMode(mode)
            let priorSupport = operations.compatibility[game.id]
            await operations.prepareInstall(game)
            check(operations.installConsent != nil && !operations.canConfirmInstall
                  && !operations.isBusy && !installed.mutationActive && operations.canQuit,
                  "B3: \(mode) leaves consent visible, Install disabled and no held mutation")
            if mode == "checkunsupported" {
                check(operations.installConsent?.compatibility?.explanation == "Neutral package is not supported."
                      && operations.compatibility[game.id]?.badge == "Installation unavailable",
                      "B3: Unsupported package shows the exact bounded product reason and negative badge")
            } else {
                check(operations.installConsent?.checkError != nil && operations.log != nil,
                      "B3: Failed/mismatched check surfaces failure and generated-run Show log")
                if mode == "check11" {
                    check(operations.installConsent?.checkError?.contains("doesn't establish") == true
                          && operations.compatibility[game.id] == priorSupport
                          && game.acquisitionKind == .unknown,
                          "SDD-LIB-07: actual package refusal preserves collection and prior support facts")
                }
            }
            if let consent = operations.installConsent { operations.confirmInstall(consent) }
            check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path),
                  "B3: Failed/unsupported consent cannot invoke installation")
            await operations.cancelInstallConsent()
            await operations.install(game)
            check(operations.installConsent == nil && !operations.installingDirectly
                  && operations.error != nil && !installed.mutationActive
                  && !FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path),
                  "Direct Install refuses \(mode) before transfer and surfaces a real failure without a check sheet")
            if let error = operations.error {
                NativeUIChecks.checkOperationFeedback(operations: operations, installed: installed,
                    game: game, expectedStatus: error, cancelTitle: nil, check: check)
                let ownerView = GameOperationProgressView(operations: operations, productID: game.id)
                let globalView = GameOperationProgressView(operations: operations)
                let retainedLog = operations.log
                checkUnrelatedDetail(operations, owner: game.id, stage: "failed preparation")
                check(operations.feedbackProductID == game.id && ownerView.operationError == error
                      && globalView.operationError == error && operations.error == error
                      && operations.log == retainedLog && ownerView.showsLog == globalView.showsLog
                      && ownerView.showsGameSignIn == globalView.showsGameSignIn,
                      "XO-022: Returning to A or global status preserves A's genuine failure and matching recovery controls")
                if mode == "check11" {
                    check(!ownerView.showsGameSignIn && ownerView.showsDownloadRecovery && ownerView.showsLog
                          && operations.failureCode == 11,
                          "Download acquisition refusal offers a status-first recovery, not another sign-in")
                    let signInsBeforeRecovery = try String(contentsOf: verificationCalls, encoding: .utf8)
                    operations.recoverDownload(productID: "FIXTURE00002")
                    check(!operations.serviceBusy, "Another product cannot recover this download attempt")
                    let consentOwner = UUID()
                    check(MicrosoftSignInGate.shared.acquire(consentOwner), "Interactive consent gate starts unowned")
                    let duplicateLibrary = PCGamesController()
                    duplicateLibrary.signIn()
                    operations.signInForGames()
                    check(!duplicateLibrary.busy && !duplicateLibrary.sheetPresented
                          && duplicateLibrary.error != nil && !operations.serviceBusy
                          && !MicrosoftSignInGate.shared.acquire(UUID()),
                          "One Microsoft interaction blocks both PC-library and game-service duplicate prompts")
                    MicrosoftSignInGate.shared.release(UUID())
                    check(!MicrosoftSignInGate.shared.available, "An unrelated owner cannot release Microsoft consent")
                    MicrosoftSignInGate.shared.release(consentOwner)
                    try writeMode("checkunsupported")
                    operations.recoverDownload(productID: game.id)
                    operations.recoverDownload(productID: game.id)
                    check(operations.serviceBusy && !operations.canStartMutation && !operations.canQuit,
                          "Download access recovery deduplicates activation and retains mutation/Quit holds")
                    await operations.waitForService()
                    let signInsAfterSavedRecovery = try String(contentsOf: verificationCalls, encoding: .utf8)
                    check(operations.error == "Neutral package is not supported."
                          && operations.failureCode == nil && !operations.downloadNeedsSignIn
                          && signInsAfterSavedRecovery == signInsBeforeRecovery,
                          "A fresh bound saved session retries the exact product check without interactive sign-in or stale authorization error")
                    try writeMode("check11")
                    await operations.install(game)
                    let attemptsBeforeRetry = try String(contentsOf: root.appendingPathComponent("check-calls"), encoding: .utf8)
                    operations.recoverDownload(productID: game.id)
                    await operations.waitForService()
                    let attemptsAfterRetry = try String(contentsOf: root.appendingPathComponent("check-calls"), encoding: .utf8)
                    check(attemptsAfterRetry.split(separator: "\n").count == attemptsBeforeRetry.split(separator: "\n").count + 2
                          && operations.failureCode == 11 && !operations.downloadNeedsSignIn
                          && operations.error == GameScriptError.failed(11).localizedDescription
                          && !operations.serviceBusy && !operations.installingDirectly,
                          "A saved-session acquisition rejection stops after exactly one explicit product retry, without a retry or login loop")
                    try FileManager.default.removeItem(at: signed)
                    operations.recoverDownload(productID: game.id)
                    await operations.waitForService()
                    let signInsAfterStatusRecovery = try String(contentsOf: verificationCalls, encoding: .utf8)
                    check(operations.downloadNeedsSignIn
                          && GameOperationProgressView(operations: operations, productID: game.id).showsGameSignIn
                          && signInsAfterStatusRecovery == signInsBeforeRecovery,
                          "Unconfirmed service status offers explicit authorization review without claiming sign-out or starting consent")
                    try privateFile(verificationFails, "Refused synthetic consent.")
                    operations.recoverDownload(productID: game.id)
                    operations.recoverDownload(productID: game.id)
                    await operations.waitForService()
                    check(!operations.downloadNeedsSignIn && operations.error?.contains("has not resumed") == true
                          && operations.failureCode == 11 && !operations.serviceBusy
                          && MicrosoftSignInGate.shared.available,
                          "Failed authorization never resumes installation and releases only its joined consent hold")
                    try FileManager.default.removeItem(at: verificationFails)
                    operations.recoverDownload(productID: game.id)
                    await operations.waitForService()
                    try writeMode("checkunsupported")
                    operations.recoverDownload(productID: game.id)
                    await operations.waitForService()
                    check(operations.serviceStatus?.accountHash == fixtureAccountHash
                          && operations.error == "Neutral package is not supported."
                          && operations.failureCode == nil && !operations.downloadNeedsSignIn
                          && !FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path),
                          "Confirmed explicit authorization resumes the initiating package check, never bypassing its unsupported verdict")
                    try writeMode("check11")
                    await operations.install(game)
                    try privateFile(statusFails, "Malformed status, not a signed-out receipt.")
                    let callsBeforeBadStatus = try String(contentsOf: verificationCalls, encoding: .utf8)
                    operations.recoverDownload(productID: game.id)
                    await operations.waitForService()
                    let callsAfterBadStatus = try String(contentsOf: verificationCalls, encoding: .utf8)
                    check(operations.serviceStatus == nil && !operations.downloadNeedsSignIn
                          && operations.error?.contains("No new sign-in was started") == true
                          && callsAfterBadStatus == callsBeforeBadStatus,
                          "Malformed or unavailable status never becomes signed-out evidence or automatic consent")
                    try FileManager.default.removeItem(at: statusFails)
                    try FileManager.default.removeItem(at: verifiedAccount)
                    operations.recoverDownload(productID: game.id)
                    await operations.waitForService()
                    let callsAfterUnbound = try String(contentsOf: verificationCalls, encoding: .utf8)
                    check(operations.serviceStatus == nil
                          && operations.error?.contains("No new sign-in was started") == true
                          && callsAfterUnbound == callsBeforeBadStatus && operations.failureCode == 11,
                          "An unbound service result cannot resume an initiating install")
                    try FileManager.default.removeItem(at: signed)
                    operations.recoverDownload(productID: game.id)
                    await operations.waitForService()
                    check(operations.downloadNeedsSignIn && operations.canRecoverDownload,
                          "Confirmed unavailable credentials request one bounded continuation")
                    try privateFile(verificationCancels, "Synthetic Microsoft-window cancellation.")
                    operations.recoverDownload(productID: game.id)
                    await operations.waitForService()
                    check(operations.serviceError?.contains("cancelled") == true
                          && operations.error?.contains("has not resumed") == true
                          && !operations.downloadNeedsSignIn && !operations.serviceBusy
                          && MicrosoftSignInGate.shared.available,
                          "Cancelled consent never resumes or leaves a held prompt or stale Continue demand")
                    try FileManager.default.removeItem(at: verificationCancels)
                    try privateFile(signed, "Restored synthetic saved sign-in.")
                    try privateFile(verifiedAccount, "Restored synthetic binding.")
                    operations.refreshService()
                    await operations.waitForService()
                    await operations.waitForSetup()
                    check(!operations.downloadNeedsSignIn && operations.error?.contains("was confirmed") == true
                          && operations.failureCode == 11 && operations.canRecoverDownload,
                          "A separate confirmed status recovery replaces stale sign-in copy without claiming a successful download")
                    try writeMode("checkslow")
                    let next = PCGame(id: "FIXTURE00002", title: "Second Fixture", artwork: nil)
                    let nextCheck = Task { await operations.prepareInstall(next) }
                    try await wait { operations.checkingCompatibility }
                    check(operations.feedbackProductID == next.id && operations.error == nil
                          && operations.failureCode == nil && operations.log == nil && operations.notice == nil,
                          "XO-022: A new accepted B action resets A's feedback together rather than relabeling its account failure/log")
                    await operations.cancelInstallConsent()
                    await nextCheck.value
                }
            }
        }
        let aliasedGames = root.appendingPathComponent("aliased-games")
        try FileManager.default.createSymbolicLink(at: aliasedGames, withDestinationURL: paths.games)
        let unavailableStorage = GameScriptPaths(scripts: paths.scripts, processed: paths.processed,
            logs: paths.logs, games: aliasedGames, journal: paths.journal)
        let storageFailure = GameOperationsController(installed: installed, paths: unavailableStorage,
                                                      compatibilityCatalogue: catalogue)
        await storageFailure.install(game)
        check(storageFailure.error == GameScriptError.invalidDestination.localizedDescription
              && storageFailure.hasDownloadStatus && storageFailure.canQuit && !installed.mutationActive,
              "F1: Unsafe storage fails before scripts and remains visible on the initiating route")
        NativeUIChecks.checkOperationFeedback(operations: storageFailure, installed: installed,
            game: game, expectedStatus: GameScriptError.invalidDestination.localizedDescription,
            cancelTitle: nil, check: check)
        checkUnrelatedDetail(storageFailure, owner: game.id, stage: "known-title storage failure")
        try writeMode("checkslow")
        let checking = Task { await operations.prepareInstall(game) }
        try await wait { operations.checkingCompatibility }
        check(operations.isBusy && !operations.hasDownloadStatus,
              "Downloads keeps its empty action during a compatibility check")
        check(!operations.canQuit && installed.mutationActive && !operations.canStartMutation
              && !operations.canSignIn && !operations.canConfirmInstall,
              "B3: One active check shares the mutation/service/Quit fence and cannot enable Install early")
        let checkingConsent = operations.installConsent?.id
        await operations.prepareInstall(game)
        check(operations.installConsent?.id == checkingConsent, "B3: A second check cannot replace active consent")
        await operations.cancelInstallConsent()
        await checking.value
        check(!operations.checkingCompatibility && !installed.mutationActive && operations.canQuit
              && operations.installConsent == nil && installed.games.isEmpty,
              "B3: Consent cancellation joins its check and releases the fence without registration or game files")
        try writeMode("0")
        let installAction = GameInstallAction(game: game, operations: operations)
        await installAction.requestInstall()
        check(operations.presentedInstallConsent?.game.id == game.id
              && operations.canConfirmInstall && !operations.installingDirectly
              && operations.operation == nil && !installed.mutationActive
              && !FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path)
              && !FileManager.default.fileExists(atPath: paths.journal.path),
              "COR89 actual Install button presents a fresh visible review without automatically starting installation")
        await operations.cancelInstallConsent()
        check(operations.presentedInstallConsent == nil && operations.operation == nil
              && installed.games.isEmpty && !installed.mutationActive
              && !FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path)
              && !FileManager.default.fileExists(atPath: paths.journal.path),
              "COR89 cancelling actual Install review performs no installation, registration or journal write")
        let blockedInstallAction = GameInstallAction(game: game, operations: operations, enabled: false)
        await blockedInstallAction.requestInstall()
        check(operations.installConsent == nil && operations.operation == nil,
              "COR89 actual Install action retains its access gate before presenting review")
        let pendingReview = GameDetailInstallRequest(game: game, accountHash: String(repeating: "a", count: 64))
        check(pendingReview.resolve(accountHash: String(repeating: "a", count: 64))?.id == game.id
              && pendingReview.resolve(accountHash: String(repeating: "b", count: 64)) == nil
              && pendingReview.resolve(accountHash: nil) == nil,
              "COR89 pending detail review retains its exact account and rejects account-switch/sign-out handoff")
        let locationSuite = "Xodus.install-location-checks.\(UUID().uuidString)"
        guard let locationDefaults = UserDefaults(suiteName: locationSuite) else { throw GameScriptError.storage }
        defer { locationDefaults.removePersistentDomain(forName: locationSuite) }
        let firstRoot = root.appendingPathComponent("first drive")
        let secondRoot = root.appendingPathComponent("second drive")
        for directory in [firstRoot, secondRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let firstLocation = try await Task.detached { try GameInstallLocation(folder: firstRoot) }.value
        locationDefaults.set(try JSONEncoder().encode(firstLocation), forKey: GameInstallLocation.preferenceKey)
        let locationOperations = GameOperationsController(installed: installed, paths: paths,
            compatibilityCatalogue: catalogue, installLocationDefaults: locationDefaults)
        await locationOperations.prepareInstall(game)
        guard let defaultConsent = locationOperations.installConsent else { throw GameScriptError.invalidDestination }
        check(defaultConsent.destination.deletingLastPathComponent().path == firstRoot.path
              && locationOperations.presentedInstallConsent != nil && locationOperations.operation == nil,
              "REQ92: Persisted default prefills the actual review without installation")
        let typedRoot = root.appendingPathComponent("Typed drive É")
        try FileManager.default.createDirectory(at: typedRoot, withIntermediateDirectories: false)
        await locationOperations.updateTypedInstallLocation(defaultConsent, path: typedRoot.path)
        check(locationOperations.installConsent?.destination.deletingLastPathComponent().path == typedRoot.path
              && locationOperations.installLocationError == nil,
              "REQ110: Typed install root preserves spaces/Unicode and resolves the separate game destination")
        await locationOperations.updateTypedInstallLocation(defaultConsent, path: "relative/folder")
        if let retained = locationOperations.installConsent { locationOperations.confirmInstall(retained) }
        check(locationOperations.installLocationError != nil && locationOperations.operation == nil
              && locationOperations.installConsent?.destination.deletingLastPathComponent().path == typedRoot.path,
              "REQ110: Invalid typed root cannot silently confirm into the previous destination")
        await locationOperations.updateTypedInstallLocation(defaultConsent, path: root.appendingPathComponent("missing drive").path)
        check(locationOperations.installLocationError != nil
              && locationOperations.installConsent?.destination.deletingLastPathComponent().path == typedRoot.path,
              "REQ110: An unavailable typed drive reports failure and retains the choice without a fallback")
        let readOnlyRoot = root.appendingPathComponent("read-only drive")
        try FileManager.default.createDirectory(at: readOnlyRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyRoot.path)
        await locationOperations.updateTypedInstallLocation(defaultConsent, path: readOnlyRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyRoot.path)
        check(locationOperations.installLocationError == GameInstallLocationError.notWritable.localizedDescription,
              "REQ110: A read-only install folder reports its actual writable-folder recovery")
        await locationOperations.updateInstallLocation(defaultConsent, root: secondRoot)
        let retainedDefault = try GameInstallLocation.load(locationDefaults)
        check(locationOperations.installConsent?.destination.deletingLastPathComponent().path == secondRoot.path
              && locationOperations.installConsent?.id == defaultConsent.id
              && retainedDefault == firstLocation
              && locationOperations.operation == nil && installed.games.isEmpty,
              "REQ92: Per-install override updates the reviewed destination, not the default or existing paths")
        let occupiedDestination = try paths.destination(title: game.title, productID: game.id, root: typedRoot)
        try FileManager.default.createDirectory(at: occupiedDestination, withIntermediateDirectories: false)
        await locationOperations.updateTypedInstallLocation(defaultConsent, path: typedRoot.path)
        check(locationOperations.installLocationError == GameInstallLocationError.destinationExists.localizedDescription
              && locationOperations.installConsent?.destination.deletingLastPathComponent().path == secondRoot.path,
              "H1: Selecting an unscanned root refuses an existing empty or unrecognized game destination")
        try FileManager.default.removeItem(at: occupiedDestination)
        let racedDestination = try paths.destination(title: game.title, productID: game.id, root: secondRoot)
        try FileManager.default.createDirectory(at: racedDestination, withIntermediateDirectories: false)
        await locationOperations.confirmInstallLocation(defaultConsent, path: secondRoot.path)
        check(locationOperations.operation == nil
              && locationOperations.installLocationError == GameInstallLocationError.destinationExists.localizedDescription,
              "H1: Final confirmation rechecks exact destination existence after an initially valid root selection")
        try FileManager.default.removeItem(at: racedDestination)
        await locationOperations.updateInstallLocation(defaultConsent, root: secondRoot)
        locationOperations.confirmInstall(defaultConsent)
        check(locationOperations.operation == nil && locationOperations.installConsent != nil,
              "REQ92: A retained pre-override consent cannot install into the old destination")
        await locationOperations.cancelInstallConsent()
        let cancelledDefault = try GameInstallLocation.load(locationDefaults)
        check(locationOperations.operation == nil && locationOperations.installConsent == nil
              && cancelledDefault == firstLocation && installed.games.isEmpty,
              "REQ110: Cancelling destination review changes no default, installed entry or operation")
        let destinationStore = InstalledGameStore(file: root.appendingPathComponent("typed-install-registry/games.json"))
        let destinationLibrary = InstalledGamesController(store: destinationStore, inspectPackage: { _ in .win32 })
        await destinationLibrary.load()
        let destinationPaths = GameScriptPaths(scripts: paths.scripts, processed: paths.processed, logs: paths.logs,
            games: paths.games, journal: root.appendingPathComponent("typed-install-operation.json"))
        let destinationOperations = GameOperationsController(installed: destinationLibrary, paths: destinationPaths,
            compatibilityCatalogue: catalogue)
        await destinationOperations.prepareInstall(game)
        guard let destinationConsent = destinationOperations.installConsent else { throw GameScriptError.invalidDestination }
        await destinationOperations.confirmInstallLocation(destinationConsent, path: typedRoot.path)
        let confirmedDestination = try destinationPaths.destination(title: game.title, productID: game.id, root: typedRoot)
        check(destinationOperations.operation?.destination == confirmedDestination.path,
              "REQ110: Confirmed typed root reaches the actual operation rather than changing only its display")
        await destinationOperations.waitForMutation()
        let destinationArguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
            .components(separatedBy: "\n")
        check(destinationArguments[3] == confirmedDestination.path
              && destinationLibrary.games.first?.folder == confirmedDestination.path
              && destinationLibrary.games.first.map { destinationLibrary.launchableIDs.contains($0.id) } == true,
              "REQ110: Disposable install propagates the confirmed path through child arguments, registration and independent readiness")
        try FileManager.default.removeItem(at: root.appendingPathComponent("arguments"))
        let partialRoot = root.appendingPathComponent("partial resume drive")
        try FileManager.default.createDirectory(at: partialRoot, withIntermediateDirectories: false)
        let partialStore = InstalledGameStore(file: root.appendingPathComponent("partial-registry/games.json"))
        let partialLibrary = InstalledGamesController(store: partialStore, inspectPackage: { _ in .win32 })
        await partialLibrary.load()
        let partialPaths = GameScriptPaths(scripts: paths.scripts, processed: paths.processed, logs: paths.logs,
            games: paths.games, journal: root.appendingPathComponent("partial-operation.json"))
        let partialOperations = GameOperationsController(installed: partialLibrary, paths: partialPaths,
            compatibilityCatalogue: catalogue)
        try writeMode("partialslow")
        await partialOperations.prepareInstall(game)
        guard let partialConsent = partialOperations.installConsent else { throw GameScriptError.invalidDestination }
        await partialOperations.confirmInstallLocation(partialConsent, path: partialRoot.path)
        let partialDestination = try paths.destination(title: game.title, productID: game.id, root: partialRoot)
        try await wait { FileManager.default.fileExists(atPath: partialDestination.appendingPathComponent("MicrosoftGame.config").path) }
        await partialOperations.cancelInstall()
        await partialOperations.waitForMutation()
        let resumedOperations = GameOperationsController(installed: partialLibrary, paths: partialPaths,
            compatibilityCatalogue: catalogue)
        await resumedOperations.restore()
        check(!resumedOperations.recoveryRequired && resumedOperations.canStartMutation
              && resumedOperations.resumableInstallations[game.id]?.destination == partialDestination.path
              && partialLibrary.games.isEmpty,
              "M2: Cancelling a config-bearing partial install preserves a durable exact-product/destination resume without registering or globally locking")
        try writeMode("success")
        await resumedOperations.prepareInstall(game)
        guard let resumedConsent = resumedOperations.installConsent else { throw GameScriptError.invalidDestination }
        check(resumedConsent.resuming && resumedConsent.destination.path == partialDestination.path,
              "M2: Reloaded Resume returns to the original managed partial folder instead of the current default")
        await resumedOperations.confirmInstallLocation(resumedConsent, path: firstRoot.path)
        await resumedOperations.waitForMutation()
        check(partialLibrary.games.first?.folder == partialDestination.path
              && resumedOperations.resumableInstallations[game.id] == nil,
              "M2: Resume installs only to its retained destination and retires the resume record after verified registration")
        try FileManager.default.removeItem(at: root.appendingPathComponent("arguments"))
        let secondLocation = try await Task.detached { try GameInstallLocation(folder: secondRoot) }.value
        locationDefaults.set(try JSONEncoder().encode(secondLocation), forKey: GameInstallLocation.preferenceKey)
        let reloadedDefaults = UserDefaults(suiteName: locationSuite)!
        let reloadedLocations = GameOperationsController(installed: installed, paths: paths,
            compatibilityCatalogue: catalogue, installLocationDefaults: reloadedDefaults)
        check(try await reloadedLocations.installDestination(for: game).deletingLastPathComponent().path == secondRoot.path,
              "REQ92: A new preference/controller instance retains the selected default")
        locationDefaults.set(Data("invalid".utf8), forKey: GameInstallLocation.preferenceKey)
        do {
            _ = try await locationOperations.installDestination(for: game)
            check(false, "REQ92: Invalid saved location never silently falls back to another drive")
        } catch { check(true, "REQ92: Invalid saved location never silently falls back to another drive") }
        let unavailableLocation = Data("""
            {"folder":"/Volumes/REQ92-Synthetic-Unmounted/Games","volume":{"path":"/Volumes/REQ92-Synthetic-Unmounted"}}
            """.utf8)
        locationDefaults.set(unavailableLocation, forKey: GameInstallLocation.preferenceKey)
        do {
            _ = try await locationOperations.installDestination(for: game)
            check(false, "REQ92: Unmounted selected drive is rejected without creating a substitute directory")
        } catch {
            check(error as? GameInstallLocationError == .driveUnavailable,
                  "REQ92: Unmounted selected drive is rejected without creating a substitute directory")
        }
        try await InstalledGameChecks.storageLocationChecks(check: check)
        if ProcessInfo.processInfo.environment["XODUS_NATIVE_CONSENT_PRESENTATION_CHECK"] == "1" {
            try await NativeUIChecks.checkInstallSheetPresentation(operations: operations, game: game, check: check)
            check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path)
                  && !FileManager.default.fileExists(atPath: paths.journal.path) && installed.games.isEmpty,
                  "COR89 native presenter: dismiss/review/cancel runs no installer, journal or registry mutation")
        }
        try writeMode("checkslow")
        let directCheck = Task { await operations.install(game) }
        try await wait { operations.checkingCompatibility }
        check(operations.installingDirectly && operations.presentedInstallConsent == nil
              && operations.hasDownloadStatus && !operations.canQuit,
              "Direct Install has cancellable preparation without presenting an internal-check sheet")
        checkUnrelatedDetail(operations, owner: game.id, stage: "direct preparation")
        check(GameOperationProgressView(operations: operations, productID: game.id).showsPreparation
              && GameOperationProgressView(operations: operations, productID: game.id).preparationCancelTitle == "Cancel",
              "XO-022: Matching detail retains direct preparation and cancellation ownership before an operation exists")
        NativeUIChecks.checkOperationFeedback(operations: operations, installed: installed,
            game: game, expectedStatus: "Preparing installation", cancelTitle: "Cancel", check: check)
        await operations.install(game)
        let cancellingPreparation = Task { await operations.cancelInstallConsent() }
        try await wait { operations.directInstallCancelled }
        if operations.installingDirectly {
            check(!operations.canQuit && !operations.canStartMutation,
                  "F2: Cancellation request cannot release preparation holds before its owned check settles")
        }
        await cancellingPreparation.value
        await directCheck.value
        check(!operations.installingDirectly && !installed.mutationActive && operations.installConsent == nil
              && !FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path),
              "Cancelling direct preparation joins the check and prevents a duplicate or subsequent download")
        func install(_ candidate: PCGame = game) async throws {
            await operations.prepareInstall(candidate)
            guard let consent = operations.installConsent else { throw GameScriptError.invalidDestination }
            operations.confirmInstall(consent)
            await operations.waitForMutation()
        }
        try writeMode("slow")
        await operations.prepareInstall(game)
        if let error = operations.error { print("NEUTRAL consent failure: \(error)") }
        guard let first = operations.installConsent else { throw GameScriptError.invalidDestination }
        check(first.destination.lastPathComponent == "FixtureGame-Xbox" && first.freeBytes >= 0
              && first.compatibility?.packageBytes == 3_200_000_000 && first.compatibility?.supported == true
              && operations.operation == nil, "B3/S5 consent has real free space, checked support/size and no installation")
        let checkArgs = try String(contentsOf: root.appendingPathComponent("check-arguments"), encoding: .utf8)
            .components(separatedBy: "\n")
        check(checkArgs[0] == "2" && GameScriptPaths.validRunID(checkArgs[1]) && checkArgs[2] == game.id,
              "B3 check receives only the generated run ID and exact Store product ID")
        operations.installConsent = nil
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path),
              "S5 cancelling consent does not start installation")
        await operations.prepareInstall(game)
        guard let consent = operations.installConsent else { throw GameScriptError.invalidDestination }
        operations.confirmInstall(consent)
        try await wait { operations.progress?.bytesDone == 20 }
        check(operations.isBusy && !operations.canQuit && installed.mutationActive
              && !operations.canStartMutation && !operations.canSignIn,
              "S5 one mutation reserves registration, service restart and normal Quit")
        checkUnrelatedDetail(operations, owner: game.id, stage: "active download")
        check(GameOperationProgressView(operations: operations, productID: game.id).presentedOperation?.productID == game.id
              && GameOperationProgressView(operations: operations, productID: game.id).installCancelTitle != nil,
              "XO-022: Matching active detail retains real progress and acknowledged cancellation")
        NativeUIChecks.checkOperationFeedback(operations: operations, installed: installed,
            game: game, expectedStatus: operations.progress?.phase.title ?? "Preparing download",
            cancelTitle: "Cancel installation", check: check)
        let activeID = operations.operation?.id
        await operations.prepareInstall(game)
        operations.signInForGames()
        check(operations.installConsent == nil && operations.operation?.id == activeID && !operations.serviceSigningIn,
              "S3/S5 commands cannot bypass the one-mutation guard while an install is active")
        let termination = ApplicationTerminationCoordinator()
        let session = LiveSession()
        check(!(await termination.shutdown(session: session, runtime: nil,
                                            installedGames: installed, gameOperations: operations)),
              "S5 normal Quit is refused before disconnecting or abandoning an operation")
        check(!installed.applicationTerminating, "S5 refused Quit leaves existing Play/controller state intact")
        let args = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8).components(separatedBy: "\n")
        check(args[0] == "3" && GameScriptPaths.validRunID(args[1]) && args[2] == game.id
              && args[3] == consent.destination.path && args[4] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
              && args[5] == "unset", "S5 script receives exact argv and minimal environment without inherited secrets")
        let cancellingInstall = Task { await operations.cancelInstall() }
        try await wait { operations.cancelling || operations.operation == nil }
        if operations.operation != nil {
            check(!operations.canQuit && installed.mutationActive && !operations.canStartMutation,
                  "F2: Acknowledging Cancel keeps mutation and Quit holds until the actual stopped receipt")
        }
        await cancellingInstall.value
        await operations.waitForMutation()
        check(!operations.isBusy && !installed.mutationActive && operations.error == nil && operations.notice != nil
              && operations.log != nil && installed.games.isEmpty,
              "S5 SIGTERM joins the script, consumes code 14 and keeps partial files unregistered")
        // M7: a queue-originated pause/cancel also stops the engine with code 14, but unlike an
        // interactive cancel it must NOT leave the shared failure banner populated — the per-job
        // queue UI is authoritative, so the Downloads screen must not show a spurious failure for
        // a job the user merely paused or cancelled.
        try writeMode("slow")
        let queuedDestination = try paths.destination(title: game.title, productID: game.id).path
        let queuedRecord = GameOperationRecord(id: InstalledGamesController.runID(), kind: .install,
            productID: game.id, title: game.title, destination: queuedDestination, installedID: nil)
        let queuedRun = Task { await operations.runQueuedOperation(queuedRecord, onProgress: { _ in }) }
        try await wait { operations.operation?.id == queuedRecord.id && operations.progress?.bytesDone == 20 }
        check(operations.operation?.id == queuedRecord.id && installed.mutationActive
              && operations.error == nil,
              "M7 a queued install reserves the single mutation slot through the shared controller")
        await operations.cancelQueuedRun(runID: queuedRecord.id)
        let queuedOutcome = await queuedRun.value
        check(queuedOutcome == .cancel && operations.error == nil && operations.failureCode == nil
              && !installed.mutationActive && installed.games.isEmpty,
              "M7 a queue-originated code-14 stop clears the shared failure banner and registers nothing")
        try writeMode("success")
        await operations.install(game)
        check(operations.operation != nil && operations.installConsent == nil && !operations.installingDirectly,
              "One Install action starts the checked download without a second user confirmation")
        await operations.waitForMutation()
        guard let imported = installed.games.first else { throw GameScriptError.invalidReceipt }
        check(imported.storeId == game.id && imported.title == "Fixture Game"
              && imported.folder == consent.destination.path && imported.launcher == launcher.path
              && operations.error == nil && installed.launchableIDs.contains(imported.id),
              "S5 status zero ignores extra result fields and registers only from config validation and durable save")
        checkUnrelatedDetail(operations, owner: game.id, stage: "completed download")
        check(operations.feedbackProductID == game.id
              && GameOperationProgressView(operations: operations, productID: game.id).operationNotice == operations.notice
              && GameOperationProgressView(operations: operations).operationNotice == operations.notice
              && operations.notice != nil,
              "XO-022: Terminal installation notice retains its owner after the active operation is cleared")
        let reloaded = try await store.load()
        check(reloaded == installed.games, "S5 validated installation survives a registry reload")
        check(installed.runningGameID == nil && !installed.launchStarted,
              "Library Install completes registration without automatically calling Play")
        let completedRow = LibraryGame.collection(installed: installed.games, owned: [game],
            products: [], gamePass: [], active: false)[0]
        let completedFacts = completedRow.facts
        check(completedFacts.badgeLabels() == ["In your library"]
              && completedFacts.installation == .installed(imported.folder)
              && !completedRow.owned && installed.runningGameID == nil && !installed.launchStarted
              && !GameInstallAction(game: game, operations: operations).active
              && operations.operation == nil && operations.canRepair(imported),
              "REQ-50: Completed installation updates shared installation facts and repair eligibility without auto-launch or Owned promotion")
        let removalStore = InstalledGameStore(file: root.appendingPathComponent("remove-only/installed-games.json"))
        try await removalStore.save([imported])
        let removalLibrary = InstalledGamesController(store: removalStore)
        await removalLibrary.load()
        let removalOperations = GameOperationsController(installed: removalLibrary, paths: paths,
                                                          compatibilityCatalogue: catalogue)
        removalOperations.prepareUninstall(imported)
        check(removalOperations.uninstallConsent == imported && !removalOperations.isBusy,
              "REQ-50: Uninstall requires its own explicit consent, not a list-removal side effect")
        removalOperations.uninstallConsent = nil
        await removalLibrary.remove(imported)
        let removedDisplay = LibraryGame.displayCollection(installed: removalLibrary.games,
            account: LibraryGame.collection(installed: [], owned: [game], products: [],
                gamePass: [], active: false))
        check(removalLibrary.games.isEmpty && removedDisplay.first?.installed == nil
              && removedDisplay.first?.facts.badgeLabels() == ["In your library"]
              && FileManager.default.fileExists(atPath: imported.folder)
              && removalOperations.operation == nil && removalOperations.uninstallConsent == nil
              && !FileManager.default.fileExists(atPath: root.appendingPathComponent("uninstall-calls").path),
              "REQ-50: List removal withdraws installed presentation, preserves held access and files, and never starts uninstall")
        installed.setAccountAccessAllowed(true)
        let play = InstalledPlayButton(library: installed, operations: operations, game: imported)
        check(play.title == "Play" && play.unsupportedIssues.isEmpty && operations.canRepair(imported),
              "UI-9 source: Shared Library/Discover installed controls offer Play and Repair for cleared MSIXVC")
        check(completedFacts.installation == .installed(imported.folder)
              && play.title == "Play" && installed.canRequestPlay(game.id)
              && installed.runningGameID == nil && !installed.launchStarted,
              "REQ-50: Install-complete exposes an eligible explicit Play action without activating it")
        for technology in ["BattlEye"] {
            let blockedCatalogue = OfflineGameCompatibility(version: 1, checkedAt: catalogue.checkedAt,
                market: catalogue.market, packageSource: catalogue.packageSource,
                antiCheatReference: catalogue.antiCheatReference,
                products: [game.id: .init(title: game.title, packageFormat: "MSIXVC", pcPackageIdentified: true,
                    antiCheat: technology, technologyReferences: [], referencePlatforms: [])])
            let blocked = GameOperationsController(installed: installed, paths: paths,
                                                    compatibilityCatalogue: blockedCatalogue)
            let panel = InstalledGameAttentionView(installed: installed, operations: blocked,
                game: imported, repairGame: game, close: {})
            check(!panel.offersRepair && !blocked.canRepair(imported)
                  && !InstalledPlayButton(library: installed, operations: blocked, game: imported).unsupportedIssues.isEmpty,
                  "UI-5: \(technology) cannot expose attention-panel Repair or an installed Play button")
            await blocked.repair(game, installed: imported)
            check(blocked.operation == nil && blocked.error?.contains(technology) == true,
                  "UI-5: Direct installed repair cannot bypass attention-panel admission")
        }
        for provider in [RuntimeProviderKind.crossover, .gptk3, .gptk4, .standaloneWine] {
            await installed.setEngineOverride(provider, for: imported)
            guard let historical = installed.games.first(where: { $0.id == imported.id }) else {
                throw GameScriptError.invalidReceipt
            }
            await installed.play(historical)
            check(installed.runningGameID == nil
                  && installed.playErrors[imported.id] == InstalledGameActionCopy.launchUnavailable,
                  "REQ95 current per-game \(provider.rawValue) choice refuses before spawning a legacy launcher")
        }
        await installed.setEngineOverride(nil, for: imported)
        guard let policyGame = installed.games.first(where: { $0.id == imported.id }) else {
            throw GameScriptError.invalidReceipt
        }
        await installed.play(policyGame)
        check(installed.runningGameID == nil
              && installed.playErrors[imported.id] == InstalledGameActionCopy.launchUnavailable,
              "REQ95 current Play refuses historical CrossOver execution before spawning its legacy script")
        await installed.playHistoricalFixture(policyGame)
        check(installed.runningGameID == imported.id && !operations.canSignIn,
              "S3 game-service restart is disabled while a game is running")
        check(!operations.canRepairSetup, "B8 environment recreation is disabled for every tracked running game")
        operations.repairSetup()
        check(!operations.setupRepairing, "B8 cannot reset the environment underneath a running title")
        await operations.prepareInstall(game, repairing: imported)
        operations.prepareUninstall(imported)
        check(operations.installConsent == nil && operations.uninstallConsent == nil,
              "S6 repair and uninstall cannot target a running game")
        try await wait { installed.runningGameID == nil }
        await installed.waitForSessionPersistence()
        guard let played = installed.games.first else { throw GameScriptError.invalidReceipt }
        let history = played.lastPlayedAt
        await reloadedLocations.prepareInstall(game, repairing: played)
        guard let locationRepair = reloadedLocations.installConsent else { throw GameScriptError.invalidDestination }
        await reloadedLocations.updateInstallLocation(locationRepair, root: secondRoot)
        check(reloadedLocations.installConsent?.destination.path == played.folder
              && reloadedLocations.installConsent?.installedID == played.id
              && installed.games.first?.folder == played.folder
              && installed.games.first?.lastPlayedAt == history,
              "REQ92: Changed or unavailable default never redirects repair, and repair rejects folder overrides")
        await reloadedLocations.cancelInstallConsent()
        await operations.prepareInstall(game, repairing: played)
        guard let repair = operations.installConsent else { throw GameScriptError.invalidDestination }
        check(repair.destination.path == played.folder && repair.installedID == played.id,
              "S6 repair consents to the exact existing folder and entry")
        operations.confirmInstall(repair)
        await operations.waitForMutation()
        check(installed.games.first?.id == played.id && installed.games.first?.lastPlayedAt == history
              && installed.games.first?.lastSessionSeconds == played.lastSessionSeconds,
              "S6 repair preserves registration identity and own-session history")
        let registryBeforeSetup = try Data(contentsOf: root.appendingPathComponent("registry/installed-games.json"))
        try writeMode("setupslow")
        operations.repairSetup()
        guard let launchDuringRepair = installed.games.first else { throw GameScriptError.invalidReceipt }
        await installed.playHistoricalFixture(launchDuringRepair)
        check(installed.runningGameID == nil && installed.runtimeRepairActive,
              "B8 no game can start while the shared environment is being rebuilt")
        await operations.waitForSetup()
        check(try Data(contentsOf: root.appendingPathComponent("registry/installed-games.json")) == registryBeforeSetup
              && installed.launchableIDs.contains(played.id) && installed.games.first?.lastPlayedAt == history,
              "B8 repair revalidates unchanged launcher paths without rewriting registration or history")
        try privateFile(launcher, """
            #!/bin/bash
            trap 'exit 9' TERM
            printf '%s\\n' "$$" > '\(root.path)/launcher-pid'
            printf 'Neutral launcher exit\\n' > '\(paths.logs.path)'/"$1.stderr.log"
            for i in $(seq 1 40); do sleep 0.05; done
            exit 9

            """, mode: 0o700)
        for mode in ["stopbefore", "stopafter", "stop21", "stopwrongid", "stopfalse", "stopmissing", "stopmismatch"] {
            try writeMode(mode)
            guard let candidate = installed.games.first else { throw GameScriptError.invalidReceipt }
            await installed.playHistoricalFixture(candidate)
            try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("launcher-pid").path) }
            check(installed.canStop(candidate) && operations.canQuit,
                  "B9 only a live Xodus-launched session can Stop; ordinary gameplay Quit is unchanged")
            operations.stop(candidate)
            check(installed.stoppingGameID == candidate.id && installed.mutationActive
                  && !installed.canStop(candidate) && !operations.canQuit,
                  "B9 Stop is disabled in flight, reserves one mutation and joins before Quit")
            operations.stop(candidate)
            await operations.waitForMutation()
            if mode == "stop21" {
                check(installed.playErrors[candidate.id] == GameScriptError.failed(21).localizedDescription
                      && installed.playLogs[candidate.id] != nil && installed.runningGameID == candidate.id,
                      "B9 no-environment receipt is a visible failure, not a fabricated stopped session")
                try writeMode("stopbefore")
                operations.stop(candidate)
                await operations.waitForMutation()
            }
            try await wait { installed.runningGameID == nil }
            await installed.waitForSessionPersistence()
            if ["stopbefore", "stopafter", "stop21"].contains(mode) {
                check(installed.playErrors[candidate.id] == nil && installed.playLogs[candidate.id] == nil
                      && installed.playNotices[candidate.id] == "Stopped",
                      "B9 confirmed Stop suppresses any launcher exit code, before or after its receipt")
            } else {
                check(installed.playErrors[candidate.id] != nil && installed.playNotices[candidate.id] == nil,
                      "B9 mismatched/false/missing stop evidence never becomes success")
            }
            check(installed.games.first?.lastSessionSeconds.map { $0 >= 0 } == true
                  && installed.stoppingGameID == nil && !installed.mutationActive && operations.canQuit,
                  "B9 ended sessions retain ordinary measured history and release every stop fence")
            try FileManager.default.removeItem(at: root.appendingPathComponent("launcher-pid"))
        }
        let stopArguments = try String(contentsOf: root.appendingPathComponent("stop-arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        check(stopArguments.count == 3 && stopArguments[0] == "2"
              && GameScriptPaths.validRunID(stopArguments[1]) && stopArguments[2] == game.id,
              "B9 script receives exactly generated runID and the launched Store ID")
        try writeMode("preservefail")
        guard let repaired = installed.games.first else { throw GameScriptError.invalidReceipt }
        operations.prepareUninstall(repaired)
        operations.confirmUninstall(repaired)
        await operations.waitForMutation()
        check(installed.games.count == 1 && operations.error?.contains("couldn't be preserved") == true,
              "S6 code 20 explicitly preserves the installed entry after save-preservation refusal")
        try writeMode("success")
        operations.prepareUninstall(repaired)
        operations.confirmUninstall(repaired)
        await operations.waitForMutation()
        check(installed.games.isEmpty && !operations.isBusy
              && FileManager.default.fileExists(atPath: repaired.folder),
              "S6 only status zero removes registration; app itself never deletes game files")
        let uninstallCalls = try String(contentsOf: root.appendingPathComponent("uninstall-calls"), encoding: .utf8)
        let afterUninstall = LibraryGame.collection(installed: installed.games, owned: [game],
            products: [], gamePass: [], active: false)[0]
        check(uninstallCalls.split(separator: "\n").count == 2
              && afterUninstall.facts.installation == .notInstalled
              && afterUninstall.facts.badgeLabels() == ["In your library"]
              && GameInstallAction(game: game, operations: operations).canInstall,
              "REQ-50: Only explicit uninstall invokes its transport; success withdraws installed facts but preserves held reinstall eligibility")
        await operations.prepareInstall(game)
        check(operations.installConsent == nil
              && operations.error == GameInstallLocationError.destinationExists.localizedDescription,
              "H1: Removing registration never grants Install permission to overwrite the retained unmanaged folder")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: repaired.folder))
        for code in [10, 11, 12, 14] {
            try writeMode(String(code))
            try await install()
            check((code == 14 ? (operations.error == nil && operations.notice != nil)
                               : operations.error == GameScriptError.failed(code).localizedDescription) && operations.log != nil
                  && installed.games.isEmpty && !operations.isBusy,
                  "S5 code \(code) has truthful failure/cancellation feedback and cannot become installed")
        }
        try writeMode("resultfailure")
        try await install()
        check(operations.failureCode == 13 && operations.error == GameScriptError.failed(13).localizedDescription
              && installed.games.isEmpty && !operations.isBusy,
              "Present install result on nonzero exit is decoded without registering a false installed success")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: repaired.folder))
        let unsupportedCache = compatibilityData.replacingOccurrences(of: "\"supported\":true", with: "\"supported\":false")
            .replacingOccurrences(of: "\"reason\":null", with: "\"reason\":\"Neutral Xbox feature is not supported.\"")
        try privateFile(cached, unsupportedCache)
        try writeMode("12")
        try await install()
        check(operations.error == "Neutral Xbox feature is not supported."
              && operations.compatibility[game.id]?.supported == false && installed.games.isEmpty,
              "B3: Install code 12 shows the private backend cache reason verbatim, without registration")
        try privateFile(cached, "{}")
        try writeMode("12progress")
        try await install()
        check(operations.error == "Neutral terminal package reason." && installed.games.isEmpty
              && operations.compatibilityErrors[game.id] != nil,
              "B3: Code 12 falls back to its bounded terminal failed-progress message when cache is invalid")
        try privateFile(cached, compatibilityData)
        try writeMode("13progress")
        try await install()
        check(operations.error == "Authorized broker returned no account credentials."
              && operations.failureCode == 13 && installed.games.isEmpty,
              "Install failures preserve a validated backend progress reason instead of generic code 13 copy")
        for mode in ["missing", "mismatch", "invalidprogress"] {
            try writeMode(mode)
            try await install()
            check(operations.error != nil && operations.log != nil && installed.games.isEmpty
                  && !operations.isBusy && operations.canQuit,
                  "S5 \(mode) is a joined failure with Show log, not a registration or orphan")
        }
        let other = PCGame(id: "FIXTURE00002", title: "Second Fixture", artwork: nil)
        try writeMode("badconfig")
        try await install(other)
        check(installed.games.isEmpty && operations.recoveryRequired && operations.error != nil,
              "S5 a successful script cannot bypass missing MicrosoftGame.config")
        await operations.reconcile()
        check(installed.games.isEmpty && operations.recoveryRequired,
              "S5 receipt reconciliation never bypasses the shared import validator")
        let journal = GameOperationJournal(file: paths.journal)
        let saved = try await journal.load()
        check(saved?.productID == other.id, "S5 interrupted registration retains its exact pending receipt")
        let recordMode = (try FileManager.default.attributesOfItem(atPath: paths.journal.path)[.posixPermissions] as? NSNumber)?.intValue
        let dirMode = (try FileManager.default.attributesOfItem(atPath: paths.journal.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        check(recordMode == 0o600 && dirMode == 0o700, "S5 pending journal is atomic/private with 0600/0700")
        installed.releaseMutation()
        let recovered = GameOperationsController(installed: installed, paths: paths,
                                                 compatibilityCatalogue: catalogue)
        await recovered.restore()
        check(recovered.recoveryRequired && recovered.operation?.id == saved?.id && !recovered.canStartMutation,
              "S5 reopening a pending operation does not replay scripts or silently permit another mutation")
        checkUnrelatedDetail(recovered, owner: other.id, stage: "restored recovery")
        check(recovered.feedbackProductID == other.id
              && GameOperationProgressView(operations: recovered, productID: other.id).presentedOperation?.id == saved?.id,
              "XO-022: Valid journal recovery restores its exact product ownership without replay")
        let recoveredFolder = try paths.destination(title: other.title, productID: other.id)
        try privateFile(recoveredFolder.appendingPathComponent("MicrosoftGame.config"),
            "<Game><Identity Name=\"Fixture.Second\" Version=\"1.2.3.4\"/><StoreId>\(other.id)</StoreId></Game>")
        await recovered.reconcile()
        check(!recovered.recoveryRequired && !recovered.isBusy && installed.games.first?.storeId == other.id,
              "S5 explicit reconciliation can finish validated registration without another script invocation")
        let cancellationRunner = GameScriptRunner(paths: paths)
        let cancelledRun = InstalledGamesController.runID()
        await cancellationRunner.cancel(runID: cancelledRun)
        let cancelledBeforeStart = try await cancellationRunner.run(command: .install, runID: cancelledRun,
            arguments: [other.id, recoveredFolder.path])
        let cancelledReceipt = try paths.receipt(cancelledRun, suffix: "status")
        check(cancelledBeforeStart.code == 14
              && !FileManager.default.fileExists(atPath: cancelledReceipt.path),
              "S5 cancellation before Process.run does not spawn a script or invent a persisted receipt")
        for arguments in [[], ["invalid", recoveredFolder.path], [other.id, root.path + "/../escape"]] {
            do {
                _ = try await cancellationRunner.run(command: .install, runID: InstalledGamesController.runID(), arguments: arguments)
                check(false, "S5 command arguments are validated before launch")
            } catch { check(true, "S5 command arguments are validated before launch") }
        }
        do {
            _ = try await cancellationRunner.run(command: .uninstall, runID: InstalledGamesController.runID(),
                                                 arguments: [other.id, root.path])
            check(false, "S6 uninstall is confined to the approved game root")
        } catch { check(true, "S6 uninstall is confined to the approved game root") }
        try writeMode("wrongid")
        guard let current = installed.games.first else { throw GameScriptError.invalidReceipt }
        await recovered.prepareInstall(other, repairing: current)
        guard let mismatchRepair = recovered.installConsent else { throw GameScriptError.invalidDestination }
        recovered.confirmInstall(mismatchRepair)
        await recovered.waitForMutation()
        check(recovered.recoveryRequired && recovered.error != nil && installed.games.first?.storeId == other.id,
              "S5/S6 result StoreId mismatch cannot replace an existing registration")
        await recovered.reconcile()
        check(recovered.recoveryRequired && installed.games.first?.id == current.id,
              "S5/S6 recovery cannot promote a mismatched result")
        let badID = root.appendingPathComponent("bad-id.status")
        try privateFile(badID, "0")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: badID.path)
        do { _ = try GameScriptFiles.read(badID); check(false, "Script receipts require private mode") }
        catch { check(true, "Script receipts require private mode") }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("receipt-link"), withDestinationURL: badID)
        do { _ = try GameScriptFiles.read(root.appendingPathComponent("receipt-link")); check(false, "Symlink receipts are refused") }
        catch { check(true, "Symlink receipts are refused") }
        let oversize = root.appendingPathComponent("oversized-result.json")
        try privateFile(oversize, String(repeating: "x", count: 65_537))
        do { _ = try GameScriptFiles.read(oversize); check(false, "S5 receipt reading is bounded at 64KiB") }
        catch { check(true, "S5 receipt reading is bounded at 64KiB") }
        for code in ["-1", "256", "0junk", ""] {
            do { _ = try GameScriptFiles.status(Data(code.utf8)); check(false, "S5 malformed terminal status is explicit") }
            catch { check(true, "S5 malformed terminal status is explicit") }
        }
        let windows = NSApplication.shared.windows.count
        for width in [CGFloat(700), CGFloat(1100)] {
            let host = NSHostingView(rootView: GameOperationProgressView(operations: recovered))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 400)
            host.layoutSubtreeIfNeeded()
            check(host.frame.width == width && NSApplication.shared.windows.count == windows,
                  "S5 native progress/recovery lays out without presenting a window or starting a script")
            let setupHost = NSHostingView(rootView: GameSetupView(operations: recovered))
            setupHost.sizingOptions = []
            setupHost.frame = CGRect(x: 0, y: 0, width: width, height: 400)
            setupHost.layoutSubtreeIfNeeded()
            check(setupHost.window == nil && NSApplication.shared.windows.count == windows
                  && recovered.setupResult == nil && !recovered.setupBusy,
                  "B8 setup layout itself never runs a check, repair, sign-in or window presentation")
        }
        installed.releaseMutation()
        try privateFile(paths.journal, "Neutral invalid journal, no recoverable product identity.")
        let unknownRecovery = GameOperationsController(installed: installed, paths: paths,
                                                       compatibilityCatalogue: catalogue)
        await unknownRecovery.restore()
        for scope in [Optional<String>.none, game.id, other.id] {
            let feedback = GameOperationProgressView(operations: unknownRecovery, productID: scope)
            check(unknownRecovery.recoveryRequired && unknownRecovery.feedbackProductID == nil
                  && unknownRecovery.operation == nil && !unknownRecovery.canStartMutation
                  && feedback.operationError == GameScriptError.storage.localizedDescription
                  && !feedback.showsGameSignIn && !feedback.showsLog,
                  "XO-022: Unbound corrupt-journal storage failure remains visible globally and on either detail without invented ownership")
        }
        let privateFailure = GameOperationProgressView(operations: unknownRecovery, privacyRestricted: true,
                                                       productID: game.id)
        check(privateFailure.operationError == "The game operation needs attention. Sign in to review its details."
              && privateFailure.operationTitle == nil && !privateFailure.showsLog,
              "XO-022: Unknown/global recovery retains welcome privacy redaction")
        installed.releaseMutation()
        for repairing in [true, false] {
            let label = repairing ? "changed-entry" : "occupied-destination"
            let consentStore = InstalledGameStore(file: root.appendingPathComponent("registry/\(label).json"))
            let consentLibrary = InstalledGamesController(store: consentStore, defaultEngine: { nil },
                detectAvailability: { RunnerAvailability([.crossover]) })
            await consentLibrary.load()
            let consentPaths = GameScriptPaths(scripts: paths.scripts, processed: paths.processed,
                logs: paths.logs, games: root.appendingPathComponent("\(label)/games"),
                journal: root.appendingPathComponent("\(label)/operation.json"))
            let controller = GameOperationsController(installed: consentLibrary, paths: consentPaths,
                                                      compatibilityCatalogue: catalogue)
            let a = PCGame(id: "FIXTURE00004", title: "Consent A", artwork: nil)
            let b = PCGame(id: "FIXTURE00005", title: "Queued B", artwork: nil)
            let aFolder = try consentPaths.destination(title: a.title, productID: a.id)
            func queuedRecord(_ game: PCGame) throws -> GameOperationRecord {
                GameOperationRecord(id: InstalledGamesController.runID(), kind: .install,
                    productID: game.id, title: game.title,
                    destination: try consentPaths.destination(title: game.title, productID: game.id).path, installedID: nil)
            }
            try writeMode("success")
            if repairing {
                check(await controller.runQueuedOperation(try queuedRecord(a), onProgress: { _ in }) == .complete,
                      "XO-022 consent: Fixture A registration succeeds through the real queued-operation path")
            }
            await controller.prepareInstall(a, repairing: repairing ? consentLibrary.games.first : nil)
            guard let retained = controller.installConsent else { throw GameScriptError.invalidDestination }
            check(retained.compatibility?.supported == true && controller.canConfirmInstall,
                  "XO-022 consent: A has an admitted reviewed consent before B starts")
            try writeMode(repairing ? "success" : "11")
            let outcome = await controller.runQueuedOperation(try queuedRecord(b), onProgress: { _ in })
            check(outcome == (repairing ? .complete : .fail(code: 11))
                  && controller.installConsent?.id == retained.id && controller.feedbackProductID == b.id
                  && controller.log != nil
                  && (repairing ? controller.notice != nil : controller.failureCode == 11),
                  "XO-022 consent: Accepted B completes with real terminal metadata while reviewed A consent survives")
            if repairing {
                guard let original = consentLibrary.games.first(where: { $0.storeId == a.id }) else {
                    throw GameScriptError.invalidReceipt
                }
                await consentLibrary.remove(original)
            } else {
                try FileManager.default.createDirectory(at: aFolder, withIntermediateDirectories: true)
                try privateFile(aFolder.appendingPathComponent("MicrosoftGame.config"),
                    "<Game><Identity Name=\"Fixture.ConsentA\" Version=\"1.2.3.4\"/><StoreId>\(a.id)</StoreId></Game>")
                await consentLibrary.importGame(folder: aFolder, launcher: launcher)
            }
            let previousError = controller.error
            let previousNotice = controller.notice
            let previousLog = controller.log
            let previousCode = controller.failureCode
            try consentLibrary.reserveMutation(gameID: nil)
            controller.confirmInstall(retained)
            check(controller.installConsent?.id == retained.id && controller.feedbackProductID == b.id
                  && controller.error == previousError && controller.notice == previousNotice
                  && controller.log == previousLog && controller.failureCode == previousCode,
                  "XO-022 consent: Mutation-rejected confirmation preserves B feedback and A consent unchanged")
            consentLibrary.releaseMutation()
            check(controller.canConfirmInstall
                  && (repairing ? !consentLibrary.games.contains(where: { $0.storeId == a.id })
                      : consentLibrary.games.contains(where: { $0.storeId == a.id && $0.folder == retained.destination.path })),
                  "XO-022 consent: A's \(label) validation failure is reachable after normal admission")
            controller.confirmInstall(retained)
            let expected = repairing ? "This game's installed entry changed. Choose it again."
                : GameScriptError.invalidDestination.localizedDescription
            check(controller.error == expected && controller.feedbackProductID == a.id
                  && controller.notice == nil && controller.log == nil && controller.failureCode == nil
                  && controller.operation == nil && controller.installConsent == nil,
                  "XO-022 consent: Admitted \(label) failure belongs to A without B's stale notice/log/code")
            check(GameOperationProgressView(operations: controller, productID: a.id).operationError == expected
                  && GameOperationProgressView(operations: controller).operationError == expected,
                  "XO-022 consent: Matching A and global presentation retain the genuine validation failure")
            checkUnrelatedDetail(controller, owner: a.id, stage: "consent \(label) failure")
            let bFeedback = GameOperationProgressView(operations: controller, productID: b.id)
            check(bFeedback.operationError == nil && bFeedback.operationNotice == nil
                  && !bFeedback.showsGameSignIn && !bFeedback.showsLog,
                  "XO-022 consent: B does not receive A's validation failure or its own stale recovery controls")
            controller.confirmInstall(retained)
            check(controller.feedbackProductID == a.id && controller.error == expected,
                  "XO-022 consent: Rejected replay of consumed consent does not reset genuine feedback")
        }
    }
}
