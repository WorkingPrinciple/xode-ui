# Ode to X: morning draft v2

Draft updated after the 05:31 EEST snapshot, 22 October 2026; refresh before sharing.

**Goal: 20 genuinely WORKING titles; current count: 4.** WORKING requires
gameplay, retained saves and normal shutdown. MSIXVC/no-anti-cheat eligibility
and cloud sync are separate. Current living counts and per-title gates: `path-to-20-v1.json`. Testing is the bottleneck.

## What works

| Title | Evidence and limits |
|---|---|
| Hollow Knight | Gameplay/retention/app E2E: `s3-hollow-app-retention-receipt.json`. |
| No Man's Sky | CrossOver and free-Wine retention: `nms-nonnative-retained-20261022T0010/qualification.json`. App E2E separate. |
| Minecraft Java | User-admitted native retention: `s3-tried-games.json`; Ode integration pending. |
| Halls of Torment | `s3-halls-retention-02`: combat, retained gold/Quest Stone, ordinary quit; admitted strict. |

## Closest additions

**Hogwarts:** retained checkpoint proven (`86e8da68`); only normal quit/clean
exit remains. **Hades II:** gameplay works; checkpoint/quit/reload remain.
Its historical CLI419c/runtime6a66 recipe is not current-runtime parity.
**Halls:** now WORKING. **Abiotic:** title screen only; gameplay/retention remain.
**Well Dweller:** host checks pass; actual-title retest/retention remain.
**Fallout:** gameplay works, observed save providers empty; diagnostic hold.

All 23 UNTESTED installs complete on adf8; seven overlap passive nine.
Next: LIMBO, Stardew, KCD1, Skyrim, FFIV, Dishonored, DOOM64, Quake.
S2 dry packets use 152 GiB; no launch grant. TUNIC CLI completed in 53.75s;
its app failure remains under investigation.

## Decisions / handoffs

| Item | Current position |
|---|---|
| CLI RC `ebd56e` / Brotato | PENDING (`3f2e500`). Candidate menu proven; forced shutdown is not normal quit. Gameplay/save/relaunch untested; frozen adf8 panics; not promoted. |
| Prefix user-folder isolation | PENDING (`08d3a33`). No existing save/link changes without scoped approval. |
| WineGStreamer | DEFER until a demonstrated media blocker and exact ABI/source/dependency proof. |
| 16 MiB boundary | Runtime rebuild DEFERRED to user: exact-limit rejection proven, **not Fallout causality**. |
| App RC `1f598fc` | **Installed 05:24** under S3 release; 10/11 tiles accepted, TUNIC exception. Rollbacks `cdd54a1`/`8140bb2` kept. |

## PENDING: catalogue and reclaim decisions

**Ranked eight:** all present in the app's official PC Game Pass feed (US/en-US).
This is catalogue membership, **not account entitlement**.
The empty Owned listing leaves ownership unknown. Catalogue installs stay closed.

**Payload-only reclaim proposal:** Digging **0.353 GiB**, Balatro **0.106 GiB**;
neither has a validated startup fix. Even combined, **0.459 GiB** would not
admit any ranked-eight install under 155+2 GiB at the measured free space.
Keep Digging if its STA comparison is scheduled. Retain Brotato, Well Dweller,
Fallout, Hades and Hogwarts for their pending RC/test/retention paths.
**User decision only; delete nothing. Saves, prefixes and evidence stay held.**

**Disk:** **156.86 GiB** free at 05:31 EEST; below the 157 GiB install margin.
No steady depletion forecast. Passive preparation's separate rule is 152 GiB.

Sources: `morning-status-v1.json`, `s3-preflight-next-v1.json`,
`catalogue-ownership-v1.json`, `morning-pending-v1.json`; current S3 matrix
and coordinator's RC/Hogwarts decisions. S5 switch receipt:
`Ode-switchover-buf1ry__/switch-over-receipt.json` (SHA `b9d0f28b...97aa4fb`).
<!-- living-tracker:start -->
Living tracker 2026-10-22T02:37:49.270790+00:00: **4/20** strict: Halls of Torment, Hollow Knight: Voidheart Edition, Minecraft: Java Edition with Minecraft Launcher, No Man's Sky. Brotato WORKING_CANDIDATE awaits CLI promotion and full gates: S2 proves menu only, forced quit; gameplay/save/relaunch untested. Same-gate >2h: none observed yet; pre-tracker gate ages unknown. Refresh every30min and owner verdict.
<!-- living-tracker:end -->
