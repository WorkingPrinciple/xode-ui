# X Ode game test ledger

Started: 2026-10-16. Scope: owner-authorized private local installation and
playtesting during the feature freeze. Public distribution and backend
provenance holds remain unchanged.

## Test boundaries

- Keep at least **100 GiB available**, including download, extraction, temporary
  launch trees and concurrent build peaks. Recheck before each mutation.
- Prefer small currently entitled PC packages and existing installations.
  No purchases, account switching, protection bypass, uninstall or deletion
  of player files/saves to make room.
- Management sign-in, PC-library entitlement and game-service identity are
  separate. A saved management credential or installed record proves neither
  ownership nor gameplay.
- A Windows package is not a macOS app bundle. Record the actual package
  evidence and supported runtime path; do not assume MSIXVC, UWP/AppX, EAppx,
  bundles and ordinary Win32 installers are interchangeable.
- The private X Ode `.app` pairs its management CLI/helper. CrossOver, Wine,
  Windows shims and existing per-title game runtimes remain separate inputs;
  the newly built management CLI must never replace a game-runtime CLI.
- A launch attempt is not a gameplay pass. Record visible launch/input/audio,
  save, normal exit, relaunch/load and safe Stop independently. Historical
  receipts are not fresh acceptance.
- Keep account identifiers, credentials, raw logs, private download URLs and
  player data out of this ledger.
- The owner explicitly authorized unattended overnight work and game
  termination on 2026-10-16. Prefer normal Quit; any forced termination must
  target the identified test game, never a broad Wine/process-name match,
  an installer or a shared service. Record abnormal exit/save uncertainty.
  Purchases and human authentication/security-consent decisions remain holds.

## Current installation inventory

The five original registered folders and executables exist. Their `MicrosoftGame.config`
Store IDs match the registry and `.xodus-streaming.msixvc` files are present.
The registry declares MSIXVC; this is **not** full container integrity,
entitlement, complete-download or runtime-compatibility verification.
Small streaming-container sizes must not be used as full download estimates.

Allocated folder sizes were measured with `du -sk`. Available disk space was
151.44 GiB at inventory and 151.37 GiB before the first launch attempt.

| Title / Store ID | Registered version | Allocated GiB | Package/launch distinction | Fresh result |
| --- | --- | --- | --- | --- |
| Hogwarts Legacy / `9MT5NJ5W7B8Z` | 1.0.16.0 | 88.92 | Declared MSIXVC; WinGDK executable named by config. Registered launcher points into an external mutable source checkout, not the isolated runtime. That checkout was not inspected or executed. | NOT ATTEMPTED; launcher tuple must be qualified first. |
| Lara Croft and the Temple of Osiris / `C3553MB4P5TT` | 1.0.5.0 | 3.03 | Declared MSIXVC; `LC2.exe`; isolated registered launcher and CrossOver bottle present. Selected first because it is the smallest existing installation. | Attempt 1: stopped service. Attempt 2: Windows process and black game window; NOT PLAYABLE in this attempt. Normal Quit and runtime exit 0 observed. |
| Abiotic Factor / `9P4NV23Q6QC2` | 1.4.28206.0 | 4.97 | Declared MSIXVC; `AbioticFactor.exe`; isolated launcher requests its existing COM-STA runtime mode. | Earlier direct-runtime tutorial movement observed. Additional actual signed-app Play rendered the title screen; native Stop settled both game processes and the run RAM mount. Guarded input was withheld in this additional attempt; audio, save/load, campaign and multiplayer remain unverified. |
| No Man's Sky / `BQVQTL3PCH05` | 7.6.0.0 | 31.38 | Declared MSIXVC; dedicated preserved runtime, pinned experimental Vulkan renderer and temporary HTTP-transport staging. Not a generic runtime substitute. | NOT ATTEMPTED. |
| Gears 5 / `C2KDNLT2H7DM` | 1.1.967.0 | 126.88 | Declared MSIXVC; config names `Gears5_EAC.exe`. Anti-cheat support is unqualified; never disable or replace it to claim compatibility. | NOT ATTEMPTED. |
| Minecraft: Java Edition / `9PJ8266BHFWN` | 1.0.5.0 | 0.067 | Newly installed MSIXVC package; config declares `MCPlaceholderStub.exe`, not a full Java game/runtime. | INSTALLATION AND RENDERED PLACEHOLDER OBSERVED. Actual signed-app Play/Stop exercised on 2026-10-17; game process and run RAM mount settled. Its window requests the Launcher; no full Java/gameplay acceptance. |

