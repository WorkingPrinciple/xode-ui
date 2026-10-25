# Local builds and release verification

## Exact dependency notices and complete component coverage

Prepare producer notices locally before the final integrated build:

```sh
python3 tools/producer_notices.py \
  --manifest /absolute/producer/signed/build-manifest.json \
  --manifest-sha256 APPROVED_MANIFEST_SHA256 \
  --metadata /absolute/producer/post-build-native-metadata.json \
  --artifacts /absolute/producer/release-artifacts.jsonl \
  --producer-source /absolute/producer-source \
  --cargo-home /absolute/cargo-cache \
  --output /absolute/new-notice-directory
```

The manifest hash must be the reviewed exact producer hash, not a newly computed
substitute for approval. The command reads the frozen source commit and cached
source archives without checking out, building, downloading or uploading code.
It writes only the new output directory. Pass that directory as
`--producer-notices` and the independently reviewed
`--producer-notices-sha256` to either builder or `release_candidate.py`.
Both copy and bind the inventory/notices before signing, rejecting a different
producer, CLI or Windows helper. An older signed stage cannot be augmented
without building/signing a new exact candidate.

The inventory's own hashes and packaged resource seal do not establish
completeness. Before approving its digest, independently compare every package
identity/licence and compiler-artifact membership with the frozen producer
manifest's hash-bound metadata/artifact evidence and exact-commit `Cargo.lock`,
and retain unresolved notice/source/rights obligations. Do not derive approval
from an inventory supplied by the same builder. Distribution and dry-run resume
require that digest again as `--producer-notices-sha256`; they never take
approval from a receipt or the packaged manifest. Removing packages or
obligations and resealing the manifest cannot bypass the external expected hash.

Production preflight enumerates optional Python runtime files, the exact
launch-association capsule and credential-broker reference separately from the
base app/AuthHost/CLI/helper. Optional source/licence/rights obligations do not
inherit base clearance. Unmapped payloads fail closed at manifest creation and
distribution verification, including extra executable/runtime files and code
disguised as non-code resources. See [Licensing boundaries](LICENSING.md) for the
r7 evidence, remaining exact notice/source gaps and runtime-path semantics.

## Purpose and authorization

### COR176 distribution preparation

The current local 2794e68 package has a source-bound receipt and exact source
archive; the historical missing-receipt stop below is not evidence that this
package lacks provenance. It is nevertheless not a production distribution.
`tools/package_resources.py` copies an explicit runtime resource allowlist in
both packaging paths, retains the AWACY MIT notice, and rejects unknown,
missing or linked inputs. Private QA queue/inspection JSON is excluded before
signing. `verify_shipping_package.py` independently enforces that same list.
Run `python3 tools/check_package_resources.py` for neutral regressions.

The existing release workflow is `tools/release_candidate.py --dry-run` followed
by its exact-receipt resume, using the existing Developer ID identity and
`--notary-profile notary`. A non-dry-run or resume submits private artifact bytes
to Apple; do not invoke it before the exact distribution target, rights and
external-submission authority are resolved. It is not an authorization probe.
`xcrun --find notarytool`, `xcrun --find stapler` and their help/version commands
need no submission or credential access. A metadata-only local lookup for the
`notary` profile did not find a matching item on 25 October 2026; this does not
prove the absence of credentials under another service/keychain. No credential
was read/exported and no Keychain settings were changed. Actual profile
authentication remains unverified; do not claim readiness from installed tools.

For an approved beta package that must not be submitted or installed, use
`tools/package_beta.py --app /absolute/path/to/Ode.app --output-root
/absolute/existing/output --format zip` (or `dmg`); when a producer inventory is
present, also pass its independently reviewed
`--producer-notices-sha256 APPROVED_DIGEST`. It accepts only version 0.11.4
after the distribution manifest and portable-resource checks pass, and audits
the app plus every nested Mach-O for the exact Developer ID leaf, team,
hardened runtime and secure timestamp. A DMG is also Developer ID signed and
timestamped. The tool emits an archive, SHA-256 sidecar, install note and local
receipt; it never invokes `notarytool`, `stapler`, install, or launch operations.
The receipt deliberately says `NOT_SUBMITTED`: archive creation is not
notarization, Gatekeeper acceptance, installation or runtime acceptance.

Final blockers are the exact component/notices/corresponding-source rights
review (see [licensing](LICENSING.md)), private worktree bindings in retained
launch policies, final custom-engine successor integration, and final
notarization/stapling/Gatekeeper plus first-run/update/rollback observations.
The release tool now derives standalone-unnotarized admission from the exact
reviewed producer commit/tree, pinned manifest and embedded CLI/helper bytes;
it still requires an explicit matching `--approve-unnotarized-cli` and never
claims Apple acceptance. There is no independent stale exception tuple.
Existing r7 build/source receipts resolve its provenance rather than requiring
reconstruction of older evidence. Outer app/DMG acceptance remains mandatory.

### REQ103 r7 source candidate: Stop lifecycle and orphan safety

The current reviewed producer source is
`01d4cfd625764c2a8ec4d60824ef4f277b30b9e9`, tree
`97a18c1f2c680cd4bce32a9bc2f0818b48977e64`. It includes the separate broker
process group, owner Stop classification, bounded parent-death pipe regression,
and the r6 fourth engine admission. It does not include REQ104/108 admissions.

The sealed signed CLI is
`358fd9ab8a90042f6678e27450e3dc28f431e99fc7669f7f97ad3a9d1cd31da9`
(28,758,848 bytes), paired Windows helper
`847ad6f535cc5a32cd33cdc687c330aa66cad45d4c2577fd4c035033b029c78d`
(20,480 bytes), and producer manifest
`4945099d043aed748d25e5908f7c6be26136ad67be18de8cd97c01161deac1fe`
(19,730 bytes). The app source and current runtime-recipe CLI binding use this
exact producer; historical gameplay identities remain unchanged. The management
schema is unchanged. Artifact verification and source checks are not installation,
native Stop acceptance, notarization, or title qualification.

### Retained REQ102 r5 source candidate: sibling-region descriptor localization

The previously accepted backend source is
`ad31a91e60306811aa0c9649cf70b06f592ee412`, tree
`ea434803e638599006b9bf2146f6f4ff9e87cebd`. Descriptor localization selects
exact locale, base language, lowest same-base regional tag, then neutral;
unrelated languages remain rejected. The wire schema is unchanged.

The genuine canonical app producer has signed CLI
`59ebf56f69aa895282c3f960ea48181a9bc5d274dedfcf6479738db03e13b594`
(28,739,664 bytes), Windows helper
`803549253613ad008d8d653574fa167a31ce19e97c72f3a11a04a5b87f0d8d7f`
(20,480 bytes), and manifest
`8e212aea448a144ed52fe4189dd0f2c1ac5174ad6b50ae0d8f72e82fa94cbbf7`
(16,989 bytes). Unsigned input
`d81b4d5975aba989aab8b460db02bfa09475fdda00285ef968bb8e5e5662dd06`
(28,889,376 bytes) and provenance
`478e89d3d4a1c9fd17ce8bcbc4df9c7c37186d6165b9762455490dd235fa273b`
(2,197 bytes) pass the sealed-input verifier with only its source/tree predicates
changed in memory before repinning. Owned artifact hashes, sizes, strict
fixed-leaf/team signature and three exact helper embeddings were independently
checked. Only current producer and recipe bindings change; historical gameplay
identities remain intact. Artifact admission is not installed/native acceptance,
notarization or game qualification.

### Retained REQ101 r4 source candidate: numeric Xbox account identity

The previously accepted backend source is
`b9946865fe500b20013d2d4875a6aa564bfa0809`, tree
`dfb28e8deac90b17f298e981701c0179940364d2`. It accepts canonical numeric
or string provider XUIDs while retaining exact authenticated-account equality.
Mismatches still fail as ProfileChanged; malformed identities remain unknown.
The profile schema is unchanged from r3.

The genuine separate canonical app producer has signed CLI
`f50938a9e3bfd5f5fbc3fa173f02ad0a26b3b50cab16149a4bca74ec60413ab6`
(28,701,424 bytes), Windows helper
`03134ed80f1dcfbd47b75d7ac524e95b0ab94ba3338a8b29133ecc1e7a6fc656`
(20,480 bytes), and manifest
`57e78daf5151cbc44cb9ebde995e60df07328a50dd37e8d85d95475143322406`
(16,337 bytes). Unsigned input
`13c7500f1ed4391018f1be0c84ebb34fa565a747aaf5c2f93b0095934c1807b8`
(28,850,912 bytes) and provenance
`0cf64043dddec8b5f15d829e081ac647a5fbc21ac6aa37c6c7141f192719d300`
(2,197 bytes) pass the sealed-input verifier with only its source/tree predicates
changed in memory before repinning. Owned hashes, sizes, modes, fixed-leaf/team
signature and three exact helper embeddings were independently checked.
Both schemas remain SHA256
`1118d0e831baa22d31b803e65e0ee4a5c12d8735fb183cecd24b3f8f25cdd4e9`.
Current recipe binding changes; historical gameplay identities remain intact.
Artifact admission is not installed acceptance, notarization or game qualification.

