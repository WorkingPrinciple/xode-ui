# UX screens and state flows

**Full consumer journey specification, not a claim that every step works.**
The default native development app has real bounded account/catalog/registry and
selected-folder inspection clients; [current integration evidence](NATIVE-INTEGRATION.md)
distinguishes those from unfinished inventory/install/play gates. The original
offline `--fixture` preview labels simulated actions explicitly and never claims
real Microsoft access or compatibility.

## X Ode first-run gate (16 October, source candidate)

**19 October unified-account source candidate:** App-owned display branding is
now **Ode to X**. Welcome uses the app mark; signed-in Account uses the profile
identity instead of a second app-brand header. An engine
advertising `ode.account.read.v1` selects the new native route: the isolated
launcher account supplies library/profile/achievement reads without separate
library or service login. Profile failure does not block the signed-in shell.
Play/install remain closed until a matching runtime consumer exists; Account
discloses that requirement rather than starting legacy consent. New-route
sign-out removes the management session and retires memory-only data; it does
not read or delete unused legacy library/global-service credentials. Those
legacy sessions are not claimed to be logged out. Other historical paths below
describe the existing admitted producer, not completion of this candidate.

**Account/Library correction:** Welcome retains the app mark. Signed-in Account
shows only the gamer picture/profile identity, without a second app-brand header
or runtime diagnostics. Game-connection details remain in Settings. Library
loads automatically on signed-in entry; success with an empty PC collection shows
an empty result, not a "Load PC games" prompt. Loading, failed and empty states
are distinct. Lists without a hero respect toolbar safe areas, and Library
follows the system appearance rather than forcing a grey/dark fallback.
The Library hero is not conditional on a populated owned collection: it prefers
current subscription-held PC games, then purchased/other held PC games, and uses
real public PC catalogue picks when account-qualified titles are absent. Public
picks are labelled as catalogue content and open details, never an invented
Owned/Included grant or a disabled fake Install prompt. Known-incompatible titles
are excluded from hero recommendations. Hero media loads automatically.

**Unified Library and recovery:** All/Installed include registered local games
as well as account-held titles, without relabelling local records as Owned or
granting launch access. Account ownership and subscription evidence remain
separate. Cards show title and a concise action, not package/entitlement columns
or an idle "Checking access" status. Local problems offer **Install required**,
**Check installation**, or **Review launch issue** and open normal game detail
for that exact installation. An app-wide launch gate offers **View details**;
it is not presented as a broken installation or a compatibility verdict. Safe local
folder/launch-file checks run automatically there. Repair/full installation uses
the existing guarded flow only when available; registry removal requires
confirmation and preserves files/saves. Technical details stay behind disclosure.

**Catalogue collections and runtime selection:** Library has no detached
"Library details" footer. Official Xbox PC collection labels and feed identifiers
are discovered from the games page's PC markup and catalogue-script data literals;
downloaded JavaScript is never executed. Day-one games lead, followed by recently
added and the other official PC collections, including popularity, coming/leaving
soon, EA Play, Bethesda, Riot and in-game benefits when the official source defines
them. Feed order is retained in shelves. Public list membership is not a subscription
grant, Mac compatibility verdict, release/departure date or install authorization.
Each list has independent loading/failure recovery; opening the full collection
automatically resolves more catalogue records. Known package/anti-cheat blockers
also remain visible for installed games, which are never hidden by the unsupported
filter. Missing compatibility evidence stays explicitly unverified.
Coming-soon announcements and in-game benefit lists have separate preview shelves,
including when a playable PC package has not yet been published. They never enter
the qualified game grid or enable installation by virtue of editorial membership.
See All moves to the selected collection rather than silently changing a filter
elsewhere on the page.

Welcome and Settings show automatically observed CrossOver version/signature
status and link missing/unverified installs to CodeWeavers' trial download.
Settings accepts a signature-verified CrossOver app, an existing Wine/GPTK
executable or containing folder, and an identifiable existing bottle/prefix.
Choices persist separately by provider; selection never runs an engine, modifies
a bottle, proves licensing or enables the still-gated development game consumer.
CrossOver is not Wine/GPTK, and Apple's evaluation environment is not asserted
to be a licensed general-purpose replacement. Custom Wine/GPTK version provenance
remains unverified rather than inferred from a folder name.

