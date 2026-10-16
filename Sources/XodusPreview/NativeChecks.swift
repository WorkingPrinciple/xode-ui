// SPDX-License-Identifier: GPL-3.0-only
import CoreFoundation
import CryptoKit
import Foundation
import XodusManagement

@MainActor
enum NativeChecks {
    static func launch(gameOperationsOnly: Bool = false, mediaOnly: Bool = false, statsOnly: Bool = false,
                       libraryAccessOnly: Bool = false) -> Never {
        Task { exit(await run(gameOperationsOnly: gameOperationsOnly, mediaOnly: mediaOnly, statsOnly: statsOnly,
                              libraryAccessOnly: libraryAccessOnly) ? 0 : 1) }
        CFRunLoopRun()
        fatalError("The native check run loop ended before completion.")
    }

    static func run(gameOperationsOnly: Bool = false, mediaOnly: Bool = false, statsOnly: Bool = false,
                    libraryAccessOnly: Bool = false) async -> Bool {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if condition { print("PASS: \(name)") }
            else {
                failures += 1
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
            }
            fflush(stdout)
        }
        func configuration(_ scenario: String) -> BackendConfiguration {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("XodusManagementChecks")
            let state = FileManager.default.temporaryDirectory
                .appendingPathComponent("XodusNativeChecks-\(UUID().uuidString)").appendingPathComponent(scenario)
            return BackendConfiguration(executable: executable, stateDirectory: state)
        }
        func session(_ scenario: String) -> LiveSession { LiveSession(configuration: configuration(scenario)) }
        func trace(_ configuration: BackendConfiguration) throws -> [String] {
            try String(contentsOf: configuration.stateDirectory.appendingPathComponent("lifecycle.log"),
                       encoding: .utf8).split(separator: "\n").map(String.init)
        }
        func cleanLifecycle(_ configuration: BackendConfiguration) throws {
            try FileManager.default.removeItem(at: configuration.stateDirectory.deletingLastPathComponent())
        }
        func waitForTrace(_ marker: String, _ configuration: BackendConfiguration) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while true {
                if FileManager.default.fileExists(atPath: configuration.stateDirectory.appendingPathComponent("lifecycle.log").path),
                   try trace(configuration).contains(marker) { return }
                guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        do {
            let navigation = AppState()
            navigation.query = "Library search"
            navigation.navigate(.discover)
            navigation.query = "Store search"
            navigation.navigate(.library)
            check(navigation.query == "Library search", "Library query survives tab navigation")
            navigation.navigate(.discover)
            check(navigation.query == "Store search", "Discover query survives tab navigation")
            let playbackArguments = (true, true, false, false, true, true, true)
            check(HeroMotionPolicy.permitsPlayback(allowed: playbackArguments.0, enabled: playbackArguments.1,
                    reduceMotion: playbackArguments.2, lowPower: playbackArguments.3,
                    active: playbackArguments.4, visible: playbackArguments.5, hasTrailer: playbackArguments.6),
                  "Visible active hero can stream muted artwork")
            for fence in 0..<8 {
                check(!HeroMotionPolicy.permitsPlayback(allowed: fence != 0, enabled: fence != 1,
                        reduceMotion: fence == 2, lowPower: fence == 3,
                        active: fence != 4, visible: fence != 5, hasTrailer: fence != 6,
                        supportsViewportVisibility: fence != 7),
                      "Hero playback respects lifecycle fence \(fence)")
            }
            try LibraryAccessChecks.run(check: check)
            if libraryAccessOnly {
                try await PCGamesChecks.run(check: check)
                print("\(count) Library access checks, \(failures) failures. Synthetic data only.")
                return failures == 0
            }
            if statsOnly {
                do { try await LibraryStatsChecks.run(check: check) }
                catch { check(false, "Stats fixture failed: \(error.localizedDescription)") }
                print("\(count) Xbox stats checks, \(failures) failures. Synthetic scripts only.")
                return failures == 0
            }
            if mediaOnly {
                do { try await CatalogMediaChecks.run(check: check) }
                catch {
                    check(false, "Public-media fixture failed: \(error.localizedDescription)")
                }
                print("\(count) public-media checks, \(failures) failures. Synthetic transport only.")
                return failures == 0
            }
            if gameOperationsOnly {
                try await GameOperationChecks.run(check: check)
                print("\(count) game operation checks, \(failures) failures. Synthetic scripts only.")
                return failures == 0
            }
            try await InstalledGameChecks.run(check: check)
            try await CatalogDetailLoadingChecks.run(check: check)
            try await PCGamesChecks.run(check: check)
            try await GameOperationChecks.run(check: check)
            try await DownloadQueueChecks.run(check: check)
            try await InstalledGameUpdateChecks.run(check: check)
            func observationFailure(_ message: String, code: String = "AUTH_INVALID",
                                    reason: String = "pipelineFailed") throws -> WireFailure {
                let value = JSONValue.object([
                    "code": .string(code), "message": .string(message), "retryable": .bool(false),
                    "details": .object(["category": .string("nativeConsentFailure"),
                                       "stage": .string("nativeSignIn"), "reason": .string(reason)])
                ])
                return try JSONDecoder().decode(WireFailure.self, from: JSONEncoder().encode(value))
            }
            for reason in ["helper.invalidFrame", "helper.invalidNavigation", "helper.navigationFailed",
                           "helper.popupUnsupported", "helper.contentTerminated", "helper.javaScriptFailed",
                           "helper.bridgeInvalid", "helper.deadlineExpired", "helper.parentUnavailable",
                           "channelEOF", "unclassified", "tokenExchangeFailed", "helperCompletionFailed",
                           "tokenExchange.requestBuild", "tokenExchange.requestSerialization",
                           "tokenExchange.requestTransport", "tokenExchange.requestTimeout",
                           "tokenExchange.httpClientError", "tokenExchange.httpServerError",
                           "tokenExchange.httpStatusRejected", "tokenExchange.responseParsing",
                           "tokenExchange.responseSignature", "tokenExchange.responseCryptography",
                           "tokenExchange.responseEncoding", "tokenExchange.continuationRequired",
                           "tokenExchange.faultWithoutContinuation", "tokenExchange.continuationRejected",
                           "exchangeRetentionFailed"] {
                let message = "Native sign-in failed: \(reason)."
                check(try LiveSession.validatedNativeSignInObservation(observationFailure(message)) == message,
                      "Exact approved \(reason) observation is available under Account Details")
                let snapshot = try LiveSession.SignInFailureSnapshot(observationFailure(message))
                check(snapshot.code == .invalid && snapshot.diagnostic == .pipelineFailed
                      && snapshot.observation == message,
                      "Latest-failure snapshot keeps only the closed \(reason) diagnostic")
            }
            for message in ["Native sign-in failed: helper.unknown.", "Native sign-in failed: channelEOF. secret",
                            " Native sign-in failed: helper.bridgeInvalid.", "Native sign-in failed: channelEOF.\n",
                            "secret raw provider text", "Native sign-in failed: helper.navigationFailed",
                            "Native sign-in failed: helper.navigationFailed. https://provider.invalid/?token=secret",
                            "Native sign-in failed: helper.tokenExchangeFailed.",
                            "Native sign-in failed: tokenExchangeFailed. extra",
                            "Native sign-in failed: helperCompletionFailed.\n",
                            "Native sign-in failed: helperCompletionFailed",
                            "Native sign-in failed: tokenExchange.unknown.",
                            "Native sign-in failed: tokenExchange.requestTransport. extra",
                            "Native sign-in failed: tokenExchange.requestTimeout.\n",
                            "Native sign-in failed: tokenExchange.responseParsing. https://provider.invalid/",
                            "Native sign-in failed: exchangeRetentionFailed. extra",
                            "Native sign-in failed: exchangeRetentionFailed"] {
                check(try LiveSession.validatedNativeSignInObservation(observationFailure(message)) == nil,
                      "Unapproved or extended engine wording never enters the displayed native observation")
            }
            check(try LiveSession.validatedNativeSignInObservation(
                observationFailure("Native sign-in failed: helper.bridgeInvalid.", code: "INTERNAL")) == nil
                  && LiveSession.validatedNativeSignInObservation(
                    observationFailure("Native sign-in failed: helper.bridgeInvalid.", reason: "unexpected")) == nil,
                  "An exact observation is rejected without the agreed AUTH_INVALID/nativeSignIn/pipelineFailed tuple")
            let unknownSnapshot = try LiveSession.SignInFailureSnapshot(
                observationFailure("Secret-shaped upstream token=value", code: "UNKNOWN_token=value", reason: "unexpected"))
            let unknownRequest = LiveSession.SignInFailureSnapshot(
                requestError: ManagementError.backendError("UNKNOWN_token=value", retryable: false))
            check(unknownSnapshot.code == nil && unknownSnapshot.diagnostic == nil && unknownSnapshot.observation == nil
                  && unknownRequest.code == nil && unknownRequest.diagnostic == nil && unknownRequest.observation == nil,
                  "Unclassified helper/exchange/commit errors retain no raw code, details or secret-shaped message")
            for reason in ["tokenExchangeFailed", "helperCompletionFailed",
                           "tokenExchange.requestBuild", "tokenExchange.requestSerialization",
                           "tokenExchange.requestTransport", "tokenExchange.requestTimeout",
                           "tokenExchange.httpClientError", "tokenExchange.httpServerError",
                           "tokenExchange.httpStatusRejected", "tokenExchange.responseParsing",
                           "tokenExchange.responseSignature", "tokenExchange.responseCryptography",
                           "tokenExchange.responseEncoding", "tokenExchange.continuationRequired",
                           "tokenExchange.faultWithoutContinuation", "tokenExchange.continuationRejected",
                           "exchangeRetentionFailed"] {
                let message = "Native sign-in failed: \(reason)."
                check(try LiveSession.validatedNativeSignInObservation(
                    observationFailure(message, code: "INTERNAL")) == nil
                      && LiveSession.validatedNativeSignInObservation(
                        observationFailure(message, reason: "unexpected")) == nil,
                      "Exact \(reason) boundary wording requires the unchanged approved failure tuple")
            }
            try await CrossOverDependencyChecks.run(check: check)
            try await ApplicationTerminationChecks.run(check: check)
            try await RecentLibraryChecks.run(check: check)
            try await CatalogMediaChecks.run(check: check)
            try await LibraryStatsChecks.run(check: check)
            let expired = session("expired")
            await expired.connect()
            check(expired.isReady && !expired.canSignIn, "Unchecked account cannot blindly retry a mutation")
            check(!expired.hasConfirmedSignIn && !expired.nativeSignInHostAdmitted
                  && !expired.canStartWelcomeSignIn,
                  "HELLO alone cannot unlock welcome or enable sign-in without an admitted helper")
            check(expired.authentication == nil && !expired.accountStatusCurrent
                  && expired.currentCredentialState == nil && expired.accountSymbol == "person.crop.circle"
                  && expired.accountLabel == "Account status not checked"
                  && expired.accountLibraryTitle == expired.accountLabel
                  && expired.accountExplanation.contains("engine is connected")
                  && expired.accountExplanation.contains("has not been checked"),
                  "HELLO and advertised auth support display connected-but-unchecked, never saved account evidence")
            await expired.refreshAccount()
            check(!expired.hasConfirmedSignIn, "Expired credentials keep games behind welcome")
            check(expired.authentication?.state == .expired && expired.needsAccountDisconnect
                  && expired.canDisconnectAccount && !expired.canSignIn,
                  "Expired profile exposes confirmed disconnect recovery, not rejected sign-in")
            await expired.signOut()
            check(!expired.hasConfirmedSignIn && !expired.canStartWelcomeSignIn,
                  "Signed-out status and advertised capabilities cannot bypass missing helper admission")
            check(expired.authentication?.state == .signedOut && expired.canSignIn,
                  "Confirmed launcher logout establishes signed-out state before sign-in")
            await expired.beginSignIn()
            check(!expired.hasConfirmedSignIn, "A pending sign-in cannot dismiss welcome")
            try await wait { expired.authentication?.flow?.state == .completed }
            check(expired.hasConfirmedSignIn, "Only confirmed completion unlocks the existing game surfaces")
            check(expired.authentication?.state == .credentialPresent && !expired.signInPending,
                  "Expired-profile recovery completes through actual mocked native session requests")
            check(expired.currentCredentialState == .credentialPresent
                  && expired.accountLabel == "Microsoft sign-in saved"
                  && expired.accountSymbol == "person.crop.circle.fill"
                  && expired.accountExplanation.contains("not proof of PC ownership")
                  && expired.accountLibraryTitle == "PC library access is not available yet",
                  "Fresh saved sign-in displays only credential evidence, not an owned or playable library")
            await expired.disconnect()
            check(!expired.hasConfirmedSignIn, "Disconnect immediately hides retained game surfaces")

            let savedBase = configuration("savedpermission")
            let neutralHelper = savedBase.stateDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent("neutral-helper")
            try FileManager.default.createDirectory(at: neutralHelper.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let helperBytes = Data("#!/bin/sh\nexit 90\n".utf8)
            try helperBytes.write(to: neutralHelper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: neutralHelper.path)
            let savedConfiguration = BackendConfiguration(
                executable: savedBase.executable, stateDirectory: savedBase.stateDirectory,
                nativeAuthHost: NativeAuthHostBinding(executable: neutralHelper,
                    sha256: SHA256.hash(data: helperBytes).map { String(format: "%02x", $0) }.joined()))
            let saved = LiveSession(configuration: savedConfiguration)
            await saved.prepareWelcome()
            check(saved.hasConfirmedSignIn && saved.nativeSignInHostAdmitted,
                  "Welcome preparation restores only confirmed saved status through the admitted neutral pair")
            check(saved.currentCredentialState == .credentialPresent
                  && saved.accountSymbol == "person.crop.circle.fill" && saved.canDisconnectAccount,
                  "Neutral saved profile initially displays the current credential result")
            await saved.revalidateAccountOnForeground()
            check(!saved.hasConfirmedSignIn && !saved.canStartWelcomeSignIn,
                  "F5: Failed foreground status locks retained cached data instead of trusting a saved snapshot")
            check(saved.isReady && saved.authentication?.state == .credentialPresent
                  && !saved.accountStatusCurrent && saved.currentCredentialState == nil
                  && saved.accountLabel == "Account status needs checking"
                  && saved.accountSymbol == "person.crop.circle"
                  && saved.accountLibraryTitle == saved.accountLabel
                  && !saved.accountLibraryExplanation.contains("sign-in is saved")
                  && saved.accountExplanation.contains("earlier result is not current")
                  && !saved.canSignIn && !saved.canDisconnectAccount,
                  "Failed status read retains the safe snapshot but removes saved-account claims across all live surfaces")
            check(saved.accountStatusError == .credentialStoreUnavailable
                  && saved.accountMessage.contains("cannot access Keychain")
                  && saved.accountMessage.contains("Sign-in stays disabled")
                  && saved.accountError == ManagementError.credentialStoreUnavailable.localizedDescription,
                  "Blocked Keychain status has a typed cause and visible recovery, not an unexplained gray sign-in")
            await saved.refreshAccount()
            check(saved.hasConfirmedSignIn, "A successful status retry restores access without fabricated ownership")
            check(saved.accountStatusCurrent && saved.currentCredentialState == .credentialPresent
                  && saved.accountLabel == "Microsoft sign-in saved" && saved.canDisconnectAccount
                  && saved.authentication?.entitlementAuthorized == false,
                  "Fresh status restores credential display without promoting PC access")
            check(saved.accountStatusError == nil,
                  "A successful fresh status clears the earlier typed Keychain-access failure")
            check(try trace(savedConfiguration).filter { $0.hasPrefix("auth.") } ==
                  ["auth.status", "auth.status", "auth.status"],
                  "Account display recovery performs only neutral requested status reads, no sign-in or logout mutation")
            await saved.signOut()
            check(!saved.hasConfirmedSignIn && saved.canStartWelcomeSignIn,
                  "Explicit sign-out returns to welcome and admits a new sign-in only with the bound helper")
            await saved.beginSignIn()
            check(!saved.hasConfirmedSignIn && !saved.canStartWelcomeSignIn,
                  "Welcome sign-in immediately fences duplicate activation and keeps games hidden")
            try await wait { saved.authentication?.flow?.state == .completed }
            check(saved.hasConfirmedSignIn && saved.authentication?.entitlementAuthorized == false,
                  "Welcome completion unlocks navigation without claiming game entitlement")
            check(await saved.disconnect(), "Account presentation regression retires its owned neutral child")
            check(saved.currentCredentialState == nil && saved.accountSymbol == "person.crop.circle"
                  && saved.accountLabel == "Connect Xodus" && saved.accountStatusError == nil,
                  "Disconnect removes current account presentation evidence")
            try cleanLifecycle(savedConfiguration)

            let permissionConfiguration = configuration("statuspermission")
            let permission = LiveSession(configuration: permissionConfiguration)
            await permission.connect()
            let readingPermission = Task { await permission.revalidateAccountOnForeground() }
            try await wait { permission.accountStatusChecking }
            check(permission.accountBusy && !permission.accountStatusCurrent
                  && !permission.canSignIn && !permission.canDisconnectAccount
                  && permission.accountNoticeTitle == "Checking saved sign-in"
                  && permission.accountMessage.contains("macOS asks for Keychain access"),
                  "Foreground Keychain check shows native permission guidance and fences account actions")
            await permission.refreshAccount()
            await permission.revalidateAccountOnForeground()
            await permission.beginSignIn()
            await permission.signOut()
            await readingPermission.value
            check(try trace(permissionConfiguration).filter { $0.hasPrefix("auth.") } == ["auth.status"],
                  "F5: Concurrent foreground/status checks and gated mutations issue only one status request")
            check(permission.currentCredentialState == .credentialPresent && !permission.accountBusy
                  && !permission.accountStatusChecking && permission.accountStatusCurrent,
                  "Actual status alone restores saved-state presentation after the bounded permission wait")
            let retiringRead = Task { await permission.revalidateAccountOnForeground() }
            try await wait { permission.accountStatusChecking }
            check(permission.hasConfirmedSignIn,
                  "F5: Foreground revalidation preserves confirmed UI only while its bounded read is in flight")
            await permission.revalidateAccountOnForeground()
            await permission.disconnect()
            await retiringRead.value
            check(permission.authentication == nil && !permission.accountStatusCurrent
                  && !permission.accountBusy && !permission.accountStatusChecking,
                  "A retired generation's status completion cannot restore credentials or checking state")
            try cleanLifecycle(permissionConfiguration)

            let foregroundConfiguration = configuration("foregroundexpired")
            let foreground = LiveSession(configuration: foregroundConfiguration)
            await foreground.revalidateAccountOnForeground()
            check(foreground.phase == .disconnected && !foreground.accountBusy,
                  "F5: Foreground revalidation cannot connect an unpaired or disconnected session")
            await foreground.connect()
            await foreground.revalidateAccountOnForeground()
            check(foreground.hasConfirmedSignIn, "F5: Fresh foreground credential status can confirm the account")
            await foreground.revalidateAccountOnForeground()
            check(!foreground.hasConfirmedSignIn && foreground.currentCredentialState == .expired
                  && foreground.accountStatusCurrent,
                  "F5: A confirmed account that expires on foreground relocks without treating expiry as a read failure")
            check(try trace(foregroundConfiguration).filter { $0.hasPrefix("auth.") } ==
                  ["auth.status", "auth.status"],
                  "F5: Foreground checks use only bounded management status, never PC/game sign-in")
            await foreground.disconnect()
            try cleanLifecycle(foregroundConfiguration)

            let denied = session("expiredpermission")
            await denied.connect()
            await denied.refreshAccount()
            check(denied.currentCredentialState == .expired
                  && denied.accountExplanation.hasPrefix("Disconnect this saved launcher sign-in first"),
                  "Only a current expired result displays saved-profile recovery advice")
            await denied.refreshAccount()
            check(denied.authentication?.state == .expired && !denied.canDisconnectAccount,
                  "An inaccessible-store error disables disconnect of an earlier expired snapshot")
            check(denied.currentCredentialState == nil
                  && denied.accountLabel == "Account status needs checking"
                  && !denied.accountExplanation.contains("Disconnect this saved")
                  && denied.accountLibraryTitle == denied.accountLabel,
                  "Unconfirmed expired snapshot does not display current expiry or recommend credential removal")
            await denied.signOut()
            await denied.refreshAccount()
            check(denied.authentication?.state == .expired,
                  "Unavailable-store recovery preserves the existing profile without a deletion request")
            await denied.disconnect()

            let uncertain = session("beginfail")
            await uncertain.connect()
            await uncertain.refreshAccount()
            await uncertain.beginSignIn()
            check(!uncertain.accountStatusCurrent && !uncertain.canSignIn,
                  "Failed sign-in preparation invalidates pre-mutation status before another attempt")
            check(uncertain.accountLabel == "Account status needs checking"
                  && uncertain.currentCredentialState == nil,
                  "Failed sign-in preparation does not leave a current signed-out display")
            let preparationSummary = uncertain.errorMessage ?? ""
            check(preparationSummary.hasPrefix("Microsoft sign-in could not start.")
                  && preparationSummary.contains("Check account status")
                  && !preparationSummary.contains("AUTH_INVALID") && !preparationSummary.contains("stageUnavailable")
                  && !preparationSummary.contains("disconnect") && !preparationSummary.contains("saved sign-in")
                  && !preparationSummary.contains("Original preparation upstream sentinel"),
                  "Request-level sign-in failure never implies invalid saved credentials or deletion advice")
            let preparationFailure = uncertain.lastSignInFailure
            check(preparationFailure?.code == .invalid && preparationFailure?.diagnostic == nil
                  && preparationFailure?.observation == nil
                  && uncertain.accountFailureDetails?.contains("AUTH_INVALID") == true
                  && uncertain.accountFailureDetails?.contains("Stage: Not reported") == true,
                  "A terminal request error latches only its closed code and an unavailable stage")
            await uncertain.refreshAccount()
            check(uncertain.accountStatusCurrent && uncertain.canSignIn,
                  "A fresh status read is required to recover from failed sign-in preparation")
            await uncertain.disconnect()
            check(uncertain.lastSignInFailure == preparationFailure,
                  "Terminal request diagnostics survive no-flow status and client retirement")

            for scenario in ["failedflow", "failedflownocode"] {
                let failed = session(scenario)
                await failed.connect()
                await failed.refreshAccount()
                await failed.beginSignIn()
                let summary = failed.accountFailureDetails ?? ""
                let visibleSummary = failed.accountFailureSummary ?? ""
                check(!visibleSummary.isEmpty && !visibleSummary.contains("AUTH_INVALID")
                      && !visibleSummary.contains("stageUnavailable") && !visibleSummary.contains("Stage:"),
                      "Primary Account failure copy is human-readable; raw code and missing-stage facts stay in disclosure details")
                check(failed.authentication?.flow?.state == .failed && failed.isReady && !failed.signInPending
                      && !summary.isEmpty && !summary.contains("Original synthetic upstream wording")
                      && !summary.contains("disconnect") && !summary.contains("saved sign-in"),
                      "Failed auth flow surfaces a local safe reason without raw upstream message or success")
                check(scenario == "failedflow" ? summary.contains("AUTH_INVALID")
                      : summary.contains("Stage: Not reported") && !summary.contains("AUTH_INVALID"),
                      "Auth summary preserves the validated failure code and never invents a missing cause")
                check(failed.canSignIn && !failed.accountBusy,
                      "Terminal failure preserves the explicit user retry gate without an automatic retry")
                let snapshot = failed.lastSignInFailure
                await failed.refreshAccount()
                check(failed.authentication?.state == .signedOut && failed.authentication?.flow == nil
                      && failed.lastSignInFailure == snapshot && failed.accountFailureDetails == summary,
                      "Fresh signed-out/no-flow status cannot erase the last terminal failure")
                await failed.disconnect()
                check(failed.authentication == nil && failed.lastSignInFailure == snapshot
                      && failed.accountFailureDetails == summary,
                      "Disconnect preserves only the fixed terminal diagnostic for observation")
            }

            for diagnostic in NativeConsentFailure.allCases {
                let failed = session("failedstage-\(diagnostic.rawValue)")
                await failed.connect()
                await failed.refreshAccount()
                await failed.beginSignIn()
                let summary = failed.accountFailureDetails ?? ""
                let visibleSummary = failed.accountFailureSummary ?? ""
                check(!visibleSummary.isEmpty && !visibleSummary.contains(diagnostic.rawValue)
                      && !visibleSummary.contains("AUTH_INVALID") && !visibleSummary.contains("Stage:"),
                      "Known sign-in diagnostics retain specific safe details without exposing machine states as primary copy")
                check(failed.authentication?.flow?.error?.nativeConsentFailure == diagnostic
                      && summary.contains("Stage: \(diagnostic.stage)") && summary.contains("Reason: \(diagnostic.rawValue)")
                      && !summary.contains("Original synthetic upstream wording") && failed.isReady
                      && failed.authentication?.entitlementAuthorized == false && !failed.signInPending
                      && (diagnostic.stage != "devicePreparation"
                          || failed.accountFailureTitle == "Microsoft sign-in could not start."),
                      "Known closed auth stage/reason is locally mapped without upstream text or entitlement promotion")
                if diagnostic == .pipelineFailed {
                    check(summary.contains("does not establish that a browser appeared or consent completed"),
                          "Native pipeline diagnostic never invents observed Microsoft UI or successful consent")
                }
                if diagnostic == .providerProofInvalid {
                    check(summary.contains("did not provide a valid sign-in proof")
                          && !summary.contains("cryptograph") && !summary.contains("signature")
                          && !summary.contains("disconnect") && !summary.contains("delete"),
                          "Device-proof shape or missing-proof failure never invents a cryptographic cause or credential deletion")
                }
                let subsiteCopy: String?
                switch diagnostic {
                case .tokenKindInvalid:
                    subsiteCopy = "The device sign-in token uses a format this launcher cannot accept."
                case .tokenAudienceInvalid:
                    subsiteCopy = "The device sign-in token did not match the required context."
                case .tokenCipherInvalid:
                    subsiteCopy = "The device sign-in token payload could not be processed."
                case .tokenSecretInvalid:
                    subsiteCopy = "The device sign-in proof was missing or invalid."
                case .tokenXmlBoundInvalid:
                    subsiteCopy = "The device sign-in payload exceeded the supported processing limit."
                case .tokenXmlParseInvalid:
                    subsiteCopy = "The device sign-in payload could not be read in the required format."
                case .tokenCipherEncodingInvalid:
                    subsiteCopy = "The device sign-in payload encoding could not be processed."
                default:
                    subsiteCopy = nil
                }
                if let subsiteCopy {
                    check(summary.contains(subsiteCopy) && failed.accountFailureTitle == "Microsoft sign-in could not start."
                          && !summary.contains("cryptograph") && !summary.contains("signature")
                          && !summary.contains("Microsoft rejected") && !summary.contains("disconnect")
                          && !summary.contains("delete") && !summary.contains("4096")
                          && !summary.contains("version4") && !summary.contains("base64") && !summary.contains("STS")
                          && !summary.contains("64KiB") && !summary.contains("65536")
                          && !summary.contains("offset") && !summary.contains("your fault"),
                          "Static token subsite copy reports only the agreed guard category, not values or a guessed cause")
                }
                await failed.disconnect()
            }
            for diagnostic in [NativeConsentFailure.tokenKindInvalid, .tokenAudienceInvalid,
                               .tokenCipherInvalid, .tokenSecretInvalid,
                               .tokenXmlBoundInvalid, .tokenXmlParseInvalid, .tokenCipherEncodingInvalid] {
                var suffixes = ["extra", "unknown", "mismatched", "cancelcode", "expirycode", "internalcode"]
                if [.tokenXmlBoundInvalid, .tokenXmlParseInvalid, .tokenCipherEncodingInvalid].contains(diagnostic) {
                    suffixes += ["malformed", "category", "missing"]
                }
                for suffix in suffixes {
                    let failed = session("failedstage-\(diagnostic.rawValue)-\(suffix)")
                    await failed.connect()
                    await failed.refreshAccount()
                    await failed.beginSignIn()
                    let summary = failed.accountFailureDetails ?? ""
                    check(failed.isReady && failed.authentication?.flow?.error?.nativeConsentFailure == nil
                          && failed.authentication?.entitlementAuthorized == false && !failed.signInPending
                          && summary.contains("Stage: Not reported") && !summary.contains("Reason:")
                          && !summary.contains("Original extra-field sentinel")
                          && !summary.contains("Original synthetic upstream wording")
                          && failed.accountFailureTitle != "Microsoft sign-in could not start.",
                          "Actual mock-child subsite rejects malformed/extra/unknown/stage/non-AUTH details without secret retention or guessed preparation")
                    await failed.disconnect()
                }
            }
            for suffix in ["extra", "unknown", "mismatched", "cancelcode", "expirycode"] {
                let failed = session("failedstage-\(suffix)")
                await failed.connect()
                await failed.refreshAccount()
                await failed.beginSignIn()
                let summary = failed.accountFailureDetails ?? ""
                check(failed.isReady && failed.authentication?.flow?.error?.nativeConsentFailure == nil
                      && summary.contains("Stage: Not reported") && !summary.contains("Reason:")
                      && !summary.contains("Original extra-field sentinel") && !summary.contains("Original synthetic upstream wording"),
                      "Malformed/extra/unknown/incompatible diagnostics yield honest unavailable stage without secret sentinel")
                await failed.disconnect()
            }
            let gateConfiguration = configuration("authgate")
            let gated = LiveSession(configuration: gateConfiguration)
            await gated.connect()
            await gated.refreshAccount()
            let beginning = Task { await gated.beginSignIn() }
            try await wait { gated.accountBusy }
            await gated.beginSignIn()
            await beginning.value
            await gated.beginSignIn()
            check(try gated.signInPending && !gated.canSignIn && gated.accountFailureSummary == nil
                  && trace(gateConfiguration).filter { $0 == "auth.begin" }.count == 1,
                  "Busy and pending state reject duplicate native sign-in activation before any second mutation")
            check(gated.accountLabel == "Sign-in pending" && gated.currentCredentialState == nil
                  && gated.accountSymbol == "person.crop.circle"
                  && gated.accountExplanation.contains("If Microsoft has opened a sign-in window")
                  && gated.accountLibraryTitle == "Sign-in pending",
                  "Pending contract state does not assert an observed provider window or completed account connection")
            let cancelling = Task { await gated.cancelSignIn() }
            try await wait { gated.accountBusy }
            await gated.cancelSignIn()
            await cancelling.value
            check(try gated.authentication?.flow?.state == .cancelled && !gated.signInPending
                  && gated.accountFailureSummary == nil
                  && trace(gateConfiguration).filter { $0 == "auth.cancel" }.count == 1,
                  "Busy cancellation gate sends one request and does not invent failure-stage diagnostics")
            check(gated.currentCredentialState == .signedOut && gated.accountSymbol == "person.crop.circle"
                  && gated.accountLabel == "Sign in with Microsoft"
                  && gated.accountExplanation.contains("no saved launcher sign-in"),
                  "Confirmed cancellation returns signed-out presentation without a saved-account badge")
            check(!gated.hasConfirmedSignIn, "Confirmed cancellation keeps welcome locked without deleting games")
            let cancelledFlow = gated.authentication?.flow?.flowID
            check(gated.canSignIn && !gated.accountBusy,
                  "Confirmed cancellation enables an explicit next sign-in without deleting credentials")
            await gated.beginSignIn()
            check(try gated.signInPending && !gated.canSignIn
                  && gated.authentication?.flow?.flowID != cancelledFlow
                  && trace(gateConfiguration).filter { $0 == "auth.begin" }.count == 2,
                  "A user retry starts one distinct flow and immediately fences duplicate sign-in")
            let closedFlow = gated.authentication?.flow?.flowID
            try Data().write(to: gateConfiguration.stateDirectory.appendingPathComponent("native-window-closed"))
            try await wait { gated.authentication?.flow?.state == .cancelled && gated.canSignIn }
            check(try !gated.signInPending && gated.currentCredentialState == .signedOut
                  && gated.authentication?.flow?.flowID == closedFlow
                  && gated.authentication?.entitlementAuthorized == false
                  && trace(gateConfiguration).filter { $0 == "auth.cancel" }.count == 1,
                  "Observed helper-close cancellation clears pending via polling without an app cancel or saved badge")
            await gated.beginSignIn()
            check(try gated.signInPending && gated.authentication?.flow?.flowID != closedFlow
                  && trace(gateConfiguration).filter { $0 == "auth.begin" }.count == 3,
                  "An automatically closed attempt permits exactly one fresh user retry")
            await gated.cancelSignIn()
            await gated.disconnect()
            try cleanLifecycle(gateConfiguration)

            for scenario in ["authgate", "deadlinecompleted"] {
                let deadlineConfiguration = configuration(scenario)
                let deadlineSession = LiveSession(configuration: deadlineConfiguration,
                                                  signInPollingBudget: .milliseconds(1))
                await deadlineSession.connect()
                await deadlineSession.refreshAccount()
                await deadlineSession.beginSignIn()
                if scenario == "authgate" {
                    try await wait { deadlineSession.accountError != nil && !deadlineSession.accountBusy }
                    check(deadlineSession.signInPending && !deadlineSession.accountStatusCurrent
                          && !deadlineSession.canSignIn && !deadlineSession.canDisconnectAccount,
                          "Final deadline read retains unknown pending outcome and invalidates freshness without cancellation")
                    check(try trace(deadlineConfiguration).filter { $0 == "auth.status" }.count == 2
                          && trace(deadlineConfiguration).filter { $0 == "auth.cancel" }.isEmpty,
                          "Deadline performs exactly one final live status read, not another flow or cancellation")
                } else {
                    try await wait { deadlineSession.currentCredentialState == .credentialPresent }
                    check(!deadlineSession.signInPending && deadlineSession.accountStatusCurrent
                          && deadlineSession.authentication?.flow?.state == .completed,
                          "Final deadline read accepts a real completion instead of leaving the old pending snapshot")
                }
                await deadlineSession.disconnect()
                try cleanLifecycle(deadlineConfiguration)
            }

            let unavailable = session("transientauth")
            await unavailable.connect()
            await unavailable.refreshAccount()
            await unavailable.beginSignIn()
            try await wait { unavailable.accountStatusError == .credentialStoreUnavailable
                && !unavailable.accountBusy && unavailable.signInPending }
            check(!unavailable.canSignIn && !unavailable.canDisconnectAccount,
                  "Transient inaccessible store never permits deletion or new sign-in")
            check(unavailable.accountLabel == "Sign-in status needs checking"
                  && unavailable.currentCredentialState == nil && unavailable.signInPending
                  && unavailable.accountExplanation.contains("current outcome could not be confirmed")
                  && unavailable.accountLibraryTitle == unavailable.accountLabel,
                  "Unconfirmed pending flow remains cancellation-fenced and displays an unknown outcome")
            await unavailable.refreshAccount()
            try await wait { unavailable.authentication?.flow?.state == .completed }
            check(unavailable.isReady && unavailable.authentication?.state == .credentialPresent,
                  "Explicit status reconciles after denied Keychain access without automatically repeating a prompt")
            await unavailable.disconnect()

            let committing = session("latecancel")
            await committing.connect()
            await committing.refreshAccount()
            await committing.beginSignIn()
            await committing.refreshAccount()
            check(committing.signInPending, "Safe status remains usable while a sign-in is pending")
            await committing.cancelSignIn()
            check(committing.signInPending && committing.authentication?.flow?.state != .cancelled,
                  "Rejected commit cancellation never reports false cancellation")
            try await wait { committing.authentication?.flow?.state == .completed }
            check(committing.authentication?.state == .credentialPresent && committing.isReady,
                  "Late INVALID_TRANSITION cancellation resumes reconciliation to completion")
            await committing.disconnect()

            let discovery = session("discoveryrecover")
            await discovery.connect()
            await discovery.refreshCatalog("")
            let failedIDs = Set(discovery.discoveryFailures.map(\.id))
            check(discovery.products.isEmpty && !failedIDs.isEmpty && discovery.canLoadMoreCatalog
                  && discovery.catalogError != nil,
                  "All-failure initial page exposes valid continuation without hiding failures")
            await discovery.refreshCatalog("", more: true)
            check(!discovery.products.isEmpty && Set(discovery.discoveryFailures.map(\.id)) == failedIDs
                  && discovery.products.flatMap(\.editions).allSatisfy { $0.entitlement.kind == .unknown },
                  "Successful continuation retains earlier failures without ownership promotion")
            await discovery.disconnect()

            let hundreds = session("discoveryhundreds")
            await hundreds.connect()
            await hundreds.loadGamePassCatalog()
            check(hundreds.gamePassProducts.count == 300
                  && hundreds.gamePassProductIDs.count == 300
                  && hundreds.nextCursor == nil && !hundreds.gamePassCatalogHasMore
                  && hundreds.gamePassCatalogExhausted && !hundreds.gamePassCatalogPaging
                  && hundreds.catalogError == nil,
                  "Game Pass selection follows every existing continuation page to hundreds of unique PC games")
            let retainedIDs = hundreds.products.map(\.id)
            await hundreds.loadCatalogOnEntry("")
            check(hundreds.products.map(\.id) == retainedIDs && hundreds.products.count == 300,
                  "Revisiting Discover retains the entire paged catalogue")
            let catalogueRows = LibraryGame.gamePassCatalog(installed: [], owned: [],
                                                            products: hundreds.gamePassProducts)
            check(catalogueRows.count == 300 && catalogueRows.allSatisfy { !$0.owned && $0.gamePass }
                  && LibraryGame.collection(installed: [], owned: [], products: [],
                    gamePass: hundreds.gamePassProducts, active: true).isEmpty,
                  "Full Game Pass browsing does not invent ownership or promote unresolved grants into personal access")
            await hundreds.loadGamePassCatalog()
            check(hundreds.gamePassProducts.count == 300 && !hundreds.gamePassCatalogPaging,
                  "Completed Game Pass paging is reused without render-triggered reload or duplicate games")
            await hundreds.disconnect()
            check(!hundreds.gamePassCatalogPaging && !hundreds.gamePassCatalogHasMore
                  && !hundreds.gamePassCatalogExhausted && hundreds.gamePassProducts.isEmpty,
                  "Disconnect retires the full catalogue scope and paging state")

            let repeatedPage = session("discoveryrepeatedpage")
            await repeatedPage.connect()
            await repeatedPage.loadGamePassCatalog()
            check(repeatedPage.gamePassProducts.count == 16
                  && repeatedPage.gamePassCatalogError != nil && !repeatedPage.gamePassCatalogPaging,
                  "Repeated catalogue cursors stop with explicit partial coverage instead of looping or duplicating games")
            await repeatedPage.disconnect()

            let boundedConfiguration = configuration("discoverybounded")
            let boundedCatalogue = LiveSession(configuration: boundedConfiguration)
            await boundedCatalogue.connect()
            await boundedCatalogue.loadGamePassCatalog()
            check(boundedCatalogue.gamePassProducts.count == 512
                  && boundedCatalogue.nextCursor != nil && !boundedCatalogue.gamePassCatalogHasMore
                  && boundedCatalogue.gamePassCatalogError?.contains("limit") == true,
                  "Catalogue limit preserves partial coverage and stops offering an impossible Load remaining action")
            let readsAtLimit = try trace(boundedConfiguration).filter { $0 == "catalog.discover" }.count
            await boundedCatalogue.loadGamePassCatalog()
            check(try trace(boundedConfiguration).filter { $0 == "catalog.discover" }.count == readsAtLimit,
                  "Repeated requests at the catalogue bound make no additional producer calls")
            await boundedCatalogue.disconnect()
            try cleanLifecycle(boundedConfiguration)

            let partialFeed = session("discoveryrefresh")
            await partialFeed.connect()
            await partialFeed.refreshCatalog("")
            let retainedFeedIDs = partialFeed.gamePassProductIDs
            check(!retainedFeedIDs.isEmpty && partialFeed.gamePassCatalogError == nil,
                  "SDD-LIB-06: partial PC discovery records remain metadata, not a personal access grant")
            await partialFeed.refreshCatalog("")
            check(partialFeed.gamePassProductIDs == retainedFeedIDs
                  && Set(partialFeed.gamePassProducts.map(\.id)) == retainedFeedIDs
                  && partialFeed.gamePassCatalogError != nil
                  && partialFeed.gamePassLibraryNotice.contains("retained")
                  && !partialFeed.gamePassCatalogLoading,
                  "SDD-LIB-06: all-failure partial refresh retains bounded catalog records with explicit stale/error state")
            await partialFeed.disconnect()
            check(partialFeed.gamePassProductIDs.isEmpty && partialFeed.gamePassProducts.isEmpty
                  && partialFeed.gamePassCatalogError == nil && !partialFeed.gamePassCatalogLoading,
                  "SDD-LIB-06: disconnect retires prior catalog scope and transient refresh state")

            let feed = session("discoverypcflag")
            await feed.connect()
            await feed.refreshCatalog("")
            let feedIDs = Set(feed.products.map(\.id))
            check(!feedIDs.isEmpty && feed.catalogError == nil
                  && feed.products.allSatisfy { !$0.pcCatalogCandidate }
                  && feed.gamePassProductIDs.isEmpty && feed.gamePassProducts.isEmpty,
                  "SDD-LIB-03: public discovery may retain console candidates but the PC Game Pass shelf excludes them")
            await feed.refreshCatalog("neutral")
            check(feed.gamePassProductIDs.isEmpty && feed.gamePassProducts.isEmpty
                  && feed.catalogCorpus == "publicMicrosoftStoreSearch"
                  && feed.catalogError == nil,
                  "B2: Searching Store preserves loaded Game Pass IDs without promoting failures or ownership")
            feed.market = "GB"
            check(feed.gamePassProductIDs.isEmpty && feed.gamePassProducts.isEmpty,
                  "B2/B5: Market/language scope changes clear Game Pass IDs and shelf products")
            await feed.disconnect()
            check(feed.gamePassProductIDs.isEmpty && feed.gamePassProducts.isEmpty,
                  "B2/B5: Disconnection discards the in-memory feed and shelf evidence")

            let publicCatalog = session("publiccapture")
            await publicCatalog.connect()
            await publicCatalog.refreshCatalog("Halo")
            check(publicCatalog.products.count == 1 && publicCatalog.products.first?.title == "Halo Infinite"
                  && publicCatalog.discoveryFailures.count == 4
                  && publicCatalog.catalogNotice == "Some results couldn't be checked.",
                  "Partial public metadata has one concise notice and keeps the checked real product")
            check(publicCatalog.authentication == nil && !publicCatalog.accountStatusCurrent
                  && publicCatalog.products.flatMap(\.editions).allSatisfy { $0.entitlement.kind == .unknown },
                  "Browsing and presenting games performs no credential read or ownership promotion")
            guard let product = publicCatalog.products.first,
                  let edition = product.editions.first else {
                throw ManagementError.invalidPayload
            }
            check(edition.installation.kind == "notInstalled"
                  && publicCatalog.libraryTitle == "Your PC library isn't available yet"
                  && publicCatalog.installedSnapshot?.installations.isEmpty == true,
                  "Catalog notInstalled and a constant-empty response never become a Mac inventory claim")
            check(publicCatalog.productSummary(product) ==
                  "Catalog metadata doesn't verify access or Mac compatibility. Use Library or Discover for Install and Play.",
                  "Multi-edition public detail separates catalog evidence from eligible Library and Discover actions")
            NativeUIChecks.checkLiveLayouts(session: publicCatalog, check: check)
            await publicCatalog.disconnect()

            let localEmpty = session("registryempty")
            await localEmpty.connect()
            check(localEmpty.installedSnapshot?.installations.isEmpty == true
                  && localEmpty.libraryTitle == "Your PC library isn't available yet"
                  && localEmpty.libraryMessage == "Xodus can't yet verify which PC games you own.",
                  "A constant-empty registry response never advertises an implemented registry or an empty Mac")
            await localEmpty.disconnect()
            let localUnavailable = session("registryunavailable")
            await localUnavailable.connect()
            check(localUnavailable.installedSnapshot == nil && localUnavailable.installedError != nil
                  && localUnavailable.libraryTitle == "Your PC library isn't available yet",
                  "An unavailable registry response never changes the real unsupported-library boundary")
            await localUnavailable.disconnect()

            let failureConfiguration = configuration("uifailures")
            let visibleFailures = LiveSession(configuration: failureConfiguration)
            await visibleFailures.connect()
            await visibleFailures.refreshAccount()
            await visibleFailures.refreshCatalog("Synthetic query")
            let catalogFailure = visibleFailures.catalogError
            check(catalogFailure != nil && visibleFailures.accountError == nil
                  && visibleFailures.accountMessage == "Your game library isn't available yet."
                  && visibleFailures.catalogNotice == "Games couldn't be loaded. Choose Refresh to try again.",
                  "A catalog failure has visible catalog recovery and never contaminates Account")
            await visibleFailures.refreshAccount()
            check(visibleFailures.accountError != nil && !visibleFailures.accountStatusCurrent
                  && visibleFailures.authentication?.state == .credentialPresent
                  && visibleFailures.currentCredentialState == nil
                  && visibleFailures.accountStatusError == .credentialStoreUnavailable
                  && visibleFailures.accountMessage.contains("cannot access Keychain")
                  && visibleFailures.accountMessage.contains("choose Check status.")
                  && !visibleFailures.canSignIn && !visibleFailures.canDisconnectAccount,
                  "Blocked Account read names Keychain access and Check status while retaining only an unconfirmed saved snapshot")
            await visibleFailures.refreshAccount()
            check(visibleFailures.accountError == nil && visibleFailures.currentCredentialState == .credentialPresent
                  && visibleFailures.catalogError == catalogFailure,
                  "Account recovery restores only credential evidence and never erases a catalog failure")
            await visibleFailures.signOut()
            check(visibleFailures.authentication?.state == .credentialPresent
                  && !visibleFailures.accountStatusCurrent && visibleFailures.currentCredentialState == nil
                  && !visibleFailures.canSignIn && !visibleFailures.canDisconnectAccount
                  && visibleFailures.accountMessage == "Sign-out couldn't be confirmed. Check status before trying again.",
                  "Failed logout preserves the previous snapshot but never presents signed-out or current-saved success")
            await visibleFailures.refreshAccount()
            await visibleFailures.refreshActivity()
            check(visibleFailures.activityError != nil && visibleFailures.activity.needsSnapshot
                  && !visibleFailures.activity.isReconciling && visibleFailures.activityNotice != nil
                  && visibleFailures.accountError == nil && visibleFailures.currentCredentialState == .credentialPresent,
                  "Failed activity refresh exposes its retry and does not become an account failure or stranded spinner")
            await visibleFailures.refreshActivity()
            check(visibleFailures.activityError == nil && visibleFailures.activityNotice == nil
                  && !visibleFailures.activity.needsSnapshot,
                  "An explicit successful activity refresh clears only its own failure")
            let previousSnapshot = visibleFailures.installedSnapshot
            await visibleFailures.refreshInstalled()
            check(visibleFailures.installedSnapshot == previousSnapshot && !visibleFailures.installedSnapshotCurrent
                  && visibleFailures.installedError != nil
                  && visibleFailures.libraryTitle == "Your PC library isn't available yet",
                  "Failed registry refresh retains a stale wire snapshot without claiming installation or a populated registry")
            check(try trace(failureConfiguration).filter { $0.hasPrefix("auth.") } ==
                  ["auth.status", "auth.status", "auth.status", "auth.logout", "auth.status"],
                  "Error presentation adds no automatic auth read, sign-in, verification or logout retry")
            check(await visibleFailures.disconnect(), "Visible-error regression retires its owned neutral child")
            try cleanLifecycle(failureConfiguration)

            let empty = session("queryempty")
            await empty.connect()
            await empty.refreshCatalog("XodusNoMatch9F4A12C7")
            check(empty.isReady && empty.products.isEmpty && empty.discoveryFailures.isEmpty
                  && empty.catalogError == nil && empty.catalogCorpus == "publicMicrosoftStoreSearch"
                  && empty.nextCursor == nil && empty.discoveryCheckedAt != nil,
                  "Genuine empty query remains live, scoped and distinct from all-failure pages")
            check(empty.catalogEmptyTitle == "No Store matches"
                  && empty.catalogEmptyExplanation(query: "No match", canRefresh: true).contains("no matching games"),
                  "Only a confirmed zero-result Store response displays the no-match message")
            await empty.refreshAccount()
            check(empty.isReady && empty.accountStatusCurrent,
                  "Native status reconciliation still works after a genuine empty query")
            await empty.disconnect()

            let stopped = session("queryslow")
            await stopped.connect()
            let late = Task { await stopped.refreshCatalog("XodusNoMatch9F4A12C7") }
            try await wait { stopped.searching }
            check(stopped.products.isEmpty && stopped.catalogEmptyTitle == "Finding games"
                  && stopped.discoveryCheckedAt == nil
                  && stopped.catalogEmptyExplanation(query: "Pending", canRefresh: true).contains("not available yet")
                  && !stopped.catalogEmptyExplanation(query: "Pending", canRefresh: true).contains("no matching"),
                  "Pending empty catalog shows loading, never a premature no-match result")
            stopped.stopCatalogSearch()
            await late.value
            check(stopped.isReady && stopped.catalogStopped && stopped.discoveryCheckedAt == nil,
                  "Stopped search discards later bounded results without pretending HTTP was cancelled")
            check(stopped.catalogEmptyTitle == "Search stopped"
                  && stopped.catalogEmptyExplanation(query: "Stopped", canRefresh: true).contains("new search"),
                  "Cancelled catalog UI remains distinct from a confirmed empty result")
            await stopped.disconnect()

            let startupConfiguration = configuration("startupquery")
            let startup = LiveSession(configuration: startupConfiguration)
            for attempt in 1...2 {
                let connecting = Task { await startup.connect() }
                try await wait { startup.isReady }
                await startup.refreshCatalog("Latest startup query \(attempt)")
                let products = startup.products, cursor = startup.nextCursor
                await connecting.value
                check(startup.products == products && startup.products.first?.title == "Latest startup query \(attempt)"
                      && startup.catalogCorpus == "publicMicrosoftStoreSearch" && startup.nextCursor == cursor,
                      "Post-ready user query survives delayed startup reconciliation and reconnect")
                check(await startup.disconnect(), "Startup query regression retires its owned neutral child")
            }
            check(try !trace(startupConfiguration).contains("catalog.search"),
                  "Superseded startup never seeds an empty cache search over the user's Store query")
            try cleanLifecycle(startupConfiguration)

            let sourceFailure = session("querynodetails")
            await sourceFailure.connect()
            await sourceFailure.refreshCatalog("Original source query")
            check(sourceFailure.isReady && sourceFailure.catalogError != nil,
                  "Source-level PACKAGE_UNAVAILABLE without batch details is a recoverable catalog error")
            try await sourceFailure.reconcileActivity()
            check(sourceFailure.isReady && !sourceFailure.activity.needsSnapshot,
                  "Native snapshot still succeeds on the same connection after a source-level query error")
            await sourceFailure.disconnect()

            let coalesced = session("querycoalesce")
            await coalesced.connect()
            var edits: [Task<Void, Never>] = []
            for index in 1...5 {
                if index == 5 { coalesced.market = "FR"; coalesced.language = "fr-FR" }
                edits.last?.cancel()
                edits.append(Task { await coalesced.refreshCatalog("Original query \(index)") })
                if index < 5 { try await Task.sleep(for: .milliseconds(300)) }
            }
            for edit in edits { await edit.value }
            check(coalesced.isReady && coalesced.catalogError == nil
                  && coalesced.products.first?.title == "Original query 5 [requests=2,max=1]",
                  "Five delayed edits issue only one in-flight and one latest query, never producer capacity failure")
            check(coalesced.products.first?.market == "FR" && coalesced.products.first?.language == "fr-FR",
                  "Latest queued query retains its captured market/language instead of old request scope")
            await coalesced.disconnect()

            let dropped = session("querycoalesce")
            await dropped.connect()
            let active = Task { await dropped.refreshCatalog("Active original query") }
            try await wait { dropped.searching }
            let queued = Task { await dropped.refreshCatalog("Queued original query") }
            try await Task.sleep(for: .milliseconds(300))
            dropped.stopCatalogSearch()
            await active.value
            await queued.value
            check(dropped.catalogStopped && dropped.discoveryCheckedAt == nil,
                  "Stop clears the queued latest request while fencing the active bounded result")
            await dropped.refreshCatalog("After stopped queue")
            check(dropped.products.first?.title == "After stopped queue [requests=2,max=1]",
                  "A stopped queued query was never sent; the next explicit search remains usable")
            check(await dropped.disconnect(), "Stopped-query worker releases its owned process without an unbounded wait")
            for _ in 0..<3 {
                await dropped.connect()
                await dropped.refreshCatalog("Reconnected original query")
                let ready = dropped.isReady
                let closed = await dropped.disconnect()
                check(ready && closed,
                      "Repeated catalog-worker reconnect waits for owned-child exit and stays usable")
            }

            let selected = URL(fileURLWithPath: "/synthetic/selected/game")
            let inspected = session("inspection")
            await inspected.connect()
            await inspected.inspectInstallation(at: selected)
            check(inspected.inspection?.directory == selected.path
                  && inspected.inspection?.assessment.registered == false
                  && inspected.inspection?.assessment.launchable == false
                  && inspected.installedSnapshot == nil,
                  "Selected-folder inspection remains separate from registry, entitlement and launch")
            await inspected.disconnect()
            check(inspected.inspection == nil, "Inspection evidence clears when its engine disconnects")

            for scenario in ["inspectionmissing", "inspectionmismatch"] {
                let rejected = session(scenario)
                await rejected.connect()
                await rejected.inspectInstallation(at: selected)
                check(rejected.inspection == nil && rejected.inspectionError != nil,
                      "Missing or differently scoped inspection is an explicit error, never empty installed success")
                await rejected.disconnect()
            }

            let slowConfiguration = configuration("retireslow")
            let retiring = LiveSession(configuration: slowConfiguration)
            await retiring.connect()
            var firstFinished = false, secondFinished = false, fixtureAllowed = false, quitAllowed = false
            let firstClose = Task { let result = await retiring.disconnect(); firstFinished = true; return result }
            try await wait { retiring.phase == .disconnecting }
            let secondClose = Task { let result = await retiring.disconnect(); secondFinished = true; return result }
            let fixtureClose = Task { let result = await retiring.disconnect(); fixtureAllowed = result; return result }
            let quitClose = Task { let result = await retiring.disconnect(); quitAllowed = result; return result }
            let overlappingReconnect = Task { await retiring.connect() }
            try await Task.sleep(for: .milliseconds(150))
            let heldTrace = try trace(slowConfiguration)
            check(!firstFinished && !secondFinished && !fixtureAllowed && !quitAllowed
                  && retiring.connectionTransitioning && heldTrace.contains("stdin.closed") && !heldTrace.contains("exiting"),
                  "Actual child held after stdin EOF prevents early disconnect, fixture or quit success")
            await overlappingReconnect.value
            check(try trace(slowConfiguration).filter { $0 == "started" }.count == 1,
                  "Reconnect during shared retirement cannot start a second engine")
            let sharedResults = await [firstClose.value, secondClose.value, fixtureClose.value, quitClose.value]
            check(sharedResults.allSatisfy { $0 } && !retiring.connectionTransitioning,
                  "All overlapping disconnect callers observe the same completed child exit")
            await retiring.connect()
            let reconnectA = Task { await retiring.connect() }
            try await wait { retiring.phase == .disconnecting }
            let reconnectB = Task { await retiring.connect() }
            await reconnectA.value
            await reconnectB.value
            check(try retiring.isReady && trace(slowConfiguration).filter { $0 == "started" }.count == 3,
                  "Overlapping complete reconnect transitions spawn exactly one replacement, not two post-close engines")
            let superseded = Task { await retiring.connect() }
            try await wait { retiring.phase == .disconnecting }
            let supersedingClose = Task { await retiring.disconnect() }
            await superseded.value
            let supersedingResult = await supersedingClose.value
            check(try supersedingResult && retiring.phase == .disconnected
                  && trace(slowConfiguration).filter { $0 == "started" }.count == 3,
                  "Disconnect supersedes an entire pending reconnect before its post-close spawn")
            try cleanLifecycle(slowConfiguration)

            let failedConfiguration = configuration("retirefailed")
            let observer = ShutdownCheckObserver()
            let unobserved = LiveSession(configuration: failedConfiguration,
                                        shutdownClient: { await observer.close($0) })
            await unobserved.connect()
            let failedA = Task { await unobserved.disconnect() }
            try await wait { unobserved.phase == .disconnecting }
            let failedB = Task { await unobserved.disconnect() }
            let failedFixture = Task { await unobserved.disconnect() }
            let quitRuntime = RuntimeProviderSettings()
            let quitCoordinator = ApplicationTerminationCoordinator()
            let failedQuit = Task { await quitCoordinator.shutdown(session: unobserved, runtime: quitRuntime) }
            await unobserved.connect()
            try await wait { unobserved.retiringDisconnectWaiterCount == 4 }
            await observer.beginShortObservation()
            let failedResults = await [failedA.value, failedB.value, failedFixture.value, failedQuit.value]
            let observedAttempts = await observer.attempts
            try await waitForTrace("retirement.held", failedConfiguration)
            check(failedResults.allSatisfy { !$0 },
                  "Actual short observation failure blocks every admitted disconnect, fixture and Quit caller")
            check(observedAttempts == 1,
                  "All four admitted callers share exactly one actual short exit observation")
            check(unobserved.phase == .failed && unobserved.errorMessage != nil,
                  "A failed actual exit observation retains an actionable failed lifecycle state")
            check(try !trace(failedConfiguration).contains("exiting"),
                  "The actual neutral child remains held until explicit release, not an arbitrary sleep")
            check(!quitRuntime.applicationTerminating && !unobserved.applicationTerminating,
                  "Refused normal termination restores interactions only after both cleanup attempts finish")
            await unobserved.connect()
            check(try !unobserved.isReady && trace(failedConfiguration).filter { $0 == "started" }.count == 1,
                  "A retry cannot overwrite an unobserved retiring child with a new engine")
            try Data("Release only this owned neutral retirement child.\n".utf8)
                .write(to: failedConfiguration.stateDirectory.appendingPathComponent("retirement.release"))
            await observer.useDefaultBudget()
            check(await quitCoordinator.shutdown(session: unobserved, runtime: quitRuntime),
                  "Retry through the normal termination coordinator reconciles the retained child's eventual exit")
            unobserved.applicationTerminating = false
            await unobserved.connect()
            check(try unobserved.isReady && trace(failedConfiguration).filter { $0 == "started" }.count == 2,
                  "A new engine is allowed only after the retained child's exit is actually observed")
            check(await unobserved.disconnect(), "Recovered lifecycle test releases its last actual child")
            try cleanLifecycle(failedConfiguration)

            for scenario in ["retirehello", "retiresnapshot"] {
                let startupConfiguration = configuration(scenario)
                let starting = LiveSession(configuration: startupConfiguration)
                let startup = Task { await starting.connect() }
                try await waitForTrace(scenario == "retirehello" ? "hello.wait" : "snapshot.wait", startupConfiguration)
                let duplicate = Task { await starting.connect() }
                let interruption = Task { await starting.disconnect() }
                await duplicate.value
                let interrupted = await interruption.value
                await startup.value
                check(try interrupted && starting.phase == .disconnected && starting.hello == nil
                      && !starting.connectionTransitioning
                      && trace(startupConfiguration).filter { $0 == "started" }.count == 1,
                      "Disconnect fences suspended negotiation/snapshot continuations without stale startup or second spawn")
                await starting.connect()
                check(starting.isReady && !starting.connectionTransitioning,
                      "A fenced startup does not strand future explicit connection attempts")
                await starting.disconnect()
                try cleanLifecycle(startupConfiguration)
            }

            let diagnostics = session("diagnostics")
            await diagnostics.connect()
            let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("XodusDiagnosticChecks-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer {
                do { try FileManager.default.removeItem(at: exportRoot) }
                catch { check(false, "Owned synthetic diagnostic export cleanup failed") }
            }

            let output = exportRoot.appendingPathComponent("summary.txt")
            await diagnostics.saveDiagnosticSummary(to: output)
            check(diagnostics.diagnosticExportError != nil && !FileManager.default.fileExists(atPath: output.path),
                  "Diagnostic export requires a current reviewed preview and creates no unreviewed file")
            await diagnostics.previewDiagnostics()
            guard let reviewed = diagnostics.diagnosticPreview else { throw ManagementError.invalidPayload }
            await diagnostics.saveDiagnosticSummary(to: output)
            check(try String(contentsOf: output, encoding: .utf8) == reviewed && diagnostics.diagnosticSaved,
                  "Export saves exactly the reviewed counts-only summary, without raw backend data")
            await diagnostics.saveDiagnosticSummary(to: exportRoot.appendingPathComponent("missing/summary.txt"))
            check(diagnostics.diagnosticExportError != nil && !diagnostics.diagnosticSaved
                  && diagnostics.diagnosticPreview == reviewed,
                  "Filesystem export failure is visible, never success, and preserves the reviewed summary for retry")
            guard let remote = URL(string: "https://example.invalid/diagnostics") else { throw ManagementError.invalidPayload }
            await diagnostics.saveDiagnosticSummary(to: remote)
            check(diagnostics.diagnosticExportError != nil && !diagnostics.diagnosticSaved,
                  "Diagnostic export rejects nonlocal destinations without writing")
            await diagnostics.disconnect()
            await diagnostics.saveDiagnosticSummary(to: output)
            check(diagnostics.diagnosticExportError != nil && !diagnostics.diagnosticSaved,
                  "Disconnect invalidates diagnostic preview before another export")
        } catch {
            check(false, (error as? ManagementError)?.localizedDescription ?? "Native fixture regression did not complete.")
        }
        print("\(count) native session checks, \(failures) failures. Mock children only; no Keychain or Microsoft operation.")
        return failures == 0
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ManagementError.requestTimedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private actor ShutdownCheckObserver {
    private(set) var attempts = 0
    private var budget: Duration = .milliseconds(200)
    private var shortObservationReleased = false
    private var admission: CheckedContinuation<Void, Never>?

    func close(_ client: ManagementClient) async -> Bool {
        attempts += 1
        if !shortObservationReleased {
            await withCheckedContinuation { admission = $0 }
        }
        return await client.close(observationTimeout: budget)
    }

    func beginShortObservation() {
        shortObservationReleased = true
        admission?.resume()
        admission = nil
    }

    func useDefaultBudget() { budget = .seconds(6) }
}