### Retained REQ101 / REQ80 COR126 candidate: account country and DIRT5 engine

The previously accepted backend source is
`a7c1b7adc3884899f4607fb8eaa8431bee0f3509`, tree
`8fadec7f4b3140aeafd8f670e9f58d32dc287c14`. It retains the reviewed NFS recovery
and adds the account-bound `profile.accountCountry` contract and the DIRT5-named
Calimocho engine admission. That engine's override is engine-scoped, not enforced
per title. This does not qualify any game.

The genuine separate canonical app producer has signed CLI
`197769abee55414cfaab3545f10c4d96af46357ea31444a6cc859d204307fcc0`
(28,699,920 bytes), Windows helper
`d09c8d5a1c4700acf334e76b2bb9a296602ca099a34fef98c1911c0df07ae7d5`
(20,480 bytes), and manifest
`732cd4037ed5dfc8369f3a0c7ac7c27601f962d154b64aaf6a15ffb2e5d9fce6`
(15,712 bytes). Unsigned input
`5e71ee04325feabb0ef5a9573ebd6d14fd2828cedcd230b6df461e5ccd069d84`
(28,849,376 bytes) and provenance
`339cd53327cb855bd33f8125e7fc33510ad9b3964d8c46e59e0419464843446d`
(2,203 bytes) pass the unchanged sealed-input verifier using that source/tree.
Actual owned hashes, sizes, modes, fixed-leaf/team signature and all three exact
helper embeddings were independently checked before repinning. Both schema
copies match canonical SHA256
`1118d0e831baa22d31b803e65e0ee4a5c12d8735fb183cecd24b3f8f25cdd4e9`.
Only the current recipe CLI binding and its bound resource digest change;
historical gameplay evidence stays intact. No installation, native acceptance,
notarization or game qualification follows from this artifact admission.

### Retained REQ102 COR124 candidate: NFS finalize recovery producer

The previously accepted backend source is
`2cb12a443fc446193282eead6b76cd3b4c73eca5`, tree
`c558c024854875deacf2f60cbf076dd7171ee8f4`. It retains the query contract and
adds the reviewed no-overwrite hardlink fallback for NFS finalize recovery.
The genuine separate canonical app producer has signed CLI
`8c47a69f6a176a9feed4d98e0ca2c3e686ee6c5f282f5518f2765c1b29da5c82`
(28,725,824 bytes), Windows helper
`32414367081e4dda4048c9260965b3a5433bc8ff1ad22e130dbb6549bcc0dd9a`
(20,480 bytes), and manifest
`ef77d022a8b3e22310bfd28aee1e33e72e27d1cd43418de8bef3326c346b98f4`
(14,157 bytes). Unsigned input
`cdfe154841437245f47dbe80f591de9798797756d726c98e78f9bba5a4d7c617`
(28,875,440 bytes) and provenance
`2d02e636fa39efb1af8c923935a4687ceeb96b5b27ea80f5a06e01123e5865d0`
(2,199 bytes) pass the unchanged sealed-input verifier with that source/tree.
Actual signed hashes, sizes, ownership/modes, all three exact helper embeddings,
and strict fixed-leaf signature were independently checked before repinning.
Both schema copies remain byte-identical to canonical SHA256
`8b35109843a37023491add7e385f51c795300df5a838194c484dd7d6b9b3d1bd`.
Only the current runtime catalogue CLI binding changes; historical gameplay
evidence stays intact. This is source/artifact admission, not proof of actual
NFS promotion, installation, gameplay or native search acceptance. The stopped
9139 producer and the separate standalone 2cb producer are not relabelled.

### Retained REQ100 candidate: accepted query producer

The accepted backend source is `a31f63df2bf265db46a8d28ed2e8ac1e60181beb`,
tree `1eb7713816f4748fa821bf9d14faff3d8498bbfa`. The sealed-input source/tree
predicate targets that exact revision; command, feature/profile, ownership and
seal validation are unchanged. The observed signed tuple is CLI
`f59ba1be087356efa6757ab38002de1cb884ab60420c15185e1a4c1a8f0fecc9`
(28,703,504 bytes), Windows helper
`3e2e8b8ce7bad9f1f283bdf01d79ef7b7dda568a585fe6958e9fd263e4ebc39a`
(20,480 bytes), and manifest
`f37bbaaa8b294e6e48010327fbe5bc7c2019665f7091737df182890e4c6df258`
(12,169 bytes). Unsigned input
`47e36b37625dec4c41cb22f14a3916362da58f31d0e0c311fdf95a9697f4b641`
(28,852,992 bytes) and provenance
`cfbb2baeb8e5a46569effa378929ca2dc525246c2b3c8b8eb416cd35d5526f6f`
(2,199 bytes) pass the unchanged sealed-input verifier. Signed artifact hashes,
all three exact helper embeddings and strict fixed-leaf signature were checked
independently before binding these pins. The runtime catalogue changes only its
current CLI hash; historical gameplay evidence identities remain unchanged.
This is source/artifact binding, not installed acceptance or a relabel of the
immutable REQ95 signed candidate.

### Frozen REQ95 candidate: compliant settings producer

The reviewed successor uses the same producer source/tree below, genuinely built
with the canonical sealed-input command. Current signed CLI is
`3b6f44c6b2cf45a5c554daaae2ddbb5034b79ade0aa6df19c8308ad96c544a39`
(28,676,640 bytes), helper
`44b72c0753c0042f1f23f469d4029584af0baa6f42003a33155b54eb198c2027`
(20,480 bytes), and manifest
`434d34898e08cd9a1d3cb3df0eef6128a113fe558e528833c0fe162c48637cdc`
(8,003 bytes). Unsigned input
`068074f1b65013f1b3eb4d5eac4739df934c9099b232891a3faa04c83cbbbf47`
(28,825,968 bytes) and provenance
`c6f2b8a46a1316e5a47166e7d1b2ac72fa5ddcc89fa2882ff14580d4bb0e5d0d`
(2,210 bytes) passed the unchanged `shipping_pair.verify_input` at that freeze.
The complete actual helper differs from the older 42560b3e artifact at only
offsets 136/137/138 (COFF timestamp) and 216 (PE checksum). This is a new genuine
compiler output, explicitly accepted by the coordinator, not a rewritten old
artifact or a claim of historical compiler identity. All three embedded helper
copies match the new paired helper. Fixed-leaf strict verification passed.
Source review and coherent staging remain separate from installation/runtime.

The superseded standalone-only tuple is retained below for provenance:

The superseded consumer source pinned producer `9f385203b9a38605beedd83d57e77253014c2190`,
tree `4c5e06fa2863d82512df2aea19b540c2b51d455e`, signed CLI
`d761d8514375fad4aa83362c98a607542e8cf3c676b997e9dd286d30004c702e`
(28,674,576 bytes), unchanged helper
`42560b3e33a258c8af43146034d6f5140d939f855d682739bc82ea1d8962ff65`
(20,480 bytes), and manifest
`45c2ea46bb1609880d046dab41a4a9541f0057655564df5b91c8853f619e98ea`
(7,512 bytes). Actual hashes and strict signature were independently read.
Its unsigned provenance is
`771aa1b1a9448034a00713b171de4febe066db8df2c76353b785a377698b18b0`.
Historical recipe evidence CLI identities are unchanged.

This tuple is accepted for standalone/source integration only:
`buildAppExactCommandCompatible:false`. It is not permission to bypass the sealed
input validator through the selected-signed refresh. The canonical predicate in
`shipping_pair.verify_input` requires the actual command
`cargo build --release --offline --locked -q -p xodus-cli --bin xodus-cli --target aarch64-apple-darwin --no-default-features --message-format=json`,
matching native feature/profile metadata before and after build, and
`metadataPlatformFilter:aarch64-apple-darwin`, plus its existing ownership,
mode, seal, source/tree, hash and byte-count checks. A genuinely compliant new
producer artifact and provenance were required before staging; the successor
documented above satisfies that predicate.
No validator or command predicate is weakened. Signed UI stage `3c0648b` remains
immutable and does not contain this source work. Source verification does not
claim installed engine parity, game acceptance or permission to deploy.

