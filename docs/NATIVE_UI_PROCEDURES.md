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

Inspect the populated app at its supported minimum and reference window sizes;
include a short/wide and a tall layout when affected. Check fixed artwork bounds,
title wrapping, filter/count scope, loading/error substitutions, ordinary native
controls and modal footer visibility. Inspect light and dark appearance together;
keep dark media treatment local instead of forcing an entire ordinary sheet.
Use one batched capture round, fix confirmed defects coherently and confirm once.

**Outcome:** usable, readable content and controls without changing the dense grid.
**Limits/stop:** an injected appearance is not an observed OS preference change;
do not expand into a redesign or indefinite polishing.

## Continuity

**Trigger:** navigation, selection, filtering or retained-host changes.
**Prerequisites:** real populated Library and Discover; identify visible anchors.

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

Check service behavior before UI behavior. Distinguish purchased, subscription,
unknown held acquisition, public catalog membership and local installation.
Unknown held games say "In your library"; they are neither Owned nor Free by
inference, and retain independently authorized actions. Check not installed,
installing/progress/cancel, installed, update, repair, failure and unsupported
states only when real evidence exists. Preserve expiry/account/launch guards.
Separate removing a list entry from uninstalling files; installation never
implies an unrequested launch.

**Outcome:** labels, filters/counts and actions agree with their actual authorities.
**Limits/stop:** unavailable entitled titles or unsafe lifecycle scenarios remain
unverified. Do not create mocks or damage installations to claim acceptance.
