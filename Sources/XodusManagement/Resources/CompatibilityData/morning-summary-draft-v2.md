# Ode to X: morning draft v2

22 October 2026; live gate timestamp below, disk snapshot separately dated.

**Goal: 20 genuinely WORKING titles; current count: 5.** Gameplay, retained
progress and normal shutdown required; eligibility/cloud/app E2E are separate.

## What works / nearest additions

| WORKING | Evidence and limits |
|---|---|
| Hollow Knight | `s3-hollow-app-retention-receipt.json`; app E2E. |
| No Man's Sky | `nms-nonnative-retained-20261022T0010/qualification.json`; free Wine; app E2E separate. |
| Minecraft Java | Native retention admitted in matrix; Ode integration pending. |
| Halls of Torment | `s3-halls-retention-02`; combat, gold/Quest Stone retention, normal quit. |
| Hogwarts | `f2471368`; retained checkpoint plus ordinary Quit to OS, CLI0/Wine0. |

**Brotato:** newer matrix proves gameplay/Chunky unlock, fresh-process retention
and normal quits (`12ebe02b`, `430e9c33`); candidate only, CLI promotion pending.
**Hades II/Abiotic:** retention/gameplay gates remain; historical Hades recipe
is not current-runtime parity. **Inscryption:** NO_TITLE_SCREEN (`3b833cc7`);
CLI0 is not success. Well needs actual-title engine retest; Fallout save diagnosis.
Batch 2/3 are dry queued packets, not title-screen passes or unrestricted grants.

## Decisions / holds

CLI `ebd56e` promotion **PENDING** (`3f2e500`); user-folder isolation **PENDING**
(`08d3a33`); WineGStreamer **DEFER** pending actual media failure/ABI proof;
16 MiB boundary rebuild **DEFER**, not proven Fallout causality.
App `1f598fc` installed, 10/11 tiles accepted; TUNIC exception.
**RC `42f793d` notarized, not installed.** Rollbacks retained.

**PENDING catalogue/reclaim:** ranked eight all in official Game Pass feed;
ownership unknown, installs closed. Digging/Balatro payload-only proposal frees
0.459 GiB, insufficient for any ranked-eight install under 155+2 GiB.
Keep Digging if STA comparison scheduled. Retain other near-term payloads.
**Delete nothing; saves/prefixes/evidence held.**

**Disk:** 156.86 GiB at 05:31 EEST, not a fresh measurement. Install margin
157 GiB; passive prestart 153/abort 152 GiB. No steady depletion forecast.
Sources: current matrix, `morning-pending-v1.json`, `s3-preflight-next-v1.json`.
<!-- living-tracker:start -->
Living tracker 2026-10-22T02:54:01.800096+00:00: **5/20** strict: Halls of Torment, Hogwarts Legacy, Hollow Knight: Voidheart Edition, Minecraft: Java Edition with Minecraft Launcher, No Man's Sky. Brotato WORKING_CANDIDATE remains excluded; see current row for gate evidence and CLI promotion hold. Same-gate >2h: none observed yet; pre-tracker gate ages unknown. Refresh every30min and owner verdict.
<!-- living-tracker:end -->
<!-- burndown:start -->
## Burn-down estimate (not promised passes)

Deadline **23 Oct 01:26 EEST**; 19.53h from 2026-10-22T02:54:01.800096+00:00. Halls passive-to-qualified: **43.9min**; Hogwarts title-probe-to-qualified proxy: **87.5min** (no bound passive start). One serial, continuously available lane yields **13/17/26** slow/mid/fast cycles, capped by **21 queued dry packets**: conditional totals **18/22/26**. Every attempted title must pass; sleep, focus, disk and failures reduce this. No probability assumed; only current admitted count is assured.

Need **15** additions; slow scenario leaves **2**. Required mean: **78.1min/addition**. Brotato CLI promotion can add one without another full cycle. Engine/recipe fixes (Inscryption/Well/Mixtape) and eight catalogue titles (entitlement/disk/install approval) add alternatives, not time. Existing queue already covers 15; catalogue expansion alone cannot cure the slow-rate gap. All these blocked lanes are excluded. Inputs/hashes: `morning-burndown-v1.json`; S1 retention spec `dfe6ad5`, `retention-passive-batches.md`.
<!-- burndown:end -->