### Current paired schema reconciliation

Both app contract copies now use the exact canonical management contract from
producer `a31f63df2bf265db46a8d28ed2e8ac1e60181beb`, tree
`1eb7713816f4748fa821bf9d14faff3d8498bbfa`, SHA256
`8b35109843a37023491add7e385f51c795300df5a838194c484dd7d6b9b3d1bd`.
Relative to the previous bundled contract, only the optional `sourceFailure`
object was added to successful and failed query pages. No bundled app-only
content was dropped; the stale docs copy gains the existing descriptor and
combined Xbox/Store contract as well. Both legacy Store Edge and combined
sources remain valid; page freshness is live and products remain PC candidates.
`tools/sync_contract.py` now verifies equality without copying. Its focused
regression proves matching, mismatched `check.sh`, and missing-file paths leave
files unchanged.

Focused source verification compares the bundled resource byte-for-byte and
validates supported producer fixtures through both contracts:

```sh
swift run XodusManagementChecks --contract-schema-checks /absolute/frozen-producer/docs/contracts/management-v1.schema.json
```

Schema parity does not admit a new executable. The existing debug CLI
`8ba24aed...` was built at `891b941`, not at this schema-only successor.
Signed CLI, embedded helper, producer manifest and lifecycle pins must be
reconciled from actual reviewed artifacts before paired packaging. Source
`ShippingPairPins.approved` stays nil; packaging generates exact pair identities
only in its isolated stage. App-only refresh retaining CLI3121 cannot claim
delivery of the shared descriptor backend.

The owner-approved port-11 selected-signed-CLI refresh tuple is observed, not predicted:
CLI SHA256 `fd6c7a6427a7317e92ebfcd5d49a5f6b5ff75e3b7330ff2bcad887262ca06dd8`
(28,535,616 bytes), actual release embedded Windows helper SHA256
`42560b3e33a258c8af43146034d6f5140d939f855d682739bc82ea1d8962ff65`
(20,480 bytes), and sibling producer manifest SHA256
`ffe2fb56897fc453c37ff680c0a14ecb70577dbc6b0aa829b9eb4b403c5d3aff`
(8,577 bytes).
The signed CLI passed strict fixed-leaf verification with the existing approved
identity. Its actual producer command was
`CARGO_BUILD_JOBS=1 CARGO_INCREMENTAL=0 cargo build --offline --locked --release -p xodus-cli`;
the unsigned provenance truthfully records that command, not the distinct
sealed-input recipe's command. Use the explicit selected signed CLI refresh
path with its paired helper and manifest. No integrity check is waived.
These pins permit exact candidate packaging; installation, observed capabilities
and gameplay remain distinct evidence. The producer admits only the exact
`a5d37d2909f56abe75f9b6096cf39b4d75c91a7f6aac75154488d4c35b5ff28a`
registry entry for `calimocho-wine11.20-gptk4b3-tls-vulkan`; static admission
does not establish gameplay qualification or general Calimocho support.
The unsigned provenance is not compatible with `build_app.sh`'s exact sealed-input
command validator. That validator and its command pins remain unchanged.
The existing selected-signed-CLI refresh rebuilds and signs the app and AuthHost;
their executable bytes are not preserved. The pin-only consumer
`d7e36f3be2632b0b9fc45aa2ff434ba3d9088d50` was based on delivered
`023904cc620b27311e0fee4310d62cfbc3003f04`, with producer-binding changes only.
That describes the historical pin-only packet, not corrected UI source
`950145d04c4a1203926fa77baf0b41b08893aba6`. The corrected UI retains the
exact-ID access and detail-dismiss/visible-consent corrections, including the
account-bound handoff from `329ef9789c071ee53b8d06fc706c5bdea80a9f58`,
and integrates the reviewed six-file producer-binding delta from `d7e36f3`.
These remain distinct candidates; source ancestry or a signed stage does not
establish installation, deployment ordering or gameplay acceptance.

The runtime catalogue's `cliSha256` also binds the selected signed CLI above.
Its bundled SHA256 is
`7c1b713e0a7cdb1879c7a528ee02c20224bd1c114caf4af06618713ea65e7878`;
both the byte digest and lifecycle equality checks remain mandatory. This
packaging binding does not rewrite `evidenceCliSha256` or any title's observed
recipe/evidence, and does not establish gameplay qualification with the new CLI.
Current CLIfd6c title/runtime qualification remains pending. Its retained launch
arguments do not prove equivalent behavior: provider admission, prefix ownership,
staging and the popup monitor changed since the historical CLIadf8 title runs.
Leaving the catalogue bound to CLI3121 while updating the lifecycle pin rejects
all profile resolution, including otherwise unrelated titles.

The new pair adds exact-opt-in descriptor count telemetry and the existing
diagnostics-export checkpoint fence. It is not a fix for the historical
management overflow: that incident remains unresolved/non-reproduced with the
diagnostic-only d0c7019/5bd7 pair installed until separately replaced by the
exclusive deployment owner. The new signed producer does not imply installed
measurement acceptance; see `NATIVE_UI_PROCEDURES.md` for the bounded same-session
count collection path. The schema, helper and historical CLIadf8 gameplay proof
remain unchanged.

### Header search regression (#40)

The collapsed header lens is an explicit accessible button, not a 32-point
`NSSearchField`. Clicking it or pressing Command-F opens Discover's global
catalogue search and focuses a 220-point native editor. AppKit editing owns
the focus binding through ordinary SwiftUI state; an unattached `FocusState`
must not reset it. Searches join public Store results with loaded Game Pass
matches and current library ownership, deduplicating by product ID.
Search results keep unsupported or unknown-package games visible with their
real compatibility restrictions; inclusion never grants installation or access.
The regression case `mortis` requires Valor Mortis (`9P861V1542BL`) without
requiring it to be owned. Installed-source `305ea58` observation confirmed the
lens and all eight verified title badges, but Store queries for `mortis` and
Asphalt failed through the paired service; price and cancellation acceptance
remain incomplete. Direct public Store Edge search omitted Valor Mortis while
Xbox's Romanian search returned its exact ID. Source-union tests are not
evidence that the installed service covers this title. Failed product IDs and
error codes are disclosed under **About these games**, not treated as an empty
successful search.

The signed CLI `3ea56ed1` / producer `974ac81` was the earlier search candidate.
The prior approved local candidate uses signed CLI
`3cdbf1dde6e136af29af9c8f3f17042abbd9f05eeca05f4f5efd57f27db67bea` from producer
`43429cc052c531029c4e1d86ead56102070b9917` (tree
`3a5ac3f32e5cc33b7f8267205a91249051d31df9`). S2's frozen source passed 396
workspace tests, and its signed binary passed strict Developer ID verification.
Its lifecycle source is unchanged from the earlier candidate; the coordinator
approved repinning and off-screen packaging. This authorizes candidate
packaging, not installation or a claim that installed UI or Brotato runtime
acceptance has passed. The prior notarized-release exception is not extended to
this unnotarized local candidate. Historical service probes and app acceptance
remain bound to the exact candidate noted in their receipts.

The bounded installed-product access rebind selects signed CLI
`71a3eb861ff4ff9d79d100469b0feea039df327983b47f5dfa15ca82ab68c3e2`,
built from `a4550b86c8ad19589b631f4e303273c367d30aab`, with its paired helper
`42560b3e33a258c8af43146034d6f5140d939f855d682739bc82ea1d8962ff65`.
The additive contract source is `2729b33a1b44e3350363037cafaf017d60d65d06`,
tree `6f29c11d41967a9f4e9870ac9700da3b349ee6f3`; no crate or dependency
bytes changed from the binary's build commit. Exact schema SHA256 is
`578d0c70217c0c3592ec5e17052c8ae62f922293354014196f7f06a3e186b31a`,
and producer manifest SHA256 is
`2cce4010dd93156982777e9d7842feafc96e5e276bab43732883a2a4a61f0056`.
The launch-recipe CLI binding follows this explicit rebind; recipe contents,
runtime pins and historical gameplay evidence pins are unchanged. This is
private local candidate admission, not gameplay requalification or public
distribution. The recursive CompatibilityData bundle and redistribution-rights
hold remain separate release blockers; no held PublicMetadata is admitted here.

