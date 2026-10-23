# Research evidence and open decisions

Recorded 2026-10-03. This foundation consumes **supplied prior research**, not fresh network observation or runtime revalidation. Public links below are evidence pointers; no Xbox desktop traffic capture, TLS/proxy interception, credentials or purchases were performed.

## Evidence ledger

| Finding | Classification | Consequence / limitation |
| --- | --- | --- |
| Apple Games Home: centered Home/Arcade/Friends/Library/Search, profile trailing, restrained chrome, editorial hero, compact Continue Playing and shelves | Supplied private visual observation | Visual authority only; no assets or screenshots copied. Xodus uses Library/Discover/Downloads and original art. |
| Apple Games Library: summary then Your Games/count/sort-filter, compact three-column horizontal entries with square icons, title/played-added metadata, compatibility warning and Play/View pill | Supplied new direct private window observation | Stronger Library-specific authority: adopt compact rows in Library; reserve editorial hero/shelves for Discover. No content/capture published. |
| Apple Games Search: centered navigation persists, broad centered search field, restrained genre/category browse at empty query | Supplied new direct private window observation | Scoped Library/Discover field; useful empty-query category browse distinct from results/no-match/offline/loading. No source assets copied. |
| User explicitly rejected v0.1 flat mockups and requested modern rounded floating transparent menu, immersive images and closer Apple Games composition | User-directed correction | v0.2 uses actual macOS 26+ Glass, full-bleed feature/detail art, separate circular profile, compact Library entries alongside featured/Continue Playing. Earlier imports are superseded, not approvals. |
| Apple published Landmarks sample demonstrates Mac Liquid Glass and edge-to-edge imagery; SwiftUI/AppKit Glass APIs available on macOS 26+ | Supplied official-documentation review; actual SDK27 app build verification | No UIKit rewrite necessary. No Apple Games source/asset copied. Static SVG/native NSView exports cannot prove compositor refraction. |
| Xodus CLI provides auth, package download/extract/stream, Unix run and product-ID metadata lookup | Supplied prior private source review | Useful foundation, not proof of complete search, owned enumeration, stable machine protocol or safe install lifecycle. No private source included. |
| Backend Keychain abstraction exists in `crates/xodus/src/tokens/backend/keychain.rs`; `secrets.rs` selects `apple_native_keyring_store::keychain` normally on macOS; optional `key-chain-file` persists `.xodus-keyring.ron` | Parent's supplied direct current source verification | Reuse one existing credential owner; forbid file-backed feature in shipping app. No private implementation copied. |
| `displaycatalog.rs` offers only `find_products_by_id`, GET `displaycatalog.mp.microsoft.com/v7.0/products/{product}?market=...&languages=...`, propagating HTTP errors | Parent's supplied direct current source verification | This function establishes ID lookup, not full-text search. The separate Store Edge search evidence is recorded below. |
| `start_new_session` uses Xbox Live flow/scopes and `get_xsts_token` accepts a relying party | Parent's supplied direct current source verification | Existing machinery does not prove inventory authorization; record audience separately per capability. |
| Interactive package prompts; inner streaming failure may yield outer success; login may report success without tokens | Supplied prior source review | Adapter requires structured results/credential proof/terminal registry evidence; never trust exit alone. |
| Streaming reuses hashed files and redownloads changed files | Supplied prior source review | Not a block-delta patch guarantee. Durable version/recovery/removal safety unestablished. |
| Exactly paired Xbox-capable Wine runtime required | Supplied technical constraint | Stock Heroic Wine/CrossOver cannot be substituted; pairing and redistribution remain gates. |
| Several private gameplay successes historically reported | Historical private reports, not revalidated | No public verified-game list or compatibility claim derived from them. |
| Heroic new-store plugin proposal remains a proposal | [Public issue #3158](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/issues/3158), supplied review | No proven shipping plugin API; standalone app selected. Do not interpret this as a freshly checked issue status. |
| Public Game Pass candidate discovery uses catalog/display catalog endpoints | [NikkelM/Game-Pass-API](https://github.com/NikkelM/Game-Pass-API), [scraper source](https://github.com/azxie/gamepass-scraper/blob/master/find_game_ids.py), prior source-derived leads | `catalog.gamepass.com/sigls/v2` and `displaycatalog.mp.microsoft.com/v7.0/products` are catalog leads, not observed desktop API traces or ownership. Region/platform/paging/freshness need proof. |
| Official current Xbox games-page script maps All PC Games to Sigls v3 category `609d944c-d395-4c0a-9ea4-e9f39b52c1ad`, PC platform and subscription context `cfq7ttc0kgq8` | Backend-supplied public script/HTTP verification; actual pinned native-engine two-page and checked-title-search probe | Anonymous feed contains a header plus candidate product IDs. Bounded metadata lookup establishes partial public discovery, not purchased/subscription entitlement or global Store search. Source-neutral `en` vs requested `en-US` is exposed, not hidden. |
| Anonymous Microsoft Store Edge v9 search returns source cards and server continuation; observed first/next pages contain 40 distinct IDs for a public Halo query | Coordinator-supplied direct public HTTP verification, followed by actual pinned management-engine two-page native-client probe | Public game search, not desktop API capture or ownership. Cards are checked against DisplayCatalog Windows.Desktop evidence; localized labels or mediaType alone do not prove PC eligibility. Same-title product IDs remain separate; CardActions are never executed. Positive pages do not establish exhaustive coverage or R06/R07 edge-case closure. |
| Legacy playing-account XAL flow alone is insufficient; isolated Store profile uses existing NativeTokenBroker/Passport provider machinery and native Keychain worker | Backend-supplied public implementation pin plus actual noninteractive native status/read-only probe | Launcher uses Xodus Management Service separately from CLI Xodus Service; no implicit credential/cookie import. Backend memory-facade tests retain device credentials on logout and leave user intact if retention fails. No actual logout, human consent or package/inventory audience proof is inferred. |
| Original synthetic XVD marker at public producer e3129 and native client runner yields fixed 196-byte non-key metadata observation | Source-backed header layout plus actual unsigned/signed process probes in isolated test roots | SHA256 covers ordered offsets 0x200..0x29c and 0x39c..0x3c4 only, not whole-file integrity. Container/header identifiers are not retail IDs. No external game, adoption, ownership or launch proof. |
| Microsoft Inventory Service + XSTS might support consumer inventory | [Historical Xbox Live API issue comment](https://github.com/microsoft/xbox-live-api/issues/575#issuecomment-1105826347) | Historical lead only: audience, pagination, current availability, PC purchases and subscriptions unproven. |
| Publisher Collections APIs query entitlements | [Microsoft GDK documentation](https://learn.microsoft.com/en-us/gaming/gdk/docs/store/commerce/service-to-service/xstore-query-user-entitlements) | Partner-oriented, not turnkey consumer library. Their scope does not prove a consumer route impossible. |
| Xbox desktop accessibility initially exposed Home/Game Pass/My Library/Store/Search and Library MyGames/PlayLater/PlayHistory/InstallQueue | Supplied initial accessibility observation | Initial navigation/network observation did not succeed; no API or inventory semantics were inferred. |
| Subsequent bounded Windows Xbox navigation verified My Library selected with an Installed filter/badge, and Store selected with Top Paid, Xbox Play Anywhere/New Games shelves, Show All and separate Owned/Installed badges | Coordinator-supplied direct current UI Automation observation, 2026-10-03 | Installed, owned and catalog evidence are separate UI concepts. ApplicationFrameHost owned the activated installed Xbox AUMID; selection alone did not navigate, exact owned-window/foreground/rectangle-checked UIA points did. No account/game content was captured. Search was left untouched because the field contained an unrelated value; no synthetic query, network request or API mapping is claimed. |
| Installed Xbox 2609.1001.16.0 static Hermes literals include `https://orderhistory.gameservices.xboxlive.com/api/purchases/days/`, Collections/catalog hosts and relative `/search/games`, `/search/gamepassgames`, `/search/multichannel` | Coordinator-supplied read-only static-literal evidence; verified Hermes 96 footer and bundle SHA256 `038a60a67cec41055fc2e6d75525eb87a4828f7ee05150f869b0e8905475a8ca` | Purchase history is only a candidate lead, not current ownership/refunds/full PC proof. Relative search routes are unbound to a host/call shape. No proprietary code/bytecode, user data, network trace or working authorization is copied or claimed. |
| PC Microsoft Store purchasing identity can differ from Xbox playing identity; delegated signed-X-token licensing audience and partner Collections mapping have distinct constraints | Coordinator-supplied current official GDK authentication review, not an implemented consumer inventory route | One saved XAL playing session does not prove Store-owned PC games. Model launcher profile, purchasing source, audience and entitlement evidence independently; preserve both accounts rather than silently importing or replacing CLI credentials. |
| Ownership title history is not inventory | Product/research conclusion | Misses never-played purchases and includes expired subscription play; can enrich but cannot authorize. |
| macOS design and modern glass guidance | [macOS HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) | Use native controls and availability-aware system behavior, not web glass styling. |

## Decision register

Retail-search evidence endpoint:
`https://storeedgefd.dsx.mp.microsoft.com/v9.0/pages/searchResults?market=US&locale=en-US&deviceFamily=windows.desktop&query=Halo&mediaType=games`.
Public source-derived prior art:
[MS-Store-API v9 pages documentation](https://github.com/ThomasPe/MS-Store-API/blob/master/endpoints/v9.0/pages.md).
Observed first response is a two-item array; the next page is an object under
`Payload`. No cookies, auth or appVersion were required. Continuation is confined
to the exact Store Edge host/path and bound market/language/query; opaque native
q1 cursors preserve leftover source positions when native pages are smaller.
Source cards can include console-only products; those are explicit failures, not
PC results or an empty-success substitute. This is anonymous public discovery,
not entitlement, observed Xbox-desktop traffic or a full Store corpus guarantee.

Zero-source query semantics are verified separately through deterministic
producer serve tests and native mock-child regression, not an assumed live
provider response. A single coordinator-supplied nonsense-query observation
returned 19 cards with continuation; suggestions/fuzzy behavior means arbitrary
nonsense is not reliable proof of an empty upstream source. No guessed-term
loop or filtering-away-cards is used.

Original synthetic marker layout reference:
[public producer smoke helper at e3129](https://github.com/dragoshont/xodus-macos/blob/e3129cee422305657b945d35daf2f780ffe98e2b/tools/smoke_management.py).
The client creates only its own sanitized 4096-byte test header and checks
unchanged bytes; it does not copy a real container or invoke a legacy parser.

| ID | Status | Decision / question | Evidence needed to close |
| --- | --- | --- | --- |
| D-01 | Confirmed direction | Public standalone SwiftUI/AppKit app; private runtime remains separate | User brief |
| D-02 | Proposed | Library default; macOS 14 deployment baseline | User acceptance, hardware/OS coverage and native API availability tests |
| D-03 | App license confirmed; redistribution pending, release blocker | User chose GPL v3; app SPDX is GPL-3.0-only. Runtime/components keep their own licenses | Verbatim GPL v3 in LICENSE; separate dependency/runtime legal review needed before packaging |
| D-04 | Pending, release blocker | Consumer auth and authoritative owned-PC inventory | Approved audience/consent, all pages, never-played purchase, expired subscription, console-only, regional variants |
| D-05 | Pending, release blocker | Package eligibility/edition mapping | Authorized sample mapping, architecture/language/market validation; no purchase required for this foundation |
| D-06 | Pending, release blocker | Management protocol and durable lifecycle | Backend contract review + crash/cancel/disk/integrity/rollback fault tests |
| D-07 | Pending, release blocker | Signed runtime manifests/pairing | Reproducible build, signer trust, hash verification, capability/version pairing and rollback |
| D-08 | Pending | Distribution/update model | `.app` bundling, signing/notarization, installer/updater selection and component licenses |
| D-09 | Pending | Offline entitlement and revoked-access policy | Authorized source expiry semantics, backend signed policy and user-facing rules |
| D-10 | Pending | Compatibility verification governance | Consentful testing, reproducible OS/hardware/runtime fingerprint and revalidation cadence |
| D-11 | Pending | Storage retention / save-format rollback | Exact staging and rollback overhead, reclaim policy; title-specific save compatibility |
| D-12 | Pending, production asset gate | Title-specific catalog image rights/cache policy | Licensed source/attribution/cache review; current authored illustrations are fixture placeholders only |

## Research gates, without blocking design

Specifications and fixture UI can proceed now. Live inventory/auth must not ship until D-04 closes; avoid presenting catalog-only, title-history or partner-only results as a solved library. A failed research route narrows the evidence, not the universe of possible consumer APIs. Use documented, authorized investigations; no TLS interception, credentials or private captures belong in this public repository.