After the Minecraft installation the registry contains six records and all
five original Store IDs remain present. This is registration preservation,
not a new whole-file integrity check of every original game.

The generic launch scripts resolve `Runtime/target/release/xodus-cli` and its
package-inventory helper; both exist. The absence of a CLI in `Runtime/bin`
does **not** establish that the game-runtime CLI is missing.

## Attempt log

### Lara attempt 1: service unavailable

Run ID: `xode-audit-lara-20261016-1`. Direct registered-runtime attempt,
**not an X Ode UI launch**.

Before launch, the service and launch inputs were read-only inspected and the
existing bottle was confirmed. The storage guard required 112 GiB available:
100 GiB reserve plus 12 GiB temporary/concurrent-build headroom. No game was
already running. The unchanged registered launcher exited 1; the first socket
probe returned `ConnectionRefusedError`. No package decryption, game window,
input, audio or save acceptance was reached.

The existing `com.xodus.service` launchd job was loaded but stopped, last status
`-15`. Its actual command is the installed `/bin/sh` service wrapper, not a
direct one-argument binary invocation. The initial stricter command-shape
preflight refused startup and made no changes. After inspecting that wrapper,
the coordinator verified the original service hash and an owner-only stale
socket, then normally started the existing job with `launchctl kickstart`
(without `-k`). No launch-agent configuration, service binary, credential,
runtime, registration or game/save file was replaced. The owner-only service
socket subsequently accepted connections.

### Lara attempt 2: black screen, normal exit

Run ID: `xode-audit-lara-20261016-2`. Same unchanged direct runtime path after
the service health check; not an X Ode UI launch.

The package-inventory/residency path proceeded to the Windows `LC2.exe`
process and its real 2560-by-1440 game window. Two local captures, including
after game-targeted Escape input, showed only black plus the graphics HUD.
The HUD's 60 FPS is **not gameplay or a performance pass**. The reason for the
black screen is not established.

Normal application Quit was requested for this exact game process; the
registered runtime then exited 0. No force termination was used. Input-driven
play, audio, save and relaunch/load are unverified. Last measured available
space after this attempt was 150.13 GiB, with source work also running.

### Abiotic Factor attempt 1: limited tutorial gameplay and normal exit

Run ID: `xode-audit-abiotic-20261016-1`. Existing isolated registration and
COM-STA mode, unchanged generic runtime, existing CrossOver bottle. The
prelaunch guard required 116 GiB available, retaining the 100 GiB floor.

The actual WinGDK shipping process rendered its title screen through D3D12.
Space input advanced to a server-browser-unavailable prompt. Its built-in
No/offline path was chosen; default quick settings were retained and optional
crossplay declined. Initial character setup led to the actual Introduction:
the character exited the vehicle using the on-screen Jump hint and walked
outside. Local captures show the changed position and the movement tutorial.
This establishes limited rendered, input-driven gameplay, not a full game pass.

The menu explicitly reported "MULTIPLAYER GAME - NOT PAUSED" and that pausing
requires singleplayer, despite entry through the offline path. Do not describe
that menu as a successful pause or infer online/multiplayer support. Leave
Tutorial opened its reversible skip confirmation; the final guarded Yes click
was refused because the game no longer owned that point. It sent no input.
Normal application Quit was subsequently requested for the exact shipping
game process; the registered runtime exited 0, without force termination.
Audio, save persistence, relaunch/load, campaign and multiplayer are unverified.
Prelaunch available space was 149.80 GiB. After this attempt and the concurrent
private app build, the measured available space was 148.13 GiB.

Automation guards correctly refused clicks when the expected window was not
recognized. A subsequent read showed the game had moved from normal level 0
to fullscreen level 26; ignoring that elevated game window had incorrectly
selected background browser windows. The local helper was corrected to check
the actual top visible window across nonnegative levels, still requiring the
exact game PID and window ID before posting a click. No click was sent to
those background apps. Direct PID-targeted mouse events alone had not activated
the offline button; guarded normal input did.

### New installations

The controlled signed app now restores the existing management
sign-in and broker-backed PC collection without token copying or broker
replacement; see [XO-009](ISSUE-LEDGER.md). Its actual Library shows 13 titles.
This repairs the raw app's pairing failure, not the separate Xbox game-service
status failure. Per-title package access and normal license checks are still
required before a download or launch.

