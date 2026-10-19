# Xodus for Mac

A native Mac launcher in development for legitimately entitled Xbox PC games, integrating with the Xodus management engine.

**Current status: native development app, not a complete game launcher.** The default SwiftUI/AppKit app has a real bounded management client, isolated Microsoft Store sign-in integration, source-backed PC Game Pass discovery and Microsoft Store network search, edition detail and activity. A native folder picker also supports a read-only marker check in one explicitly selected game folder; observed header identifiers never become retail identity, registration or permission to launch. A packaged development build includes its matching engine and connects without Terminal setup; negotiated capabilities determine which actions work. Search coverage is explicitly partial, and public results never establish ownership. The admitted f30/d00 pair confirmed saved credentials after the user's native Keychain approval and completed one Halo authenticated read with `verified: true`; no repeat verification or ownership inference was made. S4 now has a live-accepted account-bound PC Library. Game-service sign-in, installation, repair and uninstall are implemented, installed and owner-accepted as S3/S5/S6. Broader owned-PC coverage comparison, an engine-backed installed-game registry and general gameplay certification remain gaps. Saved sign-in alone is **not** proof of PC ownership or package access.

The original offline demonstration is **nonshipping only**. `XODUS_SHIPPING=1`
compiles out its views, invented state, artwork, resources and check/export
entrypoints. Shipping screens use native setup/empty/loading/error states and
actual public product data, not synthetic game illustrations. See
[native integration status and evidence](docs/NATIVE-INTEGRATION.md).

**Library design refresh (C3 visual direction approved; not installed):** the
user-selected v0.2 Figma layout uses native Apple Games-inspired art-under-toolbar chrome,
landscape Continue Playing and a 2:3 portrait grid. Native segmented filters,
compact Sort and contextual glass actions retain real access/install evidence.
The user approved C3's native regular-glass toolbar treatment. Production only
uses opaque fallback when the system requests Reduce Transparency. The source
passed 110 presentation and 853 synthetic native-session checks, and the shipping
configuration compiled; this is not shipping admission. A separate non-installed review app reads the frozen credential
broker only, keeps refreshed tokens in memory, and cannot run ordinary startup.
Real account captures remain private. Window-compositor screenshots require
an already approved observer; detached layout checks are not glass evidence.
Public PC package sizes are approximate download estimates; installed-folder
sizes are cached off-main filesystem measurements. Play remains installed-only,
and Install never auto-plays. Xbox statistics are cache-only in the frozen C3 reviewer. Subsequent source
adds account-bound ordinary stats refresh, throttled durably to one attempt per
15 minutes, and bounded persistent public-image caching. These follow-ups are
not installed or live-app-accepted; final D8 admission remains required.

**Discover design refresh (D2 direction approved; not installed):** empty-query browse
uses a public title's landscape artwork and one reasoned native action, followed
by genres actually present in the loaded catalog and portrait covers. Search
keeps owned matches first and exact-ID deduplication. The approved Library
regular-glass toolbar treatment is reused; no invented editorial genres,
subscription access or play-and-download shortcut is added. A separate read-only
review can consume an unchanged private checked-catalog snapshot and perform
local title matching. That snapshot is not relabelled live Game Pass discovery
or Microsoft Store network search. Root captured Dark/Light browse, search and
empty states with normal finishes. The approved consumer-copy correction is
frozen at `d2be594`, with [exact-source CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37822024468)
green. Explore games/More games and native No Results copy replace evidence
terminology. Shipping admission remains separate.

**Game detail (D3 source candidate; visual review pending):** the native detail
sheet adds optional public descriptions, screenshots, developer/publisher,
release date, content notices, Microsoft Store ratings and Windows PC CPU/GPU
requirements. Public capabilities remain distinct from Mac compatibility.
Trailers use native AVKit HLS streaming only after an explicit action; opening
detail never creates a player or downloads a whole video. Missing fields hide,
different PC editions do not become one invented requirement table, and there
is no Metascore. Four evidence facets remain visible; registered installed
games retain Play/Stop and uninstalled entitled games retain protected Install,
without automatic playback. Source checks are not native capture, observed
trailer playback or shipping acceptance.

