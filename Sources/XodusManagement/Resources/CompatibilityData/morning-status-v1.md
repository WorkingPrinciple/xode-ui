# Morning status

Snapshot: 2026-10-22T02:10:32.824264+00:00. Matrix updated: 2026-10-22T01:08:48Z.

WORKING: **3** | TITLE_SCREEN: **2** | BLOCKED: **22** | UNTESTED: **23**

GAMEPLAY_PASS remains BLOCKED pending retention, not WORKING. Catalogue ownership, anti-cheat absence and offline Store behavior remain unverified. No installs, launches or deletions in this task. Full paths, raw verdicts, exact blockers and source hashes are in `morning-status-v1.json`; table evidence uses basenames.

## Blocker priorities

Qualitative return per effort, not measured hours or promised WORKING counts. Groups cover BLOCKED titles only; suspected causes remain unproven. No installation/retest is authorized by this table.

| Rank | Class | Titles | Effort / best next gate |
|---|---|---|---|
| 1 | untested recipe (4) | Balatro, Hades II, Hogwarts Legacy, Well Dweller | Low-to-medium, title-specific: two gameplay passes already exist; one repaired-host retest and one unknown-render diagnosis remain. No measured engineering-hour estimate. Next: Finish Hades II/Hogwarts normal save, quit and retained-world relaunch under coordinator admission; then Well Dweller's repaired-host title retest. Balatro needs exact API-trace diagnosis, not a blind fallback. |
| 2 | CLI bug (1) | Brotato | Low-to-medium engineering relative to a new implementation: S2 already has a parser-fix candidate; integration/release review and exact launch-path validation remain. Frozen CLI is still held. Next: S2/coordinator release the corrected user-data page-unit parser through the CLI's status AND launch paths, then admit Brotato qualification. Do not promote the installer-only candidate or retry frozen adf8. |
| 3 | missing engine feature (2) | A Game About Digging A Hole™, Fallout 4 | Unknown/high diagnostic effort; this is a suspected engine/provider investigation lane, not two proven missing features or evidence that one patch fixes both. Next: Read S2's admitted no-game storage-provider probe for Fallout before another title run; diagnose Digging's exact COM/factory path before any implementation or switch. Keep provider-cap causality unproven. |
| 4 | disk/ownership (15) | Age of Empires IV: Anniversary Edition, Blue Prince, Disco Elysium - The Final Cut, Dome Keeper, Fable, High On Life 2, Hollow Knight: Silksong, INSIDE, Kingdom Come: Deliverance II, Minishoot' Adventures, Nine Sols, Resonance: A Plague Tale Legacy, South of Midnight, SUPERHOT: MIND CONTROL DELETE, Valor Mortis | Largest numerical group, but entitlement verification, coordinator admission, disk/staging budget and fresh per-title tests are required. No engineering patch establishes ownership. Next: Leave uninstalled. Verify entitlement only through a newly admitted CLI install path, never a probe now. Recheck 155+2 GiB margin and per-batch budget if the coordinator later reopens installation. |
| 5 | anti-cheat/online (0) | None established | No established blocker of this class in these 22 rows; zero does NOT mean anti-cheat absent or offline cleared. Next: Retain unknown anti-cheat/offline status. Consult existing catalogue evidence before any future eligibility change; no blanket support. |

## Per-title status

