# Native UI verification

These recipes use the existing app and native tools, not another test harness.
Keep private screenshots, traces and account observations outside the repository.

## Evidence and admission

Before interaction, record source commit and dirty delta, build configuration,
bundle path/identifier, executable hash, signature and actual PID. Record the
paired service identity separately when used. Include OS/SDK, display scale and
refresh, window bounds, appearance, relevant accessibility preferences, input
method, cache/network state, exact steps/timestamps, exit code and artifact path.
Coordinate foreground ownership; use exact-target controls and fail closed on
missing, ambiguous or wrong-role targets. Never interact with a guessed process.
For each finding retain its requirement ID, severity/confidence, rule source,
expected versus actual result, chosen correction and residuals. Distinguish
requested window size from measured viewport and inspect all relevant displays:
an activated offscreen window or another app's capture is not visible acceptance.
Reference the [current UI acceptance map](UI-CONTINUATION-SPEC.md); use this shared
schema for all five recipes rather than maintaining five duplicate manifests.

Distinguish source observations, compilation, existing deterministic checks,
real input, visible results and measured compositor behavior. None substitutes
for another. Record unavailable scenarios as unverified, not passed. Command
success alone does not prove scrolling, focus, rendering or operation completion.
Do not run account, reset, game or destructive actions without their own scope.
Stop on target drift, unexpected modal state, uncertain side effects or repeated
failure without new evidence.

## Native interface

**Trigger:** layout, controls, appearance or copy changes.
**Prerequisites:** admitted candidate, foreground window, known system appearance.

**Steps:** establish actual target/display and capture; compare populated and
affected loading/empty/error layouts at measured minimum/reference/constrained
bounds; inspect actions, text, footer and counts; preserve one coherent capture
round with before/after identity. Change only the app window within scope.

Inspect the populated app at its supported minimum and reference window sizes;
include a short/wide and a tall layout when affected. Check fixed artwork bounds,
title wrapping, filter/count scope, loading/error substitutions, ordinary native
controls and modal footer visibility. Inspect light and dark appearance together;
keep dark media treatment local instead of forcing an entire ordinary sheet.
Use one batched capture round, fix confirmed defects coherently and confirm once.

**Outcome:** usable, readable content and controls without changing the dense grid.
**Limits/stop:** an injected appearance is not an observed OS preference change;
do not expand into a redesign or indefinite polishing.

### Loading transitions

Verify startup/account checking separately from cold Library collection loading,
warm refresh and a title's launch. Cold, unfiltered Library loading without usable
account or local rows reserves the native card grid using static, noninteractive
placeholders. Pending requests must not suggest an empty collection or require
another sign-in. Existing local/account rows remain visible during a warm refresh;
errors, account approval and search results replace placeholders, not the content
they qualify. Observe immediate retirement on completion, failure and cancellation,
without a minimum display interval.

With the native lease admitted, inspect the branded startup and welcome controls,
the cold grid and a warm refresh at constrained/reference bounds in both
appearances. Check keyboard/VoiceOver navigation: decorative placeholders must not
be exposed as games or actions; the status and consent/retry controls must remain
available. Check Reduce Motion without changing an owner's global settings unless
separately authorized. A supported launch must name its title and actual
checking/preparation/opening/stopping state; existing error, retry, technical
details and Stop remain reachable. Never dismiss or cover a game's own failure.
Do not launch a real game or change accounts merely to manufacture this evidence
without the corresponding authorization. Offscreen checks are source evidence,
not installed visual acceptance.

For Continue Playing, COR-64 intentionally hides only the shelf's horizontal
indicator, including when macOS uses persistent scrollers. Preserve real native
scrolling and verify first-to-last cards by wheel/trackpad, keyboard and
accessibility routes; a hidden knob is not itself an available AX control.
The title/count and adjacent disclosure are one accessible navigation button
using the former See All destination (installed games, recently played sort).
The separate next-game arrow remains a scrolling action, not duplicate navigation.
Do not change the owner's scrollbar preference or hide indicators globally.
Instance-local legacy checks are source evidence, not installed acceptance.