**Offline compatibility catalogue:** The app resource bundle carries a versioned,
dated RO-market snapshot covering the complete union of the official PC lists
observed during generation (563 product IDs; 394 reported PC package formats).
Every record has an explicit anti-cheat knowledge state. Exact-name matches to
the MIT-licensed AreWeAntiCheatYet dataset provide 38 cross-store technology
references, not Microsoft Store or macOS clearance. Its Linux compatibility
statuses are not imported. The dataset revision and package source are recorded;
the full MIT notice ships with the data and Acknowledgments credits the authors.
Known Store-specific blockers remain separately source-backed. Missing facts
stay unknown; absence from a community dataset never means "no anti-cheat".
Live installed-file and Store observations take precedence over offline package
facts. `--gamepass-compatibility-export <path>` is an explicit nonshipping public
data regeneration command, not a normal startup network job or an account scan.
An independent publisher-evidence overlay binds four first-party records to exact
Store ID/title pairs: Halo Infinite, Halo MCC, VALORANT PC and League of Legends.
It records Windows/multiplayer/limited-service scope and checked dates. Halo's
documented mode exceptions and League's separate native Mac client are not turned
into blanket Mac support or rejection. These records override cross-store hints,
not runtime qualification; unrelated titles such as No Man's Sky remain unknown.

Ordinary startup shows the standalone green X logo with **Ode** below it over
a neutral background, not installed game cards or developer setup diagnostics.
Welcome, Account and the packaged app icon share one native vector X: standalone
on Welcome, a dark-green tile on Account, and a white tile in Finder and the Dock.
The wordmark is **Ode**; the accessible app name and security identifiers remain
X Ode and the existing Xodus identifiers. The icon renderer compiles the same
geometry as the native views, rather than maintaining a separate logo drawing.
Startup connects only through the existing management admission path and checks saved account status. A confirmed
saved sign-in starts account verification; the app stays gated until the app,
PC library, game service and returned Xbox profile identify the same account.
Welcome has one **Sign in with Xbox Live** button, replaced only by
**Cancel sign-in** during an active flow. There is no separate Check status,
Sign out or Try again button. The same login action rechecks connection/status
before starting an explicitly requested sign-in; missing pairing cannot enable
consent. Cancel sign-in waits for the existing cancellation result
and leaves Welcome locked. Choosing sign-in recovery for an expired/invalid
saved sign-in first completes the existing guarded removal stages.
The welcome copy distinguishes the X Ode sign-in from game-service consent.
Finishing launcher sign-in only refreshes game-service status; it never opens a
second Microsoft flow automatically. When a game or Xbox feature needs that
separate service identity, Account presents an explicit action and explains why
it may require another Microsoft sign-in. An unverified game-service account
also requires an explicit verification action; startup never retries consent.
During saved-status checks, Welcome identifies an expected macOS Keychain
request as checking or saving this X Ode sign-in.
Quit stays available through the native app menu, but existing mutation
holds still refuse termination until their operations settle.

**XO-010 normal Quit from Welcome:** Only the mandatory welcome presentation
opts its native sheet window out of AppKit's modal termination blocker, allowing
normal Quit to reach the existing termination delegate/coordinator. It does not
dismiss Welcome, unlock content or override operation refusal. The original
window policy is restored when Welcome leaves or its bridge is dismantled;
Account, installer and destructive sheets are not globally changed.

Pairing rejection and later connection failure are distinct. After helper and
engine identity validation, failure to start the service or negotiate its hello
offers recovery through that same login button and suggests normally closing another open X Ode copy first.
It does not assert that another copy is running or that a lock error was
received. Missing/invalid pairing retains the matching-app/service requirement.
An exact validated pre-HELLO `invalid-0` / `STATE_LOCKED` failure identifies the
separate already-owned-state case, without treating other uncorrelated responses
as valid. The login screen shows this actionable connection error instead of
hiding it behind a generic saved-sign-in failure. Startup exit handling drains
the typed pre-HELLO error before reporting process exit.
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

