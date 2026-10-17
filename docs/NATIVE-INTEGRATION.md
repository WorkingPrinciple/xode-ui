# Native management integration

This is implementation work beyond the immutable foundation at `44d7338`. It is **not a consumer-ready game launcher**.

## Library source freeze and functional follow-up

The user approved C3's native regular-glass Library direction. Source
`a080225966a9519acad54540a19ee90041e297c2` is pushed and passed
[exact-source CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37811471091).
Its separate signed reviewer is not installed and never refreshes Xbox stats.
The shipping app remains independently admitted at `2d420d1`.

Follow-up source `6485592cc99294ca206c0c07a2e3f7efbe10c815` is pushed and passed
[exact-source CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37816907637),
110 presentation/888 synthetic native checks and shipping compilation. It is
still pending live frontend acceptance and shipping admission. It extends the fixed private
script protocol with `private-xodus-manage.py game-stats <generatedRunId>`:
no extra arguments, a 120-second deadline, the usual private status/result
receipts and exact process-exit/status agreement. The result's `accountHash`
(64 lowercase hex), `games` and `friends` must match the fresh 0600 cache.
Service status supplies the same opaque, domain-separated account hash, never
the XUID or a token. Legacy status remains parsable but cannot authorize
identity-unbound stats. The private backend owns cache/binding clearing on
account change, new game sign-in and signed-out status.

Ordinary launch/foreground and Library Refresh first confirm game-service
status; they do not initiate sign-in. A matching recent cache avoids the stats
command. A locked, atomic 0600 refresh ledger in Xodus Application Support
stores only the account hash and attempt date, fencing repeated/failed requests
inside 15 minutes even after restart. Concurrent clicks coalesce. Account
retirement hides stats and joins its cancelled child; normal Quit fences new
jobs and joins cancellation. Xbox hours remain explicitly Xbox-wide, separate
from the Mac installed registry's last-played time.

Public media persistence is separate from personal metadata: atomic binary
entries under `~/Library/Caches/Xodus/CatalogMedia` use SHA-256 URL names, body
digests, expiry, ETag/Last-Modified and a 512 MiB LRU ceiling. Restart reuse and
304 revalidation retain image/MIME/redirect/byte/pixel guards. No cookies,
credentials or trailers are stored; public product metadata remains a separate
bounded request. Cache clearing fences in-flight old-generation writes. Read-only
review/export modes disable disk persistence. Neither these checks nor Root's
backend verification establish live acceptance of an installed follow-up app.

## Discover D2 source and read-only review

D2 extends the approved C3 native regular-glass chrome into Discover and keeps
the existing public discovery/query contract, exact owned-first matching and
protected Install/registered Play routes. Actual loaded DisplayCatalog genres
drive the browse tiles and local page filter; search, partial errors, cancellation
and paging retain their original backend ownership. Public metadata resets on
market/language change.

The existing fenced reviewer additionally accepts:

```text
--library-preview <private-output-directory> --discover-browse <private-catalog.json>
--library-preview <private-output-directory> --discover-search <private-catalog.json> <query>
```

The private input is `{products:[<unchanged CatalogProduct records>]}`. Reads
require a current-user regular 0600 file without symlink ancestors, at most
512 KiB, at most 64 unique valid product IDs and matching public PC
market/language/artwork/unknown-access scope. Non-PC candidates are not
presented as PC games. The raw input digest/count and filtered rendered count
are recorded separately in private readiness evidence.

Consumer headings are Explore games and More games; About these games carries
plain access/coverage copy. A valid empty search names the query and offers
another title or Clear Search, never connection recovery. Source/corpus terms
are private evidence, not product labels.

These are checked-catalog snapshots and local search, not fabricated
`CatalogDiscovery`/`CatalogQuery` responses. No feed membership, new checkedAt,
revision or cursor is invented. The frozen broker PC-library read and bounded
public art remain permitted; refreshed credentials stay in memory. Ordinary
startup and interaction stay disabled. No engine, service, stats command, private
mutation or production media-cache write is enabled. D2 has 130 detached
presentation/888 synthetic native checks and a shipping compile; native
compositor proof is separate from synthetic checks. Root captured Dark/Light
browse, populated search and empty states and confirmed every job finished
normally. The user approved the direction with the consumer-copy batch above
required before freeze. That correction is now frozen at
`d2be5943943363afe9cfc4708719ef6bf057c56f`, with
[exact-source CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37822024468)
green. The earlier signed/captured D2 bundle remains unchanged; it does not
contain the final copy correction. Final shipping admission remains pending.

## D3 public game-detail source candidate

D3 extends the native detail sheet without changing entitlement, package
selection, compatibility or installation ownership. Optional DisplayCatalog
detail data decodes separately from the base identity/artwork model, so rejected
detail data cannot grant access or erase the PC Library. Description,
developer/publisher, market-scoped release date, all-time Store average/count,
recognized ESRB/PEGI descriptors and purchase notices are optional. Unknown
fields are not invented. Explicit Windows.Desktop SKU CPU/GPU requirements
are normalized and deduplicated; differing editions disclose that variation
instead of presenting an arbitrary table. Opaque hardware codes are not
interpreted as RAM/storage. Metascore is absent.

Trailers use native `AVURLAsset`, `AVPlayerItem`, `AVPlayer` and AVKit
`VideoPlayer`, created only from the explicit trailer action. The initial
HLS URL is restricted to the observed HTTPS Microsoft dynmedia host/path,
without credentials, ports, fragments or arbitrary query parameters.
AVFoundation owns subsequent manifest/segment requests; this is not a claim
that the image client's redirect or whole-body limits govern native streaming.
No trailer is downloaded into the public-image disk cache. Playback failure
is visible, Retry is explicit, and disappearance stops playback and releases
the current item. Preview images and at most twelve deduplicated screenshots
retain the existing bounded public-image pipeline.

Four independent evidence facets remain visible. A positive backend
`packageBytes` check is separate from the approximate public download estimate;
zero/absent bytes do not imply a checked package. Play/Stop requires an installed
registry entry and its existing launch guards. Owned/Game Pass Install dismisses
detail before opening the existing protected support/space/consent flow;
read-only startup and mutation fences guard both ends of that handoff.
Xbox hours remain Xbox-wide; Last played uses only local registered history.

The nonshipping saved-response check accepts:

```text
--catalog-detail-check <private-public-response.json> <market> <language>
```

It requires a safe current-user 0600 file, at most 4 MiB and twenty unique
matching base/detail product IDs. Output is counts only; it performs no
network, player or backend action. The private saved public response
decoded one HLS trailer, five screenshots, a Store rating and one deduplicated
Windows PC requirements table. No real response or title media is committed.

The existing ordinary-startup-fenced read-only reviewer additionally accepts:

```text
--library-preview <private-output-directory> --game-detail <private-catalog.json> <productID>
--library-preview <private-output-directory> --game-detail-info <private-catalog.json> <productID>
```

These retain the unchanged checked-catalog snapshot's provenance, empty feed
membership, frozen-broker PC read and memory-only bounded public images.
The second position scrolls to About the game. Trailer playback and private
startup/actions remain disabled. Unknown or conflicting development arguments
now exit 64 before ordinary startup, rather than treating a mistyped check flag
as a launcher request. D3 has 159 detached presentation/schema checks;
compilation and synthetic regression are not native visual sign-off, observed
HLS playback or shipping admission. Root owns capture and final admission.

## Local imported-game Play

### Phase 2 B5/B7/B8/B9 (admitted and installed; owner live acceptance partial)

Frozen source is `fee7f5f186d402d2c08ca76dc9a50e638ba5c5e2`, tree
`4363d81f0363e25982590f5fc23d6b64237d750a`.
[Exact-source CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/37676485849)
passed. After independent source review, the one-use signed package retained
the previously admitted C8 byte-for-byte. The owner independently verified
the receipt, all 21 files and strict signatures, then freshly confirmed no
game/launch/stream process and authorized normal Quit/replacement.

Replacement preserved the full working `7c3c1f0` rollback, untouched profile
and identical private installed-list bytes and permissions through one
ordinary Library reopen. The admitted file inventory and strict signatures
were rechecked on the installed bundle; its single app-owned engine and no
helper were observed. No game operation, sign-in or private exporter was
automated in deployment. Ordinary startup may perform its configured
read-only Setup check.

The owner separately observed cached Active status, the four Setup items,
successful in-app Repair Xodus (status 0) with refreshed readiness, and the
Library Game Pass section header. The locked login Keychain initially blocked
title-flow acceptance. The user completed native unlock without automation;
the owner resumed acceptance and found two defects described below.
Remaining shelf/Install/Play/Stop outcomes are not inferred from deployment.

#### Live-accepted corrections (`208939c`)