**Subnautica / `BX3S1Q5DVHRD`:** actual game detail and Install were exercised.
Preparation refused the package with "This game needs Xbox features Xodus
can't provide on Mac yet." The recorded compatibility result is
`supported=false`, `packageBytes=7039869128`, checked at
`2026-10-16T21:28:45Z`. No successful download/installation or gameplay followed.
This is a preflight blocker, not a universal gameplay compatibility verdict.
Local capture: `xode-subnautica-install-preparation.jpg`.

**Minecraft: Java Edition / `9PJ8266BHFWN`:** Install in actual X Ode detail
completed and the UI displayed "Minecraft: Java Edition was installed",
"Installed on this Mac", 72.2 MB installed and a Play action. The compatibility
result was `supported=true`, `packageBytes=68421315`, checked at
`2026-10-16T21:33:50Z`; that result is not a gameplay pass.
Local capture: `xode-minecraft-java-install-preparation.jpg`.

The new registry entry declares version `1.0.5.0`, `msixvc`,
`~/Games/Xodus/MinecraftJavaEdition-Xbox` and its isolated registered launcher.
The actual `MicrosoftGame.config` Store ID matches and names
`MCPlaceholderStub.exe`; that file exists at 991,232 bytes. Folder allocation
is 70,492 KiB. Its registered-source header is not DOS MZ, as is also the case
for the registered-source executables of genuinely launched Lara and Abiotic;
do not diagnose corruption or certify a runnable payload from that header
alone. The later direct runtime attempts below exercised licensed materialization;
actual app-driven launch remains untested. A small store stub is not full Minecraft
gameplay, Java installation or successful account acceptance.

After installation and the next private app build, both the actual game
destination and `/private/tmp` were on device `16777229` with **147.55 GiB
available**. The 100 GiB reserve remained intact. No other new installation
was attempted. macOS subsequently reported its screen locked; native input
and game launches were paused without bypassing the lock. No game is accepted
as played while its windows/input cannot be observed.

After the repaired private app package was built, actual games/staging volume
availability was **146.71 GiB**. The repaired app's two normal Quit observations
did not launch a game or change the registered game-runtime/service/broker
inputs. Remaining gameplay is waiting on the unlocked console, not recorded
as a compatibility failure.

The original overnight window ended at `2026-10-17T05:15:30Z` without a
sustained unlocked console. No additional game was launched or installed
during that wait. Final game-volume availability was **147.20 GiB**; the six
registrations still included all five original Store IDs and the new Minecraft
Java package, with no saved operation journal. This is an unfinished live
qualification boundary, not a claim that every unattempted title failed.

### Bounded Minecraft backend follow-up, 2026-10-17

After the owner renewed autonomous work, two direct registered-runtime attempts
qualified the small installed package without desktop input. This did not
restart the elapsed overnight console observer, unlock the Mac or qualify
visual/native-button behavior. The unchanged generic runtime, launcher,
dedicated `Xodus-9PJ8266BHFWN` bottle and existing running service were checked;
prelaunch availability was 147.20 GiB with a 112 GiB admission threshold.

First run: `xode-audit-minecraft-20261017-1`. The licensed runtime materialized
a real DOS/PE executable of 987,648 bytes, unlike the registered encrypted
source header. After the 120-second observation limit, the owned parent launch
tree was stopped. The game process had reparented to PID 1 and survived that
external tree cancellation. Its exact new PID 83912 was independently
identified as `MCPlaceholderStub.exe`, with two native windows; a normal
application Quit was accepted and actual process exit was verified. No
keyboard/mouse input, window-content capture or gameplay was accepted.
The run's completion file said 0, but that is not used as natural lifecycle
proof: it preceded cleanup of the detached game.

This external cancellation is **not** the app's Stop implementation.
Frozen source `784dedf5` calls the separate `private-xodus-stop.sh` backend,
which targets only this title's bottle. A second bounded run exercised that
actual backend rather than inferring an X Ode Stop defect:

- Launch: `xodus-20261017T053440Z-55971a59`; actual placeholder PID 84233.
- Stop: `xodus-20261017T053440Z-c869a836`; backend exit 0 and a result bound to
  Store ID `9PJ8266BHFWN` with `stopped=true`.
- The game PID actually disappeared and the launch wrapper settled with code 1
  after the explicit Stop. This is not a natural-game-exit pass or UI verdict.
- No matching placeholder process remained. Shared service PID 39541 stayed
  running; the generic game CLI and launch-script hashes stayed unchanged.

Supplemental local evidence is
`minecraft-registered-runtime-stop-20261017.json`, separate from package
receipts. Full Minecraft, Java installation, Microsoft/Minecraft account
acceptance, rendered content, input, audio and save/load remain unverified.
Actual game-volume availability after these attempts was **146.90 GiB**.

