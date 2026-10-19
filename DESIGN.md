# Design system: native art-first Library

**19 October naming/layout correction:** App-owned display name and wordmark
are **Ode to X**. Retain the existing native vector X and system typography.
Welcome uses the app mark; signed-in Account uses only the user's gamer picture
and identity, with no additional app logo or wordmark above it. Technical runtime
details belong in Settings, not Account. Library loads automatically after
sign-in and distinguishes a loaded empty collection from a request that has not
finished. Ordinary list content respects native toolbar bounds; only actual
full-bleed hero artwork extends underneath. Follow the system appearance.
This supersedes earlier display-name and account-header instructions below.

## User-directed visual contract

For the Library refresh, the user-selected v0.2 Figma Library (`5iQu716UFImHjRxJkf0t8V`, `3:115`) owns layout and flow; Apple Games for macOS owns visual treatment. The replacement is dark-reviewed, art-first and native Liquid Glass, while production follows the system appearance. The user rejected the flat v0.1 interpretation and bespoke floating menus. Artwork extends under the real system toolbar; navigation/search and the separate trailing account control remain native. The framework is SwiftUI/AppKit, not UIKit or a painted web dashboard.

The subsequent user critique rejected the hand-rolled rounded menu as non-native.
The navigation correction uses the real macOS window toolbar: a centered native
Library / Discover / Downloads picker, compact stock search and a trailing account
button. System chrome owns geometry, selected/focus state, appearance and
background; no custom capsule selection or forced white/dark toolbar treatment.
Keep the original artwork-led content, traffic lights and routes, without a web
sidebar, Xbox-green brand or copied Apple logo/art/source. The system toolbar
is already deployed. The Library-only refresh below is separately staged for
Dark/Light screenshot sign-off; it is not a shipping replacement or approval
to restyle Discover, detail, installation consent or Downloads.

## Surfaces

**X Ode first run (16 October, user-directed source correction):** one native
welcome sheet, standard Microsoft sign-in/cancel/retry controls, and an official
CodeWeavers trial link only after CrossOver detection reports absent/unverified.
Use the incumbent scrolling Account-sheet body and fixed adaptive footer,
semantic system text/background and system appearance. No game artwork, cached
installations, navigation controls or developer setup banner appears behind
unauthenticated Welcome. A current confirmed management sign-in dismisses the
sheet; an ordinary recheck preserves the existing confirmed view until its
result, while a failed recheck locks it again. Missing pairing is unavailable,
never an invented successful login. The main app/window/About/Quit names are
X Ode, without changing bundle/security identities. After sign-in, existing
Library composition and separate access/package/runtime checks remain intact.

**Streamlined gamer flow (10 October, owner-directed):** cards offer Install or
open details; installed games offer Play. Choosing Install is the user's download
intent and starts the existing guarded installation without a second confirmation
sheet. Entitlement/package/storage validation remains internal and runs before
transfer. Preparing, progress, cancellation and actual failures remain visible;
no success or compatibility is invented. Repair/removal retain their separate
protected flows. Game Pass membership comes from the catalogue, separately from
the subscription/account's actual download rights.

Details present existing title/art immediately and request selected-game metadata
independently of bulk catalogue artwork. They do not read package checks first
or expose access-verification/PC-package/Mac-support diagnostics. Hero trailers
are muted hover previews, respecting all existing motion/power/visibility fences.
Known-duration previews begin 35 percent into the trailer (at most 60 seconds);
unknown/short duration starts normally. Discover paging uses centered clickable
dots, no previous/next hero controls and no scrollbar. A bottom-only dark scrim
protects text without washing out the entire clip.

**Launcher feedback follow-up (10 October, candidate):** retain each tab's search
and the loaded Discover continuation rather than clearing the catalogue on
revisit. Discover features a manually controlled horizontal hero carousel with
up to five real catalogue titles, selected through centered dots; Continue Playing
uses native trackpad scrolling with hidden indicators. Only the hovered,
selected, visible hero may stream a muted trailer. Account,
detail and consent sheets, game launch, inactive scenes, Reduce Motion and Low
Power Mode suppress hero playback. Pausing retains the current player rather
than restarting the trailer. Missing trailers retain artwork.
macOS 14 retains static hero artwork because it lacks the scroll-visibility API;
animated heroes require macOS 15 or later.

