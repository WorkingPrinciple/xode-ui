# Local game-engine qualification

## Session register and live ledger

| Session | Window | State |
|---|---|---|
| 1 | 20 October 2026, 08:48-20:48 local (+03:00) | Closed; five standalone controls attempted, zero Xbox game launches in this session. Historical Xbox successes remain separate. |
| 2 | Renewed 21 October 2026; ends 22 October at 08:28:46 local (+03:00) | Active joint-product investigation. Registered NMS launch actually attempted: package service returned `entry not found`; no Wine/game start. Three additional controls attempted, none qualified for gameplay. |
| 3 | Planned for 22 October 2026 | Planned only. No results, automatic extension, or additional wake/security-setting changes are implied. |

The full package-filtered title queue and reviewed per-title state are in
[the game test ledger](GAME-TEST-LEDGER.md). Its scope is the checked public
catalogue, not an account entitlement inventory. Session 2 includes recovery
and corrective work; it must not inherit Session 1's conclusions uncritically.

## Testing constitution

1. Test **Ode to X together with our modified Xodus services/libraries, built
   shims and the exact Wine/CrossOver build**. Inspect local modifications rather
   than silently substituting stock dependencies.
2. Aim to find, reproduce and fix defects, not maximize process-start or document
   counts. Fix the responsible layer and verify the integration across repositories.
   A harness fix is not a game fix or proof that the app works.
3. Recover the historically working NMS and Hogwarts CrossOver configurations
   first. Preserve them before engine substitutions. Prefer free Wine, rotate
   supported free builds where useful, and retain CrossOver as a valid fallback.
4. Spend at most 15 minutes of active debugging per title across free engines,
   then at most 15 minutes on CrossOver. Record start/end and accumulated active
   time, including retries. Downloads and idle windows are not gameplay or debugging.
5. Inventory the catalogue before claiming coverage. For the `MSI*` queue require
   explicit PC-package evidence and format `MSIXVC` or `MSIX`. Keep Appx, EAppx
   and unidentified formats outside that queue; do not equate MSIXVC with MSI.
6. Separate public package evidence, authenticated access, installed residency,
   authorization, executable load, graphics, menu, gameplay and endurance.
   Unknown access never means unowned; no process/window alone proves gameplay.
7. Capture and inspect the **full desktop on every attached display**, before
   and after launches and significant inputs. Include separate error dialogs;
   preserve display geometry, timestamps and exact owned process/window identities.
   An occluded/offscreen or locked display is unobservable, not a graphics failure.
8. Make every blocker falsifiable: identify the failing stage, observed error,
   exact configuration, attempted supported remedy and the next action or required
   permission. A hash mismatch is drift evidence, not proof of incompatibility.
   Stop repeating an unchanged hypothesis after two matching failures.
9. Preserve known-working source and artifacts, saves and account state.
   Record cross-repository revisions, dirty changes, engine/shim hashes, settings,
   evidence, result and rollback for each experiment. Never overwrite prior receipts.
10. Bound every run and clean up only verified research-owned processes.
    Capture termination/cleanup results, including surviving debuggers.
    A mock cleanup check is not proof of actual post-run cleanup.
11. Do not bypass credential, consent, licence, security or shipping-admission
    rules. Do not enable the disabled GitHub Actions workflow. Keep account data,
    keys and full-desktop evidence private; public package data is not entitlement.
12. A fix is accepted only after the original failure is reproduced, the changed
    configuration passes the affected behavior, and the preserved baseline is
    checked for regression. Otherwise label it source-only, harness-only or
    unverified. No production/login-readiness claim follows from catalogue triage.
13. Use the renewed window actively on dependency-ready work. Do not repeat
    status-only wakeups for hours. Record a genuine consent/availability hold
    and work on another admissible joint-product slice. At the deadline stop,
    preserve the handoff and attempt the scheduled five-minute lock restoration.

The owner explicitly approved relevant installs, process termination/restarts,
game launches and desktop/window arrangement for Session 2. Prefer the Studio
Display for games; the operator moved the editor to the MacBook display.
Full-screen capture remains required on both, with particular attention to
separate error messages. This approval does not include password entry, new
interactive sign-in consent, purchases or security bypasses.

## Joint delivery scope

