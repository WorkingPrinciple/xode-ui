# Verification evidence

Foundation recorded 2026-10-03; subsequent native/read-only milestones are
identified separately below. None establishes successful human authentication,
game download, install or gameplay.

## Unavailable catalog release date (source candidate, 2026-10-18)

Parent captured **Release date / 30 Dec 9998** in Minecraft: Java Edition
detail on signed `2bc5c6b`. Its text artifact did not bind the raw response or
requested market. A separately authorized, unauthenticated public lookup used
the source's native defaults US/en-US:
`https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds=9PJ8266BHFWN&market=US&languages=en-US`.
It returned product `9PJ8266BHFWN`, market `["US"]`, and
`OriginalReleaseDate: "9998-12-30T00:00:00.0000000Z"`. The response is retained
in source-session artifacts as `minecraft-public-us-release-date.json`.
This independently corroborates the exact displayed marker, not the identity
of the earlier native cached response. No broader catalog sentinel range is
claimed.

Only `CatalogDetailFacts` release-field parsing changes. The exact parsed
marker instant becomes unavailable, including equivalent zero-fraction/offset
representations. Invalid timestamp syntax, impossible days and hour 24 are
omitted instead of Foundation's silent civil-date normalization. The shared
script-receipt date parser, requested-market selection, timezone formatting,
and all other product facts are unchanged. No date cap, guessed replacement
date or title-specific exception is introduced. The existing optional-date
view branch consequently omits the row.

The actual detail metadata regressions were run before the fix against
`2bc5c6b` behavior: **211 preview checks, 6 failures**, reproducing the exact
marker and normalized invalid-date cases. After the fix,
`swift build --jobs 4 --product XodusPreview` passed and
`swift run --skip-build XodusPreview --self-check` passed **211 checks,
zero failures**. Eighteen added checks cover absent/malformed/invalid/leap
dates, the exact marker and equivalent offsets, unaffected neighboring
far-future dates (including year 9999), historical and ordinary future dates,
and preservation of other metadata.
`XODUS_SHIPPING=1 swift build --jobs 4 --scratch-path .build/shipping -c release
--product XodusPreview` and `git diff --check` passed. Logs are retained as
`release-date-*.log` in source-session artifacts.

No ordinary app/account/cache/game/VM operation, packaging, signing, install,
activation, push or CI action was performed. Parent owns native confirmation
and the subsequent exact-source shipping gate. The separate `2bc5c6b` CI run
does not establish acceptance of this follow-up; local full-Xcode XCTest
availability and external distribution/provenance holds are unchanged.

## Optional private cooperative game handoff (source candidate, 2026-10-18)

The existing launch token owns the launcher shell, not a Wine GUI process.
Shell ancestry, process names and empty/nonempty bundle identifiers are not
accepted ownership substitutes. The optional native consumer instead requires
the separately implemented private backend's live current-run socket
attestation, returning exactly PID/start seconds/start microseconds.

The opt-in input is an app-signed resource capsule at
`Contents/Resources/LaunchAssociation`: `manifest.json`, standalone stdlib-only
`adapter.py` and source-built `peer.dylib`. Manifest version 1 contains `enabled`,
`adapterSHA256`, `peerSHA256`, and `brokerSHA256`. No capsule preserves ordinary
Play unchanged. A present capsule requires valid app resource/code signature
and pinned payload hashes; invalid input gives only **Game foreground handoff
unavailable.**, without blocking the existing launch. Keep `enabled:false`
until independent actual-Wine association proof and explicit private capsule
admission. No settings toggle, installed runtime modification or capsule is
provided by this source candidate.

The broker is fixed to the standard CrossOver hosted-application wineserver
path, SHA256 `f9c4ed146c7d6dfc94334255907d4e0658218585085ca2107a5181b4deb474fc`,
CodeWeavers team `9C6B7X7Z8E`, identifier
`com.codeweavers.CrossOver.bin.wineserver`. This is a pinned backend
co-owner exception, not native discovery of a game or permission to select a
broker as the GUI. Updated broker bytes require separate qualification.

At explicit Play the app generates a fresh 32-byte random nonce and owner-only
0700 root bound to the existing run ID/token. Only its owned launcher inherits
the private options; the backend must remove them before creating the game.
The adapter receives the nonce through its dedicated environment variable,
never command-line arguments or logs. Each owned command has a three-second
bound and a 1024-byte output limit, with a 120-second total
lifecycle bound.
Cancellation closes only that exact owned consumer. The bridge owns its live
descriptor and run directory; native cleanup does not delete them.

Before any request, a typed C/libproc check verifies the same effective-user
PID/start instance. The exact PID must have an on-screen ordinary-layer usable
window and a finished, nonterminated `NSRunningApplication`; an empty bundle
identifier is allowed. Only an active X Ode donor can call ordinary
`yieldActivation(to:)` then `activate(options:[])`, once per launch.
App deactivation permanently abandons that handoff, including during launch
preparation; Stop, termination, shell exit and run replacement fence pending
callbacks. No force activation, AX, input automation, title matching or focus
reclamation is used. An accepted activation request is not foreground proof.

Source checks and actual-Wine/signed-native integration are separate gates.
Parent owns the matched backend/SDK capsule and actual foreground acceptance.
Controlled packaging accepts explicit `--launch-association-capsule PATH`:
it validates exactly the three pinned files, stages them before app signing,
and seals their identities in paired inputs/final package verification.
No option means no capsule. This does not change the existing signed-CLI reuse
or frozen credential-broker path. The adapter invocation includes
`--run-nonce-env XODUS_LAUNCH_RUN_NONCE`, `--trusted-broker-path` and
`--expected-broker-sha256`; only the owned launcher receives
`XODUS_LAUNCH_TRUSTED_BROKER_PATH` and
`XODUS_LAUNCH_EXPECTED_BROKER_SHA256` alongside the four private run options.

### Bundled interpreter admission

An enabled capsule now also requires an independently staged interpreter; it
never uses `/usr/bin/python3` or a Homebrew fallback in the shipping consumer.
The exact three-file capsule and its pinned library bytes are unchanged.
`--python-runtime-archive PATH` accepts only the archive pinned by
`tools/python-runtime.json`: python-build-standalone CPython 3.14.8, arm64,
release 20261013. The build never downloads or installs Python globally.
The operator must supply the exact approved archive.

Staging validates archive digest/length before unpacking. It rejects traversal,
duplicate names, special files and escaping/cyclic aliases, materializes
internal file aliases without links, normalizes permissions, retains upstream
license files, bounds expanded size/count, and signs the staged Mach-O files
before making runtime resources read-only and sealing their final identities
and the app. The runtime and manifest
live separately at `Contents/Resources/XodusPython{,.json}`. Final package
verification rejects unstaged/changed runtime files, metadata and modes, and
enabled capsules without the interpreter. This does not establish completeness
of third-party license notices or Developer ID/notarization acceptance.

Native admission requires valid app/resource/nested-code signatures, the pinned
runtime version/archive identity, and the exact executable digest. A present
invalid runtime fails Play or the operation explicitly instead of invoking a
different Python. Absence retains legacy source behavior and is not clean-Mac
production acceptance. The admitted bin directory is first on the owned
launcher and operation-script PATH, including without an active foreground
handoff, while retaining the legacy non-Python tool search directories.
The private generic-Wine wrapper must capture that Python executable before
its own legacy PATH reset and use the captured absolute binary for the bridge;
merely prepending the native PATH does not qualify an unchanged old wrapper.
User modules are excluded; bytecode writes are disabled. The adapter
executes that exact binary with `-I -B`, because `-I` ignores the environment's
`PYTHONDONTWRITEBYTECODE` flag. No developer selection, Xcode license agreement
or account state is changed.

`tools/check_python_runtime.py` covers neutral extraction, inventory, link,
permission and input-pin failures without executing neutral code. Packaging
checks cover the integrated enabled-capsule/runtime/tamper boundary. Native
fixtures select an explicit owned interpreter wrapper and assert that it was
used, rather than accidentally passing through the old hardcoded system path.
Actual relocatable interpreter smoke/producer checks, exact-head native build,
signed actual-app admission, hardened-runtime/notarization and clean-Mac/game
qualification remain distinct evidence gates; none implies the others.

Runtime inventories expand final package receipts beyond the previous 64 KiB
ceiling. Preserved-CLI admission and final repinning now share the same bounded
4 MiB reader; exact external receipt digest/length, producer, profile, features
and signed CLI identity checks are unchanged. Neutral coverage includes a
runtime-sized receipt, tampering and an oversized otherwise-valid receipt.
The pinned CLI is copied byte-identically, not re-signed to evade reuse.

The first actual standalone producer suite passed functionally, but its test
helper's isolated child omitted `-B`, allowing four bytecode inventory changes.
That negative comparison is retained, not counted as seal preservation.
An independent read-only-resource probe then preserved its full inventory
through the same unchanged producer suite, standalone pinned-helper ctypes
configuration and a bounded consumer refusal. Its enclosing neutral app
resource signature remained valid after execution and rejected an intentional
owned stdlib-file mutation. No X Ode/game was launched by those probes.
They do not establish actual signed-X-Ode admission or gameplay.

**Historical foreground-candidate checks (`2bc5c6be`, before the catalog and
interpreter corrections):**

`swift build --jobs 4 --product XodusPreview` passed;
`swift run --skip-build XodusPreview --self-check` passed 193 checks;
`swift run --skip-build XodusPreview --live-check` passed 1224 checks,
zero failures. New checks execute the actual isolated adapter-command path with
an owned neutral process and typed kernel start identity, not a game or backend
registration. They cover private nonce/env arguments, stale PID, extra/duplicate
identity, oversized/error output, once-only dispatch, current-run replacement,
Stop/termination cancellation, active-donor loss and joined command retirement.
The real AppKit/window readiness path rejects the attested neutral sleep process
without a GUI. The successful request path is injected, so no activation is
performed or claimed. Absent/unsigned capsule admission is also exercised.

`XODUS_SHIPPING=1 swift build --jobs 4 --scratch-path .build/shipping -c release
--product XodusPreview` passed; `PYTHONDONTWRITEBYTECODE=1 python3
tools/check_shipping_pair.py` passed 38 checks, including nine new neutral
capsule admission/staging/tamper checks. `sh -n tools/build_app.sh` and
`git diff --check` passed. The C shim also passed
`xcrun clang -Wall -Wextra -Werror -fsyntax-only -I
Sources/XodusProcessIdentity/include Sources/XodusProcessIdentity/ProcessIdentity.c`.
The release executable rejected all six existing development arguments with
exit 64 and had no preview resource bundle. Full local shipping XCTest still requires unavailable
full Xcode; no substitute, waiver or remote CI run was performed.
Build/check logs are retained as `foreground-verified-*.log` in this source
session's artifacts. The release binary has no configured capsule and is only
an integration candidate. Parent-reported Wine broker/SDK association proofs
are separate from these source tests and from actual game foreground acceptance.

## XO-022 operation feedback ownership (source candidate)

Parent reproduced an earlier Minecraft Launcher preparation refusal appearing
in No Man's Sky detail on signed `784dedf`. This source lane did not repeat
the live observation or investigate the separate NMS SDK refusal.

The controller now retains the accepted feedback product ID through preparation,
terminal outcomes and restored operations, plus the direct-preparation owner.
Detail passes its exact product ID to the existing shared progress presentation.
Known unrelated progress, errors/notices and log/sign-in/recovery/cancellation
controls are filtered without navigation clearing retained feedback. Global
Library/Discover/Downloads presentation is unchanged. A new accepted action
resets the feedback bundle before assigning its owner; unknown corrupt-journal
storage errors remain global. Privacy and mutation/cancellation/Quit gates are
unchanged.

`swift build --jobs 4 --product XodusPreview` passed;
`swift run --skip-build XodusPreview --self-check` passed 193 checks;
`swift run --skip-build XodusPreview --live-check` passed 1170 checks, zero
failures. The synthetic game harness exercises failed A preparation then B
detail and return to A/global feedback, the exact code-11 recovery/log controls,
accepted B preparation resetting A's metadata, direct preparation/cancellation,
active download, terminal installation notice, restored known recovery and
unbound corrupt-journal recovery. It uses the actual shared presentation
properties/body, including detached native layout without showing a window;
it is not live signed-app navigation or AX acceptance.