Downloads exposes real management progress and cancellation, not fabricated
jobs; its empty state provides a Browse games route. CrossOver onboarding opens
the official CodeWeavers page for installation/trial and repeats publisher
signature detection when the app becomes active. Alternative runtime settings
remain declared configuration plans, not functional game-engine switching.
That last capability requires an actual launch-provider contract and cannot be
represented as shipped by changing a picker.

**Library (Operate, C3 visual direction approved; nonshipping):** a 340-point full-width hero uses the most
recent recorded, launchable installed game, with artwork under the system
toolbar, a transparent catalog logo (up to 420x120 points, otherwise a 40-point
bold system title), a 100x150 portrait poster and large native glass actions. A landscape
Continue Playing shelf follows, then Your Games/count and adaptive 2:3 portrait
covers. Each cover opens the existing detail surface; small glass Play/Install
and contextual menu actions appear on hover or keyboard focus and remain
reachable with VoiceOver. Errors remain visible below the art. Grid minimum
width is 170 points, maximum 220, with 24-point gaps and 56-point section insets;
at the owner-accepted 1440x874 review size the first row must enter the initial viewport. Resize may reduce the
column count, not clip controls or invent horizontal page scrolling.

Use a labels-hidden native segmented All / Installed / Owned / Game Pass Picker,
with its accessibility label retained, and a fixed-size trailing native Sort
Menu. Exact Store IDs join installed, account and Game Pass evidence once.
Importing never proves purchase; catalogue membership is independent of
subscription status, while installation still requires actual download rights.
Discover fills the available Game Pass catalogue in the background without a
per-game access check. The Library loads a known saved PC collection once
on appearance only after presence/migration checks succeed. Migration remains
explicit, errors preserve the last complete collection, and Refresh is in the
toolbar with Command-R. PC-library Sign out belongs in Account, not above the
grid. Import is in the toolbar with a help tag and in File with Command-Shift-I.

Landscape art tries real public hero/title art, then screenshots, then a
portrait cover cropped to fill, then validated local splash/tile art. Missing
optional landscape art leaves a semantic neutral surface, not a broken-image
glyph. Portrait covers never stretch square icons. Metadata/image failures do
not grant access or disable valid game actions. No real account artwork or
captures are committed. Native `backgroundExtensionEffect`, soft scroll edges,
`GlassEffectContainer`, `.glassProminent` and `.glass` are availability-gated;
older systems use ordinary native buttons/materials. No sampled artwork tint,
painted glass or forced production appearance is introduced.

C3 reinforces only Library chrome: native macOS 27 tabs and the stock
NSSearchField share a `.glassEffect(.regular, in: Capsule())` principal group.
Account, Import and Refresh use native `.glass` circular buttons. Art still
extends under the toolbar; no opaque full-width band is restored. Reduce
Transparency uses the semantic opaque `.background` style and native bordered
buttons; pre-26 systems use regular material/bordered controls. D2 reuses this
grouping for Discover; Downloads keeps its original toolbar grouping. Dark, Light and injected
app-local Reduce Transparency are separate visual-review states; injection
never changes the user's system preference. SwiftUI's real
`accessibilityReduceTransparency` is read-only; the review flag exercises this
app's opaque-material fallback, not a false claim that the OS preference was
toggled. Actual OS-level Reduce Transparency still needs user-present review.
The user approved the native regular-glass treatment. This source freeze does
not authorize installing/replacing the shipping app or forcing opaque chrome.

Play remains launch-only for a registered installed entry. An uninstalled owned
or eligible Game Pass title says Install, performs package/space validation
internally, and never auto-plays on completion. Public positive PC package
`MaxDownloadSizeInBytes` maxima appear as approximate download estimates, not
verified architecture/edition/package authorization. The install review uses
the backend's selected `packageBytes` or explicit unknown-size copy instead when
reviewing a repair; a new installation goes directly to progress.
Installed sizes are metadata-only filesystem measurements off the main thread,
with symlinks excluded, hardlinks counted once, overflow checks and a
100,000-entry/15-second traversal bound. Allocated and logical bytes are kept
separate; the label uses allocated bytes and the help tag explains logical
content and shared/cloned allocation. A per-installed-identity memory cache
coalesces requests for 15 minutes. Unavailable/incomplete sizes are hidden,
with a counts-only diagnostic; no per-tile private package check is added.

