# Local game-engine qualification

## Session register and live ledger

| Session | Window | State |
|---|---|---|
| 1 | 20 October 2026, 08:48-20:48 local (+03:00) | Closed; five standalone controls attempted, zero Xbox game launches in this session. Historical Xbox successes remain separate. |
| 2 | Renewed 21 October 2026; ends 22 October at 08:28:46 local (+03:00) | Active joint-product investigation. NMS and Abiotic registered routes both failed before Wine at package licensing. Free Wine 11.0 retries visibly rendered Brogue's dungeon and Cataclysm's world; these remain standalone controls, not Xbox or joint-product acceptance. |
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
4. Latest owner limit (21 October): **at most 45 minutes per game, including
   investigation, fixes and verification**, then preserve the result and move
   to the next title. Within that ceiling retain free engines first (at most
   15 minutes combined free-engine debugging), then CrossOver (at most 15 minutes).
   Integration work and retries count toward the 45-minute total; do not restart
   a title's clock for another engine, session wakeup or shared-runtime fix.
   Record start/end and accumulated active time. Downloads and idle windows
   are not gameplay and must not be used to manufacture test progress.
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
   Also inspect runtime dialogs behind the game and after it closes. Their owners
   may be `control.exe` or `conhost.exe`, not `wine`/`winedbg`; bind each to its
   actual prefix before attributing it to the current game, installing a runtime,
   or terminating it. A stale installer is not evidence the new game needs .NET.
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
| Package-license handler failure became a malformed-frame error | Modified runtime; Session 2, `0c3cbb3` on `session2-package-diagnostics` | Optional closed error codes preserve missing/unavailable credential versus other request failures; success wire shape unchanged. CLI distinguishes an empty legacy rejection from invalid framing and rejects non-ASCII key data without slicing panics. Twelve affected Rust tests pass, including an actual in-memory Unix-socket handler round trip; release CLI/service built locally | Source/build verified only. The installed service, signed app engine and historical NMS binaries were not replaced; missing live credential and account-consumer integration are not repaired by better diagnostics |
| Failed launcher implied the game had started | Native app; Session 2 | Nonzero script exit now says the launcher reported an error, not that the game stopped. Existing generated-session log recovery remains unchanged. 247 presentation and 1,358 synthetic native checks pass | Mock children only; no live game, Keychain or Microsoft qualification. Not yet in an installed app |
| Delegated CLI run still initialized another credential owner | Modified runtime; Session 2, `cf2e023` | macOS `Run` with service-backed licensing now uses an empty memory store instead of initializing the CLI Keychain provider; other commands retain their existing initialization. Twelve affected Rust tests pass and release artifacts rebuilt | No saved credentials migrated or repaired; not installed or credential-qualified |
| Selected free engine was ignored by the registered generic adapter | Abiotic Factor route investigation; Session 2, `3be4fd1` | The generic script did not consume the selected engine and its IPC bridge always constructed a CrossOver command. The candidate now explicitly rejects Wine/GPTK/conflicting selectors before service access rather than silently choosing CrossOver. Four regression tests cover refusal, receipt status, direct bridge refusal and unchanged CrossOver command/default routing using stubs | This prevents wrong-engine testing; it does not implement free-Wine support. No actual Abiotic process or gameplay. The installed Minecraft-specific adapter is not present in the recovered source ref and was not patched |
| Old runtime windows survived named-process cleanup | Evidence/cleanup; Session 2 | Exact research-owned Luanti consoles/explorers 44568/45627/44503/45595 were terminated and their windows verified gone. Separately identified three-day-old VM-test debugger pair 24524/23278 and Mono-installer pair 22093/22076 were bound to their test prefixes and terminated | The Mono dialog belonged to `control.exe` in `XodusVMServiceTest`, not Brogue or Cataclysm. No unnecessary .NET install. Other unrelated prefixes left untouched |
| Pre-Wine failure still invoked wineserver cleanup | Private harness; Session 2 | Candidate runner now skips server stop when no preserved-runtime Wine process was observed, and records actual sample elapsed separately from the target checkpoint | Not rerun against a game; no live cleanup qualification claimed |
| Isolated account broker and package consumer had no matching route | Unified broker `0ccd528`; modified consumer `bc3afab` | Explicit exact-account package-license opt-in reuses the checked credential snapshot and authenticates the packed key. Consumer validates a private endpoint and refuses credential/global fallback; launcher and RPS bridge inherit the same endpoint. Both release CLIs built; 29 service, 77 CLI and 10 consumer checks pass, one pre-existing CLI check ignored; five adapter checks pass | Source/memory-only protocol evidence, not live credentials, full shim interoperability or game launch. Installed signed binaries and native Play gate unchanged |

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