**Cleanup recovered:** external cancellation of the first launcher left its
run-only HFS RAM image mounted at `.tmpjdD8nH` (`/dev/disk4` in this observation).
Only that positively identified staging tree was inspected: 38 source links
and the materialized placeholder, with no unknown files or player saves.
The links/materialized file were removed without following links; the
original game folder still contains exactly 71,986,661 regular-file bytes,
including its package and executable. Normal Image/Disk Utility eject and
a narrowly guarded force-unmount failed. Ordinary owner-level `/sbin/umount`
then succeeded, followed by normal `diskutil eject` of that exact RAM image
and removal of its empty mount directory. No sudo, permission/security change,
broader device, shared process, original game, bottle or save deletion was
used. The second app-wired Stop attempt did not leave another matching
Minecraft RAM volume. The differing cleanup-tool results do not establish
screen lock as their cause.

Final reconciliation after cleanup found no test placeholder process or known
run mount directory, the original 71,986,661-byte package tree intact, all three
recorded game CLI/management-script/launch-script hashes unchanged and shared
service PID 39541 still running. Available game-volume space was **146.88 GiB**.

The actual Stop success above does not prove its failure handling. A separate
isolated source test compiled only the unchanged `stop` function from the
installed Python script (SHA-256 `e6efb8488db9d68a6c69db8791b1b817427b9344d92ed0fc0afaae84c317578c`),
substituting both vendor commands with fakes returning 7. It still returned 0
and published `stopped=true`; no Wine, installed helper entrypoint, account
call or filesystem mutation ran in this test. This is a source/synthetic
failure-handling finding, **not a reproduced live Stop failure**. See XO-020
and `stop-vendor-failure-isolated-function-20261017.json`.

The following are observed **catalog labels/estimates**, not inspected
containers, current license decisions, peak disk requirements or Mac support:

| Additional collection title | Catalog package / estimate | Next qualification or hold |
| --- | --- | --- |
| Celeste | EAppx; no size displayed | Do not treat as MSIXVC; package/runner qualification required. |
| Cuphead | EAppx; no size displayed | Do not treat as MSIXVC; package/runner qualification required. |
| Fortnite | MSIXVC; no size displayed | Package/PC availability and anti-cheat qualification required; no bypass. |
| Gears of War 4 | EAppx; no size displayed | Do not treat as MSIXVC; package/runner qualification required. |
| Minecraft Launcher | MSIXVC; approximately 10.6 MB | Actual signed-app preparation refused the current account's download access. No install confirmation/start reached. Account verification is not download entitlement; cause unresolved. A launcher is not a playable-game pass. |
| Minecraft: Java Edition | MSIXVC; approximately 71.8 MB catalog estimate | Rendered placeholder and actual signed-app Play/Stop exercised; full game/launcher/account and gameplay qualification remain pending. |
| Roblox - Not Supported | MSIX; approximately 185.4 MB | Catalog title itself warns unsupported; do not infer support from size. |
| Subnautica | MSIXVC; approximately 7.19 GB catalog estimate | Native Install preparation refused unsupported Xbox features; no gameplay attempt. |
| The Witcher 3: Wild Hunt - Remastered | MSIXVC; approximately 85.51 GB | Download alone exceeds the current headroom above the 100 GiB reserve; do not start. |

## Actual signed-app Play/Stop continuation, 2026-10-17

The console was freshly confirmed unlocked. The exact privately signed
`784dedf5` package passed code-signature/hash checks, restored saved management
and PC-library access, and resolved the saved unbound game-service state through
its existing explicit Verify game account action. These remain separate
identities; no token copying, fabricated binding or installed-runtime hotfix.

### Minecraft placeholder: native Play, rendered handoff and native Stop

Available storage before launch was **146.81 GiB**, exceeding the guarded
112 GiB threshold including the 100 GiB reserve. Installed launch and management
script hashes still matched their recorded originals. No existing placeholder
process or matching temporary RAM mount was present.

At `2026-10-17T07:11:39Z`, actual native Play Minecraft: Java Edition in the
signed app was activated successfully. The app exposed Stop while the launcher
prepared. Placeholder PID 89067 subsequently appeared, with an owned visible
window (8075). An own-window-only capture showed Minecraft artwork and
**Click here to use the Launcher to play!** It was not a Java game, world or
interactive gameplay pass; the handoff was not activated.