Frozen C3 has only a 64 MiB/40-image process cache. The subsequent functional
source adds persistent public-image caching without altering C3's signed review:
hashed URL keys in
`~/Library/Caches/Xodus/CatalogMedia`, atomic files, HTTP validators/expiry,
512 MiB LRU ceiling and existing redirect/MIME/byte/pixel guards. A fresh file
survives restart without another image request; expired files revalidate with
ETag/Last-Modified and confirmed 304 responses. Cache failures are redacted
diagnostics, not claims of persistence. Clear-cache logic exists; its Account
control follows. Read-only review/export modes remain memory-only. Public product
metadata is still requested separately; this is not a persistent catalog database.
Trailers remain future D3 native AVPlayer
streaming, not automatic whole-video downloads.

Hero, Continue Playing and covers show an Owned/Game Pass native glass badge only
when exact account/subscription evidence supports it. Genre/category and
recognized single-player, online-multiplayer, co-op and cross-platform features
come from DisplayCatalog, excluding explicitly console-only attributes; they do
not certify Mac runtime support. Only actually transparent Logo/TitledHeroArt
pixels qualify as a title logo; opaque artwork remains background art. Missing
optional facts hide without a placeholder. The read-only review also accepts the
owner-provided private Xbox stats cache: hours explicitly say "on Xbox",
achievement totals of zero mean unknown rather than "of 0", and a positive
friends-who-play count has private gamertags in its help tag. Local Last played
continues to use the Mac registry, not Xbox-wide time. Cumulative local time
remains absent: the registry retains only the latest session duration. Stats
are cache-only in this review; command scheduling, account-bound refresh and
the 15-minute backend refresh integration are not yet wired into ordinary
startup in frozen C3. The functional follow-up reads service status on ordinary
launch/foreground and Library Refresh, matches its opaque account hash to the
0600 cache, and invokes only `private-xodus-manage.py game-stats RUN_ID` when due.
A private, atomic, locked timestamp ledger throttles failures across restart too.
Current-account cached stats remain visible during revalidation; account change,
new sign-in and sign-out invalidate them before late results can publish. Success
requires matching service/receipt/cache hashes, counts and a fresh checkedAt.
Normal Quit cancels and joins the owned optional stats child. There is no periodic
poller, sign-in automation or changed Mac last-played provenance. There are no
stats service actions or fabricated values in read-only review.
The nonshipping read-only reviewer can open directly at Your Games using
`--library-grid`, without enabling interactions or changing installed data.
Freshness is in the Refresh help tag; unloaded Game Pass copy appears only in
its filter's native unavailable state, not in the Library body.

**Discover (Operate/explore, D2 direction approved; not installed):** v0.2 Browse
(`3:365`) and Search (`3:288`) supply placement and flow; Apple Games supplies
the native treatment. Empty-query browse has a 340-point, art-under-toolbar
landscape hero with an actual title/logo and View game or a reasoned
installed-only Play/protected Install action. The C3 native regular-glass
principal navigation/search group and circular Account/Refresh carry across,
with real Reduce Transparency handling and no painted capsule.

Browse genres uses only DisplayCatalog facts in the loaded page, with four
artwork-led genre tiles and a native Menu for every loaded genre/All genres.
Filtering never claims full-catalog genre coverage. Adaptive 2:3 covers use the
Library's 170–220-point widths, 24-point gaps and 56-point insets. Missing art,
logos, genres and size facts do not become invented recommendations or access.
Public metadata/image loads retain their separate bounds; metadata is
invalidated across market/language changes, not silently reused in another scope.

Typing removes the editorial hero and presents Your games before More games.
Browse says Explore games; internal source/corpus names remain private evidence,
not consumer headings. About these games uses plain access/coverage copy. A
valid zero-result search says No Results for the query, suggests another title
or clearing search and never suggests reconnecting. Existing debounce,
owned-first exact-ID matching, paging, Stop search, partial/failure disclosure
and detail/consent routes remain. Feed membership is not a subscription;
unconfirmed access opens View game rather than enabling Install. Installed
matches retain their Play/Stop and management actions. Install never auto-plays.

The isolated, nonshipping reviewer may read an owner-supplied 0600
`{products:[CatalogProduct]}` snapshot, validate its public PC scope and use local
title matching. It retains checked-catalog provenance privately, establishes no Game Pass membership,
starts no engine/service/stats refresh and keeps images memory-only. It may
open browse, populated search or genuine empty search directly at 1440x874.
130 detached checks and shipping compilation are not compositor, contrast,
VoiceOver or actual-system Reduce Transparency proof; Root owns capture and
user sign-off. Root captured Dark/Light browse, populated search and empty search;
all jobs finished normally. The user approved the direction and required the
consumer-copy correction above before source freeze. This is not shipping
admission. No proprietary cover, account record or capture is committed.