The consumer-collection correction candidate explicitly pairs signed CLI
`3121df540f1ef9bb6d161f02f3c6ac958d74aa1559502304147542ad735da5b6`
with producer `8b091460e74879980081d899b1dab349141561e0`, tree
`a4d92a96ebc9070c2d1e9b9bec031aba8437b3b8`, and manifest
`d66c7a6cb55854b08e6ecda757ff1ecd10ad9bc7d5930df5424732740ca0fbfc`.
The Windows helper and management schema hashes above are unchanged. Only the
launch recipe's CLI identity binding changes; runtime rules and historical
gameplay evidence are not requalified. This is reviewed source/build pairing
for a bounded local candidate, not installation permission, live collection
qualification, restored-purchase proof or a notarization exception. Explicit
unknown acquisition remains unknown. The installed e641cfa/71a3 pair remains
the rollback baseline until independent combined-candidate admission.

Installed `122532b` with the earlier signed 71a3 pair passed the full local check and actual
AX observation: the lens focused its 220-point editor, `mortis` returned Valor
Mortis at `199,99 RON`, Asphalt Legends displayed Free, and its real external-page
confirmation was cancelled by Escape without invoking Open. All eight distinct
Verified working title badges remained. The receipt and full-screen captures are
under `~/Library/Application Support/XodusCLI/proofs/ode-search-acquisition-122532b/`.
Brotato runtime acceptance remains separate.

### Discover metadata and support defaults (#44)

Unknown package or anti-cheat facts are not known incompatibility. They no longer
hide a title or produce a generic unsupported label. Named package and anti-cheat
blockers remain visible as their specific reasons; install consent, account
access, runtime inspection, and Verified working evidence remain independent.
The shipped classification database and its evidence are not rewritten.

Game Pass metadata uses a small Xbox sphere in a green circle, not a wrapping
pill. Discover identifies PC-library, PC Game Pass and Xbox/Store sources. The
Xbox search response may now provide source-backed, market-local subscription
listing names and IDs. The listing is explicitly partial: missing IDs and
known-empty or unknown results do not imply exclusion. The UI shows any returned
names as partial public listings and keeps account-plan coverage unverified.
It does not infer tiers or platforms from IDs/names, nor grant install access
from public listing data.

Live startup takes the device's market independently from the first valid
preferred UI language (for example RO with preferred en-US/ro-RO selects
RO/en-US). An empty language preference falls back to en-US without changing
the market. Explicit test connections keep their explicit test scope.

The Library access check renders the shared card's Installed status and Discover's
coverage control in nonvisible light/dark fixture windows. OCR locates each label;
sRGB glyph-core/background samples must reach 4.5:1. These controls use primary
semantic text after a lossless installed light-mode sample exposed insufficient
secondary-text contrast. The fixture does not replace installed-build appearance
and accessibility acceptance or change any global appearance preferences.

Search uses a compact title/scope-menu header and keeps compact Library matches
separate from the shared poster grid. Result Escape clears the query; poster
focus targets its named artwork button, with an explicit ring and handled Return.
Only retained public results dim while their refresh is pending; valid local
Library matches remain usable. Appending More games keeps the current public
page reachable and focusable; only replacement requests fence retained public
placeholders. A delayed synthetic query/pagination regression exercises both
pending request types through the actual catalogue queue. Search routes blocked poster actions to details
without repeating browse diagnostics or changing installation admission.
The Library access check renders one-match and six-match synthetic compositions
offscreen at 1440x874 and 1619x1231, including overflow and a package-blocked public
result. Optional `XODUS_SEARCH_CAPTURE_DIRECTORY` saves these fixture PNGs and OCR
text in an existing directory. These are source regressions, not installed native
keyboard, VoiceOver or provider-response acceptance.

The shared state/action contract is covered by paired deterministic assertions:
`--library-access-check` covers permit expiry, imported installation,
account-switch late completion, same-scope refresh failure and metadata failure;
`--media-check` pairs rejected artwork with retained held-game facts and review
eligibility; `--game-operation-check` covers unknown held acquisition,
public-only Game Pass, purchased-uninstalled, unknown/unsupported compatibility,
list removal versus explicit uninstall, and install completion without
auto-launch. These use existing synthetic clocks, transports, stores and scripts,
not real account/provider or native-game evidence. Public membership, purchase,
installation and compatibility remain independent facts; review eligibility is
not permission to confirm an unchecked install or to launch a game.

Optional DisplayCatalog details accept the explicit `neutral` language tag as
unlocalized product metadata, alongside exact/same-language responses.
Unrelated language tags are still rejected; requested-market ratings and release
dates, exact requested product identities, and game-access gates remain unchanged.
The saved-response `--catalog-detail-check` runs offline and does not establish
that the installed app has displayed the updated details.

REQ-61 / COR-21: Ode never offers commerce on any distribution channel.
Offer decoding, price formatting, purchase/claim actions, external acquisition
links and their development commands are deleted, not feature-gated.
Entitled games retain Install and Play. Public Game Pass membership remains
independent of account access and never grants installation on its own.

### Brotato candidate route (#43)

`WORKING_CANDIDATE` displays **Candidate · CLI only** and never supplies a
Verified working badge or automatic evidence-based engine selection.
The generic wine-stable route showed splash logos followed by a black window
in run `86f694f5`; that is not gameplay success. Brotato now has an explicit
Apple GPTK 4.0b3/default-COM profile, runtime 7106's pinned primary/legacy pair,
the standard pinned native-web shims and `Brotato.exe`. Explicit title-profile
engines take priority over generic provider defaults; existing provider-specific
NMS profiles still select their own distinct recipes.
The new route keeps the app's installation-specific prefix, not the old
`430e9c33` proof prefix. Historical ebd56e gameplay/save evidence does not prove
this a1aade app route; a separate approved live regression is still required.

### Morning CLI-only WORKING additions

The app bundles source-bound Hades II (CrossOver 26.3), Abiotic Factor
(Apple GPTK 4.0b3, STA, Shipping executable) and Mixtape (Apple GPTK 4.0b3)
observations in `mac-game-evidence-v1.json`. Their tiles and details explicitly
say **CLI only · App testing not observed**. The named reload proofs are
`s3-hades-checkpoint-reload-02`, `s3-abiotic-qualification-reload-01` and
`s3-mixtape-extended-reload-01`; compilation is not app E2E acceptance.

The default local ledger is merged with these three rows. For a conflicting
product, the newer catalogue timestamp wins (local wins ties); other local
rows, including the existing five WORKING titles, are preserved. A newer local
negative verdict can revoke a bundled badge. An explicitly selected evidence
ledger remains authoritative without merging. Invalid evidence still reports
an error rather than silently falling back. No local ledger is rewritten,
and package/anti-cheat admission, CLI pins and launch recipes are unchanged.
Screenshot paths refer to retained local evidence; missing screenshots report
the existing explicit error instead of claiming fresh app evidence.

The exact c22029c installation, first-launch and c1190cc rollback commands
are in [the held switch-over runbook](RC-SWITCHOVER.md). It includes a safe
copy-only signature/ticket/Gatekeeper check; no second app copy may launch
while live HK acceptance still owns the app.

### Explicit d3dshared first fallbacks (source after c22029c only)

Frozen S1 `f9dfc3483578101f9f4a0c8a017ae5867815f977` supplies exactly
`apple-gptk-4.0b3` → `apple4-d3dshared`,
`creation-dx11-d3dmetal` → `creation-dx11-d3dshared`, and
`queue-winecx-nativejson` → `queue-winecx-d3dshared`.
These are **not defaults, automatic retries or gameplay qualifications**.
Only after observed base startup-crash/fiber/FLS/raw-GS symptoms and normal
slot/input approval may an operator explicitly set
`Xodus.lifecycle.fallback.<PRODUCT_ID>` to the matching sibling name in the
app's preferences, while the app is normally quit. Remove that exact key to
restore the base. No key is set by source loading or this runbook.

The selection is product-bound; it cannot affect another tile. The app
requires an available complete sibling registry entry with the same Wine and
base environment plus only the frozen support-library delta, pins the dylib
hash and preserves the current title's runtime pair, shims, executable,
environment, imports and overlays. It never borrows one of S1's six other
titles' runtime recipes for a newly staged game. Unknown or mismatched
selections fail explicitly. The qualified free NMS default and its exact
CrossOver fallback are unchanged. This source is not inside the already
notarized c22029c artifact.

### One-command pinned release candidate

The `a1aade` adoption is preparation only until owner approval: no release,
notarization, install or activation is authorized by this source change.
After approval, merge the preparation commit and use the existing command
below at the resulting clean full commit. The installed `42f793d` RC remains
unchanged in the meantime.

From the clean checkout at `FULL_APP_COMMIT`, run:

```sh
python3 tools/release_candidate.py \
  --app-commit FULL_APP_COMMIT \
  --installed-app "$HOME/Applications/Ode to X Local Candidate.app" \
  --output-root "$PWD/.build/local-candidates" \
  --identity 410914520BCC840C0125D3826CCF0F247F603321 \
  --candidate "$HOME/Library/Application Support/Ode to X/Service/candidates/a1aade5e959a5ad27e695f85c15ef50addf036d4ab857d70e041f57a95abe664" \
  --producer-source /absolute/frozen-xodus-macos-checkout \
  --notary-profile notary \
  --dry-run
```

