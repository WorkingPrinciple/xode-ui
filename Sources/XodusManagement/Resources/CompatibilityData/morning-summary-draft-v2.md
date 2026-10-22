# Ode to X: morning draft v2

Draft updated 05:24 EEST, 22 October 2026; refresh before sharing.

**Goal: 20 genuinely WORKING titles; current count: 3.** WORKING requires
gameplay, saved progress, a new-process reload and normal shutdown, not just
a title screen. The 0.1 eligibility gate remains MSIXVC plus evidence-backed
absence of anti-cheat; game-run qualification does not establish that clearance
or Xbox cloud sync. The frozen 50-title snapshot has 3 WORKING, 2 TITLE_SCREEN,
22 BLOCKED and 23 UNTESTED. Testing, not more installations, is the bottleneck.

## What works

| Title | Evidence and limits |
|---|---|
| Hollow Knight | Gameplay, save/relaunch and actual app E2E admitted. S3: `s3-hollow-app-retention-receipt.json`. |
| No Man's Sky | Retained-world qualification on CrossOver and free Wine (`gptk3-d3dshared`). Free proof: Engines/evidence/`nms-nonnative-retained-20261022T0010/qualification.json`. App E2E remains separate. |
| Minecraft Java | User-admitted native retained-world result in `s3-tried-games.json`; Ode provider/app integration remains pending. |

## Closest additions

**Hogwarts:** retained cave checkpoint is proven (run `86e8da68`); only ordinary
Quit to Main Menu, EXIT GAME and clean CLI/Wine exit remain. Still not WORKING.
**Hades II:** actual movement/combat works; reach a real checkpoint, quit
normally and reload it. Its proven recipe is historical CLI419c/runtime6a66,
not assumed parity with current adf8/7106.
**Halls / Abiotic:** title screens observed; gameplay and retained-save gates
remain. **Well Dweller:** host MSAA/presentation checks pass, actual-title
retest and retention do not. **Fallout:** gameplay works, but both observed
save providers stayed empty; diagnostic hold remains.

All 23 UNTESTED installs freshly report complete on adf8. Seven already belong
to the passive nine. Next eight explicit candidates: LIMBO, Stardew, KCD1,
Skyrim, FFIV, Dishonored, DOOM64 and Quake. S2 has built their dry packets under
the 152 GiB rule; no launch/prefix creation. TUNIC's CLI check took 53.75 seconds;
the app's incomplete-operation report is separately under S5 investigation.

## Decisions / handoffs

| Item | Current position |
|---|---|
| CLI RC `ebd56e` for Brotato | User decision pending (`cli-rc-brotato.md`, S2 `3f2e500`). Candidate install/status completes; frozen adf8 panics. Actual candidate launch untested; no promotion. |
| Prefix user-folder isolation | User decision pending (`docs/proposals/prefix-user-folders.md`, app `08d3a33`). Do not move existing Documents/saves or change prefix links without scoped approval. |
| WineGStreamer | DEFER. No demonstrated title-level audio/video blocker justifies a build yet; exact host ABI/source and free dependency closure must be established first. |
| 16 MiB boundary | User decision on runtime rebuild: frozen provider rejects exactly 16 MiB. S2 no-game probe proves the boundary defect, **not** that it causes Fallout's missing saves. |
| App RC `1f598fc` | **Installed at 05:24 under S3's release.** 10/11 candidate tiles accepted; TUNIC remains under investigation. Rollbacks `cdd54a1` and `8140bb2` kept. This does not promote the CLI/runtime fixes above. |

**Disk:** 157.38 GiB free at 05:23 EEST. The earlier build-growth burst ended;
its depletion ETA is obsolete. No steady consumption forecast. Install hold
and 155+2 GiB staging margin remain; passive preparation uses its separate
152 GiB rule. No new cleanup is authorized here.

Sources: `morning-status-v1.json` (`83280e1`), `s3-preflight-next-v1.json`
(`982f810`), `save-baseline-v1.json` (`f7dcfea`); authoritative S3 matrix updated
02:15:10Z; coordinator's latest Hogwarts/RC decisions. RC receipt:
S5 `.build/local-candidates/Ode-switchover-buf1ry__/switch-over-receipt.json`,
SHA `b9d0f28bf65c0c46b5b16f63d519a56625eefa840586775eb512bbcfc97aa4fb`.
Provider evidence: XodusCLI/proofs/`frozen-provider-no-game-v1/storage-receipt.json`.
Dry batch: XodusCLI/proofs/`passive-batch2-eight-v1/packets.json`.