### Branded account actions and coordinated sign-out (18 October, source candidate)

Welcome uses **Sign in with Xbox Live**; Account uses **Sign out of Xbox Live**.
The app-owned Microsoft browser window is titled **Sign in to X Ode with
Microsoft**. Microsoft-hosted pages, publisher/consent text and registered client
IDs are unchanged: provider-page branding requires the properly owned, approved
Microsoft app registration, not a native label or substituted client ID.

The confirmation describes removal in order: game-service credentials, saved
PC-library credentials through the admitted broker, then the launcher profile.
It explains partial failure before the user commits. Running games, pending
install/repair/removal and account actions prevent sign-out. Once admitted, held
mutation, library and interactive-consent gates prevent new work or duplicate
prompts throughout every awaited stage. Pending product recovery is discarded;
management auth generations are fenced before removal so stale completions cannot
restore the profile.

The game-service stage requires the admitted
`private-xodus-service-signout.sh RUN_ID` helper and its private, process-matched
receipt. Success requires `serviceRunning:false`, `signedIn:false` and
`credentialsRemoved:true`, without an account binding. No status boolean alone
proves removal. An older runtime without that helper stops before broker or
launcher deletion; a failed or indeterminate helper reports that service state
and removal are unconfirmed. Broker failure after service removal reports that
the launcher was not disconnected; failed launcher logout reports that earlier
removals may already have occurred. Neither partial outcome claims full logout.
Only all three confirmed stages say **You're signed out of X Ode on this Mac**.
A later launcher-only signed-out receipt does not independently prove game-service
logout. Welcome and Account keep explicit sign-out available for remaining or
unchecked service credentials even when the launcher is already signed out.
Fresh confirmed launcher status and the same busy/work/auth gates still apply.
In that mixed state, game-service and broker removal run normally; the already
confirmed launcher stage needs neither a new login nor a redundant logout request.
Game files, saves, device licences, other apps and Microsoft browser
sessions are not removal targets.

The helper is a separately coordinated backend capability, not deployed by this
native source change. Synthetic checks exercise receipts, held gates, failure
stages and reconstructed saved-state clients without actual credential deletion.
Live restart, logout, consent and install acceptance remain separate runtime
qualification; this does not establish a unified Microsoft session.

The normal account flow uses system type, centered identity/state, generous
whitespace and only sign-in/out/cancel/status recovery actions. Login contains no
setup, cache, diagnostic, compatibility or technical disclosure. Saved sign-in
never promises that a game can download or run. Welcome and Account retain
**Sign in with Xbox Live** / **Sign out of Xbox Live** and the explicit sign-out confirmation.

Profile bootstrap does not depend on a profile already being cached: only
confirmed matching app/library/service identities admit the existing bound
profile refresh. Missing or mismatched identities do not. Account content and
game access remain closed until an available returned profile matches that
binding. Library/service updates trigger verification, and a newly verified
profile triggers game-access and visible-content loading without another login.
These source checks do not establish signed-app or live-account acceptance.
Sign-in support and exact partial-failure details live in Settings, including
while signed out; game/account data and advanced controls still require confirmed
sign-in. Achievements remain a separate Account-menu/Settings destination backed
by real Xbox data, including truthful empty/unavailable states.

Licenses and Acknowledgments are separate native windows available from the app
menu and Settings without login. The app's GPL-3.0-only grant is not a grant for
games, CrossOver, Microsoft or other components. Acknowledgments credits upstream
Xodus and the packaged CPython 3.14.8; existing bundled notices are unchanged.
App-owned display copy uses X Ode elsewhere. Internal paths/identifiers and
genuine Microsoft consent/registered-client text remain unchanged. No organization
or new source URL is invented. These are presentation changes only, not new
authorization, licensing or consent behavior.

## Freeze correction: operation feedback and library retry (source candidate)