`--dry-run` performs the real pinned build and Developer-ID signing in a new
owned output directory; it does not submit to Apple, install or activate.
The installed app supplies only its verified icon and prior receipt.
The command verifies S2's exact immutable CLI/helper bytes, actual embedding,
producer commit `f54654db11a67497323f5e49625a48c847e1f41b`, tree
`12f94181f8448782e7eee685d66353859d78587a`, and producer manifest SHA256
`9b692e615a16376f65fd83c3c5dd42f9ea7ddda7900242941f034f79b1c31380`.
This includes TUNIC's per-call inventory index (`0b12147`), popup timeout
continuation (`fdb7931`) and bounded CrossOver probe budget (`f54654d`).
The actual embedded Windows helper SHA256 is
`0f58c46716ab759fa4317756be38812a3c2265b6c1856bacc9787f9269b28fb7`
(20,480 bytes, identical copies at offsets 13,584,269, 13,647,408 and
13,710,147), **not** the older adf8 helper's `d5968170`.
Although only PE timestamp/checksum bytes differ, they are not raw-byte equal.
The helper is preserved beside the CLI; the separately built Mach-O
authentication helper is signed independently. The producer manifest records
the historical build/test provenance, not a new build or independently
reproduced binary.

There are two morning choices; preparation grants neither:

1. Explicitly approve this exact CLI/helper/producer/manifest tuple without
   standalone acceptance. Only then add
   `--approve-unnotarized-cli a1aade5e959a5ad27e695f85c15ef50addf036d4ab857d70e041f57a95abe664`
   to the build or resume command.
2. Require real standalone acceptance. Omit that flag and wait for S2's
   `notarization/receipt.json` plus its adjacent Accepted Apple submission,
   bound to the same source and exact CLI/helper hashes. The original
   build manifest may remain a historical `NOT_SUBMITTED` record; the
   later accepted sidecar is verified independently and is never inferred.

Without the exact approval flag or a matching accepted sidecar, admission
fails **before building or signing**. An invalid sidecar cannot fall back to
the exception. The earlier ebd approval does not authorize this new pair.
For the explicit exception the manifest truthfully says `NOT_SUBMITTED`,
with no submission/acceptance pointers; the release receipt records
`standaloneNotarized:false` and `outerAppNotarizationRequired:true`.
An unknown/altered binary, helper, manifest, source or tree is rejected.
Changing the general packaging pins cannot extend this fixed exception.
No Apple acceptance is fabricated. All other standalone inputs still require
the existing accepted combined-submission receipt and exact approved hashes.
The normal outer-app and DMG notarization, codesign, stapler and Gatekeeper
checks remain mandatory before `notarized_candidate`; a dry-run is never that
state.

After the HK saved-quit/tile-relaunch handoff and the frozen free NMS binding
are admitted, omit `--dry-run` to build, sign, submit the app, require Accepted,
staple and verify it, then create a DMG containing that stapled `.app`, sign,
submit, staple and Gatekeeper-assess the DMG. No mode installs or opens an app.
The printed external `release-receipt.json` records exact source/producer
identities, build logs, commands and exit codes, Apple submission IDs,
artifact hashes, unexecuted gates and failures. The sealed app's original
candidate receipt is never edited to claim notarization. Gameplay/app_e2e
remains unobserved until separately exercised; a notarized candidate is not
automatically a production-qualified release.

To submit the **same signed dry-run bytes**, without rebuilding or re-signing:

```sh
python3 tools/release_candidate.py \
  --resume-receipt /absolute/Ode-release-SESSION/release-receipt.json \
  --notary-profile notary
```

Resume requires a successful untouched dry-run, the exact signed
launcher/helper/resource seal, the embedded source receipt and frozen
CLI/helper bytes. A failed/partially submitted run is not automatically
replayed: reconcile its recorded Apple submission before retrying. Resuming
an exception-based dry-run requires the same exact approval flag again.

### Supported local-candidate build

For a UI-only refresh after the approved pinned CLI/helper is installed, use
the explicit preservation path:

```sh
python3 tools/refresh_local_candidate.py \
  --installed-app "$HOME/Applications/Ode to X Local Candidate.app" \
  --output-root /absolute/owned-output-directory \
  --identity 410914520BCC840C0125D3826CCF0F247F603321
```

It builds the committed app/helper, regenerates exact pairing pins, preserves
the signed CLI byte-for-byte, signs the new app, and embeds
`Contents/Resources/local-candidate-receipt.json`. Missing historical receipts
and unverified producer source are recorded honestly; this does not certify
producer reproducibility or enable lifecycle on the old CLI. Replace the
installed app only after this build succeeds and the previous app quits.
Every UI-affecting commit must be followed by build, install, relaunch and
real-screen inspection; source checks alone do not update the user's app.

To replace that CLI with an immutable, already signed S2 artifact, supply all
four explicit producer inputs:

```sh
python3 tools/refresh_local_candidate.py \
  --installed-app "$HOME/Applications/Ode to X Local Candidate.app" \
  --output-root /absolute/owned-output-directory \
  --identity 410914520BCC840C0125D3826CCF0F247F603321 \
  --cli /absolute/immutable-candidate/xodus-cli \
  --producer-source /absolute/producer-repository \
  --producer-commit f54654db11a67497323f5e49625a48c847e1f41b \
  --windows-helper /absolute/immutable-candidate/xodus-window-monitor.exe
```

The tool verifies the signed CLI and exact helper embedding, resolves the
pinned commit/tree, compares its management schema, verifies the producer
manifest hash, and regenerates the app/CLI/helper pairing. Its receipt
records selection rather than claiming that the packager reproduced S2's
binary. The native lifecycle digest must also match `NativeLifecyclePins`.
An explicit frozen S2 CLI keeps its producer signing identifier and is checked
against the selected certificate leaf and frozen digest, rather than requiring
the app packager's different CLI identifier. Its original bytes are preserved.

The runtime catalogue's `cliSha256` binds the selected `a1aade` packaging
target. Its separately pinned `evidenceCliSha256` remains `adf8`: existing
Abiotic/Hogwarts recipe observations are historical adf8 observations, not
retroactive a1aade or app-E2E qualifications. Their run/receipt/recipe fields
remain unchanged. This preparation does not promote Brotato or change any
WORKING verdict.

Runtime settings can select an **experimental local** `xgameruntime.dll` and
its sibling `xgameruntime_legacy.dll`. Both hashes are captured at selection and
rechecked before launch. Release qualification is not a local testing gate;
this does not make the pair production-qualified.

Optional per-title launch profiles live in the selected profile directory as
`STOREID.json`, with this shape:

```json
{"version":1,"productID":"BQVQTL3PCH05","engine":"exact-registry-engine","environment":{"CX_ENV":"explicit adapter options"}}
```

Bundled title bindings in `Sources/XodusManagement/Resources/LaunchRecipes/`
take precedence over historical local profile files. Other titles still use
the selected local profile directory. Explicit provider selection remains an
engine override, except that an observed engine-specific STA setting cannot
silently follow a different engine selection.

The earlier adf8 RC originally embedded S2's `b464aadf03af9b5fe78f9362c422e32260c66533`
`docs/recipes/title-runtime-v1.json` (SHA256
`9cddef7cf30a9553f2ab3e9b5cffa4d5812c4fd260e03f32bf1e507c2931dd76`).
Only `pendingTest:false` + `status:title-screen-observed` with a real run,
receipt path and CLI/Wine exit0 can merge into a matching title/engine,
executable and runtime-pair binding. Abiotic therefore receives STA1 from
S2's source, not a game-name branch. Its caller-owns COM and inherited
d3dshared-library override are removed. Its base Apple4 direct-Shipping
recipe and 600-second diagnostic limit remain; this is title-screen-only
evidence, not gameplay or save qualification.

Hogwarts was pending in that snapshot; the accepted `42f793d` RC subsequently
admitted its exact WORKING/retention/ordinary-quit recipe. This preparation
preserves that recipe without claiming it was observed on a1aade.
All still-pending entries remain data-only diagnostic inventory and never
auto-apply. The earlier four queued COM bindings are withdrawn from
normal launch until observed. A stale local pending STA profile is rejected
explicitly, not silently promoted. Unknown titles and working HK/NMS routes
remain unchanged.