### Bounded NMS diagnostic follow-up

This pass began at **05:55:59Z on 21 October**, and was parked at **06:13:27Z**:
**17 minutes 28 seconds wall time charged**, an upper bound rather than a
reconstructed active-only total. The owner subsequently explicitly approved
autonomous experimentation and saved-account checks; the earlier unavailable
answer is no longer an authorization hold. The new 45-minute ceiling includes all investigation,
fixes and verification; any continuation of this pass has at most **27 minutes
32 seconds** remaining. Do not reset the clock on another engine or wakeup.

Abiotic Factor's separate, noncredential preflight began at **06:13:27Z**.
Its current adapter's ignored engine selection was investigated and the
source-only refusal fix committed by **06:16:04Z**. The actual registered
launcher was then invoked at **06:19:04Z** and exited before Wine with the same
legacy invalid-package-frame error. The receipt's supervisor-shell match is
not a remaining game process. Charge the continuous interval through
**06:25:13Z**, including shared credential diagnostics: **11 minutes 46 seconds**,
leaving at most **33 minutes 14 seconds**, less later title-specific work.

The approved saved-account check at **06:21:18Z** found a saved session under
the preserved signed engine, but both NMS/Abiotic package checks rejected the
qualifier's isolated-account permission. Using that qualifier itself as status
owner produced a native login-Keychain **password-required** dialog, confirmed
in the full-display capture. The bounded read timed out and was terminated;
no password was supplied, ACL changed, credential exported or new Microsoft
sign-in started. This is an observed OS checkpoint, not absent owner approval.
The development app was reopened; no installed runtime was replaced.

### Reviewed free-Wine controls and hidden runtime windows

On stable Wine **11.0**, Brogue's **06:25:13Z** retry visibly rendered a
depth-1 dungeon. The roughly one-minute sample was partially overlapped by
Copilot: retain the helper's ineligible flag and record the manually reviewed
scene separately. No independently verified movement, audio or endurance.

The subsequent bounded **180-second** Cataclysm run rendered its main menu.
Exact-title/executable-scoped Down, Down, Enter input was followed by captured
world loading and then a visible character in an evacuation shelter, HUD and
world messages. A later movement attempt safely refused because cleanup had
already removed the owned window; do not claim movement. The runner's final
capture returned visibility status 3, not a game-crash verdict. Its cleanup
completed and previously hidden applications were restored.

After the games closed, a **Wine Mono Installer** remained behind them. Its
owner was `control.exe` PID 22093, started **18 October**, with working directory
inside `XodusVMServiceTest`; it was not evidence Brogue/Cataclysm required .NET.
That installer and its matching stale explorer were terminated. The separate
old VM-game debugger and explorer were also removed after exact ownership
checks. The capture helper now records runtime-dialog candidates, including
offscreen/covered windows, independently of the current game's owned window.
This is attribution evidence, never permission to kill unrelated processes or
a gameplay verdict. The post-cleanup capture contained no such candidates.

The next stable-Wine control, **Dungeon Crawl Stone Soup 0.34.1 (32-bit Windows
tiles)**, ran **06:54:18Z-06:57:20Z**. Full-display inspection confirmed the title
screen, main menu, tutorial selection and a dungeon scene. Exact-window/executable
input advanced the tutorial: after Space and Right, scenery shifted relative to
the character and displayed game time advanced **0.0 to 1.0**. This is a manually
reviewed synthetic movement response, not physical-input/audio/endurance or
Xbox qualification.

The launcher was `start.exe` PID 58261; the actual window belonged to Wine PID
58310 running `crawl.exe`. The original final runner capture targeted the former.
Additional captures bound to the real renderer still correctly refused full
visual eligibility because Copilot overlapped the right side, including after
the hide attempt. Do not rewrite those flags or describe this as a crash.
The exact title-prefix wineserver stop succeeded; both PIDs were verified absent
and desktop restoration completed. Separate private `reviewed-outcome.json`
records these manual observations without changing the original receipt.

The runtime patch is committed in the isolated session-owned
`files/session2-legacy-engine` worktree at **`0c3cbb3`**, based on `7ae8ffe`.
At that revision the locally built release artifacts had SHA-256:

- CLI: `0fafe7b121e454c3a790f69a2b3c71245d6824058f63bb6fcd57b5ad7f2729b4`.
- Service: `ffcf55529700c438e78ad7c612b9ff31d20d8b18287117eed7b6cf8c077a2535`.