The independently admitted `208939cb3b52e99a15f24f6c6303cb0ed0700aad`
package passed exact CI
[37688479927](https://github.com/dragoshont/xodus-macos-app/actions/runs/37688479927).
The owner freshly authorized normal Quit/replacement after confirming game-ended.
The full prior `fee7f5f` app, untouched profile and identical private installed
list were preserved through one Library reopen. All admitted files/signatures
matched. The owner accepted Game Pass Active, Setup all Ready, and disappearance
of the stale setup banner after the successful sign-in check.

The first nonowned feed title may lack a PC package. Explicit Game Pass Check
now selects from retained validated feed products, preferring PC-candidate
flags while preserving feed order. Fresh, strict private compatibility-cache
reads exclude supported-false entries only when the reason contains
no PC game package or package type, case insensitively. Other unsupported
gameplay reasons do not imply an unusable licensing probe; malformed cache is
an explicit support-detail error, never an exclusion.

A null active result tries the next candidate, at most three commands total.
Each uses a fresh generated run ID and validates its own exact probeProductId.
False, malformed results, nonzero exits and other failures never retry.
One mutation and Quit fence spans cache reads and every attempt. Exhausted
null results remain Unknown; an all-excluded candidate set is visible recovery
without running a script. No feed or cache evidence becomes ownership.

Successful Check game sign-in also refreshes the already-started Setup check.
If a read-only check is in flight, one follow-up is coalesced rather than
discarding the refresh; no Repair or sign-in is started by this correction.

Account reads the private `compatibility/gamepass.json` cache with the existing
0600/current-user/regular-file/no-symlink/64 KiB policy. Its minimal
`{"active":true}` shape is supported; required active is boolean/null, never an
integer/string/missing value. Optional probe/time metadata must parse if present.
Missing, malformed and removed cache cannot become current subscription access.
Saved cache provenance is visible. There is no subscription end date.

Explicit Check chooses only a validated loaded Discover ID outside the loaded
S4 owned set; no loaded ownership or eligible candidate means no probe.
`private-xodus-gamepass-status.sh <generatedRunId> <productId>` shares the
mutation fence and requires matching terminal status/process exit plus a strict
result with boolean/null active, exact probeProductId and ISO checkedAt.
Unknown/failure removes active access and exposes product recovery/Show log.
Sign-in-required can invoke the existing explicit service sign-in; replacing
game-service sign-in clears prior in-memory subscription evidence.

Active status shows a distinct Library Game Pass shelf after Your PC games.
The source is the same validated public Discover feed, retained across Store
searches, bounded to 512 products and discarded on scope/revision/disconnect.
Eligible Discover and shelf tiles share B3 check, protected consent, install
validation and exact Installed Play matching. No ownership comes from that
shelf. Inactive/Unknown Discover retains Included with PC Game Pass without an
Install action. The private backend gates actual licences/installation;
cached status and feed membership are not independent title-license receipts.
The owner's B4 licensing and Abiotic gameplay findings are backend evidence,
not acceptance of this app package.

B9 invokes only `private-xodus-stop.sh <generatedRunId> <launchedStoreId>` for
the one live session launched by Xodus. No process scan or unrelated-game kill
is added. It reserves the existing mutation fence; the shared Installed,
Continue Playing and exact matching-tile Play control becomes Stop, disabled
with Stopping during the request. The script result must have the exact StoreId
and stopped true. Code 21, false/mismatched result, missing/conflicting status
or unsafe receipt is a visible failure with Show log, not Stopped.
The launcher may exit before the script publishes its receipt; classification
is held until confirmation. A confirmed requested Stop suppresses every
launcher exit code, displays Stopped and retains the ordinary durable start /
measured duration. Quit refuses to orphan an in-flight stop, but otherwise
still leaves ordinary gameplay running. Both new script commands have a
120-second observation deadline; installation still has no deadline.

B7 changes only the fixed script directory to
`~/Library/Application Support/Xodus/Runtime/scripts/macos`. Receipt, log,
game, compatibility-cache, journal and registered launcher paths are unchanged.
The owner assembles and installs that self-contained runtime separately;
no engine, inventory, private scripts or game DLLs are bundled by this change.
The admitted signed C8 engine remains byte-for-byte unchanged.

B8 invokes only `private-xodus-setup.sh <generatedRunId> check|repair`, using
the same private receipts, matching process exit/status and 120-second deadline.
Ready is strictly boolean; items must contain exactly one crossover,
environment, service and signin entry with bounded title/fix text and boolean
readiness. Overall ready does not imply game sign-in. Unknown extra fields
are ignored, while malformed required data and code 31 are visible errors.
One read-only startup check runs once per app process, without Repair or
sign-in. Reported unready/error state supplies a single Setup banner. Its
focused Account route does not read unrelated launcher credentials.

Explicit Repair Xodus uses the mutation fence, refuses tracked running games
and pending consent, blocks every Play while repairing, and joins before
normal Quit. Game-service status reads cannot race Repair in either direction.
The owner confirms generated launcher files are rewritten in place; legacy
launchers and the installed registry are untouched. Repair creates the shared
XodusGameTemplate only when missing, starts the service only when absent, and
creates an absent title environment from that template; it never rebuilds an
existing title environment or touches saves. Both installed Runtime and dev
scripts refuse Repair with code 22 when any launch/download process exists,
including sessions outside the current app's tracker; check never refuses.
The owner verified refusal with a running process and success while idle.
The app displays Quit the running game or finish the download first.
These are private-backend contract/evidence, not neutral app observations.
The app only revalidates
existing launcher availability, never invents or persists replacement paths.
Successful explicit service sign-in refreshes Setup after the startup check.

Unsupported Install/Repair consent no longer shows unknown download size or
generic future-download copy. Supported consent retains the real packageBytes
download size when supplied. Public detail directs eligible actions to Library
or Discover without promoting its edition metadata to ownership or an installed
edition.

Mac network-denied qualification passed 2,978 management checks, 812 native
session checks, 75 presentation checks and 29 portable packaging checks, plus
shipping-debug compilation. Setup tests cover strict four-item parsing,
exact check/repair arguments, once-only startup, mutual service-read/repair
fences, code 22/31 and unsafe/missing/conflicting receipts, all-game launch
blocking and byte-identical registry/history. Game Pass tests cover cache
types/privacy/removal, nonowned probe selection, strict result/status and
single-mutation fences. Stop tests cover both receipt/exit orderings, a nonzero
launcher exit, code 21/retry, false/mismatched/missing/conflicting results
and session persistence. These are bounded fake scripts and fake sessions only.
Those qualification checks do not run a live private script, sign-in, licence
probe or game operation, and do not themselves authorize replacement.
The separately authorized deployment and owner observations are recorded above.

### Historical B6 ACL qualification (superseded)

The approved 2.5-hour slice requires an explicit fixed-certificate-bound
app-owned access policy, migration without deleting the existing credential,
and qualification with two different signed synthetic builds. One human
migration authorization is allowed; its required UI copy is
Xodus needs one-time Keychain approval. The game service's item is out of scope.

At that boundary, no policy was implemented or qualified. Two original synthetic probes had
different binaries and the same fixed-certificate designated requirement.
A no-UI legacy-fixture ACL edit timed out; that synthetic keychain was deleted
and its original search-list metadata restored. A subsequent signer requested
native login Keychain authorization and stopped before creating any test item.
Only that signer's dialog was canceled, without a password or approval.
The signing job was unloaded; the live app's later unlock dialog remains
untouched. These are blockers, not evidence that migration or prompt-free
replacement works.

A modern-format, no-signing-key fixture is prepared but not executed; it
reuses the signed probes and preauthorizes only their fixed-certificate role
on synthetic data. Its source compilation is not native access qualification
or proof of human migration. The old timebox ended without a qualified ACL fix.
After the user unlocked the Keychain, signing/package admission and deployment
of the `208939c` follow-ups completed separately. Subsequent public-source
inspection established why removing PartitionID could not be a repair:
securityd assigns self-signed code a per-build cdhash partition and recreates
missing partitions on access. The new user-approved broker approach below
supersedes that hypothesis; it does not retroactively qualify it.

### B6 frozen credential broker candidate

The user chose a tiny authenticated credential helper, signed once and preserved
byte-for-byte across launcher replacements. The new slice has a three-hour
budget; the earlier expired ACL budget is not reset. This public implementation
does not modify the management engine or the game service's item.

**Trust and installation.** The helper is a one-request child, not a daemon.
It is installed separately at
`~/Library/Application Support/Xodus/CredentialBroker/XodusCredentialBroker`.
Each package's signed resources pin its version, SHA-256 and byte count. Packaging
copies the approved signed artifact without rebuilding or re-signing it.
Installation is a separate owner gate and must preserve an already installed
matching artifact; an upgrade is never inferred from a new launcher package.
Directories are private, the executable is immutable by convention and mode
0500, and replacement requires a new approved helper/migration policy.

The app validates regular/current-user/nonlinked/non-writable-by-others file
metadata, its full hash, fixed broker certificate requirement, and the spawned
child's dynamic code hash before sending data. The unnamed Unix socketpair has
no filesystem listener. The helper authenticates the kernel's LOCAL_PEERTOKEN
with SecCode and the app's fixed leaf-certificate requirement, including the
same UID; no caller-supplied PID/path is trusted. Authentication is repeated
before an operation and before returning a result. Unauthorized callers exit
with a specific denial, before any item access.

**Minimal contract.** Versioned, request-ID-bound, length-delimited private
frames permit only read (including presence-only), write, delete and explicit
migration. The token ceiling is 128 KiB; deadlines bound ordinary transport
and explicit approval. Tokens never use argv, stdout, stderr, files or app
logs. Only fixed `Xodus Library` generic-password identities are reachable:
legacy `xbox-web` and broker-owned `xbox-web.credential-broker-v1`. The backend
and `Xodus Service` identities are not exposed. A missing helper permits the
existing direct store; an existing rejected, mismatched or unavailable helper
never causes silent direct fallback.

**Migration and recovery.** Presence-only inspection shows the explicit native
UI message **Xodus needs one-time Keychain approval.** before any credential read.
Only the user's approval action enables interaction for the legacy read. The
helper creates its own fixed-requirement item, verifies an actual no-UI re-read
of the new bytes, then disables interaction and attempts deletion of the exact
legacy reference returned by that read. Public SecKeychainItemDelete is used
because SecItemDelete's legacy app-name ownership wrapper rejects a foreign
creator even after read permission. No broad query, ACL rewrite or private SPI
is used to remove the old item.

If exact-reference deletion fails, the verified new copy remains authoritative;
the response and UI report legacy retained. The next launch reads the broker
copy first, even while the old item exists. It never retries that delete in a
loop or silently repeats approval. Failure before a verified new copy retains
the original. Cancellation/uncertain delivery is not success, and an interrupted
copy can be rediscovered through presence without reading the old secret.
Explicit sign-out may fail visibly if a retained foreign item cannot be removed;
it never falsely claims all credentials were cleared.

Updating the helper changes its own cdhash and can need fresh approval, even
with the same certificate. Do not replace it as part of ordinary app updates.
A pre-broker rollback cannot read the new account directly; retain a
broker-aware rollback for future releases and gate older rollback deliberately.
Source qualification does not establish live migration or replacement behavior.
The separately authorized owner live checks are recorded below.

**Qualification boundary.** Native synthetic builds use the same transport,
peer authentication and storage logic with a compile-only fixed neutral
keychain/service and no UI. They are not production credential tests. Coverage
must distinguish two differently signed client builds using one unchanged
broker, actual changed-value rotation, unauthorized-caller rejection,
preauthorized staged-copy/exact-reference deletion, injected deletion-failure
retention, and denied migration preserving the old value. Cleanup must preserve
the original user search list and delete only the disposable test keychain.
Mocked controller checks separately cover explicit approval, cancellation,
refusal, no automatic provider refresh, and retained-legacy publication.

The final synthetic native harness passed both migration outcomes in a verified
non-graphical security session with no controlling terminal. Two different
signed clients read and actually rotated neutral bytes through one unchanged
broker; an ad-hoc caller received native denial before any item access. A
foreign-creator fixture explicitly preauthorized only with its neutral
keychain password passed read, staged verification, exact-reference deletion,
then client B's read with legacy retained false. Injected deletion denial
(-25308) retained the new copy, permitted B's subsequent rotation, and kept
legacy retained true without retrying the old deletion. Separate native read
denial (-25293) and unapproved deletion (-25244) preserved the original value.
The disposable keychain and lock were removed, the original search list was
unchanged, and the one-use signing job was unloaded.

The separately signed production helper candidate is 228448 bytes, SHA-256
`2c40354c471c7a692cc64eea473a2fe1d34630c140341010ae9967e9742c9381`.
Synthetic preauthorization is not the user's native approval; injected retention
is not an observed live delete failure. Final package/independent admission and user-present live
migration remain separate gates.

**Bounded live observations.** The owner independently admitted `2d420d1`,
its exact-source CI and the signed frozen-broker package, then authorized a
user-present installation and migration. The helper was installed at the fixed
path with the exact bytes above. The user answered the single expected native
approval; migration finished with `legacyRetained=false`. A subsequent identical
app reinstallation loaded 13 PC games without an observed reapproval. A distinct
signed, non-installed Library review build also read the same broker and loaded
13 PC games without an observed Keychain prompt, performed no credential
write/delete/migration, and quit normally. Private receipts retain the exact
identities; these observations do not guarantee every future prompt-free
replacement, authorize helper updates or establish fresh game-service status.

### Phase 2 B1/B2/B3 (admitted, installed and owner-live-accepted)

The owner-directed batch fixes PC Game Pass discovery, adds loaded-owned-first
search and integrates the private package-support check without changing C8.
Only a page validated as `pcGamePassDiscovery` / `MicrosoftGamePassSigls:v3`
may use feed membership instead of `pcCatalogCandidate`. Market, language,
resolved language, source, artwork, editions, unknown entitlement, IDs/cursor,
pagination and revision checks remain. Cache/network Store search stays strict.
Discovery requests 16 items; validated feed IDs survive Store searches in
memory, but reset on feed revision, scope change or disconnection.

Search matches loaded S4 titles by case-insensitive substring before Store
results and deduplicates exact product IDs, never title/edition guesses.
Owned takes label precedence over Game Pass. Both labels require their own
loaded evidence; Game Pass does not imply an account subscription or ownership.
The search view observes the PC library, Installed and game-operation
controllers directly and shares the existing tile/Play/Install controls.
It neither loads personal data automatically nor infers ownership from activity.

`private-xodus-check.sh <generatedRunId> <productId>` uses the existing fixed
script, private atomic receipt and matching process-exit/status contract.
The result requires the requested StoreId, nonnegative/null packageBytes,
boolean supported, bounded optional product reason and ISO checkedAt. Extra
fields are ignored. Consent remains visible while checking, disables Install
until supported and displays the real size or unknown-size copy. Unsupported
and failed checks never launch installation. One check shares the mutation,
service-restart and normal-Quit fence; explicit Cancel joins its owned script.
No game files are downloaded by this check according to the backend contract.

Tile/search badges read only
`~/Library/Application Support/XodusRemote/compatibility/<StoreId>.json`,
with the same 0600, current-user, regular-file, no-symlink and 64 KiB bounds.
Missing cache means no support badge; malformed/nonprivate cache is a quiet
explicit error. Cache reads never invoke a script. Package support is not a
certification that every title or gameplay path works. An install failure with
code 12 refreshes that bounded private cache and prefers its unsupported product
reason. If unavailable, the runner reads its bounded terminal failed-progress
message after the child has exited, then falls back to specific unsupported copy.

Neutral fixtures cover the false discovery flag while preserving strict
Store checks, local matching/deduplication/badge provenance/Installed matches,
private cached support results, consent check failures, unsupported reasons,
single-check fencing and cancellation. Mac network-denied qualification passed
2,978 management checks, 722 native session checks, 75 presentation checks and
29 portable packaging checks, plus shipping-debug compilation. The final
removed-cache regression passed in the 104-check focused operation suite with
another successful shipping-debug build. These are synthetic checks only.
Root source review was GREEN at `7c3c1f0` / tree `459a6012`.
[Exact-source CI 37668302715](https://github.com/dragoshont/xodus-macos-app/actions/runs/37668302715)
completed successfully at the full frozen head. Signed package `UcVKTf` contains
21 files, verifies strict signatures and actual fixed-certificate leaf
requirements, and preserves admitted C8 byte-for-byte. Its private receipt is
15,182 bytes, SHA256
`928e090219bfacd2a11212890a7bd8765f950c33f91f1ecf66c2fab02b241c4e`.
Root independently admitted the combined package, freshly confirmed no game/
launch/stream process and authorized normal Quit. Replacement retained the
complete `1463cdb` rollback and untouched profile. All 21 installed files and
strict signatures matched admission; the installed list stayed byte-identical
with 0600 permissions through one ordinary Library reopen. No game operation
or authentication was automated by this deployment lane.

Root closed live acceptance on `7c3c1f0`: Discover showed 16 real-art PC
Game Pass titles including A Way Out and Age of Empires II; Lara and Hogwarts
search showed Owned with Play, while Celeste showed Owned with Install. Celeste
support check displayed its exact unsupported reason with Install disabled.
Those title/flow observations are not general gameplay certification.
B5/B7/B8/B9 is the next separate package, excluded from this frozen source
and artifact.

### Historical B6 app-owned ACL follow-up

The separate next package is timeboxed to 2.5 hours of B6 work: explicit
ACL/partition policy anchored on the fixed-certificate designated requirement,
plus migration of the existing Xodus Library item. One human authorization is
acceptable and must be introduced as Xodus needs one-time Keychain approval.
Qualification requires two differently signed synthetic builds; only qualified
scope may freeze at the timebox, with the rest reported explicitly. The
Xodus Service item remains outside this app lane. That ACL candidate was not shipped. The user subsequently selected the
[frozen broker](#b6-frozen-credential-broker-candidate); its live migration and
replacement remain separate owner gates.

### S3/S5/S6 game operations (admitted, installed and live-accepted)

This app-only batch implements the approved
[remaining-work spec at bda88fe](https://github.com/dragoshont/xodus-macos/blob/bda88fe/docs/xodus/remaining-work-plan.md).
The owner confirmed four existing private script entrypoints under
`~/src/xodus-macos-private-ai/scripts/macos`: `private-xodus-service-status.sh`,
`private-xodus-service-signin.sh`, `private-xodus-install.sh`, and
`private-xodus-uninstall.sh`. The public app contains their invocation contract,
not their source, credentials or runtime. No engine/schema pin is changed.

Every invocation uses `/bin/bash`, an exact generated run ID, separate arguments,
and the existing minimal Play environment. Receipts under
`~/Library/Application Support/XodusRemote/processed` are bounded, private,
regular nonsymlink files. The owner guarantees atomic receipt publication with
status last and process exit equal to status, including SIGTERM. Missing or
conflicting terminal status is an explicit failure, never success.
Show log reveals only an existing generated-run stderr file in Finder.

Game-service status/sign-in is explicit in Account and Settings. Sign-in opens
the service-owned Microsoft flow, then reads fresh status. No library token is
passed to the service. Service restart is disabled during gameplay or a
mutation. PC-library authentication and game-service authentication remain
separate truthful states.

An uninstalled account-bound PC tile offers Install. Consent shows the exact
ASCII-title destination under `~/Games/Xodus`, measured volume capacity, and
unknown-size copy because the current catalog DTO does not retain a proven
download size. The operation view uses real receipt bytes/phases, not estimated
or simulated progress. Cancellation signals only its owned script and joins it;
code 14 retains partial files for retry. Codes 10–13 have specific storage,
sign-in, unsupported-package and verification recovery. Only code zero plus
matching requested StoreId/folder, valid MicrosoftGame.config, executable
launcher and durable registry save enables Play. Repair uses that same
validator/store path and preserves entry identity/session history.

Uninstall requires confirmation, refuses a running game, and delegates deletion
to the private script. The owner guarantees verified save copying before
deletion, code 20 without deletion if preservation fails, and a folder under
`~/Games/Xodus` whose config StoreId matches. The app itself never deletes game
files. Only confirmed code zero removes its list entry. Remove from list
remains nondestructive. One mutation reserves edits/affected-game Play; normal
Quit refuses to orphan a mutation or game sign-in, without changing the prior
rule that quitting during ordinary gameplay leaves the game running.

A private atomic 0600 journal (0700 directory) records the one pending mutation.
Reopening never replays a script: explicit Check last operation reconciles a
terminal receipt through the same validator. Uncertain registration stays
visible and fenced. Known joined failures release the mutation without
inventing an installed game. Container identifiers that masked Installed and
PC Library child actions are removed; controls keep their own identifiers.

Neutral checks use synthetic scripts, config, receipts, local folders and a fake
one-second Play session only. They do not authenticate, run private scripts,
install/uninstall a real title, query an account, or start the installed app.
Final frozen Git-LF Mac qualification passed 684 native session checks
(77 game-operation checks), 75 presentation checks and 29 portable packaging
checks, with shipping-debug compilation. Fixture receipt publication follows the same atomic,
private-file contract; additional result keys are ignored, never promoted into
registration metadata.

The subsequent observation-only correction makes Downloads itself observe
operation state (so its empty state disappears during work) and forwards
Installed-state changes to computed service/consent controls. Its focused
operation suite passed 77 checks and shipping-debug compilation.

The admitted runtime is `1463cdb5260356a536f29d8f39d90d4e69b06689`, tree
`fa3eac5f6d78e534c10e3816f615511003a5d22d`.
[Exact-source CI 37640727574 passed](https://github.com/dragoshont/xodus-macos-app/actions/runs/37640727574).
The owner independently admitted package `uybU6j`, receipt
`a929185184862f9af0a095625cc7344da6130053cbd730fd4c78ad3b89c1e73f`
(15,035 bytes, 21 files). Launcher SHA-256 is
`6d98be96eb1d40a16ec78b504b00e600d5ef2acdf27e1723732626d349285bfe`
(5,800,576 bytes); helper SHA-256 is
`d0b1a85884cf9a5afa81470edc81771b7388a881b2d9793bda5f10ee77dce3cf`
(359,120 bytes). C8 remains byte-identical to admitted S4:
`c8fe69a3bc2b6a84c5bad5ef0c1ae041f36466a87419c0f17d9567c6df3ed14d`
(22,012,176 bytes). Three fixed-leaf requirements and deep strict signature
verification passed; the one-use GUI signing job completed and was unloaded.

After a fresh owner check that no game, launch or stream process was running,
normal Quit and replacement were explicitly authorized and executed. The full
working S4 bundle and older rollbacks were retained. Profile/credentials were
not copied, deleted or reset; installed-games.json stayed byte-identical at
924 bytes/0600 across replacement and startup. All 21 installed files and
strict signatures match admission. One ordinary Library reopen left app
PID 92141 owning its sole engine PID 92153, with helper count zero.

These are installed byte/signature/ownership/startup observations, not live
Install, Repair, Uninstall, game sign-in, visual or gameplay acceptance. No
sign-in, Import, Install, Repair, Uninstall or Play was automated by this lane;
no capture, private exporter or extra RPC was used. Existing anonymous startup
catalog search is unchanged. The owner separately completed live acceptance.

**Owner-reported partial live acceptance, 2026-10-07:** no app defect found so
far. The owner verified child accessibility identifiers (closing S4 follow-up
b), the Installed menu's Check for update / Repair, Remove from list and
Uninstall actions, and the Repair consent sheet's destination, measured free
space, unknown-size copy and product wording. Repair invoked the real backend
and correctly surfaced code 11 without changing the registry. This is evidence
of the consent/invocation/sign-in-required failure path, not a successful repair.

At that intermediate checkpoint, live acceptance was held on human-only
Keychain approvals. The owner
reported an `Xodus Library` access prompt while PC games remained at Loading
your PC games, with an `Xodus Service` credential read queued behind it. The
service credential-writing follow-up is owned outside this app repository; no
app change was requested. This lane did not approve prompts, rewrite credentials
or bypass Keychain protections. The subsequent acceptance below supersedes
that testing hold.

**Owner-reported final live acceptance, 2026-10-07: ACCEPTED.** The owner closed
S3/S5/S6 on installed `1463cdb` with no app defect and observed:

- PC-game Install buttons and native Install consent.
- Real Downloads progress: 1.14 GB of 3.25 GB (34%), with Cancel installation
  available. This observation verifies the control, not a live cancellation.
- A fresh 3.25 GB Lara installation that registered with its generated launcher,
  followed by Play reaching the game's main menu.
- Repair status zero with launcher migration.
- Uninstall confirmation copy, then status zero with game files/environment
  removed, saves kept and the Installed list updated.
- Sign-in-required and unsupported-package (code 12) messages, Show log and
  Continue Playing session recording.

All backend corrections found during acceptance were private-script-only;
the accepted app runtime and preserved C8 did not change. This is independent
owner-reported installed-product evidence, not fixture or deployment inference.
The earlier menu/consent/identifier and registry-preserving code-11 observations
remain valid. S4 follow-up b is closed; broader owned-view coverage comparison
and general gameplay certification are not established by this slice.

### S4 owned PC Library (admitted, installed and live-accepted)

This slice implements AC4.1–AC4.5 of the
[remaining-work spec at fbf849d](https://github.com/dragoshont/xodus-macos/blob/fbf849d/docs/xodus/remaining-work-plan.md).
Root supplied observed protocol evidence after one user-approved device-code
sign-in: a complete two-page collection, 136 items including 69 Game entries.
That producer-side probe is not evidence of this app's installed Library or
of its PC-filtered result count.

The app uses URLSession directly, not a new engine/schema/management command.
Device-code and refresh POSTs use the approved Microsoft consumer OAuth client
and `XboxLive.signin offline_access`. The native sheet exposes only user_code
and an exact Microsoft verification link. Pending/slow_down/expiry/decline and
Cancel are explicit. Only refresh_token is stored as a nonsynchronizing,
app-owned generic-password item (service `Xodus Library`, account `xbox-web`,
AfterFirstUnlockThisDeviceOnly); rotated refresh tokens replace that item.
Access/user/XSTS tokens remain in memory, never argv, URLs, logs, registry,
UserDefaults or exported diagnostics. Sign out deletes that one item.
Library entry checks item presence without credential data or permission UI;
credential reads are limited to foreground Load/Refresh actions.

The fetch chain uses Xbox user auth (`RpsTicket=d=<access>`), XSTS for both exact
audiences, and equal user hashes before any collection request. The beneficiary
comes from the Xbox identity's xid. Collections queries use contract 2, All
validity, excludeDuplicates, locale market (US fallback), maxPageSize 100 and
bounded continuations. All requests have 30-second bounds, no redirects,
cookies, credential storage or disk cache, and at most 4 MiB per response.
Pagination stops at 20 pages; a repeated cursor, malformed page or incomplete
fetch fails explicitly and cannot supply an empty or partial successful shelf.

Only Game/Active/non-trial product IDs join to public DisplayCatalog in batches
of at most 20. Products require exact `Windows.Desktop` package evidence.
Missing/console/unresolved candidate games are excluded and counted; Application,
Durable, Pass, trial and inactive items do not inflate that count. Missing/odd
item fields simply cannot establish a candidate; page structural failures remain
explicit. Titles and
BoxArt/Poster come only from the joined product; protocol-relative images use
the existing exact-host/grammar validator and bounded memory-only artwork
loader, without sending private authorization. Installed matches use exact
StoreId, not names, activity or a PC tag. Imported games share existing Play
states/log controls; others say Not installed. No install/cache/enqueue route
or compatibility claim is added.

Neutral checks use synthetic pages/catalog/OAuth responses and a mocked
refresh-only store, never Microsoft/Keychain/game operations. The Mac source
gate passed 607 native session checks (49 added for S4), 75 presentation checks
and 29 portable packaging checks, with outbound networking denied for native
checks; the shipping Debug composition built. They cover parsing/casing,
continuations/caps, complete versus partial failures, filtering/PC join,
deduplication/batches, image grammar, identity binding/XErr, device-code timing,
refresh-only retention, cancellation/sign-out/termination and Installed match.
These are not installed sign-in or owned-PC gameplay evidence. Exact-source
CI and preserved-C8 packaging precede independent admission.
Root owns subsequent user-present device-code and actual PC shelf/Play evidence.
The signed C8, profile, contracts/pins and frozen support packets are unchanged.

Frozen corrected source `7ec1daaf1c5f3985c29eec01ed7eb90c151f001f`, tree
`997d3970bfc43cd1ae0f2ef18c900253808327e9`, passed the same 607 native checks
from its exact Git-LF archive. Exact-source
[CI 37617059339](https://github.com/dragoshont/xodus-macos-app/actions/runs/37617059339)
completed successfully, including Release ShippingChecks and resource exclusion.
Root's bounded source review correction is included: only candidate games
contribute to the hidden count, incomplete third-party items cannot fail a valid
page, and device-code copy contains no internal service language.

The matching UI-only package `odJCks` was independently admitted and installed.
Receipt SHA256:
`4e42f6239517ecae6f850a5ec059d052cdc8fdf5a1079a1bc5d0af92c871f200`,
14,449 bytes, covering 21 files. Launcher SHA256:
`16b123f10f75a1b36bf56fe931bc22704a74dbf16c3811110843ca82e8b09be0`
(5,270,144 bytes); helper SHA256:
`58b631646457482fb1d77db233ccc2cb026adf83313df5a61a4428000cc17393`
(359,072 bytes). The signed C8 engine is byte-identical to admitted S1's
`tmzPp3` input (22,012,176 bytes). All three fixed-leaf signature requirements
and deep strict verification passed; the one-use signing job is unloaded.
Root reviewed the corrected source and exact package/CI, confirmed the game and
launch script had ended, and explicitly authorized normal Quit/replacement.
The complete working S1 app and older rollbacks were preserved. The profile
and credentials were not copied, deleted or reset; installed-games.json stayed
byte-identical and 0600 across Quit, replacement and startup.
One ordinary main-Library reopen left app PID 71639 owning sole engine 71654,
with no helper. All 21 installed files and three strict fixed-leaf signatures
matched admission. No actual device-code, auth, owned-library, Import/Play, game
or new screenshot request was automated by the implementation/deployment lane;
ordinary anonymous startup catalog search remains unchanged.
These are installed/startup observations, not user-present sign-in, PC shelf
or gameplay proof.

**Separate Root live acceptance (2026-10-07):** the user completed the installed
app's in-app device-code sign-in. Root observed Your PC games with a count of 13
and real DisplayCatalog box art; Hogwarts was matched to Installed and showed
the shared Play control, whose working launch was already accepted in S1/S2.
Other titles showed Not installed; Refresh and Sign out were present.
Root explicitly closed S4 with no blocking defect. This does not claim a new
S4 game launch, an exercised sign-out/deletion, or exhaustive Windows Xbox
Owned-view parity. Two non-blocking follow-ups are retained in the owner's spec:
coverage comparison for omitted Owned-view entries and container accessibility
identifiers overriding child button identifiers. No follow-up implementation
was requested. No account identity, library title list, captured image or token
is reproduced here. Runtime source, package, signed C8 and production pins
remain unchanged.

### S1 artwork and Continue Playing (admitted, installed and live-accepted)

This slice implements AC1.1–AC1.6 of the
[published remaining-work spec](https://github.com/dragoshont/xodus-macos/blob/dragoshont-heroic-xbox-integration/docs/xodus/remaining-work-plan.md).
Tile preference is ShellVisuals Square480x480Logo, Square150x150Logo, StoreLogo;
hero preference is SplashScreenImage then the same tile order. Windows
backslashes are parsed as relative separators. Component-by-component `openat`
with no-follow directory/file descriptors rejects traversal, absolute/drive
paths and symlinks, including swapped components. Only regular PNG/JPEG files
up to 8 MiB and 16,000,000 decoded pixels are accepted. Tile/splash decoding is
off-main and downsampled to 480/1920 pixels; cache is bounded memory-only.
Missing/unreadable/invalid optional art silently retains the system symbol.
No real game art is copied into the repository, fixtures or shipping resources.

Publisher and nullable lastPlayedAt/lastSessionSeconds extend the local JSON
without making new keys required for old entries. Artwork is re-derived from
the selected folder's config, not stored as remote/provider identity. Successful
script start records lastPlayedAt; script exit records monotonic process
duration, including fast and nonzero exits. Failed startup records neither.
Actor mutations merge history with import/remove rather than overwriting it
with stale list snapshots. Async persistence failure never delays clearing the
active session; one quiet error says history couldn't be saved.

Only the newest recorded imported game with a locally available folder and
executable script can supply Continue Playing. It never consumes Xbox activity.
The native hero includes decorative splash/tile art, title, optional publisher,
relative last played and the exact shared Play/Launching/Playing/retry action.
It does not add entitlement, Store, compatibility or engine-registry claims.

Neutral checks use tiny synthetic PNGs and fake scripts for ordered art
fallback, contained paths/symlink refusal, byte/pixel bounds, downsampling,
legacy decoding, persisted own-session lifetime, history-save failure,
concurrent import preservation and hero ordering/launchability. Real-product
closure requires an admitted installation, Hogwarts artwork observation and
one user/Root-controlled post-install session. Root separately supplied that
evidence below; CI/package alone did not close the gate. The implementation and
deployment lane did not interrupt or launch the game.

The user-directed AC2.3 addition shares this batch: a nonzero session exposes
Show log only when its generated-runID stderr file exists in
`~/Library/Logs/XodusRemote`. The fixed suffix is `.stderr.log`; paths never
come from script output or arbitrary input. Finder reveals the selected file
without reading/uploading its contents. RunIDs/log locations remain in memory,
clear on retry/removal and do not become registry or diagnostic payloads.
Neutral fake scripts check existing/missing log actions and path refusal.

Frozen source `e4014647328654c4c8688ca5954b5b3f5dfd162e` (tree
`78d5b8b0cea272ce0fdaaba21d899c9c6aefd853`) passed 558 native session,
75 presentation and 29 portable checks on the user's Mac with outbound
networking denied, plus a shipping Debug build. Exact-source
[CI 37610002150](https://github.com/dragoshont/xodus-macos-app/actions/runs/37610002150)
also passed, including Release ShippingChecks and shipping resource exclusions.
These are neutral/source evidence, not real game-art/session evidence.

The matching `tmzPp3` package was independently admitted and installed. Its receipt SHA256 is
`fcb0d45ea18e0156a144dfdf52b0bd3f4bb715a7b252d7aaf86cac7a7f01e815`,
13,887 bytes, covering 21 files. Local fixed app/helper/engine signature checks
passed; the signed C8 engine is byte-for-byte preserved from admitted
`0926414`/`18uWwt`. Root independently reviewed the exact production diff,
package and successful CI, confirmed no game/script was running, and explicitly
authorized normal Quit/replacement. Full working 092 rollback and earlier
rollbacks were preserved. Profile/credentials were not copied, deleted or reset;
installed-games.json remained byte-identical and 0600 across replacement/startup.
One ordinary main-Library startup left app PID 51247 owning sole engine 51265,
with no helper. All 21 installed files and three strict fixed-leaf signatures
matched admission. No Import, Play, game launch, activity/Account/Store action,
screenshot, exporter or extra RPC was automated by the implementation/deployment
lane. This is installed/startup evidence, not visual or gameplay proof.

**Separate Root live acceptance (2026-10-07):** using its already-approved native
ScreenCaptureKit observer of app PID 51247, Root reported actual Hogwarts
Square480 tile art in Installed. One Root-controlled Play session reached the
full-screen game in about 20 seconds with no driver warning; Root ended the
test by SIGTERM after about 55 seconds. The app then showed Continue Playing
with the real 1920x1080 splash, title, publisher "Warner Bros. Interactive",
relative last-played date, shared Try again and AC2.3 Show log on both hero and
row. The registry recorded lastPlayedAt and lastSessionSeconds 54.6, with 0600
permissions preserved. Root explicitly closed S1 with no defect. The failed-exit
retry/log observation does not claim a natural exit-0 test or an exercised
Finder reveal. No captured image, private registry contents or real artwork is
published here; runtime source, package, signed C8 and production pins remain
unchanged.

Main Library offers an Installed section independently of owned-PC inventory,
which remains unavailable. The user chooses one game folder and then one
executable working Xodus launch script through native file panels. The folder
must contain one case-insensitive `MicrosoftGame.config`; bounded `XMLParser`
reads Identity Name/Version, StoreId and ShellVisuals DefaultDisplayName, falling
back to Identity Name. Malformed/missing identity, version or StoreId is refused;
external entities are not resolved. No provider, title-name mapping, engine
snapshot, entitlement or installation check is inferred from this import.

Entries contain UUID, title, identityName, version, storeId, folder, launcher and
importedAt. `~/Library/Application Support/Xodus/installed-games.json` is separate
from the existing Management profile. Writes use an exclusive 0600 temporary
file, sync and atomic rename inside a 0700 directory. Corrupt/unreadable lists
produce a visible failure and block mutations, not a success-empty overwrite.
Reimporting the same folder updates its local entry while retaining its UUID.
Remove edits only this JSON; it never deletes game, launcher or save files.

Play checks the selected folder and executable regular launcher, then starts
`/bin/bash <launcher> <runID>` off the main thread. The argument array passes no
shell-interpolated command. The runID is `xodus-yyyyMMddTHHmmssZ-xxxxxxxx` in UTC,
with eight lowercase hexadecimal characters. Environment inheritance is limited
to HOME, USER and LANG; PATH is fixed to
`/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`. The script owns the game session;
its exit resets Play, with a code-specific Try again error for nonzero exit.
Only one session can launch at a time. The first five seconds show Launching,
then Playing if still alive. Termination callbacks return to MainActor. App
Quit fences new launches but never terminates the game process.

Neutral checks use only temporary synthetic configs and fake exit-0, exit-3 and
sleep-2 scripts. They cover parsing, private persistence, argument/environment
format, launch states, missing launcher, single-session fencing, list-only
removal and natural completion after app shutdown begins. These are not real
gameplay or service sign-in evidence. Hogwarts Legacy is the sole user-approved
live target and is not launched by qualification or deployment.
The signed C8 engine, production schemas/pins, future support packets and
existing account/history boundaries are unchanged.

The frozen UI-only implementation is consumer
`0926414a258dc2f6247edcc3d9f2d962af4f2a1a`, tree
`3cd51d3776dc8b3294b3274d53e9ca68c879f188`. On the user's Mac,
516 native session checks (including 35 local import/Play checks), 75 native
presentation checks and 29 portable packaging checks passed. Native checks ran
with outbound networking denied; a separate shipping Debug composition built.
Exact-source CI
[37603065132](https://github.com/dragoshont/xodus-macos-app/actions/runs/37603065132)
completed successfully, including Release ShippingChecks and exclusion of
private fixture resources. Fake scripts and neutral bytes are not live
Hogwarts gameplay or compositor/accessibility certification.

Root independently admitted this source and the matching `18uWwt` package.
Receipt SHA256 is
`d6d916355faa41d8d4ff9c0bb1df0d092258ad3f76231f2d9e50da09149703b4`,
13,743 bytes. All 21 files, the exact source/producer pair, preserved C8 input,
strict signatures and exact-head CI passed admission. The final launcher SHA256
is `92f9afdbfd4e18c1bacdf0806e1de002b85ed05cc1adb05b44bb81efd5278393`
(4,408,624 bytes). The helper SHA256 is
`c521d79cf4ba5b7101eab526960bc961a5f6f76f37fa96a09d9f887f11158e39`
(359,120 bytes); the signed engine is byte-for-byte unchanged C8 (22,012,176 bytes).

Installation used normal owned-idle Quit and atomic replacement, preserving
the complete working 2d app, profile/credentials and earlier rollbacks. One
ordinary main-Library startup left app PID 33405 with sole parent-owned engine
33422 and no helper. All installed files and the three fixed-certificate strict
requirements matched admission. No Import, Play, real-game launch, Recent
activity, Account or Store action, screenshot, private exporter or additional
RPC was automated. Existing anonymous startup catalog search is unchanged.
This is installed-byte/signature and process-ownership evidence, not API-trace,
visual or Hogwarts gameplay evidence. The user/Root retains the live game test.

## Development-only registry compatibility

The typed registry record accepts a **required-but-nullable** `runtimeFingerprint`
and the explicit `notVerified` health value. A null fingerprint means no runtime
binding was established; a missing key or wrong type remains invalid. Encoding
preserves the key and explicit null. Existing non-null records and health values
remain valid. `notVerified` describes observed committed local metadata, not
payload integrity, entitlement, runtime certification or launchability. A legacy
package digest over a local serialized manifest is not authoritative provider
payload evidence.

This source-only preparation uses separately copied, sanitized test resources
from producer `0aca761e820db5fee0f2e03e37ab09412054620b`, tree
`82c82b67d7925b5512f72f3ad3273979dc7fcfb5`. Development schema SHA256 is
`13354f71c32e558792a83c64a0920b4831128c455385309d3b036ae93efc4b94`;
its exact corpus contains 102 positive and 99 negative frames. The development
validator uses the existing alternate-schema initializer, not new transport or
UI infrastructure. These resources are excluded from shipping.

The production schema, c107 producer and signed engine admission pins below are
unchanged. Production validation still rejects future nullable/notVerified
records before typed decoding. This packet does not enable or prove deployed
registry reads, installation, ownership or play.

Data-only checks validate the complete development corpus, backward compatibility,
null-preserving round trips, missing/type-invalid fingerprints and unknown health.
The existing fixed busy/recovery/worker failure envelopes preserve their error
code and retryability and cannot decode as successful empty snapshots. Corrupt or
partial local state must remain a failure; only an absent entire staging scope
can truthfully produce an empty registry. No operation-specific registry diagnostic
category or new error mapping was added. The targeted check entry point is
`XodusManagementChecks --registry-development-checks`; it starts no engine and
makes no `installed.snapshot`, credential, provider or artwork request.

## Development-only installation-planning failures

A standalone `InstallPlanFailure` codec preserves the exact 17 complete failure
tuples from producer `75d5ed1f00a65f18e501a048e8f6b558c23206e7`, tree
`aa7d8decf0bd885d4141e5d04570d0bb2ca94616`. Each tuple binds the exact
code, fixed message and retryability to one category/stage/reason pair. Missing,
extra, wrong-type, unknown or cross-paired values are rejected, rather than
promoted from independently recognized stages or reasons. Only
`provider/unavailable` is retryable.

Its separate, producer-qualified development schema SHA256 is
`dbd7bada96bebb09ff17bbecca622e613bb94d661766f08c2e5bd61d235cddcd`,
with 119 positive and 172 negative frames. Tests use the actual copied producer
failure witnesses and the authoritative `/$defs/installPlanError/oneOf`, not
reconstructed accepted examples. Additional invalid-input mutations exercise
missing/type-invalid fields and cross-paired complete tuples.

This preparation adds no live error routing, ready-plan Data variant, plan
cache, enqueue path, license authorization or UI. The existing transport and
auth/history failure decoding are unchanged. Reserved plan descriptors remain
codec-only and excluded from live success; no descriptor establishes payload,
runtime, entitlement or installation readiness. Production resources and pins
remain unchanged. `XodusManagementChecks --install-plan-development-checks`
runs the retained registry checks and new plan data checks without starting an
engine or making any management, credential, provider or artwork request.

## Artwork and recently played source slice

### Current Library semantic correction

The main PC Library no longer presents real TitleHub play history as owned
games or a featured Library title. Its concise unavailable state explains that
PC ownership cannot yet be verified, with native Browse games and Recent
activity actions. The separate activity scope identifies cross-platform
history prominently and has no owned-looking hero; reported PC/mixed tags do
not establish Xbox PC Store applicability or entitlement. Console-only history
can appear only in activity, never main PC Library.

Main Library entry issues no saved-status or history read. Explicit activity
entry owns the existing bounded deduplicated loader; returning or rebuilding
reuses its already consumed connection attempt and retained memory. Search is
disabled in main Library and limited to loaded history in activity. Account
checks and connection retirement retain their existing clearing/fencing
behavior. Find in Store remains a user-directed name query with explicit
catalog candidate selection, never a history-to-product mapping.

Consumer `2d741a745217f52330ad79208eb2e8374a708a0d`, tree
`8f529988df80d2005371216cabf940453106cefc`, passed 481 native session and 75
presentation checks with outbound networking denied, plus 28 portable checks.
Exact-source CI
[37522058333](https://github.com/dragoshont/xodus-macos-app/actions/runs/37522058333)
completed successfully, including shipping checks. Root independently reviewed
the semantic change and admitted all 21 package files, fixed app/CLI/helper
signatures and sealed producer bindings. Receipt SHA256 is
`60a9ca141a13f8ae2115095d42f2cc6fa07b0d02df7aed17bcc8cac22686f767`
(13,163 bytes). The signed c107 CLI is unchanged byte-for-byte at
`c8fe69a3bc2b6a84c5bad5ef0c1ae041f36466a87419c0f17d9567c6df3ed14d`,
reused from the admitted 0a package rather than rebuilt or re-signed.

Installation on 2026-10-06 used successful normal Quit and atomic replacement,
preserving the entire working 0a bundle, previous rollbacks, profile and saved
credentials. One ordinary startup left the same shipping process running in
main Library. All installed files/signatures matched admission, with one
parent-owned matching engine and no helper. No Recent activity, Account or
Store action, personal/history read, exporter, image request or screenshot was
initiated for proof. A bounded existing-log observation found zero recent-list
publication and zero image-decode events for that exact app process. Event
absence is neither an API trace nor visual evidence; existing anonymous startup
catalog search is unchanged. Source and neutral checks, not absent logs,
establish that main Library does not consume history or initiate its loader.

Earlier shipping observations below remain historical evidence for the prior
presentation, not authoritative owned-PC inventory. The frozen development-only
registry/plan codecs do not change production resources or enable these missing
capabilities.

The current source pairs with producer
`c1073100ce8936a751b962b1401ddb641c8be38a`, tree
`7a808c0e6a8a909455d07eb463379ab55bdf138c`. Its exact generated management
schema SHA256 is
`6945db01df88eeaf80f495f6b9d7240e270a879851c2c830fc5548ba20d32192`,
with 100 positive and 96 negative sanitized producer frames. Earlier pins below
record historical stages, not authorization to pair this consumer with d00.

This producer retains the 2b31d199 revision's explicit requested native interaction policy
under the existing serialized credential-read guard and checks restoration of
the exact prior policy. Noninteractive reads and credential writes retain their
existing behavior. Its bounded failure-only stderr diagnostic is not a new
management response or shipping UI feature; production stderr remains discarded.
Only exact Store metadata URLs with a previously validated single ASCII asset
path may be upgraded from HTTP to canonical HTTPS, with the same asset.
Explicit ports, credentials, queries, fragments, other hosts and wrapper URLs
remain rejected. Consumer URL validation and image fetching are unchanged.
Public fixture confirmation establishes this source format only, not the cause
of the earlier 20 actual history rejections. Optional closed rejection-shape
counts on stderr expose no URLs, assets, account identifiers or query values;
they are not management responses and remain discarded in production.
The controlled 113be57/c1073100 pair was Release-qualified, independently admitted
and installed after exact consumer CI
[37502060591](https://github.com/dragoshont/xodus-macos-app/actions/runs/37502060591)
passed. It is not a distribution release.

Actual artwork confirmation on 2026-10-06 used consumer
`113be57c7ceba230bc9252585bd98e4ce1679fa4`, tree
`868cac2bdae2691b185b7bff400c35d0672c9053`, and this producer. Package receipt
SHA256 is
`e0b19abee839821b35feaad3e486932642c92351942b28b44a463263ef5b71b2`;
the signed CLI SHA256 is
`c8fe69a3bc2b6a84c5bad5ef0c1ae041f36466a87419c0f17d9567c6df3ed14d`.
Stable local certificate `6C5F1CD832A2B2842686245B4DEF219BB8B465B2`
and fixed app/CLI/helper identities are unchanged.
One foreground saved-status request returned current `credentialPresent`,
then one recent request returned 20 live/partial titles. Artwork counts were
available 20, absent 0, rejected 0, notQueried 0; all 20 preload references
succeeded, with zero failures. Reference success is not a unique-HTTP-request
count. One actual Library image was retrieved and visually confirmed, showing
real title artwork and a featured tile, not an invented hero-role image.
No public Store query, authenticated verification or Account render was repeated.
This closes the observed history-art gap without establishing owned inventory,
package access, installation or Mac compatibility.
Normal Quit released the old owner without forced retirement. The complete
working 4e bundle and all earlier rollbacks were preserved; the profile and
saved credentials were not copied, deleted or reset. The reopened shipping
app matched all 21 admitted files and owned one matching engine with no helper.
Personal history remains memory-only: the private export never populates the
newly reopened shipping session.

### Foreground Library loading

The new consumer source defaults to Library and owns one automatic load per
management connection, admitted only while the app's Library is active and the
connection is ready and no longer transitioning. It checks saved status once
only when unconfirmed, reuses a fresh credential-present result, and conditionally
requests `library.recent` with limit 20. It never begins login. The session-owned
task survives ordinary view-task cancellation and navigation; repeated entry
joins an existing attempt or stops after the consumed generation.

A single account busy lease spans status and history. Connection retirement
cancels the owned task and prevents late publication. An explicit Account check
still clears identity-unbound history and does not silently reload it. Library
shows the actual checking/loading stage, distinct safe failure copy, and an
explicit retry that rechecks access only when it is unconfirmed. Signed-out,
expired and invalid results offer Account without requesting history.

Successful list publication emits only `stage=recentlyPlayed` and its public
numeric count through native OSLog. Successful network image decoding emits
only `stage=imageDecoded count=1`; cache hits are not additional decode events.
Neither event contains titles, identifiers, URLs, profile information or wire
frames. These aggregate events can be bound to the exact installed app PID
without a debug/export API or another personal request. Production engine stderr
remains discarded. The signed c107 engine, schema, artwork policy and saved
profile are unchanged.

Actual shipping confirmation on 2026-10-06 used consumer
`7aa9eb9de094c5f96233a6e99fb08b48c61fc92a`, tree
`bc23e93f4e0de2a870616bf2a18ba325666bc0ce`, after exact CI
[37509107895](https://github.com/dragoshont/xodus-macos-app/actions/runs/37509107895)
succeeded and independent source/package admission passed. Receipt SHA256 is
`b36305e73a4b0aa4fd779582089f716d3f368e86049582d0d06975626bc61035`.
The signed c107 CLI remains byte-for-byte
`c8fe69a3bc2b6a84c5bad5ef0c1ae041f36466a87419c0f17d9567c6df3ed14d`,
reused from the previously admitted e0b package through the existing
signed-CLI preservation path, without rebuilding or re-signing the engine.

One normal Quit released the old owner. Atomic replacement preserved the full
working 113 bundle, prior rollbacks, profile and credentials. One ordinary
foreground launch of the actual shipping app published **one** recently-played
list with **20** real titles after the guarded saved-status/history sequence.
The same installed app PID emitted **12** successful actual image-decode events.
These are decode observations, not 20 unique HTTP requests or proof that every
offscreen image loaded. All 21 installed files and strict fixed signatures
matched admission; the app owned exactly one unchanged matching engine and no
sign-in helper. **That same populated shipping process was left running.**
No private exporter, extra personal RPC, relogin/reset or reopen was used.
Only fixed stage/count events were read, and only aggregate proof was retained.
The earlier private-export evidence is not reused as proof of this flow.
Recently played remains live/partial activity, not authoritative owned-PC
inventory, installation, package authorization or Mac compatibility.

### Explicit recent-title Store search

The next source slice adds a native "Find in Store" action to the existing
recent-title feature and grid. The action routes only the actual title name as
the Discover query and clears any stale product-sheet selection. It sends no
request itself: the existing user-directed Discover search task, capability
gates and bounded/coalesced client perform the catalog search. Results remain
unmapped catalog candidates until the user explicitly selects a product.
No product/edition identity, ownership, installation or playability is inferred
from the history entry. Navigation and catalog search do not refresh Account,
reload personal history or alter its fences. Stock buttons support keyboard
activation; title-specific VoiceOver labels remain separate reachable children.
Artwork sizing, tokens and the current native composition are unchanged.
The action's routing and explicit candidate selection were qualified with
425 native neutral session checks, unchanged portable pair gates, direct source
review and exact successful CI
[37512166260](https://github.com/dragoshont/xodus-macos-app/actions/runs/37512166260).
Genuine empty/error responses stay distinct, and these tests confirm no
additional saved-status or personal-history read during title-name navigation.

The controlled consumer
`0a6dca1751576e2484b1f7606c174ae1cc5970c4`, tree
`b3e5c846f41dd95ab3e7c0f1881f4967224c803d`, was independently admitted and
installed after that exact CI passed. Receipt SHA256 is
`9ed8f5ea70818c803be4fd711aa0cd75505ecaa43f7ee6d88eecb670099fe51a`.
The existing preservation path reused the exact signed C8 CLI from the admitted
b363 package; producer c107, schema and stable signing identities are unchanged.
One normal Quit released the old owner, and atomic replacement preserved the
entire working 7aa9 bundle, all earlier rollbacks, profile and saved credentials.
One ordinary new shipping startup published one real recent20 window and
12 successful actual image-decode events. All 21 installed files and strict
signatures matched admission, with one parent-owned matching engine and no
sign-in helper. The same populated shipping process was left open with the
native action enabled. No private exporter, automated title-name Store search,
extra proof RPC, relogin/reset or subsequent reopen was used. The action's
actual public search remains for the user to invoke; neutral route tests are
not misrepresented as a personal live-query result. Installation, package
authorization, owned-PC inventory and gameplay remain separate unfinished work.

### Earlier saved-status and history confirmation

The earlier controlled 4e20427/2b31d199 pair was independently admitted and
installed after exact consumer CI passed.
The earlier fb39072/680 pair proved real public Store artwork, but personal
history was not accessed: its captured foreground status reads failed with
`credentialStoreUnavailable`. No successful permission or TitleHub read is
inferred from source changes or neutral checks.

Actual confirmation on 2026-10-06 used consumer
`4e204270550f2f83082e7562187f8619b777fc05` and producer
`2b31d199a3be15422596b46bc70e0926df30b539`, with stable local
certificate `6C5F1CD832A2B2842686245B4DEF219BB8B465B2`. Package receipt SHA256:
`91e2adf68c0c224fe5a123d5fb19c3565fb75c706be22072d03403a2521e6269`.
The actual signed CLI was
`67b6de5ec1c56316313d6901a3beaa71857c782c1cd036fc19e08c209c8ae00a`.
One foreground `auth.status` returned current `credentialPresent`, followed by
one `library.recent` request with limit 20 returning 20 real titles. This is
recently-played/live/partial evidence, not owned-PC inventory.
Artwork metadata counts were available 0, absent 0, rejected 20, notQueried 0.
No history image fetch was attempted: zero approved references is not fetch
success. No unsafe host or URL policy was broadened to obtain covers.
Actual native Library and saved-Account images showed the real results and
honest artwork fallbacks. Earlier anonymous Store cover/hero confirmation is
reused, without another public query or authenticated verification.
The reopened shipping app matched every admitted package file and owned one
engine with no sign-in helper. Full fb and earlier a8/397 rollbacks were
preserved; saved credentials were not copied, deleted or reset. Retirement of
the earlier fb app and its exact parent-bound engine used explicitly authorized
SIGTERM after normal Quit failed, separately from the atomic installer.

Every product and recent title requires the same max-four unique-role artwork
array and explicit available/absent/rejected/notQueried status. Positive,
paired dimensions are bounded to 8192 on each axis and 16,777,216 pixels;
all-null dimensions remain unknown. The native client enforces the pixel
product as well as the schema. An archived pre-artwork public test capture is
explicitly version-migrated to empty/notQueried; the live decoder never silently
adds missing fields.

The shared Foundation/ImageIO loader admits only
`https://store-images.s-microsoft.com/image/<single approved ASCII asset>`.
Redirects, URL credentials, HTTP authentication and cookies are disabled.
Each transfer is bounded to 10 seconds and 8 MiB; actual dimensions are checked
before a maximum-2400-pixel thumbnail is decoded off the main actor. Rejected
transfers are cancelled. The shared decoded cache is memory-only and bounded
to 40 images / 64 MiB. No covers, account identifiers or personal history are
saved to disk or sent to a third-party art service. Fetch failures are visible
placeholders, not mutations of metadata status.

`library.recent` is a separate negotiated read: limit 1-100, TitleHub v2,
recentlyPlayed/live/partial, null cursor and null Store product mapping.
The UI requests one 20-title window only after explicit saved-status confirmation
and a user history action. Startup, successful status refresh and sign-out
never automatically query history. The producer performs its bounded 2-second
NOUI saved read and publication witness inside a 30-second operation; it does
not invoke a helper, persist refreshed proofs, acquire a license or begin login.
Six exact failure-stage tuples become safe local actionable errors.
Personal data remains in memory, generation-fenced and separate from
ProductEvidence/installed snapshots. Explicit Account refresh clears personal
history before reading: credential-present status exposes no user/profile
binding, so "same profile" cannot be inferred. Failed/unconfirmed credentials,
profile change, sign-out and disconnection also clear it. PC filtering uses the reported platform
classification, not Xbox history as blanket PC compatibility.

The private nonshipping admitted exporter performs one actual recent-history
read after foreground Account confirmation, preloads only accepted metadata art
and renders the shared Library component without repeating the earlier public
Store query or Account image. A valid zero-title result renders an honest empty
recent scope. Private own-view images contain no XUID, email, raw responses or
secrets. Development-only stderr capture admits only the producer's closed,
at-most-512-byte failed-read diagnostic or rejection-shape aggregate.
The latter exposes only fixed scheme/host/path categories and known query-key
counts, never URLs, assets, unknown key names or query values; 69 neutral capture
checks passed. Production stderr handling remains unchanged. Own-view renders
are not compositor or VoiceOver certification, and neutral checks remain
separate from actual account/history evidence.

## Implemented client and native surfaces

`Sources/XodusManagement` implements exact protocol 1.0, request IDs, schema validation against the producer's pinned schema, typed capability objects, bounded UTF-8 JSONL and a supervised native `Process`. It never scrapes interactive output or uses runtime-service IPC as management.

Each request is correlated to its expected command-specific result definition. EOF, malformed/truncated/oversized frames, wrong IDs/shapes, unexpected major/minor, timeout and nonzero exit invalidate the connection; exit zero cannot supply a missing result. Output/event buffers and outstanding requests are bounded. stderr is drained and discarded with a byte limit, not retained as diagnostics. Error messages shown by the app are generated locally from validated error codes, not raw upstream text.

Closing the client first closes stdin for owned-child cleanup, waits for the engine to exit and release its state lock, and applies bounded signal escalation to that exact owned process if needed. Reconnect does not race the old process's lock. The app does not stop another runtime or game.

`LiveSession` and the native views implement a real default development shell: account status, explicit sign-in/cancel/logout actions, scoped partial catalog, edition detail, catalog-check cancellation/retry and authoritative activity snapshots. Native sign-in is backend-owned; the Swift app never receives tokens, redirect fragments or raw provider errors. Optional agreed flow metadata is consumed only through the bundled producer schema and negotiated capabilities. New sign-in is always an explicit user action, never startup or a test action.

Anonymous startup does not read the Keychain. Account initially remains unchecked;
explicitly opening Account requests a foreground saved-profile check. The paired
native producer may show macOS's ordinary Keychain permission prompt. Only the
human handles that prompt; the app does not collect or type its password.
**Check status** remains available during pending sign-in. A new sign-in requires
fresh, confirmed signed-out status; expired/invalid profiles instead expose a
confirmed launcher-only disconnect. An unavailable store never causes deletion.
When Keychain access fails, Account shows the error outside the collapsed
Account info section and explains why Sign in remains disabled. The typed status
failure clears only after a successful status response or disconnection; a
previous saved snapshot is not fresh evidence. Check status and Sign in retain
native Button accessibility and enabled-state semantics, without substitute
accessibility actions. Resolving a denied saved-item permission or choosing to
reset saved sign-in remains a separate human decision: this UI correction adds
neither an interactive Keychain command nor an automatic reset.
Terminal sign-in errors are latched in the current app session before account
state is replaced. The latch contains only a known error-code enum, validated
native-consent stage/reason and an exact allowlisted observation; unknown failures
show an unavailable stage. Last sign-in error is always outside Account info and
retains its accessibility identifiers across signed-out/no-flow refreshes and
client disconnection. A completed flow clears it. It is not written to disk and
does not survive quitting the app. No raw failure, provider text, account/flow ID,
token or pending-exchange credential is retained in this snapshot.
The original GUI startup
was observed to time out specifically in `auth.status`, despite the equivalent
SSH read failing promptly with `credentialStoreUnavailable`. Removing that
automatic read preserves anonymous browsing without approving any native consent.
The foreground status request has a 130-second client budget around the producer's
120-second human-permission budget, without blocking public dispatch. One native
busy gate prevents duplicate status requests and account mutations during the
check. Freshness is invalidated before the read, and a late retired-generation
result cannot restore it. A denial remains an explicit error, not signed-out
evidence or an automatic permission retry. A new locally signed development
engine may require its own approval even when its designated requirement is
unchanged. OSLog records process start, negotiation and the canonical command
name on timeout only; no paths, arguments, IDs, credentials or upstream messages
are logged.

Sign-out clears account-bound UI evidence before the operation and is shown as signed out only after the backend confirms removal. Engine/Keychain errors remain errors. A transport failure invalidates credentials/evidence in the UI rather than silently falling back to invented games.

Human-interactive `auth.begin` preparation and `auth.logout` have separate finite
600-second transport budgets; ordinary reads retain 30-second defaults. A
mutation failure invalidates the pre-mutation account freshness and never causes
a blind retry. Pending flow reconciliation survives transient unavailable-store
responses only after an explicit status request when Keychain access failed;
retryable network responses remain reconcilable. A rejected cancellation during credential commit resumes
polling with the original monotonic deadline instead of claiming cancellation.
Terminal flows cannot regress to a late pending snapshot. At deadline, the app
asks for current status rather than manufacturing a terminal outcome.

Discover now requests one bounded public **pcGamePassDiscovery** page at a time from the official Microsoft PC Game Pass feed. Request market/language, cursor and corpus revision remain bound together. Successful public products also seed **observedPublicProducts** checked-catalog
title search, which remains distinct from real **catalog.query** network search.
The latter uses Microsoft's public Store Edge search with source-backed PC product
checks, exact query echo, scope-bound opaque cursors and visible per-item failures.
Native input is explicitly trimmed before sending; duplicate identities and
contradictory product/edition scope are rejected without merging same-title IDs.
This public catalog cannot promote entitlement from unknown. Catalog checks are
not game downloads; the activity UI names their actual operation.

Each attempted page item is either a product or a visible lookup failure. An
all-failure response remains an error: only command-correlated
`failedDiscoveryData` / `failedQueryData` is retained, validated separately from successful discovery
whose products cannot be empty. No arbitrary error payload or raw upstream message
is displayed. Continuation remains visible even if every item on the first page
failed. A genuine zero-source query is distinct from failed metadata checks.
Stopping search fences late results but does not claim to abort HTTP.
Catalog requests are coalesced into one active request and one latest queued
query/market/language scope. Cancelling a view task does not free a producer
operation; newer input replaces the queued scope, and stop drops it. Pagination
retains its cursor/failure semantics. Source-level `PACKAGE_UNAVAILABLE` without
batch details stays a recoverable typed error; present malformed/null details
remain protocol failures rather than being silently discarded.
The native request allows 45 seconds around the producer's
30-second whole-page budget; there is no full-feed crawl. Requested locale remains
the cache scope; exact language is preferred, or an explicit same-base neutral
`resolvedLanguage` is shown. Unrelated/regional fallback is rejected.

Activity snapshots fence a bounded set of incoming events until the authoritative
watermark is applied, then replay newer buffered events in order. A gap triggers
a bounded snapshot retry, not a guessed queue state. Failed reconciliation retains
previously verified jobs as non-current and disables cancellation/retry until
the current snapshot is established.

The client retains typed `installed.snapshot` wire responses, but the current
producer returns a constant empty vector: no populated durable registry or Mac
scan is implemented. Library explicitly remains unavailable and product detail
keeps This Mac as Not checked. Empty responses are not evidence that no games
are installed; failed refreshes retain only non-current wire snapshots.
Public catalog `notInstalled` metadata is not treated as a whole-Mac installation
scan. User-selected, read-only inspection now uses `installed.inspect` through a native
directory-only picker with alias resolution disabled. The result must echo the
selected path exactly and stays separate from the managed registry. The producer
reads only 196 non-key metadata bytes (156 + 40) from the exact marker; header
GUID/PDUID/contentID are not Store product/edition/package IDs. Missing, aliased or
malformed markers produce explicit errors. No scan, adoption, game-file integrity
claim, entitlement promotion or launch occurs.

## Producer pin

### Separate runtime configuration consumer

Native Settings now share a bounded four-provider section with fixture Settings.
`RuntimeProviderSettings` holds in-memory declarations with initial nil selection;
its action uses `RuntimePlanClient`, not `LiveSession` authentication or C95.
Required nullable fields are explicitly encoded as JSON null. The client uses
the selected trusted executable's sole `runtime-plan` argument, filtered
nonsecret environment, nonblocking pipes, explicit stdin EOF, finite deadline
and exact-owned-process cleanup. It validates strict unique JSON keys, canonical
schema, configuration echo and configuration-hash/generation path correlation.
Nonzero exit discards even valid-looking output. Pending cancellation cannot
publish a late plan. No component path picker/inspection, provider launch,
prefix creation, save reuse, install/play promotion or production-engine trial
is included.

Normal application termination now fences new planning/connect requests and
awaits both management disconnect and runtime-plan cancel/cleanup/reap through
one shared coordinator. A missing management connection never bypasses the
planning shutdown. Failure refuses Quit with explicit state and permits
reconciliation/retry, rather than abandoning an owned process. The normal
coordinator is checked using actual neutral children, without an NSApplication
Quit event, GUI manipulation or production engine.

Source producer is independently frozen
`9ef0f298481fb48840734b538e0f6d22e1c98ff3`; schema LF SHA256
`90c094e4585af059b5ebcfc3201260362e88aa642b50ec0388a03427260d55e9`
and fixture SHA256
`76a0d791c99a6c77e12581a4361dbe6e37a0dbd29f2e556ef292bbbc360bc40c`.
The schema is a separate bundle resource; C95 and the reviewed Swift auth-host
source remain unchanged. This integration is source/headless only, not deployed
or a claim of any installed/runtime/game qualification.

The current producer pin is public commit
`d00a8b97501a2ce1045d579e62568c5feb017ca8` in `dragoshont/xodus-macos`,
branch `dragoshont-xodus-launcher-management`: 88 positive, 47 negative and four
independent evidence-edge frames. This additive contract includes public
`catalog.query`, read-only `installed.inspect` and explicit `auth.verify`; capabilities are negotiated from the running producer, not
copied from a fixture.

This producer retains the schema and fixtures unchanged. Foreground `auth.status`
restores ordinary native Keychain read interaction with a bounded 120-second
worker; its permit remains held until the OS call actually returns, including
after timeout. Discovery remains responsive. Active sign-in polling and explicit
`auth.verify` retain deliberate bounded noninteractive reads. A native permission
approval is not a new Microsoft login or an entitlement result.

Canonical committed schema SHA256:

`5b588ae7339a11850339e4979ebd14a577f37e2c8d94e02dab85969d3400c544`

`auth.verify` accepts only a canonical content UUID, returns exactly
`{"verified":true}`, or one of seven strictly matched safe failure stages. It
performs no automatic retry, sign-in, account refresh or credential write.
Success proves only an authenticated package read, not ownership, installation
or a license. No authenticated live outcome is claimed until the matching pair
is independently admitted and its single explicit probe completes.

Committed LF bytes and all four sanitized fixture hashes were independently verified from immutable public Git objects. A transient GitHub network outage was handled with that exact public-only fallback, not mutable backend source or private data.

`docs/contracts/management-v1.schema.json` is the producer's canonical scoped schema. `tools/sync_contract.py` copies its exact bytes to the Swift resource. `Tests/ManagementChecks/Fixtures` contains its sanitized public positive/negative/evidence fixtures. No private backend source or real account payload was imported. `foundation-v1.schema.json` preserves the original proposal.

The current deployed development engine source is reviewed public
`e7e61fa820b771099fd90516ccaca056f265966d`, paired with app
`e5a573aaca94f4cee46f591f9f927fcd0df0f782`. Its immutable unsigned input
SHA256 is `304c249ae24fc187533865ebb3d61cd40cec812629c537692e009f54bec22349`;
the separate signed copy is
`4d04fd6c98478574f8b0413de3a2422cebf66dce9c72357629c38cf02e2dbf32`.
The app executable is
`97e423985d1e5193db2cd80b6f2aa9ce546cc167d91ec2337a4653f3dc0bfabe`.
The Swift executable came from a verified native **release** stage; the Rust
engine is an offline/locked **default-dev** build, not a Rust release.

This producer corrects an unsupported local decoding predicate: original
Passport request builders forward the issuer's opaque ticket representation,
while the distinct proof key and SOAP cryptography still require strict
validation. Bounded/reparsed/nonblank ticket, kind/context/expiry, isolation,
cancellation and atomic-commit checks remain. Two native regressions failed
before the correction and passed afterward; 59 selected native checks passed
in one bounded run. These are not captured provider-format or authentication
success evidence. Same continuity review closed the exact combined source.

One owned native authentication window was subsequently observed. The flow
was already active before an agent Sign in guard, which refused before AXPress;
activation source is unknown and no duplicate entry was sent. Human completion
and credential commit are **not verified**. Sign-in and deployment are now user-paused; current window/worker presence is
not re-inspected or inferred. No agent navigation, approval, credential entry,
polling or restart is authorized.
The subsequent bounded native UI source correction is separately staged only;
it does not mutate that deployed app, engine or authentication flow.

The preceding reviewed eighteen-pair diagnostic engine source was
`2acb452a7ee66b2c9d3ad75ecf85e2be2f94fbc3`, paired with app
`5ae30fd4bd4e17cb235857e5c41fba1627c317f7`.
Preserved immutable input is `xodus-cli-xml-proof-v1-8a4b8d56aad18841`,
SHA256 `8a4b8d56aad18841326834e5ad57860072560f4739963323875ffa52d41a545b`;
the separate signed embedded copy is
`125a05dd0a2a577cc8fc71e4d3eaf324b9c70b3d409a54fd5b0eeef17ad45cf4`.
Deep signature, exact C95 resource/provenance, fresh parent/child ownership and
nine actual read-only checks passed. This is a local development pairing, not a
certified runtime or successful sign-in. The previous bace/da0 342/5d and
e604/360e8bf 47f/c50a pairings and all older immutable inputs remain preserved.

The historical first human-entry engine source was
`2a47eafc930603773583ce4c1d6be89a2f0ccd60`. Its preserved unsigned input is
`xodus-cli-soap-nonces-v1-57d4500d6de922d6`, SHA256
`57d4500d6de922d644071ff6749b662c56d75f5f4646da2a884a363169373c0b`;
the separate ad-hoc-signed embedded copy has SHA256
`7a6edd58efa81f567ebf7ecc8c7cf089fb7fc155533e2db28ab797111ec2230d`.
C95 schema/operations are unchanged. This is a necessary correction on the real
Store authentication decoder path: duplicate or empty derived-key nonce IDs
are rejected rather than silently overwritten/accepted. The producer pin was
confirmed by the backend before the user-directed retry; no unsigned sealed
artifact was changed. Historical e3129/da548, signed2180 and 57d/signed7a6e pairings are preserved,
not reused as the current diagnostic build.

It retains the reviewed public search/inspection behavior. The source-only app
R01-R04 fixes closed at `fb66a2d`, R08/R09 at `6750219`; the `db0bf21`
picker/consumer delta had no significant issues. Subsequently confirmed R10
shared-retirement fixes closed at `f967f5c` in retained report 13, with no
significant diagnostics issue. Separate backend R11 source closure followed in
report 14. The source/UI hold is cleared; human provider consent and the full
game journey are not completed or inferred. Historical producer
hashes, including superseded `58f5` and `35f0`, remain in
[verification](VERIFICATION.md); they are not current readiness builds.
**Provider consent remains separate from read-only/schema/build verification.**
No successful account login is claimed merely because the native UI compiles.
The user-directed retry activated the exact enabled native Account sign-in
button once through AXPress, using `auth.begin`. The app subsequently displayed
its fixed failed-flow message, not saved credentials or successful sign-in.
No Microsoft credentials, code, consent or Keychain decision was automated or
read; there was no automatic retry. The flow's failure needs further diagnosis.
The retry build's generic label does not expose its in-memory optional error,
so no exact failure code/stage was recovered. A subsequent source-only native
correction shows validated flow failure codes with local wording, never raw
messages, and explicitly preserves unknown stage when evidence is absent.
No debugger/status call/retry was used to recover that old tuple; its cause
remains unknown. The later reviewed diagnostic source was separately deployed,
not injected into the original failure.
The subsequent diagnostic-only source agreement closes the optional details to
ten exact AUTH_INVALID stage/reason pairs, mapped to local guidance; unknown,
extra or incompatible values remain unavailable stage and are not retained or
rendered as diagnostics. See [the exact object](BACKEND-CONTRACT.md).
Final original diagnostic source `360e8bf` passed 333 full checks and hosted CI.
The successor continuity reviewer closed that app/producer delta with no
significant issues; the cancelled original reviewer supplied no report 40/41
approval. The user-directed close/relaunch used only the verified idle owned app.
At verification the new pair was app 92655 / child 92660. One new agent-mediated
native entry returned `AUTH_INVALID/devicePreparation/providerProofInvalid`.
That legacy classification does **not** establish a cryptographic failure:
it covers an unsupported device response or absent/invalid proof. No successful
credential commit, Microsoft UI observation or owned-library proof was inferred.

The subsequent source batch replaces bespoke navigation with a system toolbar,
corrects that local proof wording and adds four agreed static device reasons
(fourteen closed pairs total). The coordinator's same continuity review closed
that app delta and the backend response-wrapper refinement with no significant
issues. Exact app source passed 353 hosted checks; the producer passed its 45
native checks and qualified gates before sealing. The reviewed pair was then
deployed after fresh idle-flow guards and graceful exact-owned quit.

One user-authorized native entry on the new pair returned
`AUTH_INVALID/devicePreparation/tokenStructureInvalid`, with the visible
"Microsoft sign-in could not start." explanation. No pending Cancel control
or auth child remained at observation; an owned native authentication window
was not observed. The particular structure guard is still unknown. No raw
provider data, credentials or OS decisions were inspected or automated.
The next concrete backend fix remains separate from source-review closure;
the unchanged failing engine is not repeatedly retried. Exact hashes,
historical local failures and independently passing evidence are recorded in
[verification](VERIFICATION.md).

### Reviewed static token subsites and observed cipher failure

The coordinator and sole consumer explicitly agreed four additive
`devicePreparation` reasons with the producer before implementation:
`tokenKindInvalid`, `tokenAudienceInvalid`, `tokenCipherInvalid` and
`tokenSecretInvalid`. The consumer retains all fourteen older pairs, including
coarse `tokenStructureInvalid`, and accepts only the exact three string keys
for `AUTH_INVALID` / `nativeConsentFailure`. Static local copy explains only
unsupported format, unmatched context, unprocessable payload or missing/invalid
proof; no values or assumed provider/cryptographic cause are shown.
The complete 398-check app suite passed locally and in hosted CI. The same
continuity review closed both source deltas, and the producer passed 54 native
checks before sealing. Deployment preserved originals and separately signed the
copied engine after fresh idle-flow guards and graceful exact-owned retirement.
One authorized native entry on app 41090 / engine 41093 returned
`AUTH_INVALID/devicePreparation/tokenCipherInvalid`, with zero pending Cancel
controls, progress indicators, owned auth children or observed auth windows.
The particular bound/parse/encoding guard is still unknown; a parser regression
does not prove the live proof contained whitespace.

### Agreed minimal cipher subsites (source only)

The coordinator and sole app explicitly agreed only `tokenXmlBoundInvalid`,
`tokenXmlParseInvalid` and `tokenCipherEncodingInvalid` before implementation.
All eighteen older reasons remain accepted, including coarse `tokenCipherInvalid`.
Exact keys, AUTH_INVALID-only gating, C95 and lifecycle behavior remain unchanged.
Local copy reports only a supported processing limit, unreadable required format
or unprocessable encoding; no numeric limit, data or assumed crypto/provider
cause is shown. This twenty-one-pair source batch does not relax token acceptance.
The historical source-only phase left 8a4b/125a untouched. Later same-reviewer
closure and native gates authorized the baf/e5 diagnostic pairing, followed by
the e7/e5 admission correction recorded above. The twenty-one diagnostic mappings
and all authentication lifecycle behavior remain unchanged in the current UI
source correction. Live visual verification and authentication/deployment are
paused. Source work does not imply approval to act on an existing window.

## Bounded native UI source correction

Live and fixture views share the existing native search editor/bindings with
standard `NSSearchField` appearance and clear control, without a custom capsule
or forced dark/white search styling. Following the latest user-directed header
revision, compact search now shares the principal toolbar group with navigation
instead of appearing inside the hero. Command-F continues to request its editor.
Real macOS 27 `.tabs` uses a segmented 14-26 fallback; source requires SDK 27+.
Original artwork extends behind system chrome, notices move into content, and
the visible title is hidden without discarding window/menu/Dock identity.
Account separates scrolling status/explanation content from one adaptive action
footer; a bounded sheet shrinks decoration before controls. Existing auth
predicates, identifiers, cancel/dismiss safeguards and Account refresh remain.
The Scene owns the hidden-title-bar/unified toolbar; redundant post-creation window
overrides and unconditional legacy activation have been removed.

Headless presentation checks allocate only detached native controls and
synthetic layout views. They do not instantiate the Account flow's refresh task,
show a window or contact an engine/Keychain/provider. An additive isolated
native release stage is not a signed/packaged/deployed app. Both-appearance,
compositor, preference, resize and assistive-technology confirmation remain
pending; source/framework/AX-role evidence is not visual conformance.

## Dedicated Swift native authentication host: source only

`XodusAuthHost` is a dependency-free AppKit/WebKit/Foundation SwiftPM executable,
not a second management transport. The private contract and neutral corpus are
pinned to public producer `bb6397033fc38497a73684a9ecdb2929caba1f63`;
schema SHA256 is
`c7ca7de8ee8a610b71e9e458f13469554467dd2632f88d35317a1ce2646af430`,
fixture SHA256
`d864e96079dc5292f6c078fb2be37c870f1cf4be114edc6e68e0984a555d0d24`.
It uses an anonymous inherited socket, strict bounded correlated frames,
the original remaining monotonic budget, a fresh nonpersistent WebKit store,
trusted main-frame/origin/document-generation checks and one-shot exact
seven-string legacy handoff. Native callback, genuine navigation, renderer,
checked-JS, close, EOF and deadline failures are explicit static outcomes.
Closing the owned native window, including `NSWindow.close()` paths that bypass
`windowShouldClose`, sends one terminal cancellation and exits the helper.
Unrelated windows do not cancel the attempt. The app reconciles the terminal
flow through `auth.status` and enables an explicit new sign-in; it never retries
automatically or treats closing a window as saved credentials. Neutral checks
exercise hidden AppKit window closure, private-channel EOF, helper exit and the
following user retry without contacting Microsoft.
The additive navigation correction permits all subframe loads, scoped HTTPS
Microsoft top-level redirects and same-view popups without treating ordinary
cancellation/policy interruptions as whole-flow failures. Blank popup initialization
does not replace the current document. This fixes identified brittle handling,
not a diagnosis of the previous brief-window failure.
Rust retains SOAP/proof processing, helper reaping and atomic credential commit.

The source-verified notification compatibility correction mirrors the original
handler's tolerance. Known `getContext` invokes may include unused `args` or other
keys; unrelated notifications and non-JSON strings are ignored. Flat or wrapped
provider DA objects may contain extra keys, but only the seven required strings
enter the unchanged strict `LegacyDA` and private result. A claimed malformed DA
still fails. Untrusted frames/origins receive no callback or DA delivery and do
not terminate the flow. Private wrapper shape, control generation, document nonce,
one-shot delivery, frame limits and writer/commit gates remain unchanged.

The finish-script compatibility correction also handles the original handler's
flat `ServerData`, not only `ServerData.DAProperty`, while forwarding only the
same seven string fields. Known context dispatch preserves the original window
receiver and serialized string argument. These are script-shape and call-semantics
corrections, not broader origin trust or a successful authentication claim.

The compatible producer observation uses the existing failure message only:
`Native sign-in failed: helper.REASON.` with the closed reasons `invalidFrame`,
`invalidNavigation`, `navigationFailed`, `popupUnsupported`, `contentTerminated`,
`javaScriptFailed`, `bridgeInvalid`, `deadlineExpired`, `parentUnavailable`, or
the exact `Native sign-in failed: channelEOF.` / `Native sign-in failed: unclassified.`,
or the fixed boundary messages `Native sign-in failed: tokenExchangeFailed.` /
`Native sign-in failed: helperCompletionFailed.`. These identify failed operations,
not provider error text, and never establish credential commit.
The additional `tokenExchange.STAGE` literals are limited to `requestBuild`,
`requestSerialization`, `requestTransport`, `requestTimeout`, `httpClientError`,
`httpServerError`, `httpStatusRejected`, `responseParsing`, `responseSignature`,
`responseCryptography`, `responseEncoding`, `continuationRequired`,
`faultWithoutContinuation` and `continuationRejected`. The exact
`Native sign-in failed: exchangeRetentionFailed.` is also accepted. No unknown
stage, prefix match, extended message or provider exception is displayed.
Account Details accepts these exact strings only with the existing
`AUTH_INVALID / nativeSignIn / pipelineFailed` tuple; all other message text remains
undisplayed. No new wire fields, logs, provider content or secret-bearing diagnostics
are introduced. Qualification and a fresh signed producer/consumer pair precede any
new live sign-in attempt.

Configuration binds a fixed owned bundle executable, protocol version and
SHA256 through nonsecret flags. A packaged `.app` missing both helper and receipt,
an incomplete receipt pair or an invalid helper fails before engine launch,
with a static helper-specific recovery message and without PATH selection.
Unpackaged anonymous/developer checks may still omit the binding. This local
helper check does not qualify the selected engine or attest its source.
The packaging script includes the shipping helper and post-sign metadata from
clean source, but this new revision has not been executed. Private synthetic
host-check resources are excluded from the shipping source/resource set.
The deployed e7 producer lacks the new concurrent engine-EOF guardian; the
paired producer must implement it through issuance, cleanup and publication,
then pass the agreed engine-only death/write-half/race tests and combined review.
Matching C95 alone is not this pairing gate.

The reviewed producer is `9ef0f298481fb48840734b538e0f6d22e1c98ff3`,
including auth producer `94353b5cc3196a2b73b89655855ec50c31d35b81`.
The old e7/304 engine does not support the three native-host flags; omitting them
selects its old legacy path, not the new Swift host. HELLO's supported auth
capabilities, version and C95 hash do not establish this producer pairing.
`XODUS_BACKEND_PATH` and the explicit developer engine picker are nonshipping
only. Shipping has neither override and cannot borrow bundled helper evidence.

The new [controlled local admission](SHIPPING-ADMISSION.md) tooling verifies
externally pinned unsigned CLI/provenance and exact source/tree/profile/features,
then separately signs and generates compiler-bound signed engine/helper pins.
The runtime rejects missing/mismatched pins, helper receipt source/version/hash
and nonfixed paths before execution; pure planning shares this boundary.
The committed pin template is nil, not an arbitrary-engine grant. This is the
approved external operator gate made enforceable for one local pair, **not**
generic distribution attestation. The older owner's sealed e7 provenance is
not evidence for943/9ef. Do not reuse304/4d04,
infer source from HELLO or a binary hash, or fabricate a seal. Build only in a
new isolated canonical-Git stage, verify the final helper receipt/hash/version,
resources and complete bundle, and preserve the prior app as rollback. A verified
pair is launch readiness, not successful authentication.

Detached synthetic WebKit/channel checks are not a provider trial, OS passkey
association, biometric-prompt diagnosis or authenticated/committed account.
Apple's [Supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys)
requires an associated domain for WKWebView passkeys; migrating this legacy
flow to Swift does not establish Microsoft association. Apple's
[public-key-credential browser entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
is an approved browser capability, not an ad-hoc launcher fix. Unknown passkey
eligibility is not a reason to block a possible password/code flow, change client
IDs or disable MFA. The reported prompt's cause remains unknown.
Production stdio is discarded and core dumps are disabled where possible;
OS crash-report suppression is not promised. GUI focus/input/capture/inspection
and deployment remain paused while the user's game work owns the desktop.

## Developer application

Only after explicit desktop/CPU release, source/paired-artifact approval and
fresh owned-process checks, in a new isolated canonical-source stage:

```sh
sh tools/check.sh
sh tools/build_app.sh /absolute/reviewed/engine UNSIGNED_SHA BYTES PROVENANCE_SHA PROVENANCE_BYTES APPROVED_APP_COMMIT APPROVED_APP_TREE /absolute/owned/output --signing-identity CERT_SHA1
```

The script reports a new distinct bundle and external package receipt; it never
opens a window or replaces `dist/Xodus.app`. Launch requires separate approval.
The supplied exact fingerprint must match an existing code-signing identity in
the OS Keychain; a local self-signed identity need not have global OS trust for
the fixed-leaf requirement. Provisioning and private-key prompts require separate
human approval. Fixed signing identifiers,
artifact-level designated-requirement comparison, the separate requirement for
independent approved build evidence, and prior-package-receipt-bound UI-only CLI
preservation are described in [shipping admission](SHIPPING-ADMISSION.md).

The existing deployed `.app` includes a release executable, SwiftPM resources,
original native icon and development bundle identifier. Its Rust native worker
re-executes the same engine and returns a session through a backend-private
socket; the main app receives status only. It is ad-hoc signed and locally
verified, **not notarized or released**. The unexecuted packaging revision adds
the Swift host and requires a matching new producer; it does not replace this
preserved pairing. No Wine/runtime payload, real library or credential cache is
bundled.

Settings provides account controls, explicit catalog market/language, advanced public-product lookup and a bounded redacted diagnostic preview; the native engine picker exists only in nonshipping development. After preview, a native save panel can save exactly the displayed counts-only summary atomically off the main actor. Unreviewed/stale preview and nonlocal destinations are rejected; filesystem errors are visible, not success. No account data, raw logs, URLs or personal paths enter this summary. Backend discovery in a developer bundle does not establish signed runtime certification.

Default LaunchServices startup was exercised with `open Xodus.app`, no mode,
backend flag or environment override. After fixing the automatic account read,
the included-engine child survived beyond the original timeout and the normal
Library/Discover/Downloads/Account controls passed bounded Accessibility
interaction. The committed `tools/check_live_ui.applescript` requires the exact
owned PID, bundle identity, non-fixture window and stable native control identifier;
it refuses blind interaction and logs only allowlisted, locally authored labels.
Its `InspectCancel` action was exercised against the normal native app: it opens
only the explicitly labelled game-folder picker, cancels without selecting a
directory and confirms the picker closed. The inspection button has explicit
AX label/identifier/button/press semantics. Picker contents and directory names
are not logged. Cancellation does not call `installed.inspect`.
This is not a full VoiceOver or provider-consent test. Missing included engines do not silently select a remembered
developer binary. User-mediated store authentication will use a backend-isolated
launcher Keychain profile, not implicit CLI/private-worker credential import.

`--fixture` opens the separate, labelled original design preview. Switching to it disconnects live work first. Fixture data never populates the live app. `--export-live <directory>` deliberately suppresses backend connection and renders only a disconnected shell.

The separate **development-only** `--export-live-data <directory>` renders four
actual live component hierarchies: unavailable Library, public Halo search,
the first returned product and generic signed-in Account. It requires
`XODUS_EXPORT_ADMITTED_BUNDLE` plus externally generated compiler pins for that
exact admitted installed engine/helper pair; an ordinary unpaired repository
build fails closed. The operator must close the normal app first and admit
this single read owner. The existing client validates structured results;
one explicit fresh account read and one bounded public search supply the views.
Account appearance does not trigger another read. No fixture data, account
identifiers, credential export, new sign-in or repeated authenticated-provider
verification is used. The client closes before the operator reopens the normal
app. Own-NSView PNGs include the native toolbar hierarchy on main views and
native sheet content on detail/Account, but are **not desktop captures,
compositor/glass certification or accessibility acceptance**. No such exporter
or development argument is included in shipping.

## Evidence and still-open gates

The historical app retirement/export review-fix milestone passed one full `sh tools/check.sh` invocation
on the Mac: **14 core + 189 management + 24 presentation + 51 native session =
278 checks**, zero failures. The native session set uses mock child processes and
the actual `LiveSession` coordinator, not real Keychain/provider operations.
It covers R01-R04 recovery, permission-preserving disconnect gating,
failed-mutation freshness, genuine empty query, stop-search fencing, selected
inspection scope, R08/R09, fourteen R10 overlapping-retirement/startup checks and
five reviewed-summary file/error/privacy checks. Five delayed edits with old view tasks cancelled
produce only two requests with maximum concurrency one; the newest captured
query/locale completes without a manual refresh or producer capacity error.
Management
tests include 31-second synthetic preparation/logout with concurrent public reads.
The release bundle passed resource, plist and ad-hoc-signature checks; earlier
disconnected own-view visual confirmation remains separate.

Twenty-two actual management checks passed against the signed enabled-inspection
copy: bounded Store/discovery pages, exact session identity, registry/diagnostics,
checked-title search, owned-process exit and read-only synthetic marker
inspection. The original 4096-byte fixture is authored in the committed runner,
not a real game. Exactly 196 metadata bytes/digest/version and unchanged marker/
registry bytes were verified; missing, aliased and malformed fixtures returned
typed errors and the same connection remained usable. Normal native Account
status, public Halo search and continuation passed bounded own-window checks.
No Microsoft login, logout or Keychain approval was attempted. **A live upstream
zero-source query has not been observed**: arbitrary nonsense can return
suggestions. Deterministic producer/native regressions cover empty-source
behavior separately, not as live empty-search proof.

Expanded reconnect checks exposed a Foundation `waitUntilExit` stall after the
owned child had exited; the exact mock-only stack was sampled. Close now observes
exit with a six-second bound around existing exact-PID escalation. Failed shutdown
is explicit, retains the retiring client and blocks reconnect, fixture switching
and application termination until reconciled. Repeated worker reconnect checks
pass; there is no unbounded private run-loop wait.

R10 additionally keeps retiring ownership in a shared operation before the first
suspension. Concurrent disconnect/fixture/quit callers await the same outcome;
failure never clears or replaces the retiring client. Connection reservation,
lifecycle revision and waiter gating fence the entire reconnect, including
post-negotiation/snapshot continuations. Engine selection and reconnect are
disabled during the transition. Actual held-EOF children exercise overlap and
a test-only short negative observation; production still uses six seconds.
The real application subsequently quit/relaunched with both owned processes
observed gone before another instance opened.

`tools/check_diagnostics_ui.applescript` passed actual native Settings,
counts-only preview and save-panel cancellation. It does not log picker contents,
choose a destination or write a file. Programmatic file regressions use only
owned original synthetic roots and clean them up. The same retained review closed
R10 at `f967f5c` and found no significant diagnostic-summary issue. The unchanged
native Account entry has been prepared for human handoff; no sign-in or approval
has been automated.

Native provider-consent/cancellation integration, source-backed discovery/search and explicit installed import are ongoing, not waived. Full owned-PC inventory/audience, legacy package authorization, safe staged installation/hash/expanded-size semantics, signed exact gameplay runtime, save-preserving updates/rollback, full VoiceOver/localization/min-OS and distribution remain open. No install or play action is enabled merely because Xbox Live sign-in succeeds. The user-directed full journey and coordinator-owned adversarial review remain completion prerequisites; this persisted client milestone is not final completion.