Owner clarification, 21 October 2026: **Ode to X and the modified Xodus
libraries, services and shims are the product under test and will be delivered
together.** Qualification is not an app-only review or an independent stock-Wine
compatibility exercise.

Trace each finding across the native app and modified runtime repositories.
Apply fixes to the owning layer or both layers where required, and carry the
corresponding feedback, contracts and regression coverage across that boundary.
Do not patch only the UI around a runtime defect or repair the runtime while
leaving the app's integration broken. A finding need not produce artificial
changes in both repositories when only one layer is responsible.

End-to-end evidence must identify the app, modified runtime/libraries/shims,
engine and launch configuration tested together. Standalone controls remain
diagnostic evidence, not joint-product acceptance. Preserve existing credential,
security and shipping-admission requirements; joint scope does not authorize
unattended credential access or replacing unrelated live services.

## Fix and correction ledger

These entries distinguish product code, diagnostic harness work, supported
configuration changes and corrected reporting. None is a new Xbox gameplay
qualification.

| Item | Layer / session | Change and observed result | Remaining limit |
|---|---|---|---|
| Missing metadata treated as confirmed PC-package absence | Native app; before Session 1, `af91e25` | Tri-state package listing, related Library/Discover/detail presentation and footer corrections committed; prior source checks recorded | Not an engine, entitlement or game-launch fix |
| OpenTTD hardware-acceleration warning / graphics setup | Standalone control; Session 1 | Explicit win32/software graphics and OpenGFX configuration produced a visible running world | No Xbox package, audio, controller or endurance acceptance |
| SuperTux startup/input impediments | Standalone control/harness; Session 1 | Explicit Windows data/user paths, software renderer, documented offline config and scoped input helper reached a level; synthetic movement/hit observed | No physical input, Xbox package, audio or endurance acceptance |
| Unciv missing physical fonts on stable Wine 11.0 | Standalone research prefix; Session 1 | Six fonts already bundled with that Wine build copied into its research prefix; language-selection screen rendered | No playable turn or joint-product result |
| Game-window crops missed separate errors | Evidence harness; Session 1 | Full-desktop captures exposed Luanti debugger dialogs | All-display coverage and occlusion still need review; do not promote primary-screen capture alone |
| Debuggers survived game/server cleanup | Research cleanup; Session 1 | Exact residual debugger ownership verified and those PIDs terminated | One cleanup observation, not proof all future errors are automatically reaped |
| Locked-display black screenshots misinterpreted | Reporting/harness; Session 1 | Outcomes corrected to unobservable; guard prevents unobservable visual assertions | Lock does not generally prevent OS game launch; hours of repeated lock checks were not progress |
| Runner initial-lock/finally cleanup defects | Evidence harness; Session 1 | Initial lock-state failure corrected; bounded cleanup paths added; four mocked checks and real pre-launch lock refusal recorded | Mock coverage is not actual game lifecycle/cleanup qualification |
| Service drift treated as a universal launch blocker | Investigation/reporting; Session 2 correction | Restored historical NMS/Hogwarts baseline and identified modified fork/private socket support | Current consumer pairing and working route still require recovery; no live incompatibility proven from hashes |
| No complete package-filtered queue | Test tracking; Session 2 | Deterministic ledger now lists all 374 matching catalogue IDs with untested/unknown states preserved | A queue is not 374 tests or proof of current account access |

Confirmed joint-product Xbox gameplay fixes from Sessions 1-2: **none yet**.
Findings that have only a source patch or configuration remedy must retain that
label until the failing joint flow is rerun.

## Session 1 adversarial review and Session 2 corrective actions

Independent host-native review of the prior evidence returned **REVISE**.
The review also inspected the two early Session 2 controls. Findings below
distinguish demonstrated evidence gaps from reviewer hypotheses.