### Detail-first shelf benchmark (REQ-84/85)

Compare the actual Apple TV sidebar destination (not an empty purchased Movies
library) with Ode's populated Library and Discover. Record exact PIDs, window
IDs/bounds and bundle versions before scoped captures or input. Inspect neutral
genre shelves and recorded Continue Playing groups; never infer a popularity
ranking from their position. Posters have one named detail action and no action
row, even on hover. Play/Install and native launcher recovery remain in details;
compatibility, operation failures and account-access restrictions remain honest.
Verify Return, context-menu View details, sheet dismissal and return focus,
including Continue Playing's separate disclosure/next-card controls.

For timing, use a finite sample (three warm tab/card transitions and a down/up
scroll pair per app) during a coordinated quiet interval. Start a monotonic
timer immediately before input and poll the smallest destination-specific AX
marker that was absent before the action. For an Ode detail sheet, query only
the window's immediate children for `AXSheet`; do not time a whole-library AX
traversal. Record dispatch and marker times separately. Acknowledged scrollbar
values are not painted-frame latency or sustained scrolling FPS. Likewise, AX
availability is not compositor completion: retain scoped before/after captures
and identify any transition/layout-shift observation separately. Discard stale
markers, wrong-focus samples and uncertain geometry, not just slow samples.

Already-running apps provide first-visit/warm observations, not cold launch or
cold network/cache proof. Do not clear the owner's caches or restart apps just
to manufacture a cold sample. Record overlapping builds or probes as confounders.
Targets such as 2.5 seconds cold or 200 milliseconds warm remain unproven until
the corresponding end-to-end native measurement exists.

An installed `outputOverflow` is not evidence of another running copy or an
AuthHost failure. The management OSLog category records a count-only overflow
origin: `diagnosticLifetime`, `stdoutQueue`, `stderrQueue`, `eventQueue` or
`requestBudget`. Preserve the first origin and its interval before choosing a
fix; the owned management child's exit can be a consequence of transport
retirement. The existing 1MiB diagnostic lifetime, 128-chunk/event queues and
64-pending-request limits remain unchanged. Source-only reproductions run with
`swift run XodusManagementChecks --overflow-checks`; they distinguish candidate
paths but do not identify the origin of a prior uninstrumented installed failure.

Descriptor measurement is disabled unless the app process has the exact
`XODUS_DESCRIPTOR_METRICS=1` opt-in. Its owned launcher forwards only that exact
value in addition to the existing operational environment allowlist. It does not
forward arbitrary environment variables or change the fixed Rust log level.
The management stderr reader accepts only ASCII LF-terminated lines of at most
256 bytes, under a separate 65,536-byte metrics lifetime budget:

```text
Ode descriptor metrics v1 enabled seq=1 budget=65536
Ode descriptor metrics v1 lookup seq=N hit=B forced=B coalesced=B
Ode descriptor metrics v1 attempt seq=N fetch=F
Ode descriptor metrics v1 terminal seq=N fetch=F ok=B
Ode descriptor metrics v1 checkpoint seq=N
Ode descriptor metrics v1 exhausted seq=N
```

Fields are ordered canonical unsigned decimals; `B` is zero or one. Sequence and
fetch numbers increase by one; each terminal names one active fetch exactly once.
A hit cannot also be forced or coalesced. A successful terminal describes the
raw upstream result, not cache persistence, account access or API success.
Only validated count-only lines reach the existing management OSLog sink.
Unknown versions, malformed/extra fields, gaps, missing enabled markers, byte
exhaustion and unfinished fetches cannot become zero-request proof.

