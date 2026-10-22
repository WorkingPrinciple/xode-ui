# Ode to X: morning draft v2

22 October 2026; live gate timestamp below, disk snapshot separately dated.

**Goal: 20 genuinely WORKING titles; current count: 11.** Gameplay, retained
progress and normal shutdown required; eligibility/cloud/app E2E are separate.

## What works / nearest additions

| WORKING | Evidence and limits |
|---|---|
| Hollow Knight | `s3-hollow-app-retention-receipt.json`; app E2E. |
| No Man's Sky | `nms-nonnative-retained-20261022T0010/qualification.json`; free Wine; app E2E separate. |
| Minecraft Java | Native retention admitted in matrix; Ode integration pending. |
| Halls of Torment | `s3-halls-retention-02`; combat, gold/Quest Stone retention, normal quit. |
| Hogwarts | `f2471368`; retained checkpoint plus ordinary Quit to OS, CLI0/Wine0. |
| Hades II | `80cbf59d`; coordinator verified fresh reload Crossroads, Nights 2; CLI0/Wine0. App E2E unobserved. |
| Abiotic Factor | `e5ec1841` world / `18dcee0d` fresh reload; same world, character, $5 and duct tape. Apple4/adf8, CLI0/Wine0; coordinator verified. App E2E unobserved. |
| Mixtape | `d919efb9` chapter 1 completed / `ab231868` fresh reload retained chapter; Apple4, both CLI0/Wine0, coordinator verified. App E2E unobserved. |
| Monster Sanctuary | World `cca9c74f` / fresh `0667822b` retained S3/Wolf/114G/BlobEggx1 and movement; both ordinary0/0. Coordinator verified WORKING9; app E2E unobserved. |
| TUNIC | World `a9ee48eb` / fresh `a27be511` retained WoodenStick/equipment and movement; both ordinary0/0. Coordinator admits WORKING10; no shrine claim, prior inconclusives retained. |
| Brotato | Installed-route-equivalent packet `122532b`, CLI `3ea56ed1`/Apple4; world `21bd7fd5` / fresh `01cda87b` retained usable Chunky, both ordinary0/0. Coordinator admits WORKING11; not GUI Play-click evidence. |

