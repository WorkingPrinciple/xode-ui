# UX screens and state flows

**Full consumer journey specification, not a claim that every step works.**
The default native development app has real bounded account/catalog/registry and
selected-folder inspection clients; [current integration evidence](NATIVE-INTEGRATION.md)
distinguishes those from unfinished inventory/install/play gates. The original
offline `--fixture` preview labels simulated actions explicitly and never claims
real Microsoft access or compatibility.

## X Ode first-run gate (16 October, source candidate)

Ordinary startup shows Welcome to X Ode over a neutral background, not installed
game cards or developer setup diagnostics. Startup connects only through the
existing management admission path and checks saved account status. A confirmed
saved sign-in opens the existing app; otherwise Microsoft Sign in remains the
primary action. Missing pairing disables it with a short setup-unavailable
reason. Try again rechecks connection/status; Cancel sign-in waits for the
existing cancellation result and leaves Welcome locked. Expired/invalid saved
sign-in requires explicit confirmation before disconnecting it for a fresh
attempt. Quit stays available through the native app menu, but existing mutation
holds still refuse termination until their operations settle.

**XO-010 normal Quit from Welcome:** Only the mandatory welcome presentation
opts its native sheet window out of AppKit's modal termination blocker, allowing
normal Quit to reach the existing termination delegate/coordinator. It does not
dismiss Welcome, unlock content or override operation refusal. The original
window policy is restored when Welcome leaves or its bridge is dismantled;
Account, installer and destructive sheets are not globally changed.

Pairing rejection and later connection failure are distinct. After helper and
engine identity validation, failure to start the service or negotiate its hello
offers Try again and suggests normally closing another open X Ode copy first.
It does not assert that another copy is running or that a lock error was
received. Missing/invalid pairing retains the matching-app/service requirement.
Neither message unlocks sign-in, navigation or credentials; successful connection
and current account status are still required. The dedicated native menu is
**Account**, distinct from the canonical **X Ode** application menu.

The official `https://www.codeweavers.com/crossover/download` trial handoff is
shown only for absent/unverified CrossOver. Returning to the active app repeats
read-only publisher detection. It does not install CrossOver, assert a license
or certify gameplay. Main navigation, import, Settings' game actions and cached
installations stay inaccessible without confirmed management sign-in. Sign-out,
disconnect or failed status validation returns to Welcome without deleting
game files, registrations or saves. The explicit fixture/review paths retain
their existing isolated behavior.

Returning to the foreground also requests bounded management account status
through the existing admitted connection. A previously confirmed view remains
visible only while that check is in flight; failed or expired status relocks it.
Concurrent status reads are deduplicated, and pending sign-in is not interrupted
by a second status request. There is no polling or account-identity joining.

If relocking occurs during an existing game operation, Welcome keeps generic
preparation/progress/recovery and cancellation controls. It does not expose the
game title, product ID, folder, raw error, log or cached game cards. Cancellation
is acknowledged through the existing controller; mutation and Quit holds remain
until the owned check/script settles. Full error details remain behind sign-in.

Management sign-in is not a PC-library or game-service identity binding; those
existing contracts remain separate. This gate does not invent an owned library,
join different accounts or imply successful live sign-in. The anonymous entry
behavior elsewhere in this historical specification is superseded by this
user-directed first-run correction.

## Freeze correction: operation feedback and library retry (source candidate)

**XO-018 game-service identity recovery:** A saved game-service sign-in without
an account binding says **Game sign-in saved; account not verified**, without a
confirmed-account checkmark. Account exposes **Verify game account** explicitly
through the existing service sign-in action, followed by its fresh service-status
read. Check status and view presentation never trigger verification automatically.
Only an actual bound status removes this action; an unbound result leaves it
available and a failure shows the existing error/retry path. Existing service,
mutation and Quit fences still govern the action. This does not require profile
binding to play, change game eligibility, join accounts or relax ownership of
Profile/Consoles/stats caches. Live verification still needs native acceptance.

Discover keeps the existing operation feedback above its content after a card
or hero Install action: preparation, progress, cancellation, and exact bounded
package/account/storage failures. It does not silently hand off to another tab
or treat an unsupported package as a successful install.

**XO-022 title-scoped operation feedback:** Game detail shows preparation,
active progress, recovery, terminal errors/notices and their log/sign-in/cancel
controls only for the matching product when ownership is known. Navigating to
another title does not clear the original failure: returning to its detail or
using Library, Discover or Downloads retains the existing global feedback.
Ownership follows the accepted preparation, operation record and restored
journal, not error wording or the selected screen. A new accepted action resets
the previous feedback together rather than attaching its old log or account
failure to a different game. Unbound storage/recovery failures remain visible
without inventing a title owner; Welcome still redacts private details and
retains generic operation/cancellation status. This corrects cross-title
presentation, not package authorization or a game's separate launch/SDK failure.

