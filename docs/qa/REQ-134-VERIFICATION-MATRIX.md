# REQ-134 on-screen verification matrix

Target: installed build **624**, `~/Applications/Ode to X Local Candidate.app`, X Ode 0.2.0 Beta, bundle
`com.workingprinciple.xode.development`, executable SHA-256
`b1143b9a8847c89cb6e3905e95a5619494b8d9effff77c9c309113ecda877dd2`, source `73647681` (tree `2ec283d9`).
The observer records these from the bundle at every snapshot; set `XODE_EXPECTED_SHA256` to refuse a different
binary.

Build 624 is a shipping build, so the only command-line entry points are `--play-game PRODUCTID` and
`--open-native-minecraft`. Both start a game and need a Wine slot, so the pass uses neither. Every screen below is
reached through allow-listed AX actions on the running app (AXPress, the search field's AXValue, AXScrollByPage on the main scroll area, the main window's AXSize, and activating X Ode while the owner is idle). The observer never synthesizes key or mouse events, and every action waits
for the owner to be idle (default 20 s, COR-272).

Evidence types: **AX** = accessibility-tree JSON (`*-ax-window*.json`) with identifiers, labels, frames, focus
and actions; **CAP** = window capture PNG (`screencapture -l`, owned windows only); **SCAN** = the observer's
content scan of every AX label for prices, commerce verbs, `MSIXVC`, sizes, paths, hashes and QA text;
**CON** = per-line WCAG contrast measured on the capture; **LOG** = `com.workingprinciple.xode` signposts and
logs (`load-latency`, `pc-library`, `catalog-detail`, `library-position`, `product-access`); **OWN** = owner
observation on [REQ-134-OWNER-SHEET.md](REQ-134-OWNER-SHEET.md).