**Brotato:** now coordinator-admitted WORKING11 on installed-route-equivalent
packet122532b/CLI3ea56ed1/Apple4, world21bd7fd5/reload01cda87b ordinary0/0.
Chunky retained/usable, exact1024089B/b0e2b10a world-to-reload continuity plus
raw archives, after-save da5542fd; MainQuit Entercount2 both, PIDgone before
cleanup-k1/-w0. Older12ebe02b/430e9c33 candidate runs remain historical.
**Separate UI FAILURE:** installed app cannot read tried-games.json and cards
show NotTested. Issue43 NOT passed, production UI not accepted. No GUI Play-click
claim or CLI promotion inferred from the route-equivalent packet.
**Hades II:** checkpoint retention now WORKING; earlier conversation-marker
failure is historical and not the accepted checkpoint criterion.
**Mixtape:** now WORKING after chapter 1 completion/retention; earlier
`77083b32` no-chapter result is historical. **Inscryption:** NO_TITLE_SCREEN (`3b833cc7`),
known hold until its retry at the end of the queue;
CLI0 is not success. **Well:** INCONCLUSIVE/parked (`9c31530d`), gameplay
reached but TIMEOUT/CLI1/Wine0 and no save marker; no retry grant.
Fallout save diagnosis remains separate. New-pair retry `4abf50d8` ordinary
quit CLI0/Wine0 still left six save inventories unchanged/empty after NEW SAVE;
no write trace entries or retained progress, no WORKING promotion.
Latest Fallout `7a1fdf52` delete-missing experiment is INCONCLUSIVE:
CreateUpdate0x80070057 still no payload, exit5 after Desktop; user-reported
mouse-look defect unresolved. No retained-save or normal-exit promotion.
**Digging:** retry `3e488e23` INCONCLUSIVE/parked: sold 1 stone,
$5 upgrade not bought, no save shown; no title-menu Exit, ended with -k cleanup.
**Stardew:** full test `465d526c` INCONCLUSIVE: real Spring Day1 control,
15 Parsnip Seeds and sleep to controllable Day2; stopped XML/local and GDK
payloads show saved progress. Fresh `22d78ea2` LOAD retained farmer/farm/Day2/
15 seeds and movement: retention YES. Final ExitGame input was unobserved;
CLI255 alone is insufficient. Latest `111dd574` also confirms retention, but
ordinary quit attribution is under review (helper exit1); do not count yet.
Earlier `db74c3c4` tooling cancellation remains an unconsumed historical attempt.
**Monster Sanctuary:** now coordinator-admitted WORKING9 at 22:57 EEST.
Historical world `cca9c74f` PASS-candidate with S3/Wolf,8XP,
14 earned gold,BlobEgg/SmallPotion,27968B save and ordinary0/0. Reload
`0d057caf` INFRA RPS sign-in0x80072746/timeout remains an unsuccessful attempt,
not the successful retry. New admission comes from coordinator, not that run.
**TUNIC:** now coordinator-admitted WORKING10 after CLI68f world/reload
`a9ee48eb`/`a27be511`, retained/equipped stick and fresh movement, both0/0.
Reload quit148.718s<180, exit212.898s/PIDgone beforecleanup; world quit8.735s
late operator deviation retained. No shrine reached or needed for admission.
Final reload integrity is `bb783401...`, superseding historical `8f43fc64...`
at the same local path after retention-result/admission finalization.
Historical full `d928b209` INCONCLUSIVE after quit deadline overrun/no shrine.
Historical raw save versions3a/9b were hashed but not archived before legitimate
writes; only current1b116832 is archived. This is partial historical
recoverability, not a complete save archive or invalidated retained-stick proof.
Reload `931f693e` loaded cavern but stick absent/closed chest; quit navigation
also timed out. No normal quit, no saved stick or runtime save-regression claim.
**Valor Mortis:** passive `792b6f4e` blocked by missing VC++ redistributable
prefix prerequisite. S2 setup, not a rendering verdict or WORKING qualification.
Batch 2/3 are dry queued packets, not title-screen passes or unrestricted grants.
Coordinator reports pipeline cap 23 from S1 `5b944e3` KCD1/Subnautica 2 routes;
S2 packets are being prepared. Both product IDs already exist in old packets:
S1 census confirms no additional unique installed titles: historical packet
baseline remains 21, not 23 unique titles or an executable queue.
**LIMBO:** full test `d756b27d` now INCONCLUSIVE: real awakening/movement,
forest/log descent and repeated first-spike-gap deaths; no confirmed new
checkpoint or retention. Ordinary QuitLimbo CLI0/Wine0 at 812.16s, but quit
started after the 75% policy limit. No reload consumed or automatic retry.
Earlier `15dc80fd` candidate TITLE_SCREEN_PASS is historical; frozen release unqualified.
Latest same-prefix retry reached a frozen Press Any Key screen, no gameplay;
forced cleanup at 121.7s, no ordinary quit or retention. Still INCONCLUSIVE.
**Skyrim:** INCONCLUSIVE (`fa08c5f8`); launcher reached, game child
exited without a window or gameplay. S1 diagnosing; launcher is not a title-screen pass.
**DREDGE:** reload `a452bd89` retained its save, but quit exited 255:
INCONCLUSIVE, ordinary quit still required; strict count unchanged.

## Decisions / holds

CLI `ebd56e` promotion **PENDING** (`3f2e500`); user-folder isolation **PENDING**
(`08d3a33`); WineGStreamer **DEFER** pending actual media failure/ABI proof;
16 MiB boundary rebuild **DEFER**, not proven Fallout causality.
**Historical RC `42f793d`** had Halls/Hogwarts Verified working, TUNIC Play.
Current receipt verifies `c7487d8` installed at
`~/Applications/Ode to X Local Candidate.app` at 17:22 UTC: codesign identity,
deep/strict signature, stapler and spctl all exit 0. Receipt SHA
`30f995ad334786bc51114a13402c4356b96e0246f0aa1d6fbf4b46f1e39e3591`,
`proofs/ode-installed-c7487d8-reverify/current-installed-identity-receipt.json`.
This is current identity/signing evidence, not a switch-over or game test.
S5 accidentally removed custom `.build` artifacts with `swift package clean`,
including both releases' switch-over/release/AX receipts and the DMG.
**Artifact-loss blocker, not evidence of product regression.**
Historical switch-over SHA `0e3f7f81...` and c7487d8 completion SHA
`1b72d931a4f1b48178888455b28e61a4947573580cedf731fec89c15c85ca8f5`
are retained references only; files are gone. The installed app's
`Contents/Resources/local-candidate-receipt.json` is not a replacement.
Coordinator confirms old receipt **LOST**; no lost receipt is recreated.
Separate Previous.app has UNKNOWN source identity, codesign 0 but stapler 65
and spctl 3: it must not be identified as `42f793d` or a verified rollback.
No new release/install authorized.
This does not affect title-capacity arithmetic. Play is not gameplay qualification.

