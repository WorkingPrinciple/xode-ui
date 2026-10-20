# Local game-engine qualification

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

Runtime and game receipts remain in the session's private artifacts, excluding
credentials, tickets and content keys. Update this section from actual outcomes,
not compatibility reports from another storefront.