Player launch errors use plain language for a confirmed timeout, an explicit
loader report of a missing component, and an exit before any game window was
recorded. Missing, malformed or failed monitor evidence is never treated as
proof of no window. Account failures retain their existing account recovery.
**Show launch evidence** reveals the exact run folder in Finder. Messages do
not apply repairs, promise a fix or call a zero exit gameplay success.

NMS defaults to S1's frozen `6290d24` free `nms-free-gptk3-d3dshared` recipe
after its retained-save/relaunch qualification. It pins GPTK3's support
library and the original NMS legacy DLL (`de6f1c...`), not the other titles'
7106 legacy. An explicit CrossOver provider selects a separate fallback
binding preserving S3's `f8bb9124` CrossOver 26.3 recipe, its exact
7106 runtime pair, c2b MoltenVK hash, native-web shims and native-JSON import.
Structured CrossOver environment values are shell-quoted for the adapter's
`--env` argument and mirrored in its ambient environment. Required exclusions
are removed from the inherited environment. The app creates an owned
per-launch registry document with the same engine name/executable and
checksum-checked setup, leaving the shared registry and tested prefix alone.
Fresh app prefixes remain separate from the tested CLI prefix; the a1aade
CLI and actual tile/save/relaunch path still need their own app acceptance.

`hollow-knight-local-saves-candidate-v1.json` is deliberately absent from the
active profile catalogue. It prepares a CrossOver mirror for private local
saves, but must not change the live HK run or its relaunch recipe unless the
real bench-save relaunch fails to retain the save and the coordinator admits
the correction. A missing `ps` environment entry is not evidence that Wine's
Windows process did not receive a variable and does not trigger this candidate.

The CLI receives the explicitly selected engine/registry, a game-and-engine
private prefix, mandatory `--shim-dir`, and the profile environment. The
shim-only `Engines/profiles/native-web-shims-v1` directory supplies Windows.Web,
XCurl and CA roots, with all three SHA-256 identities checked before every
launch. It cannot replace either half of the separately selected runtime pair.
Missing profiles mean no additional environment overrides, not missing sign-in
components; malformed/wrong-product profiles or alternate shim directories fail
visibly. Registry engine environment and wineserver selection
remain the CLI's responsibility.

An optional exact `engine` in a title profile binds its current qualified recipe
ahead of historical gameplay evidence, while explicit provider selections still
win. The previous local lifecycle candidate was pinned to CLI `adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604`,
producer `a86d2f654b29dd33203022013fd63b34826d47cd`, tree
`6044d5fff819393de39fae577ba9dd9bddbe795d`. The a1aade preparation supersedes only
these packaging pins with the exact producer/pair above. Both apply the
selected registry engine's checksum-checked `prefix_registry_imports` after
overlays and before launch, so a fresh Hollow Knight native-JSON prefix does
not rely on registrations left by a historical test.

Play does not require an engine-picker step. An explicit per-game/default
provider remains an override. Otherwise the latest successful gameplay ledger
entry selects its exact registry engine; without successful evidence the first
available PASS engine is used, preferring Free Wine. An unavailable proven or
explicit engine is reported rather than silently substituted. Launch requests
and pre-launch failures are logged under `io.github.dragoshont.xodus/GameLaunch`;
tile failures are shown inline. A bounded foreground handoff targets a newly
created same-user game window with an exact game-title match and the configured
executable/Wine owner. It excludes pre-existing windows and browser titles,
rechecks kernel birth identity before activation and, when existing Accessibility
permission permits, raises only that PID's exact-title accessibility window.
This avoids shared Wine bundle activation selecting a different running game.
It supports Wine's reparenting
to PID 1, and never steals focus after the user leaves Ode to X.

The owner changed the classification policy on 22 October: unknown anti-cheat
is not a known blocker. MSIXVC games without a named blocker can be tried and
are labelled "Not tested on Mac yet"; this is not a support or gameplay claim.
Named anti-cheat and unsupported formats remain blocked. The supported filter
continues to use S4's evidence-qualified `supported01` facts.
Bundled public-source `none` corrections require the explicit
`user-directed-correction` mode, documented user direction, and all three
AWACY/PCGamingWiki/publisher checks. They are not complete package scans,
installation-readiness receipts, or Mac gameplay proof. Undocumented public
absence claims and incomplete scans cannot qualify a title.

The Mac test evidence JSON automatically loads from
`~/Library/Application Support/Ode to X/Evidence/tried-games.json`; an advanced
Runtime setting (`Xodus.evidence.triedGames`) can select a different ledger.
Schema version 1 has `updatedAt` and `games[]`,
with `productId`, `title`, `verdict`, `scope`, `engine`, optional `runId`,
`screenshots[]` (`path`, `caption`), `owner`, and optional `blocker`.
Supported verdicts are `GAMEPLAY_PASS`, `MENU_PASS`, `BLOCKED`, `FAIL`,
`NOT_TESTED`, `WORKING`, `WORKING_CANDIDATE`, `TITLE_SCREEN_ONLY`,
`INCONCLUSIVE`, and `ANTI_CHEAT_EXCLUDED`.
`TITLE_SCREEN_ONLY` remains a partial observation, not gameplay or WORKING.
`INCONCLUSIVE` is a known unresolved outcome, not an unknown verdict or a
working result; it never supplies a verified-working badge or automatic engine
selection. `WORKING_CANDIDATE` remains scoped to its recorded candidate evidence
and never supplies either promotion.
Unknown future verdict strings render as "Result not recognized" for that
entry only; they never receive a working badge or supply an automatic engine,
and do not hide other valid entries. Other schema/path validation remains strict.
Engine and run ID may be
null when not recorded. The library reloads it every five
seconds, exposes compact verdict/engine copy on cards, and opens recorded local
screenshots. Full observation scope is available in Details, not on the cards. These observations
do not grant entitlement or override S4 package/anti-cheat admission.
Only `WORKING` is labelled "Works on Mac"; `GAMEPLAY_PASS` is "Playable, not
fully verified". `BLOCKED` without an explicit `launchAttempted:true` remains
"Not tested on Mac yet", so installer failures never become launch claims.

The next source candidate renders `WORKING` entries with at least one
recorded local screenshot as a **Verified working** badge on library cards,
the hero and Continue Playing. The badge opens that title's evidence path;
Details also shows the path and the full observation scope. It does not
claim app-driven E2E or cloud saves beyond that scope. Missing evidence,
`launchAttempted:false`, all other verdicts, absent/invalid ledgers and
installation completeness alone cannot produce the badge. The evidence
ledger remains read-only to this consumer; no title is promoted by UI code.
An optional `saveObservation.retentionVerified:true`, valid `retentionRunId`,
and explicit `saveObservation.normalMenuQuitObserved:false` render gameplay
partials as **Save verified · quit pending**. Prose or a save-directory path
alone never supplies this status. Explicitly pending quit also prevents a
`WORKING` entry from displaying the verified badge; unknown verdicts remain
unknown regardless of retention metadata.

### Published candidate launch rows

Halls supersedes its frozen blocked candidate row only when the read-only matrix
contains S3's exact `WORKING` evidence: first run
`8d7ea6ba-ec75-4cb1-8b96-7300bd467159`, retained run
`5b39beb9-62b4-4241-9330-33422bbccafd`, Apple4, a screenshot, verified retention
and ordinary menu quit. Its published `s3-halls-retention-02/invocation.json`
binds Apple4/default COM, direct `Halls of Torment.exe`, no game arguments,
adf8/7106/native-web shims and the existing
`XodusCLI/prefixes/s2-9NMNMS626R59-apple4-passive-v1` save prefix.
No prefix is copied or changed by resolution. Global provider/fallback
preferences cannot substitute another recipe. Missing, partial, unknown or
mismatched evidence keeps Launch unavailable; `complete` installation is still
required before Play. This is CLI-qualified evidence, not app-tile E2E.
The projection cites S1 `27b1e67160efd8460761a48e40cf7b23aacbe862`.
Hogwarts similarly consumes S1
`f7204ef6893439ac781190ee32bd95776fd63ec7` `engines/hogwarts-qualified.json`:
Apple4 with STA1 only, direct `Phoenix/Binaries/WinGDK/HogwartsLegacy.exe`,
no game arguments and existing `s3-hogwarts-apple4-v1` prefix. Matching gameplay
`891d061f`, retention `86e8da68`, ordinary quit `f2471368` and typed
retention/quit success are required. Its new WORKING record dynamically replaces
the former quit-pending label; the UI does not write or promote the matrix.