**Single-entry download recovery (18 October, source candidate):** The main
Microsoft entry remains the welcome flow. Management, PC-library and game-service
interactive entry points share one in-process consent slot, without sharing
tokens or treating their identities as interchangeable. A pending or unobserved
management outcome retains that slot until a terminal status or observed
connection retirement; cancellation does not optimistically unlock another prompt.
The PC collection continues to use its existing admitted credential broker.

An Owned collection record is not a successful package acquisition. Ambiguous
check/install exit 11 no longer claims lost entitlement or demands sign-in.
Its exact product's **Check download access** explicitly checks the existing
service receipt. A fresh signed-in, account-bound result retries that product's
normal package/licence checks without opening consent. An unconfirmed or unbound
result offers **Continue with Microsoft**, explaining the uncertainty rather than
calling a transport failure signed-out. Only that explicit action invokes the
existing service sign-in route (which may reuse its saved session); a subsequent
fresh bound receipt is required before resuming the initiating install. Failed,
cancelled, malformed or unbound results never resume it. Other products cannot
consume this recovery. A new accepted attempt replaces the old error/log together.
A separate confirmed account recovery replaces the stale sign-in demand, but
does not claim that a download finished. Repair retains its existing protected
consent and is not automatically converted into a fresh installation.
The Game Pass probe's same ambiguous acquisition failure offers a status check,
not a sign-in instruction or a claim that the subscription expired.

**Remaining contract dependency:** This is not proof of one interactive consent
across Microsoft audiences. The admitted management status, collection broker and
game-service receipt do not establish a common authorized account. The existing
game status boolean cannot distinguish unavailable/socket/parse failure from no
saved user; acquisition exit 11 cannot distinguish interaction-required, expiry,
licence rejection and other preparation failures. The backend needs classified,
account-bound saved-session authorization and acquisition outcomes, with explicit
interaction-required/cancelled/expired/unavailable results and current
product/attempt attribution. The app must not transfer credentials, restart the
service automatically, consent silently or infer authorization from an Owned
badge. Source checks do not establish live sign-in or installer acceptance.

Trailer actions say **Watch trailer**, visibly and to VoiceOver, rather than
**Play** plus the game title. A package whose MicrosoftGame.config explicitly
declares only `MCPlaceholderStub.exe` remains registered but says **Installation
incomplete**, explains that the full Launcher package is needed and is excluded
from Play/Continue Playing. Prelaunch rechecks the manifest before spawning.
Missing executable metadata, a Minecraft title, or a mixed placeholder/full
executable list alone does not establish a placeholder-only package. This
does not diagnose which control was clicked in a running app or repair the
separate Launcher acquisition failure.

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

Detail presents account access, public Windows PC package listing/format, the separate Ode install check, and local installation state, then a disclosure of provenance/time/fingerprint. A catalog-listed package is not account download access or proof the Mac can install or run it. Installed state never bypasses revoked access policy. When multiple reasons block an action, present the most actionable primary reason and retain all facets.
Fresh public package observations take precedence over older candidate flags.
An identity-only record's false candidate flag means no package evidence was
supplied, not that Microsoft has no PC package. Cards retain an unknown state
without affirmative candidate or package observations; only details use positive
offline identification alongside the snapshot date and market. Omitted or
incomplete catalog package/platform fields never establish package absence.

## Fixture interactions

The preview has simulated connection/cancellation, searchable Library/Discover, detail/installation sheets, insufficient-space denial, experimental acknowledgment, an in-memory queue with explicit advancement/pause/cancel/retry, and a simulated launch message. Settings inject partial/stale/offline/empty/error snapshots. Nothing persists or contacts an account. Empty, blocked and error illustrations are also covered by editable mockups; production flow gates remain in [requirements](REQUIREMENTS.md).

## Accessible interaction

Focus order follows chrome -> scope/search -> content -> detail action. Sheets use native controls with cancel/default actions, readable wrapped errors and no required gestures. Decorative art is hidden from VoiceOver; game buttons combine textual evidence. No autoplay art, parallax or progress animation; reduce-motion therefore loses no content. Reduced-transparency mode uses an opaque system window background. Search/tab labels and states must be localized before release; current preview is English-only.