**Detail (Operate, D3 source candidate; visual review pending):** retain the
original detail flow in a native resizable sheet: a 340-point landscape header,
optional genuine title logo/portrait cover, existing native glass actions and
four visible independent Access / PC download / Mac compatibility / On this Mac
rows. Only a registered installed entry has Play/Stop. An uninstalled entitled
entry has Install; dismissal hands off to the existing protected package,
space and consent sheet, never download-and-play. Unknown access is explicit.
Public approximate size never becomes a verified package or support check.

Optional public content follows in flat sections: explicit trailer action and
horizontal screenshots, a bounded description measure, game information and
Windows PC requirements. Native AVKit `VideoPlayer`/`AVPlayer` streams validated
public HLS only when requested, stops/releases its item on dismissal and reports
failure with retry. No autoplay, video disk-cache download or Metascore. Image
media uses the existing bounded artwork/cache pipeline. Windows requirements
are labelled as publisher PC facts, not Mac support; conflicting editions are
disclosed instead of selecting one arbitrarily. Missing fields hide. Xbox hours
retain "on Xbox"; local Last played retains the installed Mac registry. Done
and Escape remain native sheet controls. Normal application appearance and
the previously approved native glass/Reduce Transparency treatment are retained.
Read-only capture disables trailer playback and all private startup/actions.
Detached checks and saved-public-response decoding are not compositor or
observed AVPlayer playback proof.

**Install/downloads (Operate):** protected installation sheet with
space/experimental consent; flat progress rows and recoverable errors.
Artwork never replaces evidence.

**S3/S5/S6 native operations:** preserve the Library's artwork-led Installed /
Continue Playing / Your PC games order. Install on an uninstalled PC tile opens
a protected native sheet with its title, exact destination, available storage
and honest unknown-size copy. Installation progress is a flat real-byte/phase
view in Library and Downloads, with Cancel and contextual recovery/log actions.
Installed row menus group Check for update / Repair, nondestructive Remove from
list, and separated confirmed Uninstall. The destructive confirmation explicitly
states save preservation; failed preservation never looks like success.
Account distinguishes game-service sign-in from library sign-in, using native
labels/buttons and no credential transfer. Existing semantic colors, SF symbols,
system text, keyboard defaults/cancellation and resize rules apply. Child
buttons retain their own accessibility identifiers rather than inheriting a
whole-section identifier. No additional navigation, sidebar or dashboard is
introduced. The source and signed package are admitted, installed and
owner-live-accepted at `1463cdb`. The owner verified child identifiers, Installed
menus, Install/Repair consent, real Downloads bytes/percentage and Cancel
control, Lara installation/registration, Play to its main menu, successful
Repair and save-preserving Uninstall/list update. Sign-in-required and
unsupported-package errors, Show log and Continue Playing session recording
were also observed. The owner closed the slice with no app defect; this is
bounded title/flow evidence, not complete accessibility or gameplay certification.

## Actual native implementation

**Phase 2 B5/B7/B8/B9 (`fee7f5f`, admitted and installed):** retain the same native grid and controls. A separate
Game Pass shelf follows Your PC games only with active service-owned status;
its tiles share Installed matching and the protected support-check/Install
flow. Account adds a quiet PC Game Pass status and explicit Check with honest
saved-status provenance, Unknown/failure and prerequisite states. No expiry,
ownership promotion or new navigation is invented. The shared Installed /
Continue Playing / matching-tile control becomes Stop only for the session
Xodus launched. Its disabled in-flight state and Stopping indicator are shared
across every surface; confirmed completion says Stopped rather than showing
a crash/retry. Ordinary gameplay Quit is unchanged. Source qualification and
owner live acceptance are separate gates; the latter remains partial.
Account also lists the four backend Setup items as Ready or their fix text.
One quiet Xodus needs setup banner links to a focused Setup sheet without
reading unrelated launcher credentials. Repair Xodus is explicit, fenced and
shows progress/error/Show log; missing game sign-in offers its existing action.
Supported Install consent shows the real download size; unsupported consent
shows only its reason, not unknown-size or future-download copy.
The owner observed cached status, the Setup list, successful Repair with
refreshed readiness and the Game Pass section header. After the user's native
Keychain unlock, the owner found probe-selection and stale Setup-readiness
defects. The installed `208939c` correction keeps the same controls, bounds null-result
probes to three, and refreshes Setup after a successful game-sign-in check.
The owner accepted Active, all Ready, and removal of the stale setup banner.
No authorization is automated.