The source-only candidate batch consumes byte-identical S1
`small-game-candidates.json` at xode-wine `27d9af8ae66b8de9883daca25c62312562c3dfbc`
(including the four candidates first published at `1282f7a92221a3cd70498f322b1d8b5efdeed1f0`,
plus Vampire and the explicit Halls block), and `preflight-game-candidates.json`
at `c32d8eb0f6b68236a87836c30ce70a3858f20c0b`. Both bundled files are SHA-256
bound in `NativeCandidateLaunchCatalogue`; they do not import S1's mutable
checkout, change global engine settings or grant game qualification.

Installed, authoritatively complete Inscryption, DREDGE, Monster Sanctuary,
TUNIC, Vampire Survivors, Skyrim Special Edition, Dishonored, Stardew Valley,
LIMBO, Kingdom Come: Deliverance and FINAL FANTASY IV use their exact published
engine, manifest executable and empty game arguments. Skyrim uses
`SkyrimSELauncher.exe`, not an inferred direct executable or Anniversary
Edition. The installed manifest must match S1's frozen hash. Unknown status,
nonempty title environment/arguments, unknown engines, conflicting engine STA
or support-library settings and per-title fallback selection fail closed.
Halls remains **Launch unavailable**, with no Play or direct-launch bypass.
Installation completeness is still independently required; a candidate does
not become WORKING, and absent test evidence stays **Not tested on Mac yet**.
Pending STA settings remain inactive.

Mixtape's `dllOverrides` field is restricted to that product, Apple4 and
`Mixtape.exe`, appending only `msvcp140_2,vcruntime140_1=n,b` to the selected
engine's existing `environment.WINEDLLOVERRIDES` in a private per-run registry.
The shared registry, its other engines and existing clauses remain unchanged;
caller environment is not used because frozen adf8 overwrites it. Conflicting
VC clauses, other titles/values and missing evidence identity are rejected.
Evidence run `005115dd-7928-4fbc-9ffa-28379040292d` proves native VC loads and
Shipping bootstrap progress in a separate STA diagnostic, not visual gameplay
or saving. Its receipt/private-registry hashes are pinned in the recipe.
The normal tile's **DLL-only recipe - unqualified** explicitly excludes pending
STA; no inference about STA necessity or automatic WORKING promotion is made.

Details also has a read-only **Save location** section. Its bundled citation
projection in `LaunchRecipes/save-locations-v1.json` preserves S4's exact
v4/v5 Windows paths, source URLs, scope and frozen packet commit/hash identities;
it never expands Windows variables into guessed Wine paths. A title's local
ledger `saveObservation.saveDirectory`, when an accessible real directory, is
labelled **Observed save directory**. Existing default Minecraft and Fallout
Documents folders are shown separately as **Folder found - save data not
verified**. In particular, Fallout's GDK container save location remains
unresolved; the Documents folder's existence does not verify it.
**Open folder** opens Finder only for a checked existing local directory,
revalidating on click. Cited-only paths have no folder action. No save bytes,
prefixes, providers or settings are changed, and this section makes no retention
or cloud-sync claim. Missing, inaccessible and moved paths remain explicit.

Native Minecraft launcher detection in the next candidate records the
actual `.app` path and `CFBundleShortVersionString`, checks its official
bundle ID and executable, and distinguishes missing, ready and repair-needed
installations. Missing offers **Install launcher**, a complete launcher offers
**Open**, and invalid/unreadable metadata or a missing executable offers
**Repair launcher** with an explanation. Install/repair open the official
Minecraft download page for manual setup, not a simulated installation or
automatic deletion/reinstall. Details includes path, version and **Check
launcher**. Java process detection remains separate; a ready launcher never
claims the game is running or an MSIXVC package is complete. These source
changes do not activate or replace the installed c22029c RC.

In unified-account mode, the app discovers complete game configurations under
`~/Games/Xodus` and registers native lifecycle records without launcher scripts
or a file-picker step. Invalid sibling folders are reported separately and
never suppress valid imports. Registration alone does not grant Play: a
read-only, account-independent `install-status` query must return `complete`.
The app checks again before each native Play request. `missing` offers Install;
`partial` offers Resume, or Repair for invalid manifest/product/package
metadata. Resume uses incremental `install`, not Repair's full redownload.
`RESOURCE_BUSY` and failed checks offer Check installation, never inferred
partial/repair. Checks have a bounded 120-second deadline: the real TUNIC
11,169-file inspection takes about 54 seconds, exceeding the previous
30-second deadline. During inspection the action stays **Checking installation…**
without a stale failure message. A deadline expiry offers the retryable
**Check is taking longer than expected** message, not an installation failure.
Checks join cancelled children and
keep their evidence outside the game folder; they do not launch Wine or
access the account. A complete snapshot is not license or gameplay proof.
Popup-monitor warnings never convert an otherwise clean game exit into an
app failure.

Minecraft uses a separate **Native launcher**
route, matched to `com.mojang.minecraftlauncher`; its Java status checks only
owned process IDs and executable paths, never credential-bearing Java arguments.

Normal app launch actions `--play-game STOREID` and
`--open-native-minecraft` invoke the same real controller actions as their
library buttons after normal startup/account readiness. They do not enable
fixtures, change catalogue admission or bypass authentication.

`tools/build_local_candidate.py` builds an engine from a clean committed checkout
with offline locked Cargo, compares its management contract with the app's,
builds a clean app-source archive, and generates exact source and signed-byte
pins in that archive only. It does not edit release producer pins, accept
unsigned arbitrary external binaries, replace an installed app, launch sign-in,
or enable Actions.

```sh
python3 tools/build_local_candidate.py \
  --engine-source /absolute/engine-checkout \
  --output-root /absolute/owned-output-directory \
  --identity DEVELOPER_ID_CERT_SHA1
```

The output is **Ode to X Local Candidate.app**, accompanied by an observed
source/build/package inventory. It uses secure-timestamped hardened Developer ID
signatures, but is explicitly **not notarized or production-qualified**.
This local sign-in candidate does not bundle the legacy game-launch capsule or
Python runtime; their absence must not be confused with qualified gameplay.
Both source checkouts must remain clean and unchanged throughout packaging.
The packager supports Apple Silicon Macs and checks all three executables are
arm64. Actual native Cargo features/profile must match the live release build;
they are recorded rather than inferred from the command alone.

These are project packaging checks, not Apple requirements or an approval
authority separate from the owner.

The owner's authorization to build, sign, install and test locally is sufficient
to do that work. Do not repeatedly request permission for those same operations.
Do not require an independently approved receipt, a second reviewer, or manual
approval of every commit/hash merely to prepare or test a local candidate.
Record exact inputs and observed results automatically so the work is
reproducible. A generated receipt records what happened; it is not permission
to proceed and does not prove that an app works.

Source revisions, schema hashes and artifact hashes are versioned compatibility
inputs, not permanent prohibitions on development. When an authorized change
updates the engine or contract, update the corresponding consumer checks,
packaging metadata and regression tests together. Investigate mismatches before
updating pins; never remove a failing check or accept arbitrary inputs just to
make packaging pass.

Do not turn a production-release requirement into a reason to stop controlled
local implementation or testing. Conversely, a successful local build or
signature is not production readiness.

## Preserve these actual protections

- Keep credentials, content keys, signing private keys and tokens out of source,
  logs and receipts. Do not export credentials or alter credential ACLs/trust
  to avoid native authentication.
- Native password, MFA and consent steps remain with the user. Certificate
  creation and signing may be automated when the owner has authorized them;
  an outstanding native authentication dialog cannot be completed by approval
  in chat alone.
- Use a new owned output directory. Preserve the installed working app and
  account/game data while preparing a replacement. Install or replace only
  within the owner's authorized scope, with a recoverable previous version.
- Bind the package to its actual source, engine, helper, schema and resources.
  Check ownership, file type, permissions, sizes, hashes and signatures.
  Reject unexpected symlinks, malformed metadata and changed staged inputs.
- Do not silently fall back to another engine, credential owner, account or
  ad-hoc signature. Report an actual failure instead of manufacturing success.
- Keep unsupported installation/play actions unavailable; do not simulate
  entitlement, owned inventory or gameplay.
- Keep GitHub Actions disabled as requested.

## Current tooling: constraints to update, not additional policy

The original release-pair implementation predates the local-development policy
above. Its fixed producer is retained in `build_app.sh`; it is no longer the
only supported way to build a local candidate:

- `tools/build_app.sh` requires exact app commit/tree, unsigned CLI hash/size,
  provenance hash/size, a clean source tree, an owned output directory and an
  explicitly selected signing identity.
- `tools/shipping_pair.py` still pins producer
  `28f737df46b29cc195145425e3fd1397ebc09be3`, tree
  `1273ddaa50a6b3e77647aabb5bb170b1b525c922`.
