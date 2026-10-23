# Ode to X — Product Experience Specification

Status: owner-directed draft, 23 October 2026. Requirement ids are the program
ledger ids in `dragos-core/projects/ode-to-x/SPEC.md` (REQ-59 onward); this
document is their detailed design. Acceptance is accepted only with actual
native observations on a source-bound candidate (COR-15: no mock PASS).

## 1. Authority, scope and supersession

Owner direction of 23 October 22:10 (verbatim intent):

1. The Discover search screen is unacceptable and must be redesigned.
2. Show no prices and no Buy actions until the Apple policy evaluation in §4 is
   decided by the owner.
3. Show the `MSIXVC` package label only inside the game detail sheet.
4. Everywhere a game appears, show whether it is part of any Game Pass
   subscription, even when it is owned. Owned and subscription can both be
   true: some players buy a game so they do not depend on a subscription.
5. Use the independent macOS UX audit findings.
6. Extend layouts/lists from the reverse-engineered Xbox PC app (UTM VM), e.g.
   Recently added and Recently purchased.
7. Work clean, refactor, no backward compatibility.

This document supersedes the conflicting parts of earlier documents. Where it
is silent, `UI-CONTINUATION-SPEC.md`, `UX-FLOWS.md`, `DESIGN.md` and
`PRODUCT.md` still apply.

| Earlier rule | Where | Now |
|---|---|---|
| Search result cards show factual price/acquisition/package information | ledger REQ-10, `LiveCatalogView.card()` `showsPrice: true` | Search finds and links; no price, no package, no size on any card (REQ-59, REQ-60) |
| Product detail shows price when not owned/installed | `LiveProductView.swift` `showsPrice: owned == nil && installed == nil` | No price anywhere until REQ-61 is decided |
| External Xbox page / acquisition handoff from search and cards | COR-7, REQ-26, `CatalogAcquisitionAction` | No Buy/Get/Pre-order action anywhere until REQ-61 is decided; Install/Play of entitled games stays |
| Package format and download size on cards, rows, Continue Playing | `LibraryGameSizeView` callers in Library/Discover/Product, audit A12 | Package format only in detail sheet; size only in detail sheet and real install/download progress (REQ-62) |
| Two access models: search/Discover use single-valued `CatalogAccessBadge` (one of Owned / In your library / Subscription / Game Pass); Library uses `LibraryAccess.badges`, which can pair Owned + “Game Pass catalog” but collapses a subscription grant to “Subscription” | `CatalogSearchResults.swift`, `LibraryPresentation.swift` | One model with independent ownership and membership facts, shown together on every surface (REQ-63) |
| “No subscriptions listed… absence is not exclusion” and “Listed subscriptions (partial…)” on cards | `CatalogGamePassListingCopy` | One discreet coverage disclosure per surface; never on a card (REQ-63) |
| “Store and Game Pass” heading, “Sources: …” paragraph, “Source: PC Game Pass catalogue” line on cards | `DiscoverCopy`, `storeHeading`, `card()` | Section names describe content; source detail lives in one disclosure (REQ-59) |
| COR-9 discreet tier badge only | ledger | Retained and extended: membership shown on every game surface, discreetly (REQ-63) |
| COR-1 0.1 is MSIXVC-only | ledger | Unchanged as runtime admission; only its *display* moves to the detail sheet. Unsupported reasons still appear where an action is blocked (REQ-28) |

No compatibility shims: delete the replaced types, copy and parameters rather
than keeping them behind flags.

## 2. Research basis