Steps are those in `tools/qa/req134_run.sh` (`steps.tsv` records each one's exit status).

| REQ | Screen or state to reach | Observable acceptance | Evidence | Steps |
|---|---|---|---|---|
| REQ-4 | Main window at 1619×897, 1500×897, back to 1619×897, then 1280×800 and 1100×700 | First useful row visible at every size; no clipped sheet edge; returning to 1619 shows no stale gap from 1500; long titles truncate rather than overlap | AX frames, CAP | 06-size-* |
| REQ-5 | Library and Discover grids | No HP Smart, iCloud, PaintShop or other app titles in game surfaces; the AX card count matches the visible count | AX, SCAN | 02, 08 |
| REQ-8 | Library scrolled to the middle → Discover → Library | Same Library scroll offset (AX frame of the first visible card) and the same filter/sort values after the round trip; no focus jump | AX frames + `ode.library.filter`/`sort` values, LOG `library-position` | 07, 10, 11, 21 |
| REQ-9 | Discover ↔ Library switches and a search set while the results load | No result rows from the previous scope after switching; a stopped search shows "Search stopped" with Retry, distinct from empty | AX, LOG `catalog-detail` | 10–12 |
| REQ-10 | Discover search set to "mortis" | Search field `ode.catalog.search` is an AXTextField with an accessibility name; Valor Mortis is in the results; no price or commerce | AX, SCAN | 12; Command-F on the owner sheet |
| REQ-11 | Game detail for Valor Mortis at 1100×700, then closed | Artwork, title, facts and actions present at a small size; after closing, focus returns to the card it came from | AX (focused element before and after), CAP | 13, 14; Escape on the owner sheet |
| REQ-12 | Library refresh with the network off | Retained prior content plus an actionable error, not an empty library | AX, CAP | owner sheet O-12 |
| REQ-13 | Physical-trackpad scrolling with Instruments | Measured hitches and update cost | Instruments trace | owner sheet O-13 |
| REQ-14 | Hero swipes on the trackpad | Predictable adjacent page | OWN | owner sheet O-14 |
| REQ-15 | Library top with the hero visible; then the Account sheet open; then the app in the background | Hero stops advancing behind a sheet or in the background; trailer stops | Two CAPs 10 s apart compared (same hero title), LOG | 05, 16; owner sheet O-15 |
| REQ-16 | Library first load with artwork arriving | Card frames stay fixed while artwork loads; no oversized image | AX frames across 01/02, LOG `catalog-artwork` | 01, 02 |
| REQ-17 | Instruments compositor trace | Attributed cost or open hypothesis | Instruments | owner sheet O-13 |
| REQ-18 | Keyboard traversal with and without Full Keyboard Access | Visible focus on every stop, title-specific names, no double activation | OWN (key presses are not synthesized) | owner sheet O-18 |
| REQ-19 | Every captured window in the current appearance | Every control has a name (AX); text contrast per line measured; gaps listed | AX, CON | all snapshots, 30-contrast-* ; owner sheet O-19 for VoiceOver |
| REQ-20 | Current preferences, recorded read-only | Preferences recorded; behaviour under changed preferences observed by the owner | preflight `preferences`, OWN | 00; owner sheet O-20 |
| REQ-21 | The whole pass (tabs, scroll, sizes, detail) | Signpost intervals do not grow across repeats; no retained-work warnings; app memory recorded before and after | LOG, `footprint` (owner sheet) | 40-signposts |
| REQ-22 | Game detail facts | Metadata in the UI language; no Store or acquisition link | AX, SCAN | 13 |
| REQ-23 | Library, detail, Downloads | No proof paths, session IDs or QA narrative in labels; real progress visible | SCAN | 02, 13, 15 |
| REQ-59 | Search results | Grouped results with art, title and badges; scope stated | AX, CAP | 12 |
| REQ-60 | Cards, rows, search | No price, size, package or source on cards | SCAN | 02, 08, 12 |
| REQ-61 | Every surface | No price, Buy/Get/Pre-order or purchase link anywhere | SCAN | all |
| REQ-62 | Detail versus cards | "Xbox PC game" (package) only inside the detail Details group | SCAN (path of each `MSIXVC`/package hit must be under the detail window) | 13 vs 02/08/12 |
| REQ-63 | Library and detail of a purchased plus Game Pass title | Owned and Game Pass shown separately on card and detail | AX (`ode.game.accessBadge`) | 02, 13 |
| REQ-64 | Library scrolled through | Counts in headings equal the visible card count; Continue Playing cells hold art, title, last played and badges only | AX counts vs `ode.account.libraryCounts`, SCAN | 02–05 |
| REQ-65 | Discover shelves | No "Recently added" or "Leaving soon" without a source; no placeholders | AX | 08 |
| REQ-66 | Library shelves | Recently played and Recently added appear only with real dates | AX | 02 |
| REQ-75 | Launch, cold Library, refresh | Layout-shaped placeholders without fake progress; real errors and retry distinct | CAP, AX (`ode.firstLoad*`, `ode.pcGames.loading`), LOG `load-latency` | 01, 40 |
| REQ-76 | Continue Playing shelf in light appearance | No opaque white track under the shelf; See All (`ode.library.continuePlaying.showAll`) present with a count | CAP, AX | 03 |
| REQ-77 | Detail of an installed playable game | Hero subtitle does not repeat "Installed on this Mac" | AX, CAP | 13 (set `XODE_DETAIL_TITLE` to an installed title) |
| REQ-85 | Library shelves | No persistent buttons under cards; card press opens detail | AX (cards are single "View …" buttons) | 02, 13 |
| REQ-91 | Discover | No routine coverage or loading prose; no visible scroll indicators; recent searches only near search | AX, CAP | 08, 09 |
| REQ-93 | Account popup while a Library load runs | Popup's Done/Close enabled during loading; closes by AX press | AX (`enabled`), CAP | 16, 17; Escape on owner sheet O-93 |
| REQ-118 | Settings ▸ General ▸ Permissions; launch | No permission prompt at launch; each permission listed with when it is asked; Ask Now or the denial note present when applicable | AX, CAP; prompts observed by the owner | 01, 19, 20; owner sheet O-118 |
| REQ-119 | First Library load after sign-in | "Setting up your library" with real steps and a live count, then the library; no half-drawn window | CAP, AX (`ode.firstLoad.step.*`), LOG | 01 (cold start only); owner sheet O-119 |

## Running

1. The owner unlocks the screen and opens build 624 from Finder (signed in), then leaves the keyboard and mouse.
2. Close any X Ode sheet and extra window first: preflight refuses unless there is exactly one window and no
   sheet, because a leftover sheet dims every capture. Then run `tools/qa/req134_run.sh ~/xode-qa/req134-$(date +%Y%m%d-%H%M)`. It refuses to start unless exactly one build
   624 process is running and this terminal has Accessibility and Screen Recording access. It waits whenever the
   owner touches the keyboard or pointer.
3. `summary.json` lists the steps that did not complete, content-scan findings and contrast gaps. `manifest.json`
   hashes every evidence file. A step that did not complete (for example a sheet without a Close button) moves
   to the owner sheet; it is not a pass.
4. Evidence contains account and library data: keep it outside this repository.

Pass rules: a REQ is recorded as verified only from its own row's evidence. Content-scan hits and contrast lines
below 4.5:1 that are not Apple's semantic secondary text become fixes. Synthetic AX actions are not proof of
keyboard, trackpad or VoiceOver behaviour; those rows need the owner sheet.