- `tools/verify_shipping_package.py` binds both packaged schemas to the exact
  checked-in source bytes and verifies those source files against `source.tar`.
  The management contract deliberately added one-account runtime authorization
  in `13f3532`; its SHA256 is
  `03afeb28e4e5b652712c2b6f29fe648fa05c842ea86a4920bd4f960bdbcc0529`.
  Changed packaged schemas, changed source schemas, and matching source/package
  changes after archiving are rejected. Producer/consumer schema agreement
  remains a separate required check during local-candidate packaging.
- `ShippingPairPins.approved` is nil in source. Packaging generates exact
  engine/helper pins in an isolated source stage. Changing this document does
  not generate those pins or make an existing package valid.
- Runtime executable and helper checks enforce owned regular files, safe
  permissions, exact sizes/hashes and matching helper metadata immediately
  before execution. Preserve those checks when updating the build path.

The expected release profile is opt3/debug0 with no debug assertions, overflow
checks or test mode; features are xodus/CLI empty, management live, native
Keychain and security-framework. Record the actual profile/features and explain
any intentional development difference rather than labeling a different build
as the expected release input.

Local candidate support must be explicit and tested. Do not claim that editing
this policy alone fixes the current scripts, admits a new producer, or produces
a usable app.

The separate local path was built and exercised on 21 October: app source
`a444f8fe5bb040b9d9d81e4263869385f7118977` and engine source
`96d91dbec6727b4a7409908352c48f09411d3508`. Its packaged engine passed two
fresh-process saved-account/runtime checks. The app and its separately installed
copy opened native Library windows with catalogue content and four local games.
All 24 packaged files matched the recorded inventory after copying, all three
executables were arm64 with timestamped hardened Developer ID signatures, and
deep strict signature verification passed. The original installed app was
preserved. Fresh app: `~/Applications/Ode to X Local Candidate.app`.
The owner subsequently authorized sign-out and completed a fresh native
Microsoft sign-in. Both the first candidate and an independently compiled update
passed two fresh-process saved-status/runtime checks each. The updated native app
then reopened with the sign-in saved and four local game cards, without another
login. The update uses app source `2a2555305485ddf6de1031b596ebf7747889e639`;
the previous local candidate and original Development app remain preserved.
This is interactive sign-in and local-update evidence, not qualified gameplay,
reboot/locked-Keychain coverage or notarization. Gatekeeper still reports
`Unnotarized Developer ID` (exit 3); no bypass was applied.

## Signing and saved-account access

### 0.1 release-gate checklist

These are release requirements, not claims that the current candidate passed.
Keep the live game/app unchanged until its save, clean quit and tile-relaunch
handoff; build and install the next candidate only after that handoff.

- [ ] Freeze and private-push the app source, producer source/tree, CLI/helper
  identities, runtime pair, engine recipe, shim inventory and compatibility
  data. Record each local command, source commit, exit code and log path.
- [ ] Run `tools/check.sh` and the classification validator locally. A source
  check or synthetic lifecycle process is not an `app_e2e` result.
- [ ] For **each release title**, run the coordinator's `app_e2e` gate against
  the exact installed signed app: authoritative installation status; actual
  tile launch; signed-in menu where required; controllable gameplay; changed
  save; clean in-game quit; actual tile relaunch; load and verify that save.
  Record run IDs, exact process births/window owners, full-display screenshots
  and engine/runtime/recipe identities. This repository has no local executable
  named `app_e2e`; use the coordinator-configured gate, not an invented command
  or a direct CLI launch substituted for the tile.
- [ ] Exercise real install, progress/cancel, resume, repair, uninstall and
  remove-from-library flows. Check Install/Resume/Play from authoritative
  completeness, preserve saved games, and reject unsupported titles with their
  actual format/anti-cheat reason. Inspect every required button state.
- [ ] Review every title's CLI result, actual Wine exit code/signal, game log
  and matching crash reports. A clean exit must remain clean when popup
  monitoring only warns; a missing crash report alone is not crash-free proof.
  Unresolved launch/game crashes block that title's acceptance.
- [ ] Build a fresh Developer-ID candidate with the frozen inputs above,
  preserve the old app, and verify `codesign --verify --deep --strict "$APP"`.
  Keep credential stores, installed games, prefixes and private evidence out
  of the submission archive.
- [ ] Create the app ZIP with `ditto -c -k --keepParent "$APP" "$ZIP"` and submit
  with `xcrun notarytool submit "$ZIP" --keychain-profile notary --wait
  --output-format json`. Save the external submission JSON and require
  `Accepted`; inspect the notary log on any other result. Never extract profile
  credentials or edit the sealed app receipt to assert success.
- [ ] Run `xcrun stapler staple "$APP"` and `xcrun stapler validate "$APP"`,
  then repeat strict signature verification and
  `spctl --assess --type execute --verbose=4 "$APP"`. Require a successful
  notarized Developer-ID assessment, without removing quarantine or disabling
  Gatekeeper. Recreate the distribution ZIP after stapling and record its hash.
- [ ] Install/open that exact stapled candidate and repeat saved-account,
  app-update/save-preservation and each accepted title's `app_e2e` check.
  Notarization alone does not qualify gameplay, sign-in or update persistence.

Use the owner's valid Developer ID Application identity for new candidates.
Do not re-sign a preserved working engine in place. Sign a separate candidate
and regenerate its package identity metadata consistently.

Signing identifiers remain `io.github.dragoshont.xodus`,
`io.github.dragoshont.xodus.cli` and
`io.github.dragoshont.xodus.auth-host`. The existing signing helper uses an
exact certificate-leaf requirement. This is not yet a team-based renewal policy.
Certificate renewal therefore needs a tested identity update, not an assumption
that a matching team automatically satisfies the current requirement.

The owner authorized provisioning on 21 October 2026. A valid Developer ID
Application certificate was created for team `M62Z4M5EUY`; its SHA1 is
`410914520BCC840C0125D3826CCF0F247F603321`. Separate signed candidates passed
saved-account reads, noninteractive runtime authorization, same-binary restarts,
relocation and a fresh compilation. Abiotic package-license qualification also
passed without printing/saving its content key. The preserved original owner
retained access afterward. See [the evidence](UNIFIED-ACCOUNT-SPEC.md).

Do not require two independently human-approved build receipts to test rebuild
persistence. Build into a fresh target directory, record source/toolchain/
configuration and unsigned/signed identities, then exercise the actual saved
account with that artifact. Re-signing the same binary is not a rebuild test.
The existing command below compares requirements only; it does not run that
account-access test:

```sh
python3 tools/signing_identity.py compare --kind cli --identity CERT_SHA1 \
    --first /absolute/first/signed-cli --second /absolute/second/signed-cli
```

Do not promise that all future builds, reboots or locked-Keychain situations
will be prompt-free. Test those scenarios separately and report their outcomes.
Do not revoke an unidentified certificate or delete the old signing identity
while the working app still depends on it.

## Local testing versus distribution

`XODUS_SHIPPING=1` excludes fixture state, synthetic install/job success,
illustrations, exports and native test entrypoints. It uses bundled engine/
helper paths and rejects development arguments and backend overrides.
Nonshipping products remain available for explicitly requested development.
Preserve that separation; a local candidate need not be called a production
release to be useful.

`tools/check.sh` is the documented regression entrypoint. Capture each failure
truthfully and continue independent checks where useful. A passing subset does
not make the full command green. Synthetic checks do not replace live account,
UI, package-consumer or gameplay observations.

Developer ID signing alone is not notarization. The current signing helper
defaults to local signing with `--timestamp=none` and no hardened runtime.
Its explicit `sign --developer-id` mode requires a valid Developer ID Application
certificate and requests a secure timestamp plus hardened runtime:

```sh
python3 tools/signing_identity.py sign --kind cli --path /absolute/new/candidate \
    --identity CERT_SHA1 --developer-id
```

Do not apply that mode to an installed working binary. Hardened-runtime
compatibility still needs live testing; no permissive entitlements are added
automatically. `build_app.sh` does not yet select this distribution mode.
Gatekeeper rejected
the observed candidate as `Unnotarized Developer ID`. A distribution path needs
appropriate signing options/entitlements, notarization and applicable ticket/
Gatekeeper verification. Do not disable Gatekeeper or remove quarantine to
pretend those checks passed. Submission to Apple's notarization service is a
separate external operation; do not send credential stores or private evidence.

Call the product production-ready only after verifying the integrated app's
actual sign-in, restart/update behavior, error recovery and supported user
flows. A package-license check is not a launched game; standalone Wine controls
are not Xbox-route gameplay. Keep measured results, remaining defects and
untested scenarios distinct. Owner authorization permits the work; it does not
turn an untested result into a pass.