**B6 credential approval:** preserve the native PC Library header and grid.
Presence inspection never reads a saved token or presents a native prompt.
When migration is needed, a quiet key label says **Xodus needs one-time Keychain
approval.** with an explicit Approve Keychain access button. Explain that the
separate credential helper stays unchanged on app updates, while updating the
helper itself may need another approval. Waiting has a small system progress
indicator and Cancel approval; refusal/cancellation is visible and cannot clear
the saved sign-in. No Microsoft refresh happens automatically after approval.
A verified new copy with failed old-item removal ends approval normally and
shows a secondary retained-legacy notice. Load/Refresh then uses the broker
copy, never an automatic delete retry. The admitted `2d420d1` broker package is
installed and live-migrated with `legacyRetained=false`. An identical
reinstallation and a distinct, separately signed Library review build both
read through the byte-frozen broker without an observed Keychain prompt.
These bounded observations do not establish unlimited future prompt immunity
or authorize helper updates.

**Phase 2 B1/B2/B3 (`7c3c1f0`, admitted, installed and live-accepted):** retain the existing native catalog grid and
toolbar. A nonblank Discover search places Your games above Microsoft Store;
local loaded-title matches remain visible even when Store results fail or omit
them. Owned tiles share the PC-library tile and its exact Installed Play match
or protected Install flow. Quiet semantic-text Owned/Game Pass badges describe
their separate evidence; no Xbox-green identity or new navigation is added.
Cached Plays on Mac / Not supported on Mac labels come only from private
bounded check receipts. Install/Repair consent shows Checking this game while
the fenced script runs, then real download size and support/reason before
enabling its default action. Cancel joins the check without installing.
The owner accepted real-art Discover including the previously rejected feed
members, owned-first Play/Install search and unsupported Celeste consent.
The copy refinement above follows that live acceptance and is installed in
`fee7f5f`; its deployment is not a separate live acceptance observation.

**S4 PC Library (admitted and installed `7ec1daa`):** the existing native Library retains Continue Playing
and Installed above a distinct Your PC games shelf. Signed out, one native
unavailable-content prompt offers Sign in, Browse games and Recent activity.
The sign-in sheet shows Microsoft's short-lived code, opens the exact Microsoft
verification link and offers Cancel. Signed in, a restrained header/count and stock
Refresh/Sign out controls lead an adaptive artwork/title grid using the existing
catalog-art component and geometry. Exact imported StoreId matches reuse the
same Play/retry/log controls and one-session guard. Other rows say Not installed,
not Install. A quiet excluded-game count and last-updated date describe the
complete filtered account collection; failed refresh retains only the previous
complete shelf with a clear stale notice. Main search filters this PC shelf;
Recent activity keeps its separate scope. This is a bounded adaptation of the
approved Figma Library hierarchy/native tokens, not a new UI world, invented
owned shelf or fixture source. Root separately closed live acceptance after
user-completed device-code sign-in: 13 PC games with real Store box art,
Hogwarts matched to Installed with shared Play, and Refresh/Sign out visible.
This does not certify parity with every Windows Xbox Owned-view entry or
complete accessibility coverage. The owned-view comparison remains open;
the section-identifier follow-up was fixed in S3/S5/S6 and independently
verified live by the owner.

**S1 installed Library refinement (admitted shipping `e401464`):** local tile art uses
Square480, Square150, then StoreLogo from the imported folder's ShellVisuals,
with the existing 60-point square geometry and system-symbol fallback.
Continue Playing appears above Installed only for the newest recorded
Xodus-launched imported game whose folder/script are available. Its splash
(tile fallback) leads a native 12-point-radius hero; title, optional publisher,
relative last-played date and the shared Play control sit on system material
below the image so contrast is independent of the artwork. This preserves the
approved Figma Library's artwork-first hierarchy and native composition without
copying its invented shelves, ownership labels, artwork or custom toolbar.
The hero and list share one process state/error/one-session guard. Art is
decorative; hero content and title-specific controls remain independently
accessible. No motion, personal-history read or network artwork request is
added. Missing art is silent; session-history save failure is a quiet
product message and never prevents play/termination state updates.
Source, neutral/native layout and installed-byte/signature/startup qualification
passed. Root separately closed the live gate using its already-approved native
ScreenCaptureKit observer of the installed app: actual Hogwarts tile art and,
after a Root-launched session, the real splash, title, publisher and relative
last-played date were visible. The test session ended by SIGTERM; shared Try
again and Show log were visible on the hero and row. This is bounded live
evidence, not a claim of natural-exit, complete accessibility or compositor
certification.