`ManagementClient.descriptorMetricsCheckpoint()` uses the existing redacted
`diagnostics.export` request, without logging or saving its payload or requiring
the UI's diagnostic-file export. Its opt-in-only admission boundary waits for
already admitted requests within the existing diagnostics timeout and briefly
queues later requests while continuing to consume results. Queued requests keep
their original timeout budget and cancellation/disconnect behavior; admitted
and queued requests share the unchanged 64-request cap. It refuses concurrent
checkpoint requests, sends exactly one diagnostics export without implicit retry,
and requires both a successful result and a fresh drained
checkpoint marker across the independent stdout/stderr pipes. Missing markers
invalidate further measurement rather than reusing an old checkpoint. Compare
two such snapshots for one serialized interval; live events alone are
provisional. Ordinary app shutdown still cancels diagnostic reading and cannot
certify a missing checkpoint. This seam does not itself establish cold/warm
installed tab, login readiness or painted-frame performance acceptance.

For an installed measurement, the exclusive runtime owner launches the exact
paired app with that process-only opt-in, without changing global settings.
Wait for the previous Library/Discover work to settle, then use Account's
existing **Preview redacted diagnostic summary** action once for a baseline.
Navigate the bounded Library/Discover workflow, await its outstanding requests,
and use the same preview action again within 180 seconds. No Save action or
diagnostic file is needed. Both calls use the existing app-owned management
process; they never launch a neutral probe child. The app's `descriptor-metrics`
OSLog category emits only a checkpoint baseline and a complete aggregate delta
with monotonic elapsed milliseconds, or an explicit incomplete result. These
session-wide counts are not per-command attribution. A boundary drain timeout, a failed
export, a missing/late prior marker, an expired interval or a disconnected
session cannot certify the interval. Each diagnostic export is ordinally
accounted, including ordinary exports, so a delayed marker from an earlier
export cannot stand in for a newer missing marker. Disabled previews retain
their existing result and redaction behavior.
An incomplete count fence preserves a successful diagnostic preview and the
existing account/error state; only the count proof is discarded and logged as
incomplete. A real diagnostics API failure retains its existing error behavior.
Fixed `Descriptor boundary` reason/count logs distinguish admission drain,
drain timeout and missing/invalid marker from a completed fence. The first
091f39 installed preview produced no checkpoint despite a contiguous startup
stream; its exact missing-marker branch was not retained. The successor
boundary corrects the independently reproduced busy-entry/admission race,
not a proved cause of that observation or the earlier management overflow.

For keyboard acceptance, read the current keyboard-navigation setting without
changing it. Poster focus participation is explicit, including browse Library,
Continue Playing and Discover, not only search. Under `AppleKeyboardUIMode=0`,
verify a title-specific focus ring after detail dismissal, then dispatch actual
Return and confirm exactly one detail destination with no Play/Install action.
Calling the Swift Return handler directly is only synthetic coverage. An AX
focus setter returning success without an independently focused poster is not
permission to dispatch Return, nor is an AX menu action success proof of a
visible context menu. Apple's `focusable(_:interactions:)` documentation explains
the distinction between native button keyboard-navigation policy and explicit
custom focus participation on macOS 14 and later.

Playable heroes show account acquisition separately from public subscription
catalog membership; the latter is not an active plan or satisfying entitlement.
Installation/Play must never be used to infer either. Verify purchase,
subscription, overlapping facts and unknown/stale cases without commerce or
account mutation; use clearly labeled fixtures for unavailable account cases.
Unknown access contributes no hero subtitle; it must not be replaced with a
generic verification warning or guessed purchase/subscription status.
The prominent hero no longer repeats installation beside Play; installation
attention, checks, errors and launch controls remain elsewhere in the detail.

## Continuity

**Trigger:** navigation, selection, filtering or retained-host changes.
**Prerequisites:** real populated Library and Discover; identify visible anchors.