| Title | State | Blocker / next action | Evidence |
|---|---|---|---|
| Hollow Knight: Voidheart Edition | WORKING | None for admitted gameplay/save/quit/relaunch or actual app E2E. Bench gate explicitly replaced by coordinator; no cloud-save... Next: Preserve qualified recipe/save; app/cloud gates separate. | `s3-hollow-app-retention-receipt.json` |
| Minecraft: Java Edition | WORKING | No title-count blocker. Next: Preserve qualified recipe/save; app/cloud gates separate. | `s3-tried-games.json` |
| No Man's Sky | WORKING | CrossOver WORKING admitted; free-Wine gameplay/save/relaunch also qualified by S1 with actual evidence inspected by S3. App_e... Next: Preserve qualified recipe/save; app/cloud gates separate. | `relaunch-trial-result.json` |
| Abiotic Factor | TITLE_SCREEN | Full world/play/save/quit/relaunch qualification still pending; coordinator schedules same successful STA-only recipe after F... Next: Admitted gameplay + save/quit/retention check. | `s3-tried-games.json` |
| Halls of Torment | TITLE_SCREEN | Title screen only; gameplay, save and retained relaunch not qualified. Exact API remains unobserved. Next: Admitted gameplay + save/quit/retention check. | `receipt.json` |
| A Game About Digging A Hole™ | BLOCKED | RegionPolicyEvaluator factory error and COM marshal IID1f02b6c5-7842-4ee6-8a0b-9a24183a95ca HRESULT80004002; factory-error ca... Next: Resolve named gate; no automatic retry/install. | `s3-tried-games.json` |
| Age of Empires IV: Anniversary Edition | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-ready-packets-v4.json` |
| Balatro | BLOCKED | No observed rendering; causal exit unknown. S1 read-only API-trace diagnosis, not blind STA or graphics fallback. Both COM sw... Next: Resolve named gate; no automatic retry/install. | `s3-tried-games.json` |
| Blue Prince | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-preflight-catalogue-v1.json` |
| Brotato | BLOCKED | Frozen adf8 status exit101; candidate-only status complete does not clear the frozen launch path. Next: Resolve named gate; no automatic retry/install. | `s3-preflight-small-v1.json` |
| Disco Elysium - The Final Cut | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-preflight-catalogue-v1.json` |
| Dome Keeper | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-preflight-catalogue-v1.json` |
| Fable | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-ready-packets-v4.json` |
| Fallout 4 | BLOCKED | Manual-save continuation also leaves bothproviders empty after15s waits. NEXT Fallout run HOLD pending S2 no-game frozen-prov... Next: Finish admitted retention gate; await settled owner publication. | `s3-fallout-discovery-v2.json` |
| Hades II | BLOCKED | Final save/checkpoint and clean quit/relaunch pending; no Xbox cloud-save claim. Game PID77808 and wineserver77721 confirmed ... Next: Finish admitted retention gate; await settled owner publication. | `s3-tried-games.json` |
| High On Life 2 | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-ready-packets-v4.json` |
| Hogwarts Legacy | BLOCKED | Owner-reported gameplay pass only; normal save, quit and retained-world relaunch unverified. Matrix publication pending settl... Next: Finish admitted retention gate; await settled owner publication. | `s3-hogwarts-world-exit-cave.png` |
| Hollow Knight: Silksong | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-preflight-catalogue-v1.json` |
| INSIDE | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-preflight-catalogue-v1.json` |
| Kingdom Come: Deliverance II | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-ready-packets-v4.json` |
| Minishoot' Adventures | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-preflight-catalogue-v1.json` |
| Nine Sols | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-preflight-catalogue-v1.json` |
| Resonance: A Plague Tale Legacy | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-ready-packets-v4.json` |
| South of Midnight | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-ready-packets-v4.json` |
| SUPERHOT: MIND CONTROL DELETE | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-preflight-catalogue-v1.json` |
| Valor Mortis | BLOCKED | No installed manifest found in current owned-root inventory; ownership/entitlement unverified, install hold and 155+2 GiB mar... Next: Resolve named gate; no automatic retry/install. | `s3-ready-packets-v4.json` |
| Well Dweller | BLOCKED | CrossOver8x/16x MSAA HRESULT80070057 reproduced by S1. Old vanilla-Wine DXMT host lacks Metal-view symbols. New welldweller-d... Next: Resolve named gate; no automatic retry/install. | `s3-tried-games.json` |
| Beast of Reincarnation | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `queue-profiles.json` |
| Bluey's Happy Snaps | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `queue-profiles.json` |
| DEATHLOOP | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `queue-profiles.json` |
| Dishonored® Definitive Edition (PC) | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `preflight-game-candidates.json` |
| DOOM 64 | UNTESTED | Earlier renderer-selection hold superseded by exact S1 Kex candidate; no title-screen/gameplay/save receipt or execution gran... Next: Schedule exact S1 candidate with exclusive input slot. | `kex-game-candidates.json` |
| DREDGE | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `small-game-candidates.json` |
| FINAL FANTASY IV | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `preflight-game-candidates.json` |
| Forever Ago | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `queue-profiles.json` |
| Inscryption | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `small-game-candidates.json` |
| Keeper | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `queue-profiles.json` |
| Kingdom Come: Deliverance | UNTESTED | Queued for actual game test. Next: Schedule exact S1 candidate with exclusive input slot. | `s3-tried-games.json` |
| LIMBO | UNTESTED | Queued for actual game test. Next: Schedule exact S1 candidate with exclusive input slot. | `s3-tried-games.json` |
| Mixtape | UNTESTED | Queued for actual game test. Next: Schedule exact S1 candidate with exclusive input slot. | `s3-tried-games.json` |
| Monster Sanctuary | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `small-game-candidates.json` |
| Quake | UNTESTED | Earlier renderer-selection hold superseded by exact S1 Kex candidate; no title-screen/gameplay/save receipt or execution gran... Next: Schedule exact S1 candidate with exclusive input slot. | `kex-game-candidates.json` |
| REPLACED | UNTESTED | Queued for actual game test. Next: Schedule exact S1 candidate with exclusive input slot. | `s3-tried-games.json` |
| Stardew Valley | UNTESTED | Queued for actual game test. Next: Schedule exact S1 candidate with exclusive input slot. | `s3-tried-games.json` |
| Subnautica 2 (Game Preview) | UNTESTED | Queued for actual game test. Next: Schedule exact S1 candidate with exclusive input slot. | `s3-tried-games.json` |
| The Elder Scrolls IV: Oblivion Game of the Year Edition (PC) – 2009 | UNTESTED | Queued for actual game test. Next: Schedule exact S1 candidate with exclusive input slot. | `s3-tried-games.json` |
| The Elder Scrolls V: Skyrim Special Edition (PC) | UNTESTED | Queued after Fallout with adf8 and S1 per-title engine binding; no missing-file or reinstall blocker remains. Next: Schedule exact S1 candidate with exclusive input slot. | `s3-tried-games.json` |
| TUNIC | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `small-game-candidates.json` |
| Vampire Survivors | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `small-game-candidates.json` |
| Wasteland Remastered | UNTESTED | No observed title/gameplay/save-retention receipt admitted; packet is a candidate, not a pass. Next: Schedule exact S1 candidate with exclusive input slot. | `unity-gamemaker-candidates.json` |

