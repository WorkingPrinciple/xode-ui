# Ode to X: morning draft v2

22 October 2026; live gate timestamp below, disk snapshot separately dated.

**Goal: 20 genuinely WORKING titles; current count: 8.** Gameplay, retained
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

**Brotato:** newer matrix proves gameplay/Chunky unlock, fresh-process retention
and normal quits (`12ebe02b`, `430e9c33`); candidate only, CLI promotion pending.
**Hades II:** checkpoint retention now WORKING; earlier conversation-marker
failure is historical and not the accepted checkpoint criterion.
**Mixtape:** now WORKING after chapter 1 completion/retention; earlier
`77083b32` no-chapter result is historical. **Inscryption:** NO_TITLE_SCREEN (`3b833cc7`),
known hold until its retry at the end of the queue;
CLI0 is not success. **Well:** INCONCLUSIVE/parked (`9c31530d`), gameplay
reached but TIMEOUT/CLI1/Wine0 and no save marker; no retry grant.
Fallout save diagnosis remains separate.
**Digging:** retry `3e488e23` INCONCLUSIVE/parked: sold 1 stone,
$5 upgrade not bought, no save shown; no title-menu Exit, ended with -k cleanup.
**Stardew:** `db74c3c4` CANCELLED by tooling bug (runner 004 fix);
attempt not consumed, no title failure inferred.
Batch 2/3 are dry queued packets, not title-screen passes or unrestricted grants.
Coordinator reports pipeline cap 23 from S1 `5b944e3` KCD1/Subnautica 2 routes;
S2 packets are being prepared. Both product IDs already exist in old packets:
S1 census confirms no additional unique installed titles: historical packet
baseline remains 21, not 23 unique titles or an executable queue.
**LIMBO:** candidate-only TITLE_SCREEN_PASS (`15dc80fd`), opt-in null-display
runtime; no input/gameplay/save/reload. CLI0/Wine0 followed forced -k0/-w0,
not normal quit. Promoted to S3 full test; prefix held, frozen release unqualified.
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
157 GiB; passive prestart 153/abort 152 GiB. No steady depletion forecast.
Sources: current matrix, `morning-pending-v1.json`, `s3-preflight-next-v1.json`.
<!-- living-tracker:start -->
Living tracker 2026-10-22T17:23:32.289807+00:00: **8/20** strict: Abiotic Factor, Hades II, Halls of Torment, Hogwarts Legacy, Hollow Knight: Voidheart Edition, Minecraft: Java Edition with Minecraft Launcher, Mixtape, No Man's Sky. Brotato WORKING_CANDIDATE remains excluded; see current row for gate evidence and CLI promotion hold. Same-gate >2h: LIMBO, A Game About Digging A Hole, Age of Empires IV: Anniversary Edition, Balatro, Beast of Reincarnation, Blue Prince, Bluey's Happy Snaps, Brotato, DEATHLOOP, DOOM 64, DREDGE, Disco Elysium - The Final Cut, Dishonored® Definitive Edition (PC), Dome Keeper, FINAL FANTASY IV, Fable, Fallout 4, Forever Ago, High On Life 2, Hollow Knight: Silksong, INSIDE, Inscryption, Keeper, Kingdom Come: Deliverance, Kingdom Come: Deliverance II, Minishoot' Adventures, Monster Sanctuary, Nine Sols, Oblivion GOTY (2009), Quake, REPLACED, Resonance: A Plague Tale Legacy, SUPERHOT: MIND CONTROL DELETE, Skyrim Special Edition, South of Midnight, Stardew Valley, Subnautica 2, TUNIC, Valor Mortis, Vampire Survivors, Wasteland Remastered, Well Dweller. Refresh every30min and owner verdict.
<!-- living-tracker:end -->
<!-- burndown:start -->
## Burn-down estimate (not promised passes)

Deadline **23 Oct 13:26 EEST** (user +12h extension); 17.04h from 2026-10-22T17:23:32.289807+00:00. Halls passive-to-qualified: **43.9min**; Hogwarts title-probe-to-qualified proxy: **87.5min** (no bound passive start). One serial, continuously available lane yields **11/15/23** slow/mid/fast cycles, capped by **21 pipeline titles** (historical deduplicated packet baseline, not an executable queue): conditional totals **19/23/29**. These all-pass capacity ceilings assume uninterrupted focus; not predicted successes.

Need **12** additions; slow scenario leaves **1**. Required mean: **85.2min/addition**. Brotato CLI promotion can add one without another full cycle. Qualification/recipe holds (Inscryption/Well) and eight catalogue titles (entitlement/disk/approval) are excluded alternatives, not extra time. Historical packet count is not proof of executable capacity; parked/failed routes still need their gates resolved. Inputs/hashes: `morning-burndown-v1.json`; S1 spec `dfe6ad5`, `retention-passive-batches.md`.

Observed admission ratio: **8/15 matrix attempts (53.3%)**; including receipt/owner-reported attempts: **8/17 (47.1%)**. Matrix post-title-screen subset: **8/10**. Unfinished tests included; no probabilities. Minimum pass rates slow/mid/fast: **109.1%/80.0%/57.1%** of queue-capped attempts (>100% would be impossible). Fast raw-slot threshold 52.2% requires more eligible titles than current queue.

Biggest measured time sink: **between-run gaps, 69.8min total / 34.9min per addition** across Halls/Hogwarts. Unallocated, not proven screen waiting; operator/other waits and within-run startup/play/save splits unavailable.
<!-- burndown:end -->