| Severity | Finding | Consequence / required correction | Current disposition |
|---|---|---|---|
| Blocker for joint-product acceptance | Session 1 executed standalone controls, not Ode to X plus the modified package/runtime route | Controls cannot establish the delivered app's installation, authorization or launch behavior | Joint scope and historical NMS/Hogwarts baseline now explicit; actual NMS route exercised in Session 2 below |
| Major | The old preserved consumer's fixed socket was overgeneralized to the whole modified fork, and hash drift became a stop condition without reproducing the failure | Lost an available investigation path; inspect actual producer/consumer roles and obtain a real stage error | Private helper supports `--socket`; modified private broker exists. This does not alone reroute the fixed package-key consumer |
| Major | Repeated locked-display checks displaced useful investigation for much of Session 1 | Lock was an observation limit, not proof macOS prevents game launches; status wakeups did not add game evidence | User unlocked and disabled locking for this window; continuation must act on hypotheses and admissible work, not repeat the old hold |
| Blocker for visual verdicts on affected runs | Early Session 2 Brogue/Cataclysm captures showed the orchestrator rather than a game, despite named-window metadata | Those captures cannot establish a menu or gameplay. Occlusion/Space/compositing cause was not proven from that evidence | New all-display capture helper records display geometry, owned windows and potential occluders; absent/occluded targets refuse visual eligibility |
| Major | Mocked capture success did not exercise real desktop content or all displays | Prior four mocks covered control flow, not visual truth | Five updated runner mocks include visibility rejection; real helper captures both active displays and rejects nonexistent-PID/duplicate/invalid-label cases |
| Evidence limit | Elapsed launch receipts are not a complete per-title active-debugging ledger | Cannot certify all cumulative budgets merely from process lifetimes | Record accumulated investigation time on subsequent retries; do not reconstruct unsupported totals |

Positive evidence retained: false-by-default menu/gameplay flags, exact-prefix
cleanup, separately verified residual debugger cleanup, and honest labeling of
mock checks versus real game runs. Prior OpenTTD/SuperTux observations remain
standalone-control results, not invalidated Xbox results.

Review corrections: identical MoltenVK log endings do **not** prove truncation
or an engine stall; parent `fsync` cannot flush child user-space buffers.
Window-only captures would violate the full-screen requirement and were rejected.
The review's suggestion that macOS honors `XDG_RUNTIME_DIR` was rejected after
checking the fork's platform branches: only Linux uses that override; macOS
returns `/tmp/`. Full-desktop capture can incidentally include unrelated content;
that evidence stays private rather than cropping away possible error dialogs.

### First actual Session 2 Xbox route attempt

At **2026-10-21T05:55:59Z**, the unchanged registered NMS launcher was invoked
with a fresh run ID, preserving its CLI, custom runtime/shims, pinned MoltenVK
and CrossOver selection. It exited 1 **before Wine/game startup**:
`package key service failed: invalid package key response frame`.
The service log in the matching minute independently recorded the exact
nonsecret error **`entry not found`**.

Source inspection explains the misleading message: the service converts any
request-handler error into an empty response, while the CLI rejects a zero-size
response as an invalid frame. A missing stored entry and incompatible framing
are therefore indistinguishable to that CLI. The failed lookup's exact
credential/token is not established; this is not proof of absent entitlement or
an incompatible service build. No game process remained, no new sign-in was
initiated, and no credentials/content keys were printed or retained.

The attempt also exposed a harness defect: cleanup ran the preserved wineserver
despite never reaching Wine and returned 1. That is recorded as a cleanup-command
failure, not successful cleanup. The process snapshot showed no NMS process.
Do not repeat the same launch unchanged: next address the typed-error gap and
the isolated-account versus legacy-service integration without forcing another
login or silently switching accounts.

## Session 2 baseline recovery

Read-only source/artifact inspection on 21 October recovered these components.
This is an identity ledger, **not a reproduced working configuration or a backup**.
Do not infer a build-to-source mapping from a nearby branch or matching filename.