**Initial installed-game Play (admitted at `0926414`):** the non-activity Library begins with
an Installed section, separate from the unchanged owned-PC unavailable state.
User-imported entries use their config display name and a restrained system
gamecontroller icon, with native Play and list-only Remove actions. No artwork
request, ownership badge, mock shelf or game count is introduced. The empty
section has one short explanation and Import installed Xbox game. Two native
file panels select the installed folder and its executable working launch
script; cancellation changes nothing. Launching/Playing replace the Play label
for the one active session; other Play buttons are disabled. Nonzero exit shows
one plain error and Try again. Native button focus, title-specific accessibility
labels and `xodus.installed.*` identifiers preserve keyboard/VoiceOver access.
Quit leaves the game running; Remove keeps game files, launch script and saves.
This local list is not an ownership or engine registry claim. Main Library
still never reads TitleHub history; Recent activity remains separate.
Source/native-layout checks and installed-byte/signature/startup verification
passed. No screenshot, actual Import/Play interaction or live gameplay was used
for admission or deployment; those outcomes are not implied by neutral checks.

**User-directed Library semantic correction (historical unavailable state):** Library is the
default. Before S4's account-bound collection/PC join, it used one stock native
empty state, “Your PC library isn't available yet” / “Xodus can't yet verify
which PC games you own,” with real Browse games and Recent activity routes.
No TitleHub image feature, owned game count or fake install/play action was used
to fill this unavailable surface. That history boundary remains in S4. The
Figma Library's purchased/subscription fixture shelf and Apple
Games Continue Playing composition require matching access/installation
evidence; play history cannot fill them.

Recent activity is a separate explicit content scope within Library, with a
native Back to Library action and prominent cross-platform/not-owned-PC copy.
It retains the existing accepted square artwork grid, title-name Store action,
reported-platform filter and account fences, but has no featured history hero.
All history platforms, including PC/mixed, remain outside main PC Library until
ownership and PC Store applicability are independently evidenced. Console-only
activity is shown only here. Search is disabled in main Library and scoped to
the loaded activity window here; it never establishes ownership or Store
mapping. Main Library entry makes no saved-status/history request. Explicit
activity entry reuses the existing bounded deduplicated loader and retained
memory. This correction is independently admitted and installed at consumer
`2d741a7` with the unchanged signed c107 engine. Normal-startup ownership and
installed bytes were confirmed without invoking activity, Account or Store.
The retained native composition has not been visually captured in this pairing;
source/layout checks are not compositor or VoiceOver certification.

**Lean live-data slice:** owned-library enumeration remains unavailable.
The existing native toolbar, deployment target and repository tokens are
unchanged. Discover shows scoped public products and search as artwork-led Store
cards; catalog/access provenance stays in contextual info rather than repeated
ownership caveats. The separate Recent activity scope uses one explicit read
of actual TitleHub history and an adaptive native tile grid.
Reported PC/console/mixed/unknown platform tags and a native platform filter do
not establish Mac compatibility. Search in this scope filters only the loaded
history window. History has no Store mapping, entitlement or installation
evidence; its tiles do not fabricate product-detail or Play actions.
Engine-owned/installed Library enumeration still remains unavailable: the engine's registry response
is a constant empty vector, not an implemented durable registry or Mac scan.
It must not become "no games registered" or an installed-game list; Library
search is disabled. A real, read-only selected-folder marker check remains
visible, separate from retail identity, entitlement, installation and launch.
Product IDs, package metadata, provenance and
selected-folder marker inspection remain available in contextual information
disclosures. Operation-specific failures remain visible and actionable;
retained account snapshots are explicitly unconfirmed, not current saved-state
evidence. Product
detail has one availability line, with independent per-edition evidence in
Catalog info, a compact preferred size and a separate native Done footer.
Unchecked/empty/failed history has one clear state and explicit Account/load or
refresh action. Retained results visibly say they are previously checked;
account/connection changes and explicit Account checks clear personal memory.
Credential-present status carries no user identity binding, so a fresh status
cannot establish that earlier personal history belongs to the current account.
No Account check automatically rereads history.
Selected-folder inspection is secondary under Library details. Discover places
results directly after one scoped heading and any actual partial/failure notice.
Account stays
in the toolbar, and its cancellation, refresh and credential gates are
unchanged. No Home shelves, invented installed games, new framework or
speculative navigation API is introduced.

