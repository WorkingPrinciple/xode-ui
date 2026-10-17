# X Ode stabilization issue ledger

Started: 2026-10-16. Product name: **X Ode**, an ode to X.
Repository: [dragoshont/xodus-macos-app](https://github.com/dragoshont/xodus-macos-app).
GitHub API verification on this date confirmed that it is private and not a fork.
It is the existing dedicated app/distribution repository; no replacement
repository is needed.

This ledger records actionable defects and launch blockers, not a new feature
backlog. User reports, reproduced behavior, source checks and live acceptance
remain distinct. A source fix is not closed until the affected behavior is
verified. Existing GitHub tickets remain authoritative for their wider scope.
Never include accounts, tokens, raw logs, private download URLs or player data.

## Active issues

| ID | Priority | Issue and evidence | Status / owner | Exit criterion |
| --- | --- | --- | --- | --- |
| XO-001 | P0 | First run exposes a cryptic setup/configuration state rather than guiding a gamer. User described "xcode not configured"; parent independently observed "Xodus needs setup", not the exact reported wording. | Source repair `8a6aa359df63a4b63f40cea00d7efb6fc58e8a29`; parent observed native welcome without developer paths. Controlled signed package subsequently restored the saved management sign-in and PC collection (XO-009); fresh interactive sign-in remains unqualified. Related: [#10](https://github.com/dragoshont/xodus-macos-app/issues/10), [#37](https://github.com/dragoshont/xodus-macos-app/issues/37). | Native X Ode welcome/sign-in sheet with only necessary setup actions; no developer paths or configuration controls in the first-run experience. Missing runtime is explained plainly, never hidden behind a fake successful login. |
| XO-002 | P0 | Installed game cards appear before login. User report; parent confirmed the unauthenticated development UI exposes its local Library. Local installation is not current-account access. | Source repair `8a6aa35`; parent verified no cards in the signed-out welcome, then real saved management credentials dismissed that gate. PC-library account binding is still unverified, not implied by that result. Related: [#19](https://github.com/dragoshont/xodus-macos-app/issues/19), [#37](https://github.com/dragoshont/xodus-macos-app/issues/37). | Unauthenticated startup shows no installed-game/library cards or game actions. Login, logout, expiry and account changes update the gate; local registrations and files are preserved. Cached data cannot dismiss the gate or imply entitlement. |
| XO-003 | P1 | The visible application still uses Xodus/XodusPreview in places instead of the owner's product name X Ode. Observed native menu/window names and user report. | Signed `fe895e46` has the actual native application-menu heading **X Ode**, independently read through Accessibility. Corrected `7ba19a55` has one X Ode menu plus Account (XO-017). Actual signed `784dedf5` welcome Quit/reopen verified; About interaction pending. The earlier raw executable's heading was XodusPreview. Related: [#17](https://github.com/dragoshont/xodus-macos-app/issues/17). | First-run, window and relevant user-facing shell copy say X Ode. Bundle, Keychain, signer and existing installation identities are not renamed casually. Brand meaning is an ode to X, not an official Xbox affiliation claim. |
| XO-004 | P0 | CrossOver prerequisite needs a gamer-facing action, not a developer setup instruction. User requests official trial download when it is not installed. | Source repair `8a6aa35`. Exact vendor URL and missing/detection states covered by synthetic checks; parent verified no unnecessary trial link with installed CrossOver 26.3. No clean-Mac acceptance claim. Related: [#10](https://github.com/dragoshont/xodus-macos-app/issues/10), [#30](https://github.com/dragoshont/xodus-macos-app/issues/30). | Detect an existing supported CrossOver without modifying it. If absent, offer the official CodeWeavers download page; recheck after installation. Detection is not license/trial validity or game qualification. No mirrored binary, silent install or purchase. |
| XO-005 | P0 | The recovered app has no verified management/backend pair. Exact management producer was recovered and built, but later working game-runtime source and installed-source mapping remain unresolved. | Partial recovery: coordinator. Related: [#18](https://github.com/dragoshont/xodus-macos-app/issues/18), [#28](https://github.com/dragoshont/xodus-macos-app/issues/28), [#34](https://github.com/dragoshont/xodus-macos-app/issues/34). | Explicitly selected source/artifact identities, complete build inputs and reviewed provenance; real protocol/startup acceptance without substituting the game runtime CLI for the management CLI. Do not overwrite the installed runtime to make source look current. |
| XO-006 | P1 | macOS 27 Command Line Tools cannot resolve the SDK's SwiftUI State macro in two engine settings properties. Reproduced; local property-wrapper disambiguation fixes the build. | Source repair verified: `646e95acd049355d3dd1711e77e196e6a54e3473`, retained in exact `784dedf5`. Coordinator independently checked the two-property delta; normal/shipping builds and the complete unchanged full-Xcode CI gate passed. No release or default-branch integration implied. | Resolved for this source/build defect. Retain the attributable fix in the selected candidate; other launch gates remain independent. |
| XO-007 | P0 for shipping | Full shipping test chain cannot import XCTest on this Command Line Tools-only machine. Source owner reproduced missing module; normal/release builds and other existing checks passed. | Resolved for exact `784dedf517845e0caf4cdedcd032444cddaa3d2a` by unchanged full-Xcode 27 CI run [39013367846](https://github.com/dragoshont/xodus-macos-app/actions/runs/39013367846): ShippingChecks XCTest and the full existing check chain passed. Parent independently confirmed run/head/job/steps. Local CLT limitation remains; no host changes or gate waiver. | Existing shipping XCTest gate passes unchanged in an appropriate selected Xcode environment. Manual flag/admission checks do not replace this gate. New source/integration commits require their own applicable CI evidence. |
| XO-008 | P0 for distribution | Component acquisition is not a qualified release channel. App and private backend repositories currently list no GitHub releases. Separate repositories do not grant redistribution rights. | Delivery design recorded; implementation deferred pending input/consent gates. Related: [#25](https://github.com/dragoshont/xodus-macos-app/issues/25), [#28](https://github.com/dragoshont/xodus-macos-app/issues/28), [#38](https://github.com/dragoshont/xodus-macos-app/issues/38). | Qualify the separately installed runtime, pinned manifest/assets, signatures/hashes, license notices, rollback and explicit install consent before implementing automatic acquisition. Public distribution requires the existing owner legal decision. |
| XO-009 | P0 | The raw development app could not use the intact installed PC-library broker: absent bundle pin manifest and unapproved raw caller identity. | Saved-session path verified in controlled signed `fe895e46`: real management sign-in dismissed welcome and the existing broker-backed PC collection populated 13 titles. No broker replacement, direct-Keychain fallback or token copying. Interactive sign-in and cross-service account binding are not implied. | Qualify the source-matched app/helper package and its broker manifest/caller identity, preserving the existing broker and credential stores. Read cached PC-library credentials through the approved broker, or enable the existing explicit sign-in flow. Never bypass caller verification or copy/export tokens. |
| XO-010 | P1 | The setup-only raw development instance did not exit after native normal-Quit attempts. Signed `7ba19a55` also remained running; AppKit logged "App termination blocked by modal sheet". | Source correction `784dedf517845e0caf4cdedcd032444cddaa3d2a` scopes the native policy change to mandatory welcome and restores it on removal. Actual signed candidate showed its startup-sized sheet with the namespace occupied, accepted normal Quit and exited; reopened as a new PID and exited normally again. No force, unlock or operation-hold bypass. Old raw/previous candidate retirement remains separate. | Permit normal Quit from mandatory welcome to reach existing safe termination handling, without dismissing authentication or bypassing mutation holds. Verify real signed-package exit/reopen and retire the idle development instance safely. |
| XO-011 | P1 | Discover starts direct installation without presenting preparation, cancellation or failure on its initiating surface. Source-derived adversarial finding F1 at `LiveCatalogView.swift:103-164,355-378`. | Source correction `fe895e46`; existing operation feedback is now mounted on Discover. Native transfer/failure verification pending. | Reuse existing operation presentation or hand off to Downloads; package, storage and authentication failures remain visible. |
| XO-012 | P1 | Management reauthentication can lock the main content while an installation continues, hiding cancellation even when Quit refuses an active operation. Source-derived F2 at `LiveRootView.swift:190-221`. | Source correction `fe895e46`; privacy-restricted operation controls in locked Welcome/Settings, cancellation holds retained. Live reauthentication during mutation pending. | Keep browsing locked while exposing minimal existing-operation status and cancellation; retain holds until cancellation settles. |
| XO-013 | P1 | PC-library presence restoration latches after transient failure; Refresh skips when saved sign-in is unknown, preventing an effective retry. Source-derived F3 at `PCGamesController.swift:42-69`. | Source correction `fe895e46`; atomic presence restoration and explicit retry through the same admitted store. Actual saved-session pairing now works (XO-009); live transient-broker-failure recovery remains unqualified. | Explicit retry repeats the admitted broker presence check; distinguish unavailable pairing from absent credentials without token copying or fallback access. |
| XO-014 | P1 | Game detail calls a registered installation "Ready to play" without validating package, launcher or runner. Source-derived F4 at `LiveProductView.swift:5-8,174-175`. | Source correction `fe895e46`; actual newly installed Minecraft Java detail says "Installed on this Mac". Its configured executable is a placeholder stub; installation is not gameplay acceptance. | Registration alone says "Installed on this Mac"; readiness and failure reasons depend on actual checks. |
| XO-015 | P1 | Foreground refresh does not revalidate the management credential gate, so external expiry/revocation can leave cached confirmation admitting content. Source-derived F5 at `LiveRootView.swift:160-176,228-234`. | Source correction `fe895e46`; bounded foreground status read with existing serialization/failure gate. Real expiry verification pending. | Bounded foreground revalidation preserves confirmed UI while checking and relocks after failed/expired status; no polling or merged identities. |
| XO-016 | P1 | Welcome labels a startup/connection failure as a missing matching app/sign-in service. Parent observed this in a correctly signed/pinned package while an older raw CLI held the management namespace lock; closing that old copy normally and pressing Try again admitted the unchanged package and restored the collection. The exact received error frame was not captured. | Source correction `7ba19a5529764d41ef577ff1e584ac363dafd84e`, independently inspected and privately packaged/signed; native failure-copy acceptance blocked by macOS screen lock. No pairing bypass, inferred error frame or lock removal. | Distinguish missing/invalid pairing from a subsequent connection failure; plain retry/close-other-copy guidance, unchanged fail-closed readiness and current-status gates. |
| XO-017 | P2 | Actual signed menu headings included both the native application menu X Ode and a second X Ode command menu containing account destinations. | Source correction `7ba19a55` privately packaged/signed. Read-only Accessibility on that exact running bundle now reports Apple / X Ode / File / Edit / View / Navigate / Account / Window / Help. Corrected native headings verified; action/shortcut interactions still require unlocked console. | One unambiguous native X Ode application menu; account destinations remain reachable and correctly gated. |
| XO-018 | P1 | Account says "Signed in for games" while Profile/My Consoles cannot confirm the account. The normal service-local binding file is absent. Source allows signed-in status without an account hash, correctly refuses unbound companion/stats data, but hides the sign-in action in that state; Check status only rereads the absent binding. | Live recovery verified on 2026-10-17 in signed `784dedf5`, including source correction `8072c42a5b897f9bf669be7a7ea7f2e1e78a8e31`: explicit Verify game account changed the partial state to Signed in for games; Profile rendered account data, Achievements populated and My Consoles returned an explicit empty state. Existing saved-session action only; no logout, account joining, cache fabrication, token copying or runtime replacement. Fresh interactive sign-in/MFA remains separate. | Expose truthful partial-state copy and an explicit admitted verification/retry route using the saved game-service session where available. Keep profile-cache ownership checks and existing playable-game eligibility intact; native provider/consent acceptance remains separate. |
| XO-019 | P2 operational recovery | Externally cancelling the first Minecraft runtime parent left a detached placeholder process and a per-run HFS RAM volume. This is not a reproduced native X Ode Stop failure: a second attempt through the actual bottle-scoped Stop backend ended its game process and returned a product-bound receipt. | Recovered: exact game PID quit normally; known empty run RAM image was unmounted with ordinary owner-level BSD unmount and normally ejected after Image/Disk Utility attempts failed. Its empty mount directory was removed. Original game files, bottle and saves preserved; no game process remains. Details in the game ledger. | Resource recovery verified for this attempt. Preserve the distinction between external parent cancellation and native Stop; do not infer full process/resource settlement from a parent exit code alone. |
| XO-020 | P1 backend failure handling | Installed `private-xodus-manage.py:553-574` ignores both vendor Stop subprocess return codes, then returns 0 with `stopped=true`. An isolated unchanged-function test with both commands returning 7 reproduced that false result without executing Wine/helpers or touching accounts/files. The separate real Minecraft Stop succeeded; no live vendor-failure reproduction is claimed. | Local recovered-source repair candidate `cb86a8077c9509ea03e19a3762da21702002bc05` verified offline: 13 regressions, baseline four failures versus candidate zero. Not installed or matched to historical backend Git. The registered private backend project still has a public-fork origin, and its five current remote heads lack this helper. Installed script/runtime remain untouched. Exact input SHA-256 `e6efb8488db9d68a6c69db8791b1b817427b9344d92ed0fc0afaae84c317578c`; candidate details below. | Source candidate rejects final vendor failure without a success result and preserves graceful-first/title-only scope. Qualify and integrate the explicitly recovered component in the correctly mapped private source repository before deployment; native failure/retry and wider runtime provenance remain separate holds. |

## Freeze rules

- Fix the issues above before expanding package, engine, social or multiplayer
  support. The owner explicitly prioritized first-run onboarding as a repair to
  the existing gamer experience, not an invitation to redesign the whole app.
- Do not remove player files, registrations or saves to hide an onboarding bug.
- Do not ask for GitHub credentials as part of gamer onboarding. Microsoft
  sign-in and separately licensed CrossOver are the requested entry points.
- Do not infer current-account entitlement from a local install, public catalog,
  saved profile or stale authentication flag.
- Keep source-only checks, visible UI behavior, real account acceptance,
  reference-title gameplay and distribution approval separate in each update.

## Recovery evidence

The opened development copy was based on foundation
`00cff3d624ee4ce40c308128eccd3e9d213e0433` plus the SwiftUI compatibility
change. It passed 179 existing self-checks and displayed a native window; those
checks explicitly used no backend connection. Native Library/Discover/Downloads
navigation responded, but this did not qualify onboarding, sign-in or gameplay.

The management producer `c1073100ce8936a751b962b1401ddb641c8be38a`, tree
`7a808c0e6a8a909455d07eb463379ab55bdf138c`, was recovered from private archived
Git bundles. All 205 source-input hashes matched the archived manifest. A locked,
offline release build succeeded; 111 existing management tests passed. This is
newly built management software, not the historical signed binary, the installed
game runtime, provenance clearance or a released app/backend pair.

The rebuilt management executable has SHA-256
`9e69204a17aedeb5d5263adc33662842a873cacbff51537b76bec5a77cac991c`
and size 22,115,424 bytes. Existing contract fixtures passed: 100 positive, 96
negative, six failed-page, six failed-query and four evidence-edge fixtures,
preserving nine foundation definitions. A real subprocess answered one `hello`
request with a schema-valid response and no stderr in disposable session state.
No account, game or install command was sent. Its advertised game-launch and
install-plan capabilities are unsupported; this is not an interchangeable
replacement for the installed game runtime. The receipt is saved in coordinator
session files as `management-c1073100-validation.json`.

Component delivery boundaries and the frozen launch criteria are in
[launch readiness](LAUNCH-READINESS.md#component-delivery-boundaries).

The subsequent exact target-native management build completed with the
packaging-required one-job profile. Actual Cargo compiler records, post-build
native dependency metadata and all 205 source inputs were checked. Its sealed
unsigned input is SHA-256
`af40ecd5d77444eb35586a9ce34bd045acf1df5079ee7244bc142d856f93f1c5`,
22,122,624 bytes; its 2,383-byte provenance sidecar is SHA-256
`f9e086f916051415e3fc9088048f0cf23606c4345f4f3e3ce6ca676c778899f4`.
The existing input verifier admitted it. The subsequent controlled signed pair
below is separately observed; this input receipt itself is not PC-library
sign-in, a game-runtime replacement or distribution attestation.

## Adversarial window audit

The independent read-only review of frozen `8a6aa35` returned **REVISE**:
XO-011 through XO-015 plus existing packaging, Quit and shipping-test blockers.
All five new defects are source-derived, not live reproductions. One bounded
correction batch was committed as
`fe895e466cb0c4548fbb85da339facde61dbbccb`, tree
`9f9907c3adcfff31f018b04bad0f9cf2093fe070`. The coordinator independently
inspected its control-flow, privacy redaction and presentation wiring.
Focused source checks passed; they remain synthetic. The controlled local
signed-pair build completed using this clean frozen source and the sealed
native management input above, with the unchanged installed broker manifest.
Independent deep/strict signature verification passed. The generated receipt
qualifies only a controlled local operator-approved pair, not distribution.
No broker installation, runtime replacement or release was performed.

| Native surface | Evidence so far |
| --- | --- |
| Main window; Library, Discover and Downloads navigation | Signed `784dedf5` restored the saved management session and collection. All three native destinations reached; idle Downloads Browse games handed off to Discover. |
| Welcome; retry, reconnect, cancel and CrossOver handoff | Source reviewed; locked welcome observed. Real interactive sign-in pending. |
| Game detail and media sheet | Subnautica and Minecraft Java detail opened natively; package, size and install actions observed. Signed `784dedf5` also opened Abiotic Factor detail and its trailer sheet, then Close trailer returned to detail. Decoded video/audio not independently qualified. |
| Direct install progress, recovery and queue controls | Native Subnautica preflight refusal and Minecraft Java installation success/notice observed. Sustained transfer, cancellation/recovery and queue controls remain unqualified. |
| Account; management, PC-library and game-service account groups | Native Account opened using Microsoft sign-in saved. Explicit Verify game account resolved the saved unbound game-service state in signed `784dedf5` (XO-018). Subscription identity remains separate and unverified. |
| Profile, Achievements and title drill-down | Signed `784dedf5` rendered Profile data and populated the Achievements game list after explicit verification. A title drill-down and All games/Back to Account routes worked. Complete achievement-detail content/provider freshness not independently qualified. No account identifiers or player history retained in this ledger. |
| My Consoles and browser Remote Play handoff | Signed `784dedf5` reached My Consoles and displayed No consoles returned after verification, rather than the earlier unconfirmed-account state. Back to Account worked. Browser Remote Play handoff not exercised. |
| Engines and default/experimental routing | Native Engines opened; official CrossOver 26.3 detection and configuration-only distinctions observed. No settings changed; not gameplay qualification. |
| Settings; connection, artwork and advanced catalog | Signed `784dedf5` native Settings shortcut opened the real window with connection, runtime/account, catalog and diagnostic controls. Signed in for games observed. Window closed normally; no settings/connection/artwork mutations tested. |
| Diagnostics preview, export and destination picker | Redacted preview and native reviewed-summary Save panel reached. AX activation timed out while the native modal panel remained open; observed Cancel/Save before cancelling successfully. No action replay, file saved or raw diagnostics exported. |
| PC-library device-code and Keychain consent sheet | Source reviewed; broker-approved packaged interaction pending. |
| Repair/install review and destructive uninstall sheet | Source reviewed; mutation/cancellation not exercised. No player files removed. |
| Import game-folder/script and inspection pickers | Signed `784dedf5` opened the native import picker and Cancel returned normally. No folder selected or registration changed. Subsequent script/inspection selection remains unqualified. |
| Microsoft helper window and close/cancel lifecycle | Source reviewed; real provider/MFA flow pending. |
| About, native app/File/Navigate menus, Settings and Quit | Signed `784dedf5` native menu headings have one X Ode application menu plus Account. Actual About X Ode opened and displayed X Ode, then closed normally. After both game Stops settled, actual Quit X Ode exited and reopen restored Library and confirmed game sign-in. Earlier welcome Quit/reopen proof retained; old signed copies exited normally in this continuation. Legacy raw development copy remains separate. |
| Additional windows, keyboard, VoiceOver and system appearance settings | Not live-qualified; static inspection does not establish these behaviors. |

### Unlocked-console continuation, 2026-10-17

After the owner returned, the actual CoreGraphics console state reported
on-console and unlocked. Owner-requested four-hour `caffeinate -di` assertions
were verified; no lock/security settings changed.

The coordinator normally quit the idle `fe895e46` PID 49735. With its namespace
owner gone, the existing `7ba19a55` PID 66684's native Try again restored its
saved management session and collection. That older signed copy then also
quit normally. No process force, lock deletion or backend replacement was used.
Its failure-copy wording was not captured in this continuation; retry recovery
does not retroactively prove the exact error frame or wording.

The exact signed `784dedf5` package passed fresh deep/strict code-signature
verification and retained executable SHA-256
`64a036ab5d1487ef0ddd59af9f115283f1ef0dfd2ef48deb6162dadc3fc1bc97`.
It opened as PID 86437, restored the admitted saved management/PC-library
session and supported the native account/window checks above. Explicit game
account verification used the existing production action; the separate
management, library and game-service identities were not merged.

After the two game tests settled, the actual Quit X Ode menu action exited
PID 86437 normally. Reopening the same signed package produced PID 94794;
Library returned through saved management/library credentials and both Account
summaries still reported Signed in for games. No sign-out, credential prompt,
new verification action or forced termination was required for this restart.

Minecraft's actual Play and Stop buttons were also exercised in this signed
app. Its placeholder rendered a launcher-handoff window, not gameplay.
Native Stop returned the UI to Play, ended the observed game process and left
no matching run RAM mount. See the game ledger for exact scope and resources.
These native observations alone do not clear shipping XCTest, backend
provenance or distribution holds.

### Full shipping CI acceptance for the frozen source

The source owner made one authorized private-branch push of exact
`784dedf517845e0caf4cdedcd032444cddaa3d2a`, tree
`bb986a806defa63d07a9c3f58e33a19841601c03`, to the existing private, non-fork
app repository. No source/workflow changes, default-branch update, tag or
release were performed.

[CI run 39013367846](https://github.com/dragoshont/xodus-macos-app/actions/runs/39013367846),
attempt 1, and [job 117340361687](https://github.com/dragoshont/xodus-macos-app/actions/runs/39013367846/job/117340361687)
completed successfully at `2026-10-17T07:29:27Z`. The parent independently
queried GitHub and confirmed the exact head, completed/success state and every
existing job step, including SDK/runner verification, native/management checks
and SVG reproducibility.

The source owner's retained output identifies Xcode 27.0 build 27A266a,
macOS SDK 27.0 and runtime 27.0.1. The unchanged `sh tools/check.sh` passed
ShippingChecks.testShippingAdmission through real XCTest (one test, zero
failures; 36 shipping assertions), all eight shipping argument rejections,
fixture-resource exclusions, 29 portable packaging checks, 15 core checks,
5,637 management checks, 193 preview checks, 1,138 synthetic native-session
checks, 152 private native-host checks and 19 credential-wire checks without
Keychain. Editable SVG regeneration also left its tracked outputs unchanged.

The retained full log is `ci-39013367846.log` in the source owner's session
artifacts, SHA-256
`022206eb36b8e6e49881a725eb28f22b3c4e32a2ad243e41b3549f000718b8d0`.
This clears XO-007 for this exact frozen source, not through a substitute or
weakened gate. It is not fresh provider sign-in, gameplay, backend provenance,
distribution approval or acceptance of a future integration commit.

Storage-conscious title attempts and package-specific blockers are recorded in
the [game test ledger](GAME-TEST-LEDGER.md). No static audit, screenshot or
synthetic check is recorded as a played game.

## Current native observations

The coordinator independently reviewed the onboarding source delta at
`8a6aa359df63a4b63f40cea00d7efb6fc58e8a29`. The connected development executable
has SHA-256 `5968d94e83f6be8d2afc7b6b449434122b0262aa846e4de3b7ec2cf20cafb314`.
The welcome was observed with games hidden and truthful disabled sign-in when
unpaired. After the owner's explicit saved-session request, the recovered
management CLI read its normal credential API without exposing or copying raw
credentials. `credentialPresent` restored the app's management gate. The PC
library then reported its separate credential-broker pairing error (XO-009).
This is not PC ownership, fresh provider validation or gameplay acceptance.

The installed service, broker and both dedicated NMS launcher inputs still
match the recovered hashes. The broker also passes its source-pinned certificate
and identifier requirement, at 228,448 bytes. No installed broker/runtime,
credential, registration, game or save was replaced to obtain these observations.

The controlled signed `fe895e46` app subsequently opened normally. Its signed
management CLI is SHA-256
`394d244337d27f8ac9e3ba065a60a08366126fcca88c1b869c6efdf9e93eeccd`,
22,012,176 bytes; its signed AuthHost is SHA-256
`0cb79533a641468746280cbbdea32c2d08c86cdb5520639f5632fbf10ffe45c0`,
359,616 bytes. Actual code-signing identifier is `io.github.dragoshont.xodus`;
the different development CFBundleIdentifier is not evidence of a broker
caller-signing mismatch.

Initially the signed welcome stayed locked. The old raw app still had a
management child holding `Management/management.lock`; source enforces an
exclusive namespace lease. That old app and child exited normally, then the
unchanged signed app's actual Try again action restored the saved management
sign-in and its broker-backed PC collection. The welcome sheet disappeared;
the real Library showed 13 titles, package labels and an updated collection.
No new interactive authentication, raw token access or broker replacement was
needed. This is saved-session and native package acceptance, not verified
account joining, every title's entitlement, gameplay or full shipping acceptance.
The game-service account identity remains separately unconfirmed, even though
Account reports a saved usable game sign-in; see XO-018.

The next source correction is `7ba19a5529764d41ef577ff1e584ac363dafd84e`,
tree `02b49cb28e8e4244b294a04ac9735f920b61d46e`. The coordinator inspected its
historical helper-validation/recovery-copy fencing and command-menu delta.
The same original controlled packaging policy, sealed unsigned management
input and unchanged installed broker produced `Xodus-controlled-pair.VNXRWX`.
Independent deep/strict signature verification passed; package receipt SHA-256
is `2a86de9153c0ca0cbd13c96a7c45ef9d70bbad8e9a25732d5f2a7a229ffbef90`.
This remains a local operator-approved pair, not a distribution attestation.

The corrected package created process 66684 and native windows alongside the
accepted `fe895e46` process 49735. During the attempted native check macOS
reported `CGSSessionScreenIsLocked=true`; window capture failed and the bounded
Accessibility traversal could not complete. Neither corrected welcome copy nor
menu headings were observed in that initial attempt; those tool failures are
not product verdicts. A later cycle-safe read-only traversal completed and
verified the corrected menu headings (XO-017), but did not provide welcome
content or visual/interaction acceptance. The local operator now explicitly
refuses keyboard/button input while the console is locked; its exact refusal
diagnostic was exercised without sending an action.
No unlock, password, security-setting change or game/keyboard/mouse input was used.
A normal Quit request to the exact new bundle was accepted, but its later
process snapshot still showed it running. No force termination was used.
The existing accepted app and its management child were not targeted.

Subsequent narrowly filtered unified-log inspection found AppKit's
"App termination blocked by modal sheet" at `2026-10-17 00:42:03.556` local
for process 66684. A one-second sample shows its main thread normally waiting
in the AppKit event loop. This narrows XO-010 to a native modal termination
block; it is not evidence that an async shutdown or credential operation
deadlocked. The mandatory welcome uses the existing shared sheet layout.
Source correction must preserve authentication presentation and the existing
termination coordinator, not force exit or globally relax installer/destructive
modals. The subsequent repaired-package exit observations below supersede this
earlier pending-exit state.

Read-only investigation of XO-018 found no
`XodusRemote/game-stats-account.json`. Installed `private-xodus-manage.py`
SHA-256 is `e6efb8488db9d68a6c69db8791b1b817427b9344d92ed0fc0afaae84c317578c`.
Its `service_status` reports service sign-in plus the cached identity binding;
it does not resolve a missing binding. Its existing `service_signin` has a
saved-session identity-resolution branch. This script was inspected, not
executed or modified. No identity/hash value or credential was printed.

XO-018's source correction is `8072c42a5b897f9bf669be7a7ea7f2e1e78a8e31`,
tree `f2b57b1b5e3a5f5c783ce193cdd986d5d2fe4503`. Saved but unbound game sign-in
now has truthful partial-state copy/symbol and an explicit Verify game account
action through the unchanged admitted execution path. The coordinator reviewed
that frozen delta, including unchanged action gates and failure/retry tests.
Reported source checks: normal/shipping preview builds, 189 self-checks,
1,138 synthetic live checks and 29 packaging checks passed. These are not
actual cached-session identity resolution, native action reachability or the
missing full shipping XCTest gate.

### Repaired signed-package Quit acceptance

The coordinator independently inspected `784dedf517845e0caf4cdedcd032444cddaa3d2a`,
tree `bb986a806defa63d07a9c3f58e33a19841601c03`, directly atop `8072c42`.
Only the mandatory welcome attaches the native termination-policy bridge.
Window removal/change and SwiftUI dismantling restore the original policy;
authenticated Account and installer/destructive sheets are not globally changed.
The authoritative termination delegate/coordinator and operation holds are
unchanged. Source-owner results are 193 self-checks (including four actual
native property/lifecycle assertions), 1,138 synthetic live checks, normal and
shipping preview builds and 29 packaging checks, all passing.

The original controlled packaging script produced
`xode-private-pair-784dedf5/Xodus-controlled-pair.quyCXz/Xodus.app`.
This invocation used its existing signed-CLI reuse policy and the pinned
`fe895e46` receipt, preserving the exact **already-working** management CLI:
SHA-256 `394d244337d27f8ac9e3ba065a60a08366126fcca88c1b869c6efdf9e93eeccd`,
22,012,176 bytes. The sealed unsigned producer/provenance and original installed
broker remained unchanged. Parent independently verified deep/strict signatures,
source/receipt binding and byte equality to that working CLI.

New app executable SHA-256 is
`64a036ab5d1487ef0ddd59af9f115283f1ef0dfd2ef48deb6162dadc3fc1bc97`,
12,093,568 bytes; package receipt SHA-256 is
`6fc43252604ba9fc983a1b8c981b39366f6dbb7ded0fd487ba0c05689a33885f`,
21,592 bytes. The original shipping script's eight development-argument
rejection assertions and both fixture-resource exclusions were independently
exercised on the actual signed package. This does not replace shipping XCTest
or confer distribution approval.

With the accepted old management process still visibly owning its namespace
lock, the repaired package created process 81675 and its main window plus
560-by-620 startup-sized sheet. macOS remained locked. A normal
`NSRunningApplication.terminate()` request was accepted and actual process exit
was observed, without keyboard/mouse input, force termination, state/lock
removal or authentication dismissal. Reopening created distinct process 81711;
its startup-sized sheet appeared and a second normal Quit also exited.
These are actual signed-app lifecycle observations, not detached property tests.
They do not establish visual welcome copy, authenticated replacement, the new
account-verification action, provider identity or gameplay.

Supplemental observations, separate from the generated package receipt:
`xode-784dedf5-normal-quit-observation.json`,
`xode-784dedf5-reopen-quit-observation.json` and
`xode-784dedf5-shipping-entrypoint-observation.json` in the coordinator's session
artifacts. The repaired test instances exited; accepted `fe895e46` and the older
unaccepted `7ba19a55` instance were not force-terminated. Actual games/staging
volume availability after packaging was **146.71 GiB**.

A read-only, attached console wait is bounded by the original overnight
deadline, `2026-10-17T05:15:30Z`. It sends no input, wakes/unlocks nothing and
changes no settings. Unlocked-console notification only admits fresh exact-app
checks; it is not itself a native acceptance verdict. Remaining window,
saved-session replacement, provider and gameplay work stays blocked until
that prerequisite is met.

The first wait reported an unlocked observation at `2026-10-16T22:07:54Z`,
but the immediate fresh prerequisite read found the console locked again.
Activation and button/keyboard input were therefore not admitted. No saved
operation journal was present. The bounded wait was rearmed, within the same
original deadline, to require three consecutive unlocked observations; every
subsequent action still requires its own fresh check. A transient availability
notification is not recorded as a usable native session.

### End of the overnight window

The bounded observer ended at the original `2026-10-17T05:15:30Z` deadline
with exit 2: no sustained unlocked console was observed. A fresh read at
`2026-10-17T05:16:13Z` still reported the session locked. The observer is no
longer running; no scheduler, unlock/wake action or security-setting change
was installed. Remaining live checks are blocked, not silently completed.

Final reconciliation found six installed-game records, retaining all five
original Store IDs plus the new Minecraft Java package; no saved operation
journal was present. Actual game-volume availability was **147.20 GiB**.
The installed broker and generic game-runtime CLI still matched their original
recorded SHA-256 hashes. The accepted `fe895e46` app remained running as 49735.
The obsolete unaccepted `7ba19a55` test copy remained running as 66684 and
reported itself hidden; it was not force-terminated or represented as retired.
The repaired `784dedf5` test instances had already exited normally.

The ordinary service-identity resolver exists at
`Runtime/target/release/examples/xbox-social-readonly`: owned, regular,
single-link, 11,390,816 bytes, SHA-256
`66c615d57437a8cb0bcdace4128afdbba9018bb003667e277a0bd6594e165250`.
Only file metadata/identity was inspected; it was not executed, mapped to
recovered source or used to fabricate a binding. XO-018 still needs the actual
approved cached-session action/provider response after console availability.

The new private package and source corrections are preserved, not rolled out
as a fully accepted authenticated replacement. No push, PR, release, broker or
game-runtime replacement was performed. The remaining native window/provider/
gameplay work, full shipping XCTest, and provenance/distribution holds remain.

A final supported-alternative check confirmed that the active console belongs
to this user, login is complete, existing screen-capture permission is granted
and the accepted app's own windows still exist with sharing enabled.
Nevertheless the session reports locked and an attempted capture of only its
known main window 7782 was refused ("could not create image from window").
No image was created, unrelated desktop was not captured, and no input, wake,
unlock or permission prompt was attempted. This is not a missing capture
permission diagnosis or a proven app-rendering failure. Console availability
could not be obtained from the unavailable owner; the live lane remains held
rather than renewing the elapsed overnight window or bypassing its prerequisite.

The owner authorized overnight audit/playtesting and targeted game termination.
The 100 GiB free-space floor and the existing human-consent, player-data,
runtime-identity and distribution holds remain. The game ledger records real
Abiotic tutorial movement and normal exit separately from the Lara black screen.

### Post-window backend qualification and source-repair boundary

The renewed autonomous-work request admitted a separate finite Minecraft
backend check without desktop input, not a silent extension of the console
observer. The installed placeholder ran through the unchanged licensed
runtime; the actual app-wired title-scoped Stop backend ended the second
game process with a matching receipt. This does not qualify Java/Minecraft
gameplay, native Play/Stop buttons or account binding. The first external
parent-cancellation attempt's detached game and empty RAM image were both
recovered; no known test game/run volume remains. See the game ledger and
XO-019. Available game-volume space remained above 146 GiB.

The Stop failure-handling finding XO-020 was independently isolated from the
unchanged installed function with fake vendor failures, rather than mislabeling
the successful live Stop. A source-only repair was attempted through an
isolated session in the configured private backend project. Fresh GitHub API
reads confirmed `dragoshont/xodus-macos-private-ai` is private/not a fork, while
`dragoshont/xodus-macos` is public/a fork. Session creation refused with:
"origin points to dragoshont/xodus-macos, not the saved repository; restore
origin or remove and re-add the project".

No source-repair session was created. The coordinator did not alter a main
checkout, bypass that target guard, push private source to the public fork,
edit an installed helper or replace the working runtime. Repair requires a
correctly mapped isolated private backend source checkout and subsequent
source/component admission. This is a concrete additional source-work
boundary, not a reason to manufacture a local installed-runtime hotfix.

#### XO-020 recovered-source candidate, not a runtime hotfix

As a supported alternative, GitHub was read directly at the verified private
target without using or changing its misconfigured checkout. The complete,
non-truncated trees of all five current branch heads lack the management
Python helper: `5cbf0c3`, `a2ed3e9`, `ed5f37d`, `fc9bb5d`, `048843b`.
This is a scoped statement about those heads, not all history/local storage
or proof that the missing Rust runtime source has been recovered.

The actual installed Python file is interpreted source. Its exact bytes were
captured read-only with the recorded SHA-256, then repaired in a separate
session-owned local candidate repository. This explicitly establishes a new
recovery baseline; it does not invent a historical backend commit. No installed
file, main checkout, origin, credential or running component was modified.

Artifact directory: `stop-helper-source-candidate-e6efb848/` in coordinator
session files. Its capture base is local commit
`4a8fceb33fd49dd416f653c6282145318e80ef2e`; repair commit is
`cb86a8077c9509ea03e19a3762da21702002bc05`, tree
`a88d763968300d3b98a2aca7035224fe2ba668b0`. These are identities in that
local recovery repository, **not commits in this app or the GitHub backend**.
Candidate Python SHA-256 is
`7740b9eabc8074b2684be0b3f9ba89dbd4cb74cb318a9ced77b8ee5140c717be`.

The surgical source change checks the final vendor return code before writing
`stopped=true`, uses the existing `Failure(1, ...)`/entrypoint status path and
logs only a safe numeric runner code plus normal-close/retry guidance.
Graceful failure/timeout may still fall through to a successful final stop;
title-only bottle selection, legacy mapping and the 20/30-second bounds stay
unchanged.

`/usr/bin/python3` ran 13 offline isolated-function/entrypoint regressions:
the exact captured input produced four failures and the repaired candidate
zero. They cover final exit codes 1/7/-15, graceful failure/timeout with final
success, final timeout, vendor-start failure, missing environment, invalid
product, legacy scope, product-bound success and nonzero failure-status/no
success-result behavior. The exact original two-vendor-code-7 scenario now
returns status 1 with no success result. No vendor command, installed helper
invocation, account request or real operation-receipt mutation ran in these tests.

The clean local source repository and verified portable bundle are preserved:
`stop-helper-source-candidate-e6efb848.bundle`, SHA-256
`fdb407f4c3326c0193dc540c9d0bc2feb94d041bef06c5d454fbe087fccb6c30`.
Machine observations are `source-candidate.json` inside that directory and
`stop-vendor-failure-local-repair-exact-20261017.json` beside it. There was no
push, installed replacement, source-repository adoption, native failure
acceptance or distribution approval. The working installed helper still
matches the original input SHA-256.

## Owner-directed visual references

The owner selected the installed Apple Games and Music apps as inspiration.
Their existing desktop windows were inspected locally without playback,
subscription, purchase or account changes. Apple Games is the primary native
reference: centered toolbar navigation, artwork-led content and restrained
chrome. Music is a secondary reference for hierarchy, typography and grouped
library navigation; do not mix incompatible navigation models or copy Apple
assets. These references do not reopen broad redesign scope during the freeze.

Mobbin access succeeded after the owner's existing Edge login. The inspected
[Apple Music account-flow preview](https://mobbin.com/flows/994be325-9454-4ffd-86cb-3a50a0c0379a)
shows its Home view with a contextual primary action and artwork cards; it is
an iOS reference, not macOS welcome-flow evidence. Searches for Apple Games
returned Apple Fitness screens and were rejected as Games references.
No browser session tokens were exported or added to this repository.