| Topic | Finding | Confidence |
|---|---|---|
| Apple, Mac App Store US | ASRG 3.1.1(a): entitlements are not required for buttons, external links or other calls to action in US storefront apps (post-*Epic v. Apple* contempt order, Apr 2025). Ninth Circuit (11 Dec 2025, No. 25-2935) affirmed the link/design ruling but allowed a cost-based commission, remanded; no rate set as of 23 Oct 2026. | Guideline text retrieved; litigation via law-firm summaries — time-sensitive |
| Apple, Mac App Store EU | DMA alternative business terms permit external purchase links/processing with Apple's fees. | Prior reporting, not re-fetched |
| Apple, Mac App Store rest of world | 3.1.3 restricts steering; Reader (3.1.3(a)) and free stand-alone (3.1.3(f)) exceptions do not fit a game launcher. | Guideline text |
| Apple, 4.2.7 | Remote/host-client UI must not resemble the App Store or allow browsing/purchasing unlicensed software. A Wine-runtime launcher that browses a catalogue is a review risk in the Mac App Store regardless of prices. | Guideline text; applicability is our inference |
| Developer ID + notarization | App Review guidelines do not apply; notarization is a security check. No Apple restriction on prices or buy links. | Documented scope; inference |
| Game Pass tiers (Oct 2026) | Essential, Premium, Ultimate, plus standalone PC Game Pass. PC library access: Premium, PC Game Pass, Ultimate. Essential: limited/none on PC. | xbox.com compare page; pricing secondary — do not render prices |
| Catalogue lists | `catalog.gamepass.com/sigls/v2?id=<sigl>&language=&market=` returns `{id}` arrays. Community-confirmed sigls: PC `fdd9e2a7-0fee-49f6-ad69-4354098401ff`, console `f6f1f99f-9b49-4ccd-b3bf-4d9767a77f5e`, EA Play `b8900d09-a491-44cc-916e-32b5acae621b`. Our existing feed is sigl v3 `609d944c-d395-4c0a-9ea4-e9f39b52c1ad` (`allgamespc`, subscriptionContext `cfq7ttc0kgq8`) = “every game included with PC Game Pass”. Recently added / Leaving soon / per-tier sigls: **not established**. | Community repos (NikkelM/Game-Pass-API) + our prior capture; unofficial |
| Owned + Game Pass | Xbox shows purchased titles as Owned permanently and, concurrently, “Included with Game Pass” in Store/catalogue. | Reported, not screenshot-verified |
| Xbox PC app IA | Unified Home with shelves: Jump back in, Recently added (to Game Pass), Leaving soon, collections, deals, recommendations. My Library aggregates sources with Installed/Owned/Game Pass filters; play history. VM observation (GamingApp 2610): nav Home, Game Pass, My Library, Cloud Gaming, Store, Most Recent/Play history, Install queue; hero tiles “Play now”/“Pre-order now”; shelf “Recently added to Game Pass” with GAME PASS badge on art + title + publisher. | VM screenshots (session 28810515) + secondary press; search layout and detail action hierarchy **not observed** |
| UX audit (independent macOS audit) | P1 Library first screen (COR-12), P1 scroll S1–S5, P2 count scope, carousel focus A07, selection retention A02, A01 unknown→“In your library”, A11 forced-dark sheet, A12 Continue Playing clutter / package facts → detail, D1 PC Game Pass scope. | Audit document |

Open research (assigned in REQ-67): a follow-up VM pass to capture the Xbox PC
app search results, detail action hierarchy, Recently added / Leaving soon
transport, and play-history/purchase-date sources.

## 3. Game state model

Every surface renders from one value, `GameFacts`, built by the existing
`CatalogProjection`/`LibraryProjection` (`GamePresentationProjection.swift`)
and replacing the access parts of `LibraryGame.eligibility`/`gamePass` and
`CatalogDetailFacts`, with **independent** fields. No field is inferred from another.

| Field | Values | Source | Never inferred from |
|---|---|---|---|
| `ownership` | `.purchased(date?)`, `.inLibraryUnknownAcquisition`, `.notInLibrary`, `.unknown` | Account entitlements (`AccountEntitlements`) | Game Pass membership, price 0, installation |
| `memberships` | set of `SubscriptionMembership { plan, since?, leavingOn? }` where plan ∈ `pcGamePass`, `ultimate`, `premium`, `eaPlay`, `ubisoftPlusClassics`; plus `coverage: .verified/.partial/.unknown` | Catalogue lists by sigl; plan only when the list is plan-specific | Ownership, user's own plan |
| `userPlan` | user's active plan(s) or `.unknown` | Account (when supported) | Catalogue membership |
| `installation` | `.installed(path)`, `.installing(progress)`, `.notInstalled` | Local registry | Ownership |
| `package` | `.msixvc`, `.msix`, `.appx`, `.eappx`, `.unknown`, with `downloadBytes?` | Catalogue/manifest | — |
| `support` | `.supported`, `.unsupported(reason)`, `.unknown` | Classification (REQ-27/28) | Package alone |
| `offer` | `.freeToPlay`, `.none`, `.unknown` (claim-to-keep remains absent, REQ-26) | Verified transport (REQ-25) | Price 0 |
| `isGame` | `.game`, `.app`, `.unresolved` | Public Game+PC classification (REQ-5) | Collection type |

Rules:
- `ownership` and `memberships` are shown together. Example: purchased game
  that is also in PC Game Pass shows **Owned** and **Game Pass**.