`XODUS_SHIPPING=1 swift build --jobs 4 --scratch-path .build/shipping -c release
--product XodusPreview` passed. `PYTHONDONTWRITEBYTECODE=1 python3
tools/check_shipping_pair.py` passed 29 neutral admission checks;
the existing shipping-binary assertions also rejected all six development flags
with exit 64 and confirmed absence of the preview resource bundle.
`git diff --check` passed. Frozen `784dedf` retains its separate successful
full-Xcode CI run 39013367846; that evidence does not cover this new candidate.
Local full shipping XCTest still requires unavailable full Xcode and was not
replayed, substituted or weakened. No remote CI or push was performed here.

No ordinary app, real account/Keychain/network operation, signing/package/install
or installed runtime/broker/game mutation occurred. Parent owns signed-native
verification and eventual release admission; this repair does not claim a game
can download or launch.

### Reviewed-consent admission follow-up

Independent review found that reviewed A consent can survive a queued B
operation. On unchanged `94a1ea3` controller source, deterministic fixtures
reproduced both early confirmation failures: a removed A repair registration
and an occupied A installation destination. B actually ran through
`runQueuedOperation`, leaving a successful notice/log or a code-11 error/log.
The retained A consent then passed confirmation admission but its validation
error retained B's owner and metadata. The focused command
`swift run --skip-build XodusPreview --game-operation-check` produced
**357 checks, 8 failures** before the controller fix.

`confirmInstall` now resets the feedback bundle to `consent.game.id` immediately
after its existing admission guards, before either early validation error.
Rejected/protected calls and consumed-consent replays do not reset feedback.
Queue admission and mutation behavior are unchanged. Regression fixtures verify
both reachable failures, A/global error visibility, absence on B, removal of
B's stale notice/log/code, and feedback preservation while a mutation hold
rejects confirmation.

After this one-line controller correction, `swift build --jobs 4 --product
XodusPreview` passed; `swift run --skip-build XodusPreview
--game-operation-check` passed 357 checks; `swift run --skip-build XodusPreview
--self-check` passed 193 checks; and `swift run --skip-build XodusPreview
--live-check` passed 1191 checks, all zero failures.
`XODUS_SHIPPING=1 swift build --jobs 4 --scratch-path .build/shipping -c release
--product XodusPreview` passed; `PYTHONDONTWRITEBYTECODE=1 python3
tools/check_shipping_pair.py` passed 29 neutral admission checks;
`git diff --check` passed. Logs are retained as `xo022-consent-*.log` in the
source session's artifacts. These are synthetic controller/presentation
results, not signed-native acceptance. The local full-Xcode XCTest hold and
all source-only authorization boundaries above remain unchanged.

## XO-010 mandatory Welcome and normal Quit (2026-10-17)

Parent captured AppKit's **App termination blocked by modal sheet** log for a
signed candidate at Welcome; a bounded sample showed the normal event loop,
not a synchronous deadlock. A normal terminate request returning true did not
establish process exit. This lane did not repeat that live observation.