**Steps:** record per-tab scope/order/query and a recognizable visible row; perform
one warm round trip and detail dismissal; derive mid controls by actual wheel
input and filter through short/populated results; compare native offset/header
geometry and screenshots; only after primary success test See All and arrow.

Choose a recognizable row/artwork, filter/order and query in each destination.
Move the viewport, switch Library to Discover and back, and compare settled
anchors, not only stored IDs or normalized scrollbar fractions. Open and dismiss
a detail; verify the triggering context/focus remains useful. Use Continue
Playing's See All and confirm Installed/recently played and the collection are
visible together. Keep wrong-account data retirement independent of retention.

**Outcome:** each tab retains its own useful context without hidden active work.
**Limits/stop:** async content can alter scrollbar fractions; no auth changes to
manufacture a scenario. Stop rather than accepting a late or wrong-scope result.

## Performance

**Trigger:** low-FPS, delayed input or repeated-update report.
**Prerequisites:** matched Release builds/content/window/input and exclusive
profiling ownership; preserve the exact rollback.

**Steps:** establish baseline content/window/cache/input; start the existing
recorder and prove overlap with bounded real input; inspect updates, CPU and
compositor tracks separately; compare the same workload after a demonstrated
correction and retain limitations. Do not run another profiler concurrently.

Record Instruments SwiftUI and Animation Hitches when available; use Time
Profiler for CPU attribution, not as a GPU/FPS proxy. Synchronize recording-start
confirmation and bounded real input in one local shell when automation is used.
For the scroll complaint include actual trackpad slow scroll, flick, reversal
and edges; label programmatic scrolling separately. Compare overlapping input
intervals and view-update causes before narrowing a correction. Reuse unchanged
baseline evidence; change one demonstrated cause at a time.

**Outcome:** measured before/after behavior with exact scope and residuals.
**Limits/stop:** zero potential-hang rows, sample counts and encoded video frame
gaps are not FPS. Time-mapping warnings limit timing claims. No speculative blur,
glass or cache rewrite; stop a measurement lane that cannot establish overlap.

## Accessibility and motion

**Trigger:** actions, focus, modal, automatic paging or appearance changes.
**Prerequisites:** exact target and coordinated keyboard/VoiceOver observation.

**Steps:** traverse card/menu/search/sheet actions using ordinary keyboard, then
Full Keyboard Access; inspect semantics and title-specific actions in Inspector
and VoiceOver; observe focus return and separately eligible paging/video; check
real composited contrast and scoped preferences without unapproved OS mutation.

Check Tab/Shift-Tab, Return/Space, Escape, title-specific action names and focus
return. Test ordinary keyboard navigation and Full Keyboard Access separately.
Use Accessibility Inspector and VoiceOver for semantics/reachability; verify
actions do not become invisible keyboard stops. Observe system Reduce Motion,
Reduce Transparency and increased contrast separately from app-local injections.
Watch automatic hero paging while focused, offscreen, inactive and behind a
sheet; trailer playback and carousel paging require separate gates.

**Outcome:** native reachable actions, stable focus and no disruptive paging.
**Limits/stop:** source gates do not establish a VoiceOver/contrast certification.
Do not terminate gameplay as part of hidden-view or media cleanup.

## Launcher-state truth

**Trigger:** entitlement, compatibility, operation or action-presentation changes.
**Prerequisites:** admitted service/CLI contract and independently verified current
account authorization for any real operation.

**Steps:** evaluate the shared twelve-case state table in the continuation spec;
exercise the admitted service/CLI behavior before its UI action; inspect only
available real lifecycle states on an authorized target; compare authoritative
result/progress/logs and visible tile/detail actions; preserve registry, files,
saves and rollback and record any unobserved state explicitly.

Check service behavior before UI behavior. Distinguish purchased, subscription,
unknown held acquisition, public catalog membership and local installation.
Unknown held games say "In your library"; they are neither Owned nor Free by
inference, and retain independently authorized actions. Check not installed,
installing/progress/cancel, installed, update, repair, failure and unsupported
states only when real evidence exists. Preserve expiry/account/launch guards.
Separate removing a list entry from uninstalling files; installation never
implies an unrequested launch.