- `.inLibraryUnknownAcquisition` is labelled “In your library”, never
  “Owned” (A01/REQ-6).
- If `memberships` is empty and coverage is not `.verified`, show nothing on
  the card; the surface-level disclosure (§5.4) explains partial coverage.
  Absence is never rendered as “Not in Game Pass”.
- Plan names only when the list is plan-specific (COR-9). The `allgamespc`
  list maps to `pcGamePass` membership; we do not claim Ultimate/Premium from
  it even though those plans include PC Game Pass content. Copy: “Game Pass”
  on badges, “Included with PC Game Pass” in the detail sheet.
- `isGame != .game` items do not appear on game surfaces (REQ-5).

## 4. Commerce gate: no prices, no buy

REQ-61 is a decision gate, not an implementation task. Until the owner
records a decision:

- Remove price rendering: `LibraryGameInformation.showsPrice`,
  `facts.commerce.label`, `CatalogCommerce` price formatting, and any
  “with Game Pass” discount copy. No strike-through, no “Free” derived from
  price 0.
- Remove Buy / Get / Pre-order / “View in Microsoft Store to buy” actions and
  `CatalogAcquisitionAction` purchase routes. Keep Install and Play for entitled
  games, and a neutral “Open on Xbox.com” link in the detail sheet's overflow
  menu only (REQ-22 locale rules apply).
- Delete, not hide: the commerce types and copy are removed (no flag).

Decision table for the owner (time-sensitive; re-check before decision):

| Distribution | Prices | External buy link | Notes |
|---|---|---|---|
| Developer ID + notarization (outside Mac App Store) | Allowed | Allowed | No App Review; Microsoft's own terms still govern catalogue/API use |
| Mac App Store, US storefront | Allowed | Allowed (3.1.1(a)) | Possible future cost-based commission on remand; 4.2.7-style “resembles a store” review risk for a Wine launcher |
| Mac App Store, EU | Allowed | Allowed under DMA alternative terms | Fees/terms opt-in |
| Mac App Store, rest of world | Risky | Not allowed (3.1.3 exceptions do not fit) | Would need per-storefront suppression |

Recommendation: decide distribution first. If Developer ID, prices and an
external Xbox link can return later as a separate REQ; do not reintroduce
them under this document.

## 5. Discover search redesign (REQ-59)

### 5.1 Problem (observed 23 Oct, query “subnautica”)
One oversized “Your games” card dominated the screen with Install, price
149,99 RON, a source line, “No subscriptions listed… absence is not
exclusion”, an MSIXVC chip, “~7,19 GB download”, then a “Store and Game Pass”
section with “Some results couldn't be checked”. It reads as a diagnostics
panel, not search.

### 5.2 Layout
```
[Search field: “subnautica”]                          (scope: All games ▾)
In your library (2)
  ▢ Subnautica            Owned · Game Pass        Installed     [Play]
  ▢ Subnautica: Below Zero In your library         Not installed [Install]
Games (14)
  ┌art┐ ┌art┐ ┌art┐ ┌art┐ ┌art┐
  Title Title Title Title Title
  [GP]  [GP]
  [More results]
ⓘ Game Pass membership shown where our catalogue confirms it.   (disclosure)
```
- **In your library**: compact rows (art thumbnail 48 pt, title, state badges,
  install state, one primary action). Max 5, “Show all N in Library” opens the
  Library tab with the query applied. Replaces the full-card `LazyVGrid`.
- **Games**: the same poster grid cell as Library/Discover shelves (one
  `GameCard` component), with the membership badge on art. Library matches are
  excluded from this section (dedupe by product id).
- No price, package, size, source line, “Ownership not verified”, “Not in your
  PC library”, “Offline details”, or listing copy on rows or cells.
- Section headings describe content: “In your library”, “Games”. Delete
  “Store and Game Pass”, “PC Game Pass catalog”, “Explore games” and
  `DiscoverCopy.sourceDescription`.
- Scope menu: All games / Game Pass / Installed. “All games” searches the
  catalogue sources we have (today: PC Game Pass catalogue + store search);
  the disclosure states the real coverage (D1/REQ-24).

### 5.3 States
| State | Rendering |
|---|---|
| Empty query | Recent searches (local, max 8, clearable) and the Discover shelves |
| Typing | Debounced 250 ms; prior results stay dimmed, not removed (REQ-9 fencing) |
| Results | As above |
| No results | “No games match ‘x’.” + “Search Library” / clear |
| Partial (some sources failed) | Results shown; single inline note “Some results may be missing.” with Retry; no per-card warnings |
| Error | “Search isn't available right now.” + Retry; prior library rows still searchable offline |
| Unclassified items | Hidden from results (REQ-5); never a “classification unverified” sentence |