**Recent-title Store action:** a stock bordered "Find in Store" button accompanies
the activity tile entries without changing their artwork geometry
or tokens. The button has native keyboard focus/activation and a title-specific
VoiceOver label; containing accessibility groups keep the action independently
reachable. Only this explicit action routes the title name into the existing
Discover search. It does not establish a product/edition mapping or select a
result. The user chooses among catalog candidates, with the existing partial,
empty and error presentation; history and account state remain separate.

**Production hardening:** the shipping/live path no longer uses the invented
harbor/orbit promotional hero or game poster in Account. Title-specific artwork
comes only from normalized real Microsoft metadata, not bundled covers, invented
illustrations or an image-generation service. The shared native loader admits
only the exact Store CDN, disables redirects/auth/cookies and bounds each fetch
to 10 seconds, 8 MiB and 16 megapixels before decoding. Its decoded thumbnail
cache is memory-only. Missing/rejected/unqueried metadata and fetch failures
remain distinct; a failed fetch never changes metadata to "absent."
Setup/empty/error views keep semantic native window backgrounds. Fixture
illustrations remain only in the nonshipping preview source/resource set.
Remote metadata references are not a general redistribution/license grant;
distribution rights remain a separate release question.

`XodusToolbar` uses a principal `ToolbarItemGroup`, a real `.tabs` `Picker` on
macOS 27+ with a `.segmented` fallback on 14-26, stock `NSSearchField` and an
ordinary trailing toolbar `Button`. These are platform controls, not a
third-party kit or custom navigation shape. SDK 27+ is a build requirement,
independent of the proposed runtime baseline. The picker writes through
`AppState.navigate`, preserving scope resets and Command-1/2/3 routes. The
Scene's hidden-title-bar style and unified toolbar retain traffic lights and
window/menu/Dock identity while content extends only under the top container
safe area. The fixture-only path shares this navigation but
its Account button still opens only invented onboarding.

The toolbar and development/fixture status use semantic system appearance.
Remaining content actions use actual `.glassProminent` on macOS 26+, with normal
native fallbacks on older systems. `NativeGlass` remains available for other
content surfaces, not for repainting toolbar controls. Reduced transparency and
body light/dark treatment remain native. There is no fake CSS glass or private
SDK import.

The live development shell inherits this world without copying fixture game names or covers. It uses a labelled original landscape, a separate native account sheet and centered unavailable/empty states. The same scoped `NSSearchField` supplies toolbar search in live and fixture views: system bezel, search/cancel controls, semantic appearance and the existing field editor/focus binding. Empty unfocused search occupies 32 pt; editing, Command-F or nonempty text expands it to 220 pt. Downloads retains disabled search, and live Library eligibility rules remain unchanged. There is no duplicate hero search, wrapper icon, forced dark scheme or custom capsule. Fixture/development notices remain inside content rather than an opaque strip above the hero. Checked products use real BoxArt/poster references, with SF-symbol fallbacks only
for actual missing/rejected/unqueried or failed images. Product detail uses an
actual hero-role image when supplied, plus its real cover. TitleHub tile art
keeps its own aspect rather than being relabelled as SuperHeroArt. Four-facet detail does not turn catalog presence or saved sign-in into ownership. The original orbital-doorway app icon is reproducible with `tools/RenderAppIcon.swift`.

Account uses a bounded width/height range, a scrollable explanation/status body
and a separate adaptive native-action footer. Decoration contracts first at
short heights; longer action labels stack through one layout, not duplicated
button trees. The live text-only sheet prefers a compact 280 pt height instead
of the illustrated fixture's 620 pt height; long failures and expanded Account
info scroll without moving the action footer. Authentication predicates, stable identifiers, keyboard
cancellation, dismissal protection and explicit Account refresh are unchanged.
The main Scene declares a hidden-title-bar window and unified toolbar. No post-creation
bridge forces titlebar background, opacity or full-size content geometry, and
normal app activation is left to LaunchServices/AppKit. Removing those
overrides is not evidence that they previously disabled Liquid Glass.