PC-library presence restoration commits its saved-sign-in/approval/retained-item
flags only after all broker checks succeed. A transient failure says saved
sign-in is unavailable, not absent; Try again, Refresh Library and a later
Library visit can retry through the same admitted store. An installed helper
with rejected caller/pair metadata still fails closed, without direct-Keychain
fallback, broker replacement or credential removal.

Game detail says **Installed on this Mac** for a registered installation.
Registration alone is not readiness: existing package, launcher and runner
validation and their explicit failures still govern Play.

An independently admitted private launch-association capsule may request one
ordinary foreground handoff after explicit Play. It requires live current-run
PID/start-instance attestation and a usable window of that exact PID, not
launcher ancestry or title/process-name guessing. X Ode must remain active;
switching apps permanently abandons the request. Stop, launch failure and
termination cancel it. This optional source path does not add a setting, force
activation, inject input or claim foreground success from an accepted request.
Without the capsule, existing Play behavior is unchanged.

An explicitly packaged private Python runtime is separately admitted by the
signed app. It supplies the adapter, launcher and operation scripts, not a
system developer-tool prerequisite or a user-selected executable. A present
invalid runtime fails the operation with a fixed reinstall diagnostic; it
does not silently select another interpreter. No runtime/capsule is enabled
by these source changes, and signed-app/clean-Mac/game qualification is still
required.

These corrections have synthetic controller/presentation and detached native
layout coverage, not a new live all-window, account, download or gameplay
acceptance claim.

## Navigation and search

**SDD-LIB correction (source only):** Your Games, its count, search, filters,
sort, hero and Continue Playing share the qualified PC-collection join.
Installed-only records are reachable below it in **Local installations · access
not verified**, using existing native cards/actions, not a new navigation
destination. Their warning explicitly preserves files/saves and does not grant
ownership. A qualified cached collection remains navigable with source/age and
stale copy, but new Download is disabled during failed/in-flight refresh.
Revocation or account mismatch retires personal access without deleting local
records. Game Pass catalog badges describe public PC membership only;
Game-Pass-only current per-edition access remains a contract blocker.
Loading/partial/failed discovery is not an empty personal library or evidence
that missing titles are outside Game Pass. Package authorization failures ask
for account/selected-edition resolution, separately from Mac package support.
The approved Figma composition, toolbar and existing protected actions remain;
no native walkthrough of this source correction has occurred.

**Unavailable release metadata:** Detail omits the release-date row for the
observed Microsoft catalog placeholder `9998-12-30T00:00:00.0000000Z`
(including equivalent timestamp representations), absent/malformed timestamps
or impossible civil dates. Other product facts remain available. This is an
exact marker rule, not a maximum release year: historical dates and legitimate
future dates remain visible. No replacement release date is invented.

**Game Pass review affordance:** Discover and game detail keep **Check Game Pass
access** for a PC catalogue member when subscription status is active. The shared
frontend policy opens the existing package/compatibility/storage review only;
it does not establish access, add the game to Your Games, start a download or
launch it. Actual preflight and explicit confirmation still gate installation.
The earlier SDD candidate removed this working route; the frontend follow-up
restores it and removes the disconnected Install-policy assertion.

Selecting Game Pass changes the heading to **PC Game Pass** and browses the
loaded public PC membership catalogue, including titles not separately held
in the user's collection. The view follows existing continuation pages instead
of stopping after the first 16. It shows real count/loading/partial states and
never claims a fixed number of titles or complete account entitlement coverage.
Owned and Game Pass remain independent; selecting All/Owned returns to the
qualified personal Library. Per-game Check Game Pass access remains preflight,
not download confirmation.