Only the mandatory `LiveRootView` welcome-sheet branch now attaches an existing-
style `NSViewRepresentable` bridge. Its actual native window sets documented
[`preventsApplicationTerminationWhenModal`](https://developer.apple.com/documentation/appkit/nswindow/preventsapplicationterminationwhenmodal)
to false while Welcome owns the bridge, so normal Quit can reach the existing
delegate/coordinator. Native view removal/window movement and SwiftUI dismantling
restore the previous value. The shared Account layout, normal Account and
installer/destructive modal policies are not globally relaxed. Mandatory login,
interactive-dismiss prevention, current-account/readiness and source-selection
gates remain; no sign-in or exit success is manufactured. The termination
delegate and operation/cancellation/Quit holds are unchanged.

`swift build --jobs 4 --product XodusPreview` passed.
`swift run --skip-build XodusPreview --self-check` passed 193 checks, including
four actual native-window bridge checks; `swift run --skip-build XodusPreview
--live-check` passed 1138 checks, all zero failures. The bridge fixture mounts
the actual SwiftUI representable inside an unshown `NSWindow`, checks its
window-attachment policy against an unrelated blocking window, and checks
removal/dismantling restore both originally blocking and nonblocking values.
Fixture windows are never shown and are closed/released before existing
no-window layout assertions. Synthetic live checks retain active-operation
Quit refusal, held cancellation, safe owned-child retirement and idle shutdown.

`XODUS_SHIPPING=1 swift build --jobs 4 --scratch-path .build/shipping -c release
--product XodusPreview` passed; `PYTHONDONTWRITEBYTECODE=1 python3
tools/check_shipping_pair.py` passed 29 neutral admission checks;
`git diff --check` passed. Full shipping XCTest remains a missing-full-Xcode
hold and was not replayed, replaced or waived.

This is native property/lifecycle harness evidence, **not** successful normal
Quit from a real signed SwiftUI sheet. Parent owns that acceptance after console
unlock. No ordinary app or real modal was presented, no termination request
was sent to another process, and no accounts/Keychain, installed runtime/broker,
games, signing/package/install or release actions occurred in this source lane.

## XO-018 saved game-service identity recovery (2026-10-17)

Parent observed a saved game-service sign-in with no account-binding file and
unavailable Profile/My Consoles, while Account said fully signed in. Source
permits that valid partial receipt but hid its only recovery action.

The shared service presentation now distinguishes saved-but-unverified sign-in
from an account-bound result in both Account summaries. Its explicit **Verify
game account** button uses the unchanged `signInForGames` controller and admitted
service script path. No verification runs merely from presentation or Check
status. Existing success/status checks, errors, retry, service/mutation/Quit
fences and Play eligibility remain unchanged. No account hash is synthesized,
no account identities are joined, and companion/stats ownership is not relaxed.

`swift build --jobs 4 --product XodusPreview` passed;
`swift run --skip-build XodusPreview --self-check` passed 189 checks and
`swift run --skip-build XodusPreview --live-check` passed 1138 checks, zero
failures. Synthetic fixtures cover signed-out, saved-unbound and bound receipts,
no automatic verification during status/layout, explicit verification failure,
visible retry, duplicate-action fencing and subsequent bound status. The actual
shared Account service view was laid out detached with its shared action title;
this is not live AX reachability evidence.

`XODUS_SHIPPING=1 swift build --jobs 4 --scratch-path .build/shipping -c release
--product XodusPreview` passed. `PYTHONDONTWRITEBYTECODE=1 python3
tools/check_shipping_pair.py` passed 29 neutral admission checks;
`git diff --check` passed. The missing full-Xcode/XCTest shipping gate remains
unchanged and was not rerun or substituted.

This lane did not inspect, edit or execute the installed management/service
scripts, touch real accounts/Keychain/network, launch an ordinary app or game,
sign/package/install or change installed runtime/broker state. Parent-reported
cached-session binding resolution remains installed-runtime evidence, not a
claim that synthetic source checks performed it. Locked-screen native
verification and eventual app/profile acceptance remain parent-owned.

## Welcome connection recovery and Account menu (2026-10-17)

The native application menu remains X Ode; only the extra menu containing
Account/Profile/Achievements/My Consoles/Engines is renamed **Account**, without
changing actions, shortcuts, gates or security identities.

Welcome now distinguishes a genuine startup/hello/connection failure after
validated helper/engine admission from missing or invalid pairing. The client
records the validation stage before starting its child; this historical evidence
changes recovery copy only, never current sign-in or readiness. Typed
`nativeAuthHostUnavailable`/`pairedEngineUnavailable` rejection still gives
fail-closed matching-pair guidance. Later connection failure offers plain retry
guidance and suggests normally closing another open X Ode copy. No stderr
parsing, process killing, polling, state/lock deletion or admission fallback is
introduced. Generation fencing prevents a stale failure from retiring a newer
connection.

Focused regressions use an actual admitted neutral helper plus the existing
management client/mock child: one hello protocol rejection then successful
retry/status, a process-start failure after validation, invalid-helper-hash
rejection before child startup, and unchanged missing-helper/status gates.
They test the same `prepareWelcome`/`welcomeMessage` path used by native Try
again. No helper fixture is executed and no real credentials are accessed.

`swift build --jobs 4 --product XodusPreview` and
`swift build --jobs 4 --product XodusManagementChecks` passed;
`swift run --skip-build XodusPreview --self-check` passed 189 checks;
`swift run --skip-build XodusPreview --live-check` passed 1132 checks; and
`swift run --skip-build XodusManagementChecks` passed 5637 checks, all with zero
failures. The shipping source build
`XODUS_SHIPPING=1 swift build --jobs 4 --scratch-path .build/shipping -c release
--product XodusPreview` passed, as did the 29 neutral checks from
`PYTHONDONTWRITEBYTECODE=1 python3 tools/check_shipping_pair.py`.

Parent-reported live evidence was separate: another app/CLI owned the management
lock, and normally closing that old app followed by Try again in the unchanged
signed candidate restored sign-in and the broker-backed collection. No exact
`StateLocked` wire frame was captured, so this correction neither asserts that
diagnosis nor depends on a particular backend code. This lane performed no
ordinary app launch, signing, package/install, real account/Keychain or installed
broker/runtime/game operation. Native menu/AX acceptance remains parent-owned.
The full shipping XCTest gate still requires unavailable full Xcode; it was not
rerun, substituted or weakened.

## Five freeze findings: source correction (2026-10-16)

The source-derived review of `8a6aa359` identified five defects, not five live
reproductions. The bounded correction keeps Discover's direct-install feedback
on the initiating route; preserves privacy-restricted operation status and
acknowledged cancellation while Welcome is locked; makes failed PC-library
broker presence checks retryable; describes registration as **Installed on this
Mac**, not readiness; and revalidates management account status on foreground.
Existing admission, account-identity separation and operation/Quit holds remain.

Commands and observed results on this CLT-only Mac:

- `swift build --jobs 4 --product XodusPreview`: passed.
- `swift build --jobs 4 --product XodusManagementChecks`: passed.
- `swift run --skip-build XodusPreview --self-check`: 189 checks, zero failures.
- `swift run --skip-build XodusPreview --live-check`: 1127 checks, zero failures.
- `swift run --skip-build XodusManagementChecks`: 5637 checks, zero failures.
- `XODUS_SHIPPING=1 swift build --jobs 4 --scratch-path .build/shipping -c release
  --product XodusPreview`: passed; the same shipping build for
  `--product XodusAuthHost` also passed.
- `PYTHONDONTWRITEBYTECODE=1 python3 tools/check_shipping_pair.py`: 29 neutral
  packaging admission checks, zero failures.
- The existing `tools/check_shipping.sh` Python assertions were run separately:
  all eight shipping argument rejections and both fixture-resource exclusions
  passed. This does not replace that script's unavailable XCTest gate.
- `plutil -lint tools/Info.plist` and `git diff --check`: passed.

Focused coverage includes unsupported/account/storage failures before transfer,
direct preparation and transfer cancellation with real synthetic script
settlement and no registration, shared feedback/redaction presentation and
detached Discover/Welcome layout, transient failure at each of the three broker
presence/metadata steps, retry/revisit recovery, no duplicate presence or
management status reads, rejected-pair no-fallback behavior, and foreground
failure/expiry relocking. Existing missing-launcher/package/runner checks remain.
Detached AX text and native-button-title experiments could not inspect these
SwiftUI controls reliably without a window; final checks instead exercise the
shared presentation actually consumed by the views, detached native layout,
and controller actions. Live AX visibility/reachability is still unverified.

No ordinary app instance was launched, and no real account, Keychain,
installed broker/runtime or game was used or changed. Shipping executables were invoked only with arguments
that must be rejected before application startup. No signing, packaging,
installation, push or publication occurred. The known missing-`XCTest` CLT
blocker was not rerun or weakened. Parent-owned installed-package qualification,
real account/pairing checks and live all-window/gameplay acceptance remain
separate; this source result grants no release or distribution approval.

## X Ode first-run correction: candidate (2026-10-16)

The live welcome gate uses current management account status, never a persisted
welcome-complete flag or installed-game records. Confirmed saved sign-in opens
the existing app; pending/cancelled/expired/failed/disconnected state hides game
content and blocks navigation/import/Settings game actions. A bound native helper
is additionally required to enable Welcome's sign-in button. Account status
rechecks retain a previously confirmed view while in flight, but failure removes
that confirmation. Missing pairing shows concise unavailable copy rather than
developer diagnostics. The official CodeWeavers trial URL appears only after
CrossOver detection reports absent/unverified. Native window/menu/About/Quit
display branding is X Ode; bundle, executable, Keychain and security identifiers
are preserved.

`swift build --jobs 4 --product XodusPreview` passed.
`swift run --skip-build XodusPreview --self-check` passed 189 checks and
`swift run --skip-build XodusPreview --live-check` passed 1075 checks, both
with zero failures. Regressions cover missing-helper/unchecked/expired/pending/
cancelled/completed/sign-out/disconnect/status-failure/status-retry transitions,
the exact trial URL and detection states, detached Light/Dark welcome layout,
and all three signed-out destinations with actual synthetic installed records
retained unchanged. No backend, credential, provider or installer operation
is performed by the detached layout checks; session checks use mock children.

`XODUS_SHIPPING=1 swift build --jobs 4 --scratch-path .build/shipping -c release
--product XodusPreview` passed. `python3 tools/check_shipping_pair.py` passed
29 neutral packaging admission checks; all eight existing shipping
argument-rejection and fixture-resource exclusion assertions passed separately.
`plutil -lint tools/Info.plist` and `git diff --check` passed. The known CLT-only
shipping XCTest failure below was not rerun or weakened.

No ordinary app instance was launched/replaced, no sign-in or Keychain operation
was performed, and nothing was signed, installed or published. Actual native
app-menu/first-run behavior, user authentication, the separate PC-library and
game-service identities, and product/gameplay/release acceptance remain parent
verification or live-evidence gates. This source gate does not join those
accounts or establish entitlement.

## Feature-freeze source stabilization: candidate (2026-10-16)

On Apple Silicon with CLT Swift 6.4 and the macOS 27 SDK, the existing
`sh tools/check.sh` baseline failed compiling the two `EnginesView` stored
properties: `@State` resolved to the SDK's `SwiftUIMacros.StateMacro`, whose
plugin is unavailable in CLT. A private alias to the existing `SwiftUI.State`
property wrapper disambiguates only those two properties; engine defaults,
bindings, persistence and admission policy are unchanged.

`swift build --jobs 4` and the normal build inside the corrected check script
passed. Both release shipping products compiled, and the existing neutral
signing policy and 29 portable packaging admission checks passed. The shipping
test step remains **blocked**: `swift test --scratch-path .build/shipping
-c release -Xswiftc -enable-testing --filter ShippingChecks` under
`XODUS_SHIPPING=1` cannot resolve `XCTest` in this CLT-only installation.
Full Xcode is unavailable; the shipping test gate was not weakened or replaced.
The script's eight shipping argument-rejection checks and fixture-resource
exclusions were executed separately and passed.

The remaining existing checks were run separately with
`swift run --skip-build`: `XodusFixtureChecks` (15), `XodusManagementChecks`
(5637), `XodusPreview --self-check` (179), `XodusPreview --live-check` (1056),
`XodusAuthHost --self-check` (152), and `XodusCredentialChecks --self-check`
(19). All passed with zero failures. Despite its name, this `--live-check`
uses mock children and synthetic scripts, not the production runtime.
Native-host checks use detached synthetic WebKit; credential checks do not
access Keychain. No real account request, game launch, packaging, installation,
signing or replacement of the already-open development app occurred.

This is source-build and offline regression evidence only. Independent parent
verification and the unavailable shipping XCTest gate remain outstanding;
backend provenance/pairing and public distribution holds remain unchanged.

## Native finish-script compatibility: candidate

The qualified notification-compatible app was installed with the unchanged
producer `72d3000c82258c6aadbb4f72b90c75da861da802`. Its one authorized attempt
produced a visibly stable owned Microsoft window. The user subsequently reported
completing browser sign-in, but the app reported failure. One explicitly authorized
idle-only account status refresh still showed no saved launcher sign-in and the
exact observation `Native sign-in failed: helper.javaScriptFailed.` No additional
sign-in, sign-out, credential deletion or human prompt action occurred.

Static comparison identified two concrete JavaScript differences from the
original handler: finish extraction required `ServerData.DAProperty` although
the original handler forwards `ServerData` directly, and context dispatch detached
the callback function from its original window receiver. Actual detached WebKit
regressions reproduced three failures on the preceding scripts: flat finish data,
flat finish data with extra provider fields, and a receiver-sensitive callback.
With the two script corrections the identical suite passed 146 checks with zero
failures, including malformed/missing-field/array finish negatives and the existing
origin, document, generation, notification and one-shot checks. No provider request
or visible test window occurred.

This reproduces source compatibility defects that yield the observed closed
failure, not proof of which JavaScript call failed in the real attempt. Only seven
required strings are projected to the unchanged private validator; trusted finish
path, callback arguments, origin/document gates and credential commit remain
unchanged. Fresh exact CI, reviewed source and a new signed pair are still required
before any further authorized live attempt. The installed app and user data remain
untouched by these neutral checks; successful launcher authentication is unproven.

## Native bridge notification compatibility: candidate

The qualified `5f7e408d297d4b9e1e09cb1dfaef603e9af0cb31` app paired with
producer `72d3000c82258c6aadbb4f72b90c75da861da802` was installed and opened.
One actual sign-in attempt produced the exact safe observation
`Native sign-in failed: helper.bridgeInvalid.` An owned helper window was briefly
observed, but stable visibility and successful login were not established.

Source comparison with the pinned original handler identified stricter Swift
notification handling: extra keys on the recognized context invoke and unrelated
notifications terminated the flow, whereas the original handler tolerates them.
The app-only correction projects provider DA extras to the unchanged seven-string
private value, accepts only the known context method, and ignores unrelated
notifications or untrusted-frame noise without authorizing data. Claimed malformed
DA and private wrapper/generation/document/one-shot gates remain fail-closed.
Focused neutral provider-style callback and noise checks precede fresh exact native
CI and a new source-matching signed pair with the same qualified producer inputs.
This source difference is not proof of the exact previous rejecting guard or of
successful real authentication. No UI redesign, Rust change or schema change is
part of this candidate.

Focused Mac validation passed 137 private native-host checks with zero failures,
including actual detached WebKit context callbacks, notification noise, subframe
noise, provider DA projection and stale control/document negatives. No provider
request or visible/active test window occurred. The nonshipping child check now
resolves its own executable through `proc_pidpath`, not SwiftPM's logical `argv[0]`;
the latter produced `NSCocoaErrorDomain:4` before browser checks on the local
SDK27 Swift run wrapper. Direct execution passed, and the exact normal Swift run
path passed after this test-only correction. Child budgets and production
ownership/termination behavior are unchanged.

## Native sign-in navigation correction: candidate

The user's reported briefly opened Microsoft window and the captured
`AUTH_INVALID / nativeSignIn / pipelineFailed` are actual failure evidence.
Bounded sampling that found no remaining helper does not establish no spawn.
The coarse tuple does not identify the failed internal step.

One scoped source correction separates permissive subframe/navigation handling
from unchanged private bridge/DA trust, routes trusted popups into the same view,
and ignores only cancellation or provisional WebKit policy interruption (102).
Neutral host checks cover each domain, deceptive suffixes/userinfo/HTTP/IDNA,
subframe routing, harmless blank/blocked popups, cancellation and actual
same-origin subframe bridge rejection. The consumer's compatible Details hook
accepts eleven exact closed producer messages and rejects extensions, arbitrary
text and mismatched failure tuples. UI redesign is paused separately.

Fresh source-bound native CI, new producer provenance and a newly signed paired
package are required. Historical `9be` qualification is not promotion of this
candidate; no new provider attempt or successful login is claimed here.

The initial correction `519e29db71ef184d325c40114f8f033f28ca1dc8`, tree
`5c71c4dc9ca16783400c5f06032c5eb820d979da`, passed exact normal-push
[run37353741110](https://github.com/dragoshont/xodus-macos-app/actions/runs/37353741110):
15 core / 358 management / 61 presentation / 237 native session / 115 private host /
27 shipping / 29 POSIX packaging, zero failures, all steps including SVG
reproduction. The tightly coupled popup follow-up additionally enables ordinary
scripted popup routing and preserves the existing control generation/one-shot
gate for provider-originated navigation. Actual neutral `window.open` blank and
same-document fragment checks exercise this delegate path and subsequent exact
DA handoff without a provider or external page request. That follow-up requires
its own fresh CI, not promotion of the initial run.

The popup follow-up `c232e7409fa416fb8165d41773a81933487b2da4`, tree
`d0885c2da92fd40a749d4e13a067bb1e37f79fd4`, passed exact normal-push
[run37354611053](https://github.com/dragoshont/xodus-macos-app/actions/runs/37354611053):
the same suites with 119 private-host checks, zero failures, all steps and SVG.
Actual neutral blank/fragment popup routing and subsequent seven-string DA handoff
passed. This is functional source evidence, not a successful provider login.

The next pairing-only candidate pins producer
`72d3000c82258c6aadbb4f72b90c75da861da802`, tree
`7597f4534f9ad909facba96bb6af2852a896668e`, in the existing packager and
compiled admission gate, with matching neutral shipping-test identities.
The predecessor `7543744` encountered a native test-only compiler error and
is not qualified. No unsigned artifact hash is invented or borrowed from `9ef`.
Packaging remains gated on focused native producer tests, its actual freshly
sealed Release CLI/provenance, independent external approval and this candidate's
own normal native CI. The private and management schemas and generated-pin recipe
remain unchanged.

## Shipping hardening candidate

Hardening ancestor `00ba51fd5e48f6298d27a56e75f491f6f697696f` passed its
own normal-push [run37314629896](https://github.com/dragoshont/xodus-macos-app/actions/runs/37314629896):
15 core/358 management/61 presentation/176 native session/87 private host,
23 shipping admission and22 portable packaging checks, zero failures, shipping
release compilation/argument/resource checks and SVG reproduction.
This is not qualification of the additive CrossOver-first successor.

## CrossOver-first source acceptance

`CrossOverDependencyChecks.run` exercises the actual detector/model and detached
native dependency view, with explicitly neutral signature observations and
an actually unsigned owned temporary bundle. No CrossOver process, license,
prefix, game or provider/account interaction is performed.

| Requirement | Named test coverage |
| --- | --- |
| RT-01 | `RT01 Apple Security parses the approved plain requirement`; fixed identifier/team/Apple anchor; distinct version/build; wrong signer/identifier; malformed/missing/oversized plist; actual static-code rejection; absent/linked app and metadata |
| RT-02 | `RT02 Verified official CrossOver defaults only the new provider`; absent/unverified no default; unverified planner has no child; post-Quit observation cannot adopt a provider |
| RT-03 | `RT03 A decoded explicit alternative survives startup and repeat refresh`; pre-ack planner has no child; unchanged observation preserves acceptance; engine/provider/custom graphics edits and changed/late evidence reset acknowledgement without rewriting explicit choices |
| RT-04 | `RT04 Shared dependency copy distinguishes app identity from license and gameplay evidence`; actual shared native view at440/560pt; first-release choice first/all alternatives Experimental |

`ShippingChecks.testShippingAdmission` additionally exercises unchecked initial
dependency state, verified-only default and acknowledgement invalidation in the
actual shipping compile. Existing planning cancellation/reap/Quit cases explicitly
acknowledge their neutral Experimental profiles, retaining their original owned
process lifecycle assertions. Fixture installation checks are disabled, and the
new neutral check source is excluded from shipping.

The successor requires its own isolated normal-push SDK27 qualification.
Approved official publisher baseline and real engine pure-plan/public query
observations are separate operator evidence, not synthetic test certification of
a deployed app, license, successful human sign-in or playable game.

CrossOver source `95af7c0e07d84ef85672d3d1ea184955f97536bf`, tree
`a407e75dc6b9ad7cb411d6ece87f3095518b1e1c`, passed exact normal-push
[run37318275541](https://github.com/dragoshont/xodus-macos-app/actions/runs/37318275541):
15 core/358 management/61 presentation/215 native session/87 private host,
27 shipping and22 portable packaging checks, zero failures, shipping release
compilation/argument/resource checks and SVG reproduction. Hosted Compute Agent,
Xcode27.0/build27A266a, SDK27.0; no shared-Mac hooks.

Its first isolated Mac package attempt built the release helper and separately
signed helper/engine, but stopped before launcher compilation: the Mac Python
does not support `Path.write_text(newline=...)`. The additive tooling correction
writes exact UTF-8/LF bytes and exercises the actual generator in portable checks,
rather than manually manufacturing its output. The failed stage is retained;
protected old26 files remain unchanged. A new candidate/package needs its own
qualification; no completed95af package, replacement or human sign-in is claimed.

Successorbc429's first hosted run37319757608 passed portable generation,
shipping/build/model checks and all new runtime acceptance cases, but failed
the existing combined short-exit-observation assertion (215 native checks/1
failure). That test raced caller admission against a200ms observation and a
1.4s child-exit sleep. The additive neutral-only correction gates the short
observation until all four actual disconnect waiters have entered, and holds
the owned child after EOF until an explicit test release. Separate assertions
retain every original result/coalescence/failure/ownership requirement.
The waiter-count accessor is nonshipping only; production lifecycle, shutdown
budgets and escalation behavior are unchanged. No retry qualifies the failed
run; the corrected source needs a fresh normal-push result.

Source2aaba passed exact SDK27 run37321076993: 15/358/61/218/87 original
and expanded suites,27 shipping and23 portable checks, zero failures/SVG.
Its new isolated Mac package compiled both shipping release executables and
passed signing/deep signature/plist, then correctly stopped final verification
because that tool assumed flat SwiftPM resources. The Mac toolchain emits the
native bundle's `Contents/Resources` layout. The additive verifier accepts exactly
one of those two known layouts with the same required schema hashes/owned-file
validation, rejects mixed/duplicate resources and tests native-layout tampering.
It does not flatten resources or change the management/runtime contracts.
The failed stage/old installed app remain preserved; no completed package or
human login is inferred from a successful compile or signature check.

## Shipping hardening scope

The adversarial841 review required compile-time shipping/demo separation,
removal of synthetic live heroes, paired-engine admission rather than helper-only
trust, catalog-loading precedence and startup-query revision fencing.
`XODUS_SHIPPING=1` now excludes fixture views/state/resources and check entrypoints.
The interactive live-to-preview Settings transition is removed, making the
independent-planning preview-transition hazard unreachable without a new mode API.
See [controlled local admission](SHIPPING-ADMISSION.md) for the approved pin
generation and external operator trust chain; no generated artifact pins are
committed.

This candidate must pass its own normal-push SDK27 native/nonshipping checks,
shipping release compilation, actual rejected-entrypoint processes, owned-neutral
shipping admission checks and strict portable packaging negatives. No previous689
result qualifies it. No new Mac artifact, package, provider attempt, account
status, Keychain interaction or gameplay result is claimed by source qualification.

## Freshness-aware live account presentation

Source inspection found that a failed status read disabled account mutations
but still displayed a retained saved/expired snapshot as current in several
views. Shared `LiveSession` presentation now gates the profile symbol, label,
explanation and Library empty state on fresh account evidence. The retained
snapshot and pending cancellation/dismissal fences remain intact. Pending
copy does not assert an observed Microsoft window or classify an MFA step.

Targeted neutral checks use the actual LiveSession coordinator and a synthetic
saved-profile/status-unavailable/fresh-recovery child, plus the existing
expired, preparation-failure, pending, cancellation and transient-pending
scenarios. The saved recovery trace must contain only requested `auth.status`
reads, no auth mutation. Fixture/live separation and unavailable ownership,
installation and gameplay remain unchanged. No shared Mac, provider, Keychain
or human window is used by these checks; this revision needs its own isolated
normal-push SDK27 compile/regression result, not inherited674 evidence.

## Additive native-helper preflight correction

Windows source inspection found that a packaged app missing both the helper
and receipt could silently omit its binding. The additive correction rejects
that case before starting management, preserves nil binding for unpackaged
anonymous checks and gives invalid helper admission a static actionable error.
Neutral checks cover both missing, receipt-only, helper-only, canonical/invalid
metadata, invalid helper before engine launch and clean failed-preflight shutdown.
No helper/engine fixture is executed by the new preflight checks.

Exact source `6a2103cfd0e2d263918039122990ac9492ec17f3`,
tree `797e111744d180b345542380229d6fb9367e7e6b`, passed its own normal-push
[run37226882643](https://github.com/dragoshont/xodus-macos-app/actions/runs/37226882643):
Xcode27.0/27A266a, SDK27.0/macOS27.0, **674 checks**, zero failures
(15 core +358 management +60 presentation +154 mock session +87 private host)
and SVG reproducibility. Parent independently verified that evidence and SAME
review turn17 closed the scoped43-to6a source correction. The earlier668 result
was not reused to qualify6a. The existing normal-push workflow
is GitHub-hosted: the prior exact43 run's job reports runner group `GitHub Actions`
and `Hosted Compute Agent`, image `xcode-27-arm64`. Its checked-in steps run
local Python/Swift neutral checks and SVG reproducibility, with no SSH, deployment
or shared-Mac hook. No new workflow or manual dispatch is needed.

Engine source admission remains an independent manual release gate, not a
HELLO/helper-receipt inference. No new943/9ef CLI seal or versioned engine
provenance format is created by this correction. No shared-Mac action, current
pair mutation, provider/account request, signing, packaging or live-auth claim
is part of this source qualification.

## Separate four-provider native configuration and pure-plan consumption

### Canonical quit-lifetime correction

Retained review found a real source blocker in747: normal app termination
awaited management disconnect but not the independently owned runtime-plan
task. With no management connection, Quit could orphan that planning child.
`PreviewDelegate` now uses the shared `ApplicationTerminationCoordinator`,
which fences new planning/connect requests, cancels and joins the active plan
through bounded owned-child cleanup/reap, and composes that result with existing
management disconnect. Quit is permitted only when both succeed. A failed
shutdown retains ownership, surfaces an error, refuses Quit and supports a
bounded retry; no stale plan is adopted while terminating.

The actual normal coordinator, not just manual task cancellation, is exercised
against neutral owned children: zero management connection, pending plan,
SIGTERM ignored and escalated to SIGKILL, concurrent/repeated Quit, prior
cancellation/failure, explicit management-shutdown refusal and retry. No
NSApplication termination event/window or real engine is used by these checks.

New owned stage `app-runtime-quit-final-aJUrSa` is assembled from immutable Git
tree blobs, not a Windows working-tree tar. All58 Package/Sources/Tests inputs,
including raw binary resources, match exact Git blob identities before and
after compilation/checks, with no line-ending normalization in that comparison.
Raw SHA256 input manifest:
`e37b63af4b71265291c4b790739390e125dec10e9c537b797f4cc6f6bc267b0a`.
SDK27.0 / Swift6.4 arm64 native RELEASE build takes50.72 seconds. One full
bounded suite passes **668 checks**, zero failures:
15 core +352 management +60 presentation +154 mock session +87 private host.
Launcher SHA256:
`5505dd7e6cab234198eee16a1e612859c23a05b5ed01bb2c94c5a799ffcb7186`;
host SHA256:
`063d0fe5aafc34c71e71110e22ff8180f8be0f38fb60affaa7fbe3c505021b6d`.
All28 protected public artifact/resource hashes remain unchanged. Auth-host,
binding, header and C95 contract sources/policies are unchanged; only the
normal app-lifetime fence is composed with existing management shutdown.
This is source/headless evidence, not a live Quit, provider/authentication,
biometric, visual, packaging or deployment result. Retained same-context
source review remains a separate gate.

### Historical intermediate staging and independent hosted evidence

The earlier `app-runtime-providers-Pb0cum` transfer retained38 Swift/Package
CRLF inputs plus the artwork provenance JSON. Its56-input manifest compared
LF-normalized text, not literal compiled Git bytes. Those earlier658 runs and
3a7e/655e/8e0b executable hashes are **local intermediate-stage evidence**, not
exact-f6 Git qualification. This distinction is not retrofitted into their
original manifests. Stage `app-runtime-finalgit-owjAT2` subsequently assembled
literal Git747 bytes, verified all56 raw inputs before/after, and independently
passed658; that was before the new Quit correction and cannot qualify it.
Both earlier stages are preserved.

Exact f6 normal-push
[run37211014588](https://github.com/dragoshont/xodus-macos-app/actions/runs/37211014588)
passed actual Xcode27.0 build27A266a, SDK27.0, macOS27.0 and658/0 plus SVG
reproducibility. Exact747
[run37211343959](https://github.com/dragoshont/xodus-macos-app/actions/runs/37211343959)
also passed the same SDK/runtime and658/0/SVG, independently verified by the
parent from metadata and the public log. Neither hosted result qualifies the
subsequent Quit correction; its normal-push run needs separate qualification.

### Provider selection and strict pure-plan behavior

The source revision following auth correction619 adds selectable Apple GPTK3,
GPTK4, legitimately user-installed/licensed CrossOver and standalone/source-built
Wine to the shared native Settings Form. Initial selection is nil. Provider,
engine and graphics metadata are independently declared; required nullable
keys are present as JSON null, not omitted or populated with guessed versions.
The canonical source producer is
`9ef0f298481fb48840734b538e0f6d22e1c98ff3`, separate from auth producer943.

A new owned isolated stage, `app-runtime-providers-Pb0cum`, builds native
release source. All **658 checks pass**, zero failures:
15 core +352 management +60 presentation +144 mock session +87 private host.
The85 new/extended management checks include actual canonical four-preset
outgoing key/null parity, five positive configurations/four invalid configurations,
required-null omission, independent component/configuration identity, schema
conditional provenance, exact echo/path/generation correlation, evidence
promotion, extra/duplicate/escaped-duplicate/wrong-type/oversized/truncated/
multiple/nonUTF8 responses, invalid metadata and actual mock subprocesses.
Neutral child processes validate actual stdin plus explicit EOF, return fresh
generations, exercise unavailable old engines and valid-looking nonzero exits,
bounded stderr, signals, deadline escalation and cancellation/reaping. They
never execute a runtime/provider or invoke authentication. Ten additional
detached native checks exercise selection/binding/clearing and constrained
Form allocation, not screenshots, VoiceOver or live visual conformance.

The isolated launcher SHA256 is
`655e837b8d38760c71921f3cd0bbf0b1667ad98ffde94c31661e39c22a08fc14`;
host SHA256 is
`8e0b55a2bcc8bde04bb72fe0319c64959cabc2e011f653feb718c7352c26d696`.
The reviewed auth-host source has no diff from619; stage executable hashes are
not evidence of packaging or deployment. All56 Package/Sources/Tests compiler,
resource and fixture inputs match the local source after LF normalization; the
input manifest SHA256 is
`e40d814ece271ee6cc88d5d42cecf956ba2cfa9de43e314ce66385e97dd786f0`.
An additive one-string follow-up to `f6a8ad0` says "Installation not inspected",
not "Not installed": uninspected user-installed CrossOver must not be declared
absent. The unchanged full658 suite also passes this final source.
All28 protected public files match
before/after, including deployed97e launcher, signed4d04/unsigned304 engines,
adjacent provenance, original releaseac497, bundled resources/signature files
and the untouched anonymous preview1a1. No signing, packaging, desktop action,
reference capture, provider/runtime/game inspection, Keychain/status query or
production-engine invocation occurred. Runtime installation/inspection, device
preflight, per-game results, launch, license/distribution and save lifecycle are
still separate unfulfilled gates. Hosted evidence for619 does not qualify this
new provider revision; its publication needs its own automatic normal-push run.

## Reviewed opaque-ticket correction and protected human handoff

The twenty-one-pair diagnostics-only pairing used producer
`baf92bc204755a12d956dca657b7e45989ec6991` and consumer
`e5a573aaca94f4cee46f591f9f927fcd0df0f782`. Its unsigned input SHA256 was
`542e855cd2e2131b391f772590a16dfc8f22704243c9c0b4bcea419510599846`.
One authorized native entry returned
`AUTH_INVALID/devicePreparation/tokenCipherEncodingInvalid`; no owned native
authentication window was observed. Those diagnostics did not repair admission.

Source tracing then established that the original Passport request builders
forward the issuer's opaque ticket rather than locally decode its CipherValue;
the separate BinarySecret proof key supplies cryptographic proof. Reviewed
producer `e7e61fa820b771099fd90516ccaca056f265966d` removes only the unsupported
opaque-ticket decoding predicate. Two actual native regressions failed on the
preceding source and passed through the corrected managed-memory/request-builder
paths; 59 selected native checks passed in one bounded run. The exact combined
source review closed with unchanged consumer e5a. This is an admission correction,
not an inferred provider format or a change to separate proof/SOAP cryptography.

The immutable unsigned arm64 engine is 79,399,000 bytes, SHA256
`304c249ae24fc187533865ebb3d61cd40cec812629c537692e009f54bec22349`;
adjacent provenance SHA256 is
`647094684c9f90d50d30a6cf911baa5d3c4d9bdeb50b056f67f8a4a79e272bb5`.
Separate signed engine SHA256 is
`4d04fd6c98478574f8b0413de3a2422cebf66dce9c72357629c38cf02e2dbf32`;
app executable SHA256 is
`97e423985d1e5193db2cd80b6f2aa9ce546cc167d91ec2337a4653f3dc0bfabe`.
The Swift app reused the native release stage SHA256
`ac497495e1b300cae750ffb89f9470ecd29727c80982366e2a93fa4ffad8f280`.
The engine is offline/locked default-dev, not a Rust release. Original artifacts
and old bundles were preserved. C95 resources, arm64/plist/deep signature and
nine bounded anonymous-only readiness assertions passed; those assertions did
not call account status or prove a new full contract-corpus run.

After a fresh owned idle transition, one owned native authentication window
was observed on this new pair. The flow was active before the agent's next
Sign in guard; that guard refused before AXPress. Activation source is unknown,
agent Sign in presses for this engine were zero, and no duplicate entry was sent.
Window presence gets past the earlier pre-window blocker but is **not successful
authentication or credential commit**. Human completion remains unverified.
No provider page, credentials, code or OS approval was inspected or automated.
The observed flow was preserved without agent polling, focus, restart or retry.
Authentication is now user-paused; current window/worker presence is not
re-inspected or inferred.

## Paired-review host corrections: separate source evidence

Retained paired review withheld closure on consumer `ced5ff9` for two actual
host defects: its notification parser rejected the inherited flat seven-field
DA object, and continuation readiness could race an outstanding detached DA
writer after its complete frame reached the worker. The preceding 548 checks
and hosted pass did not cover or prove these paths correct.

The flat object now goes through the existing exact-seven-string `LegacyDA`
decoder before the invoke branch. Missing, nonstring and extra fields remain
failures; wrapped notifications and opaque context callbacks remain supported.
A pure native regression compiled from exact ced5 Git blobs returned expected
failure exit 1 for a synthetic flat notification. The identical regression
against corrected source passes. Actual detached WebKit notification fixtures
also pass the flat-positive and three malformed/type/extra-negative cases,
without a finish-page extraction fallback or any provider contact.

Continuation readiness and closed acknowledgement share the outstanding-output
drain and recorded-write-failure fence. A deterministic anonymous-channel test
holds completion after every DA byte reaches its peer, reproduces the unfenced
`protocolInvalid` overlap, then proves the shared production fence waits and
orders readiness after completion. A failed writer cannot promote readiness or
closed acknowledgement. The internal scheduling hook is absent from normal
calls and does not change framing or the private contract.

The corrected executable suite passes **562 checks**, zero failures:
14 core + 267 management + 50 presentation + 144 mock session + **87 private
host**. The new isolated native release stage's first complete build took
55.25 seconds. Its host SHA256 is
`8864a15a3512dc3882a7ea850bc367515c7d43cb23c29cecd6be89924b2b1fe3`;
launcher SHA256 is
`5977b420855ddea7aef63096cfb3e47dbd3741887f3ac2589754bc36e6308fcf`.
Header source is unchanged by Git comparison; these are separate-stage
executable hashes, not evidence of a deployed UI change.
All 24 protected public artifact/resource hashes and the original anonymous
preview executable match after validation.
Provider configuration groundwork is kept in a separate stash, not this
review delta. C95, twenty-one diagnostics, private schema/fixture, crypto,
production URL/client/UA/header policy and header source remain unchanged.
Current deployed artifacts and the old anonymous preview are not modified.
No signing, packaging, deployment, GUI action, credential/Keychain/provider
operation or authentication-success claim is included. Retained SAME review
turn10 closed both surgical corrections against unchanged auth producer943,
with no significant new source regression. The exact619 normal-push hosted
[run37208819522](https://github.com/dragoshont/xodus-macos-app/actions/runs/37208819522)
also succeeded on actual Xcode27.0 build27A266a, SDK27.0 and macOS27.0:
14+267+50+144+87=562, zero failures, plus SVG reproducibility. The parent
independently retrieved metadata and the full public log. These are source/
headless qualifications, not live authentication, biometric or deployment GO.

## Consolidated native header and Swift authentication host: source-only evidence

A bounded source audit confirmed actual AppKit/SwiftUI framework links and
deployed Mach-O SDK 27 / minimum macOS 14. It did not inspect window pixels or
claim that the old window overrides disabled Liquid Glass. The following source
correction groups stock scoped search and native navigation in the toolbar,
extends original artwork under chrome, hides the visible title, makes Account
body/footer adaptive, removes unconditional legacy activation and leaves
window setup to the Scene.
Routing, artwork, authentication predicates/IDs/lifecycle, C95 and the exact
twenty-one diagnostic mappings are unchanged.

Validation uses detached native controls and synthetic offscreen Account
layout, never the running application or Account refresh task. The release
build goes to a new owned scratch directory, not `dist` or the preserved ac497
stage. No signing, packaging, deployment, production app launch or live visual
confirmation is included in this consolidated validation.

An earlier pre-header source snapshot built with SDK 27.0 / Swift 6.4 and passed
**537 checks** (14 core + 262 management + 45 presentation + 144 native session +
72 private host). It is not proof for the subsequent header delta.

The consolidated source passes **548 checks** (14 core + 267 management +
50 presentation + 144 native session + 73 private host), zero failures, in an
isolated native release stage. Search checks cover stock bezel/search/cancel,
edit/clear binding, duplicate-notification fencing, disabled/focus semantics and
actual detached 32/220 pt native field geometry. Synthetic long/pending/error
Account layouts keep a single stable footer inside constrained bounds and
outside the scroll view. Native session checks use mock children only.

The arm64 Swift release executable SHA256 values are
`9ec534f589f529414de7583d458c77b40bb46b43c1556d9c4f9d5155e42e40e9`
for the launcher and
`9fe1eed545c296982d56db2b767df737b5d998748cc154d27eeb7f9b45268f68`
for the host. The final incremental host build took 3.18 seconds; the preceding
header rebuild took 14.30 seconds. The native SwiftPM builder emits its documented
deprecation warning. These are build-stage executables, not signed/deployed
application-pair evidence.

Helper tests cover strict JSON/framing/ordering/correlation, original-budget
expiry, unchanged legacy constants and verbatim seven strings, anonymous
socket framing/EOF, oversized output rejection without state promotion,
validated continuations/close dispositions, and detached neutral WebKit
callbacks, stale/duplicate messages, checked JS, popups, renderer/navigation and
close cancellation. Tests set their own activation policy to prohibited and
show no window; WebKit may allocate a hidden system window. They neither
capture/inspect a running application nor contact Microsoft/Keychain.
The production close path additionally waits for an in-flight DA write before
acknowledgement and cannot hide its failure behind a clean exit; production
helper/worker completion races still require the paired neutral Rust gates.

A neutral bundle fixture exposed Foundation resource URLs retaining a base URL
that differed in URL-object equality despite the same canonical filesystem path.
The metadata gate now compares canonical/resolved paths while retaining
no-follow regular-file, ownership, link, mode, bounded-size and stable-read
checks. Valid fixed-path metadata and duplicate/extra/incomplete/FIFO failures
are covered. Shell syntax passes without executing packaging.

All 24 curated public protected artifact/resource hashes match before/after,
and the already-running anonymous preview executable retains SHA256
`1a1eedf983c2d1349e8e3e05ccd923ba426365815c755e6fbce64404491ca9a0`.
No current bundle, signed engine, unsigned producer or preserved release stage
was modified. Private host schema/fixture pins are recorded in
[native integration](NATIVE-INTEGRATION.md); C95 bytes are unchanged.

The header follows an actually inspected, explicitly authorized historical
private Apple Games reference. A fresh single-window capture failed; a single
alternative stopped before enumeration/capture at false existing-permission
preflight, without requesting permission. There is **no fresh captured
reference**. Natural artwork-dependent toolbar tint, actual compositor geometry,
VoiceOver/focus/resize and minimum-runtime behavior remain live gates.
The existing hosted job now selects the preview `xcode-27` runner and asserts
actual SDK/runtime; hosted results must be established for the frozen commit,
not inferred from local proof or workflow configuration.

The user's game work has exclusive desktop priority. Further launcher/reference
focus, input, capture, window inspection, activation and preview cleanup are
paused. Existing preview closure is not inferred. Authentication and deployment
are also paused. The helper still requires paired Rust lifecycle tests and
combined source review; this is neither passkey support nor authenticated/
committed account evidence.

## Historical agreed minimal cipher subsites: source-only checks

The coordinator approved and the sole app explicitly agreed with the producer
before implementation to only `tokenXmlBoundInvalid`, `tokenXmlParseInvalid`
and `tokenCipherEncodingInvalid`. The exact twenty-one-reason set preserves
all eighteen older pairs and coarse `tokenCipherInvalid`; AUTH_INVALID-only
gating, exact three string keys and C95 bytes remain unchanged. Local copy
reports a supported processing limit, unreadable required format or
unprocessable encoding, never a numeric bound, data or an assumed cause.

One isolated one-job/index-disabled native build succeeded in 11.18 seconds.
The complete executable suite passed **440 checks** (14 core + 255 management +
27 presentation + 144 native), zero failures. Every reason passed schema/decode
and exact round trip. Per-reason rejection checks discard secret extra keys,
unknown reason/category, mismatched stage, malformed type, missing stage and
cancellation/expiry/non-AUTH details. The three new subsites additionally passed
27 actual mock-child presentation rejection cases and three honest local-copy
checks. Invalid diagnostics never become a preparation stage or entitlement
authority; the known preparation title remains visible without deletion advice.

This is a diagnostic refinement, **not an acceptance fix or live-cause proof**.
No layout/navigation, account lifecycle, provider request, actual sign-in or
bundle change occurred. Build/check temporary logs were cleaned. The deployed
b168 app, separately signed 125a engine and original unsigned 8a4b input below
were independently hashed unchanged after the suite. This source delta still
requires the same combined continuity review, producer native gates and a new
immutable engine before pairing/retest. User-directed UI auditing remains
deferred until authentication reaches its genuine owned-window/human gate.

## Reviewed eighteen-pair deployment and observed cipher failure

The same continuity reviewer closed producer
`bace09c` -> `2acb452a7ee66b2c9d3ad75ecf85e2be2f94fbc3` and consumer
`da0adc0` -> `5ae30fd4bd4e17cb235857e5c41fba1627c317f7` with no significant
issues. Producer native evidence recorded 54 passing checks. Exact consumer
source independently passed **398 checks** plus SVG verification in
[hosted run 37193138334](https://github.com/dragoshont/xodus-macos-app/actions/runs/37193138334).

The immutable arm64 CLI is `xodus-cli-xml-proof-v1-8a4b8d56aad18841`,
79,399,592 bytes, mode 0500, SHA256
`8a4b8d56aad18841326834e5ad57860072560f4739963323875ffa52d41a545b`.
Mode-0400 provenance is 8,666 bytes, SHA256
`2d7b372e3df8030ade83952d35f73f6cae74cf61075082ddd9aabd08c62438a6`.
Its mode-0400 public LF source archive is 5,130,240 bytes, SHA256
`9d1366907990d156d540c65be4ab7335ce5fae2ee1acc92d1e11bfeec9f583b0`;
mode-0400 native evidence SHA256 is
`773767f6f288519033abf57802dedf57a1bf1343949e1c48d2eab9c03654fa01`.
Hashes, sizes/modes, source pin, native features and absence of plaintext features
were verified before transition. No sealed original was signed or modified.

Fresh exact-owned app 18444 / child 18448 had enabled terminal Account controls,
zero pending Cancel/progress/auth children and no conflicting window. Account
closed and the owned pair exited through graceful quit, with no signals or
other-window actions. The reviewed app release built in 10.26 seconds and passed
27 presentation checks and nine actual signed read-only checks. C95 resources,
plist, deep strict signature and arm64 architecture matched. The separate
signed embedded CLI SHA256 is
`125a05dd0a2a577cc8fc71e4d3eaf324b9c70b3d409a54fd5b0eeef17ad45cf4`;
app executable SHA256 is
`b168a78e42bffc40bbb8e65379a3b117734939b4c2b4926f6aac06746e199607`.
The old bundle and unsigned inputs were preserved; probe/build temporary files
were cleaned. Fresh LaunchServices ownership was app 41090 / engine 41093,
exact parent 41090. A transient Account-readiness guard refused before any auth
entry; later unique enabled native controls were verified without a status requery.

One authorized native Sign in AXPress returned
**`AUTH_INVALID/devicePreparation/tokenCipherInvalid`**. Pending Cancel controls,
progress indicators and owned auth children were zero; an owned native
authentication window was not observed. This is the new reviewed pair's result,
not the older 342/5d attempt. It was immediately routed to the coordinator and
sole backend. No raw provider data, page/title, credentials, approval or
forensic status request was read or automated. The specific grouped guard and
live whitespace cause remain unknown. The unchanged failing pair is retained,
not blindly retried; UI auditing/correction is deferred until authentication's
genuine owned-window/human gate.

## Historical eighteen-pair source-only checks

The coordinator approved, and the sole app explicitly agreed directly with
the producer before implementation, four additive `devicePreparation` reasons:
`tokenKindInvalid`, `tokenAudienceInvalid`, `tokenCipherInvalid` and
`tokenSecretInvalid`. All fourteen older pairs remain accepted, including
`tokenStructureInvalid`; there are exactly eighteen reasons, still restricted
to `AUTH_INVALID` and the exact three string keys. C95 source/resource hashes
remain unchanged.

An isolated one-job/index-disabled native build succeeded in 11.56 seconds.
The complete executable suite passed **398 checks** (14 core + 246 management +
27 presentation + 111 native), zero failures. Management checks cover the exact
eighteen-reason set, every pair's schema/decode/round trip, and discarded
unknown/extra-secret/mismatched-category/stage/type/missing/non-AUTH details.
Native checks exercise the four honest local explanations and 24 additional
actual mock-child cases: each new subsite with extra-secret, unknown-reason,
wrong-stage, cancellation, expiry and non-AUTH error metadata. No malformed
diagnostic survives as stage evidence, raw wording or entitlement authority.
The visible device-preparation title remains unchanged.

These are **source-only, mock-child regressions**, not new provider observations.
No Keychain/Microsoft operation, live Account action, bundle replacement,
navigation polish or authentication retry occurred. Build/check temporary logs
were removed after their results were captured. The running reviewed da0/bace
pair remained unchanged during that source-only phase. The later reviewed
deployment is recorded above. This source evidence does not establish that the
live proof contains whitespace or retrospectively choose a narrower cause.

## Reviewed native-toolbar pair and latest observed retry

The same continuity review closed app
`da0adc00d337ba27c914f5e47ce3c2b11b8000de` against `360e8bf` and producer
`bace09c1be95ff35864b8c8593b974b2aeee934f` against `e60481f`, with no significant
issues. Exact app source independently passed
[hosted run 37191128180](https://github.com/dragoshont/xodus-macos-app/actions/runs/37191128180):
**14 core + 233 management + 27 presentation + 79 native = 353 checks**,
zero failures, plus SVG verification. This clears the source-validation hold
described below; it does not erase the earlier incomplete local run.
The producer separately passed 45 actual native checks and its qualified
lint/check/format/contract gates before its immutable build.

The preserved unsigned CLI is `xodus-cli-device-proof-v1-34214ee29b3582a6`,
79,387,096 bytes, mode 0500, SHA256
`34214ee29b3582a6d146ccd029991a70949514c58bcaa99f834db930d41e96ca`.
Its adjacent mode-0400 provenance SHA256 is
`4367686f926c205e5c51df1720d0e66a1ca6eee4e4e018f4b0247993ac3510c2`;
the mode-0400 native-validation record SHA256 is
`8b4c362d245daa3dda48c08ceff6a19231b95f6aa5b89ba8ffc2f24000d4f71d`.
These originals remained unchanged. The separately signed embedded engine is
`5d6bb07936559ea44a0fd81ad96ed7e118bf6346d8d09a83f8212a543ee1329a`;
the app executable is
`fa0cd48221b260f00eb3603f432ebbf07b114e48b57bde394c9076b92853b9da`.
The previous 47f/c50a bundle and older artifacts were preserved.

Before transition, fresh exact-owned path/hash/parent and local Account checks
found no pending Cancel control or auth child and enabled Close/Sign in controls.
The old app 92655 / engine 92660 then exited through graceful owned-app quit,
without signals or action on another window. The new release built successfully
in 9.85 seconds, passed 27 presentation checks and **nine actual signed read-only
checks**, and matched public source inputs, C95 resource, plist and deep signature.
Fresh ownership was app 18444 / embedded engine 18448 with exact parent 18444.
Native AX observed three system navigation radio buttons and the Account button.
These PIDs are observations at deployment, not reusable future ownership proof.

One newly user-authorized native Sign in AXPress returned
**`AUTH_INVALID/devicePreparation/tokenStructureInvalid`**. Account visibly
reported **"Microsoft sign-in could not start."** Pending Cancel controls and
owned auth children were both zero at observation; presence of an owned native
authentication window was **not observed**. This is an unsuccessful attempt,
not saved Store-user credentials, consent, ownership or a completed journey.
The static reason groups unsupported token/proof structure checks; the particular
legacy-token, STS-key, cipher-encoding or secret-shape guard is not established
by this observation. No raw token/XML/HTTP/message, credentials, provider page
or OS approval was read or automated. The precise tuple was routed to the sole
backend for public-source diagnosis; the unchanged failing pair is not blindly
retried. A further fix requires coordinated source review and verified pairing
before another agent-mediated entry.

## Reviewed diagnostic pair and observed retry

Source review closed app `f680410` -> `360e8bf3a2eb7efc087ccce2ed4d2bf93fc16369`
and producer `232a4a82` -> `e60481fc918b4cc2cc599a5db2aba17a04738872`
with no significant issues. Historical R01-R19 closures are preserved.
The cancelled original reviewer provided no report 40/41 approval.
Final `360e8bf` passed **333 full checks** and hosted run
[37189001182](https://github.com/dragoshont/xodus-macos-app/actions/runs/37189001182).

The e604 immutable CLI is 79,687,480 bytes, mode 0500, SHA256
`47fab28009f9c6c52294095e5684bfce3f86f45e50ddc98655d2b22150f02c8d`.
Its adjacent mode-0400 provenance SHA256 is
`02c9710e56713dedfc80b144dad4f86d5e34903d6a5201e9778836c6b2a4f762`.
Both were independently verified before embedding; the original stayed unchanged.
The separate signed engine SHA256 is
`c50a98b3e0afe4ba6a9b883e6f09ef194b481817eea94f5db190fb2123aceaa8`;
the app executable SHA256 is
`3858dd0fb32370c5ef0b92a866f11a6225d31edc208512b7283381d2a583915e`.
All 66 public build inputs matched reviewed Git blobs, allowing only Windows
text CRLF/LF equivalence. C95 source/resource/embedded bytes, plist and deep
signature matched. The previous signed-7a6e bundle was preserved.
The release passed 24 presentation and 74 mock-native checks; the signed pair
passed **nine actual read-only checks**, without beginning authentication or
performing catalog network queries.

Fresh ownership was app 92655 / engine 92660, exact embedded path and parent.
The old 79003 / 79007 pair exited through graceful owned-app quit after its
Account sheet had already closed; no signal or other-window action was used.
A fresh enabled native Account AXPress was activated once as newly directed.
The app reported only the closed static tuple
`AUTH_INVALID/devicePreparation/providerProofInvalid`, with the authored
failed-flow label, zero pending Cancel controls and zero owned auth children at
observation. The legacy reason is **not necessarily a cryptographic failure**.
Deeper live cause remains unproven. No provider page, credentials, code, raw
message, approval or OS decision was read or automated.

## System toolbar and device-proof refinement source evidence

The user rejected the bespoke rounded menu. The source correction uses real
macOS `ToolbarItem`/segmented `Picker`, a native Account button and macOS 26+
`ToolbarSpacer`, retaining routes, scope-reset behavior and original artwork.
The earlier candidate passed 27 presentation / 75 mock-native checks. Its
offline fixture-only AX pass confirmed native `AXRadioButton` mouse selection
for all three destinations, Command-1/2/3 selection and fit at 820-point width,
plus an enabled native Account `AXButton`, without opening onboarding or a
backend. One batched fixture-only inspection and one confirmation exported only
the original app-owned fixture views, not the desktop or live Account.
The final native-builder cached export omitted selected text/parts of hero
rendering; it is not proof of compositor fidelity or final visual legibility.
No additional capture/polish loop was performed. Live visual/assistive coverage
remains a release gate, not a claimed pass from these exports.

The same source batch corrects coarse device-proof copy, visibly explains that
device setup prevented Microsoft sign-in from starting, and extends only the
agreed exact three-key diagnostics from ten to fourteen closed pairs.
Unknown/extra/mismatched/non-AUTH diagnostics still do not survive parsing.
During this source-only phase, the running 360e8bf/c50a bundle was not replaced.
The later reviewed deployment is recorded above.

**Historical local final-suite hold:** the default builder hit host-wide ENFILE 23.
The supported native builder with one job/indexing disabled compiled the final
source successfully, then passed **14 core + 233 management + 27 presentation**
checks. The native run stopped at 61 checks with six reconnect/inspection/timeout
failures during the same host-pressure incident; this is **not a passing final
native run**. Both build systems' resource failures remain recorded, not
relabelled as a passing local suite. The independent hosted 353-check run above
subsequently established the complete final run before review/deployment.
No global limits, other processes
or private file paths were changed/inspected. Exact owned app/engine descriptor
counts were eight/ten, not evidence of an owned descriptor leak.

## User-directed sign-in retry with reviewed nonce correction

The backend explicitly confirmed reviewed producer
`2a47eafc930603773583ce4c1d6be89a2f0ccd60` was required on the actual
authentication decoder path before retrying. Immutable native unsigned input
SHA256 `57d4500d6de922d644071ff6749b662c56d75f5f4646da2a884a363169373c0b`
was checked before and after embedding; it remained unchanged, mode 0500,
79,610,312 bytes. Inert management help matched the same protocol/state-dir
entry. The separate signed embedded copy is
`7a6edd58efa81f567ebf7ecc8c7cf089fb7fc155533e2db28ab797111ec2230d`;
release compilation, plist/resources and deep strict signature checks passed.
Entitlement inspection reported no entitlement payload. C95 schema is unchanged.

Only five explicit accessibility modifiers were added to the existing
`Sign in with Microsoft` Glass action: native label, identifier, button trait,
children policy and press action. The same `beginSignIn`/`canSignIn` state gates
remain; no duplicate provider or hidden-worker invocation was introduced.
The new release passed **24 presentation checks** and the signed engine passed
**22 actual read-only management checks**. The prior 278-check app milestone is
separate, not relabelled as a new full-suite run.

The old exact app/child pair was gracefully closed after Account closed and no
modal flow was present. Fresh normal app 79003 / embedded child 79007 negotiated
the same contract and prepared Account noninteractively. A bounded exact-owned
check verified `xodus.account.signIn` was a unique enabled native AXButton with
AXPress. Initial string-label probes refused before activation because this SDK
uses attributed accessibility descriptions; those are not successful actions.
The native control was then pressed **once** as directed by the user.

The native Account subsequently displayed the fixed authored message
"Sign-in did not complete. Try again when you are ready." Close, Check status and
Sign in were enabled; no pending Cancel control was present. This is an
unsuccessful attempt, not successful issuance, credential storage or ownership.
Microsoft/Keychain prompts were not inspected, approved or automated, and no
automatic retry occurred. The running pair was retained for diagnosis; no
success-shaped fallback or invented account state is recorded.

### Safe failed-flow reporting correction (source only)

The running retry build displayed only generic failed-flow copy, although its
typed in-memory flow includes an optional error. That tuple is not exposed by
this deployed UI, so the attempt's exact code/stage is **unavailable**, not guessed.
No memory dump, debugger, new status/provider request or another sign-in was
used to recover it. Current presence-only observations found one owned app
window and no remaining auth child; they do not prove whether a Microsoft
window appeared earlier.

Added a source-only native summary showing the validated failure code with
local static wording, never raw upstream message/exception/XML. AUTH_INVALID
does not imply stored credentials are invalid or advise deleting them, and a
missing code explicitly leaves the cause unknown. Four new failure-reporting
regressions passed within **55 native session checks**, zero failures, against
mock children only. The current 79003/79007 app/engine remained unchanged at the
signed hash above; this correction is not yet deployed and cannot retrospectively
recover the first attempt. Any finer static stage diagnostic requires a
coordinated, reviewed producer/consumer delta before another human attempt.

### Closed stage/reason source agreement and checks

The coordinator approved a diagnostic-only producer/consumer correction, with
no deployment or retry until the same retained review closes it. The exact
optional object/pairs are documented in [the contract](BACKEND-CONTRACT.md).
The consumer decodes only AUTH_INVALID plus the ten closed category/stage/reason
pairs; arbitrary details are not retained as safe evidence. Known pairs map to
static local text. Coarse native-sign-in pipeline failure never proves a browser
appeared or consent completed; absent/unknown evidence says stageUnavailable.
Cancellation, expiry, pending-flow and double-mutation gates remain intact.

One complete isolated Mac `sh tools/check.sh` run passed **14 core + 221
management + 24 presentation + 73 native session = 332 checks**, zero failures.
This includes all ten diagnostic pairs/round trips, unknown/malformed/mismatched
and extra-field secret sentinels, incompatible cancellation/expiry codes,
safe UI mappings, and duplicate begin/cancel guards against actual mock children.
No provider or Keychain operation occurred in these regression tests.
The held running app 79003 / child 79007 and signed7a6e engine were checked
unchanged afterward; this source is not deployed and the previous real failure
still has no observed diagnostic code/stage.
Published diagnostic source `34e396a5a1036a8ed073ec45c0f5678424d4d603`
independently [passed hosted CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37188370651),
including the native suite and SVG regeneration. The earlier deployed AX entry
source `f289eafc4352bede7e152916c68b902124739e44` separately
[passed its hosted run](https://github.com/dragoshont/xodus-macos-app/actions/runs/37187823776).
Neither hosted result is successful live authentication or retained-review closure.
A tightly coupled follow-up also routes request-level `auth.begin` backend errors
through the same sign-in-specific local code/unavailable-stage mapping. The older
general AUTH_INVALID copy could otherwise wrongly imply invalid saved credentials
and suggest disconnecting them during an unproven preparation failure. The
fresh-status gate stays intact; no automatic mutation or retry is added.
The updated **74 native session checks** passed against mock children only,
including this regression. The running retry pair remained unchanged.
The final source snapshot separately passed one complete **14 core + 221
management + 24 presentation + 74 native session = 333 checks** run, including
an untrusted preparation-message sentinel that must never enter local UI.
No live authentication, status or credential operation was performed.

Review continuity changed: the original retained reviewer was cancelled before
returning reports 40 or 41; neither pending delta is approved by those reports.
The coordinator is routing one successor review over only the complete pending
app delta from `f680410` and diagnostic producer `232a4a82` to
`e60481fc918b4cc2cc599a5db2aba17a04738872`, preserving earlier closed findings.
No new engine or diagnostic source has been deployed to the held failed-flow
app, and the first attempt's cause is still unknown.

## Store search and adversarial-review app fixes

### Current inspection pairing and additional client fixes

One full Mac `sh tools/check.sh` invocation passed **14 core + 189 management +
24 presentation + 51 native session = 278 checks**, zero failures. The earlier
`6750219` milestone independently passed 259 checks. The preceding
212-check `fb66a2d` app revision separately
[passed hosted CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37162534769);
that success is not attributed to the newer delta. Earlier native source
`6750219cf547b693d29ee162d796b9b39c37ca70` independently
[passed hosted CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37165029761).
Current R10/diagnostic-summary native source
`f967f5c09a91f60bd82c91db6ab342de2a95d585` independently
[passed hosted CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37167088810),
including all 278 native/core/management/presentation checks and SVG regeneration.

The same retained reviewer closed app R01-R04 at `fb66a2d` and backend R05-R07.
Two subsequently confirmed app findings are fixed with new regressions:
R08 preserves source-level PACKAGE_UNAVAILABLE without optional details and
allows a subsequent snapshot on the same connection; malformed present details,
including null, are still rejected. R09 coalesces catalog work into one active
plus the latest captured query/market/language. Five delayed edits at 300 ms,
cancelling prior view tasks, issue only two requests with max concurrency one
against a mock that enforces the producer's four-operation limit. Latest scope
results arrive without manual refresh; stop drops unsent queued work. These
fixes were subsequently closed by the same retained review at `6750219`; the
`db0bf21` picker/consumer follow-up had no significant issues. A later confirmed
R10 retirement race is fixed below and was closed at `f967f5c` by the same
retained review (report 13); diagnostics had no significant issues. The separate
backend R11 source finding closed in report 14. This clears the source/UI hold,
not human consent or any game-lifecycle gate.

Canonical schema/fixtures at producer `e3129cee422305657b945d35daf2f780ffe98e2b`:
SHA256 `c95c3fabdf114f89329d2361e76421e7b47be4c113f56c2381e64d437e44f749`,
79 positive / 20 negative / four evidence-edge frames. Immutable bytes were
copied and checked; new UUID and exclusion constraints are enforced by the
consumer. Enabled-inspection unsigned engine SHA256:
`da548dd5abe4c32dc17035817d1a809a31c8eb19e615f26dad079a245cf72178`;
locally signed embedded SHA256:
`2180d02dca9300d08c91384207fed6acebdeaaa9d0c309bc0fd28a7fcf7b2296`.
Release compilation, resource/plist and ad-hoc-signature checks passed.

The unsigned producer passed 21 actual checks before the shutdown refinement;
the signed embedded copy passed **22 actual checks** including observed owned
exit. The committed `--probe-inspect` runner creates only its own original
4096-byte synthetic marker under a canonical private test root and removes it.
Its 196-byte digest/version matches; marker and management.json bytes stay
unchanged. Missing/aliased/malformed fixtures remain typed failures, and the same
connection can read the installed snapshot afterward. This is not external-game
inspection, full integrity, retail mapping, ownership, registration or gameplay.
Original layout provenance is the pinned public producer smoke helper; no key
material or real game data is copied.

Normal LaunchServices app PID 65869 / owned child 65872 passed noninteractive
Account/Check status/Close, real public Halo typing through an exact focused
native field, and native continuation. The helper refuses to replace a preexisting
query or type with a sheet open, and logs only authored allowlisted labels.
No consent/sign-in was initiated. Native picker compilation is separate from an
actual user-selected external-folder test, which has not occurred.

The same signed bundle subsequently passed graceful normal-app quit: both
owned PIDs exited before another app was opened. Relaunched app PID 67493 /
child 67496 passed Account/Check status/Close and retained the same signed
engine hash. This additionally exercises the new bounded shutdown through the
actual application delegate, not only mock-child checks. No consent was started.

### Native folder-picker cancellation follow-up

An exact-owned UI check could see the inspection section but could not find an
actionable inspection button with its plain SwiftUI label. It refused interaction;
those attempts are not recorded as successful picker tests. Added explicit
native button label, identifier, traits and press semantics, matching navigation.
The release bundle then rebuilt and passed all **24 presentation checks**.
Exact app PID 69353 / child 69356 exposed the inspection button, opened its
native folder picker and cancelled it through its sole exact Cancel button.
Account status/Close still worked afterward and the child remained alive.
No directory was selected or inspected; this is cancellation evidence, not
external-game inspection or adoption. The approved signed engine hash is
unchanged. `InspectCancel` in the committed helper confines every interaction
to the exact owned bundle/window, bounds traversal/waits and never logs picker
directory names. A single bounded own-window scroll supports the below-fold
Library action; ambiguous targets or existing modals are refused.

### Shared retirement and complete reconnect fencing (R10)

The retained reviewer found that clearing the client before awaiting close let
another disconnect return true early, and competing reconnect continuations
could create or replace ownership. Retirement now publishes a shared closing
operation before suspension and keeps its client owned until observed exit.
All callers await that same result; failed observation retains the old client.
A reserved whole-connect operation, lifecycle revision and disconnect-waiter
gate cover negotiation, snapshot and subsequent startup continuations.

Fourteen new actual LiveSession/mock-child checks hold the child alive for
1.4 seconds after stdin EOF. Concurrent disconnect/fixture/quit guards cannot
return early; reconnect starts no second process. Overlapping complete reconnects
create exactly one replacement, and a superseding disconnect prevents that
replacement. A test-only 200 ms observation budget exercises a real negative
exit observation while the child is still alive: all callers receive false from
one shared observer, old ownership survives retry, and a new engine is allowed
only after eventual exit is observed. Production remains bounded to six seconds.
Suspended hello/snapshot continuations are separately fenced and recoverable.

The release bundle rebuilt and passed actual folder-picker cancellation,
noninteractive Account/status/Close and reviewed-summary save-panel cancellation.
All 22 signed producer read-only checks passed again. App 89107 / child 89111
then exited normally before relaunch; current app 89731 / child 89734 passed
Account/status/Close with the same signed engine hash. No auth consent occurred.
The same retained review subsequently closed R10 at `f967f5c` in report 13,
independently of these tests. No significant diagnostic-summary issue was found.
The existing Account entry was opened for coordinator-routed human handoff with
the unchanged app/child pair and engine hash; sign-in was not initiated.

### Reviewed counts-only diagnostic summary export

Native Settings now offers a file destination only after preparing the displayed
summary. Exactly that private-set counts-only text is atomically written off the
main actor, never raw engine text, account identity, paths, tokens or URLs.
Five native regressions cover absent preview/no write, exact saved bytes,
visible filesystem failure with preview preserved, nonlocal destination rejection
and disconnect invalidation. The actual native save panel opened and cancelled
without selecting a destination. Earlier helper scripting errors are not counted
as passes; corrected helpers passed and their compiled temporary files were
removed. This is a limited summary, not a full engine-log export.

Live upstream zero-source behavior is **not observed**: arbitrary nonsense can
return suggested cards. The empty-source regression remains scoped to
deterministic backend serve tests and actual LiveSession/mock-child checks;
positive HTTP queries do not strengthen it into a live empty-result claim.

An expanded native run stalled during owned-process close. The exact mock-only
stack showed Foundation `NSConcreteTask.waitUntilExit` blocked in its private
run loop after the child was gone. That run was stopped, not counted as passing.
Bounded six-second exit observation replaced the unbounded wait; failure is
explicit and prevents reconnect/fixture switch/quit from pretending cleanup
finished. Three repeated worker reconnects and the complete suite then passed.

### Earlier query milestone (historical)

Recorded 2026-10-04. One complete `sh tools/check.sh` invocation passed **14 core +
156 management + 24 presentation + 18 native session = 212 checks**, zero
failures. Native checks execute the actual session coordinator against sanitized
synthetic child processes and exit before creating a window. They exercise:

| Finding / edge | Actual regression evidence |
| --- | --- |
| R01 expired profile | Explicit current status exposes confirmed launcher disconnect; fresh signed-out state precedes a new sign-in |
| Permission failure after expired status | Disconnect disabled; attempted unavailable-store recovery makes no deletion request and preserves the profile |
| R02 transient polling / rejected late cancel | Status remains available while pending; one inaccessible-store error recovers; INVALID_TRANSITION resumes polling to a terminal result, never false cancellation |
| R03 human operation budget | Synthetic preparation/logout exceeds the old 30-second limit while public snapshots still respond; finite 600-second mutation budgets remain distinct from short reads |
| Uncertain mutation | Failed preparation invalidates pre-mutation freshness; explicit fresh status required before another attempt; transport timeout separately tested with reconnect/status reconciliation |
| R04 initial all-failure page | Continuation exposed with zero products; later success retains earlier failures and unknown entitlement |
| Empty / stopped query | Genuine empty success remains live and distinct from failures; stop fences a late bounded result without claiming HTTP abort |

Canonical schema pin is `9d024ae079daccafb3437e4b0c67aef735d657bb`, SHA256
`655e1ed31772b35a8526ef5a0986557e7f6de689d5c4925ccde7041bc33b5f29`,
with 77 positive, 15 negative and four independent evidence-edge frames.
All four exact fixture hashes were checked against immutable public Git bytes.

**Thirteen actual read-only checks passed** against preserved producer
`4de9c2b2e7c114854699e3708d41c12fa73e188d` and its signed embedded copy:
two bounded Microsoft Store query pages, two discovery pages and checked-cache
title search, negotiation/session identity, registry and redacted diagnostics.
Unsigned SHA256 `58f5b80f253d8ee199dc193d3a31cbd1571b641ce309f81bf0430910a6982e83`;
embedded SHA256 `5ea5b49610fc9887345234e0d66bc9954f3bf1e78716ab25866802c4f48f324b`.
Release compilation, resources, plist and signature checks passed.

Normal LaunchServices app PID 39706 / embedded child 39709 exposed Account,
noninteractive saved-status refresh, explicit Check status and Close. Discover
retained the engine beyond 35 seconds. These are bounded owned-window authored
label checks, not successful sign-in or full VoiceOver. No consent was initiated.

**This producer was not review-closed at that milestone.** The retained reviewer subsequently found
R06 (zero-source query cached as an invalid empty registry operation) and R07
(repeated source-cursor equivalence not fully normalized). Positive two-page
evidence above could not close either issue. Their later producer closure and
current pairing are recorded above; live zero-source evidence remains unobserved,
not fabricated from an arbitrary query. App R01-R04 later closed at `fb66a2d`;
no new reviewer was spawned.

Hosted startup-fix revision `44f24407ad9562e90a305426771423e3f46864dc`
[passed its own GitHub Actions run](https://github.com/dragoshont/xodus-macos-app/actions/runs/37159377257).
That success is not attributed to these newer changes.

## Bounded discovery and default application startup

Follow-up recorded 2026-10-04: the initial PID graph below did **not** establish
sustained startup. Bounded own-window inspection subsequently found the local
timeout message and no engine child. Added privacy-safe OSLog evidence identified
`auth.status` as the exact stalled GUI request; hello and activity negotiation
succeeded, and a same-state SSH probe confirmed matching hello/snapshot session
identities. No native permission was approved.

Anonymous startup now performs registry/catalog work without a Keychain read.
The rebuilt normal LaunchServices app retained its included engine beyond the
original 30-second failure deadline. Exact-PID/bundle/window-checked Accessibility
presses successfully opened **Discover, Downloads, Library and Account**. The
account sheet exposed the authored unchecked-status explanation; it did not read
credentials or start sign-in. Navigation and profile controls now have explicit
button/press semantics and stable identifiers. The committed helper logs only
allowlisted public UI labels, not product/account data. This confirms bounded
normal startup/navigation, not full VoiceOver, live compositor or account consent.

The discovery follow-up passed **14 core + 130 management + 24 presentation =
168 checks**, zero failures. Canonical schema is now producer commit `790f5c4`,
SHA256 `2ede71d5171cf4dc1659fedfc99187a90d904d9264119a22ee9f94064baef3d2`;
the preserved discovery implementation/executable is `8718dcb`. Seventy-one
positive, eleven negative and four evidence-edge fixtures remain sanitized.
All-failure pages validate only against the explicit error definition; an empty
page cannot masquerade as successful discovery. Source language and same-base
neutral fallback, inaccessible-Keychain errors and scoped catalog invalidation
are covered.

**Eleven actual engine checks passed**, including explicit hello/snapshot session
identity and two source-backed anonymous PC Game
Pass discovery pages with distinct identities/stable cursor, and actual title
search in the resulting checked cache. This is not global Store search or owned
inventory. The refined authentication result identifies an inaccessible
credential store; no Keychain approval, credential replacement or sign-in was
performed.

The release app was rebuilt with that preserved engine, locally signed and
resource-checked. Unsigned input SHA256 is
`14dd06466a201ddb77fe7c2d6f9a57bbbb79788f03413989e5158d9053c864ad`;
embedded local SHA256 is
`62cb9564478d2a2bcee472b6f7d6865f5f3007a0314e30c7a06537523820f175`.
Actual default LaunchServices entry (`open Xodus.app`, no live/backend flags or
environment override) started the application and its own included-engine child.
That initial PID/parent relationship established default embedded selection only;
the failed sustained startup and its verified correction are recorded above.
Missing/nonexecutable embedded engines show
an actionable error and do not silently reuse saved developer binaries or fixtures.

Hosted startup follow-up subsequently succeeded for `44f2440`, as recorded above;
local Mac evidence is not relabelled as hosted CI. Full search coverage, genuine
ownership, authorized install/update/play/recovery and coordinator-owned adversarial
review/findings closure remain active completion prerequisites.

## Native client implementation

The subsequent native development app now opens a real management shell by default;
the original demonstration requires `--fixture`. On the same isolated Mac,
`sh tools/check.sh` passed **14 core + 118 management + 24 presentation = 156
checks**, zero failures. The management checks use the immutable producer pin
and sanitized corpus documented in [native integration](NATIVE-INTEGRATION.md),
plus actual mock child processes; no Microsoft login or Keychain permission was
approved by these checks.

The checks cover strict request/result correlation, capability gating, split and
oversized JSONL, truncated output, unknown IDs/shapes, process exit/EOF/timeouts,
independent evidence and activity sequence/revision invariants. In-flight activity
snapshots fence incoming events: the snapshot is applied first and newer buffered
events are applied afterward, avoiding a legitimate live-event/snapshot race.
Failed reconciliation retains the last verified jobs as non-current and disables
mutation until an authoritative snapshot is restored.

`sh tools/build_app.sh` also built the release `.app`, generated the original icon,
copied required resource bundles and the GPL notice, and passed plist/ad-hoc
signature verification. The packaged executable's resource/presentation check
passed. This is a local development bundle, not a notarized release.

Disconnected own-view Library/Discover/Downloads exports were inspected in a
bounded correction/confirmation pass. The native search placeholder and centered
empty states were corrected; no account data or desktop capture was involved.
Exports still omit live compositor/backdrop effects.

The published native-auth schema and sanitized fixtures are pinned at producer
commit `b9cd60bf51cd4cb8e864318cd0c4316453b4b8df` (68 positive, ten negative,
four independent evidence frames). Against the preserved native engine, a
**seven-check read-only interoperability probe passed against both the preserved
engine and its ad-hoc-signed embedded copy**: hello, unsupported
runtime/plan gates, explicit invalid-credential failure, partial observed catalog,
durable jobs snapshot, management-only installed registry and redacted diagnostics.
`auth.status` returned **AUTH_INVALID**, not valid sign-in; this account gate was
reported to the backend owner. No permission was approved and no authentication,
logout, installation or game process was started.

The verified unsigned input engine SHA256 is
`3fd646ac3eb7bdd2acdbcc3ed3755d2f4e2722ea1a7b4798eae72acb7ac41fd7`;
its locally ad-hoc-signed embedded copy is
`39df33fbac4334df12de39fb2e345a1ac64eb9e4330bb7a1f78de59b6fc26976`.
The packaged resource/presentation check passed. A successful real account login,
owned inventory, game installation or gameplay is **not** claimed. Hosted CI
evidence below remains evidence for its named foundation commit until the new
revision's run is separately recorded.

## Actual Mac environment

Apple Silicon arm64; macOS 27.0.1 build 26A434; Swift 6.4 (`swiftlang-6.4.0.34.1`); SDK 27; developer directory `/Library/Developer/CommandLineTools`. Full Xcode was unavailable and was not installed. Public source was transferred into the new isolated `~/xodus-app-tooling/app-foundation` directory, excluding git/credentials. No private runtime repositories, services, games, bottles or capture helpers were modified.

## Passed commands and observations

| Check | Actual result |
| --- | --- |
| `swift build` | Native SwiftUI executable and core/check targets built successfully for arm64 with proposed macOS 14 deployment target |
| `swift run XodusFixtureChecks` | 14 core checks, 0 failures |
| `swift run XodusPreview --self-check` | 15 presentation/resource checks, 0 failures; no window or backend needed (29 total checks with core) |
| `sh tools/check.sh` | All three commands above passed as one reproducible invocation |
| Native executable launch | On-screen native window verified through CoreGraphics, 1200 x 860 points; no runtime/game process launched |
| Actual macOS 26+ Glass APIs | `glassEffect(.regular.interactive(), in: Capsule())`, `GlassEffectContainer`, `.glassProminent` compiled and ran on macOS 27 CLT with older availability fallback |
| Own native view export | Three actual fixture NSView hierarchy PNGs exported in-process; Library/Discover/Downloads inspected in a bounded correction + confirmation pass |
| Native confirmation | White/legible local overlay chrome and original image-backed heroes/content confirmed by coordinator. Search prompt then received an explicit light style as a narrow coupled fix |
| `python tools/generate_mockups.py` | Nine editable SVGs generated using Python standard library; all parse as valid XML |
| `swift tools/render_mockups.swift` | All nine original SVGs rendered through native WebKit into PNG previews without third-party dependencies |
| PNG artifacts | Nine 2880 x 1960 Retina previews retrieved to `design/previews` |
| Original image resources | Six original bundled images loaded in self-check; primary 2048 x 1152 authored scenes use committed CoreGraphics/ImageIO source; no external images/service |
| v0.2 SVG upload budget | All nine self-contained data-URI screens <= 0.90 MB each, below 10 MB cap; editable text/vector layout with original JPEG derivatives |
| Figma revision | Nine v0.2 editable imports succeeded; Library/Discover official renders inspected by coordinator. Some gradient/rounded-image fidelity flattened; no compositor proof. Earlier unapproved v0.1 superseded |
| GNU GPL v3 | Verbatim 35,149-byte GNU license text retrieved from `https://www.gnu.org/licenses/gpl-3.0.txt`; app grant is explicitly GPL-3.0-only |
| Hosted GitHub Actions, code commit `4e9c963` | [Fixture foundation checks succeeded](https://github.com/dragoshont/xodus-macos-app/actions/runs/37151989754): native build/check sequence and SVG regeneration |

The check executables cover six image resources plus independent access/package/compatibility gates, subscription expiry, stale/offline/partial inventory, mismatched runtime/architecture, exact disk-space threshold, cancelled/completed job non-regression, pause/retry, identity/JSON round trip, scoped search/category/access filter, duplicate enqueue, completed-only installation, disconnected action denial and fixture reset.

## Toolchain constraints resolved

SDK 27 exposes a new `SwiftUI.State` macro whose plugin is not shipped with this CLT. The first `@State` build failed with `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`. The app uses standard native `ObservableObject`/`StateObject` for sheet interaction instead, compatible with the proposed older baseline; no private SDK plugin, type-erasure workaround or web fallback was introduced.

This CLT has neither XCTest nor Swift Testing (`no such module`/unresolved dependency). Rather than install Xcode or introduce a dependency solely for fixture assertions, tests are explicit failing Swift executables: `Tests/FixtureChecks/main.swift` and `Sources/XodusPreview/PreviewChecks.swift`. **Do not claim `swift test` passed**; use `sh tools/check.sh`. Swift's new build system also emitted non-fatal linker warnings for absent CLT `Developer/usr/lib` and `Developer/Library/Frameworks` search paths; compilation/link/run/checks nevertheless succeeded.

## Not yet verified

Static SVG translucency is a **placement/composition concept**, not native Liquid Glass. Actual framework calls were verified separately by compile/run. Own-view AppKit exports omit compositor/backdrop effects: absent glass surfaces and transparent/black titlebar strips are export limitations, not evidence of live-window refraction or titlebar alpha fidelity. No desktop/other-app capture or new Screen Recording permission was used. The coordinator confirmed native Library/Discover navigation via Accessibility on the earlier fixture window; that does not replace complete current VoiceOver or live compositor testing.

The native client and bounded read-only producer interoperability are verified as recorded above; successful account consent/provider authorization remains a separate gate. Owned-PC enumeration, game package download/installation, real game recovery, runtime pairing download, gameplay, notarized distribution and save preservation remain unavailable. Actual macOS 14 runtime behavior is not verified merely because a macOS 14 deployment target compiles on macOS 27. Full VoiceOver, keyboard sheet focus return, both appearances, reduced-preference, localization/RTL, performance and resize matrices remain release gates. Hosted CI evidence above is for the named code commit, separate from local Mac verification; later revisions need their own workflow read.

Fixture jobs deliberately reset on relaunch. The fixed fixture evidence time and illustrative 24-hour access freshness gate are demonstrations, not a proven upstream authorization TTL.