For per-title installation readiness, keep whole-library completeness separate
from the current account's resolved title. Unrelated missing details must not
disable a resolved held title; retained metadata for the unresolved title itself
must not authorize it. Check refresh-in-flight, failed refresh, account replacement,
credential approval, subscription alternatives and operation-busy states.
Disabled Install must show a visible reason, with only supported recovery
(for example, Refresh library); public PC metadata is not entitlement proof.
Populated Library content must not show or reserve space for routine background
access-check progress. Initial empty loading remains separate; background
readers and account/Play guards continue unchanged. Partial-detail notices
describe settled failures, not work in flight. Game Pass probe blockers must
describe account recovery first, then aggregate-library refresh, never infer
ownership loss from unrelated missing metadata.
The existing public descriptor cache already persists scoped metadata for five
minutes; do not create account ownership records from that cache.
Synthetic source checks use `swift run XodusPreview --library-access-check`
and `swift run XodusPreview --game-operation-check`; these do not establish
the disabled branch or successful installation of any title in a running app.

The recurring Discover Halloween shelf uses a provisional local Gregorian
October 1 through Sunday on or immediately after October 31 window, ending
at Monday midnight. It refreshes its date on appearance, activation, local
day change and timezone change, without a scheduled job or additional fetch.
Selection is limited to twelve deduplicated loaded PC catalogue products whose
existing Microsoft DisplayCatalog category metadata explicitly contains the
English words horror, spooky or Halloween. Broad categories, untranslated
categories without those words and missing metadata do not qualify by guesswork.
An empty selection omits the shelf. Ordinary cards/details and installation
guards are reused; shelf presence implies no discount, account access or Mac
compatibility. No complete seasonal catalogue is claimed.

Toolbar account/import actions share a native group with twelve points of
trailing clearance. The account button reuses the existing validated Xbox
profile avatar only when its cache matches the current account binding;
sign-out/account replacement removes that identity immediately. Missing,
loading and failed pictures retain a labeled account fallback, not a generic
game-art placeholder. The profile contract has no authoritative membership
tier: omit a tier ring/badge rather than infer Ultimate from title access or
a PC Game Pass probe. Offscreen source layout does not establish actual
window-corner clearance; capture minimum/wide native evidence under a lease.

Unified game details use a separate detail-owned `InstalledProductAccess`
instance to read the selected uninstalled PC product ID through the existing
`ode.account.read.v1` license section. This does not depend on unrelated
library completeness and does not replace the installed-inventory reader.
The current-account, exact-ID, unexpired permitted response enables the Install
control, not a download entitlement or ownership badge. In frozen `e8650d7`
the pre-existing actual button called the direct-install API, which created
and automatically confirmed an internal consent while hiding its sheet.
That build did not provide visible review; an enabled Install click could
start a download. The successor button calls `prepareInstall` instead and
shows the existing review sheet. Only its explicit Install confirmation
starts the operation; Cancel performs no installation or registry write.
The direct-install API remains separate from this interactive button path.
Denied/unknown/error/expired results remain explicit beside Install, with
an exact-ID retry; account replacement/sign-out revoke the response.
The actual native `install <ID>` path remains authoritative for Windows
package selection, content license/key, destination, disk and operation
admission. Legacy/unified routes are not interchangeable, and the legacy
unbound Game Pass receipt is not promoted to unified account evidence.
Hero blockers use an opaque-dark scrim with white text and independent
recovery controls; the hero grows rather than clipping long reasons.

**Outcome:** labels, filters/counts and actions agree with their actual authorities.
**Limits/stop:** unavailable entitled titles or unsafe lifecycle scenarios remain
unverified. Do not create mocks or damage installations to claim acceptance.