### 5.4 Coverage disclosure
One `ⓘ` line at the bottom of Discover and search, opening a popover:
which catalogues were checked, last refresh time, and that a game without a
Game Pass badge may still be included. This replaces every per-card listing
string.

### 5.5 Acceptance
On the installed candidate: query “subnautica” and “mortis” (REQ-10) with
1440×874 and 1619×1231 windows. Screenshot + AX tree show the layout above, no
price/package/size/source/QA text in AX labels, correct dedupe, scope menu
works, and keyboard: ⌘F focuses search, ↓ moves into results, Return opens
detail, Esc clears. Partial/no-results/error states observed by real network
toggling or a real failing source, not mocks (COR-15).

## 6. Package label placement (REQ-62)

- `MSIXVC` / package format and download size appear only in the detail
  sheet's “Details” facts group (alongside size, publisher, release date).
- Remove `LibraryGameSizeView` and `packageFormat`/`downloadBytes` parameters
  from cards, rows, shelves, Continue Playing and search. Real install/download
  progress (bytes, percent) stays visible on cards while installing.
- Library copy “Ode to X 0.1 installs MSIXVC games…” moves to the
  unsupported-action explanation and Help, not the Library body.
- Where an action is blocked for package reasons, the blocked action shows the
  reason in plain words (“This version can't run games packaged as MSIX yet”),
  and the detail sheet names the format. REQ-28 admission is unchanged.

Acceptance: AX tree of Library, Discover, search, Continue Playing contains no
“MSIXVC/MSIX/Appx/EAppx/GB download” strings for non-installing items; detail
sheet shows them; blocked action still explains.

## 7. Membership badge everywhere (REQ-63)

- Component `AccessBadges(facts)` renders up to two compact capsules:
  ownership (`Owned` | `In your library`) and membership (`Game Pass`,
  `EA Play`, …). Both may render together. Order: ownership first.
- Placement: on art, bottom-leading, in poster cells; inline after the title
  in rows; in the detail sheet header with full names (“Owned”, “Included with
  PC Game Pass”, “Leaving Game Pass on 31 Oct” when `leavingOn` is known).
- Surfaces: Library grid, Library lanes, Continue Playing, Discover shelves,
  search rows and cells, detail sheet, See All collections.
- Material: one solid capsule style (not glass, per S3), meets 4.5:1 contrast
  over artwork via its own background (REQ-19).
- Filters: Library filters Owned and Game Pass are independent; a game owned
  and in Game Pass appears in both (REQ-2/3 filter row unchanged visually).
- A current subscription grant in the user's library (`eligibility == .gamePass`)
  is an *access* fact, shown as “Game Pass” plus “In your library”; it is never
  “Owned”.
- Delete `CatalogAccessBadge`, `LibraryAccess`, `LibraryAccessBadge`,
  `CatalogGamePassListingCopy` and `LibraryAccess.summary` strings such as
  “Access not verified”; replace with `AccessBadges(facts)`.

Acceptance: a real owned title that is in the PC Game Pass list (identify from
actual account + `allgamespc` data) shows both badges on every listed surface;
an unknown-acquisition title shows “In your library”, never “Owned”; a title
outside the list shows no membership badge and no negative text.

## 8. Library and audit findings

| REQ | Finding | Requirement |
|---|---|---|
| REQ-64 | A12 Continue Playing clutter | Continue Playing cells: art, title, last played, primary action, badges. Package/size/source/support detail only in the detail sheet. |
| REQ-64 | P2 count scope | Counts in filter/section headings count exactly the visible scope (games only, current filter/query); no total that includes apps or unresolved items. |
| REQ-64 | A11 forced-dark sheet | Covered by REQ-11; this spec adds no new rule. |
| REQ-64 | A07 carousel focus | Covered by REQ-15. |
| REQ-64 | A02 retention | Covered by REQ-8. |
| — | P1 first screen (COR-12) | Covered by REQ-4: layout preserved; first useful row visible at 1440×874. |
| — | S1–S5 performance | Covered by REQ-13/REQ-17: measure before changing. The badge component must not add per-cell glass, blur or GeometryReader. |

## 9. Xbox-parity shelves and lists (REQ-65, REQ-66)

Shelves render only when a verified source populates them; an unpopulated
shelf is absent, never empty or placeholder. Each has its own clock; clocks
are never merged.

| Shelf | Surface | Source | Clock | Status |
|---|---|---|---|---|
| Jump back in / Continue Playing | Library top | Local play history (Ode launch records) | last played | exists; restyle per REQ-64 |
| Recently added to Game Pass | Discover | Game Pass “recently added” list (sigl unknown) or our first-seen diff of `allgamespc` | `addedToGamePass` (list) or `firstSeenByOde` (diff, labelled “New in our catalogue”) | REQ-65 |
| Leaving soon | Discover | Game Pass leaving list (sigl unknown) | `leavingOn` | REQ-65, blocked on source |
| Recently purchased | Library | Account entitlement acquisition dates | `purchasedOn` | REQ-66, blocked on source evidence (REQ-7) |
| Recently installed | Library | Local registry install dates | `installedOn` | REQ-66 |
| Free to play | Discover | Verified F2P transport | — | REQ-25 (unchanged) |
| New releases | Discover | Catalogue release date | `releaseDate` | REQ-65 |
| Claim to keep | — | — | — | absent (REQ-26 blocked) |

Rules:
- A partial refresh never removes items (no false “left Game Pass”).
- First-seen diffs require two complete refreshes; the first run shows nothing.
- See All for a shelf opens a collection with the same badges and scope rules.

Acceptance REQ-65: with a verified source, the shelf shows real items with
correct clock ordering; without one, the shelf is absent; a simulated-partial
refresh is not acceptance — demonstrate with a real interrupted refresh.
Acceptance REQ-66: Recently installed ordered by real install dates; Recently
purchased appears only once REQ-7 proves acquisition dates, otherwise absent.

## 10. Research follow-up (REQ-67)

Owner-coordinated UTM VM pass on the Xbox PC app (no purchases, no account
changes): capture search results layout, detail action hierarchy, Recently
added / Leaving soon shelves and the network requests that populate them (sigl
ids), and My Library Owned/Game Pass filter behavior with an owned+Game Pass
title. Output: screenshots + request list appended to §2 with dates. No
scraping of undocumented private APIs beyond what the existing catalogue
client already uses without owner approval.

## 11. Refactor and implementation order

1. **Projection (REQ-63 base).** Introduce `GameFacts` with independent
   ownership/membership; migrate all surfaces; delete `CatalogAccessBadge`,
   single-badge logic and listing copy.
2. **Commerce removal (REQ-61 gate).** Delete price/Buy rendering and types.
3. **Package placement (REQ-62).** Remove size/package from non-detail
   surfaces; move copy.
4. **Shared `GameCard` + `AccessBadges`.** One cell for shelves, grid, search,
   See All.
5. **Search (REQ-59/60).** Library rows + Games grid + scope + states +
   disclosure; delete `DiscoverCopy.sourceDescription`, store headings.
6. **Library cleanups (REQ-64).**
7. **Shelves (REQ-65/66)** after REQ-67 establishes sources.

Each step: unit tests on `GameFacts` derivation (no inference rules), then a
native observation on the installed candidate. No CI (COR-6); local build and
tests with exact commands and exits. Preserve registry/preferences/rollback.

## 12. Requirements

| ID | Requirement | Acceptance | Depends |
|---|---|---|---|
| REQ-59 | Redesign Discover search (§5). | §5.5 on installed candidate. | REQ-63 |
| REQ-60 | Search and every card show no price, package, size, source or QA text. | AX/screenshot sweep of search, Discover, Library, Continue Playing, See All. | REQ-61, REQ-62 |
| REQ-61 | Commerce gate: remove prices and Buy until owner decides distribution/Apple policy (§4). | Owner decision recorded; until then no price/Buy string or action in AX tree of any surface. | owner |
| REQ-62 | Package format and size only in detail sheet (§6). | §6 acceptance. | — |
| REQ-63 | Independent ownership and membership badges everywhere (§3, §7). | §7 acceptance with real owned+Game Pass title. | REQ-6 |
| REQ-64 | Library cleanups: Continue Playing content, count scope (§8). | Native screenshots/AX; counts match visible scope. | REQ-5 |
| REQ-65 | Discover shelves from verified sources with separate clocks (§9). | REQ-65 acceptance. | REQ-67 |
| REQ-66 | Library shelves Recently installed / Recently purchased (§9). | REQ-66 acceptance. | REQ-7 |
| REQ-67 | Xbox PC app follow-up research (§10). | Dated screenshots + request list; sources named or recorded as unavailable. | owner VM time |