| Component | Recovered identity / observation | Remaining work before replacement |
|---|---|---|
| Unified-account fork | Session-owned `ode-unified-engine`, clean `91624782862ef0ffb833bbbf1204a8c54629124c` | Separate source candidate from the signed engine actually used by the installed app; preserve macOS permission boundaries |
| Legacy modified service/launcher source | Fork ref `private/ai-hogwarts-runtime` at `7ae8ffe`; includes service lifecycle changes `c43a47b` and `2004d49` | Bind exact source/build inputs to the live artifact; old manifest drift alone is not a compatibility verdict |
| Modified runtime/shim source | Existing private runtime worktree at `cc051eb`; four unrelated untracked probe files observed and left untouched | Identify which built DLLs came from which source changes; do not overwrite that worktree |
| NMS preserved CLI | SHA-256 `0d0141dadd2512454122e592ef170c6aa72e78fa997568296dcb7150448b38e4` | Recover its source and compatible consumer/service route |
| Shared service, disk bytes | SHA-256 `a3cc1dd758e47be52700f84ff6874c240cca3238ffdcb9282d26ba19888286eb` | Retain the distinction between current disk identity, historical run identity and source provenance |
| NMS `runtime/xgameruntime.dll` | SHA-256 `6c9d97d3b1690c6c314d303be5d6da82f630808fc33a57395c8e102216a802a8` | Record the rest of the actual loaded shim set and source mapping |
| NMS `runtime/xgameruntime_legacy.dll` | SHA-256 `de6f1c47f3cfb087655a4852c185cf89c3d64ca5e2327146d424426d3b7944a5` | A file's presence does not prove that a game loaded it |
| Hogwarts historical configuration | `HogwartsPrivateStock` bottle retains `xgameruntime.dll` and `windows.web.dll`; fork contains isolated Hogwarts launcher | Locate actual package/content and prior successful-run evidence before claiming a new launch |
| Locally patched Wine build recipe | Fork `build-crossover-wine-af-unix.sh` references CrossOver source 26.3.0 and Xodus Wine AF_UNIX patch `6b7313c1bd` | Recipe inspection does not prove this Wine build is installed or used; do not run this provisioning script blindly |
| Private transport helper | Preserved `private-stock-ipc.py` accepts `--socket`; unified-account fork has a configurable private broker | Establish the complete consumer route and supported request protocol, not just endpoint configurability |

## Reproducibility and regression tracking

Preserve the known-working joint configuration before changing it. For each
experiment or fix, retain the exact repository commits and any uncommitted
source changes, built artifact hashes, engine version, shim/library set,
launcher arguments and nonsecret configuration. Record the observed baseline,
what changed, the result and how to restore the prior configuration. Keep
private evidence local; never retain credentials or content keys in this ledger.

Use bounded, attributable changes and separate research configurations from
the working installation. Commit source fixes in their owning repositories,
cross-reference the app/runtime revisions tested together, and add focused
regression coverage for confirmed defects where feasible. Before accepting a
replacement, rerun the affected behavior and the known-working path; if that
cannot be done, mark it unverified and retain the previous artifacts. A later
session must be able to reproduce or revert the experiment without reconstructing
its setup from conversation history.

## Historical Xbox launches: do not reset the baseline

Owner clarification, 21 October 2026: **No Man's Sky and Hogwarts Legacy
previously launched using our modified Xodus fork, libraries and shims with
CrossOver.** These are not merely standalone Windows control games.
`PAUSE-HANDOFF.md` independently records historical NMS 7.6 in-world rendering.
The equivalent Hogwarts run receipt has not yet been located in this review;
retain it as owner-reported history, not a newly reproduced result.

The fork is materially modified. The session-owned `files/ode-unified-engine`
checkout at `91624782862ef0ffb833bbbf1204a8c54629124c` contains the unified-account
work, a private configurable-socket runtime broker and an isolated package-license
qualifier. Inspect the actual fork and known-working launch configuration before
concluding that only the legacy shared-service route exists.

The recent batch's **zero Xbox game launches** means zero in that batch, not
zero in project history. The observed service hash/manifest mismatch identifies
an unreconciled preserved route; it does not by itself prove incompatibility or
invalidate previous successful launches. Recover the working NMS/Hogwarts
CrossOver configurations and their service, launcher and shim identities before
evaluating free-engine substitutions. Do not replace that task with unrelated
standalone controls or claim fresh gameplay without observing it.

## Scope and time budget

The owner approved real downloads, installations, launches, retries and removal
of research-created games on 20 October 2026. Start with five Xbox PC titles;
extend to ten only after the first legitimate package-to-engine path works.
The latest owner budget is **15 minutes total across free engines per title**,
then **at most 15 minutes on CrossOver**, with a 12-hour overall ceiling starting
at 08:48 +03:00 on 20 October 2026 (finish by 17:48 UTC).
Record elapsed investigation and observations rather than claiming unperformed
test time. Download time and unattended process survival are not gameplay.
Three hundred titles cannot all receive 30-minute sequential sessions within
12 hours: at most 24 fit before download/setup/reporting overhead. Catalogue-wide
triage must remain distinct from actually downloaded and launched games.