Cover artwork shares a top-aligned native adaptive grid across Library,
Discover and fixtures. Different title/metadata heights do not raise or lower
posters. Play remains visible on installed cards; Installed is secondary status,
not an inert action button. Apple HIG references: [Collections](https://developer.apple.com/design/human-interface-guidelines/collections),
[Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables),
[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
and [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators).

**Current shipping boundary:** the proposed artwork-led screens below are not
synthetic production content. The live source uses native window-background
setup/empty/loading/error/data views until rights-cleared real art exists.
Preview illustrations/state/resources and simulated actions are compiled out
of shipping. No live Settings transition can open the offline demo.
Catalog loading takes precedence in both heading and description; only a checked
zero-result Store response says no matches. A post-ready user query survives
initial/reconnect activity and registry reconciliation without an empty startup
seed replacing its products/corpus/cursor.

One native Mac window with full-width system toolbar chrome, native traffic lights and no visible app title. Library / Discover / Downloads and compact stock search share the principal toolbar group; Account stays separately trailing. The older floating-capsule mock direction is superseded. Original artwork extends beneath system chrome, without custom tint or decorative glass; whole-toolbar placement/tint still awaits safe live visual confirmation. Library is the proposed first screen: artwork-led focused-game area, compact Continue Playing, then Your Games/count/sort-filter and adaptive horizontal square-icon entries with separate access/compatibility text and contextual action. Discover has immersive feature/browse/shelves; detail imagery is edge-to-edge. Search is scoped to the current tab; Downloads uses a queue, not catalog search. Command-1/2/3 navigate and Command-F focuses search. Account opens a native hub that pushes to Profile, Achievements, My Consoles and Engines without adding more primary toolbar tabs; each also has a named menu/keyboard route. Native Settings links to the same dedicated Engines page and Advanced diagnostics. Back from a detail sheet restores selection and scroll position. No persistent sidebar, Friends or Arcade destination.

[Editable FigJam flow](https://www.figma.com/board/3MejlFaXHkogmJ3J5k79Gw) and [latest v0.2 Figma mockups](https://www.figma.com/design/5iQu716UFImHjRxJkf0t8V?node-id=3-115) are proposed UX artifacts, not observed API behavior or exact system compositor effects.

| Screen | Primary content/action | Distinct states and recovery |
| --- | --- | --- |
| Welcome | Explain legitimate access and runtime limitations; Connect account | Signed out, browser handoff, awaiting approval, cancelled, expired, denied, unavailable. Cancel returns to Welcome; retry creates a new request and never reuses a cancelled token flow. Preview has only "Simulate connection". |
| Library | Continue Playing plus game shelf; access filter and scoped search | Loading, complete, truly empty, no search matches, partial, stale, offline cache, failed inventory. "Try refresh" cannot relabel partial results complete; no cache + failure is an error, not zero games. |
| Discover/Search | Original artwork-led selection; "Not your library" scope note | Catalog loading, unavailable, no matches, edition variants. Discover results may show "No access" and never silently become library items. No purchase CTA in v1. |
| Detail | Artwork, description, four facet rows, edition/language and evidence disclosure | Purchased/subscription/none/unknown independent of downloadable/blocked/unknown; verified/experimental/unsupported/unknown independent of installed/not installed/updating/broken. One reasoned primary action; blocked states explain next safe step. |
| Install sheet | Pinned package plan, destination, storage math, runtime pair; confirm | Planning, ready, insufficient space, changed plan, expired authorization, cancelled. Changing edition/destination invalidates the plan and requests a new one; Escape leaves no job. Experimental requires consent. |
| Downloads | Ordered durable jobs, phase/progress and contextual controls | Queued/downloading/paused/verifying/extracting/committing/completed/cancelling/cancelled/recoverable failure/permanent failure. Retry resumes only verified bytes; integrity error triggers safe re-download or re-plan. |
| Installed detail | Launch, version, update availability | Access revoked, runtime mismatch, missing files, unsupported current OS and offline denial disable launch with reasons. Launch error remains in app with diagnostics; no false "Playing" from exit 0. |
| Settings | Account, destination, safe updates | Disconnect confirms impact on jobs; storage picker checks access; diagnostics explicitly advanced/redacted. License and distribution details await decision. |
| Account hub | Xbox game-service identity plus PC Library distinction; Profile, Achievements, My Consoles and Engines destinations | Account hash mismatch retires cached companion data. Missing profile fields hide. Section-specific Xbox failures remain unavailable rather than empty success. |
| Profile | Real gamerpic, gamertag, gamerscore, optional display name/bio/location, actual friends fields and recent activity | Recent activity is play history, never ownership. Missing bio/location/following counts are omitted. |
| Achievements | Recent Xbox titles, then exact-title achievement rows with earned/progress/G data | Unknown totals are absent rather than zero. Partial pages remain incomplete with their source error. |
| My Consoles | Actual cached consoles, readiness/storage facts and official browser Remote Play handoff | No manual devices, per-console URL, wake, power, install or native streaming controls. |
| Engines | Verified CrossOver observation and independently declared GPTK/Wine/graphics components | Unavailable and Experimental remain explicit. No runtime download/removal or arbitrary DLL manager. |

## Critical paths

**Declared runtime configuration:** Settings -> choose GPTK3, GPTK4,
legitimately user-installed CrossOver or standalone/source-built Wine ->
optionally declare separate provider/Wine/graphics metadata -> request a fresh
isolated plan or cancel. Initial selection is empty, not the external GPTK4
trial default. Blank versions/hashes remain unknown. Changing any component
clears previous planning evidence. A valid plan still says not inspected,
device preflight not performed, no game verified and Play unavailable; it
creates no prefix and touches no bottles/saves. Unsupported older engine,
invalid response, timeout and cancellation are explicit states. Fixture
Settings share the declarations but keep the planning action disabled.

**Connection:** Welcome -> connect(request ID) -> approved callback -> validated credentials in Keychain -> inventory snapshot. Cancellation from any intermediate state -> signed out. A "login successful" string without tokens -> explicit authentication failure.

**Inventory:** snapshot loading -> complete/partial + time/source -> cached offline if necessary. Purchase is distinct from time-bounded subscription. Play history is only an enrichment source. Unknown access remains unverified; expiry never becomes purchase. A refresh changes facet values but does not erase installation/save records.

**Install:** select exact edition -> evaluate four facets -> fetch authoritative plan -> recheck capacity and consent -> enqueue by idempotency key -> download -> verify -> extract to staging -> atomically register -> ready. Dismissal before confirmation creates no job. Cancellation after confirmation waits for backend acknowledgment; UI shows Cancelling, not instant fictional success.

**Reconnect:** connection lost -> preserve last known job rows with "Status reconnecting" -> request sequence after last applied event -> replay events, or replace with snapshot at a known watermark if retention expired. Never add completed bytes across duplicate events. Terminal job states cannot regress.

**Update:** fetch new immutable package/runtime pair -> preserve existing runnable registry entry -> stage/verify -> atomic promote -> retain rollback according to storage policy. If pre-promotion failure, current version still runs. Save location is separate; incompatible save formats require title-specific warning, not an unconditional rollback promise.

**Removal:** inspect managed paths -> confirm game-content removal -> remove safe manifest-owned content -> registry tombstone. Preserve saves by default. No recursive removal based on a display title or unvalidated path.

**Selected existing folder:** explicitly choose one exact directory in the
native folder picker (aliases not implicitly resolved) -> bounded read-only
streaming-marker metadata -> show selected folder and observed header version,
with unknown retail identity, game-file integrity, access and compatibility.
This result is outside the registered Library and cannot enable Play. Missing,
aliased or malformed markers are visible errors; no scan, adoption, registration
or file write is performed. Cancelling the picker makes no request.

**Rapid scoped search:** one active catalog request plus the latest queued
query/market/language; replace queued intermediate edits rather than starting
every debounce result. Stop drops unsent work and fences active results without
claiming HTTP cancellation. Source-level failures remain recoverable catalog
errors; valid all-failure pages retain visible failures and continuation.

## Status copy and independent evidence

The live toolbar, Account sheet, Settings and Library share freshness-aware
account presentation. HELLO means the development engine is connected, not
that account status was checked. A failed status read can retain the last safe
snapshot for cancellation/recovery fences, but displays "Account status needs
checking" without a saved-profile badge or current-expiry/disconnect advice.
Only a fresh credential result restores "Microsoft sign-in saved"; PC ownership,
installation and play remain separate unavailable evidence.

A pending flow is labelled "Sign-in pending", not proof that a provider window
opened or a particular MFA/passkey step is required. An unreadable pending
outcome stays pending for cancellation/dismissal protection and explicitly
requires a status check; it is never assumed completed or cancelled. Known
failed/cancelled flow results retain their existing static diagnostics.

"Purchased" means purchase entitlement evidence, not "found in catalog". "Included with subscription" carries checked time and expiry when available. "Access unverified" is not an error-free fallback. "Download unavailable" states the reason (PC package absent, market, architecture, access, API or unknown). "Verified on [OS/runtime]" must match current fingerprint. "Experimental" explains what is untested. "Unsupported" is not equivalent to "not owned".

Detail presents access -> downloadability -> compatibility -> local install, then a disclosure of provenance/time/fingerprint. Installed state never bypasses revoked access policy. When multiple reasons block an action, present the most actionable primary reason and retain all facets.

## Fixture interactions

The preview has simulated connection/cancellation, searchable Library/Discover, detail/installation sheets, insufficient-space denial, experimental acknowledgment, an in-memory queue with explicit advancement/pause/cancel/retry, and a simulated launch message. Settings inject partial/stale/offline/empty/error snapshots. Nothing persists or contacts an account. Empty, blocked and error illustrations are also covered by editable mockups; production flow gates remain in [requirements](REQUIREMENTS.md).

## Accessible interaction

Focus order follows chrome -> scope/search -> content -> detail action. Sheets use native controls with cancel/default actions, readable wrapped errors and no required gestures. Decorative art is hidden from VoiceOver; game buttons combine textual evidence. No autoplay art, parallax or progress animation; reduce-motion therefore loses no content. Reduced-transparency mode uses an opaque system window background. Search/tab labels and states must be localized before release; current preview is English-only.
