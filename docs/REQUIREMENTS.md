# Requirements and acceptance criteria

Status: **proposed v1 requirements**, not implemented functionality. "Must" below is a release gate. The current preview demonstrates only the subset listed in [verification](VERIFICATION.md).

## Core journey

| ID | Requirement | Measurable acceptance |
| --- | --- | --- |
| AUTH-01 | Connect using approved browser/device authorization and Keychain storage | A cancelled or expired flow returns to signed-out state without tokens or an installable library; test both before/after browser return. Successful connection requires nonempty validated credentials and correct audience, not exit 0. |
| AUTH-02 | Explicit disconnect and refresh ownership | Disconnect clears account credentials, closes account-scoped jobs safely and labels cached data unavailable; account B never inherits account A's entitlement. Refresh failure cannot silently extend a subscription. |
| LIB-01 | Genuine PC entitlements | A controlled fixture corpus covers never-played purchases, expired subscriptions, console-only products and unknown access. No history-only or catalog-only record appears as purchased. Enumerate every page; incomplete paging shows "Partial library" with source/time. |
| LIB-02 | Distinguish purchase, subscription, none and unknown | Every row/detail has a textual access label. Unknown and none cannot install; expired subscription cannot install. Stale access requires refresh before a new install. Cache failure is not an empty library. |
| LIB-03 | Stale and partial inventory | Show age/source, last complete refresh and incomplete reason. Never replace a complete cached snapshot with a partial result without retaining explicit completeness metadata. An offline cached snapshot remains navigable but cannot authorize a new install. |
| FIND-01 | Library and Discover scoped search | Search field names the active scope. Identical queries can yield different results; changing tabs clears the query and never silently broadens to all catalog. Empty query, no match, network failure and loading have distinct copy. |
| ID-01 | Preserve product/edition/package identities | Two editions of a title remain selectable and distinct. Console package, unsupported architecture, language and market variants cannot be guessed. Package ID/version is pinned in an approved download plan; display title is never a registry key. |
| DETAIL-01 | Four independent facets | Access, downloadability, compatibility and local installation are always visible. Test purchased-but-unavailable, subscribable-but-unsupported, unknown compatibility, expired subscription and installed-with-revoked-access combinations. |
| COMPAT-01 | Evidence-scoped compatibility | Verified/experimental/unsupported/unknown include provenance, check time, OS, architecture and exact runtime fingerprint. OS/runtime mismatch invalidates "Verified"; historical reports are not verified. Experimental install requires an explicit warning acknowledgment per plan. |
| PLAN-01 | Review before downloading | Plan identifies edition/package/version, language, destination, download bytes, expanded bytes, staging/rollback overhead, required free bytes and paired runtime. Deny insufficient space; recheck immediately before reserving, and handle space lost mid-job. |
| QUEUE-01 | Durable, cancellable queue | Request IDs deduplicate repeated submission. App close/backend crash/power interruption at each download/verify/extract/register step restores the same job or an explicit recoverable error after restart. Zero completed installs are registered before integrity and atomic commit. |
| QUEUE-02 | Cancellation and recovery | Cancel is acknowledged once; staged files are removed within the allowed staging root, not saves or a runnable version. Late progress cannot resurrect a cancelled job. Disk/network/hash errors show a code and safe retry/re-plan action. Pause is offered only if negotiated. |
| PLAY-01 | Launch known installation | Launch checks registry, entitlement policy, evidence and exact runtime pairing. Missing runtime/files, offline policy denial and child-process failure are explicit errors. A launcher process spawn is not evidence of successful gameplay. |
| UPDATE-01 | Failure-safe version changes | Power loss or verification failure cannot remove the prior runnable version. Atomic registry promotion follows full verification. Rollback uses old package/runtime pair; saves live outside version directories. Test update failure and rollback after save modification. |
| REMOVE-01 | Safe removal | Preview installed content and saves separately. Default removal preserves saves; any separate save-deletion action requires explicit consent. Registry paths are validated, symlinks cannot escape managed roots, and unrelated user files survive tests. |
| SETTINGS-01 | Simple settings; advanced diagnostics | Account, storage and update policy are normal settings. Advanced exports redact tokens, signed URLs, account IDs and filesystem personal identifiers; exported content is previewed before sharing. Runtime options are the four user-directed presets in RUNTIME-01, not an unrestricted DLL selector. |
| RUNTIME-01 / RT-01..04 | CrossOver-first dependency and explicit experimental alternatives | Read-only approved publisher/bundle verification defaults only a new/unset profile to official CrossOver. Missing/unverified installation blocks gameplay setup, not catalog/account actions. Preserve explicit profiles; label GPTK/Wine/custom graphics Experimental and require acknowledgement that resets on changes. Identity is not licensing, device preflight or gameplay. No CrossOver redistribution or provider execution. Named neutral checks and trust source: [verification](VERIFICATION.md), [runtime policy](RUNTIME-PROVIDERS.md). |
| RUNTIME-02 | Independent components and isolated generations | Engine provenance/version/artifact identity and graphics backend/provenance/version/artifact identity are represented independently. A Wine 11 + D3DMetal 4 configuration is accepted as configuration, not verified gameplay. Changes to either component invalidate applicable evidence and require a new isolated prefix generation; no old bottle/save reuse, migration or deletion occurs silently. Versioned configuration negotiation must not silently rewrite management C95. |
| PARITY-01 | Independent account entitlement and Game Pass membership | A title may show both Owned and In Game Pass. Both filters include overlapping titles. Owned means held by the PC-library account; when acquisition kind is absent the app records Unknown and never claims a paid purchase. |
| PARITY-02 | Xbox game-service profile and achievements | Account-bound caches must match the current service account hash. Profile hides absent bio/location. Achievements use exact decimal title IDs, preserve earned/progress/G fields, and never present an incomplete page as complete. Recent play history never becomes ownership. |
| PARITY-03 | Consoles and remote-play handoff | Show only cached consoles actually returned by Xbox. Console IDs are never placed in URLs. Remote Play opens `https://www.xbox.com/remoteplay` in the default browser; Xodus provides no wake, power, install-to-console or native streaming command. |
| PARITY-04 | Dedicated Engines destination | Account, Settings and keyboard commands open one Engines page that reuses the governed runtime configuration UI. CrossOver observation, declared GPTK/Wine and graphics identities remain independent, and unsupported download/removal/runner actions stay absent. |