**Updated owner priority:** try available no-additional-license engines first,
rotate to another free engine where practical, and use CrossOver last. Initial
CrossOver observations below predate this correction and are baseline controls,
not the requested free-first comparison.

Test in this order, subject to actual PC package and account access:

| Title | Purpose | Initial engine |
|---|---|---|
| No Man's Sky | Existing registered Xbox package and preserved launcher; first end-to-end test | Preserve its exact existing pair; no arbitrary engine substitution |
| Skyrim Special Edition PC | Single-player candidate; verify exact Store edition first | Free Wine where an admitted package route exists |
| Fallout 4 | Another single-player candidate; verify package and account access first | Free Wine, CrossOver fallback last |
| Hades II | Smaller candidate where the current account can acquire the exact PC package | Free Wine, CrossOver fallback last |
| Hollow Knight | Smaller candidate; do not equate Steam base game with Xbox Voidheart edition | Free Wine, CrossOver fallback last |

These are candidates, not an entitlement inventory or supported-game list.
Substitute unavailable titles using observed account/package evidence. An
encrypted package cannot be passed directly to Wine as if it were a PE file.

## Execution and evidence

1. Verify local capacity, exact runtime identity and current game activity.
2. Inspect each launcher and its effects before execution. Preserve an existing
   title's immutable CLI/service/script pairing; never transplant package-key
   protocols onto a management broker or copy content keys.
3. Use a dedicated research directory and a fresh prefix for new installations.
   Keep existing games, saves, account state and unrelated processes untouched.
4. Attempt legitimate startup. Diagnose the actual failing stage and try a
   supported alternative within the title's budget. Track owned process IDs for
   termination/restart; never use process-name-wide kills.
5. Record storefront, product ID, package/build, engine/graphics identity,
   hardware/OS, timestamps, exact commands and nonsecret observations.
6. Classify download, install, authorization, executable-load, graphics,
   menu and playable-scene outcomes separately. A process or window alone does
   not demonstrate a visible menu, and a menu does not certify gameplay.
   Per the owner's screenshot requirement, capture the full screen before and
   after each run and inspect separate crash/debugger dialogs and macOS
   notifications. Game-window crops alone are insufficient evidence. Attribute
   errors to the correct title/engine instead of blaming a foreground game for
   another title's dialog.
7. Remove only specifically identified research-created downloads, game folders
   and prefixes after evidence is retained. Existing installations are not
   cleanup targets.

No unattended sign-in/out, credential extraction, Keychain approval, trial/license
bypass, quarantine removal or Gatekeeper bypass is part of these tests. Record
an actual permission/license rejection without repeatedly triggering it.

## Engine controls

Account-free Windows games may be run in separate research prefixes to determine
whether Wine/window/graphics startup works independently of Xbox packaging.
They are **controls, not substitutes for the five Xbox-title tests**.

The first control is the official Luanti 5.17.0 Windows x64 portable release.
Its downloaded SHA-256 matches the upstream release digest:
`3ce20c77f5c206a988d7a6b883439e2759e3cf67428c9dbcf99ecd2936da631c`.
Installed CrossOver 26.3 passed strict/deep signature verification and macOS
execution assessment before creating its separate research bottle.

## Current results