## Disk

Free: **157.84 GiB**. Measured net rate over 445s: **-19.84 GiB/h**. 150 GiB estimate at that rate: **not decreasing during the sample**.

| Measured path | Growth | Rate |
|---|---|---|
| `~/src/copilot-worktrees/xodus-macos-app/dragoshont-super-spork/.build/retained-release-evidence-20261022T050629` | 312.04 MiB | 2.468 GiB/h |
| `~/.copilot/session-state/9df8acf4-7a95-43ac-84d5-d81fcdd55702/files` | 19.24 MiB | 0.152 GiB/h |
| `~/Library/Application Support/XodusCLI/proofs/s3-hogwarts-sta-world-02` | 8.01 MiB | 0.063 GiB/h |

Earlier volume baseline spans 12.9 minutes: -8.84 GiB/h net. Neither trend proves steady future consumption.

Repeated filesystem-metadata samples measure per-path allocated deltas, not exclusive physical APFS ownership. Recent mtime footprint is NOT measured 15-minute growth; no historical per-file sample exists. Metadata allocation can count hardlinks differently from historical du baselines; prefix differences are not exclusive physical allocation. Volume net rate includes other sessions, builds and APFS accounting. Shader growth, fresh prefix creation and screenshots are bursty, so hours-to-floor is an extrapolation, not a depletion forecast.

The initial 67s interval consumed 18.42 GiB/h net; `~/src/copilot-worktrees/xodus-macos-app/dragoshont-super-spork/.build/local-candidates` grew 391.37 MiB. Subsequent shared-volume free-space recovery invalidates a steady depletion ETA. Coordinator attributes the gain to authorized S5 cleanup; no cleanup or move was performed by this collector. Hogwarts shader and Fallout prefix allocations did not grow between the measured endpoints.

Latest post-cleanup interval (138s): **14.99 GiB/h** net; `~/src/copilot-worktrees/xodus-macos-app/dragoshont-super-spork/.build/local-candidates` grew 301.59 MiB. 150 GiB floor in **0.52 h** if that short post-cleanup rate persists; not a steady forecast.