**PENDING catalogue/reclaim:** ranked eight all in official Game Pass feed;
ownership unknown, installs closed. Digging/Balatro payload-only proposal frees
0.459 GiB, insufficient for any ranked-eight install under 155+2 GiB.
Keep Digging if STA comparison scheduled. Retain other near-term payloads.
**No further deletion grant.** Seven parked DREDGE/Balatro/Well prefixes
removed with user/router/owner approval; 2.981 GiB allocated removed,
2.117 GiB observed shared-volume gain. Evidence and installs retained.
Receipt: `parked-prefix-cleanup-v1.json`; S4 compiler-output cleanup separately
in `floor-reclaim-s4-cleanup-v1.json`. Release build has disk priority.

Free-title/acquisition and parked-prefix options: `free-morning-candidates-v1.md`.
**Morning user decision only**, not an install queue; fresh Owned read proved no additions.

**Disk:** 155.017 GiB at 09:08 EEST after cleanup, not a fresh measurement. Install margin
157 GiB was the historical install margin; user now confirms **110 GiB
prelaunch / 110 GiB staging-download / 105 GiB running abort** during Valor
Mortis download. S2 runner 006 applies 110/105 per coordinator.
Coordinator reports 127 GiB free at 22:51 EEST (not a new S4 disk sample):
17 GiB gross margin before prefix and transient growth.
No steady depletion forecast or new concurrent-download admission.
After-top-ten pipeline extension: Bluey's Happy Snaps, Oblivion GOTY, KCD1,
Subnautica 2, Forever Ago, Keeper, DEATHLOOP, Beast of Reincarnation and
Dishonored Definitive Edition. All nine have current manifests/no streaming
marker and need zero additional payload download or proposed purchase/claim.
Existing payload sizes are not new disk allocations; unknown prefix/transient
growth still needs S2 preflight at the 110 GiB floor. Manifest presence is not
fresh entitlement or install-status proof. Already queued titles are not extra
unique capacity. Routes/blockers: `remaining-candidates-ranked-v1.json/.md`.
Fresh 22:58 EEST account-free `install-status` confirms all nine **complete**,
including Bluey (76 files) and Subnautica 2 (278 files), all CLI0/success.
Exact receipts: `pipeline-install-entitlement-v1.json`. Fresh isolated
account-bound Collections read completed with zero products; this did not deny
access. Subsequently S2 completed the nine authorized live package-license
checks: **all GRANTED**, exact receipts pinned in the same packet.
No purchase, claim, payload download, launch or key persistence during checks;
S4 imported existing receipts only, without duplicate requests. Entitlement is
point-in-time access, not permanent ownership or anti-cheat clearance.
Latest S2 passives: Bluey `a46723e9` and Subnautica 2 `76c3b3bf` are both
**BLOCKED_PREREQ**, actual VC++2015-2022 redistributable-required dialogs,
not title screens. Forced cleanup0/0 and process0 do not qualify normal quit.
Native-first VC prerequisite candidate approved by coordinator; reruns wait
for S3 screen release. Both remain installed and license-GRANTED.
FFIV reached PRESS ANY BUTTON/passive0, Quake rendered gameplay but ended
forced247; neither is full-qualified. Vampire Survivors exit3/no window after
DQ overlay and Wasteland load_game_config0x8007000d before ticket socket are
parked. Wasteland installed config lacks MSAAppId; staged parity remains
unknown. TUNIC's later WORKING10 admission is above.
Deep retention index is embedded in existing `path-to-20-v1.json` under
`collectionInputs.attemptEvidence`, with per-title run histories, protected
local artifact paths/hashes and explicit identity/hypothesis/link gaps.
No proofs or save payloads may be deleted for reclaim. For future separately
authorized attempts, owners archive the title's authorized save bytes locally
before launch and after quit, before another write; never rerun to reconstruct
lost history.
Latest S2 five-passive index56e3acbd supersedes earlier prerequisite holds:
Bluey VC resolved, acknowledgement/Continue60FPS only; Subnautica 2 VC resolved,
ToS screen31-38FPS, **HUMAN CONSENT HOLD**, no Agree; DOOM64 title60FPS only.
Passive0/forced endings are not normal quits or full qualification.
Valor VC resolved but exit1/no window with COM marshal0x80004002/mismatched
Uninitialize fingerprint, parked. Oblivion failed before Wine with RAM-stage
overlay accounting/injection ENOSPC despite118GiB host free; bounded source
fix authorized, no retry yet. No extra WORKING title or new research scope.
Sources: current matrix, `morning-pending-v1.json`, `s3-preflight-next-v1.json`.
<!-- living-tracker:start -->
Living tracker 2026-10-22T21:17:24.982723+00:00: **11/20** strict: Abiotic Factor, Brotato, Hades II, Halls of Torment, Hogwarts Legacy, Hollow Knight: Voidheart Edition, Minecraft: Java Edition with Minecraft Launcher, Mixtape, Monster Sanctuary, No Man's Sky, TUNIC. Installed-route-equivalent title qualification is not GUI Play-click proof or production UI acceptance; see per-title scope. Same-gate >2h: A Game About Digging A Hole, Age of Empires IV: Anniversary Edition, Balatro, Beast of Reincarnation, Blue Prince, DEATHLOOP, DREDGE, Disco Elysium - The Final Cut, Dishonored® Definitive Edition (PC), Dome Keeper, Fable, Fallout 4, Forever Ago, High On Life 2, Hollow Knight: Silksong, INSIDE, Inscryption, Keeper, Kingdom Come: Deliverance, Kingdom Come: Deliverance II, LIMBO, Minishoot' Adventures, Nine Sols, REPLACED, Resonance: A Plague Tale Legacy, SUPERHOT: MIND CONTROL DELETE, Skyrim Special Edition, South of Midnight, Well Dweller. Refresh every30min and owner verdict.
<!-- living-tracker:end -->
<!-- burndown:start -->
## Burn-down estimate (not promised passes)