| Control | Engine | Actually observed |
|---|---|---|
| Luanti 5.17.0 Windows x64 | CrossOver 26.3 | Executable started, OpenGL context creation failed and game crashed; legacy OpenGL retry also faulted. No menu success. |
| OpenTTD 15.3 Windows x64 + OpenGFX 8.0 | CrossOver 26.3 | Menu visually captured, initially with a hardware-acceleration warning. Explicit `win32`/`32bpp-optimized` software retry generated and displayed a running world. No audio, controller or multiplayer test. |
| SuperTux 0.7.0 Windows x64 | CrossOver 26.3 | Initial invocation exited; explicit Windows data/user paths and SDL software rendering displayed animated startup consent UI. Not yet a playable-level result. |
| Luanti 5.17.0 Windows x64 | Free Gcenx Wine 11.18, then stable 11.0 | Both actually executed. OpenGL context creation failed; 11.18 displayed a black window and 11.0 also faulted. Neither reached a menu. No unchanged CrossOver rerun after its earlier equivalent failures. |
| OpenTTD 15.3 Windows x64 + OpenGFX 8.0 | Free Gcenx Wine 11.18 | Generated world and advancing simulation clock visually captured using `win32`/`32bpp-optimized`, hardware acceleration off, sound/music off. No input, audio, save/reload or multiplayer qualification. |
| SuperTux 0.7.0 Windows x64 | Free Gcenx Wine 11.18 | SDL software renderer, offline config, main menu, intro, world map and actual "Welcome to Antarctica" level visually verified. A locally compiled helper verified the exact window title and executable inside this research prefix before sending Windows messages; extended arrow scan codes were required for map navigation. Foreground-checked Wine `SendInput` moved the avatar into an enemy and the normal hit/death transition. Full-screen captures retained. Audio/music remained disabled; no physical-keyboard, controller, completion or endurance qualification. Earlier host-targeted/VBScript input attempts failed and are not counted as successes. |
| Unciv 4.22.12 Windows x64 | Free Gcenx Wine 11.18, then stable 11.0 | 11.18's JVM failed on OpenGL 2.1 without the FBO extension. Stable 11.0 initially failed with "No physical fonts found"; copying its six already-bundled free Wine TTFs into that research prefix's Windows Fonts directory fixed this prerequisite. Actual stable retry rendered the language-selection screen. Not yet a main-menu or playable-turn result. |
| Endless Sky 0.11.2 Windows x64 | Free Gcenx Wine 11.18 | Main menu visually captured. A texture-array warning did not prevent menu rendering. No pilot created or flight/gameplay qualification. |

Initial free-engine game executions above occurred between approximately 06:03
and 06:14 UTC on 20 October 2026. SuperTux input/level follow-through occurred
at approximately 06:18-06:23 UTC. These are observation bounds, not a
claim of continuous active debugging or gameplay. Successful free-engine paths
do not need a paid fallback. A prior CrossOver baseline is not counted as a
new free-first fallback test.

No Xbox menu or gameplay success has yet been established by this batch.
No Man's Sky and Abiotic Factor passed real local inventory/readiness checks.
Their preserved CLI expects service `24e78d536c05c52e0e5e1e8f4373c68c41c079ef68a7891eff307baeb17edfba`;
the service actually mapped by the running process is
`a3cc1dd758e47be52700f84ff6874c240cca3238ffdcb9282d26ba19888286eb`.
Both endpoint users are fixed to `/tmp/xodus.sock`; the inspected macOS service
does not honor Linux's `XDG_RUNTIME_DIR` override. These are preflight failures,
not Wine incompatibility findings. The other four candidate titles have public
PC package records but no established current-account download access in the
inspected local evidence.

Gcenx Wine 11.18's ordinary native CLI `--version` returned `wine-11.18`,
exit zero, without security-policy or quarantine changes. Fresh-prefix
`cmd.exe /c echo` also passed. Stable Gcenx Wine 11.0 (official `11.0_1`
release) independently passed version and fresh-prefix built-in execution
before the actual Luanti and Unciv rotation above. Its verified archive SHA-256:
`b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388`.
An unsigned wrapper's macOS assessment is **not** itself proof the CLI cannot
execute. Built-in execution is not game rendering or Xbox-package evidence.

Each free-engine/title combination used a separate HOME and prefix under
`game-engine-tests-20261020/free-wine-<version>/<title>`. Wine's `Z:` mapping
still exposes host paths: these are isolated configuration directories, not an
OS sandbox. Mono/Gecko were disabled; no global GStreamer, security-policy,
account, shared Xbox service or existing game-prefix changes were made.
Exact argv, engine paths, process IDs, logs and target-window captures are
recorded in that private artifact tree. In particular, Unciv's font correction
affected only its stable research prefix, not macOS fonts or another title.

The owner's full-desktop capture also showed Luanti's separate Program Error
dialog alongside SuperTux's menu and Unciv's language screen. A macOS "App Update
Required" notification warned that a Wine Devel component will not open on
macOS 28; this is a future-OS warning, not proof that the current invocation
failed on macOS 27.0.1. Earlier game-window crops did not include those separate
surfaces; future test evidence must include full-screen captures.
Full-screen inspection also caught two surviving Luanti debugger dialogs after
the game and Wine server processes had stopped. Both debugger processes were
independently bound to this batch by their research-only working directory and
mapped prefix files, then stopped by exact PID. Game/server termination alone
was therefore not sufficient cleanup evidence.