**Phase 2 B5/B7/B8/B9 (`fee7f5f`, admitted and installed; live acceptance partial):** Account
shows cached PC Game Pass status and an explicit fenced Check. Active status
enables a separate Game Pass shelf after Your PC games and the existing
support-check/consent/Install flow on eligible Discover games. No subscription
end date is inferred. While an Xodus-launched game is running, the shared
Installed/Continue Playing action becomes Stop. The fixed private script must
confirm that exact title stopped; a requested stop records normal session
history without treating the launcher's exit code as a crash. Stop is disabled
while in flight. Ordinary Quit still leaves a game running. C8 is unchanged;
network-denied neutral suites, shipping-debug compilation and
[exact-source CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37676485849)
pass. The owner independently admitted the signed package before freshly
authorizing normal Quit and replacement. Full `7c3c1f0` rollback, the untouched
profile and byte-identical private installed-list permissions were preserved
through one ordinary Library reopen.
Private script entrypoints now use the separately installed self-contained
`~/Library/Application Support/Xodus/Runtime/scripts/macos` directory; the
runtime is not bundled into the app. One read-only startup check supplies
four Setup items and, when needed, one Xodus needs setup banner. Repair Xodus
is explicit and fenced against tracked gameplay, concurrent mutations,
service sign-in/status and Quit; generated launchers are revalidated at their
existing paths without changing the installed list. The backend also refuses
repair while any launch/download process exists, including untracked sessions;
it only creates missing environments, starts a missing service, and never
rebuilds existing title environments or touches saves.
Unsupported consent hides download-size/future-download copy, while supported
consent shows the backend's real download size when available.
The owner observed cached Active status, all four Setup items, successful
in-app Repair Xodus with refreshed readiness, and the Game Pass section header.
The user subsequently unlocked the login Keychain, without automated approval,
and the owner resumed live acceptance. Two defects were then observed: a
Game Pass check could choose a feed title without a PC package and return
Unknown, and Check game sign-in left Setup readiness stale. Their next-package
source correction prefers PC catalog candidates, skips strict cached
no-PC-package/package-type failures, tries at most three exact-ID probes only
after null results, and refreshes Setup after successful sign-in checks.
The corrections are independently admitted, installed and owner-live-accepted
at `208939c`: Game Pass Check shows Active, Setup is all Ready, and the setup
banner disappears after Check game sign-in. The exact CI is
[37688479927](https://github.com/dragoshont/xodus-macos-app/actions/runs/37688479927).
The full prior app rollback, profile and installed list were preserved.
Shelf, Install, Play and Stop
acceptance remains separate from neutral qualification.

**Phase 2 B1/B2/B3 (`7c3c1f0`, admitted, installed and live-accepted):** Discover
accepts verified PC Game Pass feed membership without requiring the separate
Store PC-candidate flag. Store search remains strict. Search shows matching
titles from the loaded PC library first, reuses its Play/Install controls and
removes exact duplicates from Store results. Owned and Game Pass labels use
only loaded library/feed evidence. Install consent checks package support before
enabling Install and shows the reported download size or unsupported reason.
Private cached check results provide Mac-support badges without running a
check. These labels are not general gameplay certification. C8 is unchanged.
Mac neutral suites, shipping-debug compilation and
[exact-source CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37668302715)
pass. The source-reviewed signed package preserves admitted C8 byte-for-byte.
Independent combined admission and fresh game-ended/normal-Quit authority
preceded replacement. Full `1463cdb` rollback, the untouched profile and
byte-identical private installed list were retained through an ordinary
Library reopen. The owner accepted Discover's 16 real-art Game Pass titles,
owned-first Lara/Hogwarts Play and Celeste Install, and Celeste's exact
unsupported reason with Install disabled. These are bounded live observations,
not general gameplay certification.

**B6 (`2d420d1`) is independently admitted, installed and live-migrated.** A fixed
self-signed certificate alone cannot make macOS's per-build Keychain partition
stable. The user selected a tiny separately installed helper whose signed bytes
stay unchanged across launcher updates. It authenticates each app caller against
the fixed-certificate requirement over a private socketpair; the app verifies the
helper's packaged hash and loaded code before sending anything. It handles only
the app's PC-library refresh item. Existing but invalid or unreachable helpers
fail visibly; direct access is allowed only when the helper is absent.

An explicit **Xodus needs one-time Keychain approval.** action migrates the
legacy item: read with human approval, save and verify a broker-owned copy, then
attempt deletion of that exact old reference without further interaction.
Failure to remove the old item retains the verified new copy and reports
**legacy retained**; future launches use the new copy first and never retry
removal automatically. Helper updates need their own approval and release gate.
Synthetic qualification and live migration are separate. The owner authorized
the user-present live migration, which completed with `legacyRetained=false`.
An identical reinstallation then read the PC library without reapproval.
A distinct signed, non-installed Library review build also read the frozen
helper and loaded 13 PC titles with no Keychain prompt observed; it performed
no write/delete/migration and quit normally. This is bounded cross-build
evidence, not a guarantee against all future prompts. Game-service credentials
were not changed by this lane. See the
[broker contract and qualification boundary](docs/NATIVE-INTEGRATION.md#b6-frozen-credential-broker-candidate).

**S3/S5/S6 (`1463cdb`, admitted, installed and live-accepted):** the account area
adds explicit game-service sign-in/status, separate from PC-library credentials.
PC Library games offer Install with native destination/free-space consent.
Downloads shows script-reported bytes and phases; Cancel signals only the
app-owned install process and waits for its result. Installed entries offer
Check for update / Repair, confirmed Uninstall, and the unchanged list-only
removal. Script success still must pass the same local config/launcher validation
and private registry save as Import. Games being changed cannot be played; one
mutation runs at a time, and normal Quit waits for completion or cancellation.
Private scripts, gameplay credentials, save preservation and engine behavior
remain owned outside this public repository. No private implementation is
imported and the signed C8 engine is unchanged.
[Exact-source CI passed](https://github.com/dragoshont/xodus-macos-app/actions/runs/37640727574),
along with 684 native checks, including 77 game-operation checks. The owner
independently admitted the signed UI-only package and freshly confirmed no game
was running before authorizing normal Quit/replacement. All 21 installed files
and strict signatures match admission. A full S4 rollback is retained; the
profile was left untouched and the private installed list remained byte-identical through one
ordinary Library reopen. No game operation or sign-in was automated by the app
implementation/deployment lane. The owner separately completed live acceptance.

The owner closed S3/S5/S6 with no app defect: in-app Install consent, real
Downloads progress and Cancel control, a fresh 3.25 GB Lara installation with
generated-launcher registration, Play to its main menu, successful Repair,
and confirmed Uninstall with files/environment removed, saves kept and the
list updated. Sign-in-required and unsupported-package errors, Show log,
Continue Playing session recording, child identifiers and Installed menus were
also observed. Backend fixes during acceptance were private-script-only.
This title-specific evidence is not general gameplay certification.

**S4 PC Library (`7ec1daa`, admitted, installed and live-accepted):** a separate native
Microsoft device-code sign-in reads the account's complete paged collection,
then joins active, non-trial Game entries to exact Store products declaring
`Windows.Desktop`. The Your PC games shelf never comes from Xbox activity or
Game Pass discovery. Imported StoreId matches share the existing Play action;
other games say Not installed. Refresh tokens alone use an app-owned Keychain
item; access/Xbox tokens and the library remain in memory. Entry checks saved
sign-in presence without reading credentials or automatically querying.
Partial/failed refreshes are explicit and cannot become an empty library.
Installed and Continue Playing remain above the shelf.
[Exact-source CI passed](https://github.com/dragoshont/xodus-macos-app/actions/runs/37617059339);
the independently admitted signed package preserves C8 byte-for-byte. Normal
Quit/replacement preserved the full S1 rollback, profile and private installed
list; all 21 installed files and strict signatures matched admission. One
ordinary Library startup was left open. Root separately confirmed user-completed
in-app sign-in and 13 PC games with real Store art; Hogwarts matched Installed
with the shared Play control already verified in S1/S2. Root closed S4.
Those observations do not come from neutral or deployment checks. The owned-view
coverage comparison remains open in the owner's spec. The section-identifier
follow-up is addressed in the S3/S5/S6 source above, and the owner has verified
the child identifiers on the installed build. This is not complete accessibility
certification. S4 itself does not add installation, entitlement inference from
history, or a backend/engine change.

**Installed-game Play (introduced at `0926414`, retained in shipping `1463cdb`):** main Library has an **Installed** section
above the separate account-bound PC shelf/sign-in prompt. Import an already-installed Xbox
game folder, then explicitly select its executable Xodus launch script. The app
reads `MicrosoftGame.config` locally and saves only the selected entry in a
private, atomic local list. Play runs `/bin/bash <script> <runID>` with a minimal
environment. Only one game session runs at a time; Launching becomes Playing
while the script remains alive, and its exit ends the session. A failed exit
shows its code and Try again. Quit does not stop the game. Remove from list deletes only
the list entry, never the game, launch script or saves. These local imports are
**Installed**, not Owned, and do not establish Store availability or entitlement.
No backend, contract or signed engine change accompanies this interface.
Hogwarts Legacy's live test is separately user-controlled; neutral checks never
launch a real game.

**S1 admitted, installed and live-accepted:** imported tiles use bounded local PNG/JPEG art from
MicrosoftGame.config. The newest recorded Xodus-launched imported game supplies
a Continue Playing splash card, publisher and relative last-played date, sharing
the list's Play state. Session start/duration stay in the private local list;
old entries still load. Nonzero sessions offer Show log only for an existing
generated-session stderr file. This is not Xbox activity, ownership or network
artwork. [Exact-source CI passed](https://github.com/dragoshont/xodus-macos-app/actions/runs/37610002150).
Root independently admitted the matching package and confirmed the game had
ended before normal Quit/replacement. All 21 installed files and strict
app/helper/engine signatures matched admission, with C8 unchanged. Full 092
rollback, profile and installed-list bytes/permissions were preserved. One
ordinary Library startup was left open; no Import or Play was automated by the
app implementation/deployment lane. Root subsequently observed actual Hogwarts
tile artwork and, after its own post-install Play session, the real splash,
publisher, relative last-played date and shared retry/Show log actions.
Session history persisted with 0600 permissions. Root closed S1 with no defect;
this separate live evidence is not inferred from neutral or package checks.

The initial Play slice's exact-source [CI passed](https://github.com/dragoshont/xodus-macos-app/actions/runs/37603065132).
The independently admitted package was installed after normal Quit, preserving
a complete working 2d rollback, the profile and older rollbacks. All 21 installed
files and app/helper/engine signatures matched admission. The exact signed C8
engine is unchanged. One ordinary main-Library startup was left open; no Import,
Play or real-game launch was automated, and no screenshot or gameplay proof is
claimed.

**Preserved Library history boundary (first admitted at `2d741a7`):** before S4,
the owned-PC Library showed an unavailable state rather than guessing which
games you own. S4 replaces that state only with explicit account-bound
collection/PC-package evidence. Main Library still does not display TitleHub
history as your games, a featured owned title or a PC Store shelf, and entering
main Library makes no saved-status or history request. **Browse games** opens
Discover; **Recent activity** explicitly opens a separate in-Library scope.
That scope prominently identifies cross-platform play history, not your owned
PC library. Even a reported PC/mixed tag does not establish Store availability
or entitlement; console history appears only in activity. Activity search and
the reported-platform filter apply only to its loaded partial window.

Explicit activity entry uses the existing bounded saved-status-then-history
loader: fresh credential-present status is reused, ordinary view rebuilds and
return visits do not poll, and failures require manual retry. No automatic
login, persisted history or title-to-Store mapping is introduced. Consumer
`2d741a7` passed exact-source CI and independent source/package admission and was
installed with the unchanged signed c107 engine. One ordinary startup left the
same corrected shipping process running in main Library. All 21 installed files
and its single parent-owned engine matched admission; no helper was running.
No activity, Account or Store action was invoked for proof. Bounded aggregate
observation found no recent-list publication or image-decode events; this is
not API-trace or visual evidence, and anonymous startup catalog search remains
unchanged. Source and neutral checks establish the main-Library data boundary.
Normal Quit preserved the complete working 0a bundle, older rollbacks and profile.
The historical deployment evidence below describes the earlier presentation.
The earlier controlled
113be57/c1073100 pair was admitted and installed: one foreground check confirmed
saved sign-in, and one actual TitleHub read returned a partial 20-title window
with 20 available artwork entries and none rejected. All 20 preload references
succeeded, with zero failures; references may share cached images, so this is
not a claim of 20 unique HTTP requests. A private actual Library image was
visually confirmed with real title artwork and a featured tile. Real Store
covers and hero images were separately confirmed in Discover and Product.
Own-view evidence is not compositor or accessibility certification. The
reopened shipping app had a separate session: the export did not persist or
inject history. That historical export is not proof of the new startup flow.

The prior **0a6dca1/c1073100 shipping pair was admitted and installed**. Its
ordinary foreground startup published one real 20-title recently-played window,
and the same shipping process decoded 12 actual artwork images successfully.
That populated app was left running, with one matching engine and no sign-in
helper. No private exporter, additional personal request or reopen was used.
These are aggregate publication/decode observations, not a claim that every
title has a distinct fetched image or that recent activity proves ownership.
Recent entries now have a native **Find in Store** action. Only invoking it
uses the title name to search Discover; you choose among catalog candidates.
It does not map history to a Store product, establish access or enable play.
The routing/selection behavior was qualified with neutral tests and exact CI;
no personal-title Store query was automated during deployment.

Engine-owned/installed Library enumeration remains unavailable: the installed snapshot is a constant empty
response, not a durable registry or scan of this Mac. It never proves that no
games are installed. A selected-folder marker check is separate from ownership,
game-file integrity and permission to play. Technical metadata stays in
contextual information disclosures. This engine enumeration does not supply
an Install action. The separate
local Installed list above enables Play only through an explicitly imported
working launch script, not through the engine's empty registry.

![Original Library concept](design/previews/library.png)

## Explore the foundation

| Artifact | Purpose |
| --- | --- |
| [Product](PRODUCT.md) | Audience, scope, principles and undecided product choices |
| [Design](DESIGN.md) | Native visual direction, tokens, interaction and original mockups |
| [Requirements](docs/REQUIREMENTS.md) | Traceable requirements and measurable acceptance criteria |
| [UX flows](docs/UX-FLOWS.md) | Screens, cancellation, loading, degraded and recovery states |
| [Architecture](docs/ARCHITECTURE.md) | SwiftUI/AppKit boundary, Rust adapter and trust model |
| [Backend contract](docs/BACKEND-CONTRACT.md) | Pinned scoped management protocol and future lifecycle requirements |
| [Runtime providers](docs/RUNTIME-PROVIDERS.md) | Four declared presets and separately versioned, configuration-only planning |
| [Native integration](docs/NATIVE-INTEGRATION.md) | Actual native client, developer app bundle, limitations and producer pin |
| [Research and decisions](docs/RESEARCH.md) | Evidence, leads, uncertainties and decision register |
| [Milestones](docs/MILESTONES.md) | Release gates; prototype is not a production milestone |
| [Implementation ledger](docs/IMPLEMENTATION-LEDGER.md) | Durable v1 work IDs, actual-vs-fixture status, dependencies, evidence and blockers |
| [Editable mockups](design/README.md) | Original SVG screens, shared tokens and reproduction |

Design collaboration: [nine editable v0.2 Figma mockups](https://www.figma.com/design/5iQu716UFImHjRxJkf0t8V?node-id=3-115) and [editable FigJam UX flow](https://www.figma.com/board/3MejlFaXHkogmJ3J5k79Gw). Revised Library/Discover renders were inspected; [import status](design/README.md) records static SVG fidelity limits and superseded v0.1. These are proposed designs, not implemented APIs, exact compositor effects or a wired Figma prototype.

## Run the native development app

On an Apple Silicon Mac with the **Xcode/SDK 27 or newer** toolchain
(tested with Apple Command Line Tools, Swift 6.4 and SDK 27.0):

```sh
swift run XodusFixtureChecks
swift run XodusPreview
```

The historical SwiftPM executable name remains `XodusPreview`; its default is now the live development shell, **not simulated gameplay**. Source-only development can select a trusted engine in Advanced Settings or explicitly use `XODUS_BACKEND_PATH`. A packaged build uses its included engine automatically; a missing/nonexecutable included engine shows an actionable error rather than silently using a saved external build or convincing fixtures. There is no interactive-CLI scraping or arbitrary Wine picker. The main launcher never receives credentials; the isolated Swift authentication host handles only its private memory-only handoff, not credential storage or cryptography.

Build a controlled local `.app` only after independent source and sealed-input
approval; placeholders below are required operator pins, not values to guess:

```sh
sh tools/build_app.sh /absolute/reviewed/engine UNSIGNED_SHA BYTES PROVENANCE_SHA PROVENANCE_BYTES APPROVED_APP_COMMIT APPROVED_APP_TREE /absolute/owned/output
```

The packager verifies independently supplied unsigned CLI/provenance hashes,
sizes, exact approved producer source/tree, release profile and feature sets. It creates
a new stage, separately signs engine/helper, generates stage-only compiled
pair pins and then builds the shipping launcher. The final helper receipt and
signed identities must match those compiler inputs. No engine override, picker,
remembered path or runtime JSON can grant shipping approval. An unpaired shipping
build fails before any engine process. The prior `dist/Xodus.app` is never moved
or replaced. This source tooling is not an executed package, notarization,
distribution attestation or successful human login; deployment/launch require
separate approval. See [controlled pair admission](docs/SHIPPING-ADMISSION.md).

The proposed deployment baseline is **macOS 14**, not a user-approved support commitment. The shared native toolbar groups Library / Discover / Downloads with compact stock `NSSearchField` search: real `.tabs` on macOS 27+, segmented fallback on 14-26. Search expands for editing, Command-F or a retained query; Account stays separate at the trailing edge. The Scene hides the visible title while retaining native traffic lights and app identity. Live title art uses only actual normalized Microsoft metadata URLs through a
bounded memory-only native loader; proprietary covers are not bundled or
committed. Empty/error states keep semantic native backgrounds. Account content scrolls independently of its adaptive action footer, and normal activation remains AppKit-owned. Source/headless checks alone do not establish deployment or visual conformance; the controlled pair's actual own-view confirmation is recorded separately.

**Official CrossOver, installed separately, is the first-release dependency.**
The app checks only standard app locations, bounded metadata and a fixed
Apple-anchored CodeWeavers signature requirement. A verified installation
defaults a new/unset profile; explicit choices are preserved. Missing/unverified
CrossOver blocks first-release gameplay setup, not public browsing or Microsoft
sign-in. Wine/GPTK and custom graphics remain **Experimental**, with explicit
acknowledgement reset by configuration or observed installation changes.
See [runtime policy and scoped trust source](docs/RUNTIME-PROVIDERS.md).

Wine/graphics versions and hashes remain independent declarations. The separate
bounded `runtime-plan` validates configuration only; it never executes CrossOver,
checks a license, creates a prefix, migrates saves or enables Play. A verified
app signature is not entitlement or game compatibility. The nonshipping fixture
Settings cannot inspect CrossOver or start planning. The controlled development
sign-in result does not qualify this runtime policy for gameplay or distribution.

`XodusAuthHost` implements AppKit/WebKit window ownership and a strict private,
anonymous-channel protocol. Its exact seven-string legacy handoff remains
memory-only; Rust retains proof/SOAP processing and credential commit. Neutral
WebKit and channel checks do not contact Microsoft. The controlled human flow
now reaches saved sign-in, including after restart. Actual bounded provider
reads are recorded separately from neutral checks; passkey coverage and full
owned-library enumeration remain unqualified.

**Visual revision v0.2 supersedes the unapproved flat v0.1 concepts.** SVGs describe editable layout and intended glass placement, not live compositor refraction. Native own-view exports also cannot establish backdrop/refraction fidelity; the native implementation, not an SVG blur, owns system Glass.

For the original offline design demonstration:

```sh
swift run XodusPreview --fixture
```

In that nonshipping mode, choose **Library / Discover / Downloads**, search within the current scope, open an invented game, and use **Simulate install** or **Simulate next step**. Fixture Settings inject empty, partial, stale, offline and cancelled-auth scenarios. Simulated jobs exist only in memory and reset on relaunch. Fixture mode never contacts the engine, opens sign-in or writes a game registry. There is no live Settings transition to preview; start it explicitly as a separate nonshipping invocation.

```sh
swift run XodusPreview --self-check
```

Core, presentation and `swift run XodusManagementChecks` are dependency-free executables. Presentation checks also allocate native search controls and lay out synthetic Account content in detached `NSHostingView` instances: no window is shown, no provider is loaded and no backend connects. They do not render or capture an existing app. Management checks use the producer's sanitized fixtures plus real mock child processes to exercise negotiation, framing, EOF/timeouts/exit failures, request correlation and activity reconciliation. They do not sign in or approve Keychain access. Command Line Tools do not include XCTest/Swift Testing on the tested Mac. [Verification](docs/VERIFICATION.md) records actual evidence separately from future release criteria.

`swift run XodusPreview --live-check` exercises the actual native session coordinator against synthetic subprocesses: expired-profile recovery, permission failures, transient/late-cancel reconciliation and failed-page continuation. It exits before creating a window and performs no Microsoft or Keychain operation.

Native Settings can preview and save a **counts-only diagnostic summary** through
a native file picker. Only the reviewed summary is saved, not raw engine logs,
account identifiers, tokens, URLs or personal paths. Writes are atomic and run
off the main actor; failures remain explicit. Overlapping disconnect/reconnect
operations share bounded shutdown ownership rather than starting another engine
before the old child exits.

`sh tools/check.sh` runs the native/management/nonshipping-fixture/private-host checks,
portable packaging negatives, actual shipping release compilation and separate
shipping XCTest admission checks. The latter require full Xcode's test framework,
not only Command Line Tools; they never become application entrypoints.
For only the shipping checks, run `sh tools/check_shipping.sh`: it builds the
neutral engine and supplies its fixture paths. Invoking the shipping XCTest
directly without those inputs is not an admission result.
The existing GitHub-hosted `xcode-27` job checks actual SDK/runtime versions and
SVG regeneration. A workflow definition is not evidence of a passing revision.

Own-view exports use `--export-preview <directory>` for fixtures or `--export-live <directory>` for a **disconnected**, non-account live shell. They export this app's Library, Discover and Downloads view hierarchy and exit; they do not capture the desktop/other apps or establish Glass-compositor fidelity.

## Boundaries and licensing

The app is standalone: Heroic does not offer a proven shipping new-store plugin API. Existing Xodus runtime service IPC is **not** the management protocol. The scoped adapter does not resolve authoritative PC ownership, safe package installation or the exactly paired Xbox-capable gameplay runtime.

No private runtime source, credentials, real account data, proprietary game covers, Apple assets or paid design assets are included. The original app source, documentation and mockups are licensed **GPL-3.0-only**, by the user's explicit choice; see [LICENSE](LICENSE) and [licensing boundaries](docs/LICENSING.md). Third-party runtime components/assets retain their own licenses. Dependency redistribution, signing/notarization and installer distribution remain pending. This license does not grant rights to Microsoft packages or runtime components.
