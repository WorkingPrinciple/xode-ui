# Free-title morning decision list

MORNING USER DECISION ONLY. Free licenses are acquisitions; no acquisition or install tonight. Ranked by technical/test fit, not predicted success or popularity score. No title has an approved exact recipe or anti-cheat clearance.

Snapshot 2026-10-22T04:12:29.367246+00:00; free **155.151 GiB**. **No title fits the 155+2 GiB retained floor.**

155 GiB retained floor plus 2 GiB safety margin = 157 GiB retained. Planning budget=max(current PC MSIXVC MaxDownloadSizeInBytes, publisher cross-build storage requirement); NOT measured installed size/peak. Additional staging, prefix, shader and network downloads unknown; required free/reclaim values are lower bounds.

| Rank | Title / MSIXVC product | Payload GiB | Planning GiB | Engine / public API | Route hypothesis | Min reclaim GiB |
|---|---|---|---|---|---|---|
| 1 | [Tell Me Why](https://www.xbox.com/en-us/games/store/-/9NBL0XKVCN5L) `9NBL0XKVCN5L` | 7.697 | 23.283 | Unreal Engine 4 / DX11 minimum; DX12 recommended | Apple4 d3dmetal/default COM first hypothesis; CrossOver nativejson alternative, STA only after exact title-specific evidence | 25.132 |
| 2 | [Killer Instinct](https://www.xbox.com/en-us/games/store/-/9NBLGGH1Z149) `9NBLGGH1Z149` | 47.263 | 47.263 | Slayer / DX11 | Apple4 d3dmetal/default COM or CrossOver nativejson; no evidence for STA | 49.111 |
| 3 | [Asphalt Legends](https://www.xbox.com/en-us/games/store/-/9NZQPT0MWTD0) `9NZQPT0MWTD0` | 9.543 | 9.543 | Jet Engine / DX12 | Apple4 d3dmetal/default COM hypothesis; no title-specific STA evidence | 11.392 |
| 4 | [World of Tanks Blitz](https://www.xbox.com/en-us/games/store/-/9MWBFDRGH1SW) `9MWBFDRGH1SW` | 20.743 | 20.743 | Bigworld / DAVA Engine (PCGamingWiki) / DX11 | Apple4 d3dmetal or CrossOver nativejson hypothesis; no STA evidence | 22.592 |
| 5 | [Disney Speedstorm](https://www.xbox.com/en-us/games/store/-/9PMR3T9NSF8W) `9PMR3T9NSF8W` | 25.849 | 37.253 | Jet Engine / DX12 | Apple4 d3dmetal/default COM hypothesis; no STA evidence | 39.102 |

## Fit and licensing cautions

- **Tell Me Why:** Best narrative/singleplayer shape. Free base/chapter-one scope only; do not claim chapters2/3 owned or licensed. Needs user acceptance of chapter scope, free acquisition, anti-cheat evidence and new S1 exact recipe. [Engine](https://www.pcgamingwiki.com/wiki/Tell_Me_Why); [PC API requirements](https://store.steampowered.com/api/appdetails?appids=1180660&l=english&cc=us).
- **Killer Instinct:** Free base; exact free roster/mode restrictions need confirmation. Good API match, very poor disk fit; login/mode/retention/anti-cheat unverified. [Engine](https://www.pcgamingwiki.com/wiki/Killer_Instinct); [PC API requirements](https://store.steampowered.com/api/appdetails?appids=577940&l=english&cc=us).
- **Asphalt Legends:** Smallest catalog MSIXVC payload among these racers. Online/account and anti-cheat unknowns make it worse than a simple offline title. [Engine](https://www.pcgamingwiki.com/wiki/Asphalt_Legends); [PC API requirements](https://store.steampowered.com/api/appdetails?appids=1815780&l=english&cc=us).
- **World of Tanks Blitz:** Online multiplayer/server progression; not a quick local-save retention analogue. Anti-cheat unknown; exact installed renderer not observed. [Engine](https://www.pcgamingwiki.com/wiki/World_of_Tanks_Blitz); [PC API requirements](https://store.steampowered.com/api/appdetails?appids=444200&l=english&cc=us).
- **Disney Speedstorm:** Online/server-side progress; Local Freeplay exception does not establish a local save provider. Higher disk budget; anti-cheat unknown. [Engine](https://www.pcgamingwiki.com/wiki/Disney_Speedstorm); [PC API requirements](https://store.steampowered.com/api/appdetails?appids=1537830&l=english&cc=us).

**Anti-cheat remains unknown for every ranked title**; singleplayer is not evidence of none. Apple4/CrossOver are renderer-family hypotheses only; no blanket STA, inherited launch grant or WORKING claim.

## Account library

Fresh existing-account `auth.status` -> `ode.account.read.v1(section=library)` -> `auth.status`: complete, same account bound, **0 product rows**, so **no already-owned additions proved**. Empty collection is not a denial of subscription access or proof of no purchases. Raw account identifiers stay local; receipt identity in JSON.

## Small/popular exclusions

| Title | Largest catalog payload GiB (not install size) | Reason |
|---|---|---|
| Phantom Dust | 9.505 | EAppx, not MSIXVC; no current 0.1 route |
| One Leaves | 2.520 | Appx/EAppx, not MSIXVC; no current 0.1 route |
| OpenTTD (official) | 0.045 | AppxBundle/MsixBundle, not MSIXVC. Win32 desktop app may be repackaged; native macOS is separate scope. |
| Beach Buggy Racing | 0.187 | AppxBundle, not MSIXVC |
| Hill Climb Racing | 0.079 | x86 AppxBundle, not MSIXVC |
| Microsoft Solitaire Collection | 0.143 | MsixBundle, not MSIXVC |
| Microsoft Minesweeper | 0.249 | MsixBundle, not MSIXVC |
| Microsoft Mahjong | 0.292 | MsixBundle, not MSIXVC |
| Microsoft Jigsaw | 0.167 | x86 MsixBundle, not MSIXVC |
| Warzone 2100 for Windows | 1.287 | MsixBundle, not MSIXVC; native version separate scope |
| Roblox - Windows | 0.370 | Hyperion/Byfron Wine blocker reported; reject as anti-cheat candidate, no bypass or alternative-client plan |
| Brawlhalla | 0.010 | 10 MiB catalog stub is NOT full game size; anti-cheat/online risk, no full payload budget or cleared recipe |

Fallout Shelter was not returned as an exact title in current Desktop search; Pinball FX/FX3 not returned as exact Desktop titles either. Xbox console/cloud pages are not PC install evidence. They are not queued. Search result zero prices (including unrelated paid Game Pass products) were NOT treated as free licenses; ranked rows retain explicit zero-USD Purchase availability records.

## Read-only parked-prefix/cache reclaim proposal

Proposal only. Whole-prefix rows and nested caches overlap; sum only whole prefixes once. du allocated bytes do not guarantee APFS physical reclaim (clones/snapshots/shared extents). Saves, registries, receipts and prefix history may be valuable; inspect/preserve under owner+user decision before deletion. Documents links target host Documents; never follow/delete host targets. Quiescence/references not exhaustively checked; no deletion authorized. Working/pending retained prefixes, payloads and proof directories excluded.

| Exact path | Allocated GiB | Interpretation |
|---|---|---|
| `/Users/dragoshont/Library/Application Support/XodusCLI/prefixes/s2-balatro-apple4-exit-v1` | 0.461914 | Balatro parked |
| `/Users/dragoshont/Library/Application Support/XodusCLI/prefixes/s3-balatro-free-v1` | 0.461914 | Balatro parked alternative |
| `/Users/dragoshont/Library/Application Support/XodusCLI/prefixes/s3-hogwarts-cross-26-3` | 0.328312 | Superseded CrossOver lane; working STA Apple4 held |
| `/Users/dragoshont/Library/Application Support/XodusCLI/prefixes/s3-digging-cross-26-3` | 0.325268 | Parked CrossOver lane; proposed STA comparison must be checked |
| `/Users/dragoshont/Library/Application Support/XodusCLI/prefixes/s3-well-cross-26-3` | 0.325249 | Old CrossOver lane; diagnostic/provider evidence hold |
| `/Users/dragoshont/Library/Application Support/XodusCLI/prefixes/s3-well-dxmt` | 0.357613 | Old DXMT lane; confirm not needed for candidate retest |
| `/Users/dragoshont/Library/Application Support/XodusCLI/prefixes/s2-small-9P8NSTDMZ11P-creation-dx11-d3dmetal-passive-v1` | absent; 0 reclaim | S2 failed Inscryption; cleanup receipt says already removed |
| `/Users/dragoshont/Library/Application Support/XodusCLI/prefixes/s2-inscryption-timing300-creation-dx11-fresh-v1` | absent; 0 reclaim | S2 timing retry result binds this exact prefix |

Exact nested Temp/INetCache paths and sizes are retained in JSON; they are already included in their parent and never additive.

Conditional whole-prefix sum **2.260 GiB**; optimistic free afterward **157.412 GiB** (not a guaranteed physical gain). No ranked title fits even after this sum. Absent Inscryption names are not reclaimable; do not count prior cleanup again. The retained `s3-inscryption-crossover-nativejson-alt-v1` lane is deliberately excluded from parked-prefix proposals, as is the admitted fresh `s3-inscryption-crossover-nativejson-alt-retry-v2` route. S2 reports no additional known Apple4 cache path; earlier cleanup already reclaimed bytes, not new morning capacity.

Sources, full offer/package fields, account receipt hash and technical requirements receipt hash: `free-morning-candidates-v1.json`. No acquisition, install, launch, prefix write or deletion performed.