### Locked-display pause and prepared controls

At approximately 06:26-06:28 UTC, Endless Sky follow-through produced black
full-screen captures. A read-only macOS session query independently confirmed
`CGSSessionScreenIsLocked: 1`. Those captures are **unobservable results**, not
evidence of a graphics failure, failed new-pilot action or gameplay. No pilot
creation or flight was verified. A source-supported `--config` research-only
windowed retry also occurred before the lock was identified; it has the same
unobservable outcome. The owned game and its prefix-identified server were
stopped. No automated unlock or security-setting change was attempted.

Local runners now refuse launch/input while the display is locked. Resume
visual testing only when the user has independently unlocked the session.
Meanwhile the following additional official Windows controls were downloaded,
matched against upstream release SHA-256 digests, safely extracted and inspected
for executable headers. **None has been executed by this batch yet.**

| Prepared control | Exact release | Official archive SHA-256 |
|---|---|---|
| Dungeon Crawl Stone Soup, Windows tiles | 0.34.1 | `a772f22db9dde5dfa85bcc1652dbf16e3d62ecd1173f27c39387403532507979` |
| Brogue Community Edition, Windows x64 | 1.15.1 | `29dcbae1791156a040c9125d0a28ae97d67a09b22a52266af1c65e2918bede5f` |
| Cataclysm: Dark Days Ahead, Windows x64 graphics | 0.I-1, 2026-09-19-2324 | `c0a90bfc78e5319733abea1c10ea0c0bd7e7e05a842566e9d6da90c5486e01da` |

The preparation receipts record exact official release/download URLs, sizes,
archive checks and executable paths. This expands the prepared control queue
to eight titles, not the tested count or an Xbox support list.

Static PE inspection confirmed DCSS is a 32-bit Windows executable; Brogue and
Cataclysm are x64. The DCSS archive therefore also offers a distinct WoW64
control, but this is not proof that either Wine build runs it. Brogue directly
imports bundled SDL2/SDL2_image and Windows CRT API sets; DCSS directly imports
OpenGL32. These are preparation observations, not resolved-dependency or
renderer verdicts.

The local bounded runner now cleans up the directly owned launcher and invokes
the exact engine's `wineserver -k` with only the fresh title-specific prefix,
including when a post-launch display check or screenshot fails. Four mocked
runner checks passed: initial lock refuses before launch/state creation;
mid-run lock records an unobservable outcome and cleans up; capture failure
cleans up without a success claim; normal observation cleans up without
inventing a visual verdict. A real invocation while locked also refused before
creating the Brogue run. These are harness checks, not additional game tests.

The queued invocations now use source-documented options: Brogue's `--no-gpu`
software renderer and fixed seed `20261020`; Cataclysm's explicit research
`--userdir` and seed; DCSS's `-rc` file with research-only save/morgue paths.
Brogue's software mode is an intentional first-test setting, not a verdict on
its default GPU renderer. These queued commands have not yet been executed.

Runtime and game receipts remain in the session's private artifacts, excluding
credentials, tickets and content keys. Update this section from actual outcomes,
not compatibility reports from another storefront.

## Approved-window closeout

The approved 12-hour window ended on 20 October 2026 at 17:48:15 UTC
(20:48:15 local). Scheduled continuation was cleared at closeout; no further
launches or input were attempted. Further testing requires a newly approved
window, not merely an unlocked desktop.

The final count is **five Windows controls actually tested, three additional
controls prepared only, and zero Xbox game launches**. Free Wine demonstrated
an OpenTTD running world and SuperTux level interaction; the other outcomes
retain their stage-specific limitations above. The last scheduled display check
remained locked, preventing further required full-screen observation. Xbox
execution separately remained blocked by the exact frozen CLI/live-service
pairing mismatch. Neither blocker is an additional engine failure.

The batch remains blocked, not qualification-complete. Existing evidence is
retained; this closeout establishes no production readiness, Xbox login
readiness, or fresh verified app path.