At `2026-10-17T07:12:37Z`, actual native Stop Minecraft: Java Edition was
activated. The app returned to Play, the observed game PID disappeared and
no matching temporary RAM mount remained. The run had used `.tmp62sNH1`;
unlike the earlier externally cancelled attempt, no manual unmount/eject,
external process-tree termination or game-file deletion was needed.
Done then returned to the authenticated Library.

Evidence image `minecraft-native-play-20261017.png` remains in coordinator
session artifacts, not the repository. This qualifies the observed native
Play/Stop path and rendered launcher handoff only. It does not qualify Stop's
vendor-failure path (XO-020), natural game exit, Minecraft Launcher installation,
account entitlement to the full game, gameplay, audio or save/load.

### Abiotic Factor: native Play/title screen and native Stop

At `2026-10-17T07:15:07Z`, the actual signed-app Play Abiotic Factor action
started the unchanged installed title. Available storage was **146.75 GiB**,
above its guarded 116 GiB threshold, with no prior Abiotic game process.
Bootstrap PID 90781 and shipping-game PID 90783 appeared; the latter owned
visible window 8106. Its own-window-only capture rendered the real title
screen and Press anything to begin through D3D12.

The bounded input attempt was deliberately withheld: the identified game
window did not own the proposed click point. A normal exact-game activation
returned true but did not make that process active; the second guarded click
was also refused. No click/key was delivered and the lane stopped rather than
relaxing ownership checks. This is an automation/input-admission limit, not
proof that the game cannot accept ordinary user input. The earlier direct
runtime's limited tutorial gameplay remains a separate observation.

At `2026-10-17T07:17:41Z`, actual native Stop Abiotic Factor was activated.
The app returned to Play; both observed game PIDs disappeared and the run's
`.tmplK1lLS` RAM mount was absent. No broad Wine kill, external parent-tree
termination or manual volume cleanup was used. Final measured storage was
**146.72 GiB**, above the 100 GiB reserve. Done and the native Library shortcut
returned to the authenticated app.

Compact evidence image `abiotic-native-play-20261017.jpg` is retained in
coordinator session artifacts, not the repository. The title-screen graphics
HUD is not a performance benchmark. This attempt establishes native launch,
rendering and scoped Stop settlement, not additional gameplay, natural exit,
audio, save/load, campaign or multiplayer acceptance.

### Minecraft Launcher: native preparation refused account download access

Because the Java placeholder explicitly requests the Launcher, the coordinator
opened the existing Minecraft Launcher collection entry and invoked its actual
native Install action in signed `784dedf5`. This was the existing preparation
path, not a direct downloader or unsupported package substitution. The catalog
still described MSIXVC and approximately 10.6 MB.

Preparation showed **This account couldn't download the game. Check your game
sign-in and subscription, then try again.** on the initiating detail and the
main operation-feedback surface, with Show log and the installation entrypoint
remaining available. No installation review/confirmation or download start was
reached. No forced sign-out, purchase, token copying, account joining or repeated
unchanged retry was performed.

The separate native game-account verification had succeeded and persisted
across restart. That proves neither Microsoft Store download rights nor that
the library and game-service accounts are the same. This attempt does not
establish missing subscription, a particular provider/account mismatch,
package incompatibility or a universally unsupported Launcher. It remains an
account/download-admission hold, not a playable installation.

## Attributable launch inputs

The Lara launch path targets CrossOver 26.3 from the existing installation and
its existing `Xodus-C3553MB4P5TT` bottle; attempt 1 failed before reaching Wine.
These observed hashes identify inputs,
not complete source provenance or compatibility certification:

| Input | SHA-256 |
| --- | --- |
| Generic game CLI, 22,274,512 bytes | `0d0141dadd2512454122e592ef170c6aa72e78fa997568296dcb7150448b38e4` |
| Package-inventory helper, 1,937,616 bytes | `899b938f521d27c4b87d06e8d5089bc2924eba578ddd75ed13008d3349455941` |
| Generic launch script | `32c966943835a248dbf2181c7e44ac718d4738413b772150a4adf22ce95e981f` |
| Generic Wine wrapper | `587547ba783fad469ebdba0ee836f6c85bbb751b77fbca8ba76a71edbcc1a605` |
| Private IPC wrapper | `68d641a379d1a7c2fee7594912f90654dd6ba36aaa5117b135724bbae4b80c98` |
| Package-readiness verifier | `4b1d06b9c2d56e772b41b21b64b1a6f11fba9eb267a3717b1ad5772550a33336` |
| Installed game service | `24e78d536c05c52e0e5e1e8f4373c68c41c079ef68a7891eff307baeb17edfba` |