Apple's [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
supports current-SDK standard SwiftUI/AppKit controls, fewer custom chrome
backgrounds, safe areas and preference/resize testing. This is macOS guidance,
not an iOS touch-target or Dynamic Type score. The deployed app's Mach-O metadata
records SDK 27 and minimum macOS 14; a lower deployment target is not an old-SDK
appearance opt-out. No sampled toolbar tint or additional decorative Glass is
used: the system compositor owns the backdrop. Actual artwork-dependent tint,
modern rendering and constrained-window toolbar placement remain live gates.

| Role | Rule |
| --- | --- |
| Body text / separators | native primary/secondary / Divider |
| Toolbar/status | system primary/secondary; no forced overlay color scheme |
| Controls | native system accent; real available Glass, older material fallback |
| Typography | SF system fonts and symbols; large feature title, native body/section hierarchy |
| Spacing | 4 pt base; 30 pt body inset; 12-24 pt groups; toolbar geometry owned by macOS |
| Entries | real Store covers fitted without branding crop / square history tiles; adaptive native grid |
| Detail | actual catalog hero/cover, followed by readable ordered evidence and a fixed Done footer |
| Motion | no nonessential animation/autoplay; reduced motion loses no information |

## Original imagery and licensing

Runtime Settings reuse the existing grouped native Form, standard Picker,
TextField, DisclosureGroup and buttons; no new navigation, decorative material
or custom control chrome. CrossOver is first-release supported; only a verified
official app observation defaults an unset profile. All alternatives are
Experimental with visible acknowledgement, outside the advanced disclosure.
Dependency status and its native check/official information actions stay in
Settings, rather than repeating a runtime wall in Library and Account. Dependency
actions remain visible; only explanatory/experimental copy collapses. Controls adapt to
constrained widths; checking/absent/unverified states do not fabricate readiness
or disable unrelated catalog/account actions. Advanced component
declarations remain separate from the primary provider choice, and configuration
planning never advertises installation or verified gameplay. Fixture mode
disables planning. Detached controls/layout checks are not a live visual,
VoiceOver or compositor-conformance claim.

Primary 2048 x 1152 scenes (sunset cliff harbor/ship, textured planetary vista/explorer, alpine lake/forest) are original authored CoreGraphics/ImageIO illustrations. `tools/RenderOriginalArt.swift` reproduces them. Secondary desert/forest/ocean worlds have original SVG source generated with Python's standard library and rasterized via native WebKit.

All are **stylized fixture placeholders, not game screenshots or real covers**. No external images, account data, paid assets, trademarks or AI-image service was used. Sources/provenance and original PNGs are GPL-3.0-only. Production must use properly sourced title-specific catalog art with an explicit rights/caching policy.

JPEG derivatives are embedded as data URIs in SVGs, deduplicated per scene, with a strict 10 MB per-screen limit. Original high-resolution PNG resources remain in the app; vectors/text and image crops remain editable in mockups.

## Evidence boundaries and revision history

[Nine v0.2 SVGs](design/README.md) preserve the original editable immersive
composition and the now-superseded custom navigation concept. They are not proof
of the newer system toolbar or live system refraction. In-process AppKit exports
render only the fixture's own NSView hierarchy; compositor/backdrop effects may
be absent. They prove native layout/resource rendering, not live Glass fidelity.

The latest header source follows an explicitly authorized historical private
Apple Games reference that was actually inspected. A fresh single-window capture
attempt failed; an alternative stopped at a false existing-permission preflight,
without requesting permission or capturing. No fresh reference was obtained or
published. The historical image and its account/game content remain private.

[v0.1 SVG archive](design/archive/v0.1/README.md) is explicitly superseded and not user-approved. Its earlier Figma vector import/inspection must not be presented as approval of the revised design. Repo sources/generators remain authoritative. [v0.2 Figma](https://www.figma.com/design/5iQu716UFImHjRxJkf0t8V?node-id=3-115) has nine successful editable imports with Library/Discover render inspection; import flattens some gradients/rounded-image fidelity and does not prove system Glass. [FigJam](https://www.figma.com/board/3MejlFaXHkogmJ3J5k79Gw) is proposed UX; detailed status is in the [mockup index](design/README.md).

Command-1/2/3, Command-F, native Settings and Escape cancellation remain. Decorative images are hidden from VoiceOver; action labels disclose simulations. Full VoiceOver/focus-return, live compositor, both-appearance, reduced-preference, contrast, resize and localization/RTL coverage remain release gates. See [actual build/check evidence](docs/VERIFICATION.md).
