# Ode to X: morning draft v2

22 October 2026; live gate timestamp below, disk snapshot separately dated.

**Goal: 20 genuinely WORKING titles; current count: 7.** Gameplay, retained
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

**Brotato:** newer matrix proves gameplay/Chunky unlock, fresh-process retention
and normal quits (`12ebe02b`, `430e9c33`); candidate only, CLI promotion pending.
**Hades II:** checkpoint retention now WORKING; earlier conversation-marker
failure is historical and not the accepted checkpoint criterion.
**Mixtape:** matrix GAMEPLAY_PASS, retention INCONCLUSIVE (`77083b32`), CLI0/Wine0 but no chapter
completed or save yet; no unchanged automatic retry. **Inscryption:** NO_TITLE_SCREEN (`3b833cc7`),
known hold until its retry at the end of the queue;
CLI0 is not success. **Well:** INCONCLUSIVE/parked (`9c31530d`), gameplay
reached but TIMEOUT/CLI1/Wine0 and no save marker; no retry grant.
Fallout save diagnosis remains separate.
Batch 2/3 are dry queued packets, not title-screen passes or unrestricted grants.
Coordinator reports pipeline cap 23 from S1 `5b944e3` KCD1/Subnautica 2 routes;
S2 packets are being prepared. Both product IDs already exist in old packets:
S1 census confirms no additional unique installed titles: historical packet
baseline remains 21, not 23 unique titles or an executable queue.
**LIMBO:** passive failed before title screen (shader compiler error,
CLI1/Wine1 at 22s); S1 researching an alternative route.
**DREDGE:** reload `a452bd89` retained its save, but quit exited 255:
INCONCLUSIVE, ordinary quit still required; strict count unchanged.

## Decisions / holds

CLI `ebd56e` promotion **PENDING** (`3f2e500`); user-folder isolation **PENDING**
(`08d3a33`); WineGStreamer **DEFER** pending actual media failure/ABI proof;
16 MiB boundary rebuild **DEFER**, not proven Fallout causality.
**RC `42f793d` installed**; Halls/Hogwarts Verified working, TUNIC Play.
Receipt `Ode-switchover-rewcsnje/switch-over-receipt.json`, SHA `0e3f7f81...`;
rollbacks retained. Play is not gameplay qualification.

**PENDING catalogue/reclaim:** ranked eight all in official Game Pass feed;
ownership unknown, installs closed. Digging/Balatro payload-only proposal frees
0.459 GiB, insufficient for any ranked-eight install under 155+2 GiB.
Keep Digging if STA comparison scheduled. Retain other near-term payloads.
**Delete nothing; saves/prefixes/evidence held.**

Free-title/acquisition and parked-prefix options: `free-morning-candidates-v1.md`.
**Morning user decision only**, not an install queue; fresh Owned read proved no additions.

**Disk:** 156.86 GiB at 05:31 EEST, not a fresh measurement. Install margin
157 GiB; passive prestart 153/abort 152 GiB. No steady depletion forecast.
Sources: current matrix, `morning-pending-v1.json`, `s3-preflight-next-v1.json`.
<!-- living-tracker:start -->
Living tracker 2026-10-22T05:29:13.970296+00:00: **7/20** strict: Abiotic Factor, Hades II, Halls of Torment, Hogwarts Legacy, Hollow Knight: Voidheart Edition, Minecraft: Java Edition with Minecraft Launcher, No Man's Sky. Brotato WORKING_CANDIDATE remains excluded; see current row for gate evidence and CLI promotion hold. Same-gate >2h: A Game About Digging A Hole, Age of Empires IV: Anniversary Edition, Balatro, Beast of Reincarnation, Blue Prince, Bluey's Happy Snaps, Brotato, DEATHLOOP, DOOM 64, Disco Elysium - The Final Cut, Dishonored® Definitive Edition (PC), Dome Keeper, FINAL FANTASY IV, Fable, Fallout 4, Forever Ago, High On Life 2, Hollow Knight: Silksong, INSIDE, Inscryption, Keeper, Kingdom Come: Deliverance, Kingdom Come: Deliverance II, Minishoot' Adventures, Monster Sanctuary, Nine Sols, Oblivion GOTY (2009), Quake, REPLACED, Resonance: A Plague Tale Legacy, SUPERHOT: MIND CONTROL DELETE, Skyrim Special Edition, South of Midnight, Stardew Valley, Subnautica 2, TUNIC, Valor Mortis, Vampire Survivors, Wasteland Remastered. Refresh every30min and owner verdict.
<!-- living-tracker:end -->
<!-- burndown:start -->
## Burn-down estimate (not promised passes)

Deadline **23 Oct 01:26 EEST**; 16.95h from 2026-10-22T05:29:13.970296+00:00. Halls passive-to-qualified: **43.9min**; Hogwarts title-probe-to-qualified proxy: **87.5min** (no bound passive start). One serial, continuously available lane yields **11/15/23** slow/mid/fast cycles, capped by **21 pipeline titles** (historical deduplicated packet baseline, not an executable queue): conditional totals **18/22/28**. These all-pass capacity ceilings assume uninterrupted focus; not predicted successes.

Need **13** additions; slow scenario leaves **2**. Required mean: **78.2min/addition**. Brotato CLI promotion can add one without another full cycle. Qualification/recipe holds (Inscryption/Well/Mixtape) and eight catalogue titles (entitlement/disk/approval) are excluded alternatives, not extra time. Queue already covers 13; catalogue alone cannot cure slow throughput. Inputs/hashes: `morning-burndown-v1.json`; S1 spec `dfe6ad5`, `retention-passive-batches.md`.

Observed admission ratio: **7/14 matrix attempts (50.0%)**; including receipt/owner-reported attempts: **7/16 (43.8%)**. Matrix post-title-screen subset: **7/10**. Unfinished tests included; no probabilities. Minimum pass rates slow/mid/fast: **118.2%/86.7%/61.9%** of queue-capped attempts (slow >100% impossible). Fast raw-slot threshold 56.5% requires more eligible titles than current queue.

Biggest measured time sink: **between-run gaps, 69.8min total / 34.9min per addition** across Halls/Hogwarts. Unallocated, not proven screen waiting; operator/other waits and within-run startup/play/save splits unavailable.
<!-- burndown:end -->