## SDD-LIB source acceptance

Frozen scope: R01/R03/R04/R05/R06 personal-library correctness, not the complete
43-row parity/release program. These are source/synthetic-check outcomes, **not
installed-product acceptance**. No GUI, sign-in, deployment or package issuance
is authorized by these statuses.

| Criterion | Source status and acceptance boundary |
| --- | --- |
| SDD-LIB-01 | Implemented: complete current account-held PC entries join installed or not; acquisition remains Unknown, never Purchased. |
| SDD-LIB-02 | Partial/contract blocked for personal admission: held access and public PC catalog membership remain distinct. Discover/detail retain protected Check Game Pass access review for PC members with active status, using existing package preflight and explicit confirmation. This review is not an access grant. The first candidate removed that route; the frontend follow-up restores it and tests the shared policy used by both live views. |
| SDD-LIB-03 | Implemented under available evidence: public/local-only, console candidates, inactive/trial/expired collection rows and confirmed revoked/mismatched-account access are excluded. |
| SDD-LIB-04 | Implemented: unverified installed/imported records appear separately with a warning, never in Your Games counts or eligible hero/recent. Registry, game and save bytes are untouched. Existing protected Play/management routes remain reachable. |
| SDD-LIB-05 | Implemented: personal join drives counts/search/filter/sort and installed hero/Continue Playing; Store discovery remains separate. |
| SDD-LIB-06 | Implemented bounds; broader access contract pending: failed collection paging retains last-complete visibly stale representation, not install authorization. Account changes/revocation retire access. PC public feed loading/partial/failure is explicit; omissions do not revoke retained metadata. Cache is bounded to 512 public identities and existing market/language/disconnect boundaries. No subscription expiry completeness is claimed. |
| SDD-LIB-07 | Implemented source distinction: code 11 is package authorization/account-or-edition resolution, not unowned or Mac-unsupported. The package-check controller preserves prior compatibility/collection facts; code 12 remains separate. |
| SDD-LIB-08 | Unresolved: exact Launcher `9PGW18NPBZV5` and playable Windows `9NBLGGH2JHXJ` are distinct public identities; metadata is not access proof. Older `BZ8MZF8444Z5` has no observed PC SKU. No title-name substitution, new OAuth or broad licence experiments. Root owns further exact identity/access tracing. |

Focused neutral command: `swift run XodusPreview --library-access-check`.
It reaches the live `LibraryGame.collection`, local-record and presentation
selection seam plus `PCGamesController` with synthetic transport. Full native
checks additionally exercise public discovery failures and real controller
package-check failure paths using synthetic scripts.