The subsequent CLI-only credential-owner patch `cf2e023` was rebuilt and tested:
CLI SHA-256 is now
`45973ddf813caba9935bbd5fac90e06db7b717fb15e82b342ef749232f125ce3`;
the service bytes are unchanged. Script-only follow-up `3be4fd1` is tracked
separately from those executable builds.

These identities are traceability, **not externally approved sealed inputs or
shipping pins**. Rollback of this experiment requires no installed-binary
restoration: no installed runtime, credential store or game content was changed.
The app-side wording change accompanies the runtime diagnostics; it does not
interpret arbitrary stderr as an authorization verdict or start another login.
The exact missing live store entry still needs safe attribution. In particular,
do not infer a missing user token from the generic `entry not found` message.

### Source-only account-consumer integration follow-up

The shared integration interval **06:37:02Z-06:54:36Z** is conservatively charged
in full to NMS, not treated as free shared work: **17 minutes 34 seconds**.
Together with its earlier **17 minutes 28 seconds**, the recorded charge is
**35 minutes 2 seconds**, leaving at most **9 minutes 58 seconds** for further
NMS-specific work. Later evidence/documentation time must also be charged.
The lane is parked; no repeated credential prompt or unchanged live launch.

Unified source **`0ccd528`** adds opt-in package licensing to the private account
broker. Consumer source **`bc3afab`** removes the fixed-global-only endpoint
assumption and propagates the selected endpoint consistently. Account pinning,
strict XML/framing, parent cancellation, missing-provider refusal and actual
in-memory Unix-socket exchanges were checked. An actual candidate CLI invocation
with an explicit socket but omitted service mode refused before credential
initialization. One independent host-native source review found no blocking
issue; its indirect-snapshot observation was tightened by passing the checked
snapshot directly into the existing license implementation, then rebuilding
and rerunning affected checks.

Fresh local release CLI SHA-256 identities (not shipping pins):

- Unified broker: `9532022c31bc8d6e47fdc1d7801bd84ff7ae0908c800a5b1adf124a559dcdfb1`.
- Modified staging consumer: `df8a32cfca5f35dbf178113a1c4a79230abb0be67b0dd4bee28844406bd7ae30`.

The qualifier follow-up **`f5fe973`** replaces its count-only content-key check
with the same authenticated single-key unpack used by the broker. Tests reject
missing/multiple keys, corrupted wrapping and a wrong device key, and accept a
synthetically wrapped valid key. Five focused core checks, 77 CLI checks and
29 service checks passed; one pre-existing CLI check remains ignored. The
rebuilt unified CLI SHA-256 is now
`26564a9531c604d79c540f675be0768ad76aae71c5345b20c30f97e26be2b712`.
This closes a false-positive qualification risk, not the native password or
live-game checkpoint. Allocate a conservative **four-minute charge** for this
follow-up and its evidence closeout, rather than claiming an exact timing
receipt: **39m02s charged**, at most **5m58s** before further title-specific
work. Do not retry an unchanged prompt.

The preserved `~/Applications/Ode to X Development.app` passed strict deep
signature verification on 21 October; it was **not rebuilt or replaced** by this
slice. No fresh app/package receipt or login readiness is claimed. The sole
GitHub Actions workflow was freshly observed `disabled_manually` and left so.

The later cancellation-only regression at unified revision `0e63cd4` confirms
that an in-flight package provider is dropped on cancellation and no late key
frame is emitted. Four service XML checks passed through the real Unix-stream
router with a synthetic provider. This test-only commit does not alter the
`f5fe973` release artifact.
The owner was unavailable at the native-password checkpoint; no prompt was
retriggered and no password/security workaround was attempted.

Unified follow-up **`3bc6599`** implements the game-shim XML license-token
bridge (7/8), reusing the exact-account opt-in, one checked credential snapshot
and shared licensing-ticket acquisition. Flat XML/product bounds, missing
provider refusal, signed-out/legacy-profile refusal, actual socket framing and
cancellation of both licensing routes are checked: **77 CLI and 32 service
checks passed**, with one pre-existing CLI check ignored. Local release build
passed; its CLI SHA-256 is
`68ae6b632b5dc817d6a909d600e9bec2c556e61a0056ce9d043db8a9f82d6f69`.
Neither the installed app nor approved sealed inputs changed. No live
license-token/provider/game success is inferred.

Conservatively allocate another **six minutes** for this shared follow-up and
evidence persistence; this is not an exact active-timing receipt. Close NMS at
its **45-minute ceiling** (consume its remaining 5m58s, not a new clock), and
charge Abiotic **17m46s total**, leaving at most **27m14s** before any later
title-specific work. NMS is parked with no further title-specific work this
window; an unchanged credential or launch retry is not useful.

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