Deadline **23 Oct 13:26 EEST** (user +12h extension); 13.14h from 2026-10-22T21:17:24.982723+00:00. Halls passive-to-qualified: **43.9min**; Hogwarts title-probe-to-qualified proxy: **87.5min** (no bound passive start). One serial, continuously available lane yields **9/11/17** slow/mid/fast cycles, capped by **19 pipeline titles** (historical deduplicated packet baseline, not an executable queue): conditional totals **20/22/28**. These all-pass capacity ceilings assume uninterrupted focus; not predicted successes.

Launch admission floor: **110 GiB** (user-directed, replaces 153 GiB during Valor Mortis download). No fresh disk reading or extra executable capacity inferred.

Need **9** additions; slow scenario leaves **0**. Required mean: **87.6min/addition**. Brotato is already counted; no extra promotion-only title is added. Qualification/recipe holds (Inscryption/Well) and eight catalogue titles (entitlement/disk/approval) are excluded alternatives, not extra time. Historical packet count is not proof of executable capacity; parked/failed routes still need their gates resolved. Inputs/hashes: `morning-burndown-v1.json`; S1 spec `dfe6ad5`, `retention-passive-batches.md`.

Observed admission ratio: **11/19 matrix attempts (57.9%)**; including receipt/owner-reported attempts: **11/29 (37.9%)**. Matrix post-title-screen subset: **11/11**. Unfinished tests included; no probabilities. Minimum pass rates slow/mid/fast: **100.0%/81.8%/52.9%** of queue-capped attempts (>100% would be impossible). Fast raw-slot threshold 52.9% is no longer limited by the historical queue cap.

Biggest measured time sink: **between-run gaps, 69.8min total / 34.9min per addition** across Halls/Hogwarts. Unallocated, not proven screen waiting; operator/other waits and within-run startup/play/save splits unavailable.
<!-- burndown:end -->