**Observed neutral SDK 27 validation (9 October):** regression-first focused
test reproduced seven failures before the fix. Final source passed 104 focused
Library access checks, 15 core checks, 2,978 management checks, 172 preview
checks, 934 native-session checks, 152 native-host checks and 19 credential-wire
checks. Debug build and the shipping-configuration Release `XodusPreview`
compile passed without signing or packaging. The existing full `tools/check.sh`
gate stopped at the shipping test target because this Mac's Command Line Tools
SDK cannot resolve `XCTest`; that gate is **not PASS** and requires the existing
full-Xcode CI runner. No replacement test framework was introduced. These
synthetic/offscreen results are not a native installed walkthrough, genuine
Game-Pass-only authorization, Minecraft edition resolution or deployment.

**Exact missing backend evidence, not an invented schema:** an access response
must bind the account to the PC collection beneficiary/game-service identity
and retain exact product, selected SKU/package identity, access kind, observed
active/unresolved/revoked state, check time and source. Any declared expiry or
completeness needs authoritative evidence; absent fields stay unknown. The
existing global scoped licence probe cannot authorize every public catalog
tile or resolve Minecraft playable-edition access. No per-tile automatic
licence checks or guessed dates are introduced.

**Frontend-only review correction:** the shared `canReviewInstall` policy is
called by live Discover and product-detail controls and checked by the focused
suite. Isolated SDK 27 validation passed 105 Library-access checks, 174 preview
checks, Debug product build and shipping-configuration Release product compile.
These results supersede the stale disconnected Game Pass Install assertion;
they establish a protected review affordance, not Game-Pass-only personal
Library admission. No signing, deployment, real package check or GUI operation
was performed.

## Quality and inclusion gates

| ID | Requirement | Measurable acceptance |
| --- | --- | --- |
| A11Y-01 | Keyboard | Every action reachable using Tab/Shift-Tab with Full Keyboard Access; Command-1/2/3 navigate, Command-F focuses Search, Escape cancels a sheet without submitting, Command-comma opens Settings. Focus returns to initiating control. |
| A11Y-02 | VoiceOver | Game buttons read title + access + compatibility, four facets read in order, job changes are announced without repeating every percentage. Test onboarding, empty, detail, install confirmation, cancel and error recovery manually. |
| A11Y-03 | Contrast and preferences | Text reaches 4.5:1 (large 3:1), status is text + symbol, reduced transparency removes chrome dependence, reduced motion removes nonessential animation. All journeys usable in both appearances and increased contrast. |
| LAYOUT-01 | Resizing and text | At 820 x 600 through 1600 x 1000 points, no primary action clips, content scrolls and columns adapt. Test 30% text expansion, right-to-left reading and largest supported accessibility text settings. |
| I18N-01 | Localization | All production UI strings extracted to String Catalogs; byte/date/time formatting uses locale. Pseudolocalization and one RTL language have zero clipped controls; no title-based identifiers. English-only preview is labelled as such. |
| OFFLINE-01 | Useful but honest offline | Cached metadata and installed list load without network; unknown/stale access stays visible. No new install without approved fresh authorization. Launch offline only if the backend's signed policy permits it; never assume all owned games work offline. |
| PERF-01 | Responsiveness | Proposed target: cached 500-title library visible in <=2 s on minimum supported Mac; local search p95 <=100 ms; no main-thread operation >100 ms. Measure release builds with named fixture/hardware before adopting targets as guarantees. |
| PRIV-01 | Public/private separation | Automated source and diagnostic review finds zero real accounts, tokens, signed download URLs, private covers or private source. No TLS interception/proxy/purchase or credentials required for this foundation. |
| RELEASE-01 | Trust and distribution | Chosen licenses permit redistribution; signed/notarized app and signed, hash-verified version-paired runtime pass fresh-install, tamper, offline and rollback tests. No consumer release while ownership/API authorization remains unproven. |

## Prototype-specific acceptance

P-01: Visible "Fixture preview" notice in every main screen and sheets; no action is named simply "Install" or "Play" when it only simulates. P-02: No network clients, credentials, subprocess runtime adapter or package IO in the preview. P-03: `swift build`, `swift run XodusFixtureChecks`, and `swift run XodusPreview --self-check` pass on the isolated Mac tooling directory (no XCTest/Testing dependency; those frameworks are absent from the tested CLT). P-04: original Library, Discover/Search, detail/install, Downloads, onboarding, blocked and error SVGs are editable and reproducible. P-05: one public durable branch and one draft PR, no merge.
